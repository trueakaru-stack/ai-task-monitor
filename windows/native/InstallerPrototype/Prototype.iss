; Synthetic CI-only installer. This is not a product installer or migration.
#define OutputDirectory GetEnv("AITM_SYNTHETIC_OUTPUT")
#if OutputDirectory == ""
  #error AITM_SYNTHETIC_OUTPUT must name a disposable CI directory.
#endif

[Setup]
AppId={{6618EDCB-E544-47D0-B713-02E05E66F198}
AppName=AI Task Monitor Synthetic Installer Test
AppVersion=0.0.0.1
DefaultDirName={code:TestDestination}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableFinishedPage=yes
UsePreviousAppDir=no
UsePreviousLanguage=no
PrivilegesRequired=lowest
CloseApplications=no
RestartApplications=no
ChangesEnvironment=no
ChangesAssociations=no
CreateUninstallRegKey=no
Uninstallable=yes
UninstallLogMode=new
UninstallFilesDir={app}
OutputDir={#OutputDirectory}
OutputBaseFilename=AITM-InstallerPrototype-CI-ONLY
Compression=lzma2
SolidCompression=yes

[Files]
; Deliberately retained on uninstall until ownership-safe deletion is designed.
Source: "Fixtures\payload.txt"; DestDir: "{app}"; Flags: uninsneveruninstall
Source: "Fixtures\manifest.txt"; DestDir: "{app}"; Flags: uninsneveruninstall

[Code]
function IsSyntheticCi: Boolean;
begin
  Result := (GetEnv('GITHUB_ACTIONS') = 'true') and
    (GetEnv('RUNNER_ENVIRONMENT') = 'github-hosted') and
    (GetEnv('AITM_SYNTHETIC_INSTALLER') = '1') and
    (Length(GetEnv('AITM_SYNTHETIC_NONCE')) = 32) and
    (GetEnv('AITM_SYNTHETIC_DESTINATION') <> '');
end;

function TestDestination(Param: String): String;
begin
  Result := GetEnv('AITM_SYNTHETIC_DESTINATION');
end;

function InitializeSetup: Boolean;
begin
  Result := IsSyntheticCi;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Target: String;
begin
  Result := '';
  Target := GetEnv('AITM_SYNTHETIC_DESTINATION');
  if (not IsSyntheticCi) or (CompareText(ExpandConstant('{app}'), Target) <> 0) then
    Result := 'Synthetic CI destination is required.'
  else if FileOrDirExists(Target) then
    Result := 'Synthetic installation requires a new destination.';
end;

function InitializeUninstall: Boolean;
begin
  Result := IsSyntheticCi and
    (CompareText(ExpandConstant('{app}'), GetEnv('AITM_SYNTHETIC_DESTINATION')) = 0);
end;

