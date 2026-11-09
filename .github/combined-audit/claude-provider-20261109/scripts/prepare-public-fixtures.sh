#!/bin/bash
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/combined-audit/claude-provider-20261109"
WORK="$RUNNER_TEMP/aitm-unified-work"
OUT="$RUNNER_TEMP/aitm-unified-output"
NODE="$(command -v node)"
NPM="$(command -v npm)"
NODEBIN="$(dirname "$NODE")"
mkdir -p "$OUT/logs" "$RUNNER_TEMP/aitm-npm-cache" "$RUNNER_TEMP/aitm-downloads"
NPM_USER_CONFIG="$RUNNER_TEMP/aitm-npm-user.conf"
NPM_GLOBAL_CONFIG="$RUNNER_TEMP/aitm-npm-global.conf"
test ! -e "$NPM_USER_CONFIG" && test ! -e "$NPM_GLOBAL_CONFIG"
umask 077
: > "$NPM_USER_CONFIG"
: > "$NPM_GLOBAL_CONFIG"
for package in deepseek kimi; do
  if [ "$package" = deepseek ]; then target="$RUNNER_TEMP/aitm-dsh-upstream"; else target="$RUNNER_TEMP/aitm-kimi-upstream"; fi
  test ! -e "$target"
  mkdir -p "$target"
  cp "$INPUT/public-fixtures/$package/package.json" "$INPUT/public-fixtures/$package/package-lock.json" "$target/"
  args=(ci --ignore-scripts --no-audit --no-fund)
  if [ "$package" = kimi ]; then args+=(--omit=optional); fi
  (cd "$target" && /usr/bin/env -i "PATH=$NODEBIN:/usr/bin:/bin" "TMPDIR=$RUNNER_TEMP/" \
    "npm_config_cache=$RUNNER_TEMP/aitm-npm-cache" "npm_config_userconfig=$NPM_USER_CONFIG" \
    "npm_config_globalconfig=$NPM_GLOBAL_CONFIG" "npm_config_update_notifier=false" "$NPM" "${args[@]}")
done
kimi="$RUNNER_TEMP/aitm-kimi-upstream/node_modules/@moonshot-ai/kimi-code/dist/main.mjs"
printf '%s  %s\n' 'acd6894e2e2db50d37c449eefe9d3549a0177bd2d12cf17a8e1da94c60eb359f' "$kimi" | shasum -a 256 -c -
fetch() {
  /usr/bin/env -i "PATH=/usr/bin:/bin" /usr/bin/curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 --retry 3 "$1" --output "$2"
}
pnpm="$RUNNER_TEMP/aitm-downloads/pnpm.tgz"
fetch 'https://registry.npmjs.org/pnpm/-/pnpm-11.25.0.tgz' "$pnpm"
printf '%s  %s\n' '5cde925b4f075f725eb71fbae18a42ffe784524789f19b61c731cb8721ec28aaee160e01a8d5af4fedb2a42cdbf300efe23db356b0d4a17b4d63e11f8ab7c956' "$pnpm" | shasum -a 512 -c -
mkdir "$RUNNER_TEMP/aitm-pnpm"
tar -xzf "$pnpm" --strip-components=1 -C "$RUNNER_TEMP/aitm-pnpm"
hermes="$RUNNER_TEMP/aitm-downloads/hermes.tar.gz"
fetch 'https://codeload.github.com/NousResearch/hermes-agent/tar.gz/b200f5bc60e31588ba2cb60e288029c4a54ba5fa' "$hermes"
printf '%s  %s\n' '1f7d43fa1a515283929a739c42e10bf8d48910e523eccec74b2a2bece858d2b5' "$hermes" | shasum -a 256 -c -
/usr/bin/python3 -I -S -B "$WORK/macos/integration-tests/Extract-HermesFixture.py" "$hermes" "$RUNNER_TEMP/aitm-hermes-upstream"
packaging="$RUNNER_TEMP/aitm-downloads/packaging-26.0-py3-none-any.whl"
dotenv="$RUNNER_TEMP/aitm-downloads/python_dotenv-1.2.4-py3-none-any.whl"
fetch 'https://files.pythonhosted.org/packages/b7/b9/c538f279a4e237a006a2c98387d081e9eb060d203d8ed34467cc0f0b9b53/packaging-26.0-py3-none-any.whl' "$packaging"
fetch 'https://files.pythonhosted.org/packages/60/d1/38f3a3405989a89ac18390803e70c6ad7c7760da4f9b83cbeca0c44a0c72/python_dotenv-1.2.4-py3-none-any.whl' "$dotenv"
printf '%s  %s\n' 'b36f1fef9334a5588b4166f8bcd26a14e521f2b55e6b9de3aaa80d3ff7a37529' "$packaging" \
  '42269a8a5b3fd54ffa6f3d84b18abed50064717576b4ecf03dc4a55d8aa04fdc' "$dotenv" | shasum -a 256 -c -
ruamel="$WORK/macos/integrations/ruamel.yaml-0.18.16-py3-none-any.whl"
printf '%s  %s\n' '048f26d64245bae57a4f9ef6feb5b552a386830ef7a826f235ffb804c59efbba' "$ruamel" | shasum -a 256 -c -
PYTHON="$(command -v python3)"
test "${PYTHON#/}" != "$PYTHON"
"$PYTHON" -I -c 'import sys; assert sys.version_info[:3] == (3, 12, 10), sys.version'
"$PYTHON" -I -m venv "$RUNNER_TEMP/aitm-hermes-python"
/usr/bin/env -i "PATH=/usr/bin:/bin" "TMPDIR=$RUNNER_TEMP/" "$RUNNER_TEMP/aitm-hermes-python/bin/python" -m pip install \
  --isolated --no-index --no-deps --disable-pip-version-check "$ruamel" "$packaging" "$dotenv"
echo 'Prepared public, pinned synthetic fixtures.'
