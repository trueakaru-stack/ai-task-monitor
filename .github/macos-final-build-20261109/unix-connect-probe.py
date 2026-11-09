"""Test denied Unix connect against our own synthetic local listener."""
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

profile = "(version 1) (allow default) (deny network*) (deny process-fork)"
if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
    os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or
    os.environ.get("RUNNER_OS") != "macOS"):
    raise SystemExit("Probe requires a disposable hosted macOS runner")
if len(sys.argv) != 3 or sys.argv[2] != profile:
    raise SystemExit("Unexpected probe arguments")
temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
temporary = Path(os.environ["TMPDIR"]).resolve(strict=True)
if temporary != temp / "aitm-package-tmp":
    raise SystemExit("Unexpected temporary directory")
workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
probe = Path(sys.argv[1]).resolve(strict=True)
if probe != workspace / ".github/macos-final-build-20261109/startup-sandbox-probe.py":
    raise SystemExit("Unexpected inner probe")
directory = Path(tempfile.mkdtemp(prefix="aitm-ipc-probe-", dir=temporary))
path = directory / "socket"
server = None
try:
    if len(os.fsencode(path)) >= 100:
        raise SystemExit("Synthetic Unix socket path is too long")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    server.listen(1)
    env = {"PATH": "/usr/bin:/bin", "TMPDIR": str(temporary) + "/"}
    result = subprocess.run(
        ["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/python3", "-I", "-S", "-B",
         str(probe), "--unix-connect", str(path)],
        env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=15
    )
    if result.returncode != 0 or result.stdout.strip() != b"Synthetic Unix connect denied":
        raise SystemExit("Synthetic Unix connect denial not confirmed")
    print("Synthetic Unix listener was present and restricted connect was denied")
finally:
    if server is not None:
        server.close()
    if os.path.lexists(path):
        path.unlink()
    directory.rmdir()
