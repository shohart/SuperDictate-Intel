# Windows-Port Feature Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port a curated set of features from the sibling Windows app (`metawka/SuperDictate-win`) into this macOS app: a richer, per-word-configurable filler-word remover; auto-stop-on-silence; Settings-window rows for "Launch at Login" and "Mute system audio while recording" (both already exist as menu-only settings); a discoverability line for the existing corrections manager; and a new adaptive "Contrast" HUD accent color that fixes a real white-on-light-background invisibility bug.

**Architecture:** All changes live in `swift/Sources/Parakey/main.swift` (this project's existing single-file convention). New persisted settings follow the exact `ControlPanelSettings` get/set-over-`UserDefaults` pattern already used throughout the file. New Settings-window rows follow the existing `popupRow`/`NSSwitch`-row templates already used by `normalizeNumbersRow`/`enterDelayRow`/the HUD color rows. The app has two OS processes sharing one binary and one `UserDefaults` domain: the menu-bar `--agent` process (`ParakeyApp`) and the separate Settings-window process (`SuperDictateControlPanelApp`) — every feature here that needs to work from the Settings window either (a) writes a plain persisted setting the agent process reads fresh on its own (the existing, working pattern for every setting today), or (b) calls a system API directly (`SMAppService`) that isn't tied to a specific process. Nothing in this plan requires new cross-process IPC — see the design doc's §5 for why the corrections feature was scoped down specifically to avoid needing that.

**Tech Stack:** Swift, AppKit (`NSSwitch`, `NSPopUpButton`, `NSStackView`), `SMAppService` (login items), `UserDefaults`, this project's custom `--self-test <group>` harness (no XCTest).

## Global Constraints

- All builds/tests run on the real Intel Mac (`shohart@192.168.1.246`), synced via `git archive HEAD | ssh ... tar -x` into a fresh scratch directory — never `git clone`. Use `sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 '<command>'` for non-interactive SSH.
- **Never execute the compiled `Parakey` binary except as `Parakey --self-test <exact-group-name>`** — never `--agent`, never with zero arguments, never `--self-test all`. After any self-test invocation, run the safety check:
  ```bash
  sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
  ```
  and confirm only `/Applications/SuperDictate.app/Contents/MacOS/SuperDictate` (plain and `--agent`) are running — never a scratch-build path.
- Follow existing code style in `main.swift`: `private` where possible, existing naming conventions, Russian+English pairs (`t("Russian", "English")`) for every new user-facing string in the Settings window.
- Any new self-test group must be registered in **both** `ParakeetSelfTest.run`'s switch (`main.swift:17376`-ish area — search for `case "recording-hud-display-mode":` as a recent example) **and** called inside `testAll()` — a prior project phase shipped a real regression from skipping the second registration point. Do not repeat it.
- The self-test error type is `SelfTestFailure.failed("message")` (`main.swift:17296`), used via a project-standard `expect(_:equals:_:)` helper (`main.swift:24742`-ish — grep `private static func expect<T: Equatable>` to confirm the exact current line before use, since earlier line numbers shift as the file grows).
- No new files — this project's convention for features of this size is to extend the existing monolithic `main.swift`, matching how the recording-HUD work earlier in this project was done.
- `ParakeyApp` (agent process, menu bar) and `SuperDictateControlPanelApp` (Settings window process) are two different top-level types in the same file. Confirm which one you're editing before adding code — grep the enclosing `private final class ParakeyApp` / `private final class SuperDictateControlPanelApp` boundaries if unsure.

---

### Task 1: Filler-word preset table and persisted settings

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `FillerWordRemover` enum (currently starts `main.swift:6486`) — add the preset table
  - `ControlPanelSettings` — add three new persisted properties near `keyRemoveFillerWords`/`removeFillerWords` (`main.swift:2850`/`3510`)
  - New self-test group + `testAll()` registration

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `struct FillerWordPreset { let key: String; let displayText: String; let pattern: String; let defaultEnabled: Bool }`
  - `FillerWordRemover.presets: [FillerWordPreset]` (static let)
  - `FillerWordRemover.defaultEnabledPresetKeys: Set<String>` (static let, computed once from `presets.filter(\.defaultEnabled).map(\.key)`)
  - `ControlPanelSettings.enabledFillerPresetKeys: Set<String>` (get/set)
  - `ControlPanelSettings.customFillerWords: [String]` (get/set)
  - These are consumed by Task 2's updated `FillerWordRemover.apply(to:...)`.

- [ ] **Step 1: Add the preset table**

Directly above the existing `fillerPatterns` line inside `FillerWordRemover` (`main.swift:6499`), add:

```swift
struct FillerWordPreset {
    let key: String
    let displayText: String
    let pattern: String
    let defaultEnabled: Bool
}

/// Mirrors the Windows port's `PRESET_FILLERS`: unambiguous hesitation
/// sounds default on, real words/phrases that only sometimes serve as
/// fillers default off (never delete real words without consent).
static let presets: [FillerWordPreset] = [
    // English hesitations (existing patterns, now data-driven)
    FillerWordPreset(key: "en_um", displayText: "um", pattern: "um+", defaultEnabled: true),
    FillerWordPreset(key: "en_uh", displayText: "uh", pattern: "uh+", defaultEnabled: true),
    FillerWordPreset(key: "en_ah", displayText: "ah", pattern: "ah+", defaultEnabled: true),
    FillerWordPreset(key: "en_er", displayText: "er", pattern: "er", defaultEnabled: true),
    FillerWordPreset(key: "en_erm", displayText: "erm", pattern: "erm", defaultEnabled: true),
    FillerWordPreset(key: "en_hm", displayText: "hm", pattern: "hm+", defaultEnabled: true),
    // Russian hesitations
    FillerWordPreset(key: "ru_e", displayText: "э", pattern: "э+", defaultEnabled: true),
    FillerWordPreset(key: "ru_em", displayText: "эм", pattern: "эм+", defaultEnabled: true),
    FillerWordPreset(key: "ru_m", displayText: "м", pattern: "м+", defaultEnabled: true),
    FillerWordPreset(key: "ru_am", displayText: "ам", pattern: "ам+", defaultEnabled: true),
    FillerWordPreset(key: "ru_aa", displayText: "аа", pattern: "аа+", defaultEnabled: true),
    // Russian verbal-tic phrases (default OFF -- real words/phrases)
    FillerWordPreset(key: "ru_kak_by", displayText: "как бы", pattern: #"как\s+бы"#, defaultEnabled: false),
    FillerWordPreset(key: "ru_tipa", displayText: "типа", pattern: "типа", defaultEnabled: false),
    FillerWordPreset(key: "ru_koroche", displayText: "короче", pattern: "короче", defaultEnabled: false),
    FillerWordPreset(key: "ru_eto_samoe", displayText: "это самое", pattern: #"это\s+самое"#, defaultEnabled: false),
    FillerWordPreset(key: "ru_tak_skazat", displayText: "так сказать", pattern: #"так\s+сказать"#, defaultEnabled: false),
    FillerWordPreset(key: "ru_v_obshchem", displayText: "в общем", pattern: #"в\s+общем"#, defaultEnabled: false),
    FillerWordPreset(key: "ru_sobstvenno", displayText: "собственно", pattern: "собственно", defaultEnabled: false),
    FillerWordPreset(key: "ru_dopustim", displayText: "допустим", pattern: "допустим", defaultEnabled: false),
    FillerWordPreset(key: "ru_slushay", displayText: "слушай", pattern: "слушай", defaultEnabled: false),
    FillerWordPreset(key: "ru_ponimaesh", displayText: "понимаешь", pattern: "понимаешь", defaultEnabled: false),
    FillerWordPreset(key: "ru_znaesh", displayText: "знаешь", pattern: "знаешь", defaultEnabled: false),
    // English verbal-tic phrases (default OFF)
    FillerWordPreset(key: "en_like", displayText: "like", pattern: "like", defaultEnabled: false),
    FillerWordPreset(key: "en_you_know", displayText: "you know", pattern: #"you\s+know"#, defaultEnabled: false),
    FillerWordPreset(key: "en_i_mean", displayText: "i mean", pattern: #"i\s+mean"#, defaultEnabled: false),
    FillerWordPreset(key: "en_actually", displayText: "actually", pattern: "actually", defaultEnabled: false),
    FillerWordPreset(key: "en_basically", displayText: "basically", pattern: "basically", defaultEnabled: false),
]

static let defaultEnabledPresetKeys: Set<String> = Set(presets.filter(\.defaultEnabled).map(\.key))
```

Leave the old `private static let fillerPatterns = [...]` line in place for now — Task 2 removes it when it rewrites `apply(to:)`. This step is additive only, so the file still compiles with the old and new tables briefly coexisting.

- [ ] **Step 2: Add the two new `ControlPanelSettings` properties**

Directly after `removeFillerWords` (`main.swift:3510-3513`):

```swift
private static let keyEnabledFillerPresetKeys = "enabled_filler_preset_keys"
private static let keyCustomFillerWords = "custom_filler_words"

var enabledFillerPresetKeys: Set<String> {
    get {
        guard let stored = defaults.array(forKey: Self.keyEnabledFillerPresetKeys) as? [String] else {
            return FillerWordRemover.defaultEnabledPresetKeys
        }
        return Set(stored)
    }
    set { defaults.set(Array(newValue), forKey: Self.keyEnabledFillerPresetKeys) }
}

var customFillerWords: [String] {
    get { (defaults.array(forKey: Self.keyCustomFillerWords) as? [String]) ?? [] }
    set { defaults.set(newValue, forKey: Self.keyCustomFillerWords) }
}
```

(Add the two `private static let key...` constants next to the other `keyXxx` constants near `keyRemoveFillerWords` at `main.swift:2850`, not inline in the property block — match the file's existing layout convention of grouping all key constants together, separate from the properties.)

- [ ] **Step 3: Self-test for preset resolution and defaults**

Add near other small settings-focused self-tests (search for `testRecordingHUDDisplayMode` from a recent similar addition, place this nearby):

```swift
private static func testFillerWordPresetDefaults() throws {
    // Every preset's default-enabled status must match its curated intent:
    // hesitation sounds on, real-word phrases off.
    let alwaysOnKeys: Set<String> = ["en_um", "en_uh", "en_ah", "en_er", "en_erm", "en_hm",
                                      "ru_e", "ru_em", "ru_m", "ru_am", "ru_aa"]
    let alwaysOffKeys: Set<String> = ["ru_kak_by", "ru_tipa", "ru_koroche", "en_like", "en_you_know"]
    for preset in FillerWordRemover.presets where alwaysOnKeys.contains(preset.key) {
        guard preset.defaultEnabled else {
            throw SelfTestFailure.failed("expected \(preset.key) to default on")
        }
    }
    for preset in FillerWordRemover.presets where alwaysOffKeys.contains(preset.key) {
        guard !preset.defaultEnabled else {
            throw SelfTestFailure.failed("expected \(preset.key) to default off")
        }
    }

    // No duplicate keys -- a duplicate would silently shadow one preset's
    // toggle state with another's in the enabled-set.
    let keys = FillerWordRemover.presets.map(\.key)
    guard Set(keys).count == keys.count else {
        throw SelfTestFailure.failed("duplicate FillerWordPreset keys found")
    }
}

private static func testEnabledFillerPresetKeysSetting() throws {
    let defaults = UserDefaults.standard
    let key = "enabled_filler_preset_keys"
    let previous = defaults.array(forKey: key)
    defer {
        if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    defaults.removeObject(forKey: key)
    let settings = Settings.shared
    guard settings.enabledFillerPresetKeys == FillerWordRemover.defaultEnabledPresetKeys else {
        throw SelfTestFailure.failed("expected default enabled set when nothing stored yet")
    }

    settings.enabledFillerPresetKeys = ["en_um"]
    guard settings.enabledFillerPresetKeys == ["en_um"] else {
        throw SelfTestFailure.failed("expected stored set to override the default once written")
    }
}
```

- [ ] **Step 4: Register both self-tests**

In `ParakeetSelfTest.run`'s switch, add:

```swift
case "filler-word-preset-defaults":
    return runSuite("filler-word-preset-defaults", testFillerWordPresetDefaults)
case "enabled-filler-preset-keys-setting":
    return runSuite("enabled-filler-preset-keys-setting", testEnabledFillerPresetKeysSetting)
```

And inside `testAll()`, add both `try testFillerWordPresetDefaults()` and `try testEnabledFillerPresetKeysSetting()`.

- [ ] **Step 5: Sync, build, run the two new self-tests**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task1 && mkdir -p ~/scratch/sd-wp-task1 && tar -x -C ~/scratch/sd-wp-task1'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task1/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task1/swift && for g in filler-word-preset-defaults enabled-filler-preset-keys-setting; do echo "=== $g ==="; .build/debug/Parakey --self-test $g; done'
```

Expected: both `PASS`.

- [ ] **Step 6: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add filler-word preset table and per-preset/custom-word settings"
```

---

### Task 2: `FillerWordRemover.apply` takes presets/custom words; wire into `processedDictationText`

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `FillerWordRemover.apply(to:)` (`main.swift:6501`) and its use of `fillerPatterns`
  - `processedDictationText` (`main.swift:6674`)
  - The 3 production call sites of `processedDictationText` (`main.swift:11583`, `13138`, `13376`)

**Interfaces:**
- Consumes: `FillerWordRemover.presets`, `defaultEnabledPresetKeys` (Task 1), `ControlPanelSettings.enabledFillerPresetKeys`/`customFillerWords` (Task 1).
- Produces: `FillerWordRemover.apply(to:enabledPresetKeys:customWords:) -> (text: String, removedCount: Int)`, new `processedDictationText` parameters `enabledFillerPresetKeys: Set<String> = FillerWordRemover.defaultEnabledPresetKeys` and `customFillerWords: [String] = []` (defaulted so the many existing self-tests calling `processedDictationText` without these two new arguments keep compiling unchanged — only the 3 production call sites pass live values).

- [ ] **Step 1: Update `apply(to:)`'s signature and pattern-building**

Replace:

```swift
private static let fillerPatterns = ["um+", "uh+", "ah+", "er", "erm", "hm+"]

static func apply(to text: String) -> (text: String, removedCount: Int) {
    guard !text.isEmpty else { return (text, 0) }

    let alternation = fillerPatterns.joined(separator: "|")
```

with:

```swift
static func apply(to text: String,
                   enabledPresetKeys: Set<String> = defaultEnabledPresetKeys,
                   customWords: [String] = []) -> (text: String, removedCount: Int) {
    guard !text.isEmpty else { return (text, 0) }

    let presetPatterns = presets
        .filter { enabledPresetKeys.contains($0.key) }
        .map { (source: $0.displayText, pattern: $0.pattern) }
    let customPatterns = customWords.map { word -> (source: String, pattern: String) in
        let escapedTokens = word.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        return (source: word, pattern: escapedTokens.joined(separator: #"\s+"#))
    }
    // Longest source text first, so a multi-word phrase is tried before any
    // shorter pattern that could otherwise partially match inside it.
    let orderedPatterns = (presetPatterns + customPatterns)
        .sorted { $0.source.count > $1.source.count }
        .map(\.pattern)

    guard !orderedPatterns.isEmpty else { return (text, 0) }
    let alternation = orderedPatterns.joined(separator: "|")
```

(Delete the old `private static let fillerPatterns = [...]` line entirely — it's superseded by `presets` from Task 1.) Everything below the `let alternation = ...` line (the regex construction, matching, cleanup passes, capitalization repair) stays exactly as-is — do not touch it.

- [ ] **Step 2: Update `processedDictationText`'s signature and its call to `apply`**

Change the signature (`main.swift:6674-6678`):

```swift
private func processedDictationText(rawTranscript: String,
                                    corrections: [TranscriptCorrection],
                                    removeFillerWords: Bool,
                                    normalizeNumbersToDigits: Bool = false,
                                    language: DictationLanguage = .auto,
                                    enabledFillerPresetKeys: Set<String> = FillerWordRemover.defaultEnabledPresetKeys,
                                    customFillerWords: [String] = []) -> DictationTextProcessingResult {
```

and its call to `FillerWordRemover.apply` (`main.swift:6698`):

```swift
let stripped = FillerWordRemover.apply(to: corrected.text,
                                       enabledPresetKeys: enabledFillerPresetKeys,
                                       customWords: customFillerWords)
```

- [ ] **Step 3: Update the 3 production call sites**

At `main.swift:11583`, `13138`, and `13376`, each existing `processedDictationText(...)` call already passes `removeFillerWords: settings.removeFillerWords` — add two more arguments to each call:

```swift
enabledFillerPresetKeys: settings.enabledFillerPresetKeys,
customFillerWords: settings.customFillerWords
```

(Match each call site's existing multi-line argument-list formatting style — read each site first before editing, since the exact indentation/line-break pattern may differ slightly between the 3.)

- [ ] **Step 4: New self-test for `apply(to:...)` with presets and custom words**

```swift
private static func testFillerWordRemoverPresetsAndCustomWords() throws {
    // Only enabled presets are removed.
    let onlyUm = FillerWordRemover.apply(to: "Um, hello, ah, world.", enabledPresetKeys: ["en_um"], customWords: [])
    try expect(onlyUm.text, equals: "hello, ah, world.", "only the enabled preset (um) should be removed, ah stays")

    // Phrase preset, default-off key, explicitly enabled.
    let phrase = FillerWordRemover.apply(to: "Это как бы сложно.", enabledPresetKeys: ["ru_kak_by"], customWords: [])
    try expect(phrase.text, equals: "Это сложно.", "multi-word Russian phrase preset should be removed when enabled")

    // Custom word, case-insensitive, word-boundary safe.
    let custom = FillerWordRemover.apply(to: "So anyway I think so.", enabledPresetKeys: [], customWords: ["anyway"])
    try expect(custom.text, equals: "So I think so.", "custom single word should be removed when listed")

    // Custom multi-word phrase, tolerant of ASR spacing via \\s+.
    let customPhrase = FillerWordRemover.apply(to: "This is sort  of  fine.", enabledPresetKeys: [], customWords: ["sort of"])
    try expect(customPhrase.text, equals: "This is fine.", "custom multi-word phrase should tolerate extra whitespace")

    // No presets, no custom words -> no-op.
    let noop = FillerWordRemover.apply(to: "Nothing changes here.", enabledPresetKeys: [], customWords: [])
    try expect(noop.text, equals: "Nothing changes here.", "empty preset/custom sets should leave text untouched")

    // Longest-first ordering: a custom word that's a substring of a longer
    // enabled phrase must not corrupt the phrase.
    let ordering = FillerWordRemover.apply(to: "Это самое сложно.", enabledPresetKeys: ["ru_eto_samoe"], customWords: ["это"])
    try expect(ordering.text, equals: "сложно.", "the longer phrase preset must be tried before the shorter custom word it contains")
}
```

- [ ] **Step 5: Register the new self-test**

Add `case "filler-word-presets-custom-words": return runSuite("filler-word-presets-custom-words", testFillerWordRemoverPresetsAndCustomWords")` to `ParakeetSelfTest.run`, and `try testFillerWordRemoverPresetsAndCustomWords()` to `testAll()`.

- [ ] **Step 6: Build and run — new test plus the full existing filler-word regression suite**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task2 && mkdir -p ~/scratch/sd-wp-task2 && tar -x -C ~/scratch/sd-wp-task2'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task2/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task2/swift && for g in filler-word-presets-custom-words fillers russian-number-itn-pipeline; do echo "=== $g ==="; .build/debug/Parakey --self-test $g; done'
```

Expected: all `PASS`. The `fillers` group (the pre-existing suite exercising all the old English-only fixed-list cases from before this change — grep `testFillerWordRemoval` for its exact name if `fillers` isn't the exact self-test-group string) must still pass unmodified, since Task 1/2 default `enabledPresetKeys`/`customWords` to values that preserve the exact old English-hesitation behavior when nothing has been customized yet.

- [ ] **Step 7: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Wire filler-word presets and custom words into the transcription pipeline"
```

---

### Task 3: Filler-word Settings-window UI; remove the old menu toggle

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `ControlPanelSettingsDraft` (`main.swift:24990-25021`)
  - `makeSettingsContentView()` (`main.swift:25275`)
  - New row-building method(s), new action selectors, `saveSettingsClicked` (`main.swift:26880`)
  - `ParakeyApp`'s filler menu item (`main.swift:15286-15291`) and its action `toggleRemoveFillerWords` (`main.swift:16842-16845`) — both removed

**Interfaces:**
- Consumes: `ControlPanelSettings.removeFillerWords` (existing), `enabledFillerPresetKeys`/`customFillerWords` (Task 1), `FillerWordRemover.presets` (Task 1).
- Produces: a working end-to-end Settings-window UI for filler-word configuration.

- [ ] **Step 1: Extend the draft struct**

In `ControlPanelSettingsDraft` (`main.swift:24990-25021`), add three fields and initialize them in `init(settings:)`:

```swift
var removeFillerWords: Bool
var enabledFillerPresetKeys: Set<String>
var customFillerWords: [String]
```

```swift
removeFillerWords = settings.removeFillerWords
enabledFillerPresetKeys = settings.enabledFillerPresetKeys
customFillerWords = settings.customFillerWords
```

- [ ] **Step 2: Build the row(s)**

Add a new method, following `normalizeNumbersRow`'s exact shape (`main.swift:26111-26145`) for the master toggle, plus a per-preset checklist and a custom-word list. Given the preset count (~27 entries), use a scrollable `NSStackView` inside an `NSScrollView` with a fixed max height, revealed only when the master toggle is on (simplest correct approach: always build the checklist rows, but set the whole container's `isHidden` based on `draft.removeFillerWords`, and refresh via the existing `refreshSettingsWindow()` call already used by every other toggle action):

```swift
private func fillerWordsRow(_ draft: ControlPanelSettingsDraft) -> NSView {
    let container = NSStackView()
    container.orientation = .vertical
    container.alignment = .leading
    container.spacing = 8

    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 10

    let text = NSStackView()
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.addArrangedSubview(panelLabel(
        t("Удалять слова-паразиты", "Remove filler words"),
        size: 13,
        weight: .semibold
    ))
    text.addArrangedSubview(panelLabel(
        t("Удаляет слова-хезитации и разговорные паразиты из текста диктовки.",
          "Removes hesitation sounds and verbal tics from dictated text."),
        size: 12,
        color: .secondaryLabelColor
    ))

    let toggle = NSSwitch()
    toggle.target = self
    toggle.action = #selector(toggleRemoveFillerWordsSetting(_:))
    toggle.state = draft.removeFillerWords ? .on : .off
    toggle.setContentHuggingPriority(.required, for: .horizontal)

    header.addArrangedSubview(text)
    header.addArrangedSubview(NSView())
    header.addArrangedSubview(toggle)
    container.addArrangedSubview(header)

    if draft.removeFillerWords {
        let checklist = NSStackView()
        checklist.orientation = .vertical
        checklist.alignment = .leading
        checklist.spacing = 4
        for preset in FillerWordRemover.presets {
            let row = NSButton(checkboxWithTitle: preset.displayText, target: self, action: #selector(toggleFillerPreset(_:)))
            row.state = draft.enabledFillerPresetKeys.contains(preset.key) ? .on : .off
            row.identifier = NSUserInterfaceItemIdentifier(preset.key)
            checklist.addArrangedSubview(row)
        }
        let scroll = NSScrollView()
        scroll.documentView = checklist
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        container.addArrangedSubview(scroll)

        let customField = NSTextField()
        customField.placeholderString = t("Добавить своё слово или фразу и нажать Enter",
                                          "Add a custom word or phrase and press Enter")
        customField.target = self
        customField.action = #selector(addCustomFillerWord(_:))
        container.addArrangedSubview(customField)

        for word in draft.customFillerWords {
            let row = NSStackView()
            row.orientation = .horizontal
            row.addArrangedSubview(panelLabel(word, size: 12))
            let remove = NSButton(title: "×", target: self, action: #selector(removeCustomFillerWord(_:)))
            remove.identifier = NSUserInterfaceItemIdentifier(word)
            row.addArrangedSubview(remove)
            container.addArrangedSubview(row)
        }
    }

    return container
}
```

- [ ] **Step 3: Action selectors**

Add near `toggleNormalizeNumbers` (`main.swift:26806-26811`):

```swift
@objc private func toggleRemoveFillerWordsSetting(_ sender: NSSwitch) {
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    draft.removeFillerWords = sender.state == .on
    settingsDraft = draft
    refreshSettingsWindow()
}

@objc private func toggleFillerPreset(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue else { return }
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    if sender.state == .on {
        draft.enabledFillerPresetKeys.insert(key)
    } else {
        draft.enabledFillerPresetKeys.remove(key)
    }
    settingsDraft = draft
    refreshSettingsWindow()
}

@objc private func addCustomFillerWord(_ sender: NSTextField) {
    let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    guard !draft.customFillerWords.contains(trimmed) else {
        sender.stringValue = ""
        return
    }
    draft.customFillerWords.append(trimmed)
    settingsDraft = draft
    sender.stringValue = ""
    refreshSettingsWindow()
}

@objc private func removeCustomFillerWord(_ sender: NSButton) {
    guard let word = sender.identifier?.rawValue else { return }
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    draft.customFillerWords.removeAll { $0 == word }
    settingsDraft = draft
    refreshSettingsWindow()
}
```

- [ ] **Step 4: Add the row to `makeSettingsContentView()` and to `saveSettingsClicked`**

Add `root.addArrangedSubview(fillerWordsRow(draft))` in `makeSettingsContentView()` near the other content/behavior-related rows (e.g. right after `normalizeNumbersRow`'s call site — grep `root.addArrangedSubview(normalizeNumbersRow` to find it).

In `saveSettingsClicked` (`main.swift:26880` onward), add alongside the other `settings.x = draft.x` lines:

```swift
settings.removeFillerWords = draft.removeFillerWords
settings.enabledFillerPresetKeys = draft.enabledFillerPresetKeys
settings.customFillerWords = draft.customFillerWords
```

- [ ] **Step 5: Remove the old menu item and its action**

In `ParakeyApp`, delete the `filler` `NSMenuItem` block (`main.swift:15286-15291`):

```swift
let filler = NSMenuItem(title: "Remove filler words (um, uh, ah, er, hmm)",
                        action: #selector(toggleRemoveFillerWords(_:)),
                        keyEquivalent: "")
filler.target = self
filler.state = settings.removeFillerWords ? .on : .off
sub.addItem(filler)
```

and delete the now-unused `toggleRemoveFillerWords(_:)` method (`main.swift:16842-16845`).

- [ ] **Step 6: Build**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task3 && mkdir -p ~/scratch/sd-wp-task3 && tar -x -C ~/scratch/sd-wp-task3'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task3/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
```

Expected: `Build complete!` with no errors — in particular, no leftover reference to the deleted `toggleRemoveFillerWords` selector anywhere (the compiler will catch a dangling `#selector` reference; if the build fails on that, search for any other reference you missed).

- [ ] **Step 7: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add filler-word Settings-window UI, remove the old menu-only toggle"
```

---

### Task 4: Auto-stop-on-silence — pure state machine and settings

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - New pure type near `PauseSegmenter`/other pure audio-adjacent logic, or directly above `ParakeyApp` — a small, independently testable state machine
  - `ControlPanelSettings` — two new properties near `keyMuteWhileRecording`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `struct SilenceAutoStopTracker` with a pure `func update(level: Float, now: TimeInterval) -> Bool` (returns `true` exactly once when continuous silence has reached the configured threshold) — Task 5 drives this from the live level-timer.
  - `ControlPanelSettings.autoStopOnSilenceEnabled: Bool` (default `false`)
  - `ControlPanelSettings.autoStopSilenceSeconds: Int` (default `5`, clamped `1...10`)

- [ ] **Step 1: Write the pure state machine**

Add near `PauseSegmenter` (search for `struct PauseSegmenter` to find a suitable spot in the same "recording-adjacent pure logic" neighborhood):

```swift
/// Tracks continuous silence during a live recording and reports when a
/// configured duration has been reached, for auto-stopping the recording.
/// Pure and clock-injected (no wall-clock reads inside) so it can be
/// driven deterministically by a test.
struct SilenceAutoStopTracker {
    static let liveSilenceLevelThreshold: Float = 0.02

    private var silenceStartedAt: TimeInterval?
    private var fired = false
    let thresholdSeconds: TimeInterval

    init(thresholdSeconds: TimeInterval) {
        self.thresholdSeconds = thresholdSeconds
    }

    /// Call once per level-timer tick. Returns true exactly once, on the
    /// tick where continuous silence first reaches `thresholdSeconds`;
    /// false on every other tick, including all subsequent silent ticks
    /// after firing once (call `reset()` when starting a new recording).
    mutating func update(level: Float, now: TimeInterval) -> Bool {
        guard !fired else { return false }
        guard level < Self.liveSilenceLevelThreshold else {
            silenceStartedAt = nil
            return false
        }
        let startedAt = silenceStartedAt ?? now
        silenceStartedAt = startedAt
        guard now - startedAt >= thresholdSeconds else { return false }
        fired = true
        return true
    }

    mutating func reset() {
        silenceStartedAt = nil
        fired = false
    }
}
```

- [ ] **Step 2: Add the two settings properties**

Near `keyMuteWhileRecording`/`muteWhileRecording` (`main.swift:2832`/`3239-3244`):

```swift
private static let keyAutoStopOnSilenceEnabled = "auto_stop_on_silence_enabled"
private static let keyAutoStopSilenceSeconds = "auto_stop_silence_seconds"

var autoStopOnSilenceEnabled: Bool {
    get { defaults.bool(forKey: Self.keyAutoStopOnSilenceEnabled) }
    set { defaults.set(newValue, forKey: Self.keyAutoStopOnSilenceEnabled) }
}

var autoStopSilenceSeconds: Int {
    get {
        guard defaults.object(forKey: Self.keyAutoStopSilenceSeconds) != nil else { return 5 }
        return max(1, min(10, defaults.integer(forKey: Self.keyAutoStopSilenceSeconds)))
    }
    set { defaults.set(max(1, min(10, newValue)), forKey: Self.keyAutoStopSilenceSeconds) }
}
```

- [ ] **Step 3: Self-test the state machine**

```swift
private static func testSilenceAutoStopTracker() throws {
    // Continuous silence past the threshold fires exactly once.
    var tracker = SilenceAutoStopTracker(thresholdSeconds: 5)
    try expect(tracker.update(level: 0.0, now: 0), equals: false, "tick 0: not yet silent long enough")
    try expect(tracker.update(level: 0.0, now: 3), equals: false, "tick 3s: still under threshold")
    try expect(tracker.update(level: 0.0, now: 5), equals: true, "tick 5s: threshold reached, fires once")
    try expect(tracker.update(level: 0.0, now: 6), equals: false, "tick 6s: already fired, must not fire again")

    // A voiced tick resets the clock.
    var resetTracker = SilenceAutoStopTracker(thresholdSeconds: 5)
    _ = resetTracker.update(level: 0.0, now: 0)
    _ = resetTracker.update(level: 0.0, now: 4)
    _ = resetTracker.update(level: 0.5, now: 4.5) // voice interrupts
    try expect(resetTracker.update(level: 0.0, now: 5), equals: false, "silence restarted after voice, 0.5s in is not enough")
    try expect(resetTracker.update(level: 0.0, now: 9.5), equals: true, "5s of continuous silence after the reset point fires")

    // reset() allows firing again for a new recording.
    var reusedTracker = SilenceAutoStopTracker(thresholdSeconds: 1)
    _ = reusedTracker.update(level: 0.0, now: 0)
    try expect(reusedTracker.update(level: 0.0, now: 1), equals: true, "first recording fires at 1s")
    reusedTracker.reset()
    try expect(reusedTracker.update(level: 0.0, now: 1.5), equals: false, "after reset, clock restarts from the next tick")
    try expect(reusedTracker.update(level: 0.0, now: 2.5), equals: true, "second recording fires 1s after its own start")
}
```

- [ ] **Step 4: Register the self-test**

`case "silence-auto-stop-tracker": return runSuite("silence-auto-stop-tracker", testSilenceAutoStopTracker)` in the switch, plus `try testSilenceAutoStopTracker()` in `testAll()`.

- [ ] **Step 5: Build and run**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task4 && mkdir -p ~/scratch/sd-wp-task4 && tar -x -C ~/scratch/sd-wp-task4'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task4/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task4/swift && .build/debug/Parakey --self-test silence-auto-stop-tracker'
```

Expected: `PASS silence-auto-stop-tracker`.

- [ ] **Step 6: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add SilenceAutoStopTracker state machine and its settings"
```

---

### Task 5: Wire auto-stop-on-silence into the live recording loop; Settings UI

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `ParakeyApp` — a new `private var silenceAutoStopTracker: SilenceAutoStopTracker?` field, `startRecordingLevelMeter()` (reset), `recordingLevelTimerFired(_:)` (drive it) — search `recordingLevelTimerFired` near `main.swift:12002`
  - `ControlPanelSettingsDraft`, `makeSettingsContentView()`, `saveSettingsClicked` — Settings UI (same process/pattern as Task 3)

**Interfaces:**
- Consumes: `SilenceAutoStopTracker` (Task 4), `settings.autoStopOnSilenceEnabled`/`autoStopSilenceSeconds` (Task 4).
- Produces: a working end-to-end feature.

- [ ] **Step 1: Add the tracker field and reset it per-session**

Add `private var silenceAutoStopTracker: SilenceAutoStopTracker?` near the other recording-session fields (alongside `recordingHUDStartedAt`, added in an earlier phase of this project — grep it to find the right neighborhood).

In `startRecordingLevelMeter()` (`main.swift:11940`-ish, alongside the other per-session resets like `recordingVisualLevel = 0`), add:

```swift
silenceAutoStopTracker = settings.autoStopOnSilenceEnabled
    ? SilenceAutoStopTracker(thresholdSeconds: TimeInterval(settings.autoStopSilenceSeconds))
    : nil
```

- [ ] **Step 2: Drive the tracker from `recordingLevelTimerFired`**

Inside `recordingLevelTimerFired(_:)` (`main.swift:12002` onward), after `let rawLevel = visibleRecordingLevel(rawLevel: unsuppressedLevel)` (or the nearest existing computed live level value — read the function fully first to confirm the exact variable name and its normalized 0...1 range, since Task 4's tracker assumes that same range), add:

```swift
if silenceAutoStopTracker?.update(level: rawLevel, now: now) == true {
    log("auto-stop: \(settings.autoStopSilenceSeconds)s of continuous silence, releasing")
    hotkey.resetToggleState()
    handleRelease()
    return
}
```

Place this check after the existing HUD-update calls in the same function (so the HUD still reflects the final silent tick before the recording ends) but before anything that would be redundant once `handleRelease()` has already torn the session down. `now` should reuse the same `let now = ProcessInfo.processInfo.systemUptime` already computed earlier in this function (`main.swift:12018`-ish) rather than calling it again.

- [ ] **Step 3: Settings UI — draft field, row, save**

In `ControlPanelSettingsDraft`, add:

```swift
var autoStopOnSilenceEnabled: Bool
var autoStopSilenceSeconds: Int
```

with `init(settings:)` lines `autoStopOnSilenceEnabled = settings.autoStopOnSilenceEnabled` / `autoStopSilenceSeconds = settings.autoStopSilenceSeconds`.

Add a row-building method following the `normalizeNumbersRow` toggle pattern for the boolean, plus a `popupRow` (matching `enterDelayRow`'s exact shape at `main.swift:26156`-ish) for the duration, populated with `1...10` second options:

```swift
private static let silenceDurationOptions: [(title: String, value: String)] =
    (1...10).map { ("\($0) \(t("сек", "sec"))", String($0)) }

private func autoStopOnSilenceRow(_ draft: ControlPanelSettingsDraft) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10

    let text = NSStackView()
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.addArrangedSubview(panelLabel(
        t("Останавливать запись при тишине", "Stop automatically after silence"),
        size: 13,
        weight: .semibold
    ))
    text.addArrangedSubview(panelLabel(
        t("Диктовка завершится сама после указанного времени тишины.",
          "Dictation ends on its own after the configured amount of silence."),
        size: 12,
        color: .secondaryLabelColor
    ))

    let toggle = NSSwitch()
    toggle.target = self
    toggle.action = #selector(toggleAutoStopOnSilence(_:))
    toggle.state = draft.autoStopOnSilenceEnabled ? .on : .off
    toggle.setContentHuggingPriority(.required, for: .horizontal)

    row.addArrangedSubview(text)
    row.addArrangedSubview(NSView())
    row.addArrangedSubview(toggle)
    return row
}

private func autoStopSilenceDurationRow(_ draft: ControlPanelSettingsDraft) -> NSView {
    popupRow(
        title: t("Длительность тишины", "Silence duration"),
        detail: t("Сколько секунд тишины ждать перед остановкой.",
                  "How many seconds of silence to wait before stopping."),
        selectedValue: String(draft.autoStopSilenceSeconds),
        options: Self.silenceDurationOptions,
        action: #selector(selectAutoStopSilenceSeconds(_:)),
        toolTip: t("Настроить порог тишины для автоостановки.",
                   "Configure the silence threshold for auto-stop.")
    )
}
```

(`popupRow`'s confirmed current signature, `main.swift:26249`: `popupRow(title: String, detail: String, selectedValue: String, options: [(title: String, value: String)], action: Selector, toolTip: String? = nil) -> NSView` — the snippet above already matches it.)

Add both rows to `makeSettingsContentView()` (the duration row only meaningfully matters when the toggle is on — for a first pass, show both unconditionally, matching this codebase's existing preference for simplicity over conditional-visibility polish elsewhere in this window; revisit only if a reviewer flags it as confusing).

Action selectors:

```swift
@objc private func toggleAutoStopOnSilence(_ sender: NSSwitch) {
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    draft.autoStopOnSilenceEnabled = sender.state == .on
    settingsDraft = draft
    refreshSettingsWindow()
}

@objc private func selectAutoStopSilenceSeconds(_ sender: NSPopUpButton) {
    guard let raw = sender.selectedItem?.representedObject as? String,
          let seconds = Int(raw) else { return }
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    draft.autoStopSilenceSeconds = seconds
    settingsDraft = draft
    refreshSettingsWindow()
}
```

Add to `saveSettingsClicked`:

```swift
settings.autoStopOnSilenceEnabled = draft.autoStopOnSilenceEnabled
settings.autoStopSilenceSeconds = draft.autoStopSilenceSeconds
```

- [ ] **Step 4: Build**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task5 && mkdir -p ~/scratch/sd-wp-task5 && tar -x -C ~/scratch/sd-wp-task5'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task5/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
```

Expected: `Build complete!` with no errors.

- [ ] **Step 5: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Wire auto-stop-on-silence into the live recording loop and Settings window"
```

---

### Task 6: "Launch at Login" Settings-window row; remove the old menu item

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `ControlPanelSettingsDraft`, `makeSettingsContentView()`, new row/action in `SuperDictateControlPanelApp`
  - `ParakeyApp`'s `launchAtLogin` menu item (`main.swift:15328-15343`-ish) and `toggleLaunchAtLogin(_:)` (`main.swift:16874-16887`ish) — both removed

**Interfaces:**
- Consumes: `SMAppService.mainApp` directly (system API, no cross-process dependency — see design doc's architecture note).
- Produces: a working Settings-window toggle.

- [ ] **Step 1: Read `toggleLaunchAtLogin`'s full body first**

Before writing the Settings-window version, read `main.swift:16874` through its closing brace in full (it was only partially quoted during planning) to capture its exact error-handling call (`showLaunchAtLoginError`) and any other detail the snippet below might be missing.

- [ ] **Step 2: Add the Settings-window row**

No draft field is needed for this one — `SMAppService.mainApp.status` reads live system state, not a `UserDefaults`-backed preference, so unlike every other row in this window it should NOT go through the draft/save-and-apply flow (staging a login-item change until "Save" is clicked would be confusing — flip it immediately, matching how the menu item already behaves). Add a row directly in `makeSettingsContentView()` (or a small helper) that reads current `SMAppService.mainApp.status` fresh each time the window renders, with an `NSSwitch` acting immediately on toggle:

```swift
private func launchAtLoginRow() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10

    let text = NSStackView()
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.addArrangedSubview(panelLabel(
        t("Запускать при входе в систему", "Launch at Login"),
        size: 13,
        weight: .semibold
    ))

    let toggle = NSSwitch()
    toggle.target = self
    toggle.action = #selector(toggleLaunchAtLoginSetting(_:))
    switch SMAppService.mainApp.status {
    case .enabled:
        toggle.state = .on
    case .requiresApproval:
        toggle.state = .mixed
        toggle.toolTip = t("Подтвердите в Системных настройках → Основные → Элементы входа.",
                           "Approve in System Settings → General → Login Items.")
    default:
        toggle.state = .off
    }
    toggle.setContentHuggingPriority(.required, for: .horizontal)

    row.addArrangedSubview(text)
    row.addArrangedSubview(NSView())
    row.addArrangedSubview(toggle)
    return row
}

@objc private func toggleLaunchAtLoginSetting(_ sender: NSSwitch) {
    do {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            try SMAppService.mainApp.unregister()
        default:
            try SMAppService.mainApp.register()
        }
    } catch {
        showError(title: t("Не удалось изменить запуск при входе", "Couldn't change Launch at Login"),
                  detail: error.localizedDescription)
    }
    refreshSettingsWindow()
}
```

Add `root.addArrangedSubview(launchAtLoginRow())` to `makeSettingsContentView()`.

- [ ] **Step 3: Remove the old menu item and action**

In `ParakeyApp`, delete the `launchAtLogin` `NSMenuItem` block and the `toggleLaunchAtLogin(_:)` method entirely. Confirm `ensureLaunchAtLoginEnabled()` (the separate auto-enable-on-first-run helper) is untouched — it doesn't reference the menu item or its action, only calls `SMAppService.mainApp.register()` directly, so it should need no changes; verify this by reading it once before deleting anything nearby.

- [ ] **Step 4: Build**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task6 && mkdir -p ~/scratch/sd-wp-task6 && tar -x -C ~/scratch/sd-wp-task6'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task6/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
```

Expected: `Build complete!` with no errors, no dangling selector references.

- [ ] **Step 5: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add Launch at Login Settings-window row, remove the old menu item"
```

---

### Task 7: "Mute while recording" Settings row + corrections discoverability line

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `ControlPanelSettingsDraft`, `makeSettingsContentView()`, `saveSettingsClicked` — mute row (same pattern as Task 3/5's boolean rows, this time trivial since `muteWhileRecording` already exists exactly as a plain settings property)
  - `ParakeyApp`'s `mute` menu item (`main.swift:15309-15313`) and `toggleMute(_:)` (`main.swift:16837-16840`) — both removed
  - `makeSettingsContentView()` — one new static informational row (no logic) for corrections discoverability

**Interfaces:**
- Consumes: `ControlPanelSettings.muteWhileRecording` (already exists).
- Produces: a working Settings-window toggle; a static info label.

- [ ] **Step 1: Draft field, row, save — mute**

Add to `ControlPanelSettingsDraft`: `var muteWhileRecording: Bool`, initialized `muteWhileRecording = settings.muteWhileRecording`.

Add a row following the exact `normalizeNumbersRow` template (boolean toggle, no popup):

```swift
private func muteWhileRecordingRow(_ draft: ControlPanelSettingsDraft) -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10

    let text = NSStackView()
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.addArrangedSubview(panelLabel(
        t("Заглушать системный звук во время записи", "Mute system audio while recording"),
        size: 13,
        weight: .semibold
    ))

    let toggle = NSSwitch()
    toggle.target = self
    toggle.action = #selector(toggleMuteWhileRecording(_:))
    toggle.state = draft.muteWhileRecording ? .on : .off
    toggle.setContentHuggingPriority(.required, for: .horizontal)

    row.addArrangedSubview(text)
    row.addArrangedSubview(NSView())
    row.addArrangedSubview(toggle)
    return row
}

