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
manager_tree = ast.parse((fixture_dir.parent / "integrations" / "hermes-manager.py").read_text(encoding="utf-8"))
expected.update(next(
    ast.literal_eval(node.value)
    for node in manager_tree.body
    if isinstance(node, ast.Assign)
    and any(isinstance(target, ast.Name) and target.id == "_MANAGER_HASHES" for target in node.targets)
))
expected.update({
    "hermes_cli/middleware.py": "d563bca8757d3e9e2766db905d457fdc96de427d873b40d48e3a624f78d7c589",
    "hermes_cli/plugins_dispatch.py": "aa12d2c3b48f0af1cfcb837a0b67459c59172b0d40825b7f9b6c09076e141742",
    "hermes_cli/plugins.py": "0da0ebe88da76f4a73d77fcc6942ef549154abbc573d52d74c1608bcb61efce4",
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
