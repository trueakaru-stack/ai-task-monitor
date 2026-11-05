"""Prepare only this monitor's plugin for a verified Hermes source installation.

The user enables or disables the plugin using Hermes's own manager after
closing Hermes. This bridge never starts Hermes or modifies its configuration.
It accepts a bounded JSON request on stdin and emits only fixed status codes,
profile names and monitor-owned opaque scopes.
"""

import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import types


_PACKAGE = "aitm_hermes_setup"
_package = types.ModuleType(_PACKAGE)
_package.__path__ = [str(Path(__file__).resolve().parent)]
sys.modules[_PACKAGE] = _package
_bundle = importlib.import_module(_PACKAGE + ".provider_bundle")

# Contract tested against the upstream v0.22.7 source at b200f5bc. Normalize
# checkout line endings, but refuse a modified or unrecognized dispatcher.
_SOURCE_HASHES = {
    "hermes_cli/middleware.py": "d563bca8757d3e9e2766db905d457fdc96de427d873b40d48e3a624f78d7c589",
    "hermes_cli/plugins.py": "0da0ebe88da76f4a73d77fcc6942ef549154abbc573d52d74c1608bcb61efce4",
    "hermes_cli/plugins_dispatch.py": "aa12d2c3b48f0af1cfcb837a0b67459c59172b0d40825b7f9b6c09076e141742",
    "hermes_cli/lifecycle.py": "86fe6336a6c887bc874b9e801ad67fc3612422feb5996c6453cd75b18d7b5769",
    "agent/turn_api_request.py": "690e66223a6b6863a8404aa2f84e22ececb52132dc8baf1d1836a685534b3e4c",
    "agent/turn_finalizer.py": "44d5b86f2f76c8668cf28ac853b3a29347223ece9e1b3d4ce3abf2fddd1ae49c",
    "tools/human_input_hooks.py": "cdec5a656ddead7b3d379ba995323a03cad75fe61ec8d4ec168a27bc4fa72b6f",
    "agent/conversation_loop.py": "bc1a44a42e254c9500cee099aa0d81590534aecb0ae6986f0f5bce6f24849d49",
    "model_tools.py": "24850d5ce74f7bcf17e58638fc787d6b955bfb89f4980e74b361d7927de74581",
    "hermes_cli/cli_shutdown.py": "d6673522f6edba02dda2491732e3fd0ec140e77bc6bd2e5951018d611b9043a0",
    "hermes_cli/cli_session_mixin.py": "96c8698dd0ba773e5bc5938cf6e37bdbc83c4eeceef12a73cd32f32b89472e02",
    "hermes_cli/plugins_discovery.py": "08731e1f0f932edda7e74af4bae4c2f16870ade04b8fc31173380544bc42baf8",
    "hermes_cli/config.py": "53063c14fb03540ceb73f296e72ba2e1f71c0b0ce98e88f435fcfedf79d3355f",
    "hermes_cli/config_backend.py": "35e1c4a2cd8c1c9d6b90139a3df8a4a7c20eeb7409f12df7f54a34915d1972b7",
    "hermes_cli/managed_scope.py": "1c5d16b92952a0101cb8ee8f0f70cf7cd2d19faffe224f9ca1b52dd29e794ed2",
    "hermes_yaml.py": "f97f0f08b6474c52434d0cffaa7ba0ecaa5b9279c4abcbb35c11d15f9c89db76",
    "hermes_cli/env_loader.py": "b4ba716b5e9d73ccbbc16f507b366ffad0c02bbf12d164568ca32461bf858e11",
    "hermes_cli/config_defaults.py": "2c7f02045f582d03565dbb59972f09fc21fcac71a26adb5117d5754759ccb634",
    "hermes_cli/profiles.py": "9d3879d8bba807f03249b82595e8082116613c5e205cb902c67a825bece22e46",
    "hermes_constants.py": "74d849629c176703d48f9aa43a245fd8819545ac908c805e347db7d691976510",
    "agent/tool_executor.py": "c85e239d1d56ad415902db2371e9e28c2216f6fd72e29860cff7f97b2e05a0c2",
}
_PROFILE = re.compile(r"[a-z0-9][a-z0-9_-]{0,63}\Z", re.ASCII)
_RESERVED = frozenset({"hermes", "default", "test", "tmp", "root", "sudo"})
_MAX_REQUEST = 8192
_MAX_PROFILES = 256
_YAML_WHEEL = "ruamel.yaml-0.18.16-py3-none-any.whl"
_YAML_SHA256 = "048f26d64245bae57a4f9ef6feb5b552a386830ef7a826f235ffb804c59efbba"


