#!/usr/bin/env python3
"""Sign a built DMG and prepare its GitHub-hosted Sparkle feed using the release Keychain key."""

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
    match = re.fullmatch(r"Codex-Whip-(arm64|x86_64)\.dmg", archive.name)
    if not match or not archive.is_file():
        parser.error("Provide an existing Codex-Whip-arm64.dmg or Codex-Whip-x86_64.dmg")
    architecture = match[1]
    version = re.search(r'^VERSION = "([^"]+)"', (ROOT / "codex_whip.py").read_text(), re.M)[1]
    distribution = sparkle.distribution(ROOT)
    public_key = subprocess.check_output([
        distribution / "bin/generate_keys", "--account", sparkle.KEYCHAIN_ACCOUNT, "-p",
    ], text=True).strip()
    if public_key != sparkle.PUBLIC_KEY:
        parser.error("The release Keychain key does not match this app's public update key")
    staging = ROOT / "build/release" / architecture
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copy2(archive, staging / archive.name)
    if args.notes:
        shutil.copy2(args.notes, staging / archive.with_suffix(".txt").name)
    feed = staging / f"appcast-{architecture}.xml"
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
    # Sparkle emits an arm64 requirement for ARM-only apps. Intel-compatible
    # bundles have no hardware restriction (they may run under Rosetta too).
    hardware = item.findtext(namespace + "hardwareRequirements")
    if ((architecture == "arm64" and hardware != "arm64")
            or (architecture == "x86_64" and hardware not in (None, "x86_64"))):
        parser.error("The DMG architecture does not match its filename")
    if not enclosure.get(namespace + "edSignature"):
        parser.error("The update archive was not signed")
    subprocess.run([distribution / "bin/sign_update", "--account", sparkle.KEYCHAIN_ACCOUNT,
                    "--verify", feed], check=True)
    updates = ROOT / "updates"
    updates.mkdir(exist_ok=True)
    destination = updates / feed.name
    shutil.copy2(feed, destination)
    checksums = archive.parent / "SHA256SUMS.txt"
    archives = sorted(archive.parent.glob("Codex-Whip-*.dmg"))
    checksums.write_text("".join(
        f"{hashlib.sha256(item.read_bytes()).hexdigest()}  {item.name}\n" for item in archives
    ))
    print(f"\nPrepared v{version} {architecture}: {destination}")
    print("Upload the DMG and SHA256SUMS.txt to the matching GitHub release first.")
    print(f"Then commit and push {destination.relative_to(ROOT)} so installed apps can see the update.")


if __name__ == "__main__":
    main()
