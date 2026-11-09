"""Fail closed if an otherwise disposable runner has agent profiles or CLIs."""
import os
from pathlib import Path
import pwd
import sys

if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
    os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("RUNNER_OS") != "macOS"):
    raise SystemExit("Startup requires a disposable hosted macOS runner")
temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
synthetic = Path(os.environ["AITM_SYNTHETIC_HOME"]).resolve(strict=True)
if synthetic.parent != temp or synthetic.name != "aitm-package-home":
    raise SystemExit("Unexpected synthetic home")
account_dir = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True)
profiles = (".codex", ".claude", ".config/opencode", ".opencode", ".dsh", ".kimi-code", ".hermes")
for base in {account_dir, synthetic}:
    for relative in profiles:
        if os.path.lexists(base / relative):
            raise SystemExit("Runner is not free of agent profile data")
    if os.path.lexists(base / ".nvm/versions/node"):
        raise SystemExit("Runner contains per-version Node installations")
    for relative in (".local/bin", ".nvm/current/bin", ".volta/bin", ".npm-global/bin"):
        for name in ("codex", "claude", "opencode", "dsh", "kimi"):
            if os.path.lexists(base / relative / name):
                raise SystemExit("Runner contains an agent command")
for directory in ("/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"):
    for name in ("codex", "claude", "opencode", "dsh", "kimi"):
        if os.path.lexists(Path(directory) / name):
            raise SystemExit("Runner contains an agent command")
if any(os.path.lexists(path) for path in ("/Applications/Codex.app", "/Applications/Claude.app", "/etc/hermes")):
    raise SystemExit("Runner contains an agent installation or managed configuration")
if os.path.lexists("/private/tmp/aitm-provider-" + str(os.getuid())):
    raise SystemExit("Default provider channel already exists")
print("No known agent profiles, CLI entries, managed Hermes config or provider channel were found")
print("The check covers listed locations only; it is not a proof of complete filesystem isolation")
