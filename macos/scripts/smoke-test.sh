#!/bin/bash
set -euo pipefail

APP="${1:?Usage: smoke-test.sh /path/to/app}"
test -d "$APP"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = "io.github.trueakaru-stack.ai-task-monitor"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/data"
printf 'synthetic legacy log\n' > "$TMP/legacy-expected"
cp "$TMP/legacy-expected" "$TMP/data/claude-events.jsonl"
AI_TASK_MONITOR_SUPPORT_DIR="$TMP/data" AI_TASK_MONITOR_AUDIT=1 "$APP/Contents/MacOS/AITaskMonitor" --claude-hook <<'JSON'
{"hook_event_name":"UserPromptSubmit","session_id":"smoke-session","prompt":"Smoke test","cwd":"/tmp/project"}
JSON
test -s "$TMP/data/claude-events-v2.jsonl"
cmp "$TMP/legacy-expected" "$TMP/data/claude-events.jsonl"
grep -q 'smoke-session' "$TMP/data/claude-events-v2.jsonl"
if grep -Eq 'Smoke test|/tmp/project|"prompt"|"cwd"' "$TMP/data/claude-events-v2.jsonl"; then
  echo "Claude hook persisted synthetic prompt or working-directory data." >&2
  exit 1
fi
