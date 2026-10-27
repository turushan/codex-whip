# Desktop prototype

The `codex-whip` command includes an opt-in Desktop connector. The installed
menu bar app continues to watch terminal sessions.

It requires the running macOS Desktop app, Codex CLI's shared local daemon, and
one explicitly selected local conversation already owned by Desktop.

Build the command from the source checkout with `swift build -c release --package-path engine`.
Read the conversation's state without sending anything:

```sh
engine/.build/release/codex-whip desktop --thread CONVERSATION_ID doctor
```

Watch future capacity failures in that conversation:

```sh
engine/.build/release/codex-whip desktop --thread CONVERSATION_ID watch
```

Stop with Control-C. This foreground prototype installs no login item and uses a
separate journal under `~/Library/Application Support/Codex Whip Desktop Prototype/`.
It uses the usual three-minute capacity retry and five-minute discovery defaults.
Its private `settings.json` accepts the same intervals, message and optional sound.
Sound starts off in this prototype; an explicitly saved sound preference is preserved.

Desktop supplies current activity, owner and settings. The local daemon supplies
completion timestamps only when the saved turn matches Desktop's latest turn.
Unknown state, pending input, changed settings, lost ownership and ambiguous sends
hold or cancel retries. Quota recovery stays on hold until a Desktop-account-bound
permission check is available.

The connector uses an internal versioned Desktop interface. It refreshes the
conversation immediately before submitting, but that interface has no atomic
compare-and-start operation. Keep testing explicitly scoped; this is a prototype.
Run `doctor` before starting the watcher. It explains whether the selected
conversation is ready or held. In particular, `inheritance-mismatch` holds a retry
when Desktop's saved settings disagree with the displayed selection; the prototype
does not override either set of settings.
