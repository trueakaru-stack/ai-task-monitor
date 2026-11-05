"""Ownership-safe staging of observer bundles in an explicitly chosen profile.

This module never enables plugins, edits agent configuration, invokes a package
manager, discovers active profiles, or starts an agent. Connection controllers
must establish the host contract and perform the agent's own consent separately.
"""

import hashlib
import ctypes
import json
import importlib.util
import io
import marshal
import os
from pathlib import Path
import re
import stat
import struct
import sys
import types
import uuid


class BundleError(Exception):
    """A fixed error code suitable for display without exposing profile content."""


_BUNDLES = {
    "hermes": {
        "contract": "hermes.observer.v1",
        "profile_file": "config.yaml",
        "parent": ("plugins",),
        "folder": "ai-task-monitor",
        "files": {"hermes-entry.py": "__init__.py", "hermes-plugin.yaml": "plugin.yaml",
                  "hermes_observer.py": "hermes_observer.py", "provider_hooks.py": "provider_hooks.py",
                  "provider_sender.py": "provider_sender.py", "provider_transport.py": "provider_transport.py"},
    },
    "deepseek": {
        "contract": "dsh.cordis.bundle.v1",
        "profile_file": "package.json",
        "parent": (),
        "folder": "ai-task-monitor-observer",
        "files": {name: name for name in ("package.json", "cordis.patch.yml", "deepseek-plugin.js",
                                         "provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs")},
    },
}
_MAX_FILE = 1_048_576
_MARKER = "aitm-manifest.json"
_SCOPE = "monitor-profile.json"


def _plain_path(path, directory=None, missing=False):
    """Reject links/reparse points in every ancestor, including dangling links."""
    path = Path(os.path.abspath(path))
    for item in (*reversed(path.parents), path):
        try:
            info = item.lstat()
        except FileNotFoundError:
            if missing:
                continue
            raise BundleError("missing-path") from None
        if (stat.S_ISLNK(info.st_mode)
                or getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)):
            raise BundleError("linked-path")
        expected_directory = item != path or directory is True
        if expected_directory and not stat.S_ISDIR(info.st_mode):
            raise BundleError("invalid-path")
        if item == path and directory is False and not stat.S_ISREG(info.st_mode):
            raise BundleError("invalid-path")
    return path


def _read(path, maximum=_MAX_FILE):
    _plain_path(path, directory=False)
    before = path.lstat()
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (not stat.S_ISREG(opened.st_mode) or opened.st_dev != before.st_dev or opened.st_ino != before.st_ino):
            raise BundleError("changed-file")
        value = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
        if after.st_size != opened.st_size or after.st_mtime_ns != opened.st_mtime_ns:
            raise BundleError("changed-file")
    if len(value) > maximum:
        raise BundleError("oversized-file")
    return value


def _digest(value):
    return hashlib.sha256(value).hexdigest()


def _same_code(actual, expected):
    if not isinstance(actual, types.CodeType) or not isinstance(expected, types.CodeType):
        return False
    attributes = ("co_argcount", "co_posonlyargcount", "co_kwonlyargcount", "co_nlocals", "co_stacksize",
                  "co_flags", "co_code", "co_names", "co_varnames", "co_freevars", "co_cellvars", "co_filename",
                  "co_name", "co_qualname", "co_firstlineno", "co_linetable", "co_exceptiontable")
    if any(getattr(actual, name, None) != getattr(expected, name, None) for name in attributes):
        return False
    if len(actual.co_consts) != len(expected.co_consts):
        return False
    for left, right in zip(actual.co_consts, expected.co_consts):
        if not _same_constant(left, right):
            return False
    return True


