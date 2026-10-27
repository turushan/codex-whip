#!/usr/bin/env python3
"""Notarize a Developer ID signed DMG with Apple, staple the ticket and check Gatekeeper.

Authenticates with an App Store Connect Team API key: either --keychain-profile
(saved once with `xcrun notarytool store-credentials`) or NOTARY_KEY_PATH,
NOTARY_KEY_ID and NOTARY_ISSUER in the environment, as on CI.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def notarytool(arguments, credentials):
    result = subprocess.run(["xcrun", "notarytool", *arguments, *credentials, "--output-format", "json"],
                            stdout=subprocess.PIPE, text=True, check=False)
    try:
        return result.returncode, json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        return result.returncode, {"message": result.stdout}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="Signed DMG from scripts/build_app.py --identity")
    parser.add_argument("--keychain-profile", help="Saved notarytool credentials for local use")
    args = parser.parse_args()
    archive = args.archive.resolve()
    if args.keychain_profile:
        credentials = ["--keychain-profile", args.keychain_profile]
    else:
        try:
            credentials = ["--key", os.environ["NOTARY_KEY_PATH"], "--key-id", os.environ["NOTARY_KEY_ID"],
                           "--issuer", os.environ["NOTARY_ISSUER"]]
        except KeyError as missing:
            parser.error(f"Set {missing.args[0]} or pass --keychain-profile")
    subprocess.run(["codesign", "--verify", "--strict", archive], check=True)
    code, submission = notarytool(["submit", archive, "--wait", "--timeout", "30m"], credentials)
    print(json.dumps(submission, indent=2))
    identifier = submission.get("id")
    if identifier:
        # The log lists every issue, including warnings on an accepted submission.
        log = archive.with_name(archive.stem + "-notary-log.json")
        subprocess.run(["xcrun", "notarytool", "log", identifier, *credentials, log], check=False)
        if log.is_file():
            issues = json.loads(log.read_text()).get("issues") or []
            for issue in issues:
                print(f"{issue.get('severity')}: {issue.get('path')}: {issue.get('message')}")
    if code or submission.get("status") != "Accepted":
        sys.exit(f"Notarization failed: {submission.get('status') or submission.get('message')}")
    subprocess.run(["xcrun", "stapler", "staple", archive], check=True)
    subprocess.run(["xcrun", "stapler", "validate", archive], check=True)
    subprocess.run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
                    "--verbose=2", archive], check=True)
    # Check the app inside the stapled image as a downloaded copy would be checked.
    with tempfile.TemporaryDirectory() as mount:
        subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, archive],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            app = Path(mount) / "Codex Whip.app"
            # The ticket is stapled to the image, not to the app inside it, so
            # `syspolicy_check distribution` would report the app's ticket as missing.
            subprocess.run(["spctl", "--assess", "--type", "execute", "--verbose=2", app], check=True)
        finally:
            subprocess.run(["hdiutil", "detach", mount], check=True, stdout=subprocess.DEVNULL)
    # Stapling changes the image, so the checksum is written again.
    checksums = archive.parent / "SHA256SUMS.txt"
    checksums.write_text("".join(
        f"{hashlib.sha256(item.read_bytes()).hexdigest()}  {item.name}\n"
        for item in sorted(archive.parent.glob("Codex-Whip-*.dmg"))
    ))
    print(f"\nNotarized and stapled {archive}")


if __name__ == "__main__":
    main()
