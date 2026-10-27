#!/usr/bin/env python3
"""Draw the installer window's background in the film's blueprint look, at 1x and 2x.

The disk image opens to a 660 by 420 point window: the app on the left, Applications on the right,
an arrow between them and the first-launch step at the bottom. Finder draws icon labels white in dark
mode and black in light mode, so each label sits on a chip whose luminance gives both at least 4.5:1.
The positions here must match ICONS in scripts/build_app.py. Needs Pillow and the macOS font SF.
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 660, 420
APP, APPLICATIONS, ICON_Y, LABEL_Y = 165, 495, 200, 274
CYAN = (95, 216, 242)
SF = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    face = ImageFont.truetype(SF, size)
    face.set_variation_by_axes([100, min(96, size), 400, weight])  # width, optical size, grade, weight
    return face


def chip_color():
    """A cyan-blue whose relative luminance sits where white and black text tie, about 0.18."""
    def luminance(rgb):
        channels = [c / 255 for c in rgb]
        linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    low, high = 0.0, 1.0
    for _ in range(40):
        mid = (low + high) / 2
        if luminance(tuple(round(c * mid) for c in (70, 150, 230))) < 0.1791:
            low = mid
        else:
            high = mid
    return tuple(round(c * low) for c in (70, 150, 230))


def draw(scale):
    w, h = WIDTH * scale, HEIGHT * scale
    s = lambda v: round(v * scale)
    card = Image.new("RGB", (w, h))
    px = card.load()
    for y in range(h):
        for x in range(w):
            k = max(0.0, 1 - math.hypot((x - w / 2) / (w * 0.72), (y - s(ICON_Y)) / (h * 1.0)))
            k = k * k * (3 - 2 * k)
            px[x, y] = (int(4 + 8 * k), int(14 + 62 * k), int(36 + 118 * k))
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(layer)
    for x in range(s(6), w, s(30)):
        g.line([(x, 0), (x, h)], fill=(*CYAN, 14), width=1)
    for y in range(s(6), h, s(30)):
        g.line([(0, y), (w, y)], fill=(*CYAN, 14), width=1)
    # Soft light behind each icon, as in the film's reveal.
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for cx in (APP, APPLICATIONS):
        ImageDraw.Draw(glow).ellipse([s(cx - 78), s(ICON_Y - 78), s(cx + 78), s(ICON_Y + 78)], fill=(64, 190, 255, 70))
    card = Image.alpha_composite(card.convert("RGBA"), glow.filter(ImageFilter.GaussianBlur(s(30))))
    card = Image.alpha_composite(card, layer)
    d = ImageDraw.Draw(card)
    # The arrow: a dashed shaft and a solid head, from the app to Applications.
    start, end = APP + 82, APPLICATIONS - 86
    x = start
    while x < end - 16:
        d.line([(s(x), s(ICON_Y)), (s(min(x + 9, end - 16)), s(ICON_Y))], fill=CYAN, width=s(3))
        x += 15
    d.polygon([(s(end), s(ICON_Y)), (s(end - 16), s(ICON_Y - 9)), (s(end - 16), s(ICON_Y + 9))], fill=CYAN)
    # Title and steps.
    title, body, small = font(s(22), 700), font(s(13), 500), font(s(11.5), 400)
    def centered(text, y, face, fill, cx=WIDTH / 2):
        d.text((s(cx) - d.textlength(text, font=face) / 2, s(y)), text, font=face, fill=fill)
    centered("Codex Whip", 34, title, (244, 249, 255))
    centered("Drag to Applications to install", 66, body, (184, 226, 245))
    # Label chips under both icons.
    chip = chip_color()
    for cx, width in ((APP, 118), (APPLICATIONS, 112)):
        d.rounded_rectangle([s(cx - width / 2), s(LABEL_Y - 12), s(cx + width / 2), s(LABEL_Y + 12)], s(12), fill=chip)
    centered("First launch blocked? System Settings › Privacy & Security › Open Anyway", 372, small, (150, 180, 205))
    return card.convert("RGB")


if __name__ == "__main__":
    out = ROOT / "assets/dmg"
    out.mkdir(parents=True, exist_ok=True)
    draw(1).save(out / "background.png", optimize=True)
    draw(2).save(out / "background@2x.png", optimize=True)
    print(f"Wrote {out / 'background.png'} and @2x; chip {chip_color()}")
