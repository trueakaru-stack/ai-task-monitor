"""Extract only the hash-pinned Hermes files needed by isolated integration tests."""

import ast
import hashlib
from pathlib import Path
import sys
import tarfile


commit = "b200f5bc60e31588ba2cb60e288029c4a54ba5fa"
fixture_dir = Path(__file__).resolve().parent
tree = ast.parse((fixture_dir / "Test-HermesPublication.py").read_text(encoding="utf-8"))
expected = next(
    ast.literal_eval(node.value)
    for node in tree.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "EXPECTED" for target in node.targets)
)
expected.update({
    "hermes_cli/middleware.py": "d563bca8757d3e9e2766db905d457fdc96de427d873b40d48e3a624f78d7c589",
    "hermes_cli/plugins_dispatch.py": "aa12d2c3b48f0af1cfcb837a0b67459c59172b0d40825b7f9b6c09076e141742",
    "hermes_cli/active_sessions.py": "0e3bd5dd93281f4d392850550a8d8bf94b213f965dccd6159513fa5bc6466fb7",
})
destination = Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=False)
with tarfile.open(sys.argv[1], "r:gz") as archive:
    for name, digest in expected.items():
        member = archive.getmember(f"hermes-agent-{commit}/{name}")
        if not member.isfile() or member.size > 2_000_000:
            raise SystemExit("Unsafe Hermes fixture entry.")
        stream = archive.extractfile(member)
        if stream is None:
            raise SystemExit("Missing Hermes fixture entry.")
        with stream:
            data = stream.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit("Unrecognized Hermes fixture entry.")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
print(f"Extracted and verified {len(expected)} pinned Hermes fixture files.")
