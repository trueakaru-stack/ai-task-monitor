"""Own exactly one startup child and reap it before forgetting its identity."""
import os
from pathlib import Path
import signal
import subprocess
import sys

PROFILE = "(version 1) (allow default) (deny network*) (deny process-fork)"

def stop_owned(child, grace):
    """Never signal an already reaped child; kill only after a timed-out wait."""
    if child.returncode is not None:
        return "already-exited"
    signal_error = None
    try:
        child.terminate()
    except ProcessLookupError:
        pass
    except OSError as error:
        signal_error = error
    try:
        child.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        try:
            child.kill()
        except ProcessLookupError:
            pass
        finally:
            child.wait(timeout=grace)
        if signal_error is not None:
            raise signal_error
        return "killed-after-timeout"
    if signal_error is not None:
        raise signal_error
    return "exited-after-term-attempt"

def observe_owned(command, environment, log_file, observe_seconds, grace, check_identity=None, cwd=None):
    """An early exit is a failed smoke check; a live child is always stopped/reaped."""
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    with Path(log_file).open("xb") as output:
        child = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=subprocess.STDOUT, creationflags=flags, cwd=cwd)
        try:
            try:
                status = child.wait(timeout=observe_seconds)
            except subprocess.TimeoutExpired:
                if check_identity is not None:
                    check_identity(child)
            else:
                raise RuntimeError("Application exited before observation period: " + str(status))
        finally:
            outcome = stop_owned(child, grace)
    return outcome

def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("RUNNER_OS") != "macOS"):
        raise SystemExit("Startup owner requires a disposable hosted macOS runner")
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise SystemExit("Unexpected SIGCHLD handler")
    if len(sys.argv) != 4 or sys.argv[3] != PROFILE:
        raise SystemExit("Unexpected startup profile or arguments")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    expected_binary = temp / "aitm-package-candidate-v1/macos/dist/AI Task Monitor.app/Contents/MacOS/AITaskMonitor"
    expected_log = temp / "aitm-package-output/startup.log"
    binary = Path(sys.argv[1]).resolve(strict=True)
    log = Path(sys.argv[2]).resolve(strict=False)
    if binary != expected_binary or log != expected_log:
        raise SystemExit("Unexpected startup executable or log path")
    expected_paths = {
        "CFFIXED_USER_HOME": temp / "aitm-package-home",
        "AI_TASK_MONITOR_SUPPORT_DIR": temp / "aitm-package-support",
        "TMPDIR": temp / "aitm-package-tmp",
    }
    for name, expected in expected_paths.items():
        if Path(os.environ[name]).resolve(strict=True) != expected:
            raise SystemExit("Unexpected synthetic startup directory")
    cwd = Path(os.environ["AITM_SYNTHETIC_CWD"]).resolve(strict=True)
    if cwd != temp / "aitm-package-app-cwd" or not cwd.is_dir() or any(cwd.iterdir()):
        raise SystemExit("Startup working directory must be the empty synthetic directory")
    env = {name: os.environ[name] for name in
           ("PATH", "DEVELOPER_DIR", "TMPDIR", "CFFIXED_USER_HOME", "AI_TASK_MONITOR_SUPPORT_DIR")}
    def verify_identity(child):
        result = subprocess.run(["/bin/ps", "-p", str(child.pid), "-o", "comm="],
                                env={"PATH": "/usr/bin:/bin"}, capture_output=True, timeout=3, check=True)
        if b"AITaskMonitor" not in result.stdout:
            raise RuntimeError("The owned process is not the application executable")
    def interrupt(signum, frame):
        raise InterruptedError("Startup owner received termination")
    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        outcome = observe_owned(["/usr/bin/sandbox-exec", "-p", PROFILE, str(binary)],
                                env, log, 5, 5, verify_identity, cwd)
    finally:
        signal.signal(signal.SIGTERM, previous)
    print("Restricted app remained alive for five seconds; cleanup:", outcome)
    print("No interactive behavior or actual user integration is asserted")

if __name__ == "__main__":
    main()
