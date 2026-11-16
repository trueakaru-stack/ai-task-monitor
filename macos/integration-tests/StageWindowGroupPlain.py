"""Apply the plain WindowGroup style for an isolated diagnostic on macOS 15 or later."""

import errno
import hashlib
import os
from pathlib import Path
import re
import stat
import sys


env = os.environ
root_text = env.get("AITM_SYNTHETIC_TEST_ROOT", "")
marker = env.get("AITM_CI_DENIED_FILE", "")
root = Path(root_text)
if (sys.platform != "darwin" or env.get("CI") != "true" or env.get("GITHUB_ACTIONS") != "true"
        or env.get("RUNNER_ENVIRONMENT") != "github-hosted" or env.get("RUNNER_OS") != "macOS"
        or env.get("AITM_MACOS_TEST_SANDBOX") != "1" or "HOME" in env or "CODEX_HOME" in env
        or re.fullmatch(r"/Users/runner/work/_temp/aitm-card-tests\.[A-Za-z0-9]{8}/temp", root_text) is None
        or re.fullmatch(r"/Users/runner/work/_temp/aitm-profile-deny\.[A-Za-z0-9]{8}", marker) is None
        or root.resolve(strict=True) != root):
    raise SystemExit("An isolated synthetic test root is required.")
try:
    descriptor = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as error:
    if error.errno not in (errno.EACCES, errno.EPERM):
        raise SystemExit("Profile denial is not verified.")
else:
    os.close(descriptor)
    raise SystemExit("Profile access was not denied.")

project = root.parent / "source/macos/Sources/AITaskMonitor"
path = project / "AITaskMonitorApp.swift"
main_path = project / "main.swift"
if not stat.S_ISREG(path.lstat().st_mode) or not stat.S_ISREG(main_path.lstat().st_mode):
    raise SystemExit("Unsafe source file.")
data = path.read_bytes()
digest = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
if digest != "16d8dcedd9ddcd3cea8a73c8224ec45a2080abf9":
    raise SystemExit("Unexpected staged source.")
text = data.decode("utf-8")
if text.count("struct AITaskMonitorApp: App {") != 1 or text.count(".windowStyle(.hiddenTitleBar)") != 1:
    raise SystemExit("The original WindowGroup scene was not found exactly once.")
main_text = main_path.read_text(encoding="utf-8")
expected_main = """import Foundation
import SwiftUI

if CommandLine.arguments.contains("--claude-hook") {
    exit(ClaudeHook.run())
} else if let index = CommandLine.arguments.firstIndex(of: "--render-previews"), CommandLine.arguments.indices.contains(index + 1) {
    let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    exit(MainActor.assumeIsolated { SnapshotRenderer.run(outputDirectory: output) })
} else {
    guard MainActor.assumeIsolated({ SyntheticWindowGroupAudit.prepare() }) else { exit(78) }
    AITaskMonitorApp.main()
}
"""
if main_text != expected_main:
    raise SystemExit("Unexpected staged entry point.")
text = text.replace("struct AITaskMonitorApp: App {", "@available(macOS 15.0, *)\nstruct AITaskMonitorApp: App {", 1)
text = text.replace(".windowStyle(.hiddenTitleBar)", ".windowStyle(.plain)", 1)
main_text = main_text.replace("    AITaskMonitorApp.main()\n", """    if #available(macOS 15.0, *) {
        AITaskMonitorApp.main()
    } else {
        exit(78)
    }
""", 1)
path.write_text(text, encoding="utf-8")
main_path.write_text(main_text, encoding="utf-8")
print("Staged only the plain style in an isolated macOS 15 or later diagnostic.")
