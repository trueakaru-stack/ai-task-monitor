import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import types
import unittest
from unittest.mock import patch

module_path = Path(__file__).parent.parent / "integrations" / "provider_hooks.py"
spec = importlib.util.spec_from_file_location("provider_hooks", module_path)
hooks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hooks)
package = types.ModuleType("provider_fixture")
package.__path__ = [str(module_path.parent)]
sys.modules["provider_fixture"] = package
observer_spec = importlib.util.spec_from_file_location("provider_fixture.hermes_observer", module_path.parent / "hermes_observer.py")
observers = importlib.util.module_from_spec(observer_spec)
observer_spec.loader.exec_module(observers)
sender_spec = importlib.util.spec_from_file_location("provider_fixture.provider_sender", module_path.parent / "provider_sender.py")
senders = importlib.util.module_from_spec(sender_spec)
sender_spec.loader.exec_module(senders)
transport = sys.modules["provider_fixture.provider_transport"]


class ProviderHookFixtures(unittest.TestCase):
    def test_hermes_unload_closes_sender_without_waiting(self):
        class Context:
            def __init__(self):
                self.callbacks = {}
                self.cleanup = None

            def register_hook(self, name, callback):
                self.callbacks[name] = callback

            def on_unload(self, callback):
                self.cleanup = callback

        class Sender:
            def __init__(self):
                self.closed_with = None

            def enqueue(self, _event):
                pass

            def close(self, wait_seconds=1.0):
                self.closed_with = wait_seconds

        sender = Sender()
        context = Context()
        with patch.object(observers, "OrderedSender", return_value=sender), patch.object(observers, "profile_namespace", return_value="a" * 32):
            observers.register(context)
        self.assertTrue(context.callbacks)
        self.assertIsNotNone(context.cleanup)
        context.cleanup()
        self.assertEqual(sender.closed_with, 0)
        with patch.object(observers, "OrderedSender") as factory:
            observers.register(object())
            factory.assert_not_called()
        with patch.object(observers, "profile_namespace", return_value=None), patch.object(observers, "OrderedSender") as factory:
            observers.register(Context())
            factory.assert_not_called()

    def test_hermes_profile_namespace_is_bounded_and_rejects_links(self):
        with tempfile.TemporaryDirectory(prefix="aitm-hermes-scope-") as directory:
            path = Path(directory) / "monitor-profile.json"
            path.write_text(json.dumps({"namespace": "a" * 32}), encoding="utf-8")
            self.assertEqual(observers.profile_namespace(path), "a" * 32)
            path.write_text(json.dumps({"namespace": "a" * 32, "extra": "secret"}), encoding="utf-8")
            self.assertIsNone(observers.profile_namespace(path))
            path.write_text("x" * 257, encoding="utf-8")
            self.assertIsNone(observers.profile_namespace(path))
            link = Path(directory) / "link.json"
            try:
                link.symlink_to(path)
            except OSError:
                pass  # Windows may not permit creating links for this user.
            else:
                self.assertIsNone(observers.profile_namespace(link))

    def test_hermes_profiles_isolate_equal_sessions_and_require_documented_schema(self):
        class Context:
            def __init__(self):
                self.callbacks = {}

            def register_hook(self, name, callback):
                self.callbacks[name] = callback

        first, second = Context(), Context()
        events = []
        observers.register_observers(first, events.append, "a" * 32)
        observers.register_observers(second, events.append, "b" * 32)
        first.callbacks["pre_api_request"](session_id="same", turn_id="t1")
        first.callbacks["pre_api_request"](session_id="same", turn_id="t1", telemetry_schema_version="future")
        self.assertEqual(events, [])
        event = {"session_id": "same:profile/session", "turn_id": "session:turn:1", "telemetry_schema_version": "hermes.observer.v1", "prompt": "PRIVATE"}
        first.callbacks["pre_api_request"](**event)
        second.callbacks["pre_api_request"](**event)
        first.callbacks["post_tool_call"](**event)
        self.assertEqual(len(events), 3)
        self.assertEqual(events[0]["session"], events[2]["session"])
        self.assertNotEqual(events[0]["session"], events[1]["session"])
        self.assertNotIn("same", json.dumps(events))
        self.assertNotIn("PRIVATE", json.dumps(events))
        self.assertEqual(events[0]["turn"], events[1]["turn"])
        self.assertNotIn("session:turn:1", json.dumps(events))
        self.assertTrue(all(len(item["session"]) <= 128 for item in events))
        self.assertIsNone(observers.scoped_session("not-a-namespace", "same"))
        self.assertIsNone(observers.scoped_session("a" * 32, "bad\nidentifier"))

    def test_transport_requires_ack_and_bounds_blocked_workers(self):
        class FakeStream:
            def __init__(self, reply, release=None):
                self.reply = reply
                self.release = release

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def write(self, data):
                return len(data)

            def read(self, _):
                if self.release is not None:
                    self.release.wait(2)
                return self.reply

        event = {"version": 1, "provider": "hermes", "session": "s1", "kind": "active"}
        with patch.object(transport, "_endpoint", return_value="fixture"), patch.object(transport.os, "name", "nt"):
            with patch.object(transport, "open", create=True, side_effect=lambda *_args, **_kwargs: FakeStream(b"\x06")):
                self.assertTrue(transport.publish(event, wait_seconds=0.5))
            with patch.object(transport, "open", create=True, side_effect=lambda *_args, **_kwargs: FakeStream(b"\x15")):
                self.assertFalse(transport.publish(event, wait_seconds=0.5))
            release = threading.Event()
            try:
                with patch.object(transport, "open", create=True, side_effect=lambda *_args, **_kwargs: FakeStream(b"", release)):
                    for _ in range(4):
                        self.assertFalse(transport.publish(event, wait_seconds=0.01))
                    started = time.monotonic()
                    self.assertFalse(transport.publish(event, wait_seconds=0.5))
                    self.assertLess(time.monotonic() - started, 0.2)
            finally:
                release.set()
            deadline = time.monotonic() + 2
            held = 0
            try:
                while held < 4 and time.monotonic() < deadline:
                    if transport._IN_FLIGHT_SENDS.acquire(blocking=False):
                        held += 1
                    else:
                        time.sleep(0.01)
                self.assertEqual(held, 4, "Timed-out daemon workers must eventually release their slots")
            finally:
                for _ in range(held):
                    transport._IN_FLIGHT_SENDS.release()

    def test_ordered_delivery_reports_gap_after_a_failed_send(self):
        forwarded = []
        gap_delivered = threading.Event()
        delivered = threading.Event()
        attempts = []

        def send(event):
            attempts.append(event["kind"])
            if len(attempts) == 1:
                return False
            forwarded.append(event["kind"])
            if event["kind"] == "gap":
                gap_delivered.set()
            if event["kind"] == "plan":
                delivered.set()
            return True

        sender = senders.OrderedSender(send, retry_seconds=0.01)
        try:
            sender.enqueue({"version": 1, "provider": "hermes", "session": "s", "kind": "active"})
            sender.enqueue({"version": 1, "provider": "hermes", "session": "s", "kind": "plan", "steps": []})
            self.assertTrue(gap_delivered.wait(2))
            self.assertEqual(forwarded, ["gap"])
            deadline = time.monotonic() + 2
            while not sender.enqueue({"version": 1, "provider": "hermes", "session": "s", "kind": "plan", "steps": []}):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.assertTrue(delivered.wait(2))
            self.assertEqual(forwarded, ["gap", "plan"])
        finally:
            self.assertTrue(sender.close())

    def test_hermes_registers_only_passive_hooks_and_never_mutates_input(self):
        class Context:
            def __init__(self):
                self.callbacks = {}

            def register_hook(self, name, callback):
                self.callbacks[name] = callback

        context = Context()
        events = []
        observers.register_observers(context, events.append)
        self.assertEqual(set(context.callbacks), {"pre_api_request", "post_llm_call", "post_tool_call",
            "on_session_start", "on_session_end", "on_session_finalize",
            "on_human_input_request", "on_human_input_resolved"})
        self.assertNotIn("pre_tool_call", context.callbacks)
        self.assertNotIn("pre_llm_call", context.callbacks)
        original_args = {"command": "SECRET"}
        self.assertIsNone(context.callbacks["post_tool_call"](session_id="s1", tool_call_id="c1", tool_name="terminal", args=original_args))
        self.assertEqual(original_args, {"command": "SECRET"})
        self.assertEqual(events[0]["kind"], "active")
        self.assertNotIn("action", events[0])
        self.assertNotIn("SECRET", json.dumps(events))
        self.assertIsNone(context.callbacks["pre_api_request"](session_id="s1", turn_id="turn1", user_message="SECRET"))
        self.assertEqual(events[1]["kind"], "started")
        failing_context = Context()
        observers.register_observers(failing_context, lambda _: (_ for _ in ()).throw(RuntimeError("failure")))
        self.assertIsNone(failing_context.callbacks["pre_api_request"](session_id="s1", user_message="SECRET"))

    def test_kimi_states_and_privacy(self):
        secret = "SENSITIVE_PROMPT_COMMAND_OUTPUT_PATH"
        base = {"session_id": "session_abc", "turn_id": "turn_1", "prompt": secret,
                "tool_input": {"command": secret}, "tool_output": secret, "cwd": secret}
        for name, kind in (("TurnStarted", "started"), ("SessionStart", "unknown"),
                           ("SessionEnd", "idle"), ("PostToolUse", "active"),
                           ("PostToolUseFailure", "active"), ("PermissionRequest", "waiting"),
                           ("PermissionResult", "unknown"), ("Stop", "unknown"),
                           ("StopFailure", "failed"), ("Interrupt", "interrupted")):
            with self.subTest(name=name):
                result = hooks.from_kimi({**base, "hook_event_name": name})
                self.assertEqual(result["kind"], kind)
                self.assertNotIn(secret, json.dumps(result))
        self.assertIsNone(hooks.from_kimi({**base, "session_id": "../private", "hook_event_name": "TurnStarted"}))
        self.assertIsNone(hooks.from_kimi({**base, "hook_event_name": "UnknownEvent"}))
        self.assertIsNone(hooks.from_kimi({**base, "hook_event_name": []}))
        self.assertIsNone(hooks.from_kimi(None))

    def test_hermes_outcomes_and_privacy(self):
        secret = "SENSITIVE_PROMPT_COMMAND_OUTPUT_PATH"
        base = {"session_id": "sess_123", "tool_input": {"command": secret},
                "tool_output": secret, "cwd": secret}
        for extra, kind in (({"completed": True}, "idle"), ({"failed": True}, "failed"),
                            ({"interrupted": True}, "interrupted"), ({"completed": False}, "unknown"),
                            ({"completed": True, "interrupted": True}, "interrupted")):
            with self.subTest(extra=extra):
                result = hooks.from_hermes({**base, "hook_event_name": "on_session_end", "extra": extra})
                self.assertEqual(result["kind"], kind)
                self.assertNotIn(secret, json.dumps(result))
        for name, kind in (("on_session_start", "unknown"), ("post_llm_call", "unknown"),
                           ("on_human_input_request", "waiting"),
                           ("on_human_input_resolved", "unknown"), ("on_session_finalize", "idle")):
            self.assertEqual(hooks.from_hermes({**base, "hook_event_name": name})["kind"], kind)
        end = hooks.from_hermes({**base, "hook_event_name": "post_tool_call", "extra": {"tool_call_id": "call_1"}})
        begin = hooks.from_hermes({**base, "hook_event_name": "pre_api_request", "extra": {"turn_id": "turn_1"}})
        self.assertEqual(begin["kind"], "started")
        self.assertEqual(begin["turn"], "turn_1")
        self.assertEqual(hooks.from_hermes({**base, "hook_event_name": "pre_api_request"})["kind"], "active")
        self.assertEqual(end["kind"], "active")
        self.assertNotIn(secret, json.dumps([begin, end]))
        self.assertNotIn("call", hooks.from_hermes({**base, "hook_event_name": "post_tool_call", "extra": {"tool_call_id": "../bad"}}))
        self.assertIsNone(hooks.from_hermes({**base, "hook_event_name": "pre_tool_call", "extra": {"tool_call_id": "call_1"}}))
        self.assertIsNone(hooks.from_hermes({**base, "hook_event_name": "pre_llm_call"}))
        self.assertIsNone(hooks.from_hermes({**base, "session_id": "x" * 129, "hook_event_name": "on_session_start"}))
        self.assertIsNone(hooks.from_hermes({**base, "hook_event_name": {}}))
        self.assertIsNone(hooks.from_hermes([]))

    def test_hermes_passive_lifecycle_keeps_sessions_separate(self):
        class Context:
            def __init__(self):
                self.callbacks = {}

            def register_hook(self, name, callback):
                self.callbacks[name] = callback

        context = Context()
        events = []
        observers.register_observers(context, events.append)
        context.callbacks["pre_api_request"](session_id="first", turn_id="turn_1", user_message="PRIVATE")
        context.callbacks["pre_api_request"](session_id="second", turn_id="turn_2", request_messages=["PRIVATE"])
        context.callbacks["on_human_input_request"](session_id="second", prompt="PRIVATE")
        context.callbacks["on_human_input_resolved"](session_id="second", outcome="PRIVATE")
        context.callbacks["post_llm_call"](session_id="first", assistant_response="PRIVATE")
        context.callbacks["on_session_end"](session_id="first", turn_id="turn_1", completed=True)
        self.assertEqual([(item["session"], item["kind"]) for item in events], [
            ("first", "started"), ("second", "started"), ("second", "waiting"),
            ("second", "unknown"), ("first", "unknown"), ("first", "idle")])
        self.assertNotIn("PRIVATE", json.dumps(events))


if __name__ == "__main__":
    unittest.main()
