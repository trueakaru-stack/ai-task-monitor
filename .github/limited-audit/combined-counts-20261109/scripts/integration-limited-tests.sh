#!/bin/bash
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/combined-counts-20261109"
source "$INPUT/scripts/sandbox.sh"
run_strict /usr/bin/python3 -I -S -B "$INPUT/scripts/network-probe.py" strict | tee "$OUT/logs/network-integrations.log"
fixture="$WORK/limited-integrations"
run_strict "$TEST_PYTHON" -I -B "$INPUT/synthetic/prepare-isolated-integrations.py" \
  --source "$WORK/macos" --output "$fixture" | tee "$OUT/logs/fixture-preparation.log"
run_strict /usr/bin/python3 -I -S -B - "$INPUT/synthetic" "$fixture" <<'PY'
import json
from pathlib import Path
import sys
expected, actual = map(Path, sys.argv[1:])
for name in ("SOURCE_TREE_SHA256.json", "PREPARED_TREE_SHA256.json", "TEST_FIXTURE_SHA256.json"):
    if json.loads((expected / name).read_text(encoding="utf-8")) != json.loads((actual / name).read_text(encoding="utf-8")):
        raise SystemExit("Fixture manifest mismatch: " + name)
print("All source, prepared-tree and modified-fixture manifests match")
PY
cd "$fixture/integration-tests"
status=0
run_case() {
  local name="$1"; shift
  if ! run_strict "$@" 2>&1 | tee "$OUT/logs/integration-$name.log"; then
    echo "Limited synthetic integration failed: $name"; status=1
  fi
}
run_case restart-gate "$NODE" --test --test-reporter=tap \
  "$WORK/synthetic/restart-v2-gate.test.mjs" "$WORK/synthetic/opencode-v2-subscription.test.mjs"
for expected in '# tests 9' '# pass 9' '# fail 0' '# skipped 0'; do
  if ! /usr/bin/grep -Fxq "$expected" "$OUT/logs/integration-restart-gate.log"; then
    echo "Missing expected Node test summary: $expected"; status=1
  fi
done
run_case kimi-observer "$NODE" Test-KimiObserver.mjs
run_case kimi-upstream-hook "$NODE" Test-KimiUpstreamHook.mjs \
  "$RUNNER_TEMP/aitm-kimi-upstream/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"
run_case kimi-integration "$NODE" Test-KimiIntegration.mjs
run_case provider-bundles "$NODE" Test-ProviderBundles.mjs
run_case external-provider-hooks /usr/bin/python3 -I -B test_external_provider_hooks.py
run_case provider-bundle-nine /usr/bin/python3 -I -B "$INPUT/synthetic/run-bundle-limited.py" "$fixture/integration-tests"
run_case hermes-liveness /usr/bin/python3 -I -B Test-HermesLiveness.py "$RUNNER_TEMP/aitm-hermes-upstream/hermes_cli/active_sessions.py"
for entry in external-provider-hooks:22 provider-bundle-nine:9 hermes-liveness:5; do
  name="${entry%:*}"; count="${entry#*:}"
  if ! /usr/bin/grep -Eq "Ran $count tests? in" "$OUT/logs/integration-$name.log" || /usr/bin/grep -Eiq "skipped[=( ]" "$OUT/logs/integration-$name.log"; then
    echo "Missing expected zero-skip test count: $name"; status=1
  fi
done
exit "$status"
