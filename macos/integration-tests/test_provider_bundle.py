import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ASSETS = Path(__file__).parent.parent / "integrations"
spec = importlib.util.spec_from_file_location("provider_bundle", ASSETS / "provider_bundle.py")
bundles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundles)


class ProviderBundleTests(unittest.TestCase):
    def profile(self, root, provider, name="profile"):
        path = Path(root) / name
        path.mkdir()
        (path / ("config.yaml" if provider == "hermes" else "package.json")).write_text(
            "# FOREIGN SETTINGS AND SECRET\n" if provider == "hermes" else '{"private":true}', encoding="utf-8")
        return path

    def test_both_bundles_preserve_configuration_and_foreign_files(self):
        for provider, contract in (("hermes", "hermes.observer.v1"), ("deepseek", "dsh.cordis.bundle.v1")):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
                profile = self.profile(root, provider)
                config = profile / ("config.yaml" if provider == "hermes" else "package.json")
                original = config.read_bytes()
                foreign = profile / "other-plugin.txt"
                foreign.write_text("KEEP", encoding="utf-8")
                bundle = bundles.ProviderBundle(provider, profile)
                self.assertEqual(bundle.state(), "absent")
                with self.assertRaisesRegex(bundles.BundleError, "unverified-contract"):
                    bundle.install(ASSETS, "unknown")
                self.assertFalse(bundle.folder.exists())
                self.assertEqual(bundle.install(ASSETS, contract), "staged")
                scope = (bundle.folder / "monitor-profile.json").read_bytes()
                self.assertEqual(bundle.install(ASSETS, contract), "staged")
                self.assertEqual((bundle.folder / "monitor-profile.json").read_bytes(), scope)
                self.assertEqual(config.read_bytes(), original)
                self.assertNotIn(b"SECRET", (bundle.folder / "aitm-manifest.json").read_bytes())
                self.assertEqual(bundle.remove(), "absent")
                self.assertEqual(bundle.remove(), "absent")
                self.assertEqual(config.read_bytes(), original)
                self.assertEqual(foreign.read_text(encoding="utf-8"), "KEEP")

    def test_profiles_get_distinct_stable_private_namespaces(self):
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            scopes = []
            for name in ("one", "two"):
                bundle = bundles.ProviderBundle("hermes", self.profile(root, "hermes", name))
                bundle.install(ASSETS, "hermes.observer.v1")
                scopes.append(json.loads((bundle.folder / "monitor-profile.json").read_bytes())["namespace"])
            self.assertNotEqual(*scopes)
            self.assertTrue(all(len(scope) == 32 for scope in scopes))

    def test_modified_extra_and_cache_files_are_never_deleted(self):
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            bundle = bundles.ProviderBundle("hermes", self.profile(root, "hermes"))
            bundle.install(ASSETS, "hermes.observer.v1")
            module = bundle.folder / "provider_hooks.py"
            original = module.read_bytes()
            module.write_text("USER CHANGE", encoding="utf-8")
            with self.assertRaises(bundles.BundleError):
                bundle.remove()
            self.assertEqual(module.read_text(encoding="utf-8"), "USER CHANGE")
            module.write_bytes(original)
            cache = bundle.folder / "__pycache__"
            cache.mkdir()
            (cache / "unknown.pyc").write_bytes(b"KEEP")
            with self.assertRaises(bundles.BundleError):
                bundle.remove()
            self.assertTrue(module.exists())
            self.assertEqual((cache / "unknown.pyc").read_bytes(), b"KEEP")

    def test_python_generated_bytecode_is_removed_only_when_reproducible(self):
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            bundle = bundles.ProviderBundle("hermes", self.profile(root, "hermes"))
            bundle.install(ASSETS, "hermes.observer.v1")
            child_env = {name: os.environ[name] for name in ("PATH", "SYSTEMROOT", "WINDIR") if name in os.environ}
            child_env.update({"TMP": root, "TEMP": root, "TMPDIR": root})
            code = ("import importlib.util,sys; "
                    "spec=importlib.util.spec_from_file_location('aitm_fixture',sys.argv[1],"
                    "submodule_search_locations=[sys.argv[2]]); "
                    "module=importlib.util.module_from_spec(spec); sys.modules[spec.name]=module; "
                    "spec.loader.exec_module(module)")
            subprocess.run([sys.executable, "-c", code, str(bundle.folder / "__init__.py"), str(bundle.folder)],
                           env=child_env, check=True, capture_output=True, timeout=10)
            cache = bundle.folder / "__pycache__"
            generated = list(cache.iterdir())
            self.assertGreaterEqual(len(generated), 4)
            original = generated[0].read_bytes()
            generated[0].write_bytes(original + b"USER CHANGE")
            with self.assertRaisesRegex(bundles.BundleError, "modified-bundle"):
                bundle.remove()
            self.assertTrue(generated[0].exists())
            generated[0].write_bytes(original)
            self.assertEqual(bundle.remove(), "absent")
            self.assertFalse(bundle.folder.exists())

    def test_concurrent_creation_and_change_preserve_other_writers(self):
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            bundle = bundles.ProviderBundle("deepseek", self.profile(root, "deepseek"))
            def competing_install():
                bundle.folder.mkdir()
                (bundle.folder / "user.txt").write_bytes(b"KEEP")
            with self.assertRaisesRegex(bundles.BundleError, "bundle-conflict"):
                bundle.install(ASSETS, "dsh.cordis.bundle.v1", before_commit=competing_install)
            self.assertEqual((bundle.folder / "user.txt").read_bytes(), b"KEEP")
            self.assertFalse(list(bundle.parent.glob(".aitm-stage-*")))
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            bundle = bundles.ProviderBundle("hermes", self.profile(root, "hermes"))
            bundle.install(ASSETS, "hermes.observer.v1")
            def competing_change():
                (bundle.folder / "provider_hooks.py").write_bytes(b"NEW")
            with self.assertRaises(bundles.BundleError):
                bundle.remove(before_commit=competing_change)
            self.assertEqual((bundle.folder / "provider_hooks.py").read_bytes(), b"NEW")
            self.assertTrue((bundle.folder / "plugin.yaml").exists())

    def test_missing_profile_and_existing_foreign_directory_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            with self.assertRaises(bundles.BundleError):
                bundles.ProviderBundle("hermes", Path(root) / "missing")
            bundle = bundles.ProviderBundle("deepseek", self.profile(root, "deepseek"))
            bundle.folder.mkdir()
            with self.assertRaises(bundles.BundleError):
                bundle.install(ASSETS, "dsh.cordis.bundle.v1")
            self.assertEqual(list(bundle.folder.iterdir()), [])

    def test_symlink_profile_and_dangling_destination_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="aitm-bundle-", dir=os.path.realpath(tempfile.gettempdir())) as root:
            profile = self.profile(root, "deepseek")
            alias = Path(root) / "alias"
            try:
                alias.symlink_to(profile, target_is_directory=True)
            except OSError as error:
                self.skipTest("Symlink creation unavailable: " + str(error.errno))
            with self.assertRaisesRegex(bundles.BundleError, "linked-path"):
                bundles.ProviderBundle("deepseek", alias)
            bundle = bundles.ProviderBundle("deepseek", profile)
            bundle.folder.symlink_to(Path(root) / "nonexistent", target_is_directory=True)
            with self.assertRaisesRegex(bundles.BundleError, "linked-path"):
                bundle.install(ASSETS, "dsh.cordis.bundle.v1")


if __name__ == "__main__":
    unittest.main()
