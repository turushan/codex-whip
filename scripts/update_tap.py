#!/usr/bin/env python3
"""Point the Homebrew cask in turushan/homebrew-tap at a published release.

Reads the version from codex_whip.py and both checksums from the release's own
SHA256SUMS.txt, so the cask only ever names files that are already downloadable.
Run it after the GitHub release exists; it commits and pushes the tap.
"""

import argparse
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request

import sparkle


ROOT = Path(__file__).resolve().parents[1]
TAP = "https://github.com/turushan/homebrew-tap.git"
CASK = "Casks/codex-whip.rb"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Show the updated cask without pushing")
    args = parser.parse_args()
    version = re.search(r'^VERSION = "([^"]+)"', (ROOT / "codex_whip.py").read_text(), re.M)[1]
    sums_url = f"{sparkle.REPOSITORY}/releases/download/v{version}/SHA256SUMS.txt"
    with urllib.request.urlopen(sums_url, timeout=60) as response:
        sums = dict(reversed(line.split()) for line in response.read().decode().splitlines() if line.strip())
    arm, intel = sums["Codex-Whip-arm64.dmg"], sums["Codex-Whip-x86_64.dmg"]
    with tempfile.TemporaryDirectory() as checkout:
        subprocess.run(["git", "clone", "--quiet", "--depth", "1", TAP, checkout], check=True)
        cask = Path(checkout) / CASK
        text = cask.read_text()
        text = re.sub(r'version "[^"]+"', f'version "{version}"', text, count=1)
        text = re.sub(r'arm:   "[0-9a-f]{64}"', f'arm:   "{arm}"', text, count=1)
        text = re.sub(r'intel: "[0-9a-f]{64}"', f'intel: "{intel}"', text, count=1)
        if args.dry_run:
            print(text)
            return
        cask.write_text(text)
        if not subprocess.run(["git", "-C", checkout, "status", "--porcelain"], capture_output=True,
                              text=True, check=True).stdout:
            print(f"The cask already names {version}")
            return
        subprocess.run(["git", "-C", checkout, "commit", "--quiet", "-am", f"Codex Whip {version}"], check=True)
        subprocess.run(["git", "-C", checkout, "push", "--quiet"], check=True)
    print(f"The cask now installs Codex Whip {version}")


if __name__ == "__main__":
    main()
