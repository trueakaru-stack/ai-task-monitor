#!/bin/bash
set -euo pipefail
: "$GITHUB_WORKSPACE" "$GITHUB_SHA" "$RUNNER_TEMP" "$GITHUB_ACTIONS" "$RUNNER_ENVIRONMENT" "$RUNNER_OS"
test "$GITHUB_ACTIONS" = true
test "$RUNNER_ENVIRONMENT" = github-hosted
test "$RUNNER_OS" = macOS
INPUT="$GITHUB_WORKSPACE/.github/macos-package-audit-v2-20261109"
WORK="$RUNNER_TEMP/aitm-package-candidate-v1"
PINNED="$RUNNER_TEMP/aitm-package-v2-input"
OUT="$RUNNER_TEMP/aitm-package-output"
SYNTHETIC="$RUNNER_TEMP/aitm-package-home"
SUPPORT="$RUNNER_TEMP/aitm-package-support"
HOOK="$RUNNER_TEMP/aitm-package-hook"
TEMPDIR="$RUNNER_TEMP/aitm-package-tmp"
MOUNT="$RUNNER_TEMP/aitm-package-mounted"
APP_CWD="$RUNNER_TEMP/aitm-package-app-cwd"
HOOK_CWD="$RUNNER_TEMP/aitm-package-hook-cwd"
SWIFTWRAP="$RUNNER_TEMP/aitm-package-swift-wrapper"
SWIFTPROBE="$RUNNER_TEMP/aitm-package-swift-probe"
DEVELOPER="$DEVELOPER_DIR"
test -d "$DEVELOPER"
test ! -e "$WORK"
test ! -e "$PINNED"
test ! -e "$OUT"
test ! -e "$SYNTHETIC"
test ! -e "$SUPPORT"
test ! -e "$HOOK"
test ! -e "$TEMPDIR"
test ! -e "$MOUNT"
test ! -e "$APP_CWD"
test ! -e "$HOOK_CWD"
test ! -e "$SWIFTWRAP"
test ! -e "$SWIFTPROBE"
mkdir -p "$WORK" "$PINNED" "$OUT" "$SYNTHETIC" "$SUPPORT" "$HOOK" "$TEMPDIR" "$MOUNT" "$APP_CWD" "$HOOK_CWD" "$SWIFTWRAP" "$SWIFTPROBE"
test "$(cd "$WORK/.." && pwd -P)/aitm-package-candidate-v1" = "$(cd "$WORK" && pwd -P)"
(cd "$INPUT" && /usr/bin/shasum -a 256 -c staged.sha256)
run_git() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin' 'GIT_CONFIG_NOSYSTEM=1' \
    'GIT_CONFIG_GLOBAL=/dev/null' 'GIT_TERMINAL_PROMPT=0' \
    /usr/bin/git -C "$GITHUB_WORKSPACE" -c credential.helper= -c core.autocrlf=false "$@"
}
test "$(run_git rev-parse HEAD)" = "$GITHUB_SHA"
run_git archive 8ebef09327339711bc5a4519c62eb565203b31d4 .github/limited-audit/combined-counts-v2-20261109 | /usr/bin/tar -xf - -C "$PINNED"
V2="$PINNED/.github/limited-audit/combined-counts-v2-20261109"
printf '%s  %s\n' 'c7fd3fcdf40ac3f82a64a886c567dcdba42c689163127d6be6f38863617f43cf' "$V2/staged.sha256" | /usr/bin/shasum -a 256 -c -
(cd "$V2" && /usr/bin/shasum -a 256 -c staged.sha256) > "$OUT/v2-inputs.log"
run_git archive bbef0654fdb2789c62c8d8511576f05b75a289ca macos | /usr/bin/tar -xf - -C "$WORK"
cp -R "$V2/overlay/macos/." "$WORK/macos/"
(cd "$WORK" && /usr/bin/shasum -a 256 -c "$V2/candidate.sha256") > "$OUT/candidate-source.log"
test "$(find "$WORK/macos" -type f | wc -l | tr -d ' ')" = 224
test -z "$(find "$WORK/macos" -type l -print)"
test ! -e "$WORK/macos/dist"
PROFILE='(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket))'
START_PROFILE='(version 1) (allow default) (deny network*) (deny process-fork)'
run_isolated() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "DEVELOPER_DIR=$DEVELOPER" \
    "RUNNER_TEMP=$RUNNER_TEMP" "GITHUB_WORKSPACE=$GITHUB_WORKSPACE" "TMPDIR=$TEMPDIR/" "CFFIXED_USER_HOME=$SYNTHETIC" "AITM_SYNTHETIC_HOME=$SYNTHETIC" \
    "AI_TASK_MONITOR_SUPPORT_DIR=$SUPPORT" 'GITHUB_ACTIONS=true' 'CI=true' \
    'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
    /usr/bin/sandbox-exec -p "$PROFILE" "$@"
}
run_start_restricted() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "DEVELOPER_DIR=$DEVELOPER" \
    "RUNNER_TEMP=$RUNNER_TEMP" "GITHUB_WORKSPACE=$GITHUB_WORKSPACE" "TMPDIR=$TEMPDIR/" "CFFIXED_USER_HOME=$SYNTHETIC" "AITM_SYNTHETIC_HOME=$SYNTHETIC" \
    "AI_TASK_MONITOR_SUPPORT_DIR=$SUPPORT" 'GITHUB_ACTIONS=true' 'CI=true' \
    'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
    /usr/bin/sandbox-exec -p "$START_PROFILE" "$@"
}
run_build_script() {
  /usr/bin/env -i "PATH=$SWIFTWRAP:/usr/bin:/bin:/usr/sbin:/sbin" "DEVELOPER_DIR=$DEVELOPER" \
    "RUNNER_TEMP=$RUNNER_TEMP" "GITHUB_WORKSPACE=$GITHUB_WORKSPACE" "TMPDIR=$TEMPDIR/" "CFFIXED_USER_HOME=$SYNTHETIC" "AITM_SYNTHETIC_HOME=$SYNTHETIC" \
    "AI_TASK_MONITOR_SUPPORT_DIR=$SUPPORT" 'GITHUB_ACTIONS=true' 'CI=true' \
    'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
    /usr/bin/sandbox-exec -p "$PROFILE" /bin/bash ./scripts/build-app.sh
}
run_isolated /usr/bin/python3 -I -S -B "$INPUT/network-probe.py" strict | tee "$OUT/network.log"
SWIFT="$DEVELOPER/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
test -x "$SWIFT"
test "$(run_isolated /usr/bin/xcrun --find swift)" = "$SWIFT"
run_isolated "$SWIFT" --version | tee "$OUT/swift-version.log"
run_isolated "$SWIFT" build --help > "$OUT/swift-help.log"
/usr/bin/grep -Fq -- '--disable-sandbox' "$OUT/swift-help.log"
/usr/bin/grep -Fq -- '--manifest-cache' "$OUT/swift-help.log"
cp "$INPUT/SyntheticNetworkPackage.swift" "$SWIFTPROBE/Package.swift"
test ! -e "$SWIFTPROBE/probe-passed.txt"
if (cd "$SWIFTPROBE" && run_isolated /usr/bin/env "AITM_SWIFTPM_PROBE_MARKER=$SWIFTPROBE/probe-passed.txt" \
    "$SWIFT" package --disable-sandbox --manifest-cache none dump-package > "$OUT/swift-probe.json" 2> "$OUT/swift-probe.log"); then
  cat "$OUT/swift-probe.log"
