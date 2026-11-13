#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
NODE="$(command -v node || true)"
if [[ "$NODE" != /* || ! -x "$NODE" ]]; then
    echo "The Swift tests require an executable Node.js at an absolute path." >&2
    exit 1
fi

PYTHON=""
for name in python3 python3.14 python3.13 python3.12 python3.11; do
    candidate="$(command -v "$name" || true)"
    if [[ "$candidate" == /* && -x "$candidate" ]] &&
        "$candidate" -I -S -B -c 'import sys; assert (3, 11) <= sys.version_info[:2] < (3, 15)' 2>/dev/null; then
        PYTHON="$candidate"
        break
    fi
done
if [[ -z "$PYTHON" ]]; then
    echo "The Hermes clock test requires Python 3.11 through 3.14 on PATH." >&2
    exit 1
fi

SENDER="$ROOT/.github/provider-audit/v2-restart-20261109/synthetic/mac-v2-sender-child.mjs"
DEEPSEEK="$ROOT/.github/provider-audit/v2-restart-20261109/synthetic/mac-v2-deepseek-child.mjs"
if [[ ! -f "$SENDER" || ! -f "$DEEPSEEK" ]]; then
    echo "The required synthetic provider fixtures are missing." >&2
    exit 1
fi

export AITM_TEST_NODE="$NODE"
export AITM_HERMES_PYTHON="$PYTHON"
export AITM_V2_SENDER_FIXTURE="$SENDER"
export AITM_V2_DEEPSEEK_FIXTURE="$DEEPSEEK"
exec swift test "$@"
