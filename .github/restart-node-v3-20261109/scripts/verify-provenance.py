"""Pin the exact tested candidate modules and the one-line fixture correction."""
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def read_manifest(path):
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        checksum, name = line.split("  ", 1)
        if name in result:
            raise SystemExit("Duplicate manifest entry")
        result[name] = checksum
    return result
candidate = root / "candidate.sha256"
prior = root / "v2-staged.sha256"
if digest(candidate) != "2806821366bbce3a5e24dd6f3207fcb52ab7bd8bc5cd9e23f50e75bf0b855d21":
    raise SystemExit("Unexpected candidate manifest")
if digest(prior) != "c7fd3fcdf40ac3f82a64a886c567dcdba42c689163127d6be6f38863617f43cf":
    raise SystemExit("Unexpected prior CI manifest")
candidate_map = read_manifest(candidate)
prior_map = read_manifest(prior)
for name in ("provider-observers.mjs", "provider-events.mjs", "provider-transport.mjs"):
    path = "macos/integrations/" + name
    if digest(root / path) != candidate_map[path]:
        raise SystemExit("Candidate module changed: " + path)
for name in ("restart-v2-gate.mjs", "opencode-v2-subscription.test.mjs"):
    path = "synthetic/" + name
    if digest(root / path) != prior_map[path]:
        raise SystemExit("Prior synthetic fixture changed: " + path)
before = (root / "controls/restart-v2-gate-before.test.mjs").read_bytes()
if hashlib.sha256(before).hexdigest() != prior_map["synthetic/restart-v2-gate.test.mjs"]:
    raise SystemExit("Original restart fixture changed")
needle = b"'./integrations/provider-observers.mjs'"
replacement = b"'../macos/integrations/provider-observers.mjs'"
fixed = (root / "synthetic/restart-v2-gate.test.mjs").read_bytes()
if before.count(needle) != 1 or fixed != before.replace(needle, replacement):
    raise SystemExit("Fixture differs beyond the intended import correction")
if digest(root / "scripts/network-probe.py") != prior_map["scripts/network-probe.py"]:
    raise SystemExit("Prior network probe changed")
print("Pinned candidate modules and one-line synthetic import verified")
