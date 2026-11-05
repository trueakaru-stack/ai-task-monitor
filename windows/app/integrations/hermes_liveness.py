"""Read-only Hermes v0.22.7 liveness probes for an explicitly selected profile set.

This is a preflight, not an atomic reservation: a caller must not infer that a
closed Hermes will remain closed while another operation runs. No plugin manager
is started here and no session registry is cleaned up or rewritten.
"""

from contextlib import contextmanager
import errno
import os
from pathlib import Path
import stat

from .provider_bundle import BundleError, _plain_path


class HermesLivenessError(Exception):
    """Fixed, non-sensitive reason; never include registry contents or paths."""


def _exists(path, directory=None):
    _plain_path(path, directory=directory, missing=True)
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError:
        raise HermesLivenessError("liveness-unconfirmed") from None


@contextmanager
def _existing_lock(path, offset):
    if not _exists(path, directory=False):
        yield False
        return
    before = path.lstat()
    flags = os.O_RDWR | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError:
        raise HermesLivenessError("liveness-unconfirmed") from None
    locked = False
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise HermesLivenessError("liveness-unconfirmed")
        try:
            if os.name == "nt":
                import msvcrt
                os.lseek(fd, offset, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            locked = True
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                raise HermesLivenessError("hermes-running") from None
            raise HermesLivenessError("liveness-unconfirmed") from None
        yield True
    finally:
        if locked:
            try:
                if os.name == "nt":
                    os.lseek(fd, offset, os.SEEK_SET)
                    msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
                else:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(fd)


def require_hermes_closed(profiles, host_lock_directory, session_api):
    """Fail closed on active or unreadable locks and session leases.

    ``session_api`` is the verified installation's hermes_cli.active_sessions;
    its strict reader and PID-liveness checker are used without its cleanup path.
    ``profiles`` must already include every profile sharing the dependency home.
    """
    try:
        if not profiles or len(profiles) > 256:
            raise HermesLivenessError("liveness-unconfirmed")
        if not os.path.isabs(str(host_lock_directory)) or any(not os.path.isabs(str(item)) for item in profiles):
            raise HermesLivenessError("liveness-unconfirmed")
        paths = [_plain_path(Path(item), directory=True) for item in profiles]
        if len({os.path.normcase(str(path)) for path in paths}) != len(paths):
            raise HermesLivenessError("liveness-unconfirmed")
        host = Path(host_lock_directory)
        _plain_path(host, directory=True, missing=True)
        for name in ("host-gateway.lock", "host-serve.lock", "host-desktop-serve.lock"):
            with _existing_lock(host / name, 1_048_576):
                pass
        for profile in paths:
            _plain_path(profile / "config.yaml", directory=False)
            with _existing_lock(profile / "gateway.lock", 1_048_576):
                pass
            runtime = profile / "runtime"
            registry, lock = runtime / "active_sessions.json", runtime / "active_sessions.lock"
            if not _exists(registry, directory=False):
                # A present lock can still be held while a registry is being created.
                with _existing_lock(lock, 0):
                    pass
                continue
            if registry.lstat().st_size > 1_048_576:
                raise HermesLivenessError("liveness-unconfirmed")
            with _existing_lock(lock, 0) as exists:
                if not exists:
                    raise HermesLivenessError("liveness-unconfirmed")
                if session_api._prune_dead(session_api._read_entries(registry, strict=True), strict=True):
                    raise HermesLivenessError("hermes-running")
    except HermesLivenessError:
        raise
    except (BundleError, OSError, ValueError, TypeError, AttributeError, RuntimeError):
        raise HermesLivenessError("liveness-unconfirmed") from None
