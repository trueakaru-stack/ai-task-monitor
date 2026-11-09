"""Confirm restricted launch denies TCP, AF_UNIX, fork and posix_spawn."""
import errno
import os
from pathlib import Path
import socket
import sys
import tempfile

denied = {errno.EACCES, errno.EPERM}
if len(sys.argv) == 3 and sys.argv[1] == "--unix-connect":
    temporary = Path(os.environ["TMPDIR"]).resolve(strict=True)
    target = Path(sys.argv[2])
    if (target.parent.parent.resolve(strict=True) != temporary or
        not target.parent.name.startswith("aitm-ipc-probe-") or target.name != "socket"):
        raise SystemExit("Unexpected synthetic Unix socket path")
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError as error:
        if error.errno not in denied:
            raise
    else:
        try:
            try:
                client.connect(str(target))
            except OSError as error:
                if error.errno not in denied:
                    raise
            else:
                raise SystemExit("Unix connect denial not confirmed")
        finally:
            client.close()
    print("Synthetic Unix connect denied")
    raise SystemExit(0)
if len(sys.argv) != 1:
    raise SystemExit("Unexpected sandbox probe arguments")
for family, address in ((socket.AF_INET, ("127.0.0.1", 0)), (socket.AF_INET6, ("::1", 0))):
    try:
        client = socket.socket(family, socket.SOCK_STREAM)
    except OSError as error:
        if error.errno not in denied:
            raise
        continue
    try:
        if client.connect_ex(address) not in denied:
            raise SystemExit("TCP denial not confirmed")
    finally:
        client.close()
try:
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
except OSError as error:
    if error.errno not in denied:
        raise
else:
    directory = Path(tempfile.mkdtemp(prefix="aitm-start-probe-"))
    path = directory / "socket"
    try:
        try:
            server.bind(str(path))
        except OSError as error:
            if error.errno not in denied:
                raise
        else:
            raise SystemExit("Unix bind denial not confirmed")
    finally:
        server.close()
        if path.exists():
            path.unlink()
        directory.rmdir()
try:
    child = os.fork()
except OSError as error:
    if error.errno not in denied:
        raise
else:
    if child == 0:
        os._exit(0)
    os.waitpid(child, 0)
    raise SystemExit("Fork denial not confirmed")
try:
    child = os.posix_spawn("/usr/bin/true", ["/usr/bin/true"], {})
except OSError as error:
    if error.errno not in denied:
        raise
else:
    os.waitpid(child, 0)
    raise SystemExit("Spawn denial not confirmed")
print("Restricted startup probe denied TCP loopback, Unix bind, fork and posix_spawn")
print("This does not prove all possible filesystem, network or IPC operations")
