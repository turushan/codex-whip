# Codex Whip

A local macOS menu bar app and command-line helper for retrying Codex terminal capacity failures and recovering from usage-quota waits.

## Development

- Work directly on `main` unless another branch is requested. Preserve unrelated work and commit only owned paths.
- Use plain, public-facing commit messages without internal ticket numbers.
- Keep documentation focused on shipped behavior and contributor workflows. Keep personal setup notes, research, and conversation records outside Git.
- Never merge archived development history into this repository.
- Keep the model, reasoning effort, permissions, service tier, and conversation settings unchanged on retries.
- Retry only the latest failed capacity or supported usage-quota turn. Both `idle` and `systemError` are inactive runtime states.
- Default to five-minute checks and three-minute capacity retries. Due capacity timers and retry health observations run independently of discovery checks. Preserve saved custom settings.
- Quota recovery requires explicit ordinaryUsageAllowed permission and the same observed account. Unknown quota status or account changes hold retries. Never infer permission from percentages or reset times, consume reset credits, or switch accounts/models.
- Keep quota and capacity Activity counters separate. Do not log or store account identities in history; any private account binding stays in retry state.
- Keep the native app minimal: status, pause/resume, Start at Login, retry/check interval submenus, retry-message preview/editor/default action, Activity, Watch Demo, update controls, About, and Quit.
- Read and save preferences locally in Swift. Generate bundled defaults from settings.py; do not start the Python helper to open or edit preferences.
- Keep Whip Sound on by default for new installs. Play it asynchronously for live accepted retries, once when the app opens, and once when the sound is turned on; never for scans, uncertain sends, reconstructed history, or quitting.
- Count retry recovery after two minutes of uninterrupted observed activity, or successful completion sooner.
- The app owns its helper process and login item. The optional CLI service is a separate installation mode.
- Retain history, pending timers, and the send journal when updating an installed helper.
- Keep the command name `codex-whip`. Do not add legacy command aliases.

## Privacy and testing

- Keep credentials, runtime state, logs, build environments, and personal session data outside Git.
- Do not manufacture model requests or continue real sessions for tests. Use temporary files and local protocol stubs.
- Use `doctor` for read-only checks against an installed Codex daemon.
- Document signing and notarization truthfully. Do not recommend disabling Gatekeeper globally.
- Keep the private Sparkle update key in Keychain. Verify signed feeds and archives before installation.
- Keep the bundle ID `com.turushan.codex-whip` and the Sparkle update key stable; installed apps update only while both stay the same.
- Verify the built app's architecture, deployment target, bundled helper, and launch behavior before publishing a release.

## Validation

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
python3 codex_whip.py doctor
python3 scripts/build_app.py
```

Builds use the host architecture. See [installation and source builds](docs/INSTALL.md).
