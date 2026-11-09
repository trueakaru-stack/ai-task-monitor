#!/bin/bash
set -euo pipefail
INPUT="$GITHUB_WORKSPACE/.github/limited-audit/combined-counts-20261109"
source "$INPUT/scripts/sandbox.sh"
BASE="$RUNNER_TEMP/aitm-unified-baseline"
test ! -e "$BASE"
mkdir -p "$BASE" "$OUT/plan/base" "$OUT/plan/candidate" "$OUT/settings/base" "$OUT/settings/disabled" "$OUT/settings/enabled"
git -C "$GITHUB_WORKSPACE" -c core.autocrlf=false archive bbef0654fdb2789c62c8d8511576f05b75a289ca macos | tar -xf - -C "$BASE"
run_strict /usr/bin/python3 -I -S -B "$INPUT/scripts/network-probe.py" strict | tee "$OUT/logs/network-visual.log"
/usr/bin/python3 -I -S -B - "$RUNNER_TEMP/aitm-unified-home" "$WORK/macos/integrations" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
home, assets = map(Path, sys.argv[1:])
source = home / ".config/opencode"
folder, plugins = source / "ai-task-monitor-data", source / "plugins"
folder.mkdir(parents=True); plugins.mkdir(parents=True)
names = ("provider-events.mjs", "provider-observers.mjs", "provider-transport.mjs")
hashes = {}
for name in names:
    data = (assets / name).read_bytes()
    (folder / name).write_bytes(data)
    hashes[name] = hashlib.sha256(data).hexdigest().upper()
shim = (assets / "opencode-entry.js").read_bytes()
(plugins / "ai-task-monitor.js").write_bytes(shim)
(folder / "manifest.json").write_text(json.dumps({"owner":"AI Task Monitor OpenCode v1", "files":hashes, "shim":hashlib.sha256(shim).hexdigest().upper()}), encoding="utf-8")
print("Created synthetic OpenCode profile")
PY
for item in base candidate; do
  if [ "$item" = base ]; then directory="$BASE/macos"; else directory="$WORK/macos"; fi
  (cd "$directory" && run_strict /usr/bin/xcrun swift build --disable-sandbox 2>&1 | tee "$OUT/logs/visual-build-$item.log")
  (cd "$directory" && AITM_CLAUDE_PLAN_PREVIEW_ONLY=1 run_strict .build/debug/AITaskMonitor --render-previews "$OUT/plan/$item")
  count="$(find "$OUT/plan/$item" -type f -name '*.png' | wc -l | tr -d ' ')"
  test "$count" = 64
done
for item in base candidate; do
  if [ "$item" = base ]; then directory="$BASE/macos"; else directory="$WORK/macos"; fi
  mkdir -p "$OUT/tabs/$item"
  /usr/bin/python3 -I -S -B "$INPUT/visual/prepare_tab_counts.py" "$directory"
  (cd "$directory" && run_strict /usr/bin/xcrun swift build --disable-sandbox 2>&1 | tee "$OUT/logs/tabs-build-$item.log")
  (cd "$directory" && AITM_TAB_COUNT_PREVIEW_ONLY=1 run_strict .build/debug/AITaskMonitor --render-previews "$OUT/tabs/$item")
  count="$(find "$OUT/tabs/$item" -type f -name '*.png' | wc -l | tr -d ' ')"
  test "$count" = 24
done
run_visual() {
  local directory="$1" target="$2" profile="$3" enabled="$4" output="$5"
  (cd "$directory" && AITM_RESTART_VISUAL_ONLY=1 AITM_RESTART_VISUAL_TARGET="$target" \
    AITM_RESTART_PROFILE="$profile" AITM_RESTART_FORCE_ENABLED="$enabled" \
    run_strict .build/debug/AITaskMonitor --render-previews "$output")
}
/usr/bin/python3 -I -S -B "$INPUT/visual/prepare_visual_warmup_hermes.py" "$BASE/macos" baseline
/usr/bin/python3 -I -S -B "$INPUT/visual/prepare_hermes_preview.py" "$BASE/macos"
(cd "$BASE/macos" && run_strict /usr/bin/xcrun swift build --disable-sandbox 2>&1 | tee "$OUT/logs/settings-build-base.log")
for scenario in opencode:connected deepseek:connected deepseek:disconnected hermes:commands; do
  target="${scenario%:*}"; profile="${scenario#*:}"
  mkdir -p "$OUT/settings/base/$target-$profile"
  run_visual "$BASE/macos" "$target" "$profile" 0 "$OUT/settings/base/$target-$profile"
done
/usr/bin/python3 -I -S -B "$INPUT/visual/prepare_visual_warmup_hermes.py" "$WORK/macos" candidate
/usr/bin/python3 -I -S -B "$INPUT/visual/prepare_hermes_preview.py" "$WORK/macos"
/usr/bin/python3 -I -S -B "$INPUT/visual/prepare_long_profile.py" "$WORK/macos"
(cd "$WORK/macos" && run_strict /usr/bin/xcrun swift build --disable-sandbox 2>&1 | tee "$OUT/logs/settings-build-candidate.log")
for scenario in opencode:connected deepseek:connected deepseek:disconnected hermes:commands; do
  target="${scenario%:*}"; profile="${scenario#*:}"
  mkdir -p "$OUT/settings/disabled/$target-$profile"
  run_visual "$WORK/macos" "$target" "$profile" 0 "$OUT/settings/disabled/$target-$profile"
  if [ "$profile" = connected ]; then
    mkdir -p "$OUT/settings/enabled/$target-$profile"
    run_visual "$WORK/macos" "$target" "$profile" 1 "$OUT/settings/enabled/$target-$profile"
  fi
done
mkdir -p "$OUT/settings/enabled/deepseek-long"
run_visual "$WORK/macos" deepseek long 1 "$OUT/settings/enabled/deepseek-long"
for item in base:16 disabled:16 enabled:12; do
  name="${item%:*}"; expected="${item#*:}"
  count="$(find "$OUT/settings/$name" -type f -name '*.png' | wc -l | tr -d ' ')"
  test "$count" = "$expected"
done
cp "$INPUT/candidate.sha256" "$INPUT/source-pins.json" "$OUT/"
