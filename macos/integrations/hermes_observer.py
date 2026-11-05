"""Hermes observation-only callbacks; no directive or control hooks are registered."""

from .provider_hooks import from_hermes
from .provider_sender import OrderedSender
import hashlib
import json
import os
from pathlib import Path
import re
import stat

_EVENTS = (
    "pre_api_request", "post_llm_call", "post_tool_call",
    "on_session_start", "on_session_end", "on_session_finalize",
    "on_human_input_request", "on_human_input_resolved",
)


def scoped_session(namespace, session):
    """Separate identical session IDs in different profiles without sending paths."""
    if (not isinstance(namespace, str) or not re.fullmatch(r"[a-f0-9]{32}", namespace)
            or not isinstance(session, str) or not session or len(session) > 512
            or any(ord(character) < 32 or ord(character) == 127 for character in session)):
        return None
    try:
        encoded = session.encode("utf-8")
        return namespace + "_" + hashlib.sha256(encoded).hexdigest() if len(encoded) <= 1024 else None
    except UnicodeError:
        return None


def scoped_turn(turn):
    """Turn IDs are opaque upstream and may contain colons or other punctuation."""
    if (not isinstance(turn, str) or not turn or len(turn) > 512
            or any(ord(character) < 32 or ord(character) == 127 for character in turn)):
        return None
    try:
        encoded = turn.encode("utf-8")
        return "t_" + hashlib.sha256(encoded).hexdigest() if len(encoded) <= 1024 else None
    except UnicodeError:
        return None


def profile_namespace(path=None):
    """Read only the monitor-owned, non-secret identifier for this profile."""
    metadata = Path(path) if path is not None else Path(__file__).with_name("monitor-profile.json")
    descriptor = None
    try:
        original = metadata.lstat()
        if (not stat.S_ISREG(original.st_mode)
                or getattr(original, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
                or original.st_size > 256):
            return None
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(metadata, flags)
        current = os.fstat(descriptor)
        if (not stat.S_ISREG(current.st_mode) or current.st_dev != original.st_dev
                or current.st_ino != original.st_ino or current.st_size > 256):
            return None
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            data = stream.read(257)
        if len(data) > 256:
            return None
        value = json.loads(data)
        if (not isinstance(value, dict) or set(value) != {"namespace"}
                or not isinstance(value["namespace"], str)
                or not re.fullmatch(r"[a-f0-9]{32}", value["namespace"])):
            return None
        return value["namespace"]
    except (OSError, ValueError, TypeError):
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)


def register_observers(ctx, enqueue, namespace=None):
    def handler(name):
        def observe(**values):
            try:
                if namespace is not None and values.get("telemetry_schema_version") != "hermes.observer.v1":
                    return None
                # Build an explicit view; never pass arguments, response or prompt on.
                extra = {key: values.get(key) for key in
                         ("turn_id", "tool_call_id", "completed", "failed", "interrupted")}
                session = values.get("session_id")
                if namespace is not None:
                    session = scoped_session(namespace, session)
                    extra["turn_id"] = scoped_turn(extra["turn_id"])
                    if session is None:
                        return None
                event = from_hermes({"hook_event_name": name, "session_id": session,
                                     "tool_name": values.get("tool_name"), "extra": extra})
                if event is not None:
                    enqueue(event)
            except Exception:
                pass
            # Observer results are ignored by Hermes; never return user data.
            return None
        return observe

    registered = []
    for name in _EVENTS:
        try:
            ctx.register_hook(name, handler(name))
            registered.append(name)
        except Exception:
            # Older agent versions can lack an event; never interfere with startup.
            pass
    return tuple(registered)


def register(ctx):
    sender = None
    try:
        if not callable(getattr(ctx, "on_unload", None)):
            return
        namespace = profile_namespace()
        if namespace is None:
            return
        sender = OrderedSender()
        ctx.on_unload(lambda: sender.close(wait_seconds=0))
        register_observers(ctx, sender.enqueue, namespace)
    except Exception:
        if sender is not None:
            sender.close(wait_seconds=0)
        # An unavailable monitor must not prevent Hermes from starting.
        pass
