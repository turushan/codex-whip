#!/usr/bin/env python3
"""Build the self-contained menu bar app and an ad-hoc signed DMG on macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import venv

import sparkle


ROOT = Path(__file__).resolve().parents[1]
NAME = "Codex Whip"
EXECUTABLE = "CodexWhip"


def run(arguments, **kwargs):
    subprocess.run([str(value) for value in arguments], check=True, cwd=ROOT, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-install", action="store_true", help="Use existing build dependencies")
    parser.add_argument("--skip-tests", action="store_true", help="Skip tests already run for this source")
    parser.add_argument("--reuse-helper", action="store_true", help="Reuse an unchanged local helper when rebuilding the native menu")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Build this macOS app on a Mac")
    architecture = platform.machine()
    if architecture not in ("arm64", "x86_64"):
        parser.error(f"Unsupported build architecture: {architecture}")
    demo = ROOT / "docs/demo/codex-whip.mp4"
    if not demo.is_file():
        parser.error("The bundled demo is missing; use a complete source checkout including docs/demo")
    build = ROOT / "build"
    output = ROOT / "dist"
    build.mkdir(exist_ok=True)
    output.mkdir(exist_ok=True)
    environment = ROOT / ".venv-build"
    interpreter = environment / "bin/python"
    if not interpreter.exists():
        venv.EnvBuilder(with_pip=True).create(environment)
    if not args.skip_install:
        run([interpreter, "-m", "pip", "install", "--disable-pip-version-check",
             "-r", ROOT / "requirements-build.txt"])
    if not args.skip_tests:
        run([interpreter, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py", "-q"])
    helper_output = build / "helper"
    frozen_helper = helper_output / "whip-helper"
    if args.reuse_helper:
        source_time = max(path.stat().st_mtime for path in ROOT.glob("*.py"))
        if not frozen_helper.is_file() or frozen_helper.stat().st_mtime < source_time:
            parser.error("The bundled helper is missing or older than its source; rebuild without --reuse-helper")
    else:
        if helper_output.exists():
            shutil.rmtree(helper_output)
        run([interpreter, "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile",
             "--name", "whip-helper",
             "--distpath", build / "helper", "--workpath", build / "pyinstaller",
             "--specpath", build / "spec", "--target-arch", architecture,
             "--codesign-identity", "-", ROOT / "codex_whip.py"])
    app = output / f"{NAME}.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for directory in ("MacOS", "Helpers", "Resources", "Frameworks"):
        (contents / directory).mkdir(parents=True)
    sparkle_distribution = sparkle.distribution(ROOT)
    shutil.copytree(sparkle_distribution / "Sparkle.framework", contents / "Frameworks/Sparkle.framework",
                    symlinks=True)
    shutil.copy2(build / "helper/whip-helper", contents / "Helpers/whip-helper")
    version = re.search(r'^VERSION = "([^"]+)"', (ROOT / "codex_whip.py").read_text(), re.M)[1]
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": NAME,
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIdentifier": "com.aktay.codex-keep-going.app",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": NAME,
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleIconFile": "AppIcon",
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "NSHumanReadableCopyright": "Copyright © 2026 Codex Whip contributors",
        "WhipDefaultSettings": json.loads(subprocess.check_output([
            str(interpreter), "-c",
            "import json; from settings import DEFAULT_SETTINGS; print(json.dumps(DEFAULT_SETTINGS))",
        ], cwd=ROOT, text=True)),
        "SUFeedURL": f"{sparkle.FEED_ROOT}/appcast-{architecture}.xml",
        "SUPublicEDKey": sparkle.PUBLIC_KEY,
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False,
        "SUScheduledCheckInterval": 86400,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUEnableSystemProfiling": False,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    run(["xcrun", "swiftc", "-O", "-swift-version", "5",
         "-target", f"{architecture}-apple-macosx14.0",
         "-framework", "AppKit", "-framework", "ServiceManagement",
         "-framework", "AVKit", "-framework", "AVFoundation",
         "-F", contents / "Frameworks", "-framework", "Sparkle",
         "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
         *sorted((ROOT / "native").glob("*.swift")), "-o", contents / "MacOS" / EXECUTABLE])
    iconset = build / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    run(["xcrun", "swift", ROOT / "scripts/make_icon.swift", iconset, ROOT / "assets/AppIcon.png"])
    run(["iconutil", "-c", "icns", iconset, "-o", contents / "Resources/AppIcon.icns"])
    shutil.copy2(ROOT / "LICENSE", contents / "Resources/LICENSE.txt")
    shutil.copy2(demo, contents / "Resources/Demo.mp4")
    if (ROOT / "licenses").exists():
        shutil.copytree(ROOT / "licenses", contents / "Resources/ThirdPartyLicenses")
    shutil.copy2(sparkle_distribution / "LICENSE", contents / "Resources/ThirdPartyLicenses/Sparkle.txt")
    license_path = subprocess.check_output([
        str(interpreter), "-c",
        "import pathlib,sysconfig; print(pathlib.Path(sysconfig.get_path('stdlib')) / 'LICENSE.txt')",
    ], text=True).strip()
    if Path(license_path).is_file():
        shutil.copy2(license_path, contents / "Resources/ThirdPartyLicenses/Python-runtime.txt")
    run(["codesign", "--force", "--deep", "--sign", "-", "--timestamp=none", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    stage = build / "dmg"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    shutil.copytree(app, stage / app.name, symlinks=True)
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    (stage / "Read Me.txt").write_text(
        "Codex Whip\n\n"
        "Drag Codex Whip into Applications, then open it.\n"
        "Requires macOS 14 or newer and Codex CLI with its shared local daemon.\n\n"
        "This community build is ad-hoc signed, without Developer ID signing or Apple notarization.\n"
        "If macOS blocks the first launch, try opening the app, then visit System Settings >\n"
        "Privacy & Security > Open Anyway if you trust this download.\n"
        "Apple's instructions: https://support.apple.com/en-us/102445\n\n"
        "Source and build instructions: https://github.com/turushan/codex-whip\n"
    )
    disk = output / f"Codex-Whip-{architecture}.dmg"
    disk.unlink(missing_ok=True)
    run(["hdiutil", "create", "-volname", NAME, "-srcfolder", stage,
         "-format", "UDZO", "-ov", disk])
    digest = hashlib.sha256(disk.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {disk.name}\n")
    print(f"\nBuilt {app}\nBuilt {disk}\nSHA256 {digest}")


if __name__ == "__main__":
    main()
