"""User-invoked, installation-bound entry to Hermes' own plugin manager.

The shell environment is never changed. Only fixed diagnostics are emitted by
this launcher; after validation the interactive Hermes manager owns its output.
"""

import codecs
import contextlib
import hashlib
import importlib
import importlib.util
import json
import logging
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile


# Additional manager entrypoints, on top of the observer contract checked by
# hermes-setup.py. These are from the same pinned Hermes v0.22.7 source.
_MANAGER_HASHES = {
    "hermes_bootstrap.py": "f242036b2d35b92283b9a7e97c7059e537607fc4b02026f657a6d00cb4683f69",
    "hermes_cli/__init__.py": "6a4ab05b8621ec1cd66a5abbe30fa32ed5bddddea95903036da01f0af1af94ce",
    "hermes_cli/_parser.py": "7b83ff7de334d2589006c6effbdebf49c21bc8110dfac50290d393fecabb6ed0",
    "hermes_cli/_subprocess_compat.py": "50b77ec24e7cc3772eb8cda170099b853058f4d939bf0cefa75ed1609ce000f2",
    "hermes_cli/_launchers.py": "4defa7fd066a8cb582befab800f39a9488289519125bc8ccc2e92b8e439e3311",
    "hermes_cli/steward.py": "d365372909dd2b14d769c8df2972f7b0871e8ce294c7b18707f70e1f310ff8a7",
    "hermes_cli/runtime_state.py": "f9d14de570770f05050a08d4a2c6a7fa0530caf51fa6230e5a4b750bcb4a6c1b",
    "hermes_cli/boot_bootstrap.py": "ff1cbe91e3ff860ac5c342df0fee581f9393c354f5ce4db3bdebdef332b31ebc",
    "hermes_cli/left_core_migration.py": "0350aec64b3d0ef98fe8ff7717396e1a49d6641e7dfd29180f58beb4a32ac2b0",
    "hermes_cli/memory_provider_migration.py": "280efcccf3ac6cf0f90d8a0f13c9008c213018267d938ad7c9ff6c120477f3fa",
    "hermes_cli/plugins_cmd_capabilities.py": "1322530460936f794e0b36cba11bafc87f592b7b0a9d713bb22bca9eb06d35f6",
    "hermes_cli/plugins_cmd_git.py": "e0a71fad2f8a3fc33b80ecff9e6afff00f59df60b57504e4b317927412588f38",
    "hermes_cli/plugins_cmd_install.py": "90bdb1442c85b6e3e22a0fc6c28d67fe68d17910b1a62e8bb3c1cd77e646bd9a",
    "hermes_cli/plugins_cmd_listing.py": "9f8ab0eb85f73dcf1d8e6acc8b270a38592789d30ae125299698e82a8726e7fc",
    "hermes_cli/plugins_cmd_remove.py": "bdb5cbc176d53c24f95c22ae1e98926b9568eff0486e24ce2d2dae20c9b72c3b",
    "hermes_cli/plugins_cmd_toggle.py": "561054775f12f146417c4cf5cd5e3c6cffac421734c5211af0026da3d0ad4095",
    "hermes_cli/plugins_cmd_update.py": "1614ad8bbdfee4d7dcd2ba1e769bcbd824f1d719b36488ba9c2db3a816ece548",
    "hermes_cli/plugins_manifest.py": "89b30e679247a628c7dad93c573afa9f3f22529015b26397de24f5067ff7fc06",
    "hermes_cli/plugin_capabilities.py": "06f8c85d8d7b70d51cab535f2501bd52519292151dfbfe5ce52579b984ce6ffa",
    "pm/__init__.py": "67adcba1f0e4db2b2967d07e6b630aca4214b1fac9bd8649dcf221b4bf3fcfac",
    "pm/install.py": "2f48a18bb2b8c452432ddd675599bb859e7a1dcdcbadd5326b252376d1b4b1a0",
    "pm/client.py": "8dcca7cd9ecce89f43122c89aa273dfdf6c8e6775e4a36c0ae5f3e5f815d46f1",
    "utils.py": "7add43a4e5b3bd042e95412e2d9bd2eddfd35a8a2628f4d5ba6f20dd5eca1877",
    "hermes_cli/main.py": "e8a2cf5da958e46f119b40cac90b99e24c6ab2b1d68858e64b44df604e9fbce5",
    "hermes_cli/_startup_fast.py": "94818a6fcf1f8607e1690a95c9f9042b57aa910ebc9631cf84def5402edf1536",
    "hermes_cli/_early_recovery.py": "23c9c5b1bcbf1aa9d7fa0c2b53c2bd6b37ece945323bef8fe87c35b5be2404a5",
    "hermes_cli/venv_sync.py": "7688851ccadc994bc3b799a4a25577edaf465b7553b8887892c8b36e1811ffe0",
    "hermes_cli/subcommands/plugins.py": "4c605eac125d603cf5d72e4f48e6191079210888bbb2dcf70722d98757b596f4",
    "hermes_cli/plugins_cmd.py": "dbad2e58e6894729182a45c7b8f5106c580dfa8ea66a7a3e03e4c9f500bf6c4f",
    "hermes_cli/plugins_admission.py": "a31daa6c326c5ba82ace6bcd3a2633db51e9a08768d610c5fce943292f370242",
    "hermes_cli/plugins_activation.py": "789c6a234a77b7761dab72335e5a210f151313843a50ef811f7f4f7257c51819",
    "pm/environments.py": "bfddba8093866c66fae12115389d78a2a65adc84f68b634a989775923c42268b",
    "pm/paths.py": "8f15860b82f443a424186317dc361ea6063e0e7c3113af9b56a76f6b89e97737",
    "pm/plugins_state.py": "0dfbd6eb29a1bc6b3ce20a5aa517d83d6846b15b417feebe850dab9b824f44b0",
    "pm/publication.py": "77d66b12e325b616ba14fcba687629ba361a0bd9e61f6175d22b87b6c8f94fcc",
}


