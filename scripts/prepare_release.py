#!/usr/bin/env python3
"""Sign the universal release DMG and prepare its Sparkle feeds using the release Keychain key.

Apps from 1.11 read updates/appcast.xml. Earlier apps read appcast-arm64.xml or appcast-x86_64.xml,
so the same signed feed is written to all three names and every installed app finds the update.
"""

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

import sparkle


ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="DMG produced by scripts/build_app.py")
    parser.add_argument("--notes", type=Path, help="Plain text release notes to embed in the update dialog")
    args = parser.parse_args()
    archive = args.archive.resolve()
    if archive.name != "Codex-Whip.dmg" or not archive.is_file():
        parser.error("Provide the existing universal Codex-Whip.dmg")
    # Releases ship notarized; the Sparkle signature must cover the stapled image.
    if subprocess.run(["xcrun", "stapler", "validate", archive], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode:
        parser.error("The DMG carries no notarization ticket; build it with the Signed release build workflow")
    version = re.search(r'^public let engineVersion = "([^"]+)"',
                        (ROOT / "engine/Sources/WhipEngine/Version.swift").read_text(), re.M)[1]
    distribution = sparkle.distribution(ROOT)
    public_key = subprocess.check_output([
        distribution / "bin/generate_keys", "--account", sparkle.KEYCHAIN_ACCOUNT, "-p",
    ], text=True).strip()
    if public_key != sparkle.PUBLIC_KEY:
        parser.error("The release Keychain key does not match this app's public update key")
    staging = ROOT / "build/release/universal"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copy2(archive, staging / archive.name)
    if args.notes:
        shutil.copy2(args.notes, staging / archive.with_suffix(".txt").name)
    feed = staging / "appcast.xml"
    subprocess.run([
        distribution / "bin/generate_appcast", "--account", sparkle.KEYCHAIN_ACCOUNT,
        "--download-url-prefix", f"{sparkle.REPOSITORY}/releases/download/v{version}/",
        "--link", sparkle.REPOSITORY, "--embed-release-notes", "--maximum-deltas", "0",
        "-o", feed, staging,
    ], check=True)
    # The generator signs the archive and feed based on the app's Info.plist.
    # Refuse publishing a stale DMG under a new version's download URL.
    item = ET.parse(feed).find("./channel/item")
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    enclosure = item.find("enclosure") if item is not None else None
    feed_version = item.findtext(namespace + "version") if item is not None else None
    if enclosure is not None:
        feed_version = feed_version or enclosure.get(namespace + "version")
    if enclosure is None or feed_version != version:
        parser.error("The DMG version does not match the source version; rebuild it before releasing")
    # Sparkle adds a hardware requirement only for single-architecture apps.
    if item.findtext(namespace + "hardwareRequirements") is not None:
        parser.error("The DMG is not universal; build it with scripts/build_app.py")
    if not enclosure.get(namespace + "edSignature"):
        parser.error("The update archive was not signed")
    subprocess.run([distribution / "bin/sign_update", "--account", sparkle.KEYCHAIN_ACCOUNT,
                    "--verify", feed], check=True)
    updates = ROOT / "updates"
    updates.mkdir(exist_ok=True)
    destinations = [updates / name for name in ("appcast.xml", "appcast-arm64.xml", "appcast-x86_64.xml")]
    for destination in destinations:
        shutil.copy2(feed, destination)
    # The README's download links name the DMG for each Mac type; all three are the same universal image.
    assets = [archive]
    for name in ("Codex-Whip-arm64.dmg", "Codex-Whip-x86_64.dmg"):
        shutil.copy2(archive, archive.parent / name)
        assets.append(archive.parent / name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksums = archive.parent / "SHA256SUMS.txt"
    checksums.write_text("".join(f"{digest}  {asset.name}\n" for asset in assets))
    assets.append(checksums)
    print(f"\nPrepared v{version}: " + ", ".join(str(path.relative_to(ROOT)) for path in destinations))
    print("Upload these to the matching GitHub release first: " + " ".join(str(path) for path in assets))
    print("Then commit and push the three feeds so installed apps can see the update.")

if __name__ == "__main__":
    main()
