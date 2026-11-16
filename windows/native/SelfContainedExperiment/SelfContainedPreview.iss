; Synthetic CI-only packaging experiment. This is not a product installer.
; Its uninstaller intentionally retains the entire application payload.
#define PayloadDirectory GetEnv("AITM_SC_PAYLOAD")
#define OutputDirectory GetEnv("AITM_SC_OUTPUT")
#if (PayloadDirectory == "") || (OutputDirectory == "")
  #error A synthetic payload and output directory are required.
#endif

[Setup]
AppId={{1DB5A738-756E-43F8-AB9A-8993A5DAF749}
AppName=AI Task Monitor Synthetic Self-Contained Installer Test
AppVersion=0.0.0.1
DefaultDirName={code:TestDestination}
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableFinishedPage=yes
UsePreviousAppDir=no
UsePreviousLanguage=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=no
RestartApplications=no
ChangesEnvironment=no
ChangesAssociations=no
CreateUninstallRegKey=no
Uninstallable=yes
UninstallLogMode=new
UninstallFilesDir={app}
OutputDir={#OutputDirectory}
OutputBaseFilename=AITM-SelfContainedInstaller-CI-ONLY
Compression=lzma2
SolidCompression=yes

[Files]
; Retain all files, including nested files. Full safe removal is not implemented.
Source: "{#PayloadDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs uninsneveruninstall

[Code]
function IsSyntheticCi: Boolean;
var
  Root, Nonce: String;
  I: Integer;
begin
  Result := False;
  Root := GetEnv('AITM_SC_TEST_ROOT');
  Nonce := GetEnv('AITM_SC_NONCE');
  if (GetEnv('CI') <> 'true') or (GetEnv('GITHUB_ACTIONS') <> 'true') or
     (GetEnv('RUNNER_ENVIRONMENT') <> 'github-hosted') or
     (GetEnv('RUNNER_OS') <> 'Windows') or (GetEnv('AITM_SC_INSTALLER') <> '1') or
     (Length(Nonce) <> 32) or (Root = '') then Exit;
  for I := 1 to Length(Nonce) do
    if not (((Nonce[I] >= '0') and (Nonce[I] <= '9')) or
            ((Nonce[I] >= 'a') and (Nonce[I] <= 'f'))) then Exit;
  if CompareText(ExtractFileName(Root), 'aitm-selfcontained-' + Nonce) <> 0 then Exit;
  if CompareText(ExpandFileName(ExtractFileDir(Root)), ExpandFileName(GetEnv('RUNNER_TEMP'))) <> 0 then Exit;
  Result := True;
end;

function TestDestination(Param: String): String;
begin
  Result := AddBackslash(GetEnv('AITM_SC_TEST_ROOT')) + 'install';
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
  Target := TestDestination('');
  if (not IsSyntheticCi) or (CompareText(ExpandConstant('{app}'), Target) <> 0) then
    Result := 'A synthetic CI destination is required.'
  else if FileOrDirExists(Target) then
    Result := 'Synthetic installation requires a new destination.';
end;

function InitializeUninstall: Boolean;
begin
  Result := IsSyntheticCi and (CompareText(ExpandConstant('{app}'), TestDestination('')) = 0);
end;