class SetupError(Exception):
    pass


def _absolute(value):
    if not isinstance(value, str) or not value or not os.path.isabs(value):
        raise SetupError("invalid-request")
    return _bundle._plain_path(Path(value), directory=True)


def _verify_installation(project):
    for name, expected in _SOURCE_HASHES.items():
        data = _bundle._read(project.joinpath(*name.split("/")), 2_097_152)
        actual = hashlib.sha256(data.replace(b"\r\n", b"\n")).hexdigest()
        if actual != expected:
            raise SetupError("unsupported-version")


def _enabled_selection(profile, assets):
    """Read bounded local configuration and return only the plugin's enabled state."""
    try:
        wheel = assets / _YAML_WHEEL
        if _bundle._digest(_bundle._read(wheel)) != _YAML_SHA256:
            raise SetupError("profile-unavailable")
        # Import only the pinned, unmodified MIT-licensed wheel packaged with
        # the monitor; never execute the user's installed site-packages.
        if "ruamel" not in sys.modules:
            package = types.ModuleType("ruamel")
            package.__path__ = [str(wheel) + "/ruamel"]
            package.__package__ = "ruamel"
            sys.modules["ruamel"] = package
        from ruamel.yaml import YAML
        from ruamel.yaml.error import YAMLError
        raw = _bundle._read(profile / "config.yaml", 1_048_576)
        try:
            parser = YAML(typ="safe", pure=True)
            parser.version = (1, 1)
            config = parser.load(raw.decode("utf-8-sig"))
        except (YAMLError, UnicodeError):
            raise SetupError("profile-unavailable") from None
        if config is None:
            config = {}
        if not isinstance(config, dict):
            raise SetupError("profile-unavailable")
        plugins = config.get("plugins")
        if plugins is None:
            plugins = {}
        if not isinstance(plugins, dict):
            raise SetupError("profile-unavailable")
        enabled, disabled = plugins.get("enabled"), plugins.get("disabled")
        enabled = [] if enabled is None else enabled
        disabled = [] if disabled is None else disabled
        if (not isinstance(enabled, list) or not isinstance(disabled, list)
                or any(not isinstance(item, str) or "${" in item for item in enabled + disabled)):
            raise SetupError("profile-unavailable")
        return "ai-task-monitor" in enabled and "ai-task-monitor" not in disabled
    except (ImportError, _bundle.BundleError, OSError):
        raise SetupError("profile-unavailable") from None


def _profiles(home):
    _bundle._plain_path(home / "config.yaml", directory=False)
    found = [("root", "default", home)]
    directory = home / "profiles"
    _bundle._plain_path(directory, directory=True, missing=True)
    if not directory.exists():
        return found
    entries = list(directory.iterdir())
    if len(entries) >= _MAX_PROFILES:
        raise SetupError("too-many-profiles")
    for entry in sorted(entries, key=lambda value: value.name):
        if not _PROFILE.fullmatch(entry.name) or entry.name in _RESERVED:
            continue
        _bundle._plain_path(entry, directory=True)
        if _profile_deleted(directory, entry.name):
            continue
        found.append(("profile:" + entry.name, entry.name, entry))
    return found


