"""Hermes observation-only callbacks; no directive or control hooks are registered."""

from .provider_hooks import from_hermes
from .provider_sender import OrderedSender
from .provider_transport import publish
from contextvars import ContextVar
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time

_EVENTS = (
    "pre_api_request", "post_llm_call", "post_tool_call",
    "on_session_start", "on_session_end", "on_session_finalize",
    "on_human_input_request", "on_human_input_resolved",
)
_DEFAULT_MANAGED_DIR = Path("/etc/hermes")


def environment_unconfirmed():
    """Check only selection variables; never emit their values."""
    try:
        return (bool(os.environ.get("HERMES_MANAGED_DIR", "").strip()) or
                os.environ.get("HERMES_CONFIG_BACKEND", "").strip().lower() not in ("", "file"))
    except (OSError, ValueError, TypeError):
        return True


def managed_scope_unconfirmed():
    """Detect a possible Hermes managed overlay without opening its contents."""
    try:
        if environment_unconfirmed():
            return True
        try:
            return stat.S_ISDIR(_DEFAULT_MANAGED_DIR.stat().st_mode)
        except FileNotFoundError:
            return False
    except (OSError, ValueError, TypeError):
        return True


def guarded_publish(event):
    """Recheck managed scope on the daemon, never on the agent's hook thread."""
    try:
        if managed_scope_unconfirmed():
            event = {"version": 1, "provider": "hermes", "session": event["session"],
                     "kind": "gap", "tick": time.monotonic_ns(), "epoch": event["epoch"]}
        return publish(event, wait_seconds=None)
    except Exception:
        return False


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


def register_observers(ctx, enqueue, namespace=None, unconfirmed=False):
    epoch = time.monotonic_ns()
    if unconfirmed and namespace is not None:
        enqueue({"version": 1, "provider": "hermes", "session": namespace + "_unknown",
                 "kind": "gap", "tick": epoch, "epoch": epoch})
    def handler(name):
        # Hermes filters hook payloads by signature. Do not receive prompts,
        # messages, responses, tool arguments, or other unrelated fields.
        def observe(*, telemetry_schema_version=None, session_id=None, turn_id=None,
                    request_id=None, completed=None, failed=None, interrupted=None):
            try:
                observed = time.monotonic_ns()
                def unknown_scope():
                    enqueue({"version": 1, "provider": "hermes", "session": namespace + "_unknown",
                             "kind": "gap", "tick": observed, "epoch": epoch})
                if namespace is not None and (unconfirmed or environment_unconfirmed()):
                    unknown_scope()
                    return None
                if namespace is not None and telemetry_schema_version != "hermes.observer.v1":
                    unknown_scope()
                    return None
                if not turn_id and name in ("on_human_input_request", "on_human_input_resolved"):
                    # Hermes v0.22.7 keeps this correlation ID in its current
                    # task context but omits it from human-input payloads.
                    module = sys.modules.get("tools.approval_context")
                    variable = getattr(module, "_approval_turn_id", None)
                    if isinstance(variable, ContextVar):
                        turn_id = variable.get()
                extra = {"turn_id": turn_id, "completed": completed,
                         "failed": failed, "interrupted": interrupted}
                session = session_id
                if namespace is not None:
                    session = scoped_session(namespace, session)
                    extra["turn_id"] = scoped_turn(extra["turn_id"])
                    if session is None:
                        # An unidentifiable event may belong to any monitored task.
                        unknown_scope()
                        return None
                event = from_hermes({"hook_event_name": name, "session_id": session,
                                     "extra": extra})
                if event is not None:
                    event["tick"] = observed
                    event["epoch"] = epoch
                    if name in ("on_human_input_request", "on_human_input_resolved"):
                        request = scoped_turn(request_id)
                        if request is None:
                            # Uncorrelated prompts cannot support a confirmed state.
                            if namespace is not None:
                                unknown_scope()
                                return None
                            event["kind"] = "unknown"
                        else:
                            event["request"] = request
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
        unconfirmed = managed_scope_unconfirmed()
        sender = OrderedSender(send=guarded_publish)
        ctx.on_unload(lambda: sender.close(wait_seconds=0))
        register_observers(ctx, sender.enqueue, namespace, unconfirmed=unconfirmed)
    except Exception:
        if sender is not None:
            sender.close(wait_seconds=0)
        # An unavailable monitor must not prevent Hermes from starting.
        pass
