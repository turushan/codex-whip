<div align="center">
  <img src="docs/app-icon.png" alt="Codex Whip" width="136">
  <h1>Codex Whip</h1>
  <p><strong>Keep Codex working.</strong></p>
  <p>A tiny Mac companion that nudges Codex back to work after capacity errors and quota waits.</p>
  <p>
    <a href="https://github.com/turushan/codex-whip/releases/latest/download/Codex-Whip-arm64.dmg"><strong>Download for Apple silicon</strong></a>
    &nbsp; · &nbsp;
    <a href="https://github.com/turushan/codex-whip/releases/latest/download/Codex-Whip-x86_64.dmg"><strong>Download for Intel</strong></a>
  </p>
  <p>macOS 14+ · MIT licensed · No extra sign-in</p>
</div>

<p align="center">
  <a href="docs/demo/codex-whip.mp4">
    <picture>
      <source media="(prefers-reduced-motion: reduce)" srcset="docs/demo/poster.png?v=1.8.0-night">
      <img src="docs/demo/codex-whip.gif?v=1.8.0-night" alt="Animated demo: a whip crack introduces Codex Whip, then after a capacity error it waits three minutes, types the saved message, and Codex continues with the same model" width="800">
    </picture>
  </a>
</p>
<p align="center"><sub>Illustrated demo · Time compressed · <a href="docs/demo/codex-whip.mp4">Watch the full film with sound</a></sub></p>

## A little nudge. Same session.

When Codex says **“Selected model is at capacity,”** Whip waits, then asks the **same session** to continue with the **same model**.

Out of quota? Whip waits for Codex to confirm usage is available again, then continues. Regular renewals and early resets use the same check.

- **Set the pace.** Pick intervals right in the menu. Preview, edit, or reset the retry message.
- **Hear the nudge.** Optional whip sounds mark each retry. Silent by default.
- **See the recovery.** A clear 24-hour activity report tracks capacity and quota retries separately.
- **Keep it running.** Start at Login and optional automatic GitHub updates handle the daily routine.

Defaults: **check every five minutes · retry capacity every three minutes**. Pause anytime. Settings and history stay on your Mac.

<p align="center">
  <img src="docs/menu.png" alt="Codex Whip menu with retry and check intervals, message controls, and Activity" width="300">
</p>

## Up and running

1. Download the DMG and drag **Codex Whip** into **Applications**.
2. Open it and choose **Start at Login** if you want it there each morning.
3. Use **Codex CLI** as usual. Whip watches the loaded terminal sessions.

Choose **Watch Demo** in the menu to see capacity retries, quota renewals, and an early reset in action, with sound.

First launch blocked? This community build has no Apple notarization. [How to open it](docs/INSTALL.md#first-launch).

Downloads, source, and in-app updates are publicly available through GitHub.

<details>
<summary><strong>Build it yourself</strong></summary>

Requires a Mac, Xcode command-line tools, and Python 3.9+.

```sh
git clone https://github.com/turushan/codex-whip.git
cd codex-whip
python3 scripts/build_app.py
```

The app and DMG appear in `dist/`. [Full build and release guide](docs/RELEASING.md).

</details>

[How it works & compatibility](docs/INSTALL.md#what-gets-retried) · [Settings & privacy](docs/INSTALL.md#activity-and-local-files) · [MIT license](LICENSE)

[Experimental Desktop connector](docs/DESKTOP.md) · Explicit conversation selection; capacity retries only.

An unofficial Codex CLI companion. Requires its shared local daemon. Model availability still depends on OpenAI.
