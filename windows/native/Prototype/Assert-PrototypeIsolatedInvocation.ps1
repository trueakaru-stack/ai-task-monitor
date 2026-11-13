function Assert-PrototypeIsolatedInvocation {
    param(
        [Parameter(Mandatory=$true)][string[]]$ProcessArguments,
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [Parameter(Mandatory=$true)][string]$ExecutablePath,
        [Parameter(Mandatory=$true)][string]$PowerShellRoot,
        [Parameter(Mandatory=$true)][string]$Edition
    )

    $message = 'For safety, run this test in a separate PowerShell process using powershell.exe -NoProfile -ExecutionPolicy Bypass -File <path to Test-Prototype.ps1> and its required arguments. Do not use -NoExit.'
    if ($Edition -eq 'Desktop') { $executableName = 'powershell.exe' }
    elseif ($Edition -eq 'Core') { $executableName = 'pwsh.exe' }
    else { throw $message }

    try {
        $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $PowerShellRoot $executableName))
        $actualExecutable = [IO.Path]::GetFullPath($ExecutablePath)
        $expectedScript = [IO.Path]::GetFullPath($ScriptPath)
    } catch { throw $message }
    if (-not [string]::Equals($expectedExecutable, $actualExecutable, [StringComparison]::OrdinalIgnoreCase)) { throw $message }

    # Only known host options are accepted. In particular, -NoExit and command
    # modes cannot make this test clear the caller's interactive environment.
    $index = 1
    while ($index -lt $ProcessArguments.Count) {
        $argument = $ProcessArguments[$index]
        if ($argument -in @('-NoProfile','-NonInteractive','-NoLogo','-Sta')) { $index++; continue }
        if ($argument -eq '-ExecutionPolicy') {
            if ($index + 1 -ge $ProcessArguments.Count -or $ProcessArguments[$index + 1] -notin @('Bypass','RemoteSigned','AllSigned','Restricted','Unrestricted','Default','Undefined')) { throw $message }
            $index += 2
            continue
        }
        if ($argument -eq '-WindowStyle') {
            if ($index + 1 -ge $ProcessArguments.Count -or $ProcessArguments[$index + 1] -notin @('Hidden','Normal','Minimized','Maximized')) { throw $message }
            $index += 2
            continue
        }
        if ($argument -eq '-File') {
            if ($index + 1 -ge $ProcessArguments.Count) { throw $message }
            try {
                $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProcessArguments[$index + 1])
                $actualScript = [IO.Path]::GetFullPath($providerPath)
            } catch { throw $message }
            if ([string]::Equals($expectedScript, $actualScript, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        throw $message
    }
    throw $message
}