class InvalidManagerRequest(Exception):
    pass


class UnconfirmedLocalConfig(InvalidManagerRequest):
    pass


class PendingHermesMaintenance(InvalidManagerRequest):
    pass


def _same_path(left, right):
    return os.path.normcase(os.path.abspath(str(left))) == os.path.normcase(os.path.abspath(str(right)))


def _has_home_expansion(value):
    # Hermes expands this value again after dotenv, so an unset variable now
    # could still change the selected home later in the same launch.
    return bool(re.search(r"\$(?:[A-Za-z0-9_]+|\{[^}]*\})", value) or
                (os.name == "nt" and re.search(r"%[^%]+%", value)))


def _load_setup(assets):
    script = assets / "hermes-setup.py"
    spec = importlib.util.spec_from_file_location("aitm_manual_hermes_setup", script)
    if spec is None or spec.loader is None:
        raise InvalidManagerRequest()
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    return setup


def _verify_manager(project, bundle):
    for name, expected in _MANAGER_HASHES.items():
        data = bundle._read(project.joinpath(*name.split("/")), 2_097_152)
        if hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest() != expected:
            raise InvalidManagerRequest()


def _verify_python(home, project, bundle):
    # Mirror discovery's committed environment or its legacy in-tree venv.
    key = hashlib.sha256(str(project).encode("utf-8")).hexdigest()[:16]
    install = home / "installs" / key
    facts = install / "facts.json"
    bundle._plain_path(facts, directory=False, missing=True)
    if facts.exists():
        data = json.loads(bundle._read(facts, 1_048_576))
        value = data["packages"]["venv"]["environment"]
        if not isinstance(value, str) or not os.path.isabs(value):
            raise InvalidManagerRequest()
        root = bundle._plain_path(install / "environments", directory=True)
        environment = bundle._plain_path(Path(value), directory=True)
        if not _same_path(os.path.commonpath((str(environment), str(root))), root) or _same_path(environment, root):
            raise InvalidManagerRequest()
    else:
        environment = next((project / name for name in ("venv", ".venv") if (project / name).is_dir()), None)
        if environment is None:
            raise InvalidManagerRequest()
        environment = bundle._plain_path(environment, directory=True)
    bundle._plain_path(environment / "pyvenv.cfg", directory=False)
    python = environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python3")
    if not python.is_file() or not _same_path(sys.executable, python):
        raise InvalidManagerRequest()
    return environment


