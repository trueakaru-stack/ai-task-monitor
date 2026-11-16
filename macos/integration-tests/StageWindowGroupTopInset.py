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

path = root.parent / "source/macos/Sources/AITaskMonitor/AITaskMonitorApp.swift"
if not stat.S_ISREG(path.lstat().st_mode):
    raise SystemExit("Unsafe source file.")
data = path.read_bytes()
digest = hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()
if digest != "16d8dcedd9ddcd3cea8a73c8224ec45a2080abf9":
    raise SystemExit("Unexpected staged source.")
text = data.decode("utf-8")
old = "            RootView().environmentObject(store)"
new = "            RootView().environmentObject(store).ignoresSafeArea(.container, edges: .top)"
if text.count(old) != 1:
    raise SystemExit("The original WindowGroup root was not found exactly once.")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("Staged only the top safe-area experiment.")
