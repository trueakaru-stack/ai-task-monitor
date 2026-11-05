"""Observer-side allowlist for Kimi Code and Hermes Agent events.

Only return explicit state and identifiers. Never include prompts, commands,
tool results, working directories, environment variables or account data.
"""

import re

_SAFE_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z", re.ASCII)


def _event(provider, data, kind, turn=None):
    session = data.get("session_id")
    if not isinstance(session, str) or not _SAFE_ID.fullmatch(session):
        return None
    result = {"version": 1, "provider": provider, "session": session, "kind": kind}
    if isinstance(turn, str) and _SAFE_ID.fullmatch(turn):
        result["turn"] = turn
    return result


def from_kimi(data):
    """Convert documented Kimi hook payloads without inferring a plan."""
    try:
        if not isinstance(data, dict):
            return None
        name = data.get("hook_event_name")
        if name == "TurnStarted":
            return _event("kimi", data, "started", data.get("turn_id"))
        mapping = {
            "SessionStart": "unknown", "SessionEnd": "idle",
            "PostToolUse": "active", "PostToolUseFailure": "active",
            "PermissionRequest": "waiting", "PermissionResult": "unknown",
            "Stop": "unknown", "StopFailure": "failed", "Interrupt": "interrupted",
        }
        return _event("kimi", data, mapping[name]) if name in mapping else None
    except (TypeError, ValueError, AttributeError):
        return None


def from_hermes(data):
    """Convert observation-only Hermes payloads; missing outcomes stay unknown."""
    try:
        if not isinstance(data, dict):
            return None
        name = data.get("hook_event_name")
        extra = data.get("extra") if isinstance(data.get("extra"), dict) else {}
        if name == "post_tool_call":
            # We deliberately do not subscribe to the blocking pre-tool hook.
            # A completed tool is evidence of activity, not a matched open call.
            return _event("hermes", data, "active")
        if name == "pre_api_request":
            turn = extra.get("turn_id")
            # Without a reliable turn ID, an API retry must not look like a new task.
            if isinstance(turn, str) and _SAFE_ID.fullmatch(turn):
                return _event("hermes", data, "started", turn)
            return _event("hermes", data, "active")
        if name == "on_session_end":
            if extra.get("interrupted") is True:
                kind = "interrupted"
            elif extra.get("failed") is True:
                kind = "failed"
            elif extra.get("completed") is True:
                # This is a run/turn boundary, not proof that the user's whole task is complete.
                kind = "idle"
            else:
                kind = "unknown"
            return _event("hermes", data, kind, extra.get("turn_id"))
        mapping = {
            "on_session_start": "unknown", "post_llm_call": "unknown",
            "on_human_input_request": "waiting",
            "on_human_input_resolved": "unknown", "on_session_finalize": "idle",
        }
        return _event("hermes", data, mapping[name], extra.get("turn_id")) if name in mapping else None
    except (TypeError, ValueError, AttributeError):
        return None
