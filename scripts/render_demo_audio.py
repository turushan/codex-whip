#!/usr/bin/env python3
"""Synthesize original, event-aligned sound effects for the illustrated demo.

All audio comes from deterministic noise and oscillators in this file. There are
no recordings, borrowed samples, music, speech, or runtime dependencies.

Example:
    python3 scripts/render_demo_audio.py --duration 56 \
        --events build/demo/audio-events.json --output build/demo/score.wav

An event is {"time": 7.0, "type": "whip"}, optionally with gain (0..1.5) and
pan (-1..1). Time means onset for other cues and the visible impact for a whip:
its airy windup starts 0.7 seconds before that impact. The renderer owns timing.
"""

from __future__ import annotations

import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
import random
import sys
import wave


SAMPLE_RATE = 48000
# Leave one additional decibel for the AAC encode's possible intersample peaks.
PEAK_CEILING_DBFS = -5.0
SEED = 170056
EVENT_TYPES = frozenset({
    "whip", "whoosh", "tap", "check", "renewal", "post", "confirm", "send", "logo",
})


def _number(value, name):
    if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number")
    return float(value)


def _decay(t, rate, attack=0.003):
    if t < 0:
        return 0.0
    return min(1.0, t / attack) * math.exp(-rate * t)


def _tail(t, duration):
    """A short final release avoids a discontinuity at the edge of a cue."""
    return max(0.0, min(1.0, (duration - t) / 0.012))


def _render_cue(kind, rate, rng):
    # A whip is shaped around its visible impact, rather than starting a loud
    # noise file when the animation winds up. Restrained reflections finish it.
    if kind == "whip":
        lead, duration = 0.7, 1.04
        slow = fast = crack_low = 0.0
        for index in range(round(duration * rate)):
            local = index / rate - lead
            white = rng.uniform(-1, 1)
            if local < 0:
                phase = (local + lead) / lead
                fast += (0.06 + 0.45 * phase**2) * (white - fast)
                slow += (0.014 + 0.055 * phase) * (white - slow)
                # The rope gathers speed, then leaves a tiny gap for the snap.
                envelope = math.sin(math.pi * phase) ** 1.2 * phase**1.5
                air = (fast - slow) * envelope * 0.29
                air += math.sin(2 * math.pi * (170 * local + 630 * phase**3)) * envelope * 0.013
                yield local, air, -0.18 + 0.30 * phase
                continue
            crack_low += 0.24 * (white - crack_low)
            crack = (white - crack_low) * _decay(local, 90, 0.0006) * 0.95
            body = math.sin(2 * math.pi * (190 * local - 200 * local**2)) * _decay(local, 45) * 0.19
            flick = math.sin(2 * math.pi * (1700 * local + 900 * local**2)) * _decay(local, 105) * 0.085
            reflection = (white - crack_low) * _decay(local - 0.032, 56) * 0.14
            air = white * _decay(local - 0.020, 22, 0.010) * 0.045
            yield local, (crack + body + flick + reflection + air) * _tail(local, duration - lead), 0.12
        return

    if kind == "whoosh":
        duration = 0.62
        fast = slow = 0.0
        for index in range(round(duration * rate)):
            t = index / rate
            phase = t / duration
            white = rng.uniform(-1, 1)
            fast += (0.08 + 0.45 * phase) * (white - fast)
            slow += 0.018 * (white - slow)
            envelope = math.sin(math.pi * phase) ** 2
            yield t, (fast - slow) * envelope * 0.13, -0.35 + 0.70 * phase
        return

    if kind == "tap":
        duration = 0.065
        low = 0.0
        for index in range(round(duration * rate)):
            t = index / rate
            white = rng.uniform(-1, 1)
            low += 0.17 * (white - low)
            value = (math.sin(2 * math.pi * 420 * t) * 0.055 + low * 0.095) * _decay(t, 84, 0.001)
            yield t, value * _tail(t, duration), 0.0
        return

    if kind == "check":
        duration = 0.13
        for index in range(round(duration * rate)):
            t = index / rate
            value = (math.sin(2 * math.pi * 740 * t) * 0.045
                     + math.sin(2 * math.pi * 1110 * t) * 0.012) * _decay(t, 32)
            yield t, value * _tail(t, duration), 0.0
        return

    if kind in ("renewal", "post", "confirm", "logo"):
        # These brief, original harmonic gestures are feedback, not a score.
        notes = {
            "renewal": [(0.0, 659.255, 0.078), (0.09, 987.767, 0.061), (0.18, 1318.510, 0.050)],
            "post": [(0.0, 880.000, 0.064), (0.105, 1108.731, 0.047)],
            "confirm": [(0.0, 783.991, 0.078), (0.045, 1175.987, 0.028)],
            "logo": [(0.0, 329.628, 0.095), (0.095, 493.883, 0.076), (0.20, 659.255, 0.052)],
        }[kind]
        duration = {"renewal": 0.95, "post": 0.55, "confirm": 0.38, "logo": 1.6}[kind]
        decay = {"renewal": 7.0, "post": 11.0, "confirm": 15.0, "logo": 3.8}[kind]
        for index in range(round(duration * rate)):
            t = index / rate
            value = 0.0
            for offset, frequency, amplitude in notes:
                note_time = t - offset
                if note_time >= 0:
                    envelope = _decay(note_time, decay, 0.008)
                    value += amplitude * envelope * (
                        math.sin(2 * math.pi * frequency * note_time)
                        + 0.16 * math.sin(2 * math.pi * frequency * 2 * note_time)
                    )
            yield t, value * _tail(t, duration), 0.0
        return

    if kind == "send":
        duration = 0.19
        for index in range(round(duration * rate)):
            t = index / rate
            phase = t / duration
            value = math.sin(2 * math.pi * (430 * t + 1300 * t**2)) * math.sin(math.pi * phase)**2 * 0.065
            value += math.sin(2 * math.pi * 180 * t) * _decay(t, 42) * 0.030
            yield t, value * _tail(t, duration), 0.0
        return

    raise ValueError(f"Unknown audio event: {kind}")


