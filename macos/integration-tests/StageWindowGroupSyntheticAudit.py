"""Stage the real WindowGroup with synthetic data only for an isolated CI audit."""

import errno
import hashlib
import os
from pathlib import Path
import re
import stat
import sys


def git_blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


env = os.environ
if (sys.platform != "darwin" or env.get("CI") != "true" or env.get("GITHUB_ACTIONS") != "true"
        or env.get("RUNNER_ENVIRONMENT") != "github-hosted" or env.get("RUNNER_OS") != "macOS"
        or env.get("AITM_MACOS_TEST_SANDBOX") != "1" or "HOME" in env or "CODEX_HOME" in env):
    raise SystemExit("An isolated disposable macOS runner is required.")

root_text = env.get("AITM_SYNTHETIC_TEST_ROOT", "")
marker_text = env.get("AITM_CI_DENIED_FILE", "")
root = Path(root_text)
if (re.fullmatch(r"/Users/runner/work/_temp/aitm-card-tests\.[A-Za-z0-9]{8}/temp", root_text) is None
        or re.fullmatch(r"/Users/runner/work/_temp/aitm-profile-deny\.[A-Za-z0-9]{8}", marker_text) is None
        or str(root) != root_text or root.resolve(strict=True) != root):
    raise SystemExit("Unsafe synthetic paths.")
current = Path("/")
for part in root.parts[1:]:
    current /= part
    if not stat.S_ISDIR(current.lstat().st_mode):
        raise SystemExit("Redirected synthetic path.")
try:
    descriptor = os.open(marker_text, os.O_RDONLY | os.O_NOFOLLOW)
except OSError as error:
    if error.errno not in (errno.EACCES, errno.EPERM):
        raise SystemExit("Profile guard did not return an access denial.")
else:
    os.close(descriptor)
    raise SystemExit("Profile guard did not block reads.")

project = root.parent / "source/macos"
if project.resolve(strict=True) != project:
    raise SystemExit("Redirected source tree.")
source = project / "Sources/AITaskMonitor"
expected = {
    "main.swift": "d4040bdb2d8561614b583cc25aa16eb21f48aaca",
    "AITaskMonitorApp.swift": "b25e7bc4e99c233254847f8bff904f1d659431f7",
    "TaskStore.swift": "f06d7c5475d9d3c1b94fdee839eb128b61e97385",
    "RootView.swift": "2942794b8437eed43ef6587540a2d68e50f661a2",
}
files = {}
for name, digest in expected.items():
    path = source / name
    if not stat.S_ISREG(path.lstat().st_mode):
        raise SystemExit("Unsafe source file.")
    data = path.read_bytes()
    if git_blob(data) != digest:
        raise SystemExit("Unexpected source version.")
    files[name] = data.decode("utf-8")

def replace_once(name, old, new):
    text = files[name]
    if text.count(old) != 1:
        raise SystemExit("The synthetic replacement does not match exactly once.")
    files[name] = text.replace(old, new, 1)

replace_once("main.swift", "    AITaskMonitorApp.main()",
             "    guard MainActor.assumeIsolated({ SyntheticWindowGroupAudit.prepare() }) else { exit(78) }\n"
             "    AITaskMonitorApp.main()")
replace_once("AITaskMonitorApp.swift",
             "    @StateObject private var store = TaskStore(enableUpdateChecks: true, enableClaudeRetention: true, enableExternalProviders: true, enableExternalV2: true, enableCodexCloud: true)",
             "    @StateObject private var store = SyntheticWindowGroupAudit.makeStore()\n"
             "    init() { SyntheticWindowGroupAudit.schedule() }")
replace_once("TaskStore.swift",
             "@Published private(set) var claudeRetentionPolicy: ClaudeRetentionPolicy? = ClaudeRetentionPolicy.load()",
             "@Published private(set) var claudeRetentionPolicy: ClaudeRetentionPolicy? = nil")
replace_once("RootView.swift",
             '@AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue',
             '@State private var appearanceRaw = ProcessInfo.processInfo.environment["AITM_SYNTHETIC_APPEARANCE"] ?? "light"')
replace_once("RootView.swift",
             '@AppStorage("languageMode") private var languageRaw = AppLanguage.system.rawValue',
             '@State private var languageRaw = AppLanguage.ru.rawValue')
replace_once("RootView.swift", "preferredLanguages: Locale.preferredLanguages",
             'preferredLanguages: ["ru"]')

replace_once("RootView.swift",
             "    private func configure(_ window: NSWindow?, coordinator: Coordinator) {\n        guard let window else { return }",
             '    private func configure(_ window: NSWindow?, coordinator: Coordinator) {\n'
             '        FileHandle.standardError.write(Data("AITM_CONFIG windowIsNil=\\(window == nil)\\n".utf8))\n'
             '        guard let window else { return }')
replace_once("RootView.swift",
             "        defer { coordinator.isApplying = false }",
             '        defer {\n'
             '            coordinator.isApplying = false\n'
             '            FileHandle.standardError.write(Data("AITM_CONFIG after frame=\\(window.frame) min=\\(window.minSize) max=\\(window.maxSize) level=\\(window.level.rawValue) movable=\\(window.isMovableByWindowBackground)\\n".utf8))\n'
             '        }')
replace_once("RootView.swift",
             "        let size = isCompact ? NSSize(width: 372, height: compactHeight) : NSSize(width: 560, height: 700)",
             '        let size = isCompact ? NSSize(width: 372, height: compactHeight) : NSSize(width: 560, height: 700)\n'
             '        FileHandle.standardError.write(Data("AITM_CONFIG before compact=\\(isCompact) desired=\\(size) frame=\\(window.frame) min=\\(window.minSize) max=\\(window.maxSize)\\n".utf8))')

replace_once("RootView.swift",
             "        guard let window else { return }\n        coordinator.observe(window)",
             "        guard let window else { return }\n"
             "        SyntheticWindowGroupAudit.observeWindow(window)\n"
             "        coordinator.observe(window)")

helper = project / "integration-tests/WindowGroupSyntheticAudit.swift"
target = source / "SyntheticWindowGroupAudit.swift"
if not stat.S_ISREG(helper.lstat().st_mode) or target.exists() or target.is_symlink():
    raise SystemExit("Unsafe synthetic helper.")
for name, text in files.items():
    (source / name).write_text(text, encoding="utf-8")
with target.open("xb") as stream:
    stream.write(helper.read_bytes())
print("Staged exact WindowGroup with synthetic store and in-memory settings.")
