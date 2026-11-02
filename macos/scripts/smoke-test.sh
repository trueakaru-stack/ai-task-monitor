#!/bin/bash
set -euo pipefail

APP="${1:?Usage: smoke-test.sh /path/to/app}"
test -d "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
test "$(defaults read "$APP/Contents/Info" CFBundleIdentifier)" = "io.github.trueakaru-stack.ai-task-monitor"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME="$TMP" AI_TASK_MONITOR_AUDIT=1 "$APP/Contents/MacOS/AITaskMonitor" --claude-hook <<'JSON'
{"hook_event_name":"UserPromptSubmit","session_id":"smoke-session","prompt":"Smoke test","cwd":"/tmp/project"}
JSON
test -s "$TMP/Library/Application Support/AI Task Monitor/claude-events.jsonl"
grep -q 'smoke-session' "$TMP/Library/Application Support/AI Task Monitor/claude-events.jsonl"
