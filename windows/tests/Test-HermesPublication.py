"""Test Hermes v0.22.7 PM config publication, not the full environment sync."""
import hashlib
import importlib
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import types

EXPECTED = {
    "hermes_cli/__init__.py": "6a4ab05b8621ec1cd66a5abbe30fa32ed5bddddea95903036da01f0af1af94ce",
    "hermes_cli/config_backend.py": "35e1c4a2cd8c1c9d6b90139a3df8a4a7c20eeb7409f12df7f54a34915d1972b7",
    "hermes_cli/plugin_capabilities.py": "06f8c85d8d7b70d51cab535f2501bd52519292151dfbfe5ce52579b984ce6ffa",
    "hermes_cli/plugins_manifest.py": "89b30e679247a628c7dad93c573afa9f3f22529015b26397de24f5067ff7fc06",
    "hermes_constants.py": "74d849629c176703d48f9aa43a245fd8819545ac908c805e347db7d691976510",
    "hermes_yaml.py": "f97f0f08b6474c52434d0cffaa7ba0ecaa5b9279c4abcbb35c11d15f9c89db76",
    "pm/__init__.py": "67adcba1f0e4db2b2967d07e6b630aca4214b1fac9bd8649dcf221b4bf3fcfac",
    "pm/downloader.py": "c488a7c6e3eef70af4621f8365c2b40250abd3c32efd73a4f3e5167a1909c754",
    "pm/environment.py": "e70ad2511c662b1caf1b4803f4cc7aaf430840af9880ffe5f4913aae9f12b16f",
    "pm/environments.py": "bfddba8093866c66fae12115389d78a2a65adc84f68b634a989775923c42268b",
    "pm/filesystem.py": "1f1a38aaf92e96c69c32690a3767de770b71976ac34e402d36b9e2987503efc7",
    "pm/install.py": "2f48a18bb2b8c452432ddd675599bb859e7a1dcdcbadd5326b252376d1b4b1a0",
    "pm/lock.py": "0ff1689d1d62cabb5d3ea753a126d71cb332218bfd0cd8e8cdda5b2d888b4666",
    "pm/network.py": "ae4e7726798d860f83527c3366dd16b8daec2bfb5e867a6d825161b1fe0d6574",
    "pm/package.py": "e9d9cbd20deddce9a96ba2f57a0f921350bfb4c919a0272cae09042b9200b921",
    "pm/paths.py": "8f15860b82f443a424186317dc361ea6063e0e7c3113af9b56a76f6b89e97737",
    "pm/plugin_declarations.py": "61653deba8381138655e1ac51b8f87a9012938de74b61b18b93e98b4de248e47",
    "pm/plugin_eviction.py": "c1cba8d6d76998092dea0be9ba3b1ea6787988f984c2b2d1cb8af93317c90f19",
    "pm/plugin_inputs.py": "5804dec5716ef7763aef37dab96183aca236500254cb574c0f591f167db430e2",
    "pm/plugins_state.py": "0dfbd6eb29a1bc6b3ce20a5aa517d83d6846b15b417feebe850dab9b824f44b0",
    "pm/progress.py": "b38f1acc7e2e5f7d159e4ff5e54f113df0957224e1e63b3471d51cdd08b8c341",
    "pm/publication.py": "77d66b12e325b616ba14fcba687629ba361a0bd9e61f6175d22b87b6c8f94fcc",
    "pm/registry.py": "1b50bd09c887667983cf85972dfb346a27cae15977927ab43fda187965735a0d",
    "pm/store.py": "e9cade3e602858511626e7d2f260a514cc9bdce1f5d8d9671e619d4f018a7041",
    "pm/workspace.py": "111f0bade0820c4ab9d52cf87999f048aeddb1258026dc1b93699f52e27522d4",
    "utils.py": "7add43a4e5b3bd042e95412e2d9bd2eddfd35a8a2628f4d5ba6f20dd5eca1877",
}

source = Path(sys.argv[1]).resolve(strict=True)
for name, digest in EXPECTED.items():
    if hashlib.sha256((source / name).read_bytes()).hexdigest() != digest:
        raise SystemExit("Unrecognized Hermes PM source fixture.")

project = Path(__file__).resolve().parent.parent
assets = project / ("app/integrations" if (project / "app/integrations").is_dir() else "integrations")

