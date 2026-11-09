#!/bin/bash
set -euo pipefail
: "${GITHUB_WORKSPACE:?}" "${RUNNER_TEMP:?}" "${GITHUB_SHA:?}"
test "${GITHUB_ACTIONS:-}" = true
test "${RUNNER_ENVIRONMENT:-}" = github-hosted
test "${RUNNER_OS:-}" = macOS
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/combined-counts-v2-20261109"
WORK="$RUNNER_TEMP/aitm-unified-work"
test "$(git rev-parse HEAD)" = "$GITHUB_SHA"
test -z "$(git status --porcelain)"
(cd "$INPUT" && shasum -a 256 -c staged.sha256)
test ! -e "$WORK"
mkdir -p "$WORK"
git -c core.autocrlf=false archive bbef0654fdb2789c62c8d8511576f05b75a289ca macos | tar -xf - -C "$WORK"
cp -R "$INPUT/overlay/macos/." "$WORK/macos/"
cp -R "$INPUT/synthetic" "$WORK/synthetic"
(cd "$WORK" && shasum -a 256 -c "$INPUT/candidate.sha256")
expected="$(wc -l < "$INPUT/candidate.sha256" | tr -d ' ')"
actual="$(find "$WORK/macos" -type f | wc -l | tr -d ' ')"
test "$expected" = "$actual"
