"""Apply one temporary safe-area change to a staged synthetic WindowGroup."""

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
app = source / "AITaskMonitorApp.swift"
root_view = source / "RootView.swift"
expected = {
    app: "16d8dcedd9ddcd3cea8a73c8224ec45a2080abf9",
    root_view: "bb0ac1a2faa252c41b74cb6283da537a23423598",
}
contents = {}
for path, known in expected.items():
    if not stat.S_ISREG(path.lstat().st_mode):
        raise SystemExit("Unsafe source file.")
    data = path.read_bytes()
    digest = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
    if digest != known:
        raise SystemExit("Unexpected staged source.")
    contents[path] = data.decode("utf-8")
old_app = "            RootView().environmentObject(store)"
new_app = "            RootView().environmentObject(store).ignoresSafeArea(.container, edges: .top)"
old_root = "            window.setContentSize(size)"
new_root = """            let frame = window.frame
            let resized = NSRect(x: frame.minX, y: frame.maxY - size.height,
                                 width: size.width, height: size.height)
            window.setFrame(resized, display: true)"""
if contents[app].count(old_app) != 1 or contents[root_view].count(old_root) != 1:
    raise SystemExit("The original window geometry was not found exactly once.")
app.write_text(contents[app].replace(old_app, new_app, 1), encoding="utf-8")
root_view.write_text(contents[root_view].replace(old_root, new_root, 1), encoding="utf-8")
print("Staged only the top safe-area and frame-sizing experiment.")
