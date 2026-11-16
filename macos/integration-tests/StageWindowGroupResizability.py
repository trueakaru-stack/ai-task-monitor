"""Stage a safe, isolated WindowGroup resizability comparison on macOS CI."""

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

source = root.parent / "source/macos/Sources/AITaskMonitor"
if len(sys.argv) != 2 or sys.argv[1] not in ("fixture", "candidate"):
    raise SystemExit("Expected fixture or candidate mode.")
if sys.argv[1] == "fixture":
    path = source / "SyntheticWindowGroupAudit.swift"
    if not stat.S_ISREG(path.lstat().st_mode):
        raise SystemExit("Unsafe fixture file.")
    data = path.read_bytes()
    digest = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    if digest != "8442038cb54d6babebc08ed908ffc8afb167ab18":
        raise SystemExit("Unexpected synthetic fixture.")
    text = data.decode("utf-8")
    edits = [
        ("""        let variant = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"]
        let topInset = variant == "baseline" ? view.safeAreaInsets.top : 0
""", """        let topInset = view.safeAreaInsets.top
"""),
        ("""        let variant = ProcessInfo.processInfo.environment["AITM_WINDOWGROUP_VARIANT"]
        let inset = variant == "baseline" ? view.safeAreaInsets.top : 0
""", """        let inset = view.safeAreaInsets.top
"""),
        ("""                            try capture("after", toggleMethod: method)
                            exerciseControls()
""", """                            try capture("after", toggleMethod: method)
                            exerciseResize()
"""),
    ]
    resize = """    @MainActor private static func exerciseResize() {
        do {
            guard let output, let store = activeStore else { throw FixtureError.unsafeEnvironment }
            let window = try activeWindow()
            let original = window.frame
            let requested = NSRect(x: original.minX, y: original.minY - 40,
                                   width: original.width + 60, height: original.height + 40)
            let resizable = window.styleMask.contains(.resizable)
            let minimum = [Double(window.minSize.width), Double(window.minSize.height)]
            let maximum = [Double(window.maxSize.width), Double(window.maxSize.height)]
            let compact = store.isCompact
            window.setFrame(requested, display: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let observed = window.frame
                window.setFrame(original, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    do {
                        let restored = window.frame
                        let report: [String: Any] = [
                            "compact": compact,
                            "resizableStyle": resizable,
                            "minSize": minimum,
                            "maxSize": maximum,
                            "before": [Double(original.width), Double(original.height)],
                            "requested": [Double(requested.width), Double(requested.height)],
                            "observedAfterDelay": [Double(observed.width), Double(observed.height)],
                            "restoredAfterDelay": [Double(restored.width), Double(restored.height)]
                        ]
                        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        try write(data, name: "windowgroup-programmatic-resize.json", in: output)
                        exerciseControls()
                    } catch {
                        FileHandle.standardError.write(Data("Synthetic resize report failed.\\n".utf8))
                        exit(1)
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("Synthetic resize setup failed.\\n".utf8))
            exit(1)
        }
    }

"""
    anchor = "    @MainActor private static func exerciseControls() {\n"
    edits.append((anchor, resize + anchor))
    for old, new in edits:
        if text.count(old) != 1:
            raise SystemExit("Synthetic helper replacement was not found exactly once.")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print("Added programmatic resizing observation to the synthetic fixture.")
else:
    path = source / "AITaskMonitorApp.swift"
    if not stat.S_ISREG(path.lstat().st_mode):
        raise SystemExit("Unsafe source file.")
    data = path.read_bytes()
    digest = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    if digest != "16d8dcedd9ddcd3cea8a73c8224ec45a2080abf9":
        raise SystemExit("Unexpected staged scene.")
    text = data.decode("utf-8")
    old = "        .windowStyle(.hiddenTitleBar)\n"
    new = "        .windowStyle(.hiddenTitleBar)\n        .windowResizability(.contentSize)\n"
    if text.count(old) != 1:
        raise SystemExit("The original window style was not found exactly once.")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print("Staged only the contentSize window resizability experiment.")
