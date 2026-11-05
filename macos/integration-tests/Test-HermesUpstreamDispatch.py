"""Exercise the observer through the pinned Hermes dispatcher without starting an agent.

Pass a fixture directory containing the unmodified upstream middleware and
plugins_dispatch modules from Hermes v0.22.7; no real profile is accessed.
"""

import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
import sys
import threading
import types


if len(sys.argv) != 2:
    raise SystemExit("Pass the isolated Hermes upstream source directory.")
upstream = Path(sys.argv[1]).resolve(strict=True)
expected = {
    "hermes_cli/middleware.py": "d563bca8757d3e9e2766db905d457fdc96de427d873b40d48e3a624f78d7c589",
    "hermes_cli/plugins_dispatch.py": "aa12d2c3b48f0af1cfcb837a0b67459c59172b0d40825b7f9b6c09076e141742",
}
for name, digest in expected.items():
    if hashlib.sha256((upstream / name).read_bytes()).hexdigest() != digest:
        raise SystemExit("Unrecognized Hermes upstream fixture.")

sys.path.insert(0, str(upstream))
fake_agent = types.ModuleType("agent")
fake_agent.__path__ = []
fake_policy = types.ModuleType("agent.safe_worker_policy")
fake_policy.safe_worker_enabled = lambda: False
sys.modules.update({"agent": fake_agent, "agent.safe_worker_policy": fake_policy})
fake_plugins = types.ModuleType("hermes_cli.plugins")
fake_plugins._resolve_hook_callback_timeout = lambda: 2.0
sys.modules["hermes_cli.plugins"] = fake_plugins
dispatch = importlib.import_module("hermes_cli.plugins_dispatch")

assets = Path(__file__).resolve().parent.parent / "integrations"
fixture_package = types.ModuleType("aitm_hermes_fixture")
fixture_package.__path__ = [str(assets)]
sys.modules[fixture_package.__name__] = fixture_package
observer = importlib.import_module("aitm_hermes_fixture.hermes_observer")


class Dispatcher(dispatch.PluginDispatchMixin):
    def __init__(self):
        self._hooks = {}
        self._hook_timeout_lock = threading.Lock()
        self._hook_timeout_suppressed_until = {}
        self._hook_running_callbacks = {}
        self._hook_abandoned = {}
        self._hook_timeout_suppression_seconds = 60
        self._hook_failures_reported = set()

    def register_hook(self, name, callback):
        self._hooks.setdefault(name, []).append(callback)


events = []
first, second = Dispatcher(), Dispatcher()
observer.register_observers(first, events.append, "a" * 32)
observer.register_observers(second, events.append, "b" * 32)
assert set(first._hooks) == set(observer._EVENTS)
assert not {"pre_tool_call", "pre_llm_call"} & set(first._hooks)
payload = {"session_id": "same:session", "turn_id": "turn:1", "user_message": "PRIVATE_PROMPT"}
assert first.invoke_hook("pre_api_request", **payload) == []
assert second.invoke_hook("pre_api_request", **payload) == []
assert first.invoke_hook("post_tool_call", **payload, args={"command": "PRIVATE_COMMAND"}) == []
assert first.invoke_hook("on_human_input_request", **payload, prompt="PRIVATE_PROMPT") == []
assert first.invoke_hook("on_session_end", **payload, completed=True, failed=False, interrupted=False) == []
assert [item["kind"] for item in events] == ["started", "started", "active", "waiting", "idle"]
assert events[0]["session"] == events[2]["session"] != events[1]["session"]
assert events[0]["turn"] == events[1]["turn"]
assert "PRIVATE" not in json.dumps(events) and "same:session" not in json.dumps(events)
print("Hermes v0.22.7 dispatcher: scoped synthetic observer events and privacy passed.")
