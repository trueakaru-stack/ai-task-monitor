#!/bin/bash
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/combined-counts-v2-20261109"
WORK="$RUNNER_TEMP/aitm-unified-work"
OUT="$RUNNER_TEMP/aitm-unified-output"
DOWNLOADS="$RUNNER_TEMP/aitm-limited-downloads"
test ! -e "$DOWNLOADS"
mkdir -p "$OUT/logs" "$DOWNLOADS"
fetch() {
  /usr/bin/env -i 'PATH=/usr/bin:/bin' /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --retry 3 "$1" --output "$2"
}
kimi="$DOWNLOADS/kimi.tgz"
fetch 'https://registry.npmjs.org/@moonshot-ai/kimi-code/-/kimi-code-2.5.0.tgz' "$kimi"
printf '%s  %s\n' '018b93e1f5bba73640ab12080e3c7eca92c936800bd3b359094c8f0e57ff26b8322ab8b7e5e56af660ee8687bfc515fbc0d1cbfb57d7f87d038ffac1dc7d3862' "$kimi" | shasum -a 512 -c -
mkdir -p "$RUNNER_TEMP/aitm-kimi-upstream/node_modules/@moonshot-ai/kimi-code/dist"
kimi_main="$RUNNER_TEMP/aitm-kimi-upstream/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"
tar -xOf "$kimi" package/dist/main.mjs > "$kimi_main"
printf '%s  %s\n' 'acd6894e2e2db50d37c449eefe9d3549a0177bd2d12cf17a8e1da94c60eb359f' "$kimi_main" | shasum -a 256 -c -
hermes="$INPUT/fixtures/hermes-pinned-fixture.tar.gz"
printf '%s  %s\n' '45d1bede19566e032696d41570c9c5b0669fa32bc9e1e6c99cba7f7b8f0b1bf6' "$hermes" | shasum -a 256 -c -
/usr/bin/python3 -I -S -B "$INPUT/fixtures/verify-hermes-fixture.py" "$hermes" "$INPUT/fixtures/HERMES-FILES.sha256" "$INPUT/fixtures/HERMES-LICENSE.txt"
/usr/bin/python3 -I -S -B "$WORK/macos/integration-tests/Extract-HermesFixture.py" "$hermes" "$RUNNER_TEMP/aitm-hermes-upstream"
printf '%s  %s\n' '0e3bd5dd93281f4d392850550a8d8bf94b213f965dccd6159513fa5bc6466fb7' "$RUNNER_TEMP/aitm-hermes-upstream/hermes_cli/active_sessions.py" | shasum -a 256 -c -
echo 'Prepared the pinned public Kimi fixture and local 70-file Hermes fixture without package installation.'
