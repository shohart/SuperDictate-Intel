# Recording HUD Timer + Outline-Fill Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in Settings toggle that makes the floating recording-indicator HUD show elapsed `MM:SS` duration plus a colored outline-fill/glow level visualization, instead of the current 8-bar style, once a recording passes 10 seconds — with a smooth crossfade at the switch point.

**Architecture:** All changes live in `swift/Sources/Parakey/main.swift` (the existing project convention — this is a single-file SwiftPM executable target; no new files). A new `RecordingHUDDisplayMode` enum is persisted via `ControlPanelSettings`/`UserDefaults`, following the exact pattern already used by `RecordingHUDSize`/`RecordingHUDBackgroundStyle`. `RecordingHUDView` (the `NSView` that draws the bubble) gains a `displayMode` property, a `recordingStartedAt: Date?` property, and a per-frame-computed `timerModeTransition` crossfade progress; its `draw(_:)` path grows a new branch that renders `MM:SS` text plus an outline stroke fill/glow, cross-dissolved with the existing bar rendering around the 10-second mark. The controller (`AppDelegate`-equivalent) records a wall-clock timestamp when recording starts and feeds it to the view exactly like it already feeds `level`/`phase`/`mode`.

**Tech Stack:** Swift, AppKit (`NSView`, `NSBezierPath`, `CoreGraphics`), SwiftPM (`swift build`), the project's custom `--self-test <group>` harness (no XCTest).

## Global Constraints

- All builds/tests run on the real Intel Mac (`shohart@192.168.1.246`), synced via `git archive HEAD | ssh ... tar -x` into a scratch directory — never `git clone`. Use `sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 ...` for non-interactive SSH.
- **Never execute the compiled `Parakey` binary except as `Parakey --self-test <exact-group-name>`** — never `--agent`, never with zero arguments, never `--self-test all` (directly implicated in a real production-LaunchAgent incident in an earlier project phase). After any self-test invocation, run the safety check:
  ```bash
  sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
  ```
  and confirm `/Applications/SuperDictate.app/Contents/MacOS/SuperDictate` (both the plain and `--agent` processes) are still the ones running — never a scratch-build path.
- Follow the existing code style in `main.swift`: `private` where possible, existing naming conventions (`recordingHUD...` prefix for HUD-related identifiers), Russian+English pairs (`t("Russian", "English")`) for every user-facing string in the settings UI.
- Self-tests for pure/testable logic go through the existing harness: add a `case "<name>":` branch in `ParakeetSelfTest.run` (near `swift/Sources/Parakey/main.swift:17376`) calling `runSuite("<name>", testXxx)`, and register the new `testXxx()` call inside `testAll()` (`main.swift:17435` onward) — this project had a real regression (caught in final review of a prior plan) from a new self-test group existing but never being added to `testAll()`; do not repeat it.
- No new files — this codebase's convention for `main.swift`-adjacent features is to extend the existing monolithic file, not split out new Swift files for small additions (unlike the larger overlap-segmentation feature, which did add new files for genuinely new subsystems). This feature is small and touches existing types directly, so it stays in `main.swift`.

---

### Task 1: `RecordingHUDDisplayMode` setting (enum + persisted storage)

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - New enum near `RecordingHUDBackgroundStyle` (`main.swift:589`)
  - New `UserDefaults` key near `main.swift:2802` (`keyRecordingHUDSize`)
  - New computed property in `ControlPanelSettings` near `main.swift:3183` (`recordingHUDSize`)
  - New `case` in `ParakeetSelfTest.run` near `main.swift:17376`, and a call inside `testAll()`

**Interfaces:**
- Produces: `enum RecordingHUDDisplayMode: String, CaseIterable { case levelBars, timerOutline }` with `.displayName: String`, default `.levelBars`. Produces `ControlPanelSettings.recordingHUDDisplayMode: RecordingHUDDisplayMode` (get/set, backed by `UserDefaults` key `"recording_hud_display_mode"`).

- [ ] **Step 1: Add the enum**