@objc private func toggleMuteWhileRecording(_ sender: NSSwitch) {
    var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
    draft.muteWhileRecording = sender.state == .on
    settingsDraft = draft
    refreshSettingsWindow()
}
```

Add `root.addArrangedSubview(muteWhileRecordingRow(draft))` to `makeSettingsContentView()`, and `settings.muteWhileRecording = draft.muteWhileRecording` to `saveSettingsClicked`.

- [ ] **Step 2: Remove the old menu item and action**

Delete the `mute` `NSMenuItem` block (`main.swift:15309-15313`) and `toggleMute(_:)` (`main.swift:16837-16840`) from `ParakeyApp`.

- [ ] **Step 3: Corrections discoverability row**

Add one static row (no button, no action — see the design doc's architectural note on why this is intentionally non-interactive):

```swift
private func correctionsInfoRow() -> NSView {
    let text = NSStackView()
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 3
    text.addArrangedSubview(panelLabel(
        t("Исправления транскрипции", "Text corrections"),
        size: 13,
        weight: .semibold
    ))
    text.addArrangedSubview(panelLabel(
        t("Управляются из меню значка в строке меню → «Исправления текста».",
          "Managed from the menu bar icon → “Text Corrections”."),
        size: 12,
        color: .secondaryLabelColor
    ))
    return text
}
```

Add `root.addArrangedSubview(correctionsInfoRow())` to `makeSettingsContentView()`.

- [ ] **Step 4: Build**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task7 && mkdir -p ~/scratch/sd-wp-task7 && tar -x -C ~/scratch/sd-wp-task7'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task7/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
```

