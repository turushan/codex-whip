#!/usr/bin/env python3
"""Render the authored synthetic demo with native Mac graphics, then encode it."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from settings import DEFAULT_MESSAGE, DEFAULT_SETTINGS  # noqa: E402

DURATION = 56
FPS = 30
EXAMPLE_MESSAGE = DEFAULT_MESSAGE
EXAMPLE_RETRY_SECONDS = DEFAULT_SETTINGS["retry_seconds"]
EXAMPLE_CHECK_SECONDS = DEFAULT_SETTINGS["scan_seconds"]
WHIP_IMPACTS = (7.0, 8.8, 10.6, 28.0, 29.5, 31.0, 44.5, 46.0, 47.5)


def sound_events():
    events = [{"time": instant, "type": "whip", "pan": 0.35} for instant in WHIP_IMPACTS]
    for kind, times in (
        ("tap", (1.0, 4.3, 18.6, 35.6)),
        ("whoosh", (18.0, 35.0)),
        ("check", (21.0, 24.0, 42.0)),
        ("renewal", (25.5,)),
        ("post", (36.2,)),
        ("confirm", (26.5, 43.0)),
        ("send", (12.2, 32.3, 48.8)),
        ("logo", (52.2,)),
    ):
        events.extend({"time": instant, "type": kind} for instant in times)
    return sorted(events, key=lambda event: event["time"])


def run(*arguments: str) -> None:
    subprocess.run(arguments, cwd=ROOT, check=True)


def embed_origin(path: Path) -> None:
    """Preserve ImageIO XMP and add the portable Impeccable PNG origin keyword."""
    keyword = b"impeccable:prompt"
    origin = (
        "Programmatic origin, not an AI image prompt: deterministic native "
        "AppKit/CoreGraphics terminal and window graphics rendered by "
        "scripts/render_demo.swift. Animated whip and typing are an illustrated "
        "metaphor using the default retry message; time compressed. Three stories "
        "show capacity, scheduled renewal and an illustrated early-reset announcement. "
        "The unmodified public avatar is from https://codex-resets.com/thsottiaux-avatar.jpg; "
        "provenance: assets/demo/tibo-avatar.provenance.json. The actual "
        "app sends one local RPC message, not physical keystrokes. Synthetic "
        "demo session; no live session data or inference requests. Existing "
        "approved icon: docs/app-icon.png, "
        "derived from assets/AppIcon.png; original icon prompt and provenance "
        "are in assets/AppIcon.prompt.txt and assets/AppIcon.provenance.json."
    ).encode("ascii")
    image = path.read_bytes()
    signature = b"\x89PNG\r\n\x1a\n"
    if not image.startswith(signature):
        raise ValueError(f"Not a PNG: {path}")
    result = bytearray(signature)
    offset = len(signature)
    while offset < len(image):
        length, kind = struct.unpack_from(">I4s", image, offset)
        end = offset + length + 12
        data = image[offset + 8:offset + 8 + length]
        if end > len(image):
            raise ValueError(f"Truncated PNG: {path}")
        if kind == b"IEND":
            content = keyword + b"\0" + origin
            result.extend(struct.pack(">I", len(content)) + b"tEXt" + content)
            result.extend(struct.pack(">I", zlib.crc32(b"tEXt" + content) & 0xFFFFFFFF))
        if not (kind == b"tEXt" and data.startswith(keyword + b"\0")):
            result.extend(image[offset:end])
        offset = end
    path.write_bytes(result)


def filmstrip(ffmpeg: str, frames: Path, target: Path, times: tuple[float, ...], *, crop: bool = False) -> None:
    indices = [round(time * FPS) for time in times]
    inputs = [item for index in indices for item in ("-i", str(frames / f"frame-{index:04d}.png"))]
    tile_width, tile_height = (876, 240) if crop else (640, 360)
    scaling = "crop=1168:320:96:284,scale=876:240" if crop else "scale=640:360"
    filters = ";".join(f"[{i}:v]{scaling}[s{i}]" for i in range(len(indices)))
    layout = "|".join(f"{(i % 2) * tile_width}_{(i // 2) * tile_height}" for i in range(len(indices)))
    filters += ";" + "".join(f"[s{i}]" for i in range(len(indices)))
    filters += f"xstack=inputs={len(indices)}:layout={layout}:fill=0x081523[out]"
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *inputs,
        "-filter_complex", filters, "-map", "[out]", "-frames:v", "1", str(target))


def main() -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required to regenerate media (brew install ffmpeg).")
    work = ROOT / "build" / "demo"
    frames = work / "frames"
    target = ROOT / "docs" / "demo"
    frames.mkdir(parents=True, exist_ok=True)
    target.mkdir(parents=True, exist_ok=True)
    renderer = work / "render-demo"
    run("swiftc", "-O", "scripts/render_demo.swift", "-o", str(renderer))
    run(str(renderer), str(frames), str(ROOT / "docs" / "app-icon.png"), EXAMPLE_MESSAGE,
        str(EXAMPLE_RETRY_SECONDS), str(EXAMPLE_CHECK_SECONDS),
        str(ROOT / "assets" / "demo" / "tibo-avatar.jpg"))
    events = sound_events()
    events_path, score = work / "audio-events.json", work / "score.wav"
    events_path.write_text(json.dumps(events, indent=2) + "\n")
    audio_report = work / "audio-report.json"
    run(sys.executable, "scripts/render_demo_audio.py", "--duration", str(DURATION),
        "--events", str(events_path), "--output", str(score), "--report", str(audio_report))
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-framerate", "30",
        "-i", str(frames / "frame-%04d.png"), "-i", str(score), "-frames:v", str(DURATION * FPS),
        "-t", str(DURATION), "-c:v", "libx264", "-preset", "slow", "-crf", "20",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest",
        "-movflags", "+faststart", "-metadata", "title=Codex Whip · Three ways to keep going",
        "-metadata", "comment=Illustrated marketing demo: capacity, regular quota renewal and an early reset announcement. Time compressed. Actual app checks Codex quota, not social posts; sends one continuation message. Original procedural sound effects. No model requests or endorsement.",
        str(target / "codex-whip.mp4"))
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(target / "codex-whip.mp4"),
        "-filter_complex", "fps=20,scale=800:-1:flags=lanczos,split[a][b];"
        "[a]palettegen=max_colors=96:stats_mode=diff[p];"
        "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
        "-loop", "0", "-an", str(target / "codex-whip.gif"))
    shutil.copyfile(frames / "poster.png", target / "poster.png")
    embed_origin(target / "poster.png")

    narrative_times = (0, 7.2, 13.2, 18.6, 24, 28.2, 33.3, 36.7, 40, 43.6, 48.9, 54)
    whip_times = (6.3, 6.6, 7.0, 7.3, 7.6, 7.9)
    submission_times = (48.8, 49.0, 49.3, 49.6, 50.0, 50.4)
    filmstrip(ffmpeg, frames, work / "contact-sheet.png", narrative_times)
    filmstrip(ffmpeg, frames, work / "whip-filmstrip.png", whip_times, crop=True)
    filmstrip(ffmpeg, frames, work / "submission-filmstrip.png", submission_times, crop=True)
    filmstrip(ffmpeg, frames, work / "quota-filmstrip.png", (18.8, 24.0, 26.0, 26.8, 31.6, 34.8))
    filmstrip(ffmpeg, frames, work / "reset-filmstrip.png", (35.9, 36.5, 38.0, 40.8, 42.5, 43.4))
    manifest = {
        "duration_seconds": DURATION,
        "frame_count": DURATION * FPS,
        "mp4": {"width": 1280, "height": 720, "fps": FPS, "audio": True, "audio_codec": "AAC"},
        "gif": {"width": 800, "fps": 20, "loop": 0, "audio": False},
        "chapters": [
            {"start": 0, "end": 18, "story": "Capacity retry", "submission": 12.2},
            {"start": 18, "end": 35, "story": "Scheduled quota renewal", "quota_confirmed": 26.5, "submission": 32.3},
            {"start": 35, "end": 52, "story": "Illustrated early reset", "post_enters": 35.6, "quota_check": 42, "quota_confirmed": 43, "submission": 48.8},
            {"start": 52, "end": 56, "story": "Same model. Keep going."},
        ],
        "inspection_times_seconds": narrative_times,
        "whip_filmstrip_times_seconds": whip_times,
        "submission_filmstrip_times_seconds": submission_times,
        "whip_impact_times_seconds": WHIP_IMPACTS,
        "example_message": EXAMPLE_MESSAGE,
        "example_retry_seconds": EXAMPLE_RETRY_SECONDS,
        "example_check_seconds": EXAMPLE_CHECK_SECONDS,
        "audio_events": events,
        "audio_report": json.loads(audio_report.read_text()),
        "origin": "Programmatic AppKit/CoreGraphics render with preexisting docs/app-icon.png",
        "session": "Synthetic; typing illustrated, time compressed. No session files, identifiers, or inference requests. Actual app sends one local RPC message. An illustrated announcement is followed by a separate actual-quota confirmation; the app does not monitor social posts.",
    }
    (work / "render-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for name in ("codex-whip.mp4", "codex-whip.gif", "poster.png"):
        path = target / name
        print(f"{path.relative_to(ROOT)}: {path.stat().st_size:,} bytes")
    print("Inspection: build/demo/{contact-sheet,whip-filmstrip,submission-filmstrip,quota-filmstrip,reset-filmstrip}.png")


if __name__ == "__main__":
    main()