Add directly after the closing brace of `RecordingHUDBackgroundStyle` (after `main.swift:610`-ish — find the exact closing brace by reading the enum body first), matching the existing enum style:

```swift
enum RecordingHUDDisplayMode: String, CaseIterable {
    case levelBars
    case timerOutline

    var displayName: String {
        switch self {
        case .levelBars: return "Level bars"
        case .timerOutline: return "Timer"
        }
    }
}
```

- [ ] **Step 2: Add the `UserDefaults` key constant**

In `ControlPanelSettings`, alongside the other `keyRecordingHUD...` constants (`main.swift:2799-2802`):

```swift
private static let keyRecordingHUDDisplayMode = "recording_hud_display_mode"
```

- [ ] **Step 3: Add the computed property**

Directly after `recordingHUDSize` (`main.swift:3183-3195`), same shape:

```swift
var recordingHUDDisplayMode: RecordingHUDDisplayMode {
    get {
        guard let raw = defaults.string(forKey: Self.keyRecordingHUDDisplayMode),
              let mode = RecordingHUDDisplayMode(rawValue: raw) else {
            return .levelBars
        }
        return mode
    }
    set {
        defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDDisplayMode)
        defaults.synchronize()
    }
}
```

- [ ] **Step 4: Write a self-test for default value and round-trip persistence**

Add near the other small settings-focused self-tests (search for an existing simple settings self-test, e.g. `testDictationUsageStatistics`, to place this near similar tests). `ControlPanelSettings`/`Settings.shared` reads/writes `UserDefaults.standard` directly (no suite-name isolation exists elsewhere in this file for settings tests), so save/restore the real key's prior value around the test:

```swift
private static func testRecordingHUDDisplayMode() throws {
    let defaults = UserDefaults.standard
    let key = "recording_hud_display_mode"
    let previousRaw = defaults.string(forKey: key)
    defer {
        if let previousRaw {
            defaults.set(previousRaw, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    defaults.removeObject(forKey: key)
    let settings = Settings.shared
    guard settings.recordingHUDDisplayMode == .levelBars else {
        throw SelfTestFailure.failed("expected default .levelBars, got \(settings.recordingHUDDisplayMode)")
    }

    settings.recordingHUDDisplayMode = .timerOutline
    guard settings.recordingHUDDisplayMode == .timerOutline else {
        throw SelfTestFailure.failed("expected .timerOutline after set, got \(settings.recordingHUDDisplayMode)")
    }

    defaults.set("not-a-real-mode", forKey: key)
    guard settings.recordingHUDDisplayMode == .levelBars else {
        throw SelfTestFailure.failed("expected fallback to .levelBars for garbage stored value")
    }
}
```