Expected: `Build complete!` with no errors.

- [ ] **Step 5: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add mute-while-recording Settings row and corrections discoverability line"
```

---

### Task 8: HUD "Contrast" adaptive accent color

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`
  - `RecordingHUDAccentColor` enum (`main.swift:525-560`)
  - `RecordingHUDView.shouldUseLightBackground()` (`main.swift:9796-9806`) — visibility change only
  - `configureRecordingHUDView(_:)` (`main.swift:12425`)
  - `exportRecordingHUDAnimationFrames` (`main.swift:9813`, color assignments at `9843-9844`)
  - `localizedColorName(_:)` (`main.swift:26545`-ish)

**Interfaces:**
- Consumes: nothing new.
- Produces: `RecordingHUDAccentColor.resolvedColor(lightBackground: Bool) -> NSColor`.

- [ ] **Step 1: Add the enum case and `resolvedColor`**

In `RecordingHUDAccentColor` (`main.swift:525-560`), add `case contrast` to the case list and `case .contrast: return "Contrast"` to `displayName`. Directly after the enum's closing brace, add:

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

(`.white` intentionally keeps returning literal white from `nsColor` — it is not affected by this change, per the design doc.)

- [ ] **Step 2: Make `shouldUseLightBackground()` non-private**

Change `private func shouldUseLightBackground() -> Bool` (`main.swift:9796`) to `func shouldUseLightBackground() -> Bool` (drop `private` — it needs to be callable from `configureRecordingHUDView`, a method on a different type in the same file).

