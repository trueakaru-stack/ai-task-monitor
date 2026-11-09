#!/usr/bin/env python3
"""Probe only a disposable runner, a private temporary socket, and account-dir metadata."""
import errno
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile

DENIED = {errno.EPERM, errno.EACCES}

def denied_connect(family, target):
    try:
        client = socket.socket(family, socket.SOCK_STREAM)
    except OSError as exc:
        if exc.errno not in DENIED:
            raise
        return
    try:
        if client.connect_ex(target) not in DENIED:
            raise RuntimeError("Expected socket denial was not observed")
    finally:
        client.close()

if len(sys.argv) == 5 and sys.argv[1] == "--child":
    socket_path, account_path, mode = sys.argv[2:]
    denied_connect(socket.AF_INET, ("127.0.0.1", 0))
    denied_connect(socket.AF_INET6, ("::1", 0))
    denied_connect(socket.AF_UNIX, socket_path)
    try:
        os.stat(account_path)
    except OSError as exc:
        if exc.errno not in DENIED:
            raise
    else:
        raise RuntimeError("Account directory metadata was not denied")
    if mode == "preview":
        try:
            child = os.posix_spawn("/usr/bin/true", ["/usr/bin/true"], {})
        except OSError as exc:
            if exc.errno not in DENIED:
                raise
        else:
            os.waitpid(child, 0)
            raise RuntimeError("Preview spawn denial was not observed")
    print("Synthetic socket and account-dir denial confirmed")
    raise SystemExit(0)

if len(sys.argv) != 5:
    raise SystemExit("Expected profile, temporary directory, account path, and kind")
profile, temp, account, kind = sys.argv[1:]
if sys.platform != "darwin" or kind not in ("build", "preview"):
    raise SystemExit("Unexpected probe platform or kind")
temp_dir = Path(temp).resolve(strict=True)
if not str(temp_dir).startswith("/private/tmp/aitm-policy-"):
    raise SystemExit("Unexpected synthetic temporary root")
directory = Path(tempfile.mkdtemp(prefix="sock-", dir=temp_dir))
path = directory / "s"
if len(os.fsencode(path)) >= 100:
    raise SystemExit("Synthetic socket path too long")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    server.bind(str(path))
    server.listen(1)
    result = subprocess.run(
        ["/usr/bin/sandbox-exec", "-f", profile, "/usr/bin/python3", "-I", "-S", "-B",
         str(Path(__file__).resolve()), "--child", str(path), account, kind],
        env={"PATH": "/usr/bin:/bin", "TMPDIR": str(temp_dir) + "/"},
        cwd=str(temp_dir), stdin=subprocess.DEVNULL, capture_output=True, timeout=15,
    )
    if result.returncode != 0 or result.stdout.strip() != b"Synthetic socket and account-dir denial confirmed":
        raise SystemExit("Isolation probe failed: " + result.stderr.decode("utf-8", "replace")[:1000])
    print(kind + ": synthetic socket and account-dir denial confirmed")
finally:
    server.close()
    if os.path.lexists(path):
        path.unlink()
    directory.rmdir()
