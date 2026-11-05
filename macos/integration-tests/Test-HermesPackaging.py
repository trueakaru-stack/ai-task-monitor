"""Check the source packaging list and third-party license without building an app."""

import hashlib
from pathlib import Path
import shlex
import zipfile


root = Path(__file__).resolve().parent.parent
source = (root / "scripts" / "build-app.sh").read_text(encoding="utf-8")
line = next(line for line in source.splitlines() if line.startswith("for file in ") and "hermes-setup.py" in line)
names = set(shlex.split(line.removeprefix("for file in ").removesuffix("; do")))
expected = {
    "hermes-setup.py", "hermes-manager.py", "provider_bundle.py", "hermes-entry.py", "hermes-plugin.yaml",
    "hermes_observer.py", "provider_hooks.py", "provider_sender.py", "provider_transport.py",
    "ruamel.yaml-0.18.16-py3-none-any.whl", "ruamel.yaml-LICENSE.txt",
}
assert expected <= names
assets = root / "integrations"
assert all((assets / name).is_file() for name in expected)
wheel = assets / "ruamel.yaml-0.18.16-py3-none-any.whl"
assert hashlib.sha256(wheel.read_bytes()).hexdigest() == "048f26d64245bae57a4f9ef6feb5b552a386830ef7a826f235ffb804c59efbba"
with zipfile.ZipFile(wheel) as archive:
    assert archive.read("ruamel.yaml-0.18.16.dist-info/licenses/LICENSE") == (assets / "ruamel.yaml-LICENSE.txt").read_bytes()
print("Hermes macOS packaging source and third-party license verified.")
