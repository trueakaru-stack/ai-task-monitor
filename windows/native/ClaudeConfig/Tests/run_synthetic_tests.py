from pathlib import Path
import argparse
import os
import subprocess
import tempfile


def within(path, root):
    if not root:
        return False
    try:
        return os.path.commonpath((str(path), str(Path(root).resolve()))).casefold() == str(Path(root).resolve()).casefold()
    except ValueError:
        return False


parser = argparse.ArgumentParser()
parser.add_argument("--sdk-root", required=True)
parser.add_argument("--work-directory", required=True)
args = parser.parse_args()
if not Path(args.sdk_root).is_absolute() or not Path(args.work_directory).is_absolute():
    raise ValueError("Both paths must be absolute")
sdk = Path(args.sdk_root).resolve(strict=True)
work = Path(args.work_directory).resolve(strict=True)
if not work.is_dir():
    raise ValueError("The work directory must already exist")
repo = Path(__file__).resolve().parents[4]
required_profiles = []
for name in ("USERPROFILE", "APPDATA", "LOCALAPPDATA"):
    value = os.environ.get(name, "")
    if not value or not Path(value).is_absolute():
        raise ValueError("The current profile and application-data directories must be available")
    protected_path = Path(value).resolve(strict=True)
    if not protected_path.is_dir():
        raise ValueError("The current profile and application-data directories must be available")
    required_profiles.append(protected_path)
optional_profiles = []
for name in ("HOME", "CODEX_HOME"):
    value = os.environ.get(name, "")
    if value:
        if not Path(value).is_absolute():
            raise ValueError("A configured profile directory is not absolute")
        optional_profiles.append(Path(value).resolve())
for protected in (repo, sdk, *required_profiles, *optional_profiles):
    if within(work, protected):
        raise ValueError("The work directory must be outside the repository and user profiles")
dotnet = sdk / "dotnet.exe"
if not dotnet.is_file():
    raise RuntimeError("The requested SDK is unavailable")
run = Path(tempfile.mkdtemp(prefix="claude-config-", dir=work))
for name in ("profile", "appdata", "localappdata", "tmp", "dotnet", "packages", "out", "programfiles", "programdata"):
    (run / name).mkdir()
config = run / "NuGet.Config"
config.write_text('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear /></packageSources></configuration>', encoding="utf-8")
env = {key: os.environ[key] for key in ("SystemRoot", "WINDIR", "ComSpec", "PATHEXT", "SystemDrive") if key in os.environ}
env.update({
    "PATH": str(sdk) + os.pathsep + str(Path(os.environ["SystemRoot"]) / "System32"),
    "DOTNET_ROOT": str(sdk), "DOTNET_CLI_HOME": str(run / "dotnet"), "DOTNET_CLI_TELEMETRY_OPTOUT": "1",
    "DOTNET_SKIP_FIRST_TIME_EXPERIENCE": "1", "DOTNET_GENERATE_ASPNET_CERTIFICATE": "0", "DOTNET_NOLOGO": "1",
    "NUGET_PACKAGES": str(run / "packages"), "USERPROFILE": str(run / "profile"), "APPDATA": str(run / "appdata"),
    "LOCALAPPDATA": str(run / "localappdata"), "TEMP": str(run / "tmp"), "TMP": str(run / "tmp"),
    "ProgramFiles": str(run / "programfiles"), "ProgramFiles(x86)": str(run / "programfiles"),
    "ProgramW6432": str(run / "programfiles"), "ProgramData": str(run / "programdata"),
    "ALLUSERSPROFILE": str(run / "programdata"),
})
project = Path(__file__).resolve().with_name("ClaudeConfig.Tests.csproj")
build = subprocess.run([str(dotnet), "build", str(project), "-c", "Release", "-o", str(run / "out"),
                        "--artifacts-path", str(run / "artifacts"), "--configfile", str(config),
                        "-p:NuGetAudit=false", "--nologo"], cwd=run, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
print(build.stdout)
if build.returncode:
    raise RuntimeError("Synthetic build failed")
test = subprocess.run([str(dotnet), str(run / "out" / "AITaskMonitor.ClaudeConfig.Tests.dll")], cwd=run, env=env,
                      text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
print(test.stdout)
if test.returncode:
    raise RuntimeError("Synthetic checks failed")
print("Evidence:", run)