(The project's self-test error type is `private enum SelfTestFailure: Error, CustomStringConvertible` at `main.swift:17296`, thrown as `SelfTestFailure.failed("message")` — used exactly as shown above.)

- [ ] **Step 5: Register the self-test**

In `ParakeetSelfTest.run` (`main.swift:17376` area), add:

```swift
case "recording-hud-display-mode":
    return runSuite("recording-hud-display-mode", testRecordingHUDDisplayMode)
```

And inside `testAll()` (`main.swift:17435` onward), add a line calling `try testRecordingHUDDisplayMode()` alongside the other `try test...()` calls.

- [ ] **Step 6: Sync to the Mac, build, and run the new self-test**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task1 && mkdir -p ~/scratch/sd-hud-task1 && tar -x -C ~/scratch/sd-hud-task1'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task1/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task1/swift && .build/debug/Parakey --self-test recording-hud-display-mode'
```

Expected: `PASS recording-hud-display-mode`.

- [ ] **Step 7: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add RecordingHUDDisplayMode setting (levelBars/timerOutline)"
```

---

### Task 2: `MM:SS` elapsed-time formatter (pure function)

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - New free function near the other small free-function helpers used by the HUD (e.g. near `smootherstep`/`smoothstep`, search for `private func smootherstep` to find that neighborhood — put the new formatter in the same file-private helper area, not inside `RecordingHUDView`, so it's independently testable without instantiating an `NSView`)
  - New self-test case + `testAll()` registration

**Interfaces:**
- Consumes: nothing (pure function of a `TimeInterval`)
- Produces: `func formatRecordingHUDElapsed(_ seconds: TimeInterval) -> String` — later tasks (Task 3) call this directly from `RecordingHUDView`'s draw code.

- [ ] **Step 1: Write the failing test**

```swift
private static func testFormatRecordingHUDElapsed() throws {
    let cases: [(TimeInterval, String)] = [
        (0, "00:00"),
        (9, "00:09"),
        (9.9, "00:09"),
        (10, "00:10"),
        (59, "00:59"),
        (60, "01:00"),
        (65, "01:05"),
        (599, "09:59"),
        (600, "10:00"),
        (3661, "61:01"),
    ]
    for (input, expected) in cases {
        let actual = formatRecordingHUDElapsed(input)
        guard actual == expected else {
            throw SelfTestFailure.failed("formatRecordingHUDElapsed(\(input)) = \(actual), expected \(expected)")
        }
    }
}
```

(Match the actual self-test failure type used elsewhere in the file, as in Task 1 Step 4.)

- [ ] **Step 2: Register it and run to verify it fails (function doesn't exist yet)**

Add `case "recording-hud-elapsed-format": return runSuite("recording-hud-elapsed-format", testFormatRecordingHUDElapsed)` in `ParakeetSelfTest.run`, and `try testFormatRecordingHUDElapsed()` in `testAll()`.

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task2 && mkdir -p ~/scratch/sd-hud-task2 && tar -x -C ~/scratch/sd-hud-task2'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task2/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
```

Expected: a compile error (`formatRecordingHUDElapsed` undefined) — confirms the test references something that doesn't exist yet.

- [ ] **Step 3: Implement the formatter**

```swift
private func formatRecordingHUDElapsed(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds))
    let minutes = totalSeconds / 60
    let secs = totalSeconds % 60
    return String(format: "%02d:%02d", minutes, secs)
}
```

- [ ] **Step 4: Build and run the self-test to verify it passes**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task2 && mkdir -p ~/scratch/sd-hud-task2 && tar -x -C ~/scratch/sd-hud-task2'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task2/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task2/swift && .build/debug/Parakey --self-test recording-hud-elapsed-format'
```

Expected: `PASS recording-hud-elapsed-format`.

- [ ] **Step 5: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add formatRecordingHUDElapsed MM:SS formatter"
```

---

### Task 3: Controller-side recording-start timestamp plumbing

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - New field declaration near `recordingHUDPanel`/`recordingHUDView` (`main.swift:10782-10783`)
  - `startRecordingLevelMeter()` (`main.swift:11940`)
  - `stopRecordingLevelMeter()` (`main.swift:11982`)
  - `showRecordingHUD(mode:level:)` (`main.swift:12036`) and `updateRecordingHUD(mode:level:)` (`main.swift:12061`)

**Interfaces:**
- Consumes: nothing new
- Produces: controller field `private var recordingHUDStartedAt: Date?`, kept in sync with the recording lifecycle, fed into `RecordingHUDView.recordingStartedAt` (defined in Task 4) at every point the view's `mode`/`level`/`phase` are already being set.

- [ ] **Step 1: Add the field**

Immediately after the `recordingHUDView` field declaration (`main.swift:10783` area):

```swift
private var recordingHUDStartedAt: Date?
```

- [ ] **Step 2: Set it when a recording session starts**

In `startRecordingLevelMeter()` (`main.swift:11940`), add alongside the other resets at the top of the function (near `recordingVisualLevel = 0`):

```swift
recordingHUDStartedAt = Date()
```

- [ ] **Step 3: Clear it when the level meter stops**

In `stopRecordingLevelMeter(resetImage:hideHUD:)` (`main.swift:11982`), add alongside `recordingVisualLevel = 0`:

```swift
recordingHUDStartedAt = nil
```

- [ ] **Step 4: Feed it to the view at both HUD update sites**

In `showRecordingHUD(mode:level:)` (`main.swift:12036-12047`), inside the `if let view = recordingHUDView { ... }` block, add:

```swift
view.recordingStartedAt = recordingHUDStartedAt
```

right after `view.phase = recordingHUDPhase`. Do the same in `updateRecordingHUD(mode:level:)` (`main.swift:12061-12069`).

- [ ] **Step 5: Build (compile-only check — `recordingStartedAt` doesn't exist on the view yet, expected to fail until Task 4)**

This task's view-side property (`RecordingHUDView.recordingStartedAt`) does not exist yet — that's added in Task 4. To keep this task independently compilable and testable, add a *temporary* stub property directly on `RecordingHUDView` right now as part of this task (Task 4 will replace the stub with the full implementation that also uses it for rendering):

```swift
var recordingStartedAt: Date?
```

Add this stub immediately after the existing `var level: Float = 0 { ... }` block (`main.swift:9326-9330`), with no `didSet` (Task 4 adds behavior).

- [ ] **Step 6: Build on the Mac**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task3 && mkdir -p ~/scratch/sd-hud-task3 && tar -x -C ~/scratch/sd-hud-task3'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task3/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
```

Expected: `Build complete!` with no errors.

- [ ] **Step 7: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Track recording start timestamp and feed it to the HUD view"
```

---

### Task 4: `RecordingHUDView` timer/outline rendering with 10s crossfade

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `RecordingHUDView` property section (`main.swift:9275-9338`) — replace the Task 3 stub `recordingStartedAt` with the full version, add `displayMode` and `timerModeTransition`
  - `drawFloatingWaveformOnly()` (`main.swift:9345-9460`) — branch the bar-drawing block on display mode + transition
  - New method `drawTimerOutlineFill(in:accent:fillFraction:)` near `drawTranscribingWave` (`main.swift:9462`)
  - `configureRecordingHUDView(_:)` (`main.swift:12203-12208`) — feed `settings.recordingHUDDisplayMode` into the view

**Interfaces:**
- Consumes: `formatRecordingHUDElapsed(_:)` (Task 2), `RecordingHUDDisplayMode` (Task 1), `smootherstep` (existing helper already used at `main.swift:9355` — reuse it, do not redefine).
- Produces: `RecordingHUDView.displayMode: RecordingHUDDisplayMode` (settable, default `.levelBars`), fully-implemented `RecordingHUDView.recordingStartedAt: Date?` (replacing the Task 3 stub, now driving `needsDisplay`).

- [ ] **Step 1: Replace the Task 3 stub and add the two new properties**

Replace:

```swift
var recordingStartedAt: Date?
```

with:

```swift
var recordingStartedAt: Date? {
    didSet { needsDisplay = true }
}

var displayMode: RecordingHUDDisplayMode = .levelBars {
    didSet {
        if oldValue != displayMode { needsDisplay = true }
    }
}
```

(Both go in the same spot right after `var level: Float = 0 { ... }`, `main.swift:9326-9330`.)

- [ ] **Step 2: Compute the crossfade transition and branch the content drawing**

In `drawFloatingWaveformOnly()`, the existing bar-drawing block starts at `main.swift:9415` (`let barCount = 8`) and runs to `main.swift:9459`, right after the early-returns for `.transcribing`/`.error` modes (`main.swift:9405-9413`). Replace that whole bar-drawing block (lines 9415-9459) with:

```swift
let elapsedForMode: TimeInterval = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
let timerActivationSeconds: TimeInterval = 10
let transitionDuration: TimeInterval = 0.5
let timerModeTransition: CGFloat
if displayMode == .timerOutline {
    let progress = (elapsedForMode - timerActivationSeconds) / transitionDuration
    timerModeTransition = smootherstep(0, 1, CGFloat(max(0, min(1, progress))))
} else {
    timerModeTransition = 0
}

if timerModeTransition < 1 {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setAlpha(1 - timerModeTransition)
    drawRecordingLevelBars(audio: audio, vividAccent: vividAccent, visualScale: visualScale)
    NSGraphicsContext.restoreGraphicsState()
}
if timerModeTransition > 0 {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.cgContext.setAlpha(timerModeTransition)
    drawTimerOutlineFill(in: capsuleRect, accent: vividAccent, level: CGFloat(max(0, min(1, level))), elapsed: elapsedForMode)
    NSGraphicsContext.restoreGraphicsState()
}
```

- [ ] **Step 3: Extract the old bar-drawing block into its own method**

Add this as a new private method on `RecordingHUDView` (place it directly before `drawTranscribingWave`, `main.swift:9462`), using the exact body that used to be inline (the loop previously at old lines 9415-9459), now parameterized:

```swift
private func drawRecordingLevelBars(audio: CGFloat, vividAccent: NSColor, visualScale: CGFloat) {
    let barCount = 8
    let barWidth: CGFloat = 2.05 * visualScale
    let barGap: CGFloat = 2.55 * visualScale
    let minHeight: CGFloat = 3.0 * visualScale
    let maxHeight = min(bounds.height * 0.58, 13.2 * visualScale)
    let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    let startX = bounds.midX - (totalWidth / 2)
    let centerY = bounds.midY
    let centerIndex = CGFloat(barCount - 1) / 2
    let centerDenominator = max(centerIndex, 1)

    for index in 0..<barCount {
        let i = CGFloat(index)
        let normalized = (i - centerIndex) / centerDenominator
        let envelope = pow(max(0, cos(normalized * .pi / 2)), 0.62)
        let traveling = (sin((phase * 1.02) - (normalized * 2.85)) + 1) / 2
        let counter = (sin((phase * 1.57) + (i * 1.17)) + 1) / 2
        let slowVariance = (sin((phase * 0.23) + (i * 2.11)) + 1) / 2
        let perBarGain = 0.72 + (0.28 * slowVariance)
        let idleMotion = 0.14 + (0.075 * traveling) + (0.055 * counter * envelope)
        let centerBias = 0.22 + (0.78 * envelope)
        let voiceMotion = audio
            * centerBias
            * (0.18 + (0.42 * traveling) + (0.14 * counter))
            * perBarGain
        let activity = min(0.88, idleMotion + voiceMotion)
        let height = minHeight + ((maxHeight - minHeight) * activity)
        let x = startX + CGFloat(index) * (barWidth + barGap)
        let rect = NSRect(x: x,
                          y: centerY - (height / 2),
                          width: barWidth,
                          height: height)
        let path = NSBezierPath(roundedRect: rect,
                                xRadius: barWidth / 2,
                                yRadius: barWidth / 2)

        let glowRect = rect.insetBy(dx: -1.1 * visualScale,
                                    dy: -1.1 * visualScale)
        vividAccent.withAlphaComponent(0.07 + (0.10 * activity)).setFill()
        NSBezierPath(roundedRect: glowRect,
                     xRadius: glowRect.width / 2,
                     yRadius: glowRect.width / 2).fill()
        vividAccent.withAlphaComponent(0.74 + (0.26 * activity)).setFill()
        path.fill()
    }
}
```

Note: the original block used `bounds.midX`/`bounds.midY` for bar centering (not `capsuleRect`) — preserve that exactly, since `capsuleRect` is already clipped to by the caller (`capsule.addClip()` at `main.swift:9401`) and bar positions were always relative to the view's own `bounds`, not the capsule rect. Keep this identical to avoid any visual regression in the unchanged `.levelBars` mode.

- [ ] **Step 4: Implement `drawTimerOutlineFill`**

Add directly after `drawRecordingLevelBars`:

```swift
private func drawTimerOutlineFill(in capsuleRect: NSRect, accent: NSColor, level: CGFloat, elapsed: TimeInterval) {
    // Outline stroke, filled fraction of the perimeter grows from the
    // bottom center point symmetrically up both sides with `level`.
    let capsule = NSBezierPath(roundedRect: capsuleRect,
                               xRadius: capsuleRect.height / 2,
                               yRadius: capsuleRect.height / 2)
    let strokeWidth: CGFloat = 2.4 * visualScale
    let unfilledColor = accent.withAlphaComponent(0.14)
    unfilledColor.setStroke()
    capsule.lineWidth = strokeWidth
    capsule.stroke()

    if level > 0.001 {
        let filledPath = outlineFillPath(in: capsuleRect, fraction: level)
        let glowAlpha = 0.18 + (0.55 * level)
        let glowWidth = strokeWidth + (3.0 * visualScale * level)
        accent.withAlphaComponent(glowAlpha).setStroke()
        filledPath.lineWidth = glowWidth
        filledPath.lineCapStyle = .round
        filledPath.stroke()

        accent.withAlphaComponent(0.85 + (0.15 * level)).setStroke()
        filledPath.lineWidth = strokeWidth
        filledPath.lineCapStyle = .round
        filledPath.stroke()
    }

    let text = formatRecordingHUDElapsed(elapsed)
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12 * visualScale, weight: .semibold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraph,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()
    let textRect = NSRect(x: capsuleRect.midX - (textSize.width / 2),
                          y: capsuleRect.midY - (textSize.height / 2),
                          width: textSize.width,
                          height: textSize.height)
    attributed.draw(in: textRect)
}

/// Builds the portion of the capsule's outline that should be lit, growing
/// from the bottom center point symmetrically up both the left and right
/// sides as `fraction` (0...1) increases, tracing the same rounded-rect
/// path geometry as the full capsule outline.
private func outlineFillPath(in capsuleRect: NSRect, fraction: CGFloat) -> NSBezierPath {
    let clamped = max(0, min(1, fraction))
    let fullPath = NSBezierPath(roundedRect: capsuleRect,
                                xRadius: capsuleRect.height / 2,
                                yRadius: capsuleRect.height / 2)
    guard clamped < 1 else { return fullPath }

    // Approximate perimeter traversal by sampling the full path's element
    // list is not directly available via NSBezierPath, so build the lit
    // portion from two mirrored arcs starting at the bottom center point
    // and sweeping up each side by `clamped * halfPerimeter`.
    let radius = capsuleRect.height / 2
    let bottomCenter = NSPoint(x: capsuleRect.midX, y: capsuleRect.maxY)
    let straightLength = max(0, capsuleRect.width - capsuleRect.height)
    let halfStraight = straightLength / 2
    let halfPerimeter = halfStraight + (.pi * radius)
    let litLength = clamped * halfPerimeter

    let path = NSBezierPath()
    path.lineJoinStyle = .round

    func appendSide(direction: CGFloat) {
        // direction: -1 for left side, +1 for right side.
        var remaining = litLength
        path.move(to: bottomCenter)
        let straightEnd = NSPoint(x: bottomCenter.x + (direction * min(remaining, halfStraight)),
                                  y: bottomCenter.y)
        path.line(to: straightEnd)
        remaining -= min(remaining, halfStraight)
        guard remaining > 0 else { return }
        let arcFraction = min(1, remaining / (.pi * radius))
        let center = NSPoint(x: capsuleRect.midX + (direction * halfStraight), y: capsuleRect.midY)
        let startAngle: CGFloat = direction > 0 ? -90 : 270
        let sweep = direction > 0 ? -180 * arcFraction : 180 * arcFraction
        path.appendArc(withCenter: center,
                       radius: radius,
                       startAngle: startAngle,
                       endAngle: startAngle + sweep,
                       clockwise: direction > 0)
    }

    appendSide(direction: -1)
    appendSide(direction: 1)
    return path
}
```

- [ ] **Step 5: Wire the display mode into `configureRecordingHUDView`**

In `configureRecordingHUDView(_:)` (`main.swift:12203-12208`), add:

```swift
view.displayMode = settings.recordingHUDDisplayMode
```

- [ ] **Step 6: Build on the Mac**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task4 && mkdir -p ~/scratch/sd-hud-task4 && tar -x -C ~/scratch/sd-hud-task4'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task4/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
```

Expected: `Build complete!` with no errors. If `outlineFillPath`'s use of `NSBezierPath.appendArc(withCenter:radius:startAngle:endAngle:clockwise:)` angle-sign conventions produce a visually wrong sweep direction (AppKit's `NSBezierPath` arc angles are counter-clockwise-positive, y-flipped view — this view has `isFlipped = true`, `main.swift:9338`, which affects angle interpretation), that will only be catchable visually in Task 6's manual verification, not by this build step — flag it explicitly in the Task 6 verification notes if the fill grows from the wrong point or the wrong direction, and fix the angle signs then.

