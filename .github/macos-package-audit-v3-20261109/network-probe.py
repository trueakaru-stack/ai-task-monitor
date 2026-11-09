#!/usr/bin/env python3
"""Verify the disposable runner permits only the intended synthetic sockets."""
import errno
import os
import socket
import sys
import tempfile

mode = sys.argv[1]
if mode not in ("strict", "loopback"):
    raise SystemExit("Unknown network probe")

def rejected(family, address):
    try:
        client = socket.socket(family, socket.SOCK_STREAM)
    except OSError as error:
        if error.errno not in (errno.EPERM, errno.EACCES):
            raise
        return
    try:
        if client.connect_ex(address) not in (errno.EPERM, errno.EACCES):
            raise SystemExit("Expected network denial was not enforced")
    finally:
        client.close()

if mode == "strict":
    rejected(socket.AF_INET, ("127.0.0.1", 0))
    rejected(socket.AF_INET6, ("::1", 0))
else:
    rejected(socket.AF_INET, ("192.0.2.1", 9))
    rejected(socket.AF_INET6, ("2001:db8::1", 9))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client.connect(listener.getsockname())
        peer, _ = listener.accept()
        peer.close()
    finally:
        client.close()
        listener.close()
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        try:
            listener.bind(("0.0.0.0", 0))
        except OSError as error:
            if error.errno not in (errno.EPERM, errno.EACCES):
                raise
        else:
            raise SystemExit("Wildcard socket binding was not denied")
    finally:
        listener.close()

directory = tempfile.mkdtemp(prefix="aitm-unified-probe-", dir="/private/tmp")
path = os.path.join(directory, "events.sock")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    server.bind(path)
    server.listen(1)
    client.connect(path)
    peer, _ = server.accept()
    peer.close()
finally:
    client.close()
    server.close()
    if os.path.exists(path):
        os.unlink(path)
    os.rmdir(directory)
print("Network probe passed:", mode)
