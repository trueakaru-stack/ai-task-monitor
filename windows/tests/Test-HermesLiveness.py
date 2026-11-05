"""Hermes close-check fixtures, using the pinned upstream session registry."""
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest

source = Path(sys.argv[1]).resolve(strict=True)
if hashlib.sha256(source.read_bytes()).hexdigest() != "0e3bd5dd93281f4d392850550a8d8bf94b213f965dccd6159513fa5bc6466fb7":
    raise SystemExit("Unrecognized Hermes session-registry fixture.")
fake_constants = types.ModuleType("hermes_constants")
fake_constants.get_default_hermes_root = lambda: None
fake_constants.get_hermes_home = lambda: None
fake_constants.named_profile_is_live = lambda home: True
fake_utils = types.ModuleType("utils")
fake_utils.atomic_json_write = lambda *args, **kwargs: None
fake_gateway = types.ModuleType("gateway")
fake_gateway.__path__ = []
fake_status = types.ModuleType("gateway.status")
fake_status._pid_exists = lambda pid: pid == os.getpid()
sys.modules.update({"hermes_constants": fake_constants, "utils": fake_utils,
                    "gateway": fake_gateway, "gateway.status": fake_status})
spec = importlib.util.spec_from_file_location("hermes_fixture_sessions", source)
sessions = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = sessions
spec.loader.exec_module(sessions)
project = Path(__file__).resolve().parent.parent
assets = project / ("app/integrations" if (project / "app/integrations").is_dir() else "integrations")
package = types.ModuleType("aitm_hermes_guard_fixture")
package.__path__ = [str(assets)]
sys.modules[package.__name__] = package
guard = importlib.import_module(package.__name__ + ".hermes_liveness")

if len(sys.argv) > 2 and sys.argv[2] == "--hold":
    path, mode = Path(sys.argv[3]), sys.argv[4]
    if mode == "session":
        lock = sessions._FileLock(path)
        lock.__enter__()
        try:
            print("READY", flush=True)
            sys.stdin.read(1)
        finally:
            lock.__exit__(None, None, None)
    else:
        with open(path, "r+b") as stream:
            if os.name == "nt":
                import msvcrt
                stream.seek(1_048_576)
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            print("READY", flush=True)
            sys.stdin.read(1)
    raise SystemExit(0)

sys.argv = sys.argv[:1]


class HermesLivenessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aitm-hermes-closed-", dir=os.path.realpath(tempfile.gettempdir()))
        self.root = Path(self.temp.name)
        self.host = self.root / "host-locks"
        self.host.mkdir()
        self.profiles = [self.root / "one", self.root / "two"]
        for home in self.profiles:
            home.mkdir()
            (home / "config.yaml").write_text("unrelated: KEEP\n", encoding="utf-8")
            (home / "runtime").mkdir()
            (home / "runtime" / "active_sessions.lock").write_bytes(b"\n")
            (home / "runtime" / "active_sessions.json").write_text('{"entries":[]}', encoding="utf-8")
            (home / "gateway.lock").write_bytes(b"\n")
        for name in ("host-gateway.lock", "host-serve.lock", "host-desktop-serve.lock"):
            (self.host / name).write_bytes(b"\n")

    def tearDown(self):
        self.temp.cleanup()

    def check(self):
        guard.require_hermes_closed(self.profiles, self.host, sessions)

    def rejected(self, code):
        with self.assertRaises(guard.HermesLivenessError) as result:
            self.check()
        self.assertEqual(str(result.exception), code)
        self.assertNotIn("PRIVATE", str(result.exception))

    def test_closed_and_dead_leases_are_read_only(self):
        registry = self.profiles[0] / "runtime" / "active_sessions.json"
        original = json.dumps({"entries": [{"lease_id": "old", "session_id": "PRIVATE",
                                            "pid": 2_000_000_000}]}).encode()
        registry.write_bytes(original)
        self.check()
        self.assertEqual(registry.read_bytes(), original)
        for home in self.profiles:
            self.assertEqual((home / "config.yaml").read_text(encoding="utf-8"), "unrelated: KEEP\n")

    def test_live_and_corrupt_leases_fail_closed(self):
        registry = self.profiles[1] / "runtime" / "active_sessions.json"
        registry.write_text(json.dumps({"entries": [{"lease_id": "live", "session_id": "PRIVATE",
                                                     "pid": os.getpid()}]}), encoding="utf-8")
        self.rejected("hermes-running")
        registry.write_text("{PRIVATE", encoding="utf-8")
        self.rejected("liveness-unconfirmed")
        registry.write_bytes(b"x" * 1_048_577)
        self.rejected("liveness-unconfirmed")

    def test_registry_without_lock_is_not_treated_as_closed(self):
        lock = self.profiles[0] / "runtime" / "active_sessions.lock"
        lock.unlink()
        self.rejected("liveness-unconfirmed")

    def test_live_host_gateway_and_registry_locks_refuse_quickly(self):
        cases = [(self.host / "host-gateway.lock", "host"),
                 (self.host / "host-serve.lock", "host"),
                 (self.host / "host-desktop-serve.lock", "host"),
                 (self.profiles[1] / "gateway.lock", "host"),
                 (self.profiles[1] / "runtime" / "active_sessions.lock", "session")]
        for path, mode in cases:
            with self.subTest(mode=mode, name=path.name):
                env = {name: os.environ[name] for name in ("PATH", "SYSTEMROOT", "WINDIR", "TMP", "TEMP")
                       if name in os.environ}
                env.update({"USERPROFILE": str(self.root), "HOME": str(self.root), "PYTHONDONTWRITEBYTECODE": "1"})
                child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), str(source),
                                          "--hold", str(path), mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, env=env,
                                         creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                try:
                    self.assertEqual(child.stdout.readline().strip(), b"READY")
                    started = time.monotonic()
                    self.rejected("hermes-running")
                    self.assertLess(time.monotonic() - started, 2)
                finally:
                    child.communicate(input=b"x", timeout=5)
                self.assertEqual(child.returncode, 0)
        self.check()

    def test_duplicate_or_linked_profiles_are_unconfirmed(self):
        with self.assertRaises(guard.HermesLivenessError):
            guard.require_hermes_closed(["relative-profile"], self.host, sessions)
        with self.assertRaises(guard.HermesLivenessError):
            guard.require_hermes_closed(self.profiles, "relative-locks", sessions)
        self.profiles.append(self.profiles[0])
        self.rejected("liveness-unconfirmed")
        self.profiles.pop()
        alias = self.root / "alias"
        try:
            alias.symlink_to(self.profiles[0], target_is_directory=True)
        except OSError:
            return
        self.profiles.append(alias)
        self.rejected("liveness-unconfirmed")


if __name__ == "__main__":
    unittest.main()