- [ ] **Step 7: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Implement timer + outline-fill/glow HUD rendering with 10s crossfade"
```

---

### Task 5: Settings UI — popup row, draft wiring, save

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `ControlPanelSettingsDraft` (`main.swift:24544-24573`)
  - `makeSettingsContentView()` popup row list (`main.swift:24869-24897` area)
  - New `localizedDisplayModeName(_:)` helper near `localizedHUDSizeName` (`main.swift:26110-26117`)
  - New `@objc selectRecordingHUDDisplayMode(_:)` near `selectRecordingHUDSize` (`main.swift:26391-26398`)
  - `saveSettingsClicked(_:)` (`main.swift:26405-26424`)

**Interfaces:**
- Consumes: `RecordingHUDDisplayMode` (Task 1), `ControlPanelSettings.recordingHUDDisplayMode` (Task 1), the existing `popupRow(title:detail:selectedValue:options:action:toolTip:)` helper (used unmodified).
- Produces: a working settings toggle end to end (UI → draft → save → `UserDefaults` → next HUD render picks it up via `configureRecordingHUDView`, Task 4 Step 5).

- [ ] **Step 1: Add the draft field**

In `ControlPanelSettingsDraft` (`main.swift:24544-24573`), add the field:

```swift
var hudDisplayMode: RecordingHUDDisplayMode
```

and initialize it in `init(settings:)`:

```swift
hudDisplayMode = settings.recordingHUDDisplayMode
```

- [ ] **Step 2: Add the localized name helper**

Directly after `localizedHUDSizeName` (`main.swift:26110-26117`):

```swift
private func localizedDisplayModeName(_ mode: RecordingHUDDisplayMode) -> String {
    guard language == .russian else { return mode.displayName }
    switch mode {
    case .levelBars: return "Полоски уровня"
    case .timerOutline: return "Таймер"
    }
}
```

- [ ] **Step 3: Add the popup row**

In `makeSettingsContentView()`, directly after the "Recording color" popup row (`main.swift:24869-24877`, ends right before the "Transcribing color" row):

```swift
root.addArrangedSubview(popupRow(
    title: t("Индикатор записи", "Recording indicator"),
    detail: t("Полоски уровня громкости или таймер длительности после 10 секунд записи.",
              "Volume level bars, or an elapsed-time timer after 10 seconds of recording."),
    selectedValue: draft.hudDisplayMode.rawValue,
    options: RecordingHUDDisplayMode.allCases.map { (localizedDisplayModeName($0), $0.rawValue) },
    action: #selector(selectRecordingHUDDisplayMode(_:)),
    toolTip: t("Переключить вид плавающего индикатора во время записи.",
               "Switch how the floating recording indicator looks while recording.")
))
```

- [ ] **Step 4: Add the action selector**

Directly after `selectRecordingHUDSize` (`main.swift:26391-26398`):

```swift
@objc private func selectRecordingHUDDisplayMode(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let mode = RecordingHUDDisplayMode(rawValue: raw) else { return }
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    draft.hudDisplayMode = mode
    settingsDraft = draft
    refreshSettingsWindow()
}
```

- [ ] **Step 5: Apply on save**

In `saveSettingsClicked(_:)` (`main.swift:26405-26424`), add alongside `settings.recordingHUDSize = draft.hudSize`:

```swift
settings.recordingHUDDisplayMode = draft.hudDisplayMode
```

- [ ] **Step 6: Build on the Mac**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task5 && mkdir -p ~/scratch/sd-hud-task5 && tar -x -C ~/scratch/sd-hud-task5'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task5/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
```