def _same_constant(actual, expected):
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, types.CodeType):
        return _same_code(actual, expected)
    if isinstance(expected, tuple):
        return len(actual) == len(expected) and all(_same_constant(a, b) for a, b in zip(actual, expected))
    if isinstance(expected, frozenset):
        if len(actual) != len(expected) or len(actual) > 4096:
            return False
        remaining = list(actual)
        for value in expected:
            index = next((i for i, item in enumerate(remaining) if _same_constant(item, value)), None)
            if index is None:
                return False
            remaining.pop(index)
        return True
    if isinstance(expected, float):
        return struct.pack("<d", actual) == struct.pack("<d", expected)
    if isinstance(expected, complex):
        return struct.pack("<dd", actual.real, actual.imag) == struct.pack("<dd", expected.real, expected.imag)
    return actual == expected


def _write_new(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(value)


def _move_new(source, target):
    if os.name == "nt":
        os.rename(source, target)  # Windows never replaces an existing target.
    elif sys.platform == "darwin":
        library = ctypes.CDLL(None, use_errno=True)
        rename = library.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(source), os.fsencode(target), 4) != 0:  # RENAME_EXCL
            raise BundleError("bundle-conflict")
    else:
        raise BundleError("unsupported-platform")


class ProviderBundle:
    def __init__(self, provider, profile):
        if provider not in _BUNDLES:
            raise BundleError("unsupported-provider")
        self.provider = provider
        self.spec = _BUNDLES[provider]
        self.profile = _plain_path(profile, directory=True)
        _plain_path(self.profile / self.spec["profile_file"], directory=False)
        self.parent = self.profile.joinpath(*self.spec["parent"])
        self.folder = self.parent / self.spec["folder"]

    def _owned(self):
        _plain_path(self.folder, directory=True, missing=True)
        if not self.folder.exists():
            return None
        try:
            marker = json.loads(_read(self.folder / _MARKER, 16_384))
            expected = set(self.spec["files"].values()) | {_SCOPE}
            if (set(marker) != {"owner", "provider", "contract", "files"}
                    or marker["owner"] != "AI Task Monitor observer v1"
                    or marker["provider"] != self.provider or marker["contract"] != self.spec["contract"]
                    or not isinstance(marker["files"], dict) or set(marker["files"]) != expected):
                raise BundleError("modified-bundle")
            names = set(item.name for item in self.folder.iterdir())
            if names not in (expected | {_MARKER}, expected | {_MARKER, "__pycache__"}):
                raise BundleError("modified-bundle")
            for name, expected_hash in marker["files"].items():
                if _digest(_read(self.folder / name)) != expected_hash:
                    raise BundleError("modified-bundle")
            scope = json.loads(_read(self.folder / _SCOPE, 256))
            if (set(scope) != {"namespace"} or not isinstance(scope["namespace"], str)
                    or len(scope["namespace"]) != 32 or any(c not in "0123456789abcdef" for c in scope["namespace"])):
                raise BundleError("modified-bundle")
            self._owned_bytecode()
            return marker
        except (OSError, ValueError, TypeError, KeyError, EOFError):
            raise BundleError("modified-bundle") from None

    def _owned_bytecode(self):
        """Recognize only bytecode exactly reproducible from the verified Python sources."""
        cache = self.folder / "__pycache__"
        _plain_path(cache, directory=True, missing=True)
        if not cache.exists():
            return []
        if self.provider != "hermes":
            raise BundleError("modified-bundle")
        tag = getattr(sys.implementation, "cache_tag", "")
        if not isinstance(tag, str) or not tag:
            raise BundleError("unsupported-python")
        pattern = re.compile(r"^(.+)\." + re.escape(tag) + r"(?:\.opt-([12]))?\.pyc$")
        sources = {Path(name).stem: name for name in self.spec["files"].values() if name.endswith(".py")}
        recognized = []
        for item in cache.iterdir():
            match = pattern.fullmatch(item.name)
            if match is None or match.group(1) not in sources:
                raise BundleError("modified-bundle")
            source_path = self.folder / sources[match.group(1)]
            source = _read(source_path)
            data = _read(item, 2 * _MAX_FILE)
            if len(data) < 16 or data[:4] != importlib.util.MAGIC_NUMBER:
                raise BundleError("modified-bundle")
            flags = struct.unpack("<I", data[4:8])[0]
            if flags == 0:
                info = source_path.stat()
                header = struct.pack("<II", int(info.st_mtime) & 0xffffffff, len(source) & 0xffffffff)
            elif flags in (1, 3):
                header = importlib.util.source_hash(source)
            else:
                raise BundleError("modified-bundle")
            level = int(match.group(2) or "0")
            expected = compile(source, str(source_path), "exec", dont_inherit=True, optimize=level)
            stream = io.BytesIO(data[16:])
            cached = marshal.load(stream)
            if data[8:16] != header or stream.read(1) or not _same_code(cached, expected):
                raise BundleError("modified-bundle")
            recognized.append((item, _digest(data)))
        return recognized

    def state(self):
        # Staged is deliberately not connected: host activation is separate.
        return "staged" if self._owned() is not None else "absent"

    def install(self, assets, contract, before_commit=None):
        if contract != self.spec["contract"]:
            raise BundleError("unverified-contract")
        source = _plain_path(assets, directory=True)
        values = {target: _read(source / name) for name, target in self.spec["files"].items()}
        _plain_path(self.parent, directory=True, missing=True)
        self.parent.mkdir(mode=0o700, parents=False, exist_ok=True)
        _plain_path(self.parent, directory=True)
        lock = self.parent / ("." + self.spec["folder"] + ".lock")
        try:
            descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise BundleError("bundle-busy") from None
        stage = None
        created = []
        try:
            existing = self._owned()
            if existing is not None:
                if any(existing["files"][name] != _digest(value) for name, value in values.items()):
                    raise BundleError("bundle-update-required")
                return "staged"
            stage = self.parent / (".aitm-stage-" + uuid.uuid4().hex)
            stage.mkdir(mode=0o700)
            values[_SCOPE] = json.dumps({"namespace": uuid.uuid4().hex}).encode("ascii")
            for name, value in values.items():
                target = stage / name
                _write_new(target, value)
                created.append(target)
            marker = {"owner": "AI Task Monitor observer v1", "provider": self.provider,
                      "contract": contract, "files": {name: _digest(value) for name, value in values.items()}}
            _write_new(stage / _MARKER, json.dumps(marker, sort_keys=True).encode("ascii"))
            created.append(stage / _MARKER)
            if before_commit is not None:
                before_commit()
            _plain_path(self.parent, directory=True)
            # Do not replace even an empty directory created by another process.
            if os.path.lexists(self.folder):
                raise BundleError("bundle-conflict")
            _move_new(stage, self.folder)
            stage = None
            return "staged"
        finally:
            os.close(descriptor)
            if stage is not None:
                _plain_path(stage, directory=True)
                for target in created:
                    _plain_path(target, directory=False)
                    target.unlink()
                stage.rmdir()
            lock.unlink()

    def remove(self, before_commit=None):
        _plain_path(self.parent, directory=True, missing=True)
        if not self.parent.exists():
            return "absent"
        lock = self.parent / ("." + self.spec["folder"] + ".lock")
        try:
            descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            raise BundleError("bundle-busy") from None
        try:
            marker = self._owned()
            if marker is None:
                return "absent"
            if before_commit is not None:
                before_commit()
            if self._owned() != marker:
                raise BundleError("bundle-changed")
            cache = self._owned_bytecode()
            for path, expected_hash in cache:
                if _digest(_read(path, 2 * _MAX_FILE)) != expected_hash:
                    raise BundleError("bundle-changed")
            for path, _ in cache:
                path.unlink()
            cache_directory = self.folder / "__pycache__"
            if cache_directory.exists():
                cache_directory.rmdir()
            for name in marker["files"]:
                (self.folder / name).unlink()
            (self.folder / _MARKER).unlink()
            self.folder.rmdir()
            return "absent"
        finally:
            os.close(descriptor)
            lock.unlink()