if len(sys.argv) == 2:
    with tempfile.TemporaryDirectory(prefix="aitm-hermes-pm-", dir=os.path.realpath(tempfile.gettempdir())) as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        env = {name: os.environ[name] for name in ("PATH", "SYSTEMROOT", "WINDIR") if name in os.environ}
        env.update({"HOME": str(root), "USERPROFILE": str(root), "LOCALAPPDATA": str(root),
                    "APPDATA": str(root), "HERMES_HOME": str(home), "XDG_STATE_HOME": str(root / "state"),
                    "HERMES_GATEWAY_LOCK_DIR": str(root / "locks"), "TMP": str(root), "TEMP": str(root),
                    "TMPDIR": str(root), "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"})
        subprocess.run([sys.executable, str(Path(__file__).resolve()), str(source), "--worker", str(root)],
                       env=env, check=True, timeout=30, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    print("Hermes 0.22.7 PM selection publication: isolation and conflict checks passed.")
    raise SystemExit(0)

root = Path(sys.argv[3]).resolve(strict=True)
home = root / "home"
sys.path.insert(0, str(source))
import pm.publication as publication
import pm.plugins_state as plugins_state
from hermes_yaml import roundtrip_yaml

assert publication.dependency_home_root().resolve() == home
config = home / "config.yaml"
config.write_text("# PRESERVE COMMENT\nplugins:\n  enabled: [zeta, alpha]\n  disabled: [parked]\n"
                  "  other_option: KEEP\nprivate_setting: KEEP\n", encoding="utf-8")
secondary = home / "profiles" / "two"
secondary.mkdir(parents=True)
secondary_config = secondary / "config.yaml"
secondary_config.write_text("plugins:\n  enabled: []\n  disabled: []\nforeign: KEEP\n", encoding="utf-8")
secondary_before = secondary_config.read_bytes()
assert secondary in plugins_state.dependency_homes()

package = types.ModuleType("aitm_hermes_publication_fixture")
package.__path__ = [str(assets)]
sys.modules[package.__name__] = package
bundles = importlib.import_module(package.__name__ + ".provider_bundle")
bundle = bundles.ProviderBundle("hermes", home)
assert bundle.install(assets, "hermes.observer.v1") == "staged"
for name in ("alpha", "zeta"):
    plugin = home / "plugins" / name
    plugin.mkdir()
    (plugin / "plugin.yaml").write_text(f"name: {name}\nversion: '1.0'\n", encoding="utf-8")
    (plugin / "foreign.txt").write_text("KEEP", encoding="utf-8")
fixture_project = root / "project"
fixture_project.mkdir()
publication.install_state_dir(fixture_project).mkdir(parents=True)

def select(enabled, disabled):
    value = config.read_bytes()
    return publication.PluginSelection({
        "home": str(home), "enabled": enabled, "disabled": disabled,
        "expected_config": hashlib.sha256(value).hexdigest(),
        "extra_dirs": [], "settled": ["ai-task-monitor"],
    })

selected = select(["zeta", "alpha", "ai-task-monitor"], ["parked"])
selected.publish(fixture_project)
yaml = roundtrip_yaml()
saved = yaml.load(config.read_text(encoding="utf-8"))
assert saved["plugins"]["enabled"] == ["ai-task-monitor", "alpha", "zeta"]
assert saved["plugins"]["disabled"] == ["parked"]
assert saved["plugins"]["other_option"] == saved["private_setting"] == "KEEP"
assert "# PRESERVE COMMENT" in config.read_text(encoding="utf-8")
assert secondary_config.read_bytes() == secondary_before

conflict = select(["alpha", "zeta"], ["parked", "ai-task-monitor"])
changed = secondary_before + b"concurrent: KEEP\n"
secondary_config.write_bytes(changed)
try:
    conflict.publish(fixture_project)
    raise AssertionError("The upstream PM overwrote a concurrent change.")
except ValueError:
    pass
assert secondary_config.read_bytes() == changed
assert "ai-task-monitor" in yaml.load(config.read_text(encoding="utf-8"))["plugins"]["enabled"]
secondary_config.write_bytes(secondary_before)

disabled = select(["alpha", "zeta"], ["parked", "ai-task-monitor"])
disabled.publish(fixture_project)
saved = yaml.load(config.read_text(encoding="utf-8"))
assert saved["plugins"]["enabled"] == ["alpha", "zeta"]
assert saved["plugins"]["disabled"] == ["ai-task-monitor", "parked"]
assert saved["plugins"]["other_option"] == saved["private_setting"] == "KEEP"
assert bundle.remove() == "absent"
for name in ("alpha", "zeta"):
    assert (home / "plugins" / name / "foreign.txt").read_text(encoding="utf-8") == "KEEP"
