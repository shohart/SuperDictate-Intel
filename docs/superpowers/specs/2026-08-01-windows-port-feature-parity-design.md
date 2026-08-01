# Windows-port feature parity: fillers, auto-stop, login/mute settings rows, adaptive HUD color

Date: 2026-08-01

> Per explicit instruction, this spec was written without an interactive
> brainstorming/approval round. Design calls made unilaterally are
> documented inline as they occur, so they can be revisited on review if
> needed.

## Scope

Following a comparison against the sibling Windows port
(`github.com/metawka/SuperDictate-win`), the user selected exactly these
items to bring over, plus one unrelated small HUD bug fix surfaced in the
same conversation:

1. Expand filler-word removal to match the Windows port's richer,
   per-word-configurable preset list (Russian + English hesitations and
   verbal-tic phrases), with a custom-word list, exposed in the Settings
   window (currently a single non-configurable menu toggle).
2. Auto-stop recording after a configurable duration of continuous
   silence (does not exist today — only in-recording pause *segmentation*
   for transcription accuracy exists, which is a different mechanism).
3. "Launch at login" as a Settings-window row (the engine already fully
   exists via `SMAppService`; today it's a menu-bar item only).
4. "Mute system audio while recording" as a Settings-window row (the
   engine already fully exists; today it's a menu-bar item only).
5. A "Manage corrections…" discoverability row in the Settings window
   that opens the existing corrections manager (the corrections engine
   *and* its full menu-driven UI — add/edit/delete/import/export/sync —
   already exist and are more capable than the Windows port's; no backend
   or menu changes needed here, purely a Settings-window entry point).
6. A new "Contrast" (adaptive) option for the HUD's recording/transcribing
   accent color, alongside the existing fixed colors — fixes a real bug
   where choosing "White" with a light capsule background makes the
   waveform/outline invisible. "Contrast" resolves to black on a light
   capsule background and white on a dark one, decided fresh every time
   the HUD redraws (so it also tracks a `.system`-background-style HUD
   through a live light/dark-mode switch, same as the background itself
   already does).

**Explicitly out of scope** (per direct user instruction): live/streaming
transcript preview, compute-provider/model-quantization settings (not
portable — no CUDA-equivalent concept on this stack), text-style presets
(deferred, discuss later), history-bubble-count setting (existing history
design is different, do not touch), and the statistics dashboard (already
exists, not being touched here).

## 1. Filler-word removal: preset table, per-word toggles, custom words

### Current state

`FillerWordRemover` (`main.swift:6486`) has a hardcoded English-only list:

```swift
private static let fillerPatterns = ["um+", "uh+", "ah+", "er", "erm", "hm+"]
```

applied via `apply(to:)` with no parameters controlling which patterns are
active. The single on/off toggle (`ControlPanelSettings.removeFillerWords`,
key `remove_filler_words`) lives only in the menu-bar dropdown
(`main.swift:15286-15291`, action `toggleRemoveFillerWords` at `16842`) —
there is no Settings-window row for it today.

### Design

**Preset table.** Replace the flat `fillerPatterns` array with a
structured table:

```swift
struct FillerWordPreset {
    let key: String              // stable identifier, e.g. "ru_kak_by" — used as the persistence key, never shown to the user, never renamed once shipped
    let displayText: String      // e.g. "как бы", "um"
    let pattern: String          // regex fragment, same word-boundary-safe style already used
    let defaultEnabled: Bool
}
```

Seed list (mirrors the Windows port's `PRESET_FILLERS`, adapted to this
file's existing regex conventions — repeat-quantified where the original
already did this for stretched-out hesitations):

- Default **on** (unambiguous hesitation sounds): `um+`, `uh+`, `ah+`,
  `er`, `erm`, `hm+` (existing English set, unchanged), plus Russian:
  `э+`, `эм+`, `м+`, `ам+`, `аа+`.
- Default **off** (real words/phrases that are only sometimes filler —
  same rationale the Windows port documents: don't delete real words
  without explicit consent): Russian phrases `как бы`, `типа`, `короче`,
  `это самое`, `так сказать`, `в общем`, `собственно`, `допустим`,
  `слушай`, `понимаешь`, `знаешь`; English `like`, `you know`, `i mean`,
  `actually`, `basically`.

Multi-word phrase patterns join tokens with `\s+` (tolerant of ASR
spacing variance), single-word entries keep the existing quantifier style.
**Longest-pattern-first ordering** in the built alternation, so "это
самое" is tried before a bare "это" could ever partially match (it can't,
since "это" isn't itself a preset — but this ordering rule generalizes to
custom words too, see below, and matches the Windows port's stated
behavior).

**Custom words.** A user-editable `[String]` list,
`ControlPanelSettings.customFillerWords` (new key
`custom_filler_words`), each entry regex-escaped via
`NSRegularExpression.escapedPattern(for:)` token-by-token and rejoined
with `\s+` between whitespace-separated tokens (so a multi-word custom
entry tolerates ASR spacing the same way presets do, while still being a
literal match, not a user-supplied regex).

**Per-preset enablement.** `ControlPanelSettings.enabledFillerPresetKeys:
Set<String>` (new key `enabled_filler_preset_keys`, stored as an array).
Getter: if the key has never been written (first run / upgrade from an
older version), return the default-enabled key set computed from
`defaultEnabled`; once written, always return exactly the stored set.
This means an upgrade from the old single-toggle world preserves "filler
removal is on" behavior via the *existing* `removeFillerWords` master
toggle (unchanged), while the newly-introduced per-preset breakdown starts
from sensible defaults rather than "everything off."

**Updated `apply(to:)` signature:**

```swift
static func apply(to text: String,
                   enabledPresetKeys: Set<String>,
                   customWords: [String]) -> (text: String, removedCount: Int)
```

Builds its alternation from `presets.filter { enabledPresetKeys.contains($0.key) }.map(\.pattern) + escapedCustomPatterns(customWords)`, sorted longest-source-text-first, then proceeds exactly as today (same punctuation-cleanup and capitalization-repair passes, untouched). All call sites (`main.swift:11585`, `13140`, `13378`) pass `settings.enabledFillerPresetKeys` / `settings.customFillerWords` instead of relying on the old implicit list — but only when `settings.removeFillerWords` is `true` (the master toggle keeps its current gating role unchanged).

### Settings-window UI

New disclosure-style row group under a new master toggle in
`makeSettingsContentView()` (`main.swift:25275`), following the existing
`NSSwitch` row pattern (`normalizeNumbersRow`, `main.swift:26111-26145`)
for the master on/off switch, plus a scrollable checklist (one row per
preset, grouped by language, `NSSwitch` per item) revealed by an
expand/disclosure control, plus a simple add/remove text-field-and-list
control for custom words (same interaction shape as any other
add/remove list in this codebase — the corrections menu at
`main.swift:15873-15939` is the closest existing reference for "list with
per-row delete," even though that one lives in a menu, not this window).

**Menu-bar item removed.** The existing `toggleRemoveFillerWords` menu
item (`main.swift:15286-15291`, `16842`) is removed once the master
toggle lives in Settings — one authoritative place per persisted
preference, matching how every other durable setting in this app already
works (colors, HUD size, hotkeys, etc. are Settings-only, not
menu-duplicated).

## 2. Auto-stop recording after N seconds of silence

### Current state

No such feature exists. `PauseSegmenter` splits a completed recording's
PCM into pause-bounded chunks for ASR accuracy — an offline,
post-recording concern, unrelated to *live* auto-termination of the
recording session itself.

The closest existing *live* auto-termination mechanism is
`scheduleMaxDurationAutoRelease()` (`main.swift:13654-13663`): a
fixed-deadline `DispatchWorkItem` that, after `MAX_RECORDING_SECONDS`,
calls `hotkey.resetToggleState()` then `handleRelease()` — exactly the
same effect as the user releasing the hotkey normally. This is the
pattern to mirror.

### Design

New settings:

- `ControlPanelSettings.autoStopOnSilenceEnabled: Bool` (key
  `auto_stop_on_silence_enabled`, default `false` — opt-in, since this
  changes recording behavior for everyone who might currently rely on
  long silent pauses mid-thought).
- `ControlPanelSettings.autoStopSilenceSeconds: Int` (key
  `auto_stop_silence_seconds`, default `5`, valid range 1-10 — mirrors the
  Windows port's slider range exactly).

**Live silence tracking**, added to `recordingLevelTimerFired`
(`main.swift:12002` onward), which already runs at a fixed cadence and
already computes `unsuppressedLevel`/`rawLevel` from
`audio.latestRecordingLevelSnapshot()` each tick (`main.swift:12007-12015`)
— exactly the signal this feature needs, no new audio-processing
machinery required:

```swift
private static let liveSilenceLevelThreshold: Float = 0.02
private var silenceStartedAt: TimeInterval?
```

Each tick: if `unsuppressedLevel < Self.liveSilenceLevelThreshold`, set
`silenceStartedAt` if not already set, and if
`settings.autoStopOnSilenceEnabled` and `now - silenceStartedAt >=
TimeInterval(settings.autoStopSilenceSeconds)`, trigger the same
end-of-recording path the max-duration timer uses:

```swift
hotkey.resetToggleState()
handleRelease()
```

If `unsuppressedLevel >= liveSilenceLevelThreshold`, reset
`silenceStartedAt = nil` (silence must be *continuous* to count, matching
the Windows port's semantics — any voiced tick resets the clock).
`silenceStartedAt` is reset to `nil` in `startRecordingLevelMeter()`
alongside the meter's other per-session resets, so a fresh recording
always starts with a clean slate.

This constant `0.02` is deliberately a fresh, independent threshold — not
reused from `PauseSegmenter.defaultSilenceRMSThreshold`, which operates on
raw sample RMS in a completely different signal domain (offline PCM
buffer analysis vs. the already-normalized 0...1 `level` value the HUD
bars already animate from). Tune-by-inspection is expected here; the
self-test for this logic (see plan) validates the *state-machine*
behavior (continuous-silence timing, reset-on-voice, opt-in gating), not
a specific numeric threshold choice, since the right threshold is a
product/UX call verified by listening, not something a unit test can
validate in isolation.

### Settings-window UI

New row group in `makeSettingsContentView()`: a boolean toggle ("Stop
automatically after silence") using the same `NSSwitch` pattern as
`normalizeNumbersRow`, plus — only meaningfully visible/enabled when the
toggle is on — a duration control. Given this codebase's existing
`popupRow` pattern is the only pre-built control for "a small closed set
of choices" (`main.swift:26249`), reuse it here for simplicity rather than
introducing a new slider widget: a `popupRow` with a `1...10` (seconds)
option set, labeled "Silence duration," matching the Windows port's 1-10s
range exactly but as a dropdown instead of a slider (this is a
UI-technology substitution, not a functional deviation — the underlying
persisted value and behavior are identical).

## 3. "Launch at Login" — promote to a Settings-window row

### Current state

Fully implemented via `SMAppService.mainApp` (`register()`/`unregister()`,
status read at `main.swift:14802-14813` and `16891-16901`), exposed only
as a menu-bar item ("Launch at Login," `main.swift:15331-15344`, action
`toggleLaunchAtLogin` at `16874`), plus an auto-enable-on-first-run path
(`ensureLaunchAtLoginEnabled()`, `16890`) that is **unaffected by this
change** — it keeps running exactly as today.

### Design

No new engine code. Add a Settings-window `NSSwitch` row (same pattern as
`normalizeNumbersRow`) whose state reflects `SMAppService.mainApp.status
== .enabled` and whose toggle action calls the existing
`register()`/`unregister()` paths (the same calls the menu item already
makes — factor the menu action's body into a small shared helper if it
isn't already a standalone function, so both the menu item, if kept, and
the new Settings row call one source of truth rather than duplicating
`SMAppService` calls).

**Menu-bar item removed** once the Settings row exists, for the same
one-authoritative-place-per-preference reasoning as filler words above.

## 4. "Mute system audio while recording" — promote to a Settings-window row

### Current state

Fully implemented: `ControlPanelSettings.muteWhileRecording` (key
`mute_while_recording`, default `true`), engine at
`muteIfNeededForRecording()` (`main.swift:13477`) and the
mute/unmute state machine (`8072-8093`), invoked at `12950`. Exposed only
as a menu-bar item (`main.swift:15309-15313`, `16838`).

### Design

No new engine code — this is a pure UI relocation, identical in shape to
§3: add a Settings-window `NSSwitch` row wired to the existing
`settings.muteWhileRecording` property (same read/write path the menu
item already uses), following the `normalizeNumbersRow` pattern. **Menu
item removed** once the Settings row exists.

Note: "pause media playback" (a *different*, media-key-simulation-based
feature the Windows port also has) is explicitly **not** part of this
work — the user only asked for the system-audio mute to move into
Settings, not for a new media-pause feature to be built.

## 5. "Manage corrections…" — Settings-window discoverability row

### Current state

`TranscriptCorrection` (`main.swift:1083`), persisted via
`ControlPanelSettings.transcriptCorrections` (key
`transcript_corrections`, capped at `MAX_TRANSCRIPT_CORRECTIONS = 512`),
already has a **complete** menu-driven management UI
(`buildCorrectionsItem()`, `main.swift:15788`): add, add-from-last-
transcript, per-item edit/delete, remove-all, import/export, share, and a
full sync-file mechanism. This is already more capable than the Windows
port's corrections tab — **no backend or menu changes are needed here.**

### Design

**Architectural constraint discovered during planning**: `buildCorrectionsItem()`
and its action handlers live on `ParakeyApp` (`main.swift:10918`), the
menu-bar `--agent` process. `makeSettingsContentView()` lives on
`SuperDictateControlPanelApp` (`main.swift:25047`), a **separate process**
— the Settings window is its own executable invocation, not merely a
different window in the same app. There is no existing IPC call that lets
the control-panel process trigger the agent process to present a specific
piece of UI (the only cross-process mechanism in this codebase today is a
`DistributedNotificationCenter` pair used for hotkey-capture coordination,
`main.swift:11319-11337`, which isn't a fit for "pop up a menu with a
screen anchor" across process boundaries).

Building real cross-process menu-triggering for this would be
disproportionate to the value of what is explicitly the lowest-priority,
purely-discoverability item in this whole spec. Design call: **no
interactive control**. Add one static informational row to
`makeSettingsContentView()` — a label (both languages, via `t(...)`)
along the lines of "Manage text corrections from the menu bar icon →
Text Corrections" — with no button, no action, no new IPC. This still
meets the actual goal (a first-time Settings-window visitor now learns
the feature exists and roughly where to find it) without inventing
cross-process plumbing for a minor nicety. The full-featured menu-driven
corrections UI is untouched and remains the single, sole entry point.

## 6. HUD "Contrast" (adaptive) accent color

### Current state

`RecordingHUDAccentColor` (`main.swift:525-560`) has 8 fixed cases
(`red/orange/pink/purple/blue/cyan/green/white`), each with a static
`.nsColor`. `RecordingHUDView.shouldUseLightBackground()`
(`main.swift:9796-9806`, currently `private`) decides light-vs-dark
capsule background from `backgroundStyle` (`.light`/`.dark`/`.system`,
the last consulting `effectiveAppearance`). The two places accent colors
get resolved onto the view
(`configureRecordingHUDView`, `main.swift:12417-12424`; and the debug/
preview helper `exportRecordingHUDAnimationFrames`, `main.swift:9843-9844`)
currently do a flat `settings.recordingHUDRecordingColor.nsColor` with no
knowledge of the chosen background — so picking "White" with a light
capsule background (or "system" background style resolving light)
produces invisible bars/outline. This is a real, reported bug, not
hypothetical.

### Design

Add a ninth case:

```swift
enum RecordingHUDAccentColor: String, CaseIterable {
    case red, orange, pink, purple, blue, cyan, green, white, contrast
    // ... existing displayName additions: .contrast -> "Contrast"
}
```

New resolution method (existing `.nsColor` stays as-is and is still used
directly by anything that doesn't care about background, e.g. any
existing self-test asserting a specific static color):

```swift
extension RecordingHUDAccentColor {
    func resolvedColor(lightBackground: Bool) -> NSColor {
        switch self {
        case .contrast: return lightBackground ? .black : .white
        default: return nsColor
        }
    }
}
```

`.white` is intentionally left alone — it stays literally white even on a
light background if a user explicitly picks it (their choice to fix by
switching to "Contrast" instead, not something this fix silently
overrides).

**Wiring**: change `shouldUseLightBackground()`'s access level from
`private` to (no modifier / internal) — it needs to be callable from
`configureRecordingHUDView`, a method on a different type in the same
file. In `configureRecordingHUDView` (`main.swift:12417-12424`), reorder
so `view.backgroundStyle` is set *before* colors are resolved, then
resolve through the view's own live decision:

```swift
private func configureRecordingHUDView(_ view: RecordingHUDView) {
    view.visualScale = settings.recordingHUDSize.visualScale
    view.backgroundStyle = settings.recordingHUDBackgroundStyle
    let isLight = view.shouldUseLightBackground()
    view.recordingColor = settings.recordingHUDRecordingColor.resolvedColor(lightBackground: isLight)
    view.transcribingColor = settings.recordingHUDTranscribingColor.resolvedColor(lightBackground: isLight)
    view.displayMode = settings.recordingHUDDisplayMode
}
```

Because `configureRecordingHUDView` already runs on every
`showRecordingHUD`/`updateRecordingHUD` call (i.e. every level-update
tick during a live recording, per the existing HUD update loop), a
`.system`-background-style HUD with "Contrast" selected will re-resolve
live if the user's system appearance changes mid-recording — the same
liveness `.system` background style already has for the capsule fill
itself, just now extended to the accent color too, at no extra cost.

The debug/preview helper `exportRecordingHUDAnimationFrames`
(`main.swift:9843-9844`) is updated analogously for consistency
(hardcodes `backgroundStyle = .dark`, so it resolves with
`lightBackground: false`), though this path is not user-visible — it's
generated animation-frame export tooling.

### Settings-window UI

No new UI mechanism — the existing "Recording color"/"Transcribing color"
`popupRow`s (`main.swift:25317-25325` and the transcribing-color
equivalent) already iterate `RecordingHUDAccentColor.allCases`, so adding
the new case to the enum is sufficient; it appears automatically in both
dropdowns with its `displayName`/localized name once
`localizedColorName(_:)` (wherever that switch lives, alongside
`localizedHUDSizeName`/`localizedDisplayModeName`) gets one new case
added.

## Testing strategy

- **Filler words**: pure-logic self-test group covering preset alternation
  building (longest-first ordering, custom-word escaping, multi-word
  `\s+` tolerance), default-enabled-set computation on first run vs.
  respecting a stored override, and end-to-end `apply(to:...)` cases for
  a representative sample of new Russian presets and phrases — following
  the existing `testRussianNumberITN*`-style self-test conventions
  already used elsewhere in this file for similar text-transformation
  logic.
- **Auto-stop-on-silence**: pure state-machine self-test (not a live-audio
  test) — feed a sequence of synthetic `(level, elapsedTime)` samples into
  the tracking logic (refactored into a small, independently-testable
  pure function/struct rather than living directly inline in
  `recordingLevelTimerFired`, so it can be driven by a test without a real
  `AVAudioEngine`) and assert: continuous silence past the threshold
  triggers, a voiced tick resets the clock, disabled setting never
  triggers, and the boundary (`elapsed == threshold` exactly) behaves
  consistently.
- **Launch at Login / Mute rows**: no new pure-logic surface beyond what
  already has coverage (if any) for `SMAppService`/`muteWhileRecording` —
  these are UI-wiring-only changes, verified by manual check per the
  existing project convention for pure-UI work (same as the recording HUD
  work earlier in this project).
- **Corrections row**: trivial UI wiring, manual check only.
- **HUD contrast color**: pure-logic self-test for
  `resolvedColor(lightBackground:)` (all 9 cases × both background
  states, asserting `.contrast` flips and every other case stays
  constant), following the same self-test-group convention as the rest of
  the HUD work (`recording-hud-*` groups). No automated rendering test
  (same rationale as prior HUD work — pure UI, manually verified).

All builds/tests run on the real Intel Mac via SSH, per this project's
established convention — never locally, never via
`--self-test all`, always with the post-test LaunchAgent safety check.
