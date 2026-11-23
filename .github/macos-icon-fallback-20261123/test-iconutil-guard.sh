#!/bin/bash
set -euo pipefail

test "$#" = 1
task_original="$1"
test -d "$task_original/macos/assets/app-icon"
test "${GITHUB_ACTIONS:-}" = true && test "${RUNNER_ENVIRONMENT:-}" = github-hosted && test "${RUNNER_OS:-}" = macOS
task_synthetic="${AITM_SYNTHETIC_TEST_ROOT:?}"
test -d "$task_synthetic" && test ! -L "$task_synthetic"
task_test="$(/usr/bin/mktemp -d "$task_synthetic/icon-guard.XXXXXXXX")"
case "$task_test" in "$task_synthetic"/icon-guard.????????) ;; *) exit 1;; esac
test "$(cd -P "$task_test" && pwd -P)" = "$task_test"
task_source="$task_test/source/macos"
task_assets="$task_source/assets/app-icon"
task_fixture="$task_test/source/.github/macos-icon-fallback-20261123/AppIcon.icns"
task_wrapper="$task_original/.github/macos-icon-fallback-20261123/iconutil-ci.sh"
task_output='dist/AI Task Monitor.app/Contents/Resources/AppIcon.icns'
mkdir -p "$task_assets" "${task_fixture%/*}" "$task_source/dist/AI Task Monitor.app/Contents/Resources" "$task_test/release-artifacts" "$task_test/temp"
for size in 16 32 64 128 256 512 1024; do
    /bin/cp "$task_original/macos/assets/app-icon/icon-$size.png" "$task_assets/icon-$size.png"
done
/bin/cp "$task_original/.github/macos-icon-fallback-20261123/AppIcon.icns" "$task_fixture"
task_parent="$(/usr/bin/mktemp -d "$task_test/temp/aitm-release.XXXXXXXX")"
task_iconset="$task_parent/AppIcon.iconset"
mkdir -p "$task_iconset"
/bin/cp "$task_assets/icon-16.png" "$task_iconset/icon_16x16.png"
/bin/cp "$task_assets/icon-32.png" "$task_iconset/icon_16x16@2x.png"
/bin/cp "$task_assets/icon-32.png" "$task_iconset/icon_32x32.png"
/bin/cp "$task_assets/icon-64.png" "$task_iconset/icon_32x32@2x.png"
/bin/cp "$task_assets/icon-128.png" "$task_iconset/icon_128x128.png"
/bin/cp "$task_assets/icon-256.png" "$task_iconset/icon_128x128@2x.png"
/bin/cp "$task_assets/icon-256.png" "$task_iconset/icon_256x256.png"
/bin/cp "$task_assets/icon-512.png" "$task_iconset/icon_256x256@2x.png"
/bin/cp "$task_assets/icon-512.png" "$task_iconset/icon_512x512.png"
/bin/cp "$task_assets/icon-1024.png" "$task_iconset/icon_512x512@2x.png"
cat > "$task_test/native-iconutil" <<'STUB'
#!/bin/bash
printf 'called\n' > "$AITM_RELEASE_ROOT/native-called"
exit 1
STUB
chmod 700 "$task_test/native-iconutil"
export AITM_RELEASE_ROOT="$task_test" AITM_ICON_WRAPPER_TEST_MODE=1
cd "$task_source"

expect_rejected() {
    local label="$1"; shift
    if /bin/bash "$task_wrapper" "$@" >"$task_test/rejection.log" 2>&1; then
        echo "Guard unexpectedly accepted $label" >&2; exit 1
    fi
    test ! -e "$task_test/native-called"
    test ! -e "$task_output" && test ! -L "$task_output"
    test ! -e "$task_test/release-artifacts/icon-fallback-used"
    echo "Rejected $label"
}

expect_rejected 'extra argument' -c icns "$task_iconset" -o "$task_output" extra
expect_rejected 'wrong operation' -c iconset "$task_iconset" -o "$task_output"
expect_rejected 'wrong output' -c icns "$task_iconset" -o 'dist/other.icns'
expect_rejected 'wrong input path' -c icns "$task_parent" -o "$task_output"

/bin/cp "$task_assets/icon-32.png" "$task_assets/icon-16.png"
expect_rejected 'changed source PNG' -c icns "$task_iconset" -o "$task_output"
/bin/cp "$task_original/macos/assets/app-icon/icon-16.png" "$task_assets/icon-16.png"

/bin/cp "$task_assets/icon-32.png" "$task_iconset/icon_16x16.png"
expect_rejected 'changed iconset PNG' -c icns "$task_iconset" -o "$task_output"
/bin/cp "$task_assets/icon-16.png" "$task_iconset/icon_16x16.png"

/bin/rm "$task_iconset/icon_16x16.png"
/bin/ln -s "$task_assets/icon-16.png" "$task_iconset/icon_16x16.png"
expect_rejected 'iconset symlink' -c icns "$task_iconset" -o "$task_output"
/bin/rm "$task_iconset/icon_16x16.png"
/bin/cp "$task_assets/icon-16.png" "$task_iconset/icon_16x16.png"

/usr/bin/touch "$task_iconset/.unexpected"
expect_rejected 'extra iconset entry' -c icns "$task_iconset" -o "$task_output"
/bin/rm "$task_iconset/.unexpected"

printf x >> "$task_fixture"
expect_rejected 'changed ICNS fixture' -c icns "$task_iconset" -o "$task_output"
/bin/cp "$task_original/.github/macos-icon-fallback-20261123/AppIcon.icns" "$task_fixture"

/bin/ln -s "$task_test/unused-target" "$task_output"
if /bin/bash "$task_wrapper" -c icns "$task_iconset" -o "$task_output" >"$task_test/rejection.log" 2>&1; then
    echo 'Guard unexpectedly accepted output symlink' >&2; exit 1
fi
test ! -e "$task_test/native-called" && test ! -e "$task_test/unused-target"
/bin/rm "$task_output"
echo 'Rejected output symlink'

task_resources='dist/AI Task Monitor.app/Contents/Resources'
/bin/rmdir "$task_resources"
mkdir -p "$task_test/alternate-resources"
/bin/ln -s "$task_test/alternate-resources" "$task_resources"
expect_rejected 'output directory symlink' -c icns "$task_iconset" -o "$task_output"
/bin/rm "$task_resources"
mkdir -p "$task_resources"

if AITM_RELEASE_ROOT="${task_original%/source}" AITM_ICON_WRAPPER_TEST_MODE=1 /bin/bash "$task_wrapper" -c icns "$task_iconset" -o "$task_output" >"$task_test/rejection.log" 2>&1; then
    echo 'Guard unexpectedly accepted test mode on the real build root' >&2; exit 1
fi
test ! -e "$task_test/native-called"
echo 'Rejected test mode outside the disposable test root'

/bin/bash "$task_wrapper" -c icns "$task_iconset" -o "$task_output"
test -f "$task_test/native-called"
/usr/bin/cmp "$task_fixture" "$task_output"
test "$(cat "$task_test/release-artifacts/icon-fallback-used")" = ec9ba4d716b1988dfad213127d9d2dffbb37e188199f8c7576d4325774e78e67
grep -Fq 'Icon: published v0.3.7-alpha ICNS fallback' "$task_test/release-artifacts/build-method.txt"
echo 'Verified fallback after controlled native iconutil failure'
