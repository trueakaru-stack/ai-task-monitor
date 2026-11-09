"""Compare nested and direct strict sandbox against one synthetic Unix listener."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

OUTER = "(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket))"
STRICT = "(version 1) (allow default) (deny network*) (deny process-fork)"


def report(result):
    if len(result.stdout) > 65536 or len(result.stderr) > 65536:
        raise RuntimeError("Unexpectedly large diagnostic output")
    return {"returncode": result.returncode, "stdout_bytes": len(result.stdout),
            "stderr_bytes": len(result.stderr), "stdout": result.stdout.decode("utf-8", "replace"),
            "stderr": result.stderr.decode("utf-8", "replace")}


def run_inner(probe, target, environment):
    return subprocess.run(["/usr/bin/sandbox-exec", "-p", STRICT, "/usr/bin/python3", "-I", "-S", "-B",
                           str(probe), "--unix-connect", str(target)], env=environment,
                          stdin=subprocess.DEVNULL, capture_output=True, timeout=15)


def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("RUNNER_OS") != "macOS"):
        raise SystemExit("Diagnostic requires a disposable hosted macOS runner")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    inputs = workspace / ".github/macos-unix-nested-diagnostic-20261109"
    probe = (inputs / "startup-sandbox-probe.py").resolve(strict=True)
    script = (inputs / "diagnostic.py").resolve(strict=True)
    if Path(__file__).resolve(strict=True) != script:
        raise SystemExit("Unexpected diagnostic file")
    temporary = temp / "aitm-package-tmp"
    environment = {"PATH": "/usr/bin:/bin", "TMPDIR": str(temporary) + "/", "RUNNER_TEMP": str(temp),
                   "GITHUB_WORKSPACE": str(workspace), "GITHUB_ACTIONS": "true",
                   "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_OS": "macOS"}
    if len(sys.argv) == 3 and sys.argv[1] == "--nested":
        target = Path(sys.argv[2])
        if (target.parent.parent.resolve(strict=True) != temporary.resolve(strict=True) or
            not target.parent.name.startswith("aitm-ipc-probe-") or target.name != "socket"):
            raise SystemExit("Unexpected synthetic socket")
        print(json.dumps(report(run_inner(probe, target, environment))), flush=True)
        return
    if len(sys.argv) != 1 or temporary.exists():
        raise SystemExit("Unexpected arguments or pre-existing synthetic directory")
    temporary.mkdir(mode=0o700)
    directory = Path(tempfile.mkdtemp(prefix="aitm-ipc-probe-", dir=temporary))
    target = directory / "socket"
    listener = None
    try:
        if len(os.fsencode(target)) >= 100:
            raise SystemExit("Synthetic Unix socket path is too long")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(target))
        listener.listen(1)
        direct = report(run_inner(probe, target, environment))
        print("DIRECT=" + json.dumps(direct), flush=True)
        if direct["returncode"] != 0 or direct["stdout"].strip() != "Synthetic Unix connect denied":
            raise SystemExit("Direct strict sandbox did not prove Unix connect denial")
        outer = subprocess.run(["/usr/bin/sandbox-exec", "-p", OUTER, "/usr/bin/python3", "-I", "-S", "-B",
                                str(script), "--nested", str(target)], env=environment,
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        outer_report = report(outer)
        print("OUTER=" + json.dumps(outer_report), flush=True)
        if outer.returncode != 0:
            raise SystemExit("Outer diagnostic did not return an inner result")
        nested = json.loads(outer_report["stdout"])
        print("NESTED=" + json.dumps(nested), flush=True)
        if nested["returncode"] == 0 or "sandbox_apply" not in nested["stderr"]:
            raise SystemExit("Nested failure differs from the proposed cause")
        print("Nested sandbox failure reproduced; direct strict Unix denial confirmed", flush=True)
    finally:
        if listener is not None:
            listener.close()
        if os.path.lexists(target):
            target.unlink()
        directory.rmdir()
        temporary.rmdir()


if __name__ == "__main__":
    main()
