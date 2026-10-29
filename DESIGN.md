# Design

Codex Whip uses one monochrome whip icon and a standard macOS menu.
The static 18-point template echoes the large icon: a broad rounded loop, a diagonal grip at the lower
right (2.6-point stroke), and a filled rope outline tapering from a thick attachment to a fine tip.
The tail curls away from the grip, preserving a visible gap at actual menu size. AppKit supplies its
native tint and highlighted appearance. Keep the accessible name "Codex Whip". Preserve system typography, spacing,
separators, keyboard behavior, and accessibility. The app follows light and dark system appearance.
An invisible main menu gives the app's windows Command-W, Command-Q, and the standard Edit shortcuts.

The large application icon uses a dimensional braided brown whip over a luminous cyan-to-blue blueprint tile, with fine
grid lines, construction guides, a beveled rim, and an open curl. Preserve the generated source PNG,
prompt, and provenance under `assets/`. The native icon export applies a clean rounded mask and
downsamples that artwork into the standard macOS icon sizes.
Export the blue tile with an opaque interior so macOS does not wrap the artwork in a gray plate.
Retain transparent outer margins and the rounded silhouette for older macOS versions.

The first lines answer whether retries are enabled, how many sessions are watched, and whether a retry
is waiting. The actions are Pause/Resume, Start at Login, Retry Every, Check Every, Retry Message,
update controls, Activity, Watch Demo, and Quit Codex Whip. Activity and Watch Demo only show
information, so they take no ellipsis. Quit names the app and sits after its own separator.
While macOS awaits approval, Start at Login reads Approve Start at Login… and opens Login Items in
System Settings; it never unregisters the pending item.

Retry Every and Check Every are native submenus with checked selections and labeled defaults.
Their titles use title-style capitalization and spelled-out units, such as Retry Every 3 Minutes
and 3 Minutes (Default). They keep that wording, disabled, while preferences load or cannot be read.
Five-minute checks and three-minute capacity retries are the defaults; selections save immediately. Preserve
valid custom intervals and show them as checked custom values when outside the preset choices.
Retry Message: Default or Custom opens a preview bounded to two short lines, followed by Edit
Message… and Use Default Message. The menu's Use Default Message saves the default immediately.

Edit Message… opens a compact, resizable plain-text editor with Use Default, Cancel, and Save.
Use Default fills the draft; Save applies it, while Cancel or closing discards unsaved text. Keep
validation and save errors beside the text, with native keyboard behavior and Command Return to
save. Opening the menu reads local `settings.json` directly; interval choices and message saves
write it atomically. Defaults come from the app bundle, and existing custom values remain intact.

Whip Sound is a native checkable menu item beside the retry preferences. It is off by default and
saves immediately. A short whip crack marks each sent retry without changing focus or system volume.
Checks, waiting, uncertain sends, and restored activity remain silent.

Keep Check for Updates… and a checkable Automatic Updates item in the same native menu treatment.
Sparkle owns its standard update and relaunch dialogs. Public GitHub feeds and downloads support
in-app update delivery.

Activity is a small readable native report with the last 24-hour totals and recent events. Startup,
missing Codex, paused, waiting, running, updating, and failed states must be truthful: a helper that
stopped or could not start never reads as Paused, preferences that cannot load never read as
preparing, and countdowns appear only while watching, never beside an error. Errors use the app's
name and plain words, with details in tooltips and the Activity report. Counts come from the engine's
last successful scan. Successful retries mean two uninterrupted minutes of observed activity,
or successful completion sooner. The report explains this without waiting for the whole task.
Keep separate Capacity and Quota recovery counts. Show a quota status row only while quota waits
exist, distinguish the next quota check from a capacity retry countdown, and explain unknown status
or account changes without showing account identifiers.

Watch Demo opens codexwhip.com/demo in the default browser, where the film starts at once. The app
bundles no video, so downloads and updates stay small. A browser that refuses sound before the
visitor interacts plays the film muted, with a button that restarts it with sound.

The sixty-second marketing film follows one terminal through a night. Codex stops at 2:14 AM, a
whip crack introduces the app, and three stories follow on the menu bar clock: a capacity retry, a
scheduled quota renewal, and a recreated reset post from Tibo. Morning ends on the native
Activity report and menu, then "Codex stops. Whip doesn’t." holds from 52 seconds. A Whip timeline
column explains each wait; the three-minute capacity wait and five-minute quota checks are
explicitly compressed. The reset post precedes a separate Codex quota confirmation; it never
suggests Whip monitors posts or redeems credits.

The whip is kinematic: a U-turn loop rolls from the handle to the tip, so each crack lands on its
beat and target, with motion blur, a refractive shockwave and sparks. The capacity story's three
strikes type the default message; later stories send it with one strike, closer to the real single
send. An original 120 BPM score in D minor lifts to F major at sunrise; a tape stop marks the halt,
cracks fall on beats, and checks and chimes are tuned to the key. Keep the illustrated and
time-compressed disclosure visible. The real app sends saved text at once and confirms recovery
only after healthy work. The film uses no real sessions or inference.

The README is a short visual product page: lead with the app icon, a clear promise, and direct Mac
downloads; show the looping demo GIF with a reduced-motion still alternative, a link to the MP4,
and real native preferences screenshots; give three setup steps. Keep build details in a collapsed disclosure
and link to the fuller documentation.
