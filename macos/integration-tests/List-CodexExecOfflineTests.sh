#!/bin/bash
set -euo pipefail

# Print individual XCTest methods so the official-CLI fixture remains a
# separate, explicitly unverified check when its isolated input is unavailable.
source_file=${1:?Pass the path to CodexExecDiscoveryTests.swift}
[[ -f "$source_file" && ! -L "$source_file" ]] || { echo "Test source is unavailable" >&2; exit 1; }

if ! awk '
BEGIN { fixture = "testOfficialCodexExecFixtureWhenProvided" }
/^[[:space:]]*func[[:space:]]+test/ {
  if ($0 !~ /^[[:space:]]*func[[:space:]]+test[A-Za-z0-9_]+\(\)/) {
    failed = 1; next
  }
  line = $0
  sub(/^[[:space:]]*func[[:space:]]+/, "", line)
  sub(/\(.*/, "", line)
  if (seen[line]++) failed = 1
  names[++count] = line
  if (line == fixture) found++
}
END {
  if (failed || count < 2 || found != 1) {
    exit 1
  }
  for (i = 1; i <= count; i++) if (names[i] != fixture) print names[i]
}' "$source_file"; then
  echo "Offline test inventory is incomplete or has duplicate/unexpected signatures" >&2
  exit 1
fi
echo "NOT RUN: testOfficialCodexExecFixtureWhenProvided requires an actual isolated official CLI fixture" >&2
