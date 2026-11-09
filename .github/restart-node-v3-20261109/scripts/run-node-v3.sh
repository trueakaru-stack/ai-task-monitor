#!/bin/bash
set -euo pipefail
: "$GITHUB_WORKSPACE" "$RUNNER_TEMP" "$GITHUB_ACTIONS" "$RUNNER_ENVIRONMENT" "$RUNNER_OS"
test "$GITHUB_ACTIONS" = true
test "$RUNNER_ENVIRONMENT" = github-hosted
test "$RUNNER_OS" = macOS
INPUT="$GITHUB_WORKSPACE/.github/restart-node-v3-20261109"
WORK="$RUNNER_TEMP/aitm-restart-v3-work"
OUT="$RUNNER_TEMP/aitm-restart-v3-output"
NODE="$(command -v node)"
test -x "$NODE"
test "$("$NODE" --version)" = 'v24.22.2'
test ! -e "$WORK"
mkdir -p "$WORK" "$OUT" "$RUNNER_TEMP/aitm-restart-v3-tmp" "$RUNNER_TEMP/aitm-restart-v3-home"
(cd "$INPUT" && /usr/bin/shasum -a 256 -c staged.sha256)
cp -R "$INPUT/." "$WORK/"
(cd "$WORK" && /usr/bin/shasum -a 256 -c staged.sha256) > "$OUT/inputs.log"
STRICT_PROFILE='(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket))'
run_strict() {
  /usr/bin/env -i "PATH=$(dirname "$NODE"):/usr/bin:/bin" \
    "CFFIXED_USER_HOME=$RUNNER_TEMP/aitm-restart-v3-home" "TMPDIR=$RUNNER_TEMP/aitm-restart-v3-tmp/" \
    'GITHUB_ACTIONS=true' 'CI=true' 'RUNNER_ENVIRONMENT=github-hosted' 'RUNNER_OS=macOS' \
    /usr/bin/sandbox-exec -p "$STRICT_PROFILE" "$@"
}
run_strict /usr/bin/python3 -I -S -B "$WORK/scripts/network-probe.py" strict | tee "$OUT/network.log"
run_strict /usr/bin/python3 -I -S -B "$WORK/scripts/verify-provenance.py" "$WORK" | tee "$OUT/provenance-before.log"
/usr/bin/shasum -a 256 "$NODE" | tee "$OUT/node-sha256.log"
test -f "$WORK/macos/integrations/provider-observers.mjs"
test ! -e "$WORK/synthetic/integrations/provider-observers.mjs"
cp "$WORK/controls/restart-v2-gate-before.test.mjs" "$WORK/synthetic/restart-v2-gate.test.mjs"
if run_strict "$NODE" --test --test-reporter=tap "$WORK/synthetic/restart-v2-gate.test.mjs" 2>&1 | tee "$OUT/before.log"; then
  echo 'Expected old import to fail'; exit 1
fi
if ! /usr/bin/grep -Fq 'ERR_MODULE_NOT_FOUND' "$OUT/before.log" ||
   ! /usr/bin/grep -Fq '/synthetic/integrations/provider-observers.mjs' "$OUT/before.log"; then
  echo 'Before control failed for an unexpected reason'; exit 1
fi
cp "$INPUT/synthetic/restart-v2-gate.test.mjs" "$WORK/synthetic/restart-v2-gate.test.mjs"
(cd "$WORK" && /usr/bin/shasum -a 256 -c staged.sha256) > "$OUT/restored-inputs.log"
run_strict /usr/bin/python3 -I -S -B "$WORK/scripts/verify-provenance.py" "$WORK" | tee "$OUT/provenance-after.log"
run_strict "$NODE" --test --test-reporter=tap \
  "$WORK/synthetic/restart-v2-gate.test.mjs" \
  "$WORK/synthetic/opencode-v2-subscription.test.mjs" 2>&1 | tee "$OUT/node-tests.log"
for expected in '# tests 9' '# pass 9' '# fail 0' '# skipped 0'; do
  /usr/bin/grep -Fxq "$expected" "$OUT/node-tests.log" || { echo "Missing test summary: $expected"; exit 1; }
done
(cd "$WORK" && /usr/bin/shasum -a 256 -c staged.sha256) > "$OUT/inputs-after-tests.log"
cp "$INPUT/candidate.sha256" "$INPUT/v2-staged.sha256" "$INPUT/staged.sha256" "$OUT/"
echo 'Nine synthetic Node tests passed; no XCTest, real agent, UI or installer was run.'
