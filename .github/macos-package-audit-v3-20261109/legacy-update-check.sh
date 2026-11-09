#!/bin/bash
set -euo pipefail
: "$GITHUB_WORKSPACE" "$GITHUB_SHA" "$RUNNER_TEMP" "$GITHUB_ACTIONS" "$RUNNER_ENVIRONMENT" "$RUNNER_OS"
test "$GITHUB_ACTIONS" = true
test "$RUNNER_ENVIRONMENT" = github-hosted
test "$RUNNER_OS" = macOS
INPUT="$GITHUB_WORKSPACE/.github/macos-package-audit-v3-20261109"
WORK="$RUNNER_TEMP/aitm-old-selector-v1"
OUT="$RUNNER_TEMP/aitm-old-selector-output"
SYNTHETIC="$RUNNER_TEMP/aitm-old-selector-home"
TEMPDIR="$RUNNER_TEMP/aitm-old-selector-tmp"
DEVELOPER="$DEVELOPER_DIR"
test -d "$DEVELOPER"
test ! -e "$WORK"
test ! -e "$OUT"
test ! -e "$SYNTHETIC"
test ! -e "$TEMPDIR"
mkdir -p "$WORK" "$OUT" "$SYNTHETIC" "$TEMPDIR"
(cd "$INPUT" && /usr/bin/shasum -a 256 -c staged.sha256)
run_git() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin' 'GIT_CONFIG_NOSYSTEM=1' \
    'GIT_CONFIG_GLOBAL=/dev/null' 'GIT_TERMINAL_PROMPT=0' \
    /usr/bin/git -C "$GITHUB_WORKSPACE" -c credential.helper= -c core.autocrlf=false "$@"
}
test "$(run_git rev-parse HEAD)" = "$GITHUB_SHA"
run_git archive c034eef660922c9a06ee601e6ab9f8eac22b7889 macos/Sources/AITaskMonitor/ReleaseUpdates.swift | /usr/bin/tar -xf - -C "$WORK"
OLD="$WORK/macos/Sources/AITaskMonitor/ReleaseUpdates.swift"
printf '%s  %s\n' '531dee18ce0a17314e41869b8ef7e3caf5eb79ae7f1a69e34e78eb0728aba669' "$OLD" | /usr/bin/shasum -a 256 -c -
cp "$INPUT/legacy-update-main.swift" "$WORK/main.swift"
PROFILE='(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket))'
run_isolated() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "DEVELOPER_DIR=$DEVELOPER" \
    "RUNNER_TEMP=$RUNNER_TEMP" "TMPDIR=$TEMPDIR/" "CFFIXED_USER_HOME=$SYNTHETIC" \
    'GITHUB_ACTIONS=true' 'CI=true' 'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
    /usr/bin/sandbox-exec -p "$PROFILE" "$@"
}
run_isolated /usr/bin/python3 -I -S -B "$INPUT/network-probe.py" strict | tee "$OUT/network.log"
run_isolated /usr/bin/xcrun swiftc "$OLD" "$WORK/main.swift" -o "$WORK/old-selector-test" 2>&1 | tee "$OUT/compile.log"
run_isolated "$WORK/old-selector-test" | tee "$OUT/selector.log"
test "$(/usr/bin/grep -c '^PASS: ' "$OUT/selector.log")" = 6
/usr/bin/grep -Fq 'Legacy selector synthetic checks passed' "$OUT/selector.log"
printf '%s\n' 'Source tag v0.3.7-alpha c034eef; synthetic metadata only; no installed app, notification or live network was tested.' > "$OUT/SCOPE.txt"
for artifact in selector.log SCOPE.txt; do
  test -s "$OUT/$artifact"
  test ! -L "$OUT/$artifact"
done
