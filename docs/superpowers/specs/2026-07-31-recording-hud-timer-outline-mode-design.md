# Recording HUD: timer + outline-fill display mode

Date: 2026-07-31

## Problem

The floating recording-indicator HUD ("bubble") currently has one visual
style while recording: 8 animated vertical bars driven by the live audio
level (`RecordingHUDView.drawFloatingWaveformOnly()`,
`swift/Sources/Parakey/main.swift:9345`). Now that long dictations are
reliable (overlap segmentation + seam dedup, v0.4.7), users want an
optional at-a-glance sense of *how long* they've been talking, without
having to enable the (out-of-scope, not implemented, and intentionally
not being added) live-transcript-in-bubble option.

## Goals

- Add a second HUD display mode, selectable in Settings, that shows the
  elapsed recording duration as `MM:SS` text (minutes always two digits,
  e.g. `00:10`) centered in the bubble.
- In this new mode, audio level is still visualized, but as a colored
  outline-fill around the bubble's pill/capsule border (growing from the
  bottom, symmetrically up both sides) instead of the current bar style.
  The filled portion of the outline also glows, with glow intensity
  increasing as the filled fraction increases.
- The existing bar-style visualization remains available, unchanged, as
  the default and first option.
- No new color setting — the outline-fill/glow uses the existing
  "Recording color" (`RecordingHUDAccentColor`) setting.

## Non-goals

- Live transcribed text in the bubble (explicitly rejected by the user).
- Any change to `transcribing` / `error` HUD modes — this only affects
  the `.recording` mode's visualization.
- A new color picker.

## Design

### Setting: display mode

New enum, following the existing `RecordingHUDAccentColor` pattern
(`main.swift:525-560`):

```swift
enum RecordingHUDDisplayMode: String, CaseIterable {
    case levelBars   // current behavior, default
    case timerOutline
}
```

Stored in `ControlPanelSettings` (alongside `showRecordingWaveform` at
`main.swift:2798-2803`, property pattern at `main.swift:3128-3138`),
backed by `UserDefaults`. Exposed in the Settings panel
(`makeSettingsContentView()`, `main.swift:24827`) as a new popup row via
the existing `popupRow(title:detail:selectedValue:options:action:toolTip:)`
helper — the same mechanism used for "Recording color"
(`main.swift:24869-24877`) — placed directly below it. Default:
`.levelBars`, so existing users see no change until they opt in.

### Timer source of truth

`startRecordingLevelMeter()` (`main.swift:11940`) is the single place
recording-level tracking begins. It gains one new field set at the top of
the function, alongside the existing resets:

```swift
recordingHUDStartedAt = Date()
```

This is a real wall-clock timestamp of when audio capture begins — not
tied to the reveal animation (`recordingHUDRevealStartedAt`,
`main.swift:12278`), which is a separate, variable-duration cosmetic
appear effect and would make a poor timer origin. `recordingHUDStartedAt`
is read (not mutated) by the HUD's per-frame update path
(`recordingLevelTimerFired`, driving `updateRecordingHUD`,
`main.swift:12023`) to compute elapsed seconds each frame, same cadence
as the existing 24 fps level timer. No new timer is introduced.

### Rendering: `drawTimerWithOutlineFill`

New method on `RecordingHUDView`, sibling to
`drawFloatingWaveformOnly()` (`main.swift:9345`) and
`drawTranscribingWave(in:alpha:)` (`main.swift:9462`), selected by mode at
the same dispatch point currently choosing between the recording/
transcribing/error draw paths. Reuses the same `capsuleRect` /
`NSBezierPath(roundedRect:xRadius:yRadius:)` geometry already computed
for the pill shape (`main.swift:9371-9377`) — the outline traces this
same path, not a new shape.

- **Text**: `MM:SS` computed from `elapsed = now - recordingHUDStartedAt`,
  minutes always zero-padded to 2 digits (so `00:10`, not `0:10`), drawn
  centered using a monospaced-digit font variant so the text doesn't
  jitter horizontally as digits change.
- **Outline fill**: strokes the capsule border, filled fraction of the
  perimeter tracks the existing `level` value (`main.swift:9326`)
  directly and instantly — same reactivity as the current 8-bar
  visualization, no added smoothing. Fill grows from the bottom center
  point of the capsule, symmetrically up both the left and right side, so
  at `level == 1` the entire perimeter is lit.
- **Glow**: applied only to the filled portion of the outline (the
  unfilled remainder of the perimeter stays a plain, unlit stroke). Glow
  intensity (blur radius and/or alpha) scales with the filled fraction —
  louder voice means both more of the outline is lit *and* that lit
  portion glows more strongly.
- **Color**: both the outline stroke and its glow use the user's
  configured `RecordingHUDAccentColor` (existing "Recording color"
  setting) — no new color configuration surface.

### Interaction with other HUD modes

`.transcribing` and `.error` HUD modes are unaffected — this design only
adds a second rendering path for `.recording` mode, chosen by the new
setting. When recording stops (transitions to `.transcribing`), the
timer/outline visualization simply stops updating along with the rest of
the recording-mode drawing, same lifecycle as the current bars.

### Testing

Manual verification on the real Mac (per project convention — this is a
pure UI/rendering change with no automatable self-test coverage):
toggle the new setting, dictate for >60s to confirm minutes roll over
correctly and stay two-digit (`01:05`, not `1:05`), confirm outline fill
and glow respond to loud vs. quiet speech, confirm switching the setting
back to bars restores the exact prior appearance.

## Open follow-up (out of scope for this design)

User separately flagged a minor, unrelated issue: punctuation words
spoken adjacent to digits (e.g. "двоеточие", "тире") sometimes get
inserted as literal extra punctuation/characters around numbers instead
of being normalized into the expected symbol only when directly between
digits. This is a number/punctuation-normalization logic issue (likely in
the Russian ITN/number-normalization path), unrelated to the HUD and will
be scoped as its own follow-up.
