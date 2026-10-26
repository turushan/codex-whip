# Demo assets

A 56-second marketing film shows three ways Codex Whip keeps work moving. The
terminal, whip, input and output are authored illustrations. Persistent labels
identify the demo, illustrated typing and compressed time. No real session data,
identifiers or inference requests are used.

| Time | Story |
|---|---|
| 0–18 s | Model at capacity → explicit three-minute wait → three whip strikes reveal the retry message → continued work. |
| 18–35 s | Quota exhausted → recurring five-minute checks → regular renewal → quota confirmation → continued work. |
| 35–52 s | An illustrated Tibo reset post → the next Codex quota check → quota confirmation → continued work. |
| 52–56 s | “Same model. Keep going.” Closing brand moment and a quiet sound cue. |

The announcement illustrates an early reset. Whip checks Codex quota and does not
monitor tweets or consume reset credits. The post/avatar sources and retrieved
asset hash are in [the avatar provenance](../../assets/demo/tibo-avatar.provenance.json).
The reference archive is [Codex Resets](https://codex-resets.com/); its linked
[original post](https://x.com/thsottiaux/status/2106131810921136451) could not be
retrieved directly during production. The scene is labeled as illustrated and
does not imply endorsement.

Whip strikes and progressive typing are visual metaphors. The real helper sends
the saved continuation as one local message. “Working” means activity observed;
successful recovery still requires two uninterrupted observed minutes or a
completed retry turn. Saved custom messages remain unchanged.

The MP4 includes original procedural whip, typing, check, renewal, notification
and ending sounds. There is no licensed music, downloaded sound sample or voice
imitation. The README GIF is silent; its link opens the MP4 with sound. The native
app starts sound only after Watch Demo is selected, supplies mute/volume controls
and remembers those choices during the app session.

## Regenerate

Requires macOS, Xcode Command Line Tools, Python 3 and FFmpeg with H.264/AAC/GIF
support. FFmpeg is needed only to regenerate media, not to build or run the app.

```sh
python3 scripts/render_demo.py
```

The wrapper reads the shared message and interval defaults from `settings.py`,
compiles the native renderer, generates original audio with
`scripts/render_demo_audio.py`, and writes:

- `codex-whip.mp4`: 1280×720, 30fps, H.264/yuv420p, stereo AAC at 48 kHz, fast start.
- `codex-whip.gif`: silent looping animation for the README.
- `poster.png`: a closing still with portable origin metadata.

Ignored `build/demo/` contains temporary frames, audio event timings, render
metadata and contact sheets for motion review. Sound is deterministic noise and
oscillator synthesis, mastered with headroom for AAC encoding. The event timings
tie each crack to its visible whip impact.

## Asset origin

Terminal, typography, grid, whip geometry and motion come from AppKit/CoreGraphics
code in `scripts/render_demo.swift`. The approved icon comes from
`assets/AppIcon.png`; its generation prompt and provenance stay beside it.
Tibo's unmodified public avatar appears only in the illustrated post, with its
source recorded separately. Rendered PNGs carry origin metadata rather than an
invented AI prompt. MP4 metadata describes the illustrated scenes and sound.
