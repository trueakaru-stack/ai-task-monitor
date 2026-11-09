#!/bin/bash
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/combined-counts-20261109"
source "$INPUT/scripts/sandbox.sh"
cd "$WORK/macos"
for tool in swift swiftc swift-frontend clang ld; do
  executable="$(DEVELOPER_DIR="$DEVELOPER" /usr/bin/xcrun --find "$tool")"
  test -x "$executable"
  /usr/bin/shasum -a 256 "$executable"
done | tee "$OUT/logs/toolchain-sha256.log"
run_strict /usr/bin/python3 -I -S -B "$INPUT/scripts/network-probe.py" strict | tee "$OUT/logs/network-strict.log"
audit_status=0
expect_red() {
  local name="$1" filter="$2" expected="$3" count="$4" status
  set +e
  run_strict /usr/bin/xcrun swift test --disable-sandbox --filter "$filter" 2>&1 | tee "$OUT/logs/red-$name.log"
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -eq 0 ]; then echo "Expected pre-fix failure did not occur: $name"; audit_status=1; fi
  if ! /usr/bin/grep -Fq "$expected" "$OUT/logs/red-$name.log"; then echo "Wrong failure: $name"; audit_status=1; fi
  if ! /usr/bin/grep -Eq "Executed $count tests?, with [1-9][0-9]* failures?" "$OUT/logs/red-$name.log"; then
    echo "Wrong failing test count: $name"; audit_status=1
  fi
}
# Five test files use APIs absent in the deliberately old controls.
# Restore all before the explicitly limited suite.
for name in ClaudeScopedRetentionTests.swift ClaudeScopedOverflowDetailsTests.swift ClaudeProviderCombinedIsolationTests.swift ExternalProviderTaskStoreTests.swift HermesTaskStoreTests.swift; do
  mv "Tests/AITaskMonitorTests/$name" "$RUNNER_TEMP/aitm-$name"
done
cp "$INPUT/controls/TaskStore-before-merge.swift" Sources/AITaskMonitor/TaskStore.swift
run_strict /usr/bin/xcrun swift build --disable-sandbox 2>&1 | tee "$OUT/logs/debug-before.log"
expect_red phase ClaudePhaseIsolationRaceTests.testAttributedPhaseAfterSnapshotPreservesNeighbor \
  'An attributed phase in first must not clear neighbor' 1
cp "$INPUT/controls/TaskStore-before-reader-merge.swift" Sources/AITaskMonitor/TaskStore.swift
cp "$INPUT/controls/ClaudeTaskReader-before.swift" Sources/AITaskMonitor/ClaudeTaskReader.swift
expect_red title ClaudeTitleHistoryTests.testOldAndNewTitleSameIDBeforeFirstPollSurviveKnownLoss \
  'Both observed titles must survive one read' 1
cp "$INPUT/controls/ClaudeTaskReader-before-prefix.swift" Sources/AITaskMonitor/ClaudeTaskReader.swift
expect_red prefix ClaudePrefixTitleTests.testValidPrefixTitleBeforePartialBoundarySurvivesFirstRead \
  'Valid prefix title must be retained without trusting its status' 1
cp "$INPUT/controls/TaskStore-before-overflow-merge.swift" Sources/AITaskMonitor/TaskStore.swift
cp "$INPUT/controls/ClaudeTaskReader-before-overflow.swift" Sources/AITaskMonitor/ClaudeTaskReader.swift
expect_red overflow ClaudeScopedOverflowBaseTests.testOneSessionOverflowDoesNotInventGlobalLoss \
  'A session-local overflow must not invent source-wide loss' 1
cp "$INPUT/overlay/macos/Sources/AITaskMonitor/TaskStore.swift" Sources/AITaskMonitor/TaskStore.swift
cp "$INPUT/overlay/macos/Sources/AITaskMonitor/ClaudeTaskReader.swift" Sources/AITaskMonitor/ClaudeTaskReader.swift
for name in ClaudeScopedRetentionTests.swift ClaudeScopedOverflowDetailsTests.swift ClaudeProviderCombinedIsolationTests.swift ExternalProviderTaskStoreTests.swift HermesTaskStoreTests.swift; do
  mv "$RUNNER_TEMP/aitm-$name" "Tests/AITaskMonitorTests/$name"
done
cp "$INPUT/controls/ExternalProviderV2Runtime-before.swift" Sources/AITaskMonitor/ExternalProviderV2Runtime.swift
expect_red restart RestartAcknowledgementIndependentTests \
  'An in-flight reply for a neighbour rejected the restart action' 2
if ! /usr/bin/grep -Fq 'The pending old frame rejected the restart action' "$OUT/logs/red-restart.log"; then
  echo 'Second pre-fix restart failure did not occur'; audit_status=1
fi
cp "$INPUT/overlay/macos/Sources/AITaskMonitor/ExternalProviderV2Runtime.swift" Sources/AITaskMonitor/ExternalProviderV2Runtime.swift
cp "$INPUT/controls/TaskStore-before-counts.swift" Sources/AITaskMonitor/TaskStore.swift
expect_red visible-counts ProviderCountsVisibilityTests \
  'Every visible card must be included' 2
cp "$INPUT/overlay/macos/Sources/AITaskMonitor/TaskStore.swift" Sources/AITaskMonitor/TaskStore.swift
if ! (cd "$WORK" && shasum -a 256 -c "$INPUT/candidate.sha256") > "$OUT/logs/source-verification.log"; then
  echo 'Candidate source changed during reproduction'; exit 1
fi
if ! run_strict /usr/bin/xcrun swift build --disable-sandbox 2>&1 | tee "$OUT/logs/debug-final.log"; then
  echo 'Final debug build failed'; exit 1
fi
/usr/bin/shasum -a 256 .build/debug/AITaskMonitor | tee "$OUT/logs/debug-executable-sha256.log"
filter="$(/usr/bin/awk -F: 'BEGIN { printf "(" } NR > 1 { printf "|" } { printf "%s", $1 } END { printf ")" }' "$INPUT/required-suites-limited.txt")"
set +e
run_strict /usr/bin/xcrun swift test --disable-sandbox --filter "$filter" 2>&1 | tee "$OUT/logs/limited-xctest.log"
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then echo 'Limited XCTest run failed'; audit_status=1; fi
if ! run_strict /usr/bin/python3 -I -S -B "$INPUT/scripts/verify-limited-suites.py" "$OUT/logs/limited-xctest.log" "$INPUT/required-suites-limited.txt"; then
  audit_status=1
fi
if ! (cd "$WORK" && shasum -a 256 -c "$INPUT/candidate.sha256") > "$OUT/logs/source-after-tests.log"; then
  echo 'Candidate source changed during limited tests'; audit_status=1
fi
if ! run_strict /usr/bin/xcrun swift build --disable-sandbox --configuration release 2>&1 | tee "$OUT/logs/release-build.log"; then
  audit_status=1
else
  /usr/bin/shasum -a 256 .build/release/AITaskMonitor | tee "$OUT/logs/release-executable-sha256.log"
fi
cp "$INPUT/candidate.sha256" "$INPUT/source-pins.json" "$OUT/"
exit "$audit_status"
