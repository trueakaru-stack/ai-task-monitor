#!/bin/bash
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/combined-audit/claude-provider-20261109"
source "$INPUT/scripts/sandbox.sh"
cd "$WORK/macos"
run_strict /usr/bin/python3 -I -S -B "$INPUT/scripts/network-probe.py" strict | tee "$OUT/logs/network-integrations.log"
audit_status=0
run_case() {
  local name="$1"; shift
  if ! run_strict "$@" 2>&1 | tee "$OUT/logs/integration-$name.log"; then
    echo "Synthetic integration failed: $name"; audit_status=1
  fi
}
cp -R "$WORK/macos/integrations" "$WORK/synthetic/integrations"
run_case restart-gate "$NODE" --test --test-reporter=tap \
  "$WORK/synthetic/restart-v2-gate.test.mjs" "$WORK/synthetic/opencode-v2-subscription.test.mjs"
for expected in '# tests 9' '# pass 9' '# fail 0' '# skipped 0'; do
  if ! /usr/bin/grep -Fxq "$expected" "$OUT/logs/integration-restart-gate.log"; then
    echo "Missing expected Node test summary: $expected"; audit_status=1
  fi
done
for name in Test-ExternalProviderEvents Test-ExternalProviderObservers Test-ProviderBundles Test-KimiIntegration Test-KimiObserver; do
  run_case "$name" "$NODE" "integration-tests/$name.mjs"
done
run_case deepseek-cordis "$NODE" integration-tests/Test-DeepSeekCordisRuntime.mjs \
  "$RUNNER_TEMP/aitm-dsh-upstream/node_modules"
run_case deepseek-bridge "$NODE" integration-tests/Test-DeepSeekIntegration.mjs \
  "$RUNNER_TEMP/aitm-dsh-upstream/node_modules/@deepseek-ai/dsh/package.json" "$RUNNER_TEMP/aitm-pnpm/bin/pnpm.mjs"
for name in test_external_provider_hooks test_provider_bundle; do
  run_case "$name" /usr/bin/python3 -I -B "integration-tests/$name.py"
done
HERMES="$RUNNER_TEMP/aitm-hermes-upstream"
PYTHON="$RUNNER_TEMP/aitm-hermes-python/bin/python"
run_case hermes-setup "$PYTHON" -I -S -B integration-tests/Test-HermesSetup.py integrations "$HERMES"
run_case hermes-manager "$PYTHON" -I -B integration-tests/Test-HermesManager.py integrations "$HERMES"
run_case hermes-packaging /usr/bin/python3 -I -S -B integration-tests/Test-HermesPackaging.py
run_case hermes-dispatch /usr/bin/python3 -I -S -B integration-tests/Test-HermesUpstreamDispatch.py "$HERMES"
run_case hermes-liveness /usr/bin/python3 -I -S -B integration-tests/Test-HermesLiveness.py "$HERMES/hermes_cli/active_sessions.py"
run_case hermes-publication "$PYTHON" -I -B integration-tests/Test-HermesPublication.py "$HERMES"
KIMI="$RUNNER_TEMP/aitm-kimi-upstream/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"
for name in Test-KimiUpstreamHook Test-KimiUpstreamContract Test-KimiUpstreamInstall; do
  run_case "$name" "$NODE" "integration-tests/$name.mjs" "$KIMI"
done
if run_loopback /usr/bin/python3 -I -S -B "$INPUT/scripts/network-probe.py" loopback 2>&1 | tee "$OUT/logs/network-loopback.log"; then
  if ! run_loopback "$NODE" integration-tests/Test-KimiApprovalWeb.mjs "$RUNNER_TEMP/aitm-kimi-upstream" 2>&1 | tee "$OUT/logs/integration-kimi-approval-web.log"; then
    echo 'Synthetic local Kimi approval test failed'; audit_status=1
  fi
else
  echo 'Loopback isolation probe failed; Kimi approval test was not run'; audit_status=1
fi
exit "$audit_status"
