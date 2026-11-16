#!/bin/bash
set -euo pipefail
test "$CI" = true
test "$GITHUB_ACTIONS" = true
test "$RUNNER_ENVIRONMENT" = github-hosted
test "$RUNNER_OS" = macOS
test "$DOTNET_ADD_GLOBAL_TOOLS_TO_PATH" = 0
repo="$AITM_DIAGNOSTIC_SOURCE"
root="$AITM_DIAGNOSTIC_ROOT"
test -d "$root"
mkdir "$root/old" "$root/current" "$root/legacy-schedule" "$root/tmp" "$root/profile"
git -C "$repo" show 'c034eef660922c9a06ee601e6ab9f8eac22b7889:macos/Sources/AITaskMonitor/ReleaseUpdates.swift' > "$root/old/ReleaseUpdates.swift"
git -C "$repo" show 'c034eef660922c9a06ee601e6ab9f8eac22b7889:macos/Sources/AITaskMonitor/TaskStore.swift' > "$root/legacy-schedule/TaskStore.swift"
git -C "$repo" show '3457773aeec8c5ac0e22c42a31cde44aaecc4160:macos/Sources/AITaskMonitor/ReleaseUpdates.swift' > "$root/current/ReleaseUpdates.swift"
git -C "$repo" show '3457773aeec8c5ac0e22c42a31cde44aaecc4160:macos/Sources/AITaskMonitor/ReleaseRetrySchedule.swift' > "$root/current/ReleaseRetrySchedule.swift"
git -C "$repo" show '3457773aeec8c5ac0e22c42a31cde44aaecc4160:macos/Sources/AITaskMonitor/ReleaseScheduleFileStore.swift' > "$root/current/ReleaseScheduleFileStore.swift"
cp "$repo/update-diagnosis/mac-old-main.swift" "$root/old/main.swift"
cp "$repo/update-diagnosis/mac-current-main.swift" "$root/current/main.swift"
developer=$(/usr/bin/xcode-select -p)
profile='(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket))'
run_fixture() {
  /usr/bin/env -i "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "DEVELOPER_DIR=$developer" \
    "TMPDIR=$root/tmp/" "CFFIXED_USER_HOME=$root/profile" \
    'DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=0' 'DOTNET_GENERATE_ASPNET_CERTIFICATE=0' \
    /usr/bin/sandbox-exec -p "$profile" "$@"
}
run_fixture /usr/bin/python3 -I -S -B - "$repo" "$root" <<'PY'
import pathlib, re, sys
repo, root = map(pathlib.Path, sys.argv[1:])
text = (root / "legacy-schedule/TaskStore.swift").read_text(encoding="utf-8")
matches = list(re.finditer(r"(?ms)^    func checkForUpdates\(now: Date = Date\(\)\) \{\n.*?^    \}", text))
if len(matches) != 1:
    raise SystemExit("Expected one original legacy scheduling method")
before = (repo / "update-diagnosis/mac-schedule-pre.swift.txt").read_text(encoding="utf-8")
after = (repo / "update-diagnosis/mac-schedule-post.swift.txt").read_text(encoding="utf-8")
(root / "legacy-schedule/main.swift").write_text(before + matches[0].group() + "\n" + after, encoding="utf-8")
PY
run_fixture /usr/bin/xcrun swiftc "$root/old/ReleaseUpdates.swift" "$root/old/main.swift" -o "$root/old/test"
run_fixture "$root/old/test" "$repo/update-diagnosis/release-fixture.json"
run_fixture /usr/bin/xcrun swiftc "$root/current/ReleaseUpdates.swift" "$root/current/ReleaseRetrySchedule.swift" "$root/current/ReleaseScheduleFileStore.swift" "$root/current/main.swift" -o "$root/current/test"
run_fixture "$root/current/test" "$repo/update-diagnosis/release-fixture.json"
run_fixture /usr/bin/xcrun swiftc "$root/legacy-schedule/main.swift" -o "$root/legacy-schedule/test"
run_fixture "$root/legacy-schedule/test"
