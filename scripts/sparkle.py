"""Pinned Sparkle tools and framework used by local and CI builds."""

import hashlib
import fcntl
from pathlib import Path
import shutil
import tarfile
import urllib.request


VERSION = "2.10.1"
SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
PUBLIC_KEY = "TpY4sWpjeIKQgoPdsO3wgg4zTqf0koP5if0uXK75hLw="
KEYCHAIN_ACCOUNT = "com.turushan.codex-whip"
REPOSITORY = "https://github.com/turushan/codex-whip"
FEED_ROOT = "https://raw.githubusercontent.com/turushan/codex-whip/main/updates"


REQUIRED = (
    "Sparkle.framework/Versions/B/Sparkle",
    "Sparkle.framework/Versions/B/Autoupdate",
    "Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater",
    "bin/generate_appcast",
    "bin/sign_update",
    "bin/generate_keys",
)


def distribution(root):
    cache = Path(root) / "build/sparkle"
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "fetch.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _distribution(cache)


def _distribution(cache):
    archive = cache / f"Sparkle-{VERSION}.tar.xz"
    if not archive.exists():
        url = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/{archive.name}"
        temporary = archive.with_suffix(".download")
        try:
            with urllib.request.urlopen(url, timeout=120) as response, temporary.open("wb") as target:
                shutil.copyfileobj(response, target)
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError(f"Sparkle checksum mismatch: {archive}. Remove it and retry the build.")
    # Tools are immutable after extraction. Replacing a signed Mach-O tool
    # while another release command runs can invalidate its mapped code pages.
    extracted = cache / f"{VERSION}-{SHA256[:12]}"
    marker = extracted / ".archive-sha256"
    # A cache with a missing part, such as a deleted Updater.app, is extracted again.
    complete = all((extracted / part).exists() for part in REQUIRED)
    if marker.exists() and marker.read_text() == SHA256 and complete:
        return extracted
    if extracted.exists():
        shutil.rmtree(extracted)
    extracted.mkdir()
    with tarfile.open(archive) as package:
        # The archive is pinned above; also reject paths outside our build cache.
        for member in package.getmembers():
            target = (extracted / member.name).resolve()
            if target != extracted.resolve() and extracted.resolve() not in target.parents:
                raise RuntimeError(f"Invalid Sparkle archive path: {member.name}")
        package.extractall(extracted)
    marker.write_text(SHA256)
    return extracted
