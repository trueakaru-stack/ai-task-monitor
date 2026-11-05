param([Parameter(Mandatory=$true)][string]$Source)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -Path $Source -ReferencedAssemblies System.Web.Extensions
$parse=[AITaskMonitor.ClaudeLoop.Channel].GetMethod('Parse',[Reflection.BindingFlags]'NonPublic,Instance')
if($null -eq $parse){throw 'Reference parser was not found.'}
$fingerprint='a'*64
$fixtures=@(
    @{Name='reset'; Raw='{"session":"one","kind":"reset"}'},
    @{Name='edit'; Raw='{"session":"one","kind":"edit"}'},
    @{Name='stop'; Raw='{"session":"one","kind":"stop"}'},
    @{Name='started'; Raw=('{"session":"one","tool":"call_1","kind":"start","fingerprint":"'+$fingerprint+'"}')},
    @{Name='failed'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":7}')},
    @{Name='negative failure'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":-2}')},
    @{Name='success'; Raw=('{"session":"one","tool":"call_1","kind":"success","fingerprint":"'+$fingerprint+'"}')},
    @{Name='unexpected field'; Raw='{"session":"one","kind":"reset","command":"secret"}'},
    @{Name='unknown kind'; Raw='{"session":"one","kind":"unexpected"}'},
    @{Name='missing session'; Raw='{"kind":"reset"}'},
    @{Name='unsafe session'; Raw='{"session":"../one","kind":"reset"}'},
    @{Name='numeric session'; Raw='{"session":12,"kind":"reset"}'},
    @{Name='bad fingerprint'; Raw='{"session":"one","tool":"call_1","kind":"start","fingerprint":"not-a-hash"}'},
    @{Name='uppercase fingerprint'; Raw=('{"session":"one","tool":"call_1","kind":"start","fingerprint":"'+('A'*64)+'"}')},
    @{Name='zero failure'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":0}')},
    @{Name='string code'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":"7"}')},
    @{Name='float code'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":7.0}')},
    @{Name='large code'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":2147483648}')},
    @{Name='integer lower bound'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":-2147483648}')},
    @{Name='duplicate kind'; Raw='{"session":"one","kind":"invalid","kind":"reset"}'},
    @{Name='invalid overwritten kind'; Raw='{"session":"one","kind":"reset","kind":"invalid"}'},
    @{Name='extra escaped field'; Raw='{"session":"one","kind":"reset","\u0063ommand":"secret"}'},
    @{Name='truncated JSON'; Raw='{"session":"one","kind":"reset"'},
    @{Name='array root'; Raw='[{"session":"one","kind":"reset"}]'},
    @{Name='null root'; Raw='null'},
    @{Name='nested session'; Raw='{"session":{"id":"one"},"kind":"reset"}'},
    @{Name='optional numeric tool'; Raw='{"session":"one","tool":42,"kind":"edit"}'},
    @{Name='unicode escape'; Raw='{"session":"\u006fne","kind":"reset"}'},
    @{Name='max safe ID'; Raw=('{"session":"'+('x'*128)+'","kind":"reset"}')},
    @{Name='too long ID'; Raw=('{"session":"'+('x'*129)+'","kind":"reset"}')},
    @{Name='legacy non-JSON leading zero'; Raw=('{"session":"one","tool":"call_1","kind":"failed","fingerprint":"'+$fingerprint+'","exitCode":07}'); Stricter=$true}
)
$name='AITM.Test.LegacyClaude.'+[guid]::NewGuid().ToString('N')
$channel=[AITaskMonitor.ClaudeLoop.Channel]::new($name)
try {
    $output=foreach($fixture in $fixtures){
        $bytes=[Text.Encoding]::UTF8.GetBytes([string]$fixture.Raw)
        $entry=$parse.Invoke($channel,@(,$bytes))
        $expected=if($null -eq $entry){$null}else{[ordered]@{
            Session=$entry.SessionId; Tool=$entry.ToolId; Kind=$entry.Kind
            Fingerprint=$entry.Fingerprint; ExitCode=$entry.ExitCode
        }}
        [ordered]@{Name=$fixture.Name; Raw=$fixture.Raw; Expected=$expected; Stricter=[bool]$fixture.Stricter}
    }
    ConvertTo-Json -InputObject @($output) -Depth 8 -Compress
} finally {$channel.Dispose()}