def _reject_unconfirmed_environment():
    if os.environ.get("HERMES_MANAGED_DIR", "").strip():
        raise UnconfirmedLocalConfig()
    backend = os.environ.get("HERMES_CONFIG_BACKEND", "").strip().lower()
    if backend not in ("", "file"):
        raise UnconfirmedLocalConfig()
    # These can redirect bootstrap away from the verified checkout or store.
    if any(os.environ.get(name, "").strip() for name in
           ("HERMES_RUNTIME_DIR", "HERMES_INSTALL_ROOT", "HERMES_PYTHON_SRC_ROOT")):
        raise UnconfirmedLocalConfig()
    try:
        if stat.S_ISDIR(Path("/etc/hermes").stat().st_mode):
            raise UnconfirmedLocalConfig()
    except (FileNotFoundError, NotADirectoryError):
        pass
    except OSError:
        raise UnconfirmedLocalConfig() from None


def _validate(arguments, assets, setup):
    if len(arguments) != 4:
        raise InvalidManagerRequest()
    home_arg, project_arg, name, action = arguments
    if action not in ("enable", "disable") or not isinstance(name, str):
        raise InvalidManagerRequest()
    if name != "default" and (not setup._PROFILE.fullmatch(name) or name in setup._RESERVED):
        raise InvalidManagerRequest()
    if any(not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value)
           for value in (home_arg, project_arg)):
        raise InvalidManagerRequest()
    if home_arg != home_arg.strip() or _has_home_expansion(home_arg):
        raise UnconfirmedLocalConfig()
    _reject_unconfirmed_environment()
    home, project = setup._absolute(home_arg), setup._absolute(project_arg)
    if not _same_path(project, home / "hermes-agent"):
        raise InvalidManagerRequest()
    setup._verify_installation(project)
    _verify_manager(project, setup._bundle)
    _verify_python(home, project, setup._bundle)
    identifier = "root" if name == "default" else "profile:" + name
    matches = [item for item in setup._profiles(home) if item[0] == identifier]
    if len(matches) != 1 or setup._profile_state(*matches[0], assets).get("state") != "prepared":
        raise InvalidManagerRequest()
    return home, project, name, action


def _dotenv_snapshots(paths, bundle):
    """Bounded, in-memory snapshots; absent files are distinct from empty files."""
    result = {}
    for path in paths:
        path = bundle._plain_path(path, directory=False, missing=True)
        try:
            path.lstat()
        except FileNotFoundError:
            result[path] = None
            continue
        result[path] = bundle._read(path, 1_048_576)
    return result


def _reject_pending_maintenance(home, project, setup):
    bundle = setup._bundle
    key = hashlib.sha256(str(project).encode("utf-8")).hexdigest()[:16]
    install = home / "installs" / key
    markers = [project / ".update-incomplete", project / ".lazy-refresh-incomplete",
               project / ".hermes-update-zip-swap", install / ".repair-incomplete"]
    git = bundle._plain_path(project / ".git", missing=True)
    try:
        git_info = git.lstat()
    except FileNotFoundError:
        git_info = None
    if git_info is not None:
        if stat.S_ISREG(git_info.st_mode):
            value = bundle._read(git, 4096).decode("utf-8-sig").strip()
            if not value.startswith("gitdir:") or not value[7:].strip():
                raise PendingHermesMaintenance()
            git = bundle._plain_path(project / value[7:].strip(), directory=True)
        elif not stat.S_ISDIR(git_info.st_mode):
            raise PendingHermesMaintenance()
        markers.append(git / "hermes-update-pull")
    for marker in markers:
        bundle._plain_path(marker, missing=True)
        try:
            marker.lstat()
        except FileNotFoundError:
            continue
        raise PendingHermesMaintenance()
    # An orphaned update pause can restart another Hermes component on boot.
    for index, entry in enumerate(home.iterdir()):
        if index >= 10000:
            raise PendingHermesMaintenance()
        if entry.name.startswith(".hermes-update-paused-gateways.") and entry.name != ".hermes-update-paused-gateways.lock":
            raise PendingHermesMaintenance()
    facts = install / "facts.json"
    bundle._plain_path(facts, directory=False, missing=True)
    if facts.exists():
        # Missing selected site-packages makes upstream repair the environment
        # during startup, even when lazy synchronization has been disabled.
        environment = _verify_python(home, project, bundle)
        from pm.environments import site_packages
        bundle._plain_path(site_packages(environment), directory=True)


