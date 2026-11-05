"""Small, silent, bounded local transport for already-sanitized hook events."""

import hashlib
import json
import os
import re
import socket
import stat
import struct
import threading

_SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z", re.ASCII)
_SAFE_PIPE = re.compile(r"AITaskMonitor\.[A-Za-z0-9_.-]{1,100}\Z", re.ASCII)
_PROVIDERS = {"kimi", "deepseek", "hermes", "opencode"}
_KINDS = {"started", "active", "waiting", "unknown", "idle", "completed", "failed", "interrupted", "plan", "gap", "tool_started", "tool_finished", "heartbeat"}
_FIELDS = {"version", "provider", "session", "kind", "turn", "steps", "call", "action"}
_IN_FLIGHT_SENDS = threading.BoundedSemaphore(4)


def user_pipe_name(profile=None):
    profile = os.environ.get("USERPROFILE") if profile is None else profile
    if not profile:
        return None
    digest = hashlib.sha256(profile.encode("utf-8")).hexdigest()[:24]
    return "AITaskMonitor.ProviderEvents." + digest


def _encode(value):
    try:
        if (not isinstance(value, dict) or set(value) - _FIELDS or type(value.get("version")) is not int
                or value["version"] != 1 or value.get("provider") not in _PROVIDERS
                or not isinstance(value.get("session"), str) or not _SAFE_ID.fullmatch(value["session"])
                or value.get("kind") not in _KINDS):
            return None
        if "turn" in value and (not isinstance(value["turn"], str) or not _SAFE_ID.fullmatch(value["turn"])):
            return None
        if value["kind"] == "heartbeat" and len(value) != 4:
            return None
        tool_event = value["kind"] in {"tool_started", "tool_finished"}
        if tool_event and (not isinstance(value.get("call"), str) or not _SAFE_ID.fullmatch(value["call"])):
            return None
        if not tool_event and ("call" in value or "action" in value):
            return None
        if value["kind"] == "tool_started" and value.get("action") not in {"command", "read", "edit", "search", "other"}:
            return None
        if value["kind"] == "tool_finished" and "action" in value:
            return None
        if value["kind"] == "plan":
            steps = value.get("steps")
            if not isinstance(steps, list) or len(steps) > 100:
                return None
            for step in steps:
                if (not isinstance(step, dict) or set(step) != {"title", "status"}
                        or not isinstance(step["title"], str) or not step["title"].strip()
                        or len(step["title"].encode("utf-16-le")) > 1024
                        or step["status"] not in {"pending", "active", "done"}):
                    return None
        elif "steps" in value:
            return None
        body = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return struct.pack("<I", len(body)) + body if 2 <= len(body) <= 65536 else None
    except (TypeError, ValueError, UnicodeError, KeyError):
        return None


def _endpoint(pipe_name):
    if os.name == "nt":
        name = pipe_name or user_pipe_name()
        return "\\\\.\\pipe\\" + name if isinstance(name, str) and _SAFE_PIPE.fullmatch(name) else None
    if os.uname().sysname != "Darwin" or pipe_name:
        return None
    uid = os.getuid()
    directory = "/private/tmp/aitm-provider-{}".format(uid)
    path = directory + "/events.sock"
    try:
        parent = os.lstat(directory)
        target = os.lstat(path)
        if (not stat.S_ISDIR(parent.st_mode) or parent.st_uid != uid or parent.st_mode & 0o077
                or not stat.S_ISSOCK(target.st_mode) or target.st_uid != uid):
            return None
        return path
    except OSError:
        return None


def publish(value, pipe_name=None, wait_seconds=0.2):
    """Send at most one sanitized event; an absent monitor is never an error."""
    payload = _encode(value)
    target = _endpoint(pipe_name)
    if payload is None or target is None or not 0 <= wait_seconds <= 1:
        return False
    if not _IN_FLIGHT_SENDS.acquire(blocking=False):
        return False
    completed = threading.Event()
    result = []

    def send():
        try:
            if os.name == "nt":
                with open(target, "r+b", buffering=0) as stream:
                    offset = 0
                    while offset < len(payload):
                        written = stream.write(payload[offset:])
                        if not written:
                            raise OSError("Incomplete local write")
                        offset += written
                    if stream.read(1) != b"\x06":
                        raise OSError("Local receiver did not acknowledge the frame")
            else:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stream:
                    stream.settimeout(0.15)
                    stream.connect(target)
                    stream.sendall(payload)
                    if stream.recv(1) != b"\x06":
                        raise OSError("Local receiver did not acknowledge the frame")
            result.append(True)
        except (OSError, ValueError):
            pass
        finally:
            _IN_FLIGHT_SENDS.release()
            completed.set()

    try:
        threading.Thread(target=send, daemon=True).start()
    except RuntimeError:
        _IN_FLIGHT_SENDS.release()
        return False
    completed.wait(wait_seconds)
    return bool(result)
