#!/usr/bin/env python3
"""Build the universal menu bar app and its DMG on macOS.

The Swift engine in engine/ becomes the bundled helper, and both it and the app are built
for Apple silicon and Intel. Builds are ad hoc signed unless --identity names a Developer ID
Application certificate in the keychain. scripts/notarize.py then notarizes that DMG.
"""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time
import venv

import sparkle


ROOT = Path(__file__).resolve().parents[1]
NAME = "Codex Whip"
EXECUTABLE = "CodexWhip"
BUNDLE_ID = "com.turushan.codex-whip"
ARCHITECTURES = ("arm64", "x86_64")
DISK = "Codex-Whip.dmg"


def engine_version():
    """The single version, kept in the engine: engine/Sources/WhipEngine/Version.swift."""
    text = (ROOT / "engine/Sources/WhipEngine/Version.swift").read_text()
    return re.search(r'^public let engineVersion = "([^"]+)"', text, re.M)[1]


def run(arguments, **kwargs):
    subprocess.run([str(value) for value in arguments], check=True, cwd=ROOT, **kwargs)


def sign(app, identity):
    """Sign nested code first and the app last, never with --deep.

    A Developer ID signature adds the hardened runtime and a secure timestamp,
    which notarization requires.
    """
    options = ["--force", "--sign", identity]
    if identity == "-":
        options += ["--timestamp=none"]
    else:
        options += ["--timestamp", "--options", "runtime"]
    framework = app / "Contents/Frameworks/Sparkle.framework"
    # The XPC services serve sandboxed apps only; this app is not sandboxed.
    shutil.rmtree(framework / "Versions/B/XPCServices")
    (framework / "XPCServices").unlink()
    for code in (framework / "Versions/B/Autoupdate", framework / "Versions/B/Updater.app", framework):
        run(["codesign", *options, code])
    run(["codesign", *options, "--identifier", f"{BUNDLE_ID}.helper", app / "Contents/Helpers/whip-helper"])
    run(["codesign", *options, app])
    run(["codesign", "--verify", "--deep", "--strict", app])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-install", action="store_true", help="Use existing build dependencies")
    parser.add_argument("--skip-tests", action="store_true", help="Skip tests already run for this source")
    parser.add_argument("--identity", default="-",
                        help='Signing identity, such as "Developer ID Application: Name (TEAMID)"; ad hoc by default')
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Build this macOS app on a Mac")
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
        run(["swift", "test", "--package-path", ROOT / "engine"])
    # One universal engine binary serves as the app's helper and as the codex-whip command.
    engine = ["swift", "build", "--package-path", str(ROOT / "engine"), "-c", "release",
              *[flag for arch in ARCHITECTURES for flag in ("--arch", arch)]]
    run(engine)
    helper = Path(subprocess.check_output([*engine, "--show-bin-path"], text=True).strip()) / "codex-whip"
    app = output / f"{NAME}.app"
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    for directory in ("MacOS", "Helpers", "Resources", "Frameworks"):
        (contents / directory).mkdir(parents=True)
    sparkle_distribution = sparkle.distribution(ROOT)
    shutil.copytree(sparkle_distribution / "Sparkle.framework", contents / "Frameworks/Sparkle.framework",
                    symlinks=True)
    shutil.copy2(helper, contents / "Helpers/whip-helper")
    version = engine_version()
    scratch = build / "defaults-state"
    shutil.rmtree(scratch, ignore_errors=True)
    defaults = json.loads(subprocess.check_output([str(helper), "--state-dir", str(scratch), "settings"],
                                                  text=True))["defaults"]
    shutil.rmtree(scratch, ignore_errors=True)
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": NAME,
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIdentifier": BUNDLE_ID,
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
        "WhipDefaultSettings": defaults,
        "SUFeedURL": f"{sparkle.FEED_ROOT}/appcast.xml",
        "SUPublicEDKey": sparkle.PUBLIC_KEY,
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": True,
        "SUScheduledCheckInterval": 86400,
        "SUVerifyUpdateBeforeExtraction": True,
        "SURequireSignedFeed": True,
        "SUEnableSystemProfiling": False,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    slices = []
    for arch in ARCHITECTURES:
        slices.append(build / f"{EXECUTABLE}-{arch}")
        run(["xcrun", "swiftc", "-O", "-swift-version", "5",
             "-target", f"{arch}-apple-macosx14.0",
             "-framework", "AppKit", "-framework", "ServiceManagement",
             "-framework", "AVKit", "-framework", "AVFoundation",
             "-F", contents / "Frameworks", "-framework", "Sparkle",
             "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
             *sorted((ROOT / "native").glob("*.swift")), "-o", slices[-1]])
    run(["lipo", "-create", *slices, "-output", contents / "MacOS" / EXECUTABLE])
    iconset = build / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    run(["xcrun", "swift", ROOT / "scripts/make_icon.swift", iconset, ROOT / "assets/AppIcon.png"])
    run(["iconutil", "-c", "icns", iconset, "-o", contents / "Resources/AppIcon.icns"])
    shutil.copy2(ROOT / "LICENSE", contents / "Resources/LICENSE.txt")
    shutil.copy2(demo, contents / "Resources/Demo.mp4")
    shutil.copy2(ROOT / "engine/Sources/WhipEngine/Resources/whip.wav", contents / "Resources/Whip.wav")
    if (ROOT / "licenses").exists():
        shutil.copytree(ROOT / "licenses", contents / "Resources/ThirdPartyLicenses")
    shutil.copy2(sparkle_distribution / "LICENSE", contents / "Resources/ThirdPartyLicenses/Sparkle.txt")
    sign(app, args.identity)
    for arch in ARCHITECTURES:
        for code in (contents / "MacOS" / EXECUTABLE, contents / "Helpers/whip-helper"):
            if arch not in subprocess.check_output(["lipo", "-archs", str(code)], text=True).split():
                raise SystemExit(f"{code.name} is missing its {arch} slice")
    disk = output / DISK
    disk.unlink(missing_ok=True)
    # The installer window: background, icon positions and the volume icon (scripts/dmg_settings.py).
    # Detaching the scratch image can fail while Spotlight still reads it, so a busy disk gets retries.
    for attempt in range(3):
        try:
            run([interpreter, "-m", "dmgbuild", "-s", ROOT / "scripts/dmg_settings.py",
                 "-D", f"app={app}", "-D", f"assets={ROOT / 'assets/dmg'}",
                 "-D", f"icon={contents / 'Resources/AppIcon.icns'}", f"{NAME} {version}", disk])
            break
        except subprocess.CalledProcessError:
            disk.unlink(missing_ok=True)
            if attempt == 2:
                raise
            time.sleep(10)
    if args.identity != "-":
        run(["codesign", "--force", "--sign", args.identity, "--timestamp",
             "--identifier", f"{BUNDLE_ID}.dmg", disk])
    digest = hashlib.sha256(disk.read_bytes()).hexdigest()
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {disk.name}\n")
    print(f"\nBuilt {app}\nBuilt {disk}\nSHA256 {digest}")


if __name__ == "__main__":
    main()
