param(
    [Parameter(Mandatory=$true)][string]$ReferenceDirectory,
    [Parameter(Mandatory=$true)][string]$FramesDirectory,
    [switch]$CompareCompact,
    [switch]$ReportOnly
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing @'
using System;
using System.Drawing;
public sealed class PixelComparison {
    public int Different;
    public int OutsideMasks;
    public int MinX = int.MaxValue, MinY = int.MaxValue, MaxX = -1, MaxY = -1;
    public int OutsideMinX = int.MaxValue, OutsideMinY = int.MaxValue, OutsideMaxX = -1, OutsideMaxY = -1;
}
public static class ReferenceFrameComparison {
    public static PixelComparison Compare(string original, string actual, string mode) {
        using (var a = new Bitmap(original)) using (var b = new Bitmap(actual)) {
            if (a.Width != b.Width || a.Height != b.Height) throw new ArgumentException("Frame dimensions differ.");
            var result = new PixelComparison();
            for (int y = 0; y < a.Height; y++) for (int x = 0; x < a.Width; x++) {
                if (a.GetPixel(x,y).ToArgb() == b.GetPixel(x,y).ToArgb()) continue;
                result.Different++; result.MinX = Math.Min(result.MinX,x); result.MinY = Math.Min(result.MinY,y);
                result.MaxX = Math.Max(result.MaxX,x); result.MaxY = Math.Max(result.MaxY,y);
                bool clock = mode == "active" && x >= 160 && x <= 250 && y >= 465 && y <= 490;
                bool gapTitle = mode == "gap" && x >= 60 && x <= 430 && y >= 188 && y <= 212;
                // The reference task is unconfirmed with a confirmed plan; a real gap
                // produces an unconfirmed plan, so its metadata text and time differ.
                bool gapMetadata = mode == "gap" && x >= 60 && x <= 320 && y >= 395 && y <= 420;
                bool oldPlanTitle = mode == "old-plan" && x >= 60 && x <= 430 && y >= 188 && y <= 212;
                bool oldPlanActivity = mode == "old-plan" && x >= 80 && x <= 430 && y >= 215 && y <= 238;
                bool oldPlanClock = mode == "old-plan" && x >= 160 && x <= 320 && y >= 395 && y <= 420;
                bool compactTitle = mode == "compact-single" && x >= 40 && x <= 355 && y >= 75 && y <= 100;
                bool compactActivity = mode == "compact-single" && x >= 60 && x <= 355 && y >= 100 && y <= 120;
                bool compactMultiTitle = mode == "compact-multi" && x >= 40 && x <= 355 && y >= 75 && y <= 119;
                bool compactMultiActivity = mode == "compact-multi" && x >= 60 && x <= 355 && y >= 119 && y <= 140;
                if (!clock && !gapTitle && !gapMetadata && !oldPlanTitle && !oldPlanActivity && !oldPlanClock &&
                    !compactTitle && !compactActivity && !compactMultiTitle && !compactMultiActivity) {
                    result.OutsideMasks++; result.OutsideMinX = Math.Min(result.OutsideMinX,x); result.OutsideMinY = Math.Min(result.OutsideMinY,y);
                    result.OutsideMaxX = Math.Max(result.OutsideMaxX,x); result.OutsideMaxY = Math.Max(result.OutsideMaxY,y);
                }
            }
            return result;
        }
    }
}
'@

$cases = @(
    @('empty','empty','none'),
    @('full-active','active','active'),
    @('compact-active','compact','none'),
    @('kimi-unconfirmed','state-kimi','none'),
    @('task-unconfirmed','state-gap','gap'),
    @('plan-unconfirmed','state-old-plan','old-plan')
)
$failures = 0
foreach ($theme in @('dark','light')) {
    foreach ($language in @('ru','en')) {
        foreach ($case in $cases) {
            $reference = Join-Path (Join-Path $ReferenceDirectory "$theme-$language") ($case[0] + '.png')
            $actual = Join-Path $FramesDirectory "$theme-$language-$($case[1]).png"
            $result = [ReferenceFrameComparison]::Compare($reference, $actual, $case[2])
            Write-Output ("$theme-$language-$($case[1]): different=$($result.Different), outside_masks=$($result.OutsideMasks), outside_bounds=$($result.OutsideMinX),$($result.OutsideMinY)-$($result.OutsideMaxX),$($result.OutsideMaxY)")
            if ($result.OutsideMasks -ne 0) { $failures++ }
        }
        if ($CompareCompact) {
            foreach ($case in @(@('old-plan','state-old-plan','compact-single'),@('gap','state-gap','compact-single'),
                @('unknown','state-kimi','compact-single'),@('unknown','state-hermes-wait','compact-single'),
                @('multi','state-multi','compact-multi'))) {
                $reference = Join-Path $FramesDirectory "reference-$theme-$language-$($case[0])-compact.png"
                $actual = Join-Path $FramesDirectory "$theme-$language-$($case[1])-compact.png"
                $result = [ReferenceFrameComparison]::Compare($reference, $actual, $case[2])
                Write-Output ("$theme-$language-$($case[1])-compact: different=$($result.Different), outside_masks=$($result.OutsideMasks), outside_bounds=$($result.OutsideMinX),$($result.OutsideMinY)-$($result.OutsideMaxX),$($result.OutsideMaxY)")
                if ($result.OutsideMasks -ne 0) { $failures++ }
            }
        }
    }
}
if ($failures -gt 0 -and -not $ReportOnly) { throw "$failures reference comparisons differ outside the documented data masks." }
