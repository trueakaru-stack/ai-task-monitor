"""Mount and inspect only this job's test image, cleaning up even on attach failure."""
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys


def hdi_info():
    result = subprocess.run(["/usr/bin/hdiutil", "info", "-plist"], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    value = plistlib.loads(result.stdout)
    images = value.get("images")
    if not isinstance(images, list):
        raise RuntimeError("Unexpected hdiutil info format")
    return images


def matching_attachment(images, image_path, mount_path):
    """Return only an unambiguous attachment of our exact image, or None."""
    own = []
    for image in images:
        if not isinstance(image, dict) or not isinstance(image.get("system-entities", []), list):
            raise RuntimeError("Unexpected hdiutil image entry")
        entities = image.get("system-entities", [])
        if not all(isinstance(entity, dict) for entity in entities):
            raise RuntimeError("Unexpected hdiutil entity")
        mounted = [Path(entity["mount-point"]).resolve() for entity in entities
                   if isinstance(entity.get("mount-point"), str)]
        path = image.get("image-path")
        is_ours = isinstance(path, str) and Path(path).resolve() == image_path
        if mount_path in mounted and not is_ours:
            raise RuntimeError("Synthetic mount point belongs to another image")
        if is_ours:
            if any(point != mount_path for point in mounted):
                raise RuntimeError("Test image has an unexpected mount point")
            roots = {entity.get("dev-entry") for entity in entities
                     if isinstance(entity.get("dev-entry"), str)
                     and re.fullmatch(r"/dev/disk[0-9]+", entity["dev-entry"])}
            own.append((mounted, roots))
    if len(own) > 1:
        raise RuntimeError("More than one attachment for the test image")
    return own[0] if own else None


def detach_owned(image_path, mount_path):
    """Use the verified mount point or, for an unmounted partial attach, its whole disk."""
    attachment = matching_attachment(hdi_info(), image_path, mount_path)
    if attachment is None:
        if os.path.ismount(mount_path):
            raise RuntimeError("Mount point is occupied by an unknown device")
        return "No test attachment remained"
    mounted, roots = attachment
    if mounted:
        target = str(mount_path)
    elif len(roots) == 1:
        target = next(iter(roots))
    else:
        raise RuntimeError("Cannot safely identify partially attached whole disk")
    subprocess.run(["/usr/bin/hdiutil", "detach", target, "-quiet"], check=True, timeout=60)
    if matching_attachment(hdi_info(), image_path, mount_path) is not None or os.path.ismount(mount_path):
        raise RuntimeError("Test image remained attached after detach")
    return "Detached verified test image"


def run_logged(command, log_path, timeout):
    try:
        with log_path.open("xb") as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=timeout)
    finally:
        if log_path.is_file():
            print(log_path.read_text(encoding="utf-8", errors="replace"), end="", flush=True)


def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true" or
        os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.environ.get("RUNNER_OS") != "macOS"):
        raise SystemExit("DMG owner requires a disposable hosted macOS runner")
    if len(sys.argv) != 1:
        raise SystemExit("Unexpected DMG owner arguments")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    work = temp / "aitm-package-candidate-v1/macos"
    image = (work / "dist/AITaskMonitor-macOS-0.3.8-ci.1.dmg").resolve(strict=True)
    expected_image = work / "dist/AITaskMonitor-macOS-0.3.8-ci.1.dmg"
    mount = (temp / "aitm-package-mounted").resolve(strict=True)
    output = (temp / "aitm-package-output").resolve(strict=True)
    inputs = workspace / ".github/macos-package-audit-v2-20261109"
    if image != expected_image or mount != temp / "aitm-package-mounted" or output != temp / "aitm-package-output":
        raise SystemExit("Unexpected test image, output, or mount path")
    if not image.is_file() or not mount.is_dir() or any(mount.iterdir()) or os.path.ismount(mount):
        raise SystemExit("Test image or empty mount point is invalid")
    if matching_attachment(hdi_info(), image, mount) is not None:
        raise SystemExit("Test image was already attached")
    app = work / "dist/AI Task Monitor.app"
    mounted_app = mount / "AI Task Monitor.app"
    resources = inputs / "bundle-resources.sha256"
    def interrupt(signum, frame):
        raise InterruptedError("DMG owner received termination")
    previous = signal.signal(signal.SIGTERM, interrupt)
    try:
        try:
            run_logged(["/usr/bin/hdiutil", "attach", "-plist", "-readonly", "-nobrowse", "-noautoopen",
                        "-mountpoint", str(mount), str(image)], output / "mount.log", 180)
            attachment = matching_attachment(hdi_info(), image, mount)
            if attachment is None or mount not in attachment[0] or not os.path.ismount(mount):
                raise RuntimeError("Mounted image identity was not confirmed")
            checks = [
                ("dmg-contents.log", ["/usr/bin/python3", "-I", "-S", "-B", str(inputs / "verify-dmg-contents.py"), str(app), str(mount)]),
                ("mounted-bundle.json", ["/usr/bin/python3", "-I", "-S", "-B", str(inputs / "verify-app-bundle.py"), str(mounted_app), str(work), str(resources)]),
                ("mounted-signature.log", ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(mounted_app)]),
            ]
            for name, command in checks:
                run_logged(command, output / name, 180)
                print(name + ": verified", flush=True)
        finally:
            print(detach_owned(image, mount), flush=True)
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    main()