Expected: `Build complete!` with no errors.

- [ ] **Step 7: Run the full targeted self-test set from Tasks 1-2**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task5/swift && for g in recording-hud-display-mode recording-hud-elapsed-format; do echo "=== $g ==="; .build/debug/Parakey --self-test $g; echo "EXIT=$?"; done'
```

Expected: both `PASS`, `EXIT=0`.

- [ ] **Step 8: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Wire recording indicator display mode into the Settings panel"
```

---

### Task 6: Real-hardware manual verification and final review

**Files:** none (verification only; fix-forward in `main.swift` if verification finds a defect, following the same file/section references as Tasks 1-5)

**Interfaces:** none new

- [ ] **Step 1: Build a debug binary and run it manually (NOT via `--self-test`) in a disposable, non-production way**

This task requires actually watching the HUD animate, which the `--self-test` harness cannot do (it's headless). Per this project's LaunchAgent-safety rule, the compiled binary must never be run outside `--self-test` except as the actual signed `/Applications/SuperDictate.app` — so verification happens by installing this branch's build as a temporary local run the user drives interactively, not by launching the scratch binary directly from an agent. Concretely:

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-hud-task6 && mkdir -p ~/scratch/sd-hud-task6 && tar -x -C ~/scratch/sd-hud-task6'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-hud-task6/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
```

Then report to the user (in the final task summary, this is not something an agent can self-verify) exactly which manual steps to run and what to look for — do not attempt to launch the HUD interactively from an automated agent. Write the verification checklist into `PROGRESS.md`/the task report:

1. Open Settings (gear icon), find "Recording indicator" / "Индикатор записи", switch it to "Timer" / "Таймер", save.
2. Start a short dictation (under 10s), confirm the bubble still shows the plain level bars the whole time — no visual change from before this feature.
3. Start a dictation and keep talking past 10 seconds. Confirm: at 10s, a smooth crossfade begins (bars fading out, outline+timer fading in) — not a hard cut. Confirm the `MM:SS` text is centered, minutes always 2 digits (`00:10`, `01:05`, ...), and updates every second.
4. While past 10s, speak loudly vs. quietly and confirm the outline fill grows/shrinks from the bottom of the capsule up both sides, and the glow on the filled portion visibly brightens with louder speech.
5. Change "Recording color" in Settings, confirm the outline/glow color follows it (reusing the same setting, not a separate one).
6. Switch "Recording indicator" back to "Level bars" / "Полоски уровня", confirm the bubble looks exactly as it did before this feature (regression check).
7. Confirm `.transcribing` (spinner-like wave after releasing the hotkey) and `.error` HUD states look unchanged in both display-mode settings.

- [ ] **Step 2: Fix forward if verification finds a defect**

If the outline fill grows from the wrong point/direction (flagged as a known risk in Task 4 Step 6, due to `NSBezierPath` arc angle conventions under `isFlipped = true`), adjust the `startAngle`/`sweep` signs in `outlineFillPath` (Task 4) and rebuild/re-verify. If the crossfade timing feels off, adjust `transitionDuration` in Task 4 Step 2 (currently `0.5`) — do not change `timerActivationSeconds` (10s) without the user's approval, since that value came from an explicit user decision.

- [ ] **Step 3: Safety check**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
```

Confirm the production app/agent are still the real `/Applications/SuperDictate.app` processes, untouched by this task's scratch build.

- [ ] **Step 4: Final commit if fixes were made**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "Fix HUD timer/outline rendering issues found in manual verification"
```

(Skip this step if Step 1 found no issues — nothing to commit.)
