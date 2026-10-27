# Demo assets

A 60-second marketing film follows one Codex session through a night of
interruptions. The terminal, whip, menus and timeline are authored illustrations.
A persistent label marks the film as an illustrated demo with compressed time. No
real session data, identifiers or inference requests are used.

| Time | Story |
|---|---|
| 0–8 s | 2:13 AM. Codex works through a task, then stops at “Selected model is at capacity.” The music tape-stops. Without help, the session waits all night. |
| 8–12 s | A whip crack introduces Codex Whip: “Keep Codex working.” The icon settles into the menu bar. |
| 12–22 s | Capacity. Whip finds the error on its next check at 2:15 AM. A compressed three-minute wait follows, three strikes type the default retry message, and the same session continues at 2:18 AM. |
| 22–32 s | Quota renewal. Usage runs out at 4:52 AM. Whip checks Codex every five minutes, Codex confirms quota at 5:02 AM, and one strike sends the message. |
| 32–42 s | Early reset. A recreated reset post from Tibo appears. Whip’s next Codex quota check at 6:36 AM finds quota and continues. |
| 42–52 s | Morning. The task finishes. The Activity report shows the night’s recoveries, and the native menu shows the interval choices. |
| 52–60 s | “Codex stops. Whip doesn’t.” Closing lockup with the download link. |

The post card recreates Tibo’s public post of 2 October 2026, “Reset all
propagated. Enjoy.”, as listed by [Codex Resets](https://codex-resets.com/) with
its [original link](https://x.com/thsottiaux/status/2106131810921136451). The film
places it at an illustrative time to show an early reset. Whip checks Codex quota
and does not monitor posts or consume reset credits. The post/avatar sources and
retrieved asset hash are in [the avatar provenance](../../assets/demo/tibo-avatar.provenance.json).
The card is labeled “Recreated from X” and does not imply endorsement.

Whip strikes and progressive typing are visual metaphors. The real helper sends
the saved continuation as one local message. “Back to work” means activity
observed; successful recovery still requires two uninterrupted observed minutes
or a completed retry turn. The menu titles, interval choices and Activity labels
match the native app; the counts and session IDs are illustrative. Saved custom
messages remain unchanged.

## Sound

The MP4 carries an original score at 120 BPM in D minor that lifts to F major at
sunrise, mixed with original effects: whip cracks on the beat, a tape stop when
Codex halts, ticks for compressed waits, check pings and confirmation chimes in
the score’s key. Every sound is deterministic synthesis in `scripts/demo/audio`.
There is no licensed music, downloaded sample, sound bank or voice. The mix is
normalized to about −16 LUFS with true peaks at or below −1.5 dBTP. The README
GIF is silent; its link opens the MP4 with sound. The native app starts sound
only after Watch Demo is selected, supplies mute and volume controls and
remembers those choices during the app session.

## Regenerate

Requires macOS, Xcode Command Line Tools, Python 3 and FFmpeg with libx264 and
the AudioToolbox AAC encoder (`aac_at`). FFmpeg is needed only to regenerate
media, not to build or run the app.

```sh
python3 scripts/render_demo.py
```

The wrapper reads the shared message and interval defaults from `settings.py`,
compiles both renderers, writes the timeline and sound cues to
`build/demo/plan.json`, renders the score from that plan, renders the picture in
parallel chunks and writes:

- `codex-whip.mp4`: 1920×1080, 60 fps, H.264 High with BT.709 primaries and
  matrix, AAC 256 kbps stereo at 48 kHz, fast start. The sRGB transfer tag is
  deliberate: AVFoundation then shows the frames as rendered, while a BT.709
  tag lifts the dark navy.
- `codex-whip.gif`: a silent 800 px loop of the reveal and the capacity story
  for the README.
- `poster.png`: the closing frame with portable origin metadata, used as the
  reduced-motion still.

`--preview` writes a faster encode to `build/demo/preview.mp4` instead. Ignored
`build/demo/` also holds the score, its loudness report, review stills, a
contact sheet, a whip filmstrip and `render-manifest.json`.

## Asset origin

Terminal, typography, grid, menus, whip geometry, motion and finishing come from
AppKit, CoreGraphics and Core Image code in `scripts/demo/video`. The whip is
kinematic: a U-turn loop rolls from the handle to the tip, so every crack lands
on its beat and on its target. The approved icon comes from `assets/AppIcon.png`;
its generation prompt and provenance stay beside it. Tibo’s unmodified public
avatar appears only in the recreated post, with its source recorded
separately. Rendered PNGs carry origin metadata rather than an invented AI
prompt. MP4 metadata describes the illustrated scenes and sound.
