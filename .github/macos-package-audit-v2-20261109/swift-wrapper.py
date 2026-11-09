#!/usr/bin/python3 -I
"""Constrain the audit's one SwiftPM invocation while retaining the outer sandbox."""
import os
from pathlib import Path
import subprocess
import sys

ALLOWED = ("build", "-c", "release", "--arch", "arm64", "--arch", "x86_64")
PASSTHROUGH = ("DEVELOPER_DIR", "RUNNER_TEMP", "GITHUB_WORKSPACE", "TMPDIR", "CFFIXED_USER_HOME",
               "AI_TASK_MONITOR_SUPPORT_DIR", "AITM_SYNTHETIC_HOME", "GITHUB_ACTIONS", "CI",
               "RUNNER_ENVIRONMENT", "RUNNER_OS")
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def build_arguments(arguments):
    if tuple(arguments) != ALLOWED:
        raise ValueError("Unexpected Swift invocation")
    return ["build", "--disable-sandbox", *ALLOWED[1:]]


def clean_environment(source):
    result = {name: source[name] for name in PASSTHROUGH}
    result["PATH"] = SYSTEM_PATH
    return result


def selected_swift(developer, selected):
    expected = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    if not expected.is_file() or not os.access(expected, os.X_OK):
        raise ValueError("Expected Swift toolchain executable is unavailable")
    if Path(selected).resolve(strict=True) != expected.resolve(strict=True):
        raise ValueError("Selected Swift is not the expected Xcode toolchain")
    return expected


def main():
    command_args = build_arguments(sys.argv[1:])
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("RUNNER_OS") != "macOS"):
        raise SystemExit("Swift wrapper requires a disposable hosted macOS runner")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    wrapper = temp / "aitm-package-swift-wrapper/swift"
    actual_wrapper = Path(sys.argv[0])
    if actual_wrapper.is_symlink() or actual_wrapper.resolve(strict=True) != wrapper:
        raise SystemExit("Unexpected Swift wrapper path")
    if Path.cwd().resolve() != temp / "aitm-package-candidate-v1/macos":
        raise SystemExit("Unexpected package working directory")
    developer = Path(os.environ["DEVELOPER_DIR"]).resolve(strict=True)
    environment = clean_environment(os.environ)
    selected = subprocess.run(["/usr/bin/xcrun", "--find", "swift"], check=True, timeout=30,
                              capture_output=True, text=True, env=environment).stdout.strip()
    swift = selected_swift(developer, selected)
    probe = workspace / ".github/macos-package-audit-v2-20261109/network-probe.py"
    subprocess.run(["/usr/bin/python3", "-I", "-S", "-B", str(probe), "strict"],
                   check=True, timeout=30, env=environment)
    with (wrapper.parent / "invoked").open("x", encoding="ascii") as marker:
        marker.write("one checked invocation\n")
    print("Selected Xcode Swift:", swift, flush=True)
    print("Verified SwiftPM invocation; outer network probe passed", flush=True)
    os.execve(str(swift), [str(swift), *command_args], environment)


if __name__ == "__main__":
    main()