else
  cat "$OUT/swift-probe.log"
  exit 1
fi
test ! -L "$SWIFTPROBE/probe-passed.txt"
test "$(cat "$SWIFTPROBE/probe-passed.txt")" = 'ipv4-and-ipv6-denied'
printf '%s\n' 'SwiftPM manifest descendant denied synthetic IPv4 and IPv6 loopback connections.' | tee "$OUT/swift-probe-result.log"
cp "$INPUT/swift-wrapper.py" "$SWIFTWRAP/swift"
chmod 700 "$SWIFTWRAP/swift"
cmp -s "$INPUT/swift-wrapper.py" "$SWIFTWRAP/swift"
test "$(find "$SWIFTWRAP" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1
run_isolated /usr/bin/python3 -I -S -B "$INPUT/prepare-test-version.py" --apply-ci "$WORK/macos" | tee "$OUT/test-version.log"
(cd "$WORK" && /usr/bin/shasum -a 256 -c "$INPUT/candidate-test-version.sha256") > "$OUT/versioned-source.log"
(cd "$WORK/macos" && run_build_script) 2>&1 | tee "$OUT/build-app.log"
test "$(cat "$SWIFTWRAP/invoked")" = 'one checked invocation'
cmp -s "$INPUT/swift-wrapper.py" "$SWIFTWRAP/swift"
test "$(find "$SWIFTWRAP" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 2
APP="$WORK/macos/dist/AI Task Monitor.app"
BINARY="$APP/Contents/MacOS/AITaskMonitor"
run_isolated /usr/bin/python3 -I -S -B "$INPUT/verify-app-bundle.py" "$APP" "$WORK/macos" "$INPUT/bundle-resources.sha256" | tee "$OUT/bundle.json"
run_isolated /usr/bin/xcrun lipo "$BINARY" -verify_arch arm64 x86_64
run_isolated /usr/bin/xcrun lipo -archs "$BINARY" | tee "$OUT/architectures.log"
run_isolated /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tee "$OUT/signature.log"
run_isolated /usr/bin/otool -L "$BINARY" | tee "$OUT/dynamic-libraries.log"
run_isolated /usr/bin/python3 -I -S -B "$INPUT/startup-guard.py" | tee "$OUT/startup-preflight.log"
run_start_restricted /usr/bin/python3 -I -S -B "$INPUT/startup-sandbox-probe.py" | tee "$OUT/startup-sandbox.log"
run_isolated /usr/bin/python3 -I -S -B "$INPUT/unix-connect-probe.py" "$INPUT/startup-sandbox-probe.py" "$START_PROFILE" | tee "$OUT/unix-connect.log"
/usr/bin/env -i 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "DEVELOPER_DIR=$DEVELOPER" \
  "RUNNER_TEMP=$RUNNER_TEMP" "TMPDIR=$TEMPDIR/" "CFFIXED_USER_HOME=$SYNTHETIC" \
  "AI_TASK_MONITOR_SUPPORT_DIR=$SUPPORT" "AITM_SYNTHETIC_CWD=$APP_CWD" 'GITHUB_ACTIONS=true' 'CI=true' \
  'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
  /usr/bin/python3 -I -S -B "$INPUT/startup-owner.py" "$BINARY" "$OUT/startup.log" "$START_PROFILE" | tee "$OUT/startup-process.log"
