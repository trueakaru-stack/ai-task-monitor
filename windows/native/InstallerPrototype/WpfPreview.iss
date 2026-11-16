; Synthetic hosted-CI-only installer, not an application release or migration.
#define PayloadDirectory GetEnv("AITM_WPF_PAYLOAD")
#define OwnershipInclude GetEnv("AITM_WPF_OWNERSHIP")
#define OutputDirectory GetEnv("AITM_WPF_OUTPUT")
#if (PayloadDirectory == "") || (OwnershipInclude == "") || (OutputDirectory == "")
  #error The synthetic payload, ownership include and output paths are required.
#endif

[Setup]
AppId={{3EDB64F8-BF10-4710-93B5-DAA8B8A07979}
AppName=AI Task Monitor Synthetic WPF Installer Test
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
OutputBaseFilename=AITM-WpfPreviewInstaller-CI-ONLY
Compression=lzma2
SolidCompression=yes

[Files]
; Deletion is handled below using the manifest embedded in the uninstaller.
Source: "{#PayloadDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion uninsneveruninstall

[Code]
const
  AccessReadAndDelete = $80010000;
  ShareRead = 1;
  OpenExisting = 3;
  OpenReparsePoint = $00200000;
  AttributeDirectory = $10;
  AttributeReparsePoint = $400;
  DiskFile = 1;
  FileDispositionInfo = 4;

type
  THandleFileInfo = record
    Attributes: Cardinal;
    CreationLow, CreationHigh: Cardinal;
    AccessLow, AccessHigh: Cardinal;
    WriteLow, WriteHigh: Cardinal;
    VolumeSerial, SizeHigh, SizeLow, LinkCount, IndexHigh, IndexLow: Cardinal;
  end;

function NativeCreateFile(const Name: String; Access, Share: Cardinal;
  Security: NativeUInt; Creation, Flags: Cardinal; Template: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall uninstallonly';
function NativeFileInfo(Handle: THandle; var Info: THandleFileInfo): BOOL;
  external 'GetFileInformationByHandle@kernel32.dll stdcall uninstallonly';
function NativeFileType(Handle: THandle): Cardinal;
  external 'GetFileType@kernel32.dll stdcall uninstallonly';
function NativeSetFileInfo(Handle: THandle; InfoClass: Cardinal;
  var DeleteFlag: Byte; BufferSize: Cardinal): BOOL;
  external 'SetFileInformationByHandle@kernel32.dll stdcall uninstallonly';
function NativeCloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall uninstallonly';

function IsSyntheticCi: Boolean;
var
  Root, Nonce: String;
  I: Integer;
begin
  Result := False;
  Root := GetEnv('AITM_WPF_TEST_ROOT');
  Nonce := GetEnv('AITM_WPF_NONCE');
  if (GetEnv('CI') <> 'true') or (GetEnv('GITHUB_ACTIONS') <> 'true') or
     (GetEnv('RUNNER_ENVIRONMENT') <> 'github-hosted') or
     (GetEnv('RUNNER_OS') <> 'Windows') or (GetEnv('AITM_WPF_INSTALLER') <> '1') or
     (Length(Nonce) <> 32) or (Root = '') then Exit;
  for I := 1 to Length(Nonce) do
    if not (((Nonce[I] >= '0') and (Nonce[I] <= '9')) or
            ((Nonce[I] >= 'a') and (Nonce[I] <= 'f'))) then Exit;
  if CompareText(ExtractFileName(Root), 'aitm-wpf-install-' + Nonce) <> 0 then Exit;
  if CompareText(ExpandFileName(ExtractFileDir(Root)), ExpandFileName(GetEnv('RUNNER_TEMP'))) <> 0 then Exit;
  Result := True;
end;

function TestDestination(Param: String): String;
begin
  Result := AddBackslash(GetEnv('AITM_WPF_TEST_ROOT')) + 'install';
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

procedure RemoveOwnedFile(const Name, ExpectedHash: String);
var
  Handle: THandle;
  Info: THandleFileInfo;
  Stream: THandleStream;
  DeleteFlag: Byte;
begin
  { The compiler-generated include contains only validated plain filenames. }
  Handle := NativeCreateFile(AddBackslash(ExpandConstant('{app}')) + Name,
    AccessReadAndDelete, ShareRead, 0, OpenExisting, OpenReparsePoint, 0);
  if Handle = THandle(-1) then Exit;
  try
    try
      if (NativeFileType(Handle) <> DiskFile) or (NativeFileInfo(Handle, Info) = 0) then Exit;
      if (Info.Attributes and (AttributeDirectory or AttributeReparsePoint)) <> 0 then Exit;
      Stream := THandleStream.Create(Handle);
      try
        if CompareText(GetSHA256OfStream(Stream), ExpectedHash) = 0 then begin
          DeleteFlag := 1;
          NativeSetFileInfo(Handle, FileDispositionInfo, DeleteFlag, 1);
        end;
      finally
        Stream.Free;
      end;
    except
      { On read, hash or permission failure, retain the file. }
    end;
  finally
    NativeCloseHandle(Handle);
  end;
end;

#include OwnershipInclude

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and IsSyntheticCi then RemoveInstalledPayload;
end;

