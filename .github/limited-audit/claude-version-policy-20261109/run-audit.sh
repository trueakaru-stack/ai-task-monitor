#!/bin/bash
set -euo pipefail
: "${GITHUB_WORKSPACE:?}" "${GITHUB_SHA:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}" "${DEVELOPER_DIR:?}"
test "${GITHUB_ACTIONS:-}" = true
test "${RUNNER_ENVIRONMENT:-}" = github-hosted
test "${RUNNER_OS:-}" = macOS
MODE="${1:-}"
case "$MODE" in preview|race) ;; *) echo 'Unexpected audit mode'; exit 1;; esac
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/claude-version-policy-20261109"
ROOT="$(/usr/bin/mktemp -d /private/tmp/aitm-policy-XXXXXXXX)"
case "$ROOT" in /private/tmp/aitm-policy-*) ;; *) exit 1;; esac
test ! -L "$ROOT"
mkdir -p "$ROOT/source" "$ROOT/pin" "$ROOT/tmp" "$ROOT/synthetic" "$ROOT/support" "$ROOT/logs"
WORK="$ROOT/source"
SWIFT="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
test -x "$SWIFT"
run_git() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin' 'GIT_CONFIG_NOSYSTEM=1' 'GIT_CONFIG_GLOBAL=/dev/null' \
    'GIT_TERMINAL_PROMPT=0' /usr/bin/git -C "$GITHUB_WORKSPACE" \
    -c credential.helper= -c core.autocrlf=false "$@"
}
test "$(run_git rev-parse HEAD)" = "$GITHUB_SHA"
run_git archive 8ebef09327339711bc5a4519c62eb565203b31d4 .github/limited-audit/combined-counts-v2-20261109 | /usr/bin/tar -xf - -C "$ROOT/pin"
V2="$ROOT/pin/.github/limited-audit/combined-counts-v2-20261109"
printf '%s  %s\n' c7fd3fcdf40ac3f82a64a886c567dcdba42c689163127d6be6f38863617f43cf "$V2/staged.sha256" | /usr/bin/shasum -a 256 -c -
(cd "$V2" && /usr/bin/shasum -a 256 -c staged.sha256) > "$ROOT/logs/pin.log"
run_git archive bbef0654fdb2789c62c8d8511576f05b75a289ca macos | /usr/bin/tar -xf - -C "$WORK"
cp -R "$V2/overlay/macos/." "$WORK/macos/"
(cd "$WORK" && /usr/bin/shasum -a 256 -c "$V2/candidate.sha256") > "$ROOT/logs/source.log"
test "$(find "$WORK/macos" -type f | wc -l | tr -d ' ')" = 224
test -z "$(find "$WORK/macos" -type l -print)"
test ! -e "$WORK/macos/dist"
cp "$INPUT/SettingsView.swift" "$WORK/macos/Sources/AITaskMonitor/SettingsView.swift"
cp "$INPUT/SnapshotRenderer.swift" "$WORK/macos/Sources/AITaskMonitor/SnapshotRenderer.swift"
mv "$WORK/macos/Tests" "$ROOT/unexecuted-original-tests"
mkdir -p "$WORK/macos/Tests/AITaskMonitorTests"
if [ "$MODE" = preview ]; then
  cp "$INPUT/ClaudeVersionPolicyTextTests.swift" "$WORK/macos/Tests/AITaskMonitorTests/"
  cp "$ROOT/unexecuted-original-tests/AITaskMonitorTests/ClaudePhaseIntegrationTests.swift" "$WORK/macos/Tests/AITaskMonitorTests/"
else
  cp "$INPUT/ClaudeIntegrationLateRace.swift" "$WORK/macos/Sources/AITaskMonitor/ClaudeIntegration.swift"
  cp "$INPUT/ClaudeLateRaceTests.swift" "$WORK/macos/Tests/AITaskMonitorTests/"
fi
cp "$INPUT/isolation-check.py" "$ROOT/isolation-check.py"
cp "$INPUT/verify-frames.py" "$ROOT/verify-frames.py"

# Deny access to the hosted account's entire home, not just known agent paths.
# The synthetic root is outside that directory. This does not change HOME.
/usr/bin/python3 -I -S -B - "$ROOT" <<'PY'
import json, os, pwd, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve(strict=True)
account = Path(pwd.getpwuid(os.getuid()).pw_dir).resolve(strict=True)
if str(account) in ('/', '/private', '/private/tmp') or account == root or account in root.parents or root in account.parents:
    raise SystemExit('Unsafe account/synthetic directory relationship')
quoted = json.dumps(str(account), ensure_ascii=True)
base = '(version 1) (allow default) (deny network*) (deny file-read* file-write* (subpath ' + quoted + '))'
(root / 'build.sb').write_text(base, encoding='utf-8')
(root / 'preview.sb').write_text(base + ' (deny process-fork)', encoding='utf-8')
(root / 'account.txt').write_text(str(account), encoding='utf-8')
PY
ACCOUNT="$(cat "$ROOT/account.txt")"
probe() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin' "TMPDIR=$ROOT/tmp/" \
    /usr/bin/python3 -I -S -B "$ROOT/isolation-check.py" "$ROOT/$1.sb" "$ROOT/tmp" "$ACCOUNT" "$1"
}
probe build
if [ "$MODE" = preview ]; then probe preview; fi
run_restricted() {
  local profile="$1"; shift
  /usr/bin/env -i 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "DEVELOPER_DIR=$DEVELOPER_DIR" \
    "TMPDIR=$ROOT/tmp/" "CFFIXED_USER_HOME=$ROOT/synthetic" "AI_TASK_MONITOR_SUPPORT_DIR=$ROOT/support" \
    "CLANG_MODULE_CACHE_PATH=$ROOT/tmp/clang-cache" "SWIFTPM_MODULECACHE_OVERRIDE=$ROOT/tmp/swift-cache" \
    'GITHUB_ACTIONS=true' 'CI=true' 'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
    /usr/bin/sandbox-exec -f "$ROOT/$profile.sb" "$@"
}
cd "$WORK/macos"
if [ "$MODE" = preview ]; then
  run_restricted build "$SWIFT" test --disable-sandbox --filter ClaudeVersionPolicyTextTests 2>&1 | tee "$ROOT/logs/text.log"
  /usr/bin/grep -Eq 'Executed 2 tests?, with 0 failures' "$ROOT/logs/text.log"
  run_restricted build "$SWIFT" test --disable-sandbox --filter ClaudePhaseIntegrationTests.testStopWithBackgroundOrMissingInformationRetainsUnconfirmedCard 2>&1 | tee "$ROOT/logs/stop.log"
  /usr/bin/grep -Eq 'Executed 1 test, with 0 failures' "$ROOT/logs/stop.log"
  test -x .build/debug/AITaskMonitor
  mkdir "$ROOT/frames"
  run_restricted preview /usr/bin/env 'AITM_CLAUDE_REQUIREMENT_PREVIEW_ONLY=1' \
    .build/debug/AITaskMonitor --render-previews "$ROOT/frames"
  run_restricted build /usr/bin/python3 -I -S -B "$ROOT/verify-frames.py" "$ROOT/frames"
  printf 'frames=%s\n' "$ROOT/frames" >> "$GITHUB_OUTPUT"
else
  run_restricted build "$SWIFT" test --disable-sandbox --filter ClaudeLateRaceTests 2>&1 | tee "$ROOT/logs/race.log"
  /usr/bin/grep -Eq 'Executed 3 tests?, with 0 failures' "$ROOT/logs/race.log"
  echo 'Counterexample reproduced: late concurrent changes are overwritten; no fix is claimed.'
fi
