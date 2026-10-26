#!/usr/bin/env python3
"""Render the illustrated marketing film with native Mac graphics and an original score.

The storyboard lives in scripts/demo/video/Film.swift. This wrapper compiles the
video and audio renderers, writes the shared timeline, renders the score, renders
the picture in parallel chunks, and encodes the README and app assets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from settings import DEFAULT_MESSAGE, DEFAULT_SETTINGS  # noqa: E402

DURATION = 60
FPS = 60
WIDTH, HEIGHT = 1920, 1080
WORK = ROOT / "build" / "demo"
TARGET = ROOT / "docs" / "demo"
# The README loop: the reveal, then the capacity story back to work.
GIF_RANGE = (8.0, 22.0)
GIF_FPS = 15
GIF_WIDTH = 800
POSTER_TIME = 58.0
REVIEW_TIMES = (1.5, 4.2, 6.4, 8.25, 9.6, 11.0, 13.5, 16.05, 17.6, 20.5, 23.6, 26.9,
                28.1, 30.5, 34.4, 36.9, 40.0, 43.6, 45.8, 46.8, 49.9, 52.3, 54.8, 58.0)
STRIKE_TIMES = tuple(round(15.62 + index / 30, 4) for index in range(18))
TITLE = "Codex Whip · Same model. Keep going."
DESCRIPTION = (
    "Illustrated marketing film: a capacity retry, a scheduled quota renewal and an early reset, overnight. "
    "Time compressed and typing illustrated. Whip checks Codex quota, not social posts, and sends one saved "
    "continuation message. Original procedural music and sound. No model requests or endorsement."
)


def run(*arguments: str, **options) -> subprocess.CompletedProcess:
    return subprocess.run(arguments, cwd=ROOT, check=True, **options)


def embed_origin(path: Path) -> None:
    """Preserve ImageIO metadata and add the portable Impeccable PNG origin keyword."""
    keyword = b"impeccable:prompt"
    origin = (
        "Programmatic origin, not an AI image prompt: deterministic native AppKit, CoreGraphics and "
        "Core Image frame rendered by scripts/demo/video. An illustrated overnight story with the default "
        "retry message; time compressed. Kinematic whip, synthetic terminal and interface. The unmodified "
        "public avatar is from https://codex-resets.com/thsottiaux-avatar.jpg; provenance: "
        "assets/demo/tibo-avatar.provenance.json. The actual app sends one local RPC message and checks "
        "Codex quota, not posts. Synthetic demo session; no live session data or inference requests. "
        "Existing approved icon: docs/app-icon.png, derived from assets/AppIcon.png; original icon prompt "
        "and provenance are in assets/AppIcon.prompt.txt and assets/AppIcon.provenance.json."
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


def compile_renderers() -> tuple[Path, Path]:
    video = WORK / "render-film"
    audio = WORK / "render-score"
    for sources, binary in ((sorted((ROOT / "scripts/demo/video").glob("*.swift")), video),
                            (sorted((ROOT / "scripts/demo/audio").glob("*.swift")), audio)):
        run("xcrun", "swiftc", "-O", "-swift-version", "5", *map(str, sources), "-o", str(binary))
    return video, audio


def film_arguments(renderer: Path) -> list[str]:
    return [str(renderer), "--icon", str(ROOT / "docs/app-icon.png"),
            "--avatar", str(ROOT / "assets/demo/tibo-avatar.jpg"),
            "--message", DEFAULT_MESSAGE,
            "--retry", str(DEFAULT_SETTINGS["retry_seconds"]),
            "--check", str(DEFAULT_SETTINGS["scan_seconds"])]


def render_chunks(ffmpeg: str, renderer: Path, jobs: int, start: float, end: float, fps: int,
                  folder: Path, *, gif: bool = False) -> list[Path]:
    """Render frames in parallel processes, each into a lossless RGB intermediate."""
    folder.mkdir(parents=True, exist_ok=True)
    first, last = round(start * fps), round(end * fps)
    bounds = [first + (last - first) * index // jobs for index in range(jobs + 1)]
    processes, outputs = [], []
    for index in range(jobs):
        output = folder / f"chunk-{index:02d}.mkv"
        command = film_arguments(renderer) + ["raw", "--fps", str(fps),
                                              "--from", repr(bounds[index] / fps), "--to", repr(bounds[index + 1] / fps)]
        if gif:
            command.append("--gif")
        producer = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE)
        encoder = subprocess.Popen([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
                                    "-pix_fmt", "bgra", "-s", f"{WIDTH}x{HEIGHT}", "-r", str(fps), "-i", "-",
                                    "-c:v", "libx264rgb", "-qp", "0", "-preset", "ultrafast", str(output)],
                                   cwd=ROOT, stdin=producer.stdout)
        producer.stdout.close()
        processes.append((producer, encoder))
        outputs.append(output)
    for producer, encoder in processes:
        if producer.wait() != 0 or encoder.wait() != 0:
            raise SystemExit("Rendering a chunk failed.")
    listing = folder / "chunks.txt"
    listing.write_text("".join(f"file '{path.name}'\n" for path in outputs))
    return outputs


def filmstrip(ffmpeg: str, stills: Path, times: tuple[float, ...], target: Path, *, columns: int,
              width: int, crop: str | None = None) -> None:
    inputs = []
    for instant in times:
        inputs += ["-i", str(stills / f"still-{instant:06.3f}.png")]
    scale = (f"crop={crop}," if crop else "") + f"scale={width}:-2"
    filters = ";".join(f"[{index}:v]{scale}[s{index}]" for index in range(len(times)))
    rows = (len(times) + columns - 1) // columns
    labels = "".join(f"[s{index}]" for index in range(len(times)))
    filters += f";{labels}xstack=inputs={len(times)}:grid={columns}x{rows}:fill=0x081523[out]"
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *inputs, "-filter_complex", filters,
        "-map", "[out]", "-frames:v", "1", str(target))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=max(2, min(6, (os.cpu_count() or 4) // 2)),
                        help="parallel render processes")
    parser.add_argument("--preview", action="store_true", help="fast encode into build/demo only")
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required to regenerate media (brew install ffmpeg).")
    began = time.monotonic()
    WORK.mkdir(parents=True, exist_ok=True)
    TARGET.mkdir(parents=True, exist_ok=True)
    video, audio = compile_renderers()

    plan = WORK / "plan.json"
    run(*film_arguments(video), "plan", str(plan))
    score, audio_report = WORK / "score.wav", WORK / "audio-report.json"
    run(str(audio), "--plan", str(plan), "--output", str(score), "--report", str(audio_report))

    print(f"Rendering {DURATION * FPS} frames in {args.jobs} processes…", flush=True)
    chunks = render_chunks(ffmpeg, video, args.jobs, 0, DURATION, FPS, WORK / "chunks")
    film = (WORK / "preview.mp4") if args.preview else (TARGET / "codex-whip.mp4")
    run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
        "-f", "concat", "-safe", "0", "-i", str(chunks[0].parent / "chunks.txt"), "-i", str(score),
        "-map", "0:v", "-map", "1:a",
        # Tag the sRGB transfer so AVFoundation shows the frames as rendered, without a gamma lift.
        "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p,"
               "setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=tv",
        "-c:v", "libx264", "-preset", "veryfast" if args.preview else "veryslow", "-crf", "23",
        "-profile:v", "high", "-level", "4.2", "-x264-params", "aq-mode=3:deblock=-1,-1",
        "-c:a", "aac_at", "-b:a", "256k", "-t", str(DURATION), "-shortest", "-movflags", "+faststart",
        "-metadata", f"title={TITLE}", "-metadata", f"comment={DESCRIPTION}", str(film))

    stills = WORK / "stills"
    shutil.rmtree(stills, ignore_errors=True)
    review = sorted(set(REVIEW_TIMES + STRIKE_TIMES + (POSTER_TIME,)))
    run(*film_arguments(video), "stills", ",".join(f"{instant:.3f}" for instant in review), str(stills))
    filmstrip(ffmpeg, stills, REVIEW_TIMES, WORK / "contact-sheet.png", columns=4, width=640)
    filmstrip(ffmpeg, stills, STRIKE_TIMES, WORK / "whip-filmstrip.png", columns=6, width=480, crop="1500:900:300:120")

    if not args.preview:
        gif_chunks = render_chunks(ffmpeg, video, args.jobs, *GIF_RANGE, GIF_FPS, WORK / "gif", gif=True)
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "concat", "-safe", "0", "-i", str(gif_chunks[0].parent / "chunks.txt"),
            "-filter_complex", f"scale={GIF_WIDTH}:-1:flags=lanczos,split[a][b];"
            "[a]palettegen=max_colors=128:stats_mode=diff[p];"
            "[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
            "-loop", "0", str(TARGET / "codex-whip.gif"))
        poster = WORK / "poster"
        shutil.rmtree(poster, ignore_errors=True)
        run(*film_arguments(video), "--grain", "0", "stills", f"{POSTER_TIME:.3f}", str(poster))
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(poster / f"still-{POSTER_TIME:06.3f}.png"),
            "-vf", "scale=1280:-1:flags=lanczos", str(TARGET / "poster.png"))
        embed_origin(TARGET / "poster.png")

    manifest = {
        "duration_seconds": DURATION,
        "frame_count": DURATION * FPS,
        "mp4": {"width": WIDTH, "height": HEIGHT, "fps": FPS, "video": "H.264 High, yuv420p, BT.709",
                "audio": "AAC 256 kbps (AudioToolbox), 48 kHz stereo"},
        "gif": {"range_seconds": GIF_RANGE, "fps": GIF_FPS, "width": GIF_WIDTH, "loop": 0, "audio": False},
        "poster_time_seconds": POSTER_TIME,
        "plan": json.loads(plan.read_text()),
        "audio_report": json.loads(audio_report.read_text()),
        "example_message": DEFAULT_MESSAGE,
        "example_retry_seconds": DEFAULT_SETTINGS["retry_seconds"],
        "example_check_seconds": DEFAULT_SETTINGS["scan_seconds"],
        "origin": "Programmatic AppKit, CoreGraphics and Core Image render with preexisting docs/app-icon.png; "
                  "original procedural score from scripts/demo/audio",
        "session": "Synthetic; typing illustrated, time compressed. No session files, identifiers or inference requests. "
                   "The illustrated announcement is followed by a separate Codex quota confirmation; the app does not monitor posts.",
        "sha256": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (film, TARGET / "codex-whip.gif", TARGET / "poster.png") if path.exists()},
    }
    (WORK / "render-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for path in (film, TARGET / "codex-whip.gif", TARGET / "poster.png"):
        if path.exists() and (not args.preview or path == film):
            print(f"{path.relative_to(ROOT)}: {path.stat().st_size:,} bytes")
    print(f"Review: build/demo/contact-sheet.png and build/demo/whip-filmstrip.png · {time.monotonic() - began:.0f} s")


if __name__ == "__main__":
    main()
