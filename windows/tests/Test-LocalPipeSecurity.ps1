$ErrorActionPreference = 'Stop'
$appRoot = Join-Path $PSScriptRoot '../app'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path @(
    (Join-Path $appRoot 'integrations/ProviderEventState.cs'),
    (Join-Path $appRoot 'integrations/ProviderEventChannel.cs'),
    (Join-Path $appRoot 'ClaudeLoopChannel.cs')
) -ReferencedAssemblies System.Web.Extensions
Add-Type @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class LocalPipeSecurityTest {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeInfo(SafePipeHandle pipe, out uint flags,
        out uint outBuffer, out uint inBuffer, out uint maxInstances);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetHandleInformation(SafePipeHandle handle, out uint flags);
}
'@

function Assert([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Check-Channel($channel) {
    try {
        $field = $channel.GetType().GetField('active', [Reflection.BindingFlags]'NonPublic,Instance')
        $server = $field.GetValue($channel)
        Assert ($null -ne $server) 'A synthetic pipe was not created.'
        [uint32]$mode=0; [uint32]$outBuffer=0; [uint32]$inBuffer=0; [uint32]$maxInstances=0; [uint32]$handleFlags=0
        Assert ([LocalPipeSecurityTest]::GetNamedPipeInfo($server.SafePipeHandle, [ref]$mode, [ref]$outBuffer, [ref]$inBuffer, [ref]$maxInstances)) 'Could not read pipe mode.'
        Assert (($mode -band 8) -ne 0) 'The pipe did not reject remote clients.'
        Assert ($outBuffer -eq 4096 -and $inBuffer -eq 4096 -and $maxInstances -eq 1) 'The pipe geometry changed.'
        Assert ([LocalPipeSecurityTest]::GetHandleInformation($server.SafePipeHandle, [ref]$handleFlags)) 'Could not read pipe handle flags.'
        Assert (($handleFlags -band 1) -eq 0) 'The pipe handle was inheritable.'

        $nameField = $channel.GetType().GetField('name', [Reflection.BindingFlags]'NonPublic,Instance')
        $pipeName = [string]$nameField.GetValue($channel)
        $duplicate = $null; $rejected = $false
        try {
            $duplicate = [IO.Pipes.NamedPipeServerStream]::new($pipeName, [IO.Pipes.PipeDirection]::InOut,
                1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
        } catch { $rejected = $true }
        finally { if ($null -ne $duplicate) { $duplicate.Dispose() } }
        Assert $rejected 'A second server acquired the same synthetic pipe name.'

        $acl = $server.GetAccessControl()
        Assert $acl.AreAccessRulesProtected 'The pipe inherited access rules.'
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$allowed.Add([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        [void]$allowed.Add('S-1-5-18')
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        Assert ($rules.Count -eq $allowed.Count) 'Unexpected pipe access-rule count.'
        foreach ($rule in $rules) {
            Assert (-not $rule.IsInherited -and $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $allowed.Contains($rule.IdentityReference.Value) -and $seen.Add($rule.IdentityReference.Value) -and
                ($rule.PipeAccessRights -band [IO.Pipes.PipeAccessRights]::FullControl) -eq [IO.Pipes.PipeAccessRights]::FullControl) 'Unexpected pipe access rule.'
        }
        Assert ($seen.SetEquals($allowed)) 'The current user or SYSTEM access rule is missing.'
    } finally { $channel.Dispose() }
    Assert $channel.IsStopped 'The synthetic channel did not stop.'
}

$suffix = [Guid]::NewGuid().ToString('N')
Check-Channel ([AITaskMonitor.ExternalProviders.EventChannel]::new('AITaskMonitor.Test.Provider.' + $suffix))
Check-Channel ([AITaskMonitor.ClaudeLoop.Channel]::new('AITaskMonitor.Test.Claude.' + $suffix))
Write-Output 'Both synthetic local channels reject remote clients and retain the protected user/SYSTEM ACL.'