def _check_secret_sources(data):
    from ruamel.yaml import YAML

    parser = YAML(typ="safe", pure=True)
    parser.version = (1, 1)
    config = parser.load(data.decode("utf-8-sig"))
    if config is None:
        return
    if not isinstance(config, dict):
        raise UnconfirmedLocalConfig()
    for key, secrets in config.items():
        if not isinstance(key, str) or key.lower() != "secrets":
            continue
        if secrets is None:
            continue
        if not isinstance(secrets, dict):
            raise UnconfirmedLocalConfig()

        def no_expansions(value):
            if isinstance(value, str):
                return "${" not in value
            if isinstance(value, list):
                return all(no_expansions(item) for item in value)
            if isinstance(value, dict):
                return all(no_expansions(k) and no_expansions(v) for k, v in value.items())
            return value is None or isinstance(value, (bool, int, float))

        if not no_expansions(secrets):
            raise UnconfirmedLocalConfig()
        for source, settings in secrets.items():
            if not isinstance(source, str):
                raise UnconfirmedLocalConfig()
            if source.lower() == "sources" and isinstance(settings, list) and all(isinstance(item, str) for item in settings):
                continue
            if not isinstance(settings, dict):
                raise UnconfirmedLocalConfig()
            for setting, value in settings.items():
                if isinstance(setting, str) and setting.lower() == "enabled" and value is not None and value is not False:
                    raise UnconfirmedLocalConfig()


def _check_local_config(home, project, name, setup):
    """Accept only literal local selectors across every possible dotenv layer."""
    environment = _verify_python(home, project, setup._bundle)
    dotenv = importlib.import_module("dotenv")
    module_path = getattr(dotenv, "__file__", "")
    if (not module_path or not _same_path(os.path.commonpath((os.path.abspath(module_path), str(environment))), environment)):
        raise InvalidManagerRequest()
    loader = importlib.import_module("hermes_cli.env_loader")
    dotenv_main = importlib.import_module("dotenv.main")
    parser_logger = getattr(dotenv_main, "logger", None)
    if not isinstance(parser_logger, logging.Logger):
        raise UnconfirmedLocalConfig()
    profile = home if name == "default" else home / "profiles" / name
    paths = {home / ".env", home / ".op.env", profile / ".env", profile / ".op.env", project / ".env"}
    config_paths = {home / "config.yaml", profile / "config.yaml"}
    snapshots = _dotenv_snapshots(paths | config_paths, setup._bundle)
    checksums = {path: None if data is None else hashlib.sha256(data).digest() for path, data in snapshots.items()}
    original_read = Path.read_bytes
    old_disable = logging.root.manager.disable
    had_warning_override = "warning" in parser_logger.__dict__
    original_warning = parser_logger.__dict__.get("warning")

    def read_snapshot(path):
        if path not in snapshots:
            raise InvalidManagerRequest()
        value = snapshots[path]
        if value is None:
            raise FileNotFoundError()
        return value

    def invalid_dotenv(*_args, **_kwargs):
        raise UnconfirmedLocalConfig()

    try:
        # Use Hermes' actual dotenv decoder/tokenizer, without interpolation.
        # Checking every occurrence avoids relying on any launch or reload order.
        logging.disable(logging.CRITICAL)
        Path.read_bytes = read_snapshot
        parser_logger.warning = invalid_dotenv
        with open(os.devnull, "w", encoding="utf-8") as sink, \
                contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            for path in config_paths:
                if snapshots[path] is None:
                    raise UnconfirmedLocalConfig()
                _check_secret_sources(snapshots[path])
            for path in paths:
                data = snapshots[path]
                if data is None:
                    continue
                if data.startswith((codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE)):
                    raise UnconfirmedLocalConfig()
                if data.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
                    data.decode("utf-16")
                else:
                    data.decode("utf-8-sig")
                for key, value in loader._dotenv_assignments(path):
                    if not isinstance(key, str) or value is None:
                        continue
                    key = key.upper()  # Windows environment names are case-insensitive.
                    if key == "HERMES_CONFIG_BACKEND":
                        if value.strip().lower() not in ("", "file"):
                            raise UnconfirmedLocalConfig()
                    elif key == "HERMES_DISABLE_LAZY_INSTALLS":
                        if value.strip().lower() not in ("1", "true", "yes"):
                            raise UnconfirmedLocalConfig()
                    elif key in ("HERMES_MANAGED_DIR", "HERMES_RUNTIME_DIR", "HERMES_INSTALL_ROOT", "HERMES_PYTHON_SRC_ROOT"):
                        if value.strip():
                            raise UnconfirmedLocalConfig()
                    elif key == "HERMES_HOME":
                        expected = [profile] if path.parent == profile else [home]
                        if path.parent == project:
                            expected = [home, profile]
                        if not os.path.isabs(value) or not all(_same_path(value, item) for item in expected):
                            raise UnconfirmedLocalConfig()
    finally:
        Path.read_bytes = original_read
        if had_warning_override:
            parser_logger.warning = original_warning
        else:
            del parser_logger.warning
        logging.disable(old_disable)
        snapshots.clear()
    return checksums


