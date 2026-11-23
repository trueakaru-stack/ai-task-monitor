#!/bin/bash
set -euo pipefail

reject() { echo "Isolated icon fallback rejected: $1" >&2; exit 1; }
test "${GITHUB_ACTIONS:-}" = true && test "${RUNNER_ENVIRONMENT:-}" = github-hosted && test "${RUNNER_OS:-}" = macOS || reject 'runner'
test "$#" = 5 || reject 'argument count'
test "$1" = -c && test "$2" = icns && test "$4" = -o || reject 'operation'
test "$5" = 'dist/AI Task Monitor.app/Contents/Resources/AppIcon.icns' || reject 'output path'

task_root="${AITM_RELEASE_ROOT:?}"
task_synthetic="${AITM_SYNTHETIC_TEST_ROOT:?}"
test -d "$task_root" && test ! -L "$task_root" || reject 'root'
test "$(cd -P "$task_root" && pwd -P)" = "$task_root" || reject 'root identity'
if test "${AITM_ICON_WRAPPER_TEST_MODE:-}" = 1; then
    case "$task_root" in "$task_synthetic"/icon-guard.????????) ;; *) reject 'test root';; esac
    task_native="$task_root/native-iconutil"
    test -f "$task_native" && test -x "$task_native" && test ! -L "$task_native" || reject 'test executable'
else
    test -z "${AITM_ICON_WRAPPER_TEST_MODE:-}" || reject 'test mode'
    test "$task_root/temp" = "$task_synthetic" || reject 'temporary root'
    task_native=/usr/bin/iconutil
fi

task_source="$task_root/source/macos"
test "$(pwd -P)" = "$task_source" || reject 'working directory'
for dir in "$task_root/source" "$task_source" "$task_source/assets" "$task_source/assets/app-icon" \
           "$task_root/source/.github" "$task_root/source/.github/macos-icon-fallback-20261123" \
           "$task_source/dist" "$task_source/dist/AI Task Monitor.app" \
           "$task_source/dist/AI Task Monitor.app/Contents" "$task_source/dist/AI Task Monitor.app/Contents/Resources" \
           "$task_root/release-artifacts"; do
    test -d "$dir" && test ! -L "$dir" || reject 'directory identity'
done

task_iconset="$3"
task_icon_parent="${task_iconset%/AppIcon.iconset}"
task_icon_name="${task_icon_parent##*/}"
[[ "$task_icon_name" =~ ^aitm-release[.][A-Za-z0-9]{8}$ ]] || reject 'iconset name'
test "$task_iconset" = "$task_root/temp/$task_icon_name/AppIcon.iconset" || reject 'iconset path'
test -d "$task_icon_parent" && test ! -L "$task_icon_parent" || reject 'iconset parent'
test "$(cd -P "$task_icon_parent" && pwd -P)" = "$task_icon_parent" || reject 'iconset parent identity'
test -d "$task_iconset" && test ! -L "$task_iconset" || reject 'iconset identity'
test ! -L "$5" || reject 'output symlink'
test ! -L "$task_root/release-artifacts/build-method.txt" && test ! -L "$task_root/release-artifacts/icon-fallback-used" || reject 'method symlink'

verify() {
    local file="$1" expected="$2" actual
    test -f "$file" && test ! -L "$file" || reject 'input file'
    actual="$(/usr/bin/shasum -a 256 "$file")"
    test "${actual%% *}" = "$expected" || reject 'input digest'
}

sha16=26a0c117876b90172a4d2c6dfd0ce90f8775a02505f2117d308c9b9b942fa336
sha32=e544079c37c58fe7b048f6c864565eba81f90f342f4ef5fe4d4a1d1e959600ec
sha64=b415afb520d28d8cc8ba68d45a83c5c0c65852058871ea952daeaad0319016f2
sha128=7e4659d724e69ca3ae7e40acb101ff72714f602bfe35765f209343ae1ed21505
sha256=c4f1f3b288b41079799b4f8b8134df47d1a3dd17274813fab7f1fad587e901d6
sha512=79d37b5a4e4db2af0c3d7c15c374bd5415d7ea1c2288fe2f9a33f9c29927003b
sha1024=41c12eba042d3a6184aa10ff296597d2f28d4fab700a7adea9714638b5def3e0
sha_icns=ec9ba4d716b1988dfad213127d9d2dffbb37e188199f8c7576d4325774e78e67
task_assets="$task_source/assets/app-icon"
verify "$task_assets/icon-16.png" "$sha16"
verify "$task_assets/icon-32.png" "$sha32"
verify "$task_assets/icon-64.png" "$sha64"
verify "$task_assets/icon-128.png" "$sha128"
verify "$task_assets/icon-256.png" "$sha256"
verify "$task_assets/icon-512.png" "$sha512"
verify "$task_assets/icon-1024.png" "$sha1024"

shopt -s nullglob dotglob
task_entries=("$task_iconset"/*)
test "${#task_entries[@]}" = 10 || reject 'iconset entries'
verify "$task_iconset/icon_16x16.png" "$sha16"
verify "$task_iconset/icon_16x16@2x.png" "$sha32"
verify "$task_iconset/icon_32x32.png" "$sha32"
verify "$task_iconset/icon_32x32@2x.png" "$sha64"
verify "$task_iconset/icon_128x128.png" "$sha128"
verify "$task_iconset/icon_128x128@2x.png" "$sha256"
verify "$task_iconset/icon_256x256.png" "$sha256"
verify "$task_iconset/icon_256x256@2x.png" "$sha512"
verify "$task_iconset/icon_512x512.png" "$sha512"
verify "$task_iconset/icon_512x512@2x.png" "$sha1024"
task_fallback="$task_root/source/.github/macos-icon-fallback-20261123/AppIcon.icns"
verify "$task_fallback" "$sha_icns"

if "$task_native" "$@"; then
    test -s "$5" && test ! -L "$5" || reject 'native output'
    printf '%s\n' 'Icon: native iconutil.' >> "$task_root/release-artifacts/build-method.txt"
else
    test ! -L "$5" || reject 'fallback output symlink'
    /bin/cp -f "$task_fallback" "$5"
    verify "$5" "$sha_icns"
    printf '%s\n' "$sha_icns" > "$task_root/release-artifacts/icon-fallback-used"
    printf '%s\n' "Icon: published v0.3.7-alpha ICNS fallback, SHA-256 $sha_icns." >> "$task_root/release-artifacts/build-method.txt"
fi
