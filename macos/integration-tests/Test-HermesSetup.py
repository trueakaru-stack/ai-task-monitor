"""Hermes manual preparation against disposable profiles and pinned source files."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ASSETS = Path(sys.argv.pop(1)).resolve(strict=True)
SOURCE = Path(sys.argv.pop(1)).resolve(strict=True)
FILES = (
    "hermes_cli/middleware.py", "hermes_cli/plugins.py", "hermes_cli/plugins_dispatch.py",
    "hermes_cli/lifecycle.py", "agent/turn_api_request.py", "agent/turn_finalizer.py",
    "tools/human_input_hooks.py", "agent/conversation_loop.py", "model_tools.py",
    "hermes_cli/cli_shutdown.py", "hermes_cli/cli_session_mixin.py",
    "hermes_cli/plugins_discovery.py", "hermes_cli/config.py", "hermes_cli/config_backend.py",
    "hermes_cli/managed_scope.py", "hermes_yaml.py", "hermes_cli/env_loader.py",
    "hermes_cli/config_defaults.py", "hermes_cli/profiles.py", "hermes_constants.py", "agent/tool_executor.py",
)
ASSET_FILES = (
    "hermes-setup.py", "provider_bundle.py", "hermes-entry.py", "hermes-plugin.yaml",
    "hermes_observer.py", "provider_hooks.py", "provider_sender.py", "provider_transport.py",
    "ruamel.yaml-0.18.16-py3-none-any.whl",
)


class ManualHermesSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="aitm-hermes-профиль-")
        self.root = Path(self.temp.name).resolve()
        self.home, self.project, self.assets = (self.root / name for name in ("home", "project", "assets"))
        self.home.mkdir()
        self.assets.mkdir()
        for name in FILES:
            target = self.project.joinpath(*name.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE.joinpath(*name.split("/")), target)
        for name in ASSET_FILES:
            shutil.copyfile(ASSETS / name, self.assets / name)
        self.config = b"# KEEP COMMENT\nplugins:\n  enabled: [other-plugin]\nprivate_setting: PRIVATE_FIXTURE\n"
        (self.home / "config.yaml").write_bytes(self.config)
        self.named = self.home / "profiles" / "work"
        self.named.mkdir(parents=True)
        (self.named / "config.yaml").write_bytes(self.config)
        self.env = {key: os.environ[key] for key in ("SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT") if key in os.environ}
        self.env.update({"HOME": str(self.root), "USERPROFILE": str(self.root), "LOCALAPPDATA": str(self.root),
                         "APPDATA": str(self.root), "TMP": str(self.root), "TEMP": str(self.root),
                         "TMPDIR": str(self.root), "PATH": ""})

    def tearDown(self):
        self.temp.cleanup()

    def call(self, action, **extra):
        request = {"action": action, "home": str(self.home), "project": str(self.project),
                   "assets": str(self.assets), **extra}
        result = subprocess.run([sys.executable, "-I", "-S", "-B", str(self.assets / "hermes-setup.py")],
                                input=json.dumps(request).encode(), capture_output=True, timeout=10, env=self.env)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertNotIn(b"PRIVATE_FIXTURE", result.stdout)
        return json.loads(result.stdout)

    def test_prepare_is_scoped_idempotent_and_preserves_other_settings(self):
        self.assertEqual([item["state"] for item in self.call("list")["result"]], ["absent", "absent"])
        unrelated = self.home / "plugins" / "other-plugin"
        unrelated.mkdir(parents=True)
        (unrelated / "keep.txt").write_text("KEEP", encoding="utf-8")
        self.assertEqual(self.call("prepare", profile="root")["result"], "prepared")
        self.assertEqual(self.call("prepare", profile="root")["result"], "prepared")
        self.assertEqual(self.call("prepare", profile="profile:work")["result"], "prepared")
        states = self.call("list")["result"]
        self.assertEqual([item["state"] for item in states], ["prepared", "prepared"])
        self.assertEqual([item["enabled"] for item in states], [False, False])
        self.assertNotEqual(states[0]["scope"], states[1]["scope"])
        self.assertTrue(all(len(item["scope"]) == 32 for item in states))
        self.assertEqual((unrelated / "keep.txt").read_text(encoding="utf-8"), "KEEP")
        self.assertEqual((self.home / "config.yaml").read_bytes(), self.config)
        self.assertEqual((self.named / "config.yaml").read_bytes(), self.config)
        # Stand in for the user's later manual enable/disable; this fixture is disposable.
        enabled = self.config.replace(b"[other-plugin]", b"[other-plugin, ai-task-monitor]")
        (self.home / "config.yaml").write_bytes(enabled)
        (self.named / "config.yaml").write_bytes(enabled)
        self.assertEqual([item["enabled"] for item in self.call("list")["result"]], [True, True])
        disabled = enabled.replace(b"  enabled:", b"  disabled: [ai-task-monitor]\n  enabled:")
        (self.home / "config.yaml").write_bytes(disabled)
        self.assertEqual([item["enabled"] for item in self.call("list")["result"]], [False, True])

    def test_modified_bundle_and_foreign_folder_are_never_replaced(self):
        self.call("prepare", profile="root")
        target = self.home / "plugins" / "ai-task-monitor" / "hermes_observer.py"
        target.write_text("foreign edit", encoding="utf-8")
        self.assertEqual(self.call("list")["result"][0]["state"], "error")
        self.assertFalse(self.call("prepare", profile="root")["ok"])
        self.assertEqual(target.read_text(encoding="utf-8"), "foreign edit")
        foreign = self.named / "plugins" / "ai-task-monitor"
        foreign.mkdir(parents=True)
        (foreign / "other.txt").write_text("KEEP", encoding="utf-8")
        self.assertFalse(self.call("prepare", profile="profile:work")["ok"])
        self.assertEqual((foreign / "other.txt").read_text(encoding="utf-8"), "KEEP")

    def test_unrecognized_source_and_invalid_profile_are_refused(self):
        self.assertEqual(self.call("prepare", profile="profile:../other")["error"], "invalid-profile")
        source = self.project / "hermes_cli" / "plugins.py"
        source.write_bytes(source.read_bytes() + b"\n# changed\n")
        self.assertEqual(self.call("prepare", profile="root")["error"], "unsupported-version")
        self.assertFalse((self.home / "plugins").exists())

    def test_standard_windows_checkout_line_endings_are_accepted(self):
        for name in FILES:
            source = self.project.joinpath(*name.split("/"))
            source.write_bytes(source.read_bytes().replace(b"\n", b"\r\n"))
        self.assertTrue(self.call("list")["ok"])

    def test_incomplete_profile_is_reported_without_hiding_valid_profiles(self):
        incomplete = self.home / "profiles" / "unfinished"
        incomplete.mkdir()
        states = {item["id"]: item["state"] for item in self.call("list")["result"]}
        self.assertEqual(states, {"root": "absent", "profile:unfinished": "error", "profile:work": "absent"})

    def test_invalid_yaml_cannot_prepare_or_claim_enabled(self):
        (self.home / "config.yaml").write_bytes(b"plugins: [broken\n")
        self.assertEqual(self.call("list")["result"][0]["state"], "error")
        self.assertEqual(self.call("prepare", profile="root")["error"], "profile-unavailable")
        self.assertFalse((self.home / "plugins").exists())

    def test_managed_or_environment_dependent_selection_is_unconfirmed(self):
        self.assertEqual(self.call("list", managed=True)["error"], "managed-config-unconfirmed")
        (self.home / "config.yaml").write_bytes(
            b'plugins:\n  enabled: [ai-task-monitor]\n  disabled: ["${SYNTHETIC_DISABLED}"]\n')
        self.assertEqual(self.call("list")["result"][0]["state"], "error")
        self.assertEqual(self.call("prepare", profile="root")["error"], "profile-unavailable")
        self.assertFalse((self.home / "plugins").exists())

    def test_yaml_11_duplicate_keys_are_not_accepted(self):
        (self.home / "config.yaml").write_bytes(b"yes: 1\ntrue: 2\nplugins:\n  enabled: [ai-task-monitor]\n")
        self.assertEqual(self.call("list")["result"][0]["state"], "error")
        self.assertEqual(self.call("prepare", profile="root")["error"], "profile-unavailable")

    def test_deleted_profile_is_not_listed_or_prepared(self):
        tombstones = self.home / "profiles" / ".deleted"
        tombstones.mkdir()
        (tombstones / "work").write_text("deleted", encoding="utf-8")
        self.assertEqual([item["id"] for item in self.call("list")["result"]], ["root"])
        self.assertEqual(self.call("prepare", profile="profile:work")["error"], "invalid-profile")
        self.assertFalse((self.named / "plugins").exists())

    def test_modified_parser_wheel_is_never_executed(self):
        wheel = self.assets / "ruamel.yaml-0.18.16-py3-none-any.whl"
        wheel.write_bytes(wheel.read_bytes() + b"unexpected")
        self.assertEqual(self.call("list")["result"][0]["state"], "error")
        self.assertEqual(self.call("prepare", profile="root")["error"], "profile-unavailable")
        self.assertFalse((self.home / "plugins").exists())

    def test_changed_plugin_discovery_is_an_unsupported_contract(self):
        discovery = self.project / "hermes_cli" / "plugins_discovery.py"
        discovery.write_bytes(discovery.read_bytes() + b"\n# incompatible\n")
        self.assertEqual(self.call("list")["error"], "unsupported-version")


if __name__ == "__main__":
    unittest.main()