def _profile_deleted(directory, name):
    tombstones = directory / ".deleted"
    _bundle._plain_path(tombstones, directory=True, missing=True)
    try:
        if not tombstones.is_dir():
            return False
        marker = tombstones / name
        _bundle._plain_path(marker, missing=True)
        marker.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError:
        raise SetupError("profile-unavailable") from None


def _profile_state(profile_id, name, path, assets):
    try:
        bundle = _bundle.ProviderBundle("hermes", path)
        enabled = _enabled_selection(path, assets)
        marker = bundle._owned()
        if marker is None:
            return {"id": profile_id, "name": name, "state": "absent"}
        for source, target in bundle.spec["files"].items():
            if _bundle._digest(_bundle._read(assets / source)) != marker["files"][target]:
                raise SetupError("modified-bundle")
        metadata = json.loads(_bundle._read(bundle.folder / "monitor-profile.json", 256))
        return {"id": profile_id, "name": name, "state": "prepared", "scope": metadata["namespace"], "enabled": enabled}
    except (SetupError, _bundle.BundleError, OSError, ValueError, TypeError, KeyError):
        return {"id": profile_id, "name": name, "state": "error", "error": "profile-unavailable"}


def perform(request):
    if not isinstance(request, dict) or set(request) - {"action", "home", "project", "assets", "profile", "managed"}:
        raise SetupError("invalid-request")
    managed = request.get("managed", False)
    if type(managed) is not bool:
        raise SetupError("invalid-request")
    if managed:
        raise SetupError("managed-config-unconfirmed")
    try:
        default_managed = Path("/etc/hermes").stat()
        if stat.S_ISDIR(default_managed.st_mode):
            raise SetupError("managed-config-unconfirmed")
    except (FileNotFoundError, NotADirectoryError):
        pass
    except OSError:
        raise SetupError("managed-config-unconfirmed") from None
    action = request.get("action")
    if action not in ("list", "prepare"):
        raise SetupError("invalid-request")
    home = _absolute(request.get("home"))
    project = _absolute(request.get("project"))
    assets = _absolute(request.get("assets"))
    _verify_installation(project)
    profiles = _profiles(home)
    if action == "list":
        if "profile" in request:
            raise SetupError("invalid-request")
        return [_profile_state(identifier, name, path, assets) for identifier, name, path in profiles]
    wanted = request.get("profile")
    choices = [item for item in profiles if item[0] == wanted]
    if len(choices) != 1:
        raise SetupError("invalid-profile")
    selected = choices[0][2]
    def verify_profile():
        if wanted != "root" and _profile_deleted(home / "profiles", selected.name):
            raise SetupError("invalid-profile")
    verify_profile()
    _enabled_selection(selected, assets)
    _bundle.ProviderBundle("hermes", selected).install(assets, "hermes.observer.v1", before_commit=verify_profile)
    verify_profile()
    result = _profile_state(*choices[0], assets)
    if result["state"] != "prepared":
        raise SetupError("operation-failed")
    return "prepared"


def main():
    try:
        raw = sys.stdin.buffer.read(_MAX_REQUEST + 1)
        if len(raw) > _MAX_REQUEST:
            raise SetupError("invalid-request")
        result = perform(json.loads(raw.decode("utf-8")))
        print(json.dumps({"ok": True, "result": result}, ensure_ascii=True, separators=(",", ":")))
    except (SetupError, _bundle.BundleError) as error:
        allowed = {"invalid-request", "invalid-profile", "unsupported-version", "too-many-profiles", "modified-bundle", "profile-unavailable", "managed-config-unconfirmed",
                   "bundle-conflict", "bundle-busy", "bundle-update-required", "operation-failed"}
        code = str(error)
        print(json.dumps({"ok": False, "error": code if code in allowed else "operation-failed"}, separators=(",", ":")))
    except (OSError, ValueError, TypeError, KeyError, UnicodeError):
        print('{"ok":false,"error":"operation-failed"}')
    except Exception:
        # Never expose profile contents, paths, or third-party parser diagnostics.
        print('{"ok":false,"error":"operation-failed"}')


if __name__ == "__main__":
    main()