- [ ] **Step 3: Reorder and resolve in `configureRecordingHUDView`**

Find the current body at `main.swift:12425`. Change from:

```swift
private func configureRecordingHUDView(_ view: RecordingHUDView) {
    view.visualScale = settings.recordingHUDSize.visualScale
    view.recordingColor = settings.recordingHUDRecordingColor.nsColor
    view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
    view.backgroundStyle = settings.recordingHUDBackgroundStyle
    view.displayMode = settings.recordingHUDDisplayMode
}
```

to:

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

(`backgroundStyle` must be set before `shouldUseLightBackground()` is called, since that method reads `self.backgroundStyle` — this reordering is the whole point of this step.)

- [ ] **Step 4: Update the debug/preview export helper**

In `exportRecordingHUDAnimationFrames` (`main.swift:9813`; the color assignments are at `9843-9844`, with `view.backgroundStyle = .dark` a few lines below), change:

```swift
view.recordingColor = settings.recordingHUDRecordingColor.nsColor
view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
```

to:

```swift
view.recordingColor = settings.recordingHUDRecordingColor.resolvedColor(lightBackground: false)
view.transcribingColor = settings.recordingHUDTranscribingColor.resolvedColor(lightBackground: false)
```

(`lightBackground: false` because this helper hardcodes `.dark` — confirm that hardcoded value is still `.dark` at the point you read it; if it has changed, match `resolvedColor`'s argument to whatever it now is.)

- [ ] **Step 5: Localized name**

In `localizedColorName(_:)` (`main.swift:26545`-ish), add a case:

```swift
case .contrast: return "Контрастный"
```

(matching the existing per-case Russian-string switch pattern already used there for the other 8 colors).

- [ ] **Step 6: Self-test for `resolvedColor`**

```swift
private static func testRecordingHUDAccentColorResolvedColor() throws {
    for color in RecordingHUDAccentColor.allCases where color != .contrast {
        try expect(color.resolvedColor(lightBackground: true), equals: color.nsColor,
                   "\(color) must be background-independent on a light background")
        try expect(color.resolvedColor(lightBackground: false), equals: color.nsColor,
                   "\(color) must be background-independent on a dark background")
    }
    try expect(RecordingHUDAccentColor.contrast.resolvedColor(lightBackground: true), equals: .black,
               "contrast on a light background must resolve to black")
    try expect(RecordingHUDAccentColor.contrast.resolvedColor(lightBackground: false), equals: .white,
               "contrast on a dark background must resolve to white")
}
```

(`NSColor` conforms to `Equatable` via `isEqual`-bridging for exact-literal comparisons like `.black`/`.white`/the existing `nsColor` cases used here — this mirrors how `RecordingHUDView`'s existing `didSet { if !oldValue.isEqual(recordingColor) ... }` pattern already treats `NSColor` comparisons elsewhere in this file, so a plain `==` in a test is consistent with that.)

Register: `case "recording-hud-accent-color-resolved": return runSuite("recording-hud-accent-color-resolved", testRecordingHUDAccentColorResolvedColor)`, plus the `testAll()` call.

- [ ] **Step 7: Build and run**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task8 && mkdir -p ~/scratch/sd-wp-task8 && tar -x -C ~/scratch/sd-wp-task8'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task8/swift && swift build -c debug --product Parakey 2>&1 | tail -40'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task8/swift && .build/debug/Parakey --self-test recording-hud-accent-color-resolved'
```

Expected: `PASS recording-hud-accent-color-resolved`.

- [ ] **Step 8: Safety check and commit**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
git add swift/Sources/Parakey/main.swift
git commit -m "Add adaptive Contrast HUD accent color option"
```

---

### Task 9: Full-branch build verification and manual checklist

**Files:** none (verification only; fix-forward in `main.swift` if this task finds a defect, following the same file/section references as Tasks 1-8)

- [ ] **Step 1: Full sync, build, and run every new self-test group together**

```bash
git archive HEAD | sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'rm -rf ~/scratch/sd-wp-task9 && mkdir -p ~/scratch/sd-wp-task9 && tar -x -C ~/scratch/sd-wp-task9'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task9/swift && swift build -c debug --product Parakey 2>&1 | tail -60'
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'cd ~/scratch/sd-wp-task9/swift && for g in filler-word-preset-defaults enabled-filler-preset-keys-setting filler-word-presets-custom-words silence-auto-stop-tracker recording-hud-accent-color-resolved fillers russian-number-itn-pipeline; do echo "=== $g ==="; .build/debug/Parakey --self-test $g; echo "EXIT=$?"; done'
```

Expected: `Build complete!` and every listed group `PASS`/`EXIT=0`. The last two groups (`fillers`, `russian-number-itn-pipeline`) are pre-existing regression suites unrelated to this plan's own new tests — included here as a broader sanity check that nothing in the filler-word rewrite (Task 2) silently broke old behavior.

- [ ] **Step 2: Prepare the manual verification checklist for the human**

This plan touches user-visible UI extensively (a Settings window with ~6 new/moved rows, two removed menu items) in ways no self-test can confirm end-to-end. Write the following checklist into the task report for the human to run once the build is installed:

1. Open Settings — confirm new rows exist: filler-word master toggle + expandable per-word checklist + custom-word field; "Stop automatically after silence" toggle + duration dropdown; "Launch at Login" toggle; "Mute system audio while recording" toggle; a static "Text corrections" info line; "Recording color"/"Transcribing color" dropdowns now include "Contrast."
2. Confirm the menu bar dropdown no longer has "Remove filler words," "Mute system audio while recording," or "Launch at Login" entries (moved to Settings), but still has the full "Text Corrections" submenu (unchanged).
3. Toggle filler words on, enable a couple of Russian phrase presets (e.g. "как бы"), add a custom word, dictate a sentence containing them, confirm they're removed and the rest of the text/punctuation looks correct.
4. Enable auto-stop-on-silence at a short duration (1-2s for a fast manual test), start dictating, stop talking, confirm the recording ends on its own after roughly that many seconds and produces a normal transcript — same as releasing the hotkey manually.
5. Toggle "Launch at Login" on, check System Settings → General → Login Items to confirm SuperDictate is listed; toggle off, confirm it's removed.
6. Toggle "Mute system audio while recording" — play some audio, start a dictation, confirm playback mutes/unmutes around the recording exactly as before this change (this only moved where the toggle lives, not its behavior).
7. Set Recording color to "Contrast" with HUD background style = Light — confirm the waveform/outline is dark and clearly visible (this is the bug that motivated §6; confirm it's actually fixed, not just that the option exists). Repeat with background style = Dark, confirm it shows white/light.

- [ ] **Step 3: Fix forward if verification finds a defect**

Address findings in the relevant task's file/section per this plan; rebuild and re-verify per that task's own build steps.

- [ ] **Step 4: Safety check**

```bash
sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
```

- [ ] **Step 5: Final commit if fixes were made**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "Fix issues found in Windows-port feature parity manual verification"
```

(Skip if Step 1's build/self-tests were clean and no manual-checklist issue required a code change during this task — the manual checklist itself is executed by the human after this plan's automated portion completes, same convention as the recording-HUD plan's own Task 6.)
