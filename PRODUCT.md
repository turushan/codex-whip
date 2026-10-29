# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Stack

Native AppKit menu bar app in Swift, wrapping the existing Python retry engine bundled with PyInstaller.
Distribute a minimal native Mac app as a DMG, with source builds available.
The repository, release downloads, and update feeds are public.

## Users and purpose

Codex terminal users who want their selected model to continue after a temporary capacity failure or usage-quota renewal.
The app watches existing local terminal sessions and continues only unfinished work.
The app is named Codex Whip; the command and repository are `codex-whip`.

## Confirmed constraints

- One small menu with watching status, pause, start at login, Retry Every, Check Every, Retry Message, update controls, Activity, Watch Demo, and Quit Codex Whip.
- Use a monochrome whip for the menu bar identity.
- Default to five-minute checks and three-minute capacity retries. Native interval submenu selections apply immediately. Due retries and healthy-turn observations run independently of discovery cadence.
- Resume supported usage-quota failures only after Codex explicitly permits ordinary usage again for the observed account. This covers regular and early renewals without a reset tracker. Unknown status/account changes hold retries; never consume credits or change accounts/models.
- Show quota waiting/check status in the menu and separate quota/capacity counts in Activity. Account permission allows a guarded attempt, without guaranteeing selected-model availability.
- The default retry message is "Keep using the selected model. Continue the unfinished work." Preserve saved custom intervals and messages.
- Keep a bounded retry-message preview with Edit Message… and Use Default Message. The latter saves immediately; the compact editor's Use Default fills a draft that requires Save. Cancel or closing discards unsaved text.
- Offer a Whip Sound toggle, off by default. Play one short original sound after each accepted retry, respecting system volume and mute.
- Read and write local `settings.json` directly, using atomic saves and authoritative defaults bundled with the app. Reflect CLI preference edits when the menu opens.
- Use a blue blueprint grid and a dimensional braided whip for the large app icon. Keep the menu bar glyph monochrome.
- Keep the README short and visual, with direct downloads, real screenshots, three setup steps, and collapsed build details.
- Tell the capacity retry, scheduled quota renewal, and early reset stories in a labeled sixty-second overnight marketing film at 1080p and 60 fps, ending on the native Activity report and menu. Keep readable message entry and a whip whose cracks land on the beat: a silent looping README GIF with a reduced-motion still, plus an MP4 with an original procedural score and sound effects.
- The Tibo announcement is an illustrated example. Show quota confirmation before continuation; Whip checks Codex usage and does not monitor tweets. Keep the original post/avatar sources and provenance with the assets.
- Preserve the session, model, reasoning, permissions, and service tier.
- Distribute a self-contained Mac app and source that users can build themselves.
- Watch Demo opens the film on codexwhip.com/demo; the app bundles no video. FFmpeg is needed only to regenerate demo assets, not to build or run the app.
- Current releases are ad hoc signed and are not Apple-notarized. Document the first-launch macOS warning.
- Keep all session metadata and history on the user's Mac.
- Count recovery as successful after two uninterrupted minutes of observed retry activity, or successful completion sooner.
- Keep Sparkle's signed-update controls and optional automatic installation. Release downloads and update feeds are public GitHub URLs.
- The command is `codex-whip`; no legacy aliases are installed.

## Evidence

The existing Python engine has automated local protocol and behavior tests and has resumed real capacity-failed sessions.
The source repository contains no production session data.
The authored demo uses no live session data or inference requests.
