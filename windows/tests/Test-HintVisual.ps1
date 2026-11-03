$ErrorActionPreference="Stop"
Add-Type -AssemblyName System.Drawing
$app=Join-Path (Join-Path $PSScriptRoot "..\app") "CodexProgress.ps1"
$root=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) ("ai-task-monitor-hint-test-"+[Guid]::NewGuid().ToString("N"))))
$tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if(-not $root.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test directory."}
[void][IO.Directory]::CreateDirectory($root)
try{
    foreach($theme in @("dark","light")){
        $base=Join-Path $root ("base-"+$theme+".png")
        $composite=Join-Path $root ("composite-"+$theme+".png")
        $raw=Join-Path $root ("raw-"+$theme+".png")
        & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $app -PreviewActiveTasks 1 -ThemeOverride $theme -CompactMode -SnapshotFile $base -HintSnapshotFile $composite -HintRawSnapshotFile $raw
        if($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $raw)){throw "The WPF tooltip preview failed for $theme."}
        $bitmap=[Drawing.Bitmap]::new($raw)
        try{
            for($x=0;$x -lt $bitmap.Width;$x++){
                if($bitmap.GetPixel($x,0).A -ne 0 -or $bitmap.GetPixel($x,$bitmap.Height-1).A -ne 0){throw "The tooltip shadow is clipped at a horizontal edge in $theme."}
            }
            for($y=0;$y -lt $bitmap.Height;$y++){
                if($bitmap.GetPixel(0,$y).A -ne 0 -or $bitmap.GetPixel($bitmap.Width-1,$y).A -ne 0){throw "The tooltip shadow is clipped at a vertical edge in $theme."}
            }
            if($bitmap.GetPixel([int]($bitmap.Width/2),[int]($bitmap.Height/2)).A -eq 0){throw "The tooltip interior is unexpectedly transparent in $theme."}
        }finally{$bitmap.Dispose()}
    }
    Write-Output "Tooltip visuals: transparent outer edges and visible content verified in both themes."
}finally{
    if(Test-Path -LiteralPath $root){
        $resolved=(Resolve-Path -LiteralPath $root).Path
        if($resolved -ne $root -or -not $resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe test cleanup path."}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
