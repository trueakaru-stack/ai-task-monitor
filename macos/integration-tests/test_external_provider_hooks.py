import importlib.util
import inspect
import json
import os
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


def invoke(callback, **payload):
    # Match the upstream dispatcher's filtering for explicit hook signatures.
    accepted = inspect.signature(callback).parameters
    return callback(**{key: value for key, value in payload.items() if key in accepted})


class ProviderHookFixtures(unittest.TestCase):
    def setUp(self):
        # Each fixture uses an isolated selection and restores the test process.
        environment = patch.dict(os.environ, {"HERMES_MANAGED_DIR": "", "HERMES_CONFIG_BACKEND": ""})
        environment.start()
        self.addCleanup(environment.stop)

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
        with patch.object(observers, "OrderedSender", return_value=sender), \
             patch.object(observers, "profile_namespace", return_value="a" * 32), \
             patch.object(observers, "managed_scope_unconfirmed", return_value=False):
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

    def test_managed_scope_never_confirms_or_reads_managed_contents(self):
        class Context:
            def __init__(self): self.callbacks = {}; self.cleanup = None
            def register_hook(self, name, callback): self.callbacks[name] = callback
            def on_unload(self, callback): self.cleanup = callback

        class Sender:
            def __init__(self): self.events = []
            def enqueue(self, event): self.events.append(event); return True
            def close(self, wait_seconds=1.0): return True

        with tempfile.TemporaryDirectory(prefix="aitm-managed-fixture-") as temporary:
            managed = Path(temporary) / "managed"
            with patch.dict(os.environ, {"HERMES_MANAGED_DIR": ""}), patch.object(observers, "_DEFAULT_MANAGED_DIR", managed):
                self.assertFalse(observers.managed_scope_unconfirmed())
                managed.mkdir()
                # Directory existence alone is sufficient; content must not be opened.
                self.assertTrue(observers.managed_scope_unconfirmed())
                sender, context = Sender(), Context()
                with patch.object(observers, "OrderedSender", return_value=sender), \
                     patch.object(observers, "profile_namespace", return_value="a" * 32), \
                     patch.object(Path, "read_text", side_effect=AssertionError("Managed content was read")), \
                     patch.object(Path, "read_bytes", side_effect=AssertionError("Managed content was read")):
                    observers.register(context)
                    invoke(context.callbacks["pre_api_request"], session_id="s", turn_id="turn",
                           telemetry_schema_version="hermes.observer.v1", user_message="PRIVATE")
                    invoke(context.callbacks["on_human_input_request"], session_id="s", request_id="r",
                           telemetry_schema_version="hermes.observer.v1", prompt="PRIVATE")
                self.assertTrue(sender.events)
                self.assertTrue(all(event["kind"] == "gap" for event in sender.events))
                self.assertNotIn("PRIVATE", json.dumps(sender.events))
            with patch.dict(os.environ, {"HERMES_MANAGED_DIR": "nonexistent-private-path"}), \
                 patch.object(observers, "_DEFAULT_MANAGED_DIR", Path(temporary) / "missing"):
                self.assertTrue(observers.managed_scope_unconfirmed())
            with patch.dict(os.environ, {"HERMES_MANAGED_DIR": ""}), \
                 patch.object(Path, "stat", side_effect=PermissionError):
                self.assertTrue(observers.managed_scope_unconfirmed())

    def test_managed_directory_appearing_after_registration_is_checked_in_sender(self):
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "started",
                 "tick": time.monotonic_ns(), "epoch": 1}
        sent = []
        with tempfile.TemporaryDirectory(prefix="aitm-managed-late-") as temporary:
            managed = Path(temporary) / "managed"
            with patch.dict(os.environ, {"HERMES_MANAGED_DIR": "", "HERMES_CONFIG_BACKEND": "file"}), \
                 patch.object(observers, "_DEFAULT_MANAGED_DIR", managed), \
                 patch.object(observers, "publish", side_effect=lambda value, **_: (sent.append(value), True)[1]):
                self.assertTrue(observers.guarded_publish(event))
                managed.mkdir()
                self.assertTrue(observers.guarded_publish(event))
        self.assertEqual([item["kind"] for item in sent], ["started", "gap"])
        self.assertEqual(sent[1]["epoch"], event["epoch"])
        self.assertTrue(transport._encode(sent[1]))

    def test_managed_gap_requires_and_preserves_observer_epoch(self):
        sent = []
        with patch.object(observers, "managed_scope_unconfirmed", return_value=True), \
             patch.object(observers, "publish", side_effect=lambda value, **_: (sent.append(value), True)[1]):
            event = {"version": 1, "provider": "hermes", "session": "s", "kind": "active",
                     "tick": time.monotonic_ns(), "epoch": 1}
            self.assertTrue(observers.guarded_publish(event))
            self.assertEqual(sent[0]["epoch"], 1)
            self.assertTrue(transport._encode(sent[0]))
            self.assertFalse(observers.guarded_publish({"session": "s", "kind": "active"}))
            self.assertEqual(len(sent), 1)

    def test_blocked_managed_directory_check_never_blocks_hook_or_unload(self):
        entered, release = threading.Event(), threading.Event()
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "active"}

        def slow_check():
            entered.set()
            release.wait(3)
            return False

        with patch.object(observers, "managed_scope_unconfirmed", side_effect=slow_check), \
             patch.object(observers, "publish", return_value=True):
            sender = senders.OrderedSender(send=observers.guarded_publish)
            try:
                self.assertTrue(sender.enqueue(event))
                self.assertTrue(entered.wait(1))
                started = time.monotonic()
                self.assertTrue(sender.enqueue(event))
                sender.close(wait_seconds=0)
                self.assertLess(time.monotonic() - started, 0.2)
            finally:
                release.set()
                sender.close()

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
        self.assertEqual([item["kind"] for item in events], ["gap", "gap"])
        events.clear()
        event = {"session_id": "same:profile/session", "turn_id": "session:turn:1", "telemetry_schema_version": "hermes.observer.v1", "prompt": "PRIVATE"}
        invoke(first.callbacks["pre_api_request"], **event)
        invoke(second.callbacks["pre_api_request"], **event)
        invoke(first.callbacks["post_tool_call"], **event)
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

    def test_unidentified_human_request_invalidates_provider_without_payload(self):
        class Context:
            def __init__(self): self.callbacks = {}
            def register_hook(self, name, callback): self.callbacks[name] = callback
        context, events = Context(), []
        observers.register_observers(context, events.append, "a" * 32)
        for name in ("on_human_input_request", "on_human_input_resolved"):
            invoke(context.callbacks[name], session_id="", request_id="PRIVATE_ID",
                   prompt="PRIVATE_PROMPT", telemetry_schema_version="hermes.observer.v1")
        self.assertEqual([item["kind"] for item in events], ["gap", "gap"])
        self.assertTrue(all(item["session"] == "a" * 32 + "_unknown" for item in events))
        self.assertTrue(all(transport._encode(item) for item in events))
        self.assertNotIn("PRIVATE", json.dumps(events))
        events.clear()
        for request in (None, "", "x" * 513):
            invoke(context.callbacks["on_human_input_request"], session_id="s", request_id=request,
                   telemetry_schema_version="hermes.observer.v1")
        self.assertEqual([item["kind"] for item in events], ["gap", "gap", "gap"])

    def test_backend_and_managed_overrides_are_checked_on_every_event(self):
        class Context:
            def __init__(self): self.callbacks = {}
            def register_hook(self, name, callback): self.callbacks[name] = callback
        context, events = Context(), []
        with patch.dict(os.environ, {"HERMES_MANAGED_DIR": "", "HERMES_CONFIG_BACKEND": "file"}):
            observers.register_observers(context, events.append, "a" * 32)
            values = {"session_id": "s", "turn_id": "turn", "telemetry_schema_version": "hermes.observer.v1"}
            invoke(context.callbacks["pre_api_request"], **values)
            os.environ["HERMES_CONFIG_BACKEND"] = "PRIVATE_REMOTE_BACKEND"
            invoke(context.callbacks["pre_api_request"], **values)
            os.environ["HERMES_CONFIG_BACKEND"] = "FiLe"
            invoke(context.callbacks["pre_api_request"], **values)
            os.environ["HERMES_MANAGED_DIR"] = "PRIVATE_MANAGED_PATH"
            invoke(context.callbacks["pre_api_request"], **values)
        self.assertEqual([event["kind"] for event in events], ["started", "gap", "started", "gap"])
        self.assertNotIn("PRIVATE", json.dumps(events))

    def test_hermes_metadata_is_strict_and_not_accepted_for_other_providers(self):
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "waiting",
                 "tick": 100, "epoch": 99, "request": "hashed_request"}
        self.assertIsNotNone(transport._encode(event))
        for invalid in ({**event, "tick": True}, {**event, "tick": -1}, {**event, "epoch": 101},
                        {**event, "request": "../unsafe"}, {**event, "kind": "active"},
                        {**event, "provider": "kimi"}, {**event, "epoch": 1.5}):
            self.assertIsNone(transport._encode(invalid))
        self.assertIsNone(transport._encode({"version": 1, "provider": "hermes", "session": "s", "kind": "gap"}))
        self.assertIsNone(transport._encode({"version": 1, "provider": "hermes", "session": "s", "kind": "gap", "tick": 2}))
        self.assertIsNotNone(transport._encode({"version": 1, "provider": "kimi", "session": "s", "kind": "gap"}))

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
        events = []
        gap_delivered = threading.Event()
        delivered = threading.Event()
        attempts = []

        def send(event):
            attempts.append(event["kind"])
            if len(attempts) == 1:
                return False
            forwarded.append(event["kind"])
            events.append(event)
            if event["kind"] == "gap":
                gap_delivered.set()
            if event["kind"] == "plan":
                delivered.set()
            return True

        sender = senders.OrderedSender(send, retry_seconds=0.01)
        try:
            sender.enqueue({"version": 1, "provider": "hermes", "session": "s", "kind": "active", "tick": time.monotonic_ns(), "epoch": 1})
            sender.enqueue({"version": 1, "provider": "hermes", "session": "s", "kind": "plan", "steps": [], "tick": time.monotonic_ns(), "epoch": 1})
            self.assertTrue(gap_delivered.wait(2))
            self.assertEqual(forwarded, ["gap"])
            self.assertEqual(events[0]["epoch"], 1)
            self.assertIsNotNone(transport._encode(events[0]))
            deadline = time.monotonic() + 2
            while not sender.enqueue({"version": 1, "provider": "hermes", "session": "s", "kind": "plan", "steps": [], "tick": time.monotonic_ns(), "epoch": 1}):
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.assertTrue(delivered.wait(2))
            self.assertEqual(forwarded, ["gap", "plan"])
        finally:
            self.assertTrue(sender.close())

    def test_busy_queue_never_blocks_hook_and_reports_gap(self):
        sent = []
        gap = threading.Event()

        def send(event):
            sent.append(event)
            if event["kind"] == "gap":
                gap.set()
            return True

        sender = senders.OrderedSender(send, retry_seconds=0.01)
        completed = threading.Event()
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "active", "tick": time.monotonic_ns(), "epoch": 1}
        try:
            with sender._condition:
                worker = threading.Thread(target=lambda: (sender.enqueue(event), completed.set()))
                worker.start()
                self.assertTrue(completed.wait(0.5), "Hook waited for the sender lock")
                # Unloading must also return without acquiring that lock.
            worker.join(1)
            self.assertTrue(gap.wait(2))
            self.assertEqual(sent[0]["kind"], "gap")
            self.assertGreaterEqual(sent[0]["tick"], event["tick"])
            self.assertEqual(sent[0]["epoch"], event["epoch"])
            self.assertIsNotNone(transport._encode(sent[0]))
        finally:
            sender.close()

    def test_unload_never_waits_for_busy_queue(self):
        sender = senders.OrderedSender(lambda _: True)
        done = threading.Event()
        with sender._condition:
            worker = threading.Thread(target=lambda: (sender.close(wait_seconds=0), done.set()))
            worker.start()
            self.assertTrue(done.wait(0.5), "Unload waited for the sender lock")
        worker.join(1)
        self.assertTrue(sender.close())

    def test_slow_old_send_cannot_overtake_gap(self):
        entered, release, gap = threading.Event(), threading.Event(), threading.Event()
        delivered = []

        class Pipe:
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def write(self, data):
                value = json.loads(data[4:])
                kind = value["kind"]
                if kind == "started":
                    entered.set()
                    release.wait(3)
                delivered.append(value)
                if kind == "gap": gap.set()
                return len(data)
            def read(self, _): return b"\x06"

        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "started", "tick": time.monotonic_ns(), "epoch": 1}
        with patch.object(transport, "_endpoint", return_value="fixture"), patch.object(transport.os, "name", "nt"), \
             patch.object(transport, "open", create=True, side_effect=lambda *_args, **_kwargs: Pipe()):
            sender = senders.OrderedSender(retry_seconds=0.01)
            try:
                self.assertTrue(sender.enqueue(event))
                self.assertTrue(entered.wait(1))
                with sender._condition:
                    lost = threading.Thread(target=lambda: sender.enqueue({**event, "kind": "active"}))
                    lost.start()
                    lost.join(0.5)
                    self.assertFalse(lost.is_alive())
                self.assertFalse(gap.wait(0.3), "Gap overtook an unfinished send")
                release.set()
                self.assertTrue(gap.wait(2))
                self.assertEqual([item["kind"] for item in delivered[:2]], ["started", "gap"])
                self.assertEqual(delivered[1]["epoch"], event["epoch"])
            finally:
                release.set()
                sender.close()

    def test_overflow_and_unload_report_uncertainty_without_blocking(self):
        entered, release, gap = threading.Event(), threading.Event(), threading.Event()
        delivered = []

        def slow_send(event):
            if event["kind"] == "active":
                entered.set()
                release.wait(3)
            delivered.append(event)
            if event["kind"] == "gap": gap.set()
            return True

        sender = senders.OrderedSender(slow_send, retry_seconds=0.01)
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "active", "tick": time.monotonic_ns(), "epoch": 1}
        try:
            self.assertTrue(sender.enqueue(event))
            self.assertTrue(entered.wait(1))
            for _ in range(128):
                self.assertTrue(sender.enqueue({**event, "kind": "idle"}))
            self.assertFalse(sender.enqueue({**event, "kind": "idle"}))
            started = time.monotonic()
            sender.close(wait_seconds=0)
            self.assertLess(time.monotonic() - started, 0.2)
            release.set()
            self.assertTrue(gap.wait(2))
            self.assertEqual([item["kind"] for item in delivered], ["active", "gap"])
            self.assertEqual(delivered[1]["epoch"], event["epoch"])
            self.assertIsNotNone(transport._encode(delivered[1]))
        finally:
            release.set()
            sender.close()

    def test_overflow_reports_original_epoch_before_unload(self):
        entered, release, gap = threading.Event(), threading.Event(), threading.Event()
        delivered = []

        def slow_send(event):
            if event["kind"] == "active":
                entered.set()
                release.wait(3)
            delivered.append(event)
            if event["kind"] == "gap": gap.set()
            return True

        sender = senders.OrderedSender(slow_send, retry_seconds=0.01)
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "active", "tick": time.monotonic_ns(), "epoch": 1}
        try:
            self.assertTrue(sender.enqueue(event))
            self.assertTrue(entered.wait(1))
            for _ in range(128):
                self.assertTrue(sender.enqueue({**event, "kind": "idle"}))
            self.assertFalse(sender.enqueue({**event, "kind": "idle"}))
            release.set()
            self.assertTrue(gap.wait(2))
            self.assertEqual([item["kind"] for item in delivered[:2]], ["active", "gap"])
            self.assertEqual(delivered[1]["epoch"], event["epoch"])
            self.assertIsNotNone(transport._encode(delivered[1]))
        finally:
            release.set()
            sender.close()

    def test_unload_without_overflow_reports_original_epoch(self):
        active, gap = threading.Event(), threading.Event()
        delivered = []

        def send(event):
            delivered.append(event)
            if event["kind"] == "active": active.set()
            if event["kind"] == "gap": gap.set()
            return True

        sender = senders.OrderedSender(send, retry_seconds=0.01)
        event = {"version": 1, "provider": "hermes", "session": "s", "kind": "active", "tick": time.monotonic_ns(), "epoch": 1}
        try:
            self.assertTrue(sender.enqueue(event))
            self.assertTrue(active.wait(2))
            sender.close(wait_seconds=0)
            self.assertTrue(gap.wait(2))
            self.assertEqual([item["kind"] for item in delivered], ["active", "gap"])
            self.assertEqual(delivered[1]["epoch"], event["epoch"])
            self.assertIsNotNone(transport._encode(delivered[1]))
        finally:
            sender.close()

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
        callback = context.callbacks["post_tool_call"]
        self.assertNotIn("args", inspect.signature(callback).parameters)
        self.assertFalse(any(item.kind == inspect.Parameter.VAR_KEYWORD for item in inspect.signature(callback).parameters.values()))
        self.assertIsNone(invoke(callback, session_id="s1", tool_call_id="c1", tool_name="terminal", args=original_args))
        self.assertEqual(original_args, {"command": "SECRET"})
        self.assertEqual(events[0]["kind"], "active")
        self.assertNotIn("action", events[0])
        self.assertNotIn("SECRET", json.dumps(events))
        self.assertIsNone(invoke(context.callbacks["pre_api_request"], session_id="s1", turn_id="turn1", user_message="SECRET"))
        self.assertEqual(events[1]["kind"], "started")
        failing_context = Context()
        observers.register_observers(failing_context, lambda _: (_ for _ in ()).throw(RuntimeError("failure")))
        self.assertIsNone(invoke(failing_context.callbacks["pre_api_request"], session_id="s1", user_message="SECRET"))

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
                           ("on_human_input_resolved", "unknown"), ("on_session_finalize", "unknown")):
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
        invoke(context.callbacks["pre_api_request"], session_id="first", turn_id="turn_1", user_message="PRIVATE")
        invoke(context.callbacks["pre_api_request"], session_id="second", turn_id="turn_2", request_messages=["PRIVATE"])
        invoke(context.callbacks["on_human_input_request"], session_id="second", request_id="private-id", prompt="PRIVATE")
        invoke(context.callbacks["on_human_input_resolved"], session_id="second", request_id="private-id", outcome="PRIVATE")
        invoke(context.callbacks["post_llm_call"], session_id="first", assistant_response="PRIVATE")
        invoke(context.callbacks["on_session_end"], session_id="first", turn_id="turn_1", completed=True)
        self.assertEqual([(item["session"], item["kind"]) for item in events], [
            ("first", "started"), ("second", "started"), ("second", "waiting"),
            ("second", "unknown"), ("first", "unknown"), ("first", "idle")])
        self.assertNotIn("PRIVATE", json.dumps(events))
        self.assertNotIn("private-id", json.dumps(events))
        self.assertEqual(events[2]["request"], events[3]["request"])
        self.assertTrue(all(type(item["tick"]) is int for item in events))


if __name__ == "__main__":
    unittest.main()
