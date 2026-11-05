"""Bounded, ordered, background delivery for in-process Python observers."""

from collections import deque
import threading

from .provider_transport import publish


class OrderedSender:
    def __init__(self, send=publish, retry_seconds=1.0):
        self._send = send
        self._retry_seconds = retry_seconds
        self._queue = deque()
        self._gap = None
        self._condition = threading.Condition()
        self._closed = False
        self._worker = threading.Thread(target=self._run, daemon=True, name="AI Task Monitor observer")
        self._worker.start()

    def enqueue(self, event):
        if event is None:
            return False
        with self._condition:
            if self._closed:
                return False
            if self._gap is not None:
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

    def close(self, wait_seconds=1.0):
        with self._condition:
            self._closed = True
            self._condition.notify()
        if wait_seconds > 0:
            self._worker.join(timeout=wait_seconds)
        return not self._worker.is_alive()

    def _run(self):
        while True:
            with self._condition:
                while not self._closed and not self._gap and not self._queue:
                    self._condition.wait()
                if self._closed:
                    return
                reporting_gap = self._gap is not None
                origin = self._gap if reporting_gap else self._queue.popleft()
            event = ({"version": 1, "provider": origin["provider"], "session": origin["session"], "kind": "gap"}
                     if reporting_gap else origin)
            try:
                sent = self._send(event) is True
            except Exception:
                sent = False
            with self._condition:
                if self._closed:
                    return
                if sent and reporting_gap and self._gap is origin:
                    self._gap = None
                elif not sent:
                    self._gap = origin
                    self._queue.clear()
                    self._condition.wait(timeout=self._retry_seconds)