def _recheck_dotenv(checksums, bundle):
    values = _dotenv_snapshots(checksums, bundle)
    try:
        for path, value in values.items():
            digest = None if value is None else hashlib.sha256(value).digest()
            if digest != checksums[path]:
                raise InvalidManagerRequest()
    finally:
        values.clear()


def _run(cache_prefix):
    try:
        if not sys.flags.isolated or not sys.dont_write_bytecode:
            raise InvalidManagerRequest()
        if any(name in ("ruamel", "dotenv", "hermes_bootstrap", "hermes_cli", "hermes_constants", "pm") or
               name.startswith(("ruamel.", "dotenv.", "hermes_cli.", "pm.")) for name in sys.modules):
            raise InvalidManagerRequest()
        assets = Path(__file__).resolve().parent
        setup = _load_setup(assets)
        home, project, name, action = _validate(sys.argv[1:], assets, setup)
        sys.path.insert(0, str(project))
        try:
            checksums = _check_local_config(home, project, name, setup)
        except Exception:
            raise UnconfirmedLocalConfig() from None
        try:
            _reject_pending_maintenance(home, project, setup)
        except Exception:
            raise PendingHermesMaintenance() from None
        # The bridge loads its own pinned parser. Do not leak that temporary
        # module into Hermes' normal dependency environment.
        for module in [key for key in sys.modules if key == "ruamel" or key.startswith("ruamel.")]:
            del sys.modules[module]
        os.environ["HERMES_HOME"] = str(home)
        os.environ["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        for variable in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
            os.environ.pop(variable, None)
        # Let Hermes construct and re-exec its own bootstrap with the actual
        # plugin-manager arguments and the terminal's standard streams.
        from hermes_cli._launchers import runtime_command
        arguments = ["-p", name, "plugins", action, "ai-task-monitor"]
        command = runtime_command(project, args=arguments, python=sys.executable, home=home)
        if (not isinstance(command, list) or len(command) != 4 + len(arguments)
                or not _same_path(command[0], sys.executable) or command[1:3] != ["-I", "-c"]
                or not isinstance(command[3], str) or command[4:] != arguments):
            raise InvalidManagerRequest()
        command[2:2] = ["-B", "-X", "pycache_prefix=" + cache_prefix]
        try:
            _recheck_dotenv(checksums, setup._bundle)
        except Exception:
            raise UnconfirmedLocalConfig() from None
        return subprocess.call(command)
    except PendingHermesMaintenance:
        message = ("AI Task Monitor: менеджер Hermes не запущен. Сначала завершите обновление или восстановление Hermes, "
                   "затем закройте Hermes и повторите попытку.")
        try:
            print(message, file=sys.stderr)
        except UnicodeError:
            print("AI Task Monitor: Hermes was not started. Finish the pending Hermes update or repair, then close it and retry.", file=sys.stderr)
        return 1
    except UnconfirmedLocalConfig:
        message = ("AI Task Monitor: менеджер Hermes не запущен. Проверьте локальные настройки: "
                   "удалённые, управляемые и динамические параметры, а также активные внешние источники ключей не поддерживаются.")
        try:
            print(message, file=sys.stderr)
        except UnicodeError:
            print("AI Task Monitor: Hermes was not started. Remote, managed, dynamic or external-secret configurations are unsupported.", file=sys.stderr)
        return 1
    except SystemExit as exc:
        if exc.code is None:
            return 0
        if isinstance(exc.code, int):
            return exc.code
    except Exception:
        pass
    print("AI Task Monitor: unable to verify or launch this Hermes installation.", file=sys.stderr)
    return 1


def main():
    try:
        # -B alone still reads existing bytecode. Isolate both this preflight
        # and Hermes' child from existing caches without writing secrets.
        with tempfile.TemporaryDirectory(prefix="aitm-hermes-pycache-") as cache_prefix:
            previous = sys.pycache_prefix
            sys.pycache_prefix = cache_prefix
            try:
                return _run(cache_prefix)
            finally:
                sys.pycache_prefix = previous
    except Exception:
        print("AI Task Monitor: unable to verify or launch this Hermes installation.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
