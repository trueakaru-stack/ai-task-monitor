#!/bin/bash
# Sourced only on a disposable GitHub-hosted macOS runner.
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/combined-counts-20261109"
WORK="$RUNNER_TEMP/aitm-unified-work"
OUT="$RUNNER_TEMP/aitm-unified-output"
NODE="$(command -v node)"
TEST_PYTHON="$(command -v python3)"
DEVELOPER="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$DEVELOPER"
test "${NODE#/}" != "$NODE"
test "${TEST_PYTHON#/}" != "$TEST_PYTHON"
STRICT_PROFILE='(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket))'
LOOPBACK_PROFILE='(version 1) (allow default) (deny network*) (allow network* (local unix-socket)) (allow network-outbound (remote unix-socket)) (allow network-bind (local ip "localhost:*")) (allow network-inbound (local ip "localhost:*")) (allow network-outbound (remote ip "localhost:*"))'
mkdir -p "$OUT/logs" "$RUNNER_TEMP/aitm-unified-home" "$RUNNER_TEMP/aitm-unified-tmp" "$RUNNER_TEMP/aitm-unified-support" \
  "$RUNNER_TEMP/aitm-layout-$GITHUB_RUN_ID" "$RUNNER_TEMP/aitm-feedback-$GITHUB_RUN_ID"
run_sandbox() {
  local profile="$1"; shift
  /usr/bin/env -i "PATH=$(dirname "$NODE"):/usr/bin:/bin" "DEVELOPER_DIR=$DEVELOPER" \
    "CFFIXED_USER_HOME=$RUNNER_TEMP/aitm-unified-home" "TMPDIR=$RUNNER_TEMP/aitm-unified-tmp/" \
    "AI_TASK_MONITOR_SUPPORT_DIR=$RUNNER_TEMP/aitm-unified-support" "RUNNER_TEMP=$RUNNER_TEMP" \
    "GITHUB_ACTIONS=true" "CI=true" "RUNNER_ENVIRONMENT=github-hosted" "RUNNER_OS=macOS" \
    "AITM_TEST_NODE=$NODE" "AITM_NODE=$NODE" \
    "AITM_HERMES_SOURCE=$RUNNER_TEMP/aitm-hermes-upstream" \
    "AITM_HERMES_PYTHON=$TEST_PYTHON" \
    "AITM_CLAUDE_TEST_EXECUTABLE=$WORK/macos/.build/debug/AITaskMonitor" \
    "AITM_V2_SENDER_FIXTURE=$WORK/synthetic/mac-v2-sender-child.mjs" \
    "AITM_V2_DEEPSEEK_FIXTURE=$WORK/synthetic/mac-v2-deepseek-child.mjs" \
    "AITM_LAYOUT_SYNTHETIC_CI=1" "AITM_LAYOUT_SYNTHETIC_ROOT=$RUNNER_TEMP/aitm-layout-$GITHUB_RUN_ID" \
    "AITM_FEEDBACK_SYNTHETIC_CI=1" "AITM_FEEDBACK_SYNTHETIC_ROOT=$RUNNER_TEMP/aitm-feedback-$GITHUB_RUN_ID" \
    "AITM_CLAUDE_PLAN_PREVIEW_ONLY=${AITM_CLAUDE_PLAN_PREVIEW_ONLY:-0}" \
    "AITM_TAB_COUNT_PREVIEW_ONLY=${AITM_TAB_COUNT_PREVIEW_ONLY:-0}" \
    "AITM_RESTART_VISUAL_ONLY=${AITM_RESTART_VISUAL_ONLY:-0}" \
    "AITM_RESTART_VISUAL_TARGET=${AITM_RESTART_VISUAL_TARGET:-}" \
    "AITM_RESTART_PROFILE=${AITM_RESTART_PROFILE:-}" \
    "AITM_RESTART_FORCE_ENABLED=${AITM_RESTART_FORCE_ENABLED:-0}" \
    /usr/bin/sandbox-exec -p "$profile" "$@"
}
run_strict() { run_sandbox "$STRICT_PROFILE" "$@"; }
run_loopback() { run_sandbox "$LOOPBACK_PROFILE" "$@"; }
