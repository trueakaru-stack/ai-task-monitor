"""Synthetic tests for the user-invoked Hermes manager launcher."""

import ast
import contextlib
import importlib.util
import io
import marshal
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ASSETS = Path(sys.argv.pop(1)).resolve(strict=True)
SOURCE = Path(sys.argv.pop(1)).resolve(strict=True)
spec = importlib.util.spec_from_file_location("aitm_hermes_manager_test", ASSETS / "hermes-manager.py")
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)
setup = manager._load_setup(ASSETS)


class HermesManagerTests(unittest.TestCase):
    def setUp(self):
        self.original_path = list(sys.path)
        self.original_modules = set(sys.modules)
        self.temp = tempfile.TemporaryDirectory(prefix="aitm-hermes-manager-")
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home 'quoted' \u042f $()"
        self.project = self.home / "hermes-agent"
        self.home.mkdir()
        for name in setup._SOURCE_HASHES.keys() | manager._MANAGER_HASHES.keys():
            target = self.project.joinpath(*name.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOURCE.joinpath(*name.split("/")), target)
        (self.home / "config.yaml").write_text("plugins: {}\n", encoding="utf-8")
        self.named = self.home / "profiles" / "work"
        self.named.mkdir(parents=True)
        (self.named / "config.yaml").write_text("plugins: {}\n", encoding="utf-8")
        for profile in (self.home, self.named):
            setup._bundle.ProviderBundle("hermes", profile).install(ASSETS, "hermes.observer.v1")
        self.venv = self.project / "venv"
        self.python = self.venv / ("Scripts/python.exe" if os.name == "nt" else "bin/python3")
        self.python.parent.mkdir(parents=True)
        self.python.write_bytes(b"synthetic")
        (self.venv / "pyvenv.cfg").write_text("fixture\n", encoding="utf-8")
        self.environment = {name: os.environ[name] for name in ("SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT") if name in os.environ}
        self.environment.update({"HOME": str(self.root), "USERPROFILE": str(self.root), "LOCALAPPDATA": str(self.root),
                                 "APPDATA": str(self.root), "TEMP": str(self.root), "TMP": str(self.root),
                                 "TMPDIR": str(self.root), "PATH": "", "HERMES_HOME": str(self.root / "wrong")})

    def tearDown(self):
        for name in [name for name in sys.modules if name not in self.original_modules and
                     (name in ("ruamel", "dotenv", "hermes_cli", "hermes_constants", "hermes_yaml", "utils", "pm") or
                      name.startswith(("ruamel.", "dotenv.", "hermes_cli.", "pm.")))]:
            del sys.modules[name]
        sys.path[:] = self.original_path
        self.temp.cleanup()

    def use_synthetic_dotenv(self):
        site = self.venv / ("Lib/site-packages" if os.name == "nt" else "lib/site-packages")
        site.mkdir(parents=True, exist_ok=True)
        wheel = os.environ.get("AITM_TEST_DOTENV_WHEEL", "")
        if wheel:
            target = site / Path(wheel).name
            shutil.copyfile(wheel, target)
            sys.path.insert(0, str(target))
        else:
            found = importlib.util.find_spec("dotenv")
            if found is None or found.origin is None:
                self.fail("Synthetic python-dotenv test dependency is unavailable")
            shutil.copytree(Path(found.origin).parent, site / "dotenv")
            sys.path.insert(0, str(site))
        sys.path.insert(0, str(self.project))

    def local_config(self, name="work"):
        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "executable", str(self.python)):
            return manager._check_local_config(self.home, self.project, name, setup)

    def check(self, home=None, project=None, name="work", action="enable"):
        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "executable", str(self.python)):
            return manager._validate([str(home or self.home), str(project or self.project), name, action], ASSETS, setup)

    def test_default_and_named_profile_are_checked_in_the_selected_install(self):
        for name in ("default", "work"):
            for action in ("enable", "disable"):
                home, project, found, actual_action = self.check(name=name, action=action)
                self.assertEqual((home, project, found, actual_action), (self.home, self.project, name, action))

    def test_unverified_or_modified_inputs_are_refused(self):
        for name, action in (("../work", "enable"), ("work;echo", "enable"), ("WORK", "enable"),
                             ("sudo", "enable"), ("work", "remove")):
            with self.assertRaises(Exception):
                self.check(name=name, action=action)
        foreign = self.root / "other-project"
        foreign.mkdir()
        with self.assertRaises(Exception):
            self.check(project=foreign)
        self.python.unlink()
        with self.assertRaises(Exception):
            self.check()

    def test_home_environment_expansion_is_rejected_even_if_unset(self):
        for pattern in ("$AITM_UNSET", "${AITM_UNSET}"):
            self.assertTrue(manager._has_home_expansion(pattern))
            with patch.object(setup, "_absolute") as resolve:
                with self.assertRaises(manager.UnconfirmedLocalConfig):
                    manager._validate([str(self.root / pattern), str(self.project), "work", "enable"], ASSETS, setup)
                resolve.assert_not_called()
        self.assertFalse(manager._has_home_expansion("literal $()"))
        if os.name == "nt":
            self.assertTrue(manager._has_home_expansion("%AITM_UNSET%"))
            with self.assertRaises(manager.UnconfirmedLocalConfig):
                self.check(home=self.root / "%AITM_UNSET%")

    def test_modified_manager_source_or_bundle_is_refused(self):
        source = self.project / "hermes_cli" / "main.py"
        original = source.read_bytes()
        source.write_bytes(original + b"\n# modified\n")
        with self.assertRaises(Exception):
            self.check()
        source.write_bytes(original)
        parser = self.project / "hermes_cli" / "_parser.py"
        before = parser.read_bytes()
        parser.write_bytes(before + b"\n# modified\n")
        with self.assertRaises(Exception):
            self.check()
        parser.write_bytes(before)
        (self.named / "plugins" / "ai-task-monitor" / "hermes_observer.py").write_text("changed", encoding="utf-8")
        with self.assertRaises(Exception):
            self.check()

    def test_managed_remote_and_foreign_runtime_overrides_are_refused(self):
        for key, value in (("HERMES_MANAGED_DIR", "private"), ("HERMES_CONFIG_BACKEND", "remote"),
                           ("HERMES_RUNTIME_DIR", "foreign"), ("HERMES_INSTALL_ROOT", "foreign"),
                           ("HERMES_PYTHON_SRC_ROOT", "foreign")):
            self.environment[key] = value
            with self.assertRaises(Exception):
                self.check()
            del self.environment[key]
        self.environment["HERMES_CONFIG_BACKEND"] = "file"
        self.check()

    def test_dotenv_layers_are_checked_without_logging_or_changing_files(self):
        self.use_synthetic_dotenv()
        paths = (self.home / ".env", self.home / ".op.env", self.named / ".env",
                 self.named / ".op.env", self.project / ".env")
        secret = "SYNTHETIC_SECRET_MUST_NOT_APPEAR"
        cases = [
            ({}, {}, True),
            ({0: "HERMES_CONFIG_BACKEND=remote"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=remote"}, {}, False),
            ({4: "HERMES_CONFIG_BACKEND=remote"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=file", 4: "HERMES_CONFIG_BACKEND=remote"}, {}, False),
            ({3: "HERMES_CONFIG_BACKEND=remote"}, {}, False),
            ({3: "HERMES_CONFIG_BACKEND=remote"}, {"OP_SERVICE_ACCOUNT_TOKEN": secret}, False),
            ({2: "SELECTOR=remote\nHERMES_CONFIG_BACKEND=${SELECTOR}"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=${UNSET:-remote}"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=${UNSET:-file}"}, {}, False),
            ({0: "HERMES_CONFIG_BACKEND=file", 2: "HERMES_CONFIG_BACKEND=${HERMES_CONFIG_BACKEND:-remote}"}, {}, False),
            ({0: "SELECTOR=remote", 2: "HERMES_CONFIG_BACKEND=${SELECTOR:-file}"}, {}, False),
            ({0: "HERMES_MANAGED_DIR=managed"}, {}, False),
            ({2: "HERMES_MANAGED_DIR=managed"}, {}, False),
            ({4: "HERMES_MANAGED_DIR=managed"}, {}, False),
            ({2: "HERMES_HOME=other-profile"}, {}, False),
            ({2: "HERMES_HOME="}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=FILE"}, {}, True),
            ({2: "hermes_config_backend=remote"}, {}, False),
            ({2: "HeRmEs_MaNaGeD_dIr=managed"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=remote\nHERMES_CONFIG_BACKEND=file"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=${CHOICE:-file}\nCHOICE=remote"}, {}, False),
            ({2: "HERMES_CONFIG_BACKEND=file\nHERMES_CONFIG_BACKEND=FiLe"}, {}, True),
            ({2: "HERMES_DISABLE_LAZY_INSTALLS=1"}, {}, True),
            ({2: "HERMES_DISABLE_LAZY_INSTALLS=0"}, {}, False),
            ({2: "hermes_disable_lazy_installs=${SKIP:-1}"}, {}, False),
            ({2: "export HERMES_CONFIG_BACKEND='FiLe'"}, {}, True),
            ({2: 'HERMES_CONFIG_BACKEND="fi\nle"'}, {}, False),
            ({2: 'TOKEN="private\nmultiline"'}, {}, True),
            ({2: 'HERMES_CONFIG_BACKEND="unterminated'}, {}, False),
        ]
        for contents, extras, expected in cases:
            with self.subTest(case=contents):
                for path in paths:
                    path.unlink(missing_ok=True)
                for index, content in contents.items():
                    paths[index].write_text(content + "\nTOKEN=" + secret + "\n", encoding="utf-8")
                before = {path: path.read_bytes() for path in paths if path.exists()}
                self.environment.update(extras)
                out, err = io.StringIO(), io.StringIO()
                try:
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        try:
                            self.local_config()
                            actual = True
                        except Exception:
                            actual = False
                finally:
                    for key in extras:
                        del self.environment[key]
                self.assertEqual(actual, expected)
                self.assertNotIn(secret, out.getvalue() + err.getvalue())
                self.assertEqual({path: path.read_bytes() for path in paths if path.exists()}, before)

    def test_dotenv_utf16_oversize_and_postcheck_change_fail_closed(self):
        self.use_synthetic_dotenv()
        path = self.named / ".env"
        path.write_bytes("HERMES_CONFIG_BACKEND=remote\n".encode("utf-16"))
        with self.assertRaises(Exception):
            self.local_config()
        path.write_bytes("HERMES_CONFIG_BACKEND=file\n".encode("utf-16"))
        self.local_config()
        path.write_bytes(b"\xef\xbb\xbfhermes_config_backend=remote\n")
        with self.assertRaises(Exception):
            self.local_config()
        path.write_bytes(b"H\x00E\x00R\x00M\x00E\x00S\x00_\x00C\x00O\x00N\x00F\x00I\x00G\x00_\x00B\x00A\x00C\x00K\x00E\x00N\x00D\x00=\x00r\x00e\x00m\x00o\x00t\x00e\x00\n\x00")
        with self.assertRaises(Exception):
            self.local_config()
        path.write_bytes(b"HERMES_CONFIG_BACKEND=\xff\n")
        with self.assertRaises(Exception):
            self.local_config()
        path.write_bytes(b"A" * 1_048_577)
        with self.assertRaises(Exception):
            self.local_config()
        path.write_bytes(b"HERMES_CONFIG_BACKEND=file\n")
        checksums = self.local_config()
        path.write_bytes(b"HERMES_CONFIG_BACKEND=remote\n")
        with self.assertRaises(Exception):
            manager._recheck_dotenv(checksums, setup._bundle)

    def test_profile_managed_scope_is_refused_before_managed_file_is_read(self):
        self.use_synthetic_dotenv()
        managed = self.root / "managed"
        managed.mkdir()
        (managed / ".env").write_text("HERMES_CONFIG_BACKEND=remote\n", encoding="utf-8")
        (self.named / ".env").write_text("HERMES_MANAGED_DIR=" + str(managed) + "\n", encoding="utf-8")
        with self.assertRaises(Exception):
            self.local_config()

    def test_external_secret_sources_are_refused_for_root_and_profile(self):
        self.use_synthetic_dotenv()
        configs = (self.home / "config.yaml", self.named / "config.yaml")
        variants = (
            ("secrets: {}\n", True),
            ("secrets:\n  source:\n    enabled: false\n", True),
            ("secrets:\n  sources: [other]\n  source:\n    enabled: false\n", True),
            ("secrets:\n  source:\n    enabled: true\n", False),
            ("secrets:\n  source:\n    enabled: yes\n", False),
            ("secrets:\n  source:\n    Enabled: true\n", False),
            ("secrets:\n  source:\n    enabled: '${ACTIVE}'\n", False),
            ("secrets: '${INHERITED}'\n", False),
            ("secrets:\n  source: unexpected\n", False),
        )
        for config in configs:
            for source, expected in variants:
                with self.subTest(config=config.name, content=source):
                    config.write_text("plugins: {}\n" + source + "private: SYNTHETIC_SECRET\n", encoding="utf-8")
                    before = config.read_bytes()
                    out, err = io.StringIO(), io.StringIO()
                    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                        try:
                            checksums = self.local_config()
                            actual = True
                        except Exception:
                            actual = False
                    self.assertEqual(actual, expected)
                    self.assertNotIn("SYNTHETIC_SECRET", out.getvalue() + err.getvalue())
                    self.assertEqual(config.read_bytes(), before)
                    if actual:
                        config.write_bytes(before + b"# changed\n")
                        with self.assertRaises(Exception):
                            manager._recheck_dotenv(checksums, setup._bundle)
                config.write_text("plugins: {}\n", encoding="utf-8")

    def test_known_pending_update_and_repair_markers_are_refused(self):
        key = __import__("hashlib").sha256(str(self.project).encode("utf-8")).hexdigest()[:16]
        paths = (self.project / ".update-incomplete", self.project / ".lazy-refresh-incomplete",
                 self.project / ".hermes-update-zip-swap", self.home / "installs" / key / ".repair-incomplete",
                 self.home / ".hermes-update-paused-gateways.synthetic.json")
        manager._reject_pending_maintenance(self.home, self.project, setup)
        for marker in paths:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text("synthetic", encoding="utf-8")
            with self.assertRaises(Exception):
                manager._reject_pending_maintenance(self.home, self.project, setup)
            marker.unlink()
        lock = self.home / ".hermes-update-paused-gateways.lock"
        lock.write_text("synthetic", encoding="utf-8")
        manager._reject_pending_maintenance(self.home, self.project, setup)
        git = self.project / ".git"
        git.mkdir()
        marker = git / "hermes-update-pull"
        marker.write_text("synthetic", encoding="utf-8")
        with self.assertRaises(Exception):
            manager._reject_pending_maintenance(self.home, self.project, setup)
        marker.unlink()
        git.rmdir()
        worktree = self.root / "git-worktree"
        worktree.mkdir()
        git.write_text("gitdir: " + str(worktree), encoding="utf-8")
        marker = worktree / "hermes-update-pull"
        marker.write_text("synthetic", encoding="utf-8")
        with self.assertRaises(Exception):
            manager._reject_pending_maintenance(self.home, self.project, setup)

    def test_upstream_explicit_plugin_admission_is_not_a_lazy_install(self):
        source = SOURCE / "hermes_cli" / "plugins_admission.py"
        tree = ast.parse(source.read_text(encoding="utf-8"))
        function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "admit_plugin_set_change")
        calls = [n for n in ast.walk(function) if isinstance(n, ast.Call) and
                 isinstance(n.func, ast.Name) and n.func.id == "sync_venv"]
        self.assertEqual(len(calls), 1)
        explicit = [k.value for k in calls[0].keywords if k.arg == "explicit"]
        self.assertEqual(len(explicit), 1)
        self.assertIsInstance(explicit[0], ast.Constant)
        self.assertIs(explicit[0].value, True)

    def test_pending_update_refuses_before_any_manager_process(self):
        self.use_synthetic_dotenv()
        (self.project / ".update-incomplete").write_text("synthetic", encoding="utf-8")
        original = [str(ASSETS / "hermes-manager.py"), str(self.home), str(self.project), "work", "enable"]
        err = io.StringIO()
        sys.path.remove(str(self.project))
        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "executable", str(self.python)), \
             patch.object(sys, "argv", original), patch.object(manager.subprocess, "call") as launch, \
             contextlib.redirect_stderr(err):
            self.assertEqual(manager.main(), 1)
        launch.assert_not_called()
        self.assertTrue("обновление" in err.getvalue() or "update" in err.getvalue())

    def test_remote_dotenv_refuses_before_any_manager_process(self):
        self.use_synthetic_dotenv()
        (self.named / ".env").write_text("HERMES_CONFIG_BACKEND=remote\nTOKEN=SYNTHETIC_SECRET\n", encoding="utf-8")
        original = [str(ASSETS / "hermes-manager.py"), str(self.home), str(self.project), "work", "enable"]
        err = io.StringIO()
        # main adds the verified source itself, and refuses before subprocess.call.
        sys.path.remove(str(self.project))
        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "executable", str(self.python)), \
             patch.object(sys, "argv", original), patch.object(manager.subprocess, "call") as launch, \
             contextlib.redirect_stderr(err):
            self.assertEqual(manager.main(), 1)
        launch.assert_not_called()
        self.assertNotIn("SYNTHETIC_SECRET", err.getvalue())
        self.assertTrue("не запущен" in err.getvalue() or "not started" in err.getvalue())

    def test_external_secret_source_refuses_before_any_manager_process(self):
        self.use_synthetic_dotenv()
        (self.named / "config.yaml").write_text(
            "plugins: {}\nsecrets:\n  synthetic_source:\n    enabled: true\nprivate: SYNTHETIC_SECRET\n", encoding="utf-8")
        original = [str(ASSETS / "hermes-manager.py"), str(self.home), str(self.project), "work", "enable"]
        err = io.StringIO()
        sys.path.remove(str(self.project))
        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "executable", str(self.python)), \
             patch.object(sys, "argv", original), patch.object(manager.subprocess, "call") as launch, \
             contextlib.redirect_stderr(err):
            self.assertEqual(manager.main(), 1)
        launch.assert_not_called()
        self.assertNotIn("SYNTHETIC_SECRET", err.getvalue())
        self.assertTrue("внешние источники ключей" in err.getvalue() or "external-secret" in err.getvalue())

    def test_committed_python_must_belong_to_selected_generation(self):
        key = __import__("hashlib").sha256(str(self.project).encode("utf-8")).hexdigest()[:16]
        install = self.home / "installs" / key
        generation = install / "environments" / "version one"
        executable = generation / ("Scripts/python.exe" if os.name == "nt" else "bin/python3")
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"synthetic")
        (generation / "pyvenv.cfg").write_text("fixture\n", encoding="utf-8")
        (install / "facts.json").write_text(json.dumps({"packages": {"venv": {"environment": str(generation)}}}), encoding="utf-8")
        with self.assertRaises(Exception):
            self.check()
        self.python = executable
        self.check()
        (install / "facts.json").write_text(json.dumps({"packages": {"venv": {"environment": str(self.venv)}}}), encoding="utf-8")
        with self.assertRaises(Exception):
            self.check()

    @unittest.skipIf(os.name == "nt", "macOS/POSIX venv uses a symlinked Python")
    def test_symlinked_python_is_bound_to_its_venv_not_only_the_shared_target(self):
        target = self.root / "shared-python"
        target.write_bytes(b"synthetic")
        self.python.unlink()
        self.python.symlink_to(target)
        self.check()
        other = self.root / "other-venv" / "bin" / "python3"
        other.parent.mkdir(parents=True)
        other.symlink_to(target)
        self.python = other
        with self.assertRaises(Exception):
            self.check()

    def test_delegates_to_official_launcher_with_exact_manager_arguments(self):
        original = [str(ASSETS / "hermes-manager.py"), str(self.home), str(self.project), "work", "enable"]
        seen = []
        fake = types.SimpleNamespace(_bundle=object())
        real_import = __import__

        def importing(name, *args, **kwargs):
            if name == "hermes_cli._launchers":
                module = types.ModuleType(name)
                def runtime(project, args, python, home):
                    seen.append(("runtime", project, args, python, home, os.environ.get("HERMES_HOME")))
                    return [str(python), "-I", "-c", "trusted-bootstrap", *args]
                module.runtime_command = runtime
                return module
            return real_import(name, *args, **kwargs)

        def dispatch(command):
            cache = command[4].removeprefix("pycache_prefix=")
            seen.append(("dispatch", command, list(sys.argv), os.environ.get("HERMES_DISABLE_LAZY_INSTALLS"),
                         sys.pycache_prefix, Path(cache).is_dir()))
            return 0

        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "argv", list(original)), \
             patch.object(sys, "path", list(sys.path)), patch.object(manager, "_load_setup", return_value=fake), \
             patch.object(manager, "_validate", return_value=(self.home, self.project, "work", "enable")), \
             patch.object(manager, "_check_local_config", return_value={}), \
             patch.object(manager, "_reject_pending_maintenance"), \
             patch("builtins.__import__", side_effect=importing), \
             patch.object(manager.subprocess, "call", side_effect=dispatch):
            self.assertEqual(manager.main(), 0)
        args = ["-p", "work", "plugins", "enable", "ai-task-monitor"]
        self.assertIn(("runtime", self.project, args, sys.executable, self.home, str(self.home)), seen)
        event = next(item for item in seen if item[0] == "dispatch")
        command, argv, lazy, cache, existed = event[1:]
        self.assertEqual(command[:4], [sys.executable, "-I", "-B", "-X"])
        self.assertEqual(command[4], "pycache_prefix=" + cache)
        self.assertEqual(command[5:], ["-c", "trusted-bootstrap", *args])
        self.assertEqual(argv, original)
        self.assertEqual(lazy, "1")
        self.assertTrue(existed)
        self.assertFalse(Path(cache).exists())

    def test_pinned_upstream_relaunch_preserves_original_script_arguments(self):
        path = SOURCE / "hermes_cli" / "venv_sync.py"
        tree = ast.parse(path.read_text(encoding="utf-8"))
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "relaunch_command")
        module = ast.Module(body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0), function], type_ignores=[])
        namespace = {"Path": Path}
        exec(compile(ast.fix_missing_locations(module), str(path), "exec"), namespace)
        arguments = ["-p", "work", "plugins", "enable", "ai-task-monitor"]
        code = "import json,sys;print(json.dumps([sys.argv[1:],getattr(sys,'_hermes_relaunched',False),sys.pycache_prefix]))"
        argv = ["-c", *arguments]
        prefix = str(self.root / "isolated-bytecode")
        original = [sys.executable, "-I", "-B", "-X", "pycache_prefix=" + prefix, "-c", code, *arguments]
        command = namespace["relaunch_command"](Path(sys.executable), self.project, argv, original, None)
        result = subprocess.run(command, env=self.environment, cwd=self.root, capture_output=True, timeout=20, check=True)
        self.assertEqual(json.loads(result.stdout), [arguments, True, prefix])

    def test_preflight_ignores_tampered_existing_bytecode(self):
        self.use_synthetic_dotenv()
        source = self.project / "hermes_cli" / "env_loader.py"
        marker = "SYNTHETIC_TAMPERED_BYTECODE"
        code = compile('raise RuntimeError("' + marker + '")', str(source), "exec")
        info = source.stat()
        payload = importlib.util.MAGIC_NUMBER + struct.pack("<III", 0, int(info.st_mtime), info.st_size) + marshal.dumps(code)
        cache = Path(importlib.util.cache_from_source(str(source)))
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(payload)
        probe = "import sys;sys.path.insert(0,sys.argv[1]);import hermes_cli.env_loader"
        result = subprocess.run([sys.executable, "-I", "-B", "-c", probe, str(self.project)],
                                env=self.environment, cwd=self.root, capture_output=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(marker.encode(), result.stderr, "Fixture must reproduce Python reading the tampered cache")

        original = [str(ASSETS / "hermes-manager.py"), str(self.home), str(self.project), "work", "enable"]
        sys.path.remove(str(self.project))
        real_import = __import__
        def importing(name, *args, **kwargs):
            if name == "hermes_cli._launchers":
                module = types.ModuleType(name)
                module.runtime_command = lambda project, args, python, home: [str(python), "-I", "-c", "trusted", *args]
                return module
            return real_import(name, *args, **kwargs)
        with patch.dict(os.environ, self.environment, clear=True), patch.object(sys, "executable", str(self.python)), \
             patch.object(sys, "argv", original), patch("builtins.__import__", side_effect=importing), \
             patch.object(manager.subprocess, "call", return_value=0):
            self.assertEqual(manager.main(), 0)

    def test_pinned_runtime_bootstrap_sees_manager_arguments_and_selected_home(self):
        path = SOURCE / "hermes_cli" / "_launchers.py"
        tree = ast.parse(path.read_text(encoding="utf-8"))
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name in ("_inline_string_literal", "runtime_command")]
        module = ast.Module(body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0),
                                  *functions], type_ignores=[])
        namespace = {"Path": Path, "os": os, "sys": sys}
        exec(compile(ast.fix_missing_locations(module), str(path), "exec"), namespace)
        arguments = ["-p", "work", "plugins", "enable", "ai-task-monitor"]
        probe = ("import json,os,sys,hermes_bootstrap;"
                 "print(json.dumps([sys.argv[1:],os.environ['HERMES_HOME'],hermes_bootstrap.__file__]))")
        command = namespace["runtime_command"](self.project, args=arguments, python=sys.executable,
                                                home=self.home, code=probe)
        # Block network and child processes in the synthetic bootstrap itself.
        guard = ("import socket,subprocess;"
                 "deny=lambda *a,**k: (_ for _ in ()).throw(RuntimeError('offline fixture'));"
                 "socket.socket.connect=deny;socket.socket.connect_ex=deny;socket.getaddrinfo=deny;"
                 "subprocess.Popen=type('NoPopen',(subprocess.Popen,),{'__init__':deny});")
        command[3] = guard + command[3]
        command.insert(2, "-B")
        environment = dict(self.environment, HERMES_HOME=str(self.home), HERMES_DISABLE_LAZY_INSTALLS="1")
        result = subprocess.run(command, env=environment, cwd=self.root, capture_output=True, timeout=30, check=True)
        actual, home, bootstrap = json.loads(result.stdout)
        self.assertEqual(actual, arguments)
        self.assertEqual(home, str(self.home))
        self.assertEqual(Path(bootstrap), self.project / "hermes_bootstrap.py")

    def test_native_shell_quoting_preserves_literal_paths_and_parent_environment(self):
        recorder = self.root / "record 'path'.py"
        recorder.write_text("import json,sys;print(json.dumps(sys.argv[1:]))\n", encoding="utf-8")
        arguments = [str(self.home), str(self.project), "work", "enable"]
        if os.name == "nt":
            def quote(value): return "'" + str(value).replace("'", "''") + "'"
            command = " ".join(["&", quote(sys.executable), "-I", "-B", quote(recorder), *map(quote, arguments)])
            command += "\nif ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\nif ($env:HERMES_HOME -cne " + quote(self.environment["HERMES_HOME"]) + ") { exit 98 }"
            shell = str(Path(self.environment["SYSTEMROOT"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")
            process = [shell, "-NoProfile", "-NonInteractive", "-Command", command]
        else:
            command = " ".join(map(shlex.quote, [sys.executable, "-I", "-B", str(recorder), *arguments]))
            command += "; test \"$HERMES_HOME\" = " + shlex.quote(self.environment["HERMES_HOME"])
            process = ["/bin/sh", "-c", command]
        result = subprocess.run(process, env=self.environment, cwd=self.root, capture_output=True, timeout=20, check=True)
        self.assertEqual(json.loads(result.stdout), arguments)


if __name__ == "__main__":
    unittest.main()
