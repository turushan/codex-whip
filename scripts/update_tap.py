#!/usr/bin/env python3
"""Point the Homebrew cask in turushan/homebrew-tap at a published release.

Reads the version from the engine and the checksum from the release's own SHA256SUMS.txt,
so the cask only ever names a file that is already downloadable. Run it after the GitHub
release exists; it rewrites the cask, commits and pushes the tap.
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


CASK_TEMPLATE = """cask "codex-whip" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/turushan/codex-whip/releases/download/v#{{version}}/Codex-Whip.dmg"
  name "Codex Whip"
  desc "Menu bar app that resumes Codex CLI after capacity errors and quota waits"
  homepage "https://codexwhip.com/"

  livecheck do
    url "https://raw.githubusercontent.com/turushan/codex-whip/main/updates/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Codex Whip.app"

  zap trash: [
    "~/Library/Application Support/Codex Whip",
    "~/Library/Caches/com.turushan.codex-whip",
    "~/Library/HTTPStorages/com.turushan.codex-whip",
    "~/Library/Preferences/com.turushan.codex-whip.plist",
  ]
end
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="Show the updated cask without pushing")
    args = parser.parse_args()
    version = re.search(r'^public let engineVersion = "([^"]+)"',
                        (ROOT / "engine/Sources/WhipEngine/Version.swift").read_text(), re.M)[1]
    sums_url = f"{sparkle.REPOSITORY}/releases/download/v{version}/SHA256SUMS.txt"
    with urllib.request.urlopen(sums_url, timeout=60) as response:
        sums = dict(reversed(line.split()) for line in response.read().decode().splitlines() if line.strip())
    text = CASK_TEMPLATE.format(version=version, sha256=sums["Codex-Whip.dmg"])
    if args.dry_run:
        print(text)
        return
    with tempfile.TemporaryDirectory() as checkout:
        subprocess.run(["git", "clone", "--quiet", "--depth", "1", TAP, checkout], check=True)
        cask = Path(checkout) / CASK
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