def generate_audio(output_path, duration, events, sample_rate=SAMPLE_RATE):
    """Write a deterministic stereo PCM16 WAV and return small quality metadata."""
    duration = _number(duration, "duration")
    if not 0.05 <= duration <= 300:
        raise ValueError("duration must be from 0.05 to 300 seconds")
    if isinstance(sample_rate, bool) or not isinstance(sample_rate, int) or not 8000 <= sample_rate <= 96000:
        raise ValueError("sample_rate must be an integer from 8000 to 96000")
    if not isinstance(events, list):
        raise ValueError("events must be a JSON array")
    if len(events) > 2000:
        raise ValueError("The demo supports at most 2,000 sound events")
    frames = round(duration * sample_rate)
    mix = array("f", [0.0]) * (frames * 2)
    cue_report = []
    for event in events:
        if not isinstance(event, dict) or set(event) - {"time", "type", "gain", "pan"}:
            raise ValueError("Each event requires time/type and optional gain/pan")
        time = _number(event.get("time"), "event time")
        if not 0 <= time < duration:
            raise ValueError("event time must fall inside the film")
        kind = event.get("type")
        if not isinstance(kind, str) or kind not in EVENT_TYPES:
            raise ValueError(f"Unsupported audio event type: {kind!r}")
        gain = _number(event.get("gain", 1.0), "event gain")
        pan = _number(event.get("pan", 0.0), "event pan")
        if not 0 <= gain <= 1.5 or not -1 <= pan <= 1:
            raise ValueError("event gain must be 0..1.5 and pan must be -1..1")
        digest = hashlib.sha256(json.dumps(event, sort_keys=True).encode("utf-8")).digest()
        rng = random.Random(SEED ^ int.from_bytes(digest[:8], "big"))
        first_frame = last_frame = None
        for local, value, sweep in _render_cue(kind, sample_rate, rng):
            position = round((time + local) * sample_rate)
            if not 0 <= position < frames:
                continue
            direction = max(-1.0, min(1.0, pan + sweep))
            left, right = math.sqrt((1 - direction) / 2), math.sqrt((1 + direction) / 2)
            mix[position * 2] += value * gain * left
            mix[position * 2 + 1] += value * gain * right
            first_frame = position if first_frame is None else min(first_frame, position)
            last_frame = position
        cue_report.append({
            "type": kind, "time": time,
            "first_frame": first_frame, "last_frame": last_frame,
            "anchor_frame": round(time * sample_rate),
        })

    # Trim clicks at film boundaries without filling the purposeful quiet gaps.
    fade = min(round(0.008 * sample_rate), frames // 2)
    for index in range(fade):
        factor = index / fade
        for frame in (index, frames - 1 - index):
            mix[frame * 2] *= factor
            mix[frame * 2 + 1] *= factor
    peak = max((abs(value) for value in mix), default=0.0)
    ceiling = 10 ** (PEAK_CEILING_DBFS / 20)
    scale = min(1.0, ceiling / peak) if peak else 1.0
    pcm = array("h")
    squared = left_energy = right_energy = dc_sum = 0.0
    quantized_peak = 0
    for index, value in enumerate(mix):
        value *= scale
        encoded = round(value * 32767)
        pcm.append(encoded)
        quantized_peak = max(quantized_peak, abs(encoded))
        squared += encoded * encoded
        dc_sum += encoded
        if index % 2:
            right_energy += encoded * encoded
        else:
            left_energy += encoded * encoded
    if sys.byteorder != "little":
        pcm.byteswap()
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as file:
        file.setparams((2, 2, sample_rate, frames, "NONE", "not compressed"))
        file.writeframes(pcm.tobytes())
    rms = math.sqrt(squared / len(mix)) / 32767
    report = {
        "duration_seconds": frames / sample_rate,
        "sample_rate": sample_rate,
        "channels": 2,
        "pcm_bits": 16,
        "frames": frames,
        "event_count": len(events),
        "peak_dbfs": 20 * math.log10(quantized_peak / 32767) if quantized_peak else None,
        "rms_dbfs": 20 * math.log10(rms) if rms else None,
        "dc_offset": dc_sum / len(mix) / 32767,
        "channel_energy_ratio": left_energy / right_energy if right_energy else None,
        "master_scale": scale,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "source": "Original deterministic procedural sound design in scripts/render_demo_audio.py; no outside audio assets.",
        "cues": cue_report,
    }
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, required=True)
    parser.add_argument("--events", type=Path, required=True, help="JSON array of timed cues")
    parser.add_argument("--output", type=Path, required=True, help="Stereo PCM16 WAV path")
    parser.add_argument("--report", type=Path, help="Optional JSON measurements")
    args = parser.parse_args()
    try:
        events = json.loads(args.events.read_text(encoding="utf-8"))
        report = generate_audio(args.output, args.duration, events)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "cues"}, indent=2))


if __name__ == "__main__":
    main()