test -z "$(ls -A "$HOOK_CWD")"
(cd "$HOOK_CWD" && printf '%s' '{"session_id":"aitm-synthetic","hook_event_name":"UserPromptSubmit"}' | \
  /usr/bin/env -i 'PATH=/usr/bin:/bin' "DEVELOPER_DIR=$DEVELOPER" "TMPDIR=$TEMPDIR/" \
    "CFFIXED_USER_HOME=$SYNTHETIC" "AI_TASK_MONITOR_SUPPORT_DIR=$HOOK" 'AI_TASK_MONITOR_AUDIT=1' \
    /usr/bin/sandbox-exec -p "$START_PROFILE" "$BINARY" --claude-hook)
run_isolated /usr/bin/python3 -I -S -B - "$HOOK/claude-events-v2.jsonl" <<'PY'
import json, pathlib, sys
rows = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
assert len(rows) == 1
record = json.loads(rows[0])
assert record["session_id"] == "aitm-synthetic" and record["event"] == "UserPromptSubmit"
assert record["provider"] == "claude" and record["active"] is True
print("Synthetic bundle hook wrote the expected event")
PY
(cd "$WORK/macos" && run_isolated /bin/bash ./scripts/create-dmg.sh) 2>&1 | tee "$OUT/create-dmg.log"
DMG="$WORK/macos/dist/AITaskMonitor-macOS-0.3.8-ci.1.dmg"
test -f "$DMG"
(cd "$WORK/macos/dist" && /usr/bin/shasum -a 256 -c SHA256SUMS-macOS.txt) | tee "$OUT/dmg-checksum.log"
run_isolated /usr/bin/hdiutil verify "$DMG" | tee "$OUT/dmg-verify.log"
run_isolated /usr/bin/python3 -I -S -B "$INPUT/dmg-owner.py" | tee "$OUT/dmg-owner.log"
(cd "$WORK" && /usr/bin/shasum -a 256 -c "$INPUT/candidate-test-version.sha256") > "$OUT/source-after-build.log"
cp "$DMG" "$WORK/macos/dist/SHA256SUMS-macOS.txt" "$INPUT/candidate-test-version.sha256" "$INPUT/bundle-resources.sha256" "$OUT/"
printf '%s\n' 'INTERNAL TEST BUILD: 0.3.8-ci.1; ad-hoc signature; not notarized; not a public release.' > "$OUT/NOT-A-RELEASE.txt"
for artifact in AITaskMonitor-macOS-0.3.8-ci.1.dmg SHA256SUMS-macOS.txt candidate-test-version.sha256 bundle-resources.sha256 NOT-A-RELEASE.txt; do
  test -s "$OUT/$artifact"
  test ! -L "$OUT/$artifact"
done
