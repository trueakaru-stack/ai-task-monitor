"""Bounded, ordered background delivery for in-process Python observers."""

from collections import deque
import threading
import time

from .provider_transport import publish


def _ordered_publish(event):
    # Only the daemon sender waits. Do not start a newer delivery while an old
    # transport thread could still write its frame after a reported gap.
    return publish(event, wait_seconds=None)


class OrderedSender:
    def __init__(self, send=None, retry_seconds=1.0):
        self._send = send or _ordered_publish
        self._retry_seconds = retry_seconds
        self._queue = deque()
        self._missed = deque(maxlen=1)
        self._gap = None
        self._last_origin = None
        self._condition = threading.Condition()
        self._closed = False
        self._worker = threading.Thread(target=self._run, daemon=True, name="AI Task Monitor observer")
        self._worker.start()

    def enqueue(self, event):
        if event is None or self._closed:
            return False
        # A hook must not wait for the background worker, including on
        # upstream's unbounded human-input and finalization callbacks.
        if not self._condition.acquire(blocking=False):
            self._missed.append(event)
            return False
        try:
            if self._closed:
                return False
            self._last_origin = event
            if self._gap is not None or self._missed:
                self._missed.append(event)
                return False
            if len(self._queue) >= 128:
                self._queue.clear()
                self._gap = event
                accepted = False
            else:
                self._queue.append(event)
                accepted = True
            self._condition.notify()
            return accepted
        finally:
            self._condition.release()

    def close(self, wait_seconds=1.0):
        # The unload callback uses zero: it must not wait even if another
        # thread currently owns the queue lock. The worker polls for closure.
        self._closed = True
        if self._condition.acquire(blocking=False):
            try:
                self._condition.notify()
            finally:
                self._condition.release()
        if wait_seconds > 0 and threading.current_thread() is not self._worker:
            self._worker.join(timeout=wait_seconds)
        return not self._worker.is_alive()

    @staticmethod
    def _gap_event(origin):
        event = {"version": 1, "provider": origin["provider"], "session": origin["session"], "kind": "gap"}
        if event["provider"] == "hermes":
            event["tick"] = time.monotonic_ns()
            event["epoch"] = origin.get("epoch")
        return event

    def _run(self):
        while True:
            with self._condition:
                # deque append/pop are thread-safe; a producer that could not
                # obtain the condition never waits and records a lost event.
                if self._missed:
                    self._gap = self._missed.pop()
                    self._queue.clear()
                if self._closed:
                    origin = self._gap or self._last_origin
                    self._queue.clear()
                    closing = True
                    reporting_gap = True
                elif self._gap is not None:
                    origin = self._gap
                    closing = False
                    reporting_gap = True
                elif self._queue:
                    origin = self._queue.popleft()
                    closing = False
                    reporting_gap = False
                else:
                    self._condition.wait(timeout=0.05)
                    continue
            if origin is None:
                return
            event = self._gap_event(origin) if reporting_gap else origin
            try:
                sent = self._send(event) is True
            except Exception:
                sent = False
            if closing:
                return
            with self._condition:
                if sent and reporting_gap and self._gap is origin:
                    self._gap = None
                elif not sent:
                    self._gap = origin
                    self._queue.clear()
                    self._condition.wait(timeout=self._retry_seconds)
