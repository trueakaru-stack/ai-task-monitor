; Synthetic CI-only packaging experiment. This is not a product installer.
; This experiment tests removal of installed payload and preservation of unrelated data.
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
; The uninstaller tracks these installed files. This remains a CI-only experiment.
Source: "{#PayloadDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

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

// CI-only preflight: refuse existing redirected paths before uninstall.
// This does not eliminate concurrent path replacement.
function DirectoryAttributes(const Path: String): Cardinal;
  external 'GetFileAttributesW@kernel32.dll stdcall uninstallonly';

function PlainDirectory(const Path: String): Boolean;
var
  Attr: Cardinal;
begin
  Attr := DirectoryAttributes(Path);
  Result := (Attr <> $FFFFFFFF) and ((Attr and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
    ((Attr and FILE_ATTRIBUTE_REPARSE_POINT) = 0);
end;

function PlainAncestors(const Path: String): Boolean;
var
  Current, Parent: String;
  I: Integer;
begin
  Result := False;
  Current := RemoveBackslashUnlessRoot(ExpandFileName(Path));
  for I := 0 to 64 do begin
    if not PlainDirectory(Current) then Exit;
    Parent := RemoveBackslashUnlessRoot(ExtractFileDir(Current));
    if CompareText(Parent, Current) = 0 then begin Result := True; Exit; end;
    if (Parent = '') or (Length(Parent) >= Length(Current)) then Exit;
    Current := Parent;
  end;
end;

var
  Examined: Integer;

function PlainTree(const Path: String; const Depth: Integer): Boolean;
var
  Entry: TFindRec;
begin
  Result := False;
  if (Depth > 32) or not PlainDirectory(Path) then Exit;
  if not FindFirst(AddBackslash(Path) + '*', Entry) then Exit;
  try
    repeat
      if (Entry.Name <> '.') and (Entry.Name <> '..') then begin
        Examined := Examined + 1;
        if Examined > 10000 then Exit;
        if (Entry.Attributes and FILE_ATTRIBUTE_REPARSE_POINT) <> 0 then Exit;
        if ((Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
           not PlainTree(AddBackslash(Path) + Entry.Name, Depth + 1) then Exit;
      end;
    until not FindNext(Entry);
  finally
    FindClose(Entry);
  end;
  Result := True;
end;

function InitializeUninstall: Boolean;
var
  InstallPath: String;
begin
  InstallPath := ExpandConstant('{app}');
  Result := IsSyntheticCi and (CompareText(InstallPath, TestDestination('')) = 0);
  if Result then begin
    Examined := 0;
    Result := PlainAncestors(InstallPath) and PlainTree(InstallPath, 0);
  end;
end;

