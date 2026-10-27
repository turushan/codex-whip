#!/usr/bin/env python3
"""Render the original short retry whip effect with the Python standard library."""

import math
from pathlib import Path
import random
import struct
import wave


def render():
    rate = 44100
    count = round(rate * 0.55)
    strike = round(rate * 0.24)
    samples = [0.0] * count
    rng = random.Random(0x57484950)
    low = previous_low = 0.0
    for i in range(strike):
        u = i / strike
        cutoff = 350 * (16 ** u)
        coefficient = 1 - math.exp(-2 * math.pi * cutoff / rate)
        low += coefficient * (rng.uniform(-1, 1) - low)
        high = low - previous_low
        previous_low = low
        fade = min(1, i / (0.015 * rate), (strike - i) / (0.004 * rate))
        samples[i] = (0.25 * low + 2 * high) * u ** 2.5 * max(0, fade) * 0.42

    core = []
    low = 0.0
    for i in range(round(0.12 * rate)):
        t = i / rate
        noise = rng.uniform(-1, 1)
        low += 0.25 * (noise - low)
        burst = (noise - low) * math.exp(-t / 0.009) * min(1, i / 7) * 0.42
        body = math.sin(2 * math.pi * 210 * t) * math.exp(-t / 0.018) * 0.22
        boom = 0.0
        if i < 5:
            boom = i / 4
        elif i < 29:
            boom = 1 - 1.35 * (i - 5) / 24
        elif i < 37:
            boom = -0.35 * (1 - (i - 29) / 8)
        core.append(boom + burst + body)
    for delay, gain in [(0, 1), (0.009, 0.16), (0.017, 0.09)]:
        for i, sample in enumerate(core):
            samples[strike + round(delay * rate) + i] += sample * gain
    peak = max(abs(value) for value in samples)
    return rate, b"".join(struct.pack("<h", round(value / peak * 0.6 * 32767)) for value in samples)


def main():
    output = Path(__file__).resolve().parents[1] / "engine/Sources/WhipEngine/Resources/whip.wav"
    output.parent.mkdir(parents=True, exist_ok=True)
    rate, data = render()
    with wave.open(str(output), "wb") as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(rate)
        sound.writeframes(data)
    print(f"Rendered {output.name}: 0.55 seconds, mono 44.1 kHz PCM")


if __name__ == "__main__":
    main()
