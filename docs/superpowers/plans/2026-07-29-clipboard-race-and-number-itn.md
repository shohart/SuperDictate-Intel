# Clipboard-Restore Race Fix + Russian Number ITN — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the clipboard-restore race that overwrites dictated text with stale clipboard content on slow target apps, and add a Control Panel toggle that renders dictated Russian numbers as digits instead of words.

**Architecture:** Part A replaces the fixed 0.35s delay in `ClipboardPasteInserter.restorePasteboard` with an AX-polling confirmation that the target actually received the pasted text, falling back to a longer safety timeout. Part B adds a new standalone `RussianNumberNormalizer` pure-function module, wired into the existing `processedDictationText` pipeline (main.swift:6325) as a new stage gated by a new `Settings.normalizeNumbersToDigits` flag, exposed via a new Control Panel toggle row following the existing `alternateCompletionRow`/`ControlPanelSettingsDraft` pattern.

**Tech Stack:** Swift, AppKit, ApplicationServices (Accessibility API), XCTest (this project's existing test target — confirm exact test command in Task A1 Step 2 before relying on it).

## Global Constraints

- Follow existing code style: 4-space indent, `// MARK:` section banners, doc comments only where they explain non-obvious *why* (matches this file's existing convention, e.g. main.swift:6127-6136, 6345-6352).
- No new external dependencies (no Python runtime, no third-party Swift packages) — this was an explicit design decision to keep the app dependency-light.
- All new settings keys follow the existing `Settings` pattern: a `private static let keyX = "snake_case_key"` constant plus a computed `var x: Bool` property backed by `UserDefaults` (see main.swift:2821, 3466-3468).
- The Control Panel toggle must be a genuine settings-window control (`ControlPanelSettingsDraft` + a row function + save/discard wiring), **not** a menu-bar-only `NSMenuItem` toggle — this was an explicit user requirement.
- Russian-only scope for ITN: gate on `language == .auto || language == .russian`, mirroring the exact pattern already used by `ParakeetTranscriptRepair.apply` (main.swift:6028-6038).
- ITN must never guess: any numeral word sequence that isn't recognized with high confidence is left as the original dictated words, unchanged.

---

## Part A — Clipboard-restore race fix

### Task A1: AX-based paste confirmation poller

**Files:**
- Create: `swift/Sources/Parakey/PasteConfirmationPoller.swift`
- Test: `swift/Tests/ParakeyTests/PasteConfirmationPollerTests.swift` (create `swift/Tests/ParakeyTests/` if it doesn't already exist — check first with `find swift/Tests -type d`; if the project uses a different existing test target name, add the new test file there instead and note the actual path in your commit message)

**Interfaces:**
- Produces: `enum PasteConfirmationPoller` with
  `static func waitForPasteConfirmation(expectedSubstring: String, pollInterval: TimeInterval = 0.05, timeout: TimeInterval = 2.0, valueReader: () -> String?) -> Bool`
  — polls `valueReader()` up to `timeout` seconds, at `pollInterval` cadence, returning `true` the moment the returned string contains `expectedSubstring`, and `false` if `timeout` elapses first. `valueReader` is injected so tests don't need real AX/Accessibility permission.
  Also produces `static func currentFocusedElementValueReader() -> (() -> String?)` — the real, non-test `valueReader` factory: it resolves the focused element via `FocusedTextTargetResolver().captureTarget()` (FocusedTextTarget.swift:54-111) and reads `kAXValueAttribute` (falling back to the `AXSelectedText` attribute name used elsewhere in that file, FocusedTextTarget.swift:61) as a `String`, returning `nil` on any AX error instead of throwing (this runs on a background queue per FocusedTextTargetResolver's own documented threading contract, FocusedTextTarget.swift:43-53).

- [ ] **Step 1: Write the failing tests for the pure polling logic**

```swift
import XCTest
@testable import Parakey

final class PasteConfirmationPollerTests: XCTestCase {
    func test_returnsTrueAsSoonAsSubstringAppears() {
        var callCount = 0
        let values = ["", "старое ", "старое текст"]
        let reader: () -> String? = {
            defer { callCount += 1 }
            return callCount < values.count ? values[callCount] : values.last
        }
        let confirmed = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            pollInterval: 0.001,
            timeout: 1.0,
            valueReader: reader
        )
        XCTAssertTrue(confirmed)
        XCTAssertLessThan(callCount, values.count + 1)
    }

    func test_returnsFalseOnTimeoutWhenSubstringNeverAppears() {
        let confirmed = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { "unrelated value" }
        )
        XCTAssertFalse(confirmed)
    }

    func test_returnsFalseWhenReaderAlwaysReturnsNil() {
        let confirmed = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "текст",
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { nil }
        )
        XCTAssertFalse(confirmed)
    }

    func test_emptyExpectedSubstringConfirmsImmediately() {
        let confirmed = PasteConfirmationPoller.waitForPasteConfirmation(
            expectedSubstring: "",
            pollInterval: 0.005,
            timeout: 0.05,
            valueReader: { nil }
        )
        XCTAssertTrue(confirmed)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail with "cannot find type 'PasteConfirmationPoller'"**

Run: `swift test --filter PasteConfirmationPollerTests` from the `swift/` directory.
Expected: FAIL — build error, type does not exist yet.

- [ ] **Step 3: Implement `PasteConfirmationPoller`**

```swift
import AppKit
import ApplicationServices

// Polls the currently AX-focused element's value until dictated text
// actually appears in it (or a timeout elapses), so the clipboard-restore
// step in ClipboardPasteInserter can wait for real paste completion instead
// of guessing a fixed delay. See main.swift ClipboardPasteInserter for the
// caller and the race this closes.
enum PasteConfirmationPoller {
    static func waitForPasteConfirmation(expectedSubstring: String,
                                         pollInterval: TimeInterval = 0.05,
                                         timeout: TimeInterval = 2.0,
                                         valueReader: () -> String?) -> Bool {
        if expectedSubstring.isEmpty { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = valueReader(), value.contains(expectedSubstring) {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    static func currentFocusedElementValueReader() -> () -> String? {
        {
            guard let target = try? FocusedTextTargetResolver().captureTarget() else {
                return nil
            }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(target.element,
                                                        kAXValueAttribute as CFString,
                                                        &value)
            if result == .success, let stringValue = value as? String {
                return stringValue
            }
            var selectedText: CFTypeRef?
            let selectedResult = AXUIElementCopyAttributeValue(target.element,
                                                                "AXSelectedText" as CFString,
                                                                &selectedText)
            if selectedResult == .success, let stringValue = selectedText as? String {
                return stringValue
            }
            return nil
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PasteConfirmationPollerTests` from the `swift/` directory.
Expected: PASS, all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/PasteConfirmationPoller.swift swift/Tests/ParakeyTests/PasteConfirmationPollerTests.swift
git commit -m "Add AX-based paste confirmation poller"
```

---

### Task A2: Wire confirmation polling into `ClipboardPasteInserter.restorePasteboard`

**Files:**
- Modify: `swift/Sources/Parakey/main.swift:7247-7299` (the `ClipboardPasteInserter` enum)
- Test: `swift/Tests/ParakeyTests/ClipboardPasteInserterRestoreTests.swift`

**Interfaces:**
- Consumes: `PasteConfirmationPoller.waitForPasteConfirmation(expectedSubstring:pollInterval:timeout:valueReader:) -> Bool` and `PasteConfirmationPoller.currentFocusedElementValueReader() -> () -> String?` from Task A1.
- Produces: `ClipboardPasteInserter.restorePasteboard`'s new signature takes an injectable `valueReader` (defaulted to the real AX reader in production, overridable in tests) and an injectable `confirm` function (defaulted to `PasteConfirmationPoller.waitForPasteConfirmation`) so the existing `insert(_:)` call site and its tests aren't broken.

**Note on threading:** `restorePasteboard` currently runs entirely on `DispatchQueue.main` via `asyncAfter`. Polling with `Thread.sleep` must NOT run on the main queue/actor (it would freeze the UI for up to 2s). Dispatch the wait onto a background queue and hop back to main only to touch `pasteboard`/`NSPasteboard`.

- [ ] **Step 1: Write the failing test for the new restore behavior**

```swift
import XCTest
@testable import Parakey

final class ClipboardPasteInserterRestoreTests: XCTestCase {
    func test_restoresOnlyAfterConfirmationSucceeds() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard content", forType: .string)

        let expectation = expectation(description: "restore ran")
        var confirmWasCalledWithExpectedText: String?

        ClipboardPasteInserterTestHooks.restorePasteboardForTesting(
            previousText: "previous clipboard content",
            dictatedText: "dictated text",
            pasteboard: pasteboard,
            confirm: { expectedSubstring, _, _, _ in
                confirmWasCalledWithExpectedText = expectedSubstring
                return true
            }
        ) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(confirmWasCalledWithExpectedText, "dictated text")
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard content")
    }

    func test_stillRestoresAfterConfirmationTimesOut() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard content", forType: .string)

        let expectation = expectation(description: "restore ran")

        ClipboardPasteInserterTestHooks.restorePasteboardForTesting(
            previousText: "previous clipboard content",
            dictatedText: "dictated text",
            pasteboard: pasteboard,
            confirm: { _, _, _, _ in false }
        ) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard content")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ClipboardPasteInserterRestoreTests` from `swift/`.
Expected: FAIL — `ClipboardPasteInserterTestHooks` does not exist yet.

- [ ] **Step 3: Refactor `ClipboardPasteInserter` to poll for confirmation before restoring**

Replace the existing `restorePasteboard` function (main.swift:7280-7291) and the call site in `insert(_:)` (main.swift:7273-7276) with:

```swift
@MainActor
private enum ClipboardPasteInserter {
    private static let virtualKeyCommand: CGKeyCode = 0x37  // left Command
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'
    private static let confirmationPollInterval: TimeInterval = 0.05
    private static let confirmationTimeout: TimeInterval = 2.0

    static func write(_ text: String, to pb: NSPasteboard) -> Bool {
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    static func insert(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        guard write(text, to: pasteboard) else {
            log("pasteboard write failed")
            return false
        }
        let transientChangeCount = pasteboard.changeCount

        let steps = clipboardPasteKeyboardEventSteps(commandKey: virtualKeyCommand,
                                                     pasteKey: virtualKeyV)
        guard post(steps) else {
            log("paste event creation failed")
            previous.restore(to: pasteboard)
            return false
        }
        restorePasteboard(previous,
                          ifStillTemporaryText: text,
                          changeCount: transientChangeCount,
                          pasteboard: pasteboard,
                          valueReader: PasteConfirmationPoller.currentFocusedElementValueReader(),
                          confirm: PasteConfirmationPoller.waitForPasteConfirmation)
        return true
    }

    private static func restorePasteboard(_ snapshot: PasteboardSnapshot,
                                          ifStillTemporaryText text: String,
                                          changeCount: Int,
                                          pasteboard: NSPasteboard,
                                          valueReader: @escaping () -> String?,
                                          confirm: @escaping (String, TimeInterval, TimeInterval, () -> String?) -> Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = confirm(text, confirmationPollInterval, confirmationTimeout, valueReader)
            DispatchQueue.main.async {
                guard pasteboard.changeCount == changeCount,
                      pasteboard.string(forType: .string) == text else {
                    return
                }
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private static func post(_ steps: [KeyboardEventStep]) -> Bool {
        // Post Command as real key events instead of only tagging the V
        // events with .maskCommand. Sleep/wake can leave session modifier
        // state unreliable for flag-only synthetic shortcuts.
        return postKeyboardEventSteps(steps)
    }
}

// Test-only seam: exercises the confirmation-gated restore logic without
// requiring real Accessibility permission or a real paste event. Not used
// by production code paths.
enum ClipboardPasteInserterTestHooks {
    @MainActor
    static func restorePasteboardForTesting(previousText: String,
                                            dictatedText: String,
                                            pasteboard: NSPasteboard,
                                            confirm: @escaping (String, TimeInterval, TimeInterval, () -> String?) -> Bool,
                                            completion: @escaping () -> Void) {
        let previous = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        _ = pasteboard.setString(dictatedText, forType: .string)
        let changeCount = pasteboard.changeCount

        DispatchQueue.global(qos: .userInitiated).async {
            _ = confirm(dictatedText, 0.01, 0.2, { nil })
            DispatchQueue.main.async {
                if pasteboard.changeCount == changeCount,
                   pasteboard.string(forType: .string) == dictatedText {
                    previous.restore(to: pasteboard)
                }
                completion()
            }
        }
    }
}
```

Note: `ClipboardPasteInserterTestHooks` duplicates the restore guard rather than making `ClipboardPasteInserter.restorePasteboard` itself `internal`, because that function is intentionally `private` to its enum and the surrounding code keeps insertion-strategy internals private by convention (see `DirectUnicodeInserter`, `PasteboardSnapshot` in the same block). If a reviewer prefers exposing `restorePasteboard` directly instead of duplicating it, that's an acceptable simplification — note it in the task's commit message either way.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardPasteInserterRestoreTests` from `swift/`.
Expected: PASS, both tests green.

- [ ] **Step 5: Run the full existing test suite to check for regressions**

Run: `swift test` from `swift/`.
Expected: PASS (no regressions in pre-existing tests, e.g. the `ParakeetTranscriptRepair` tests referenced at main.swift:20339-20364).

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/Parakey/main.swift swift/Tests/ParakeyTests/ClipboardPasteInserterRestoreTests.swift
git commit -m "Replace fixed clipboard-restore delay with paste confirmation polling"
```

---

## Part B — Russian number ITN toggle

### Task B1: `RussianNumberNormalizer` — tokenizer + cardinal parser

**Files:**
- Create: `swift/Sources/Parakey/RussianNumberNormalizer.swift`
- Test: `swift/Tests/ParakeyTests/RussianNumberNormalizerCardinalTests.swift`

**Interfaces:**
- Produces:
  - `enum RussianNumberNormalizer { static func normalize(_ text: String) -> String }` — the public entry point later tasks (B2, B3, B4) extend.
  - Internal (same file, `private`/`fileprivate` as appropriate — later tasks in this same file can widen visibility as needed): a word-classification table `numberWordValues: [String: (value: Int, category: NumberWordCategory)]` and `enum NumberWordCategory { case unit, teen, ten, hundred, thousandMultiplier, millionMultiplier }`, plus a `parseCardinalRun(_ words: [String]) -> (value: Int, consumedWordCount: Int)?` that greedily consumes as many leading words as form one valid cardinal number and returns `nil` if the first word isn't a recognized number word at all.

- [ ] **Step 1: Write the failing cardinal tests**

```swift
import XCTest
@testable import Parakey

final class RussianNumberNormalizerCardinalTests: XCTestCase {
    func test_simpleTens() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("двадцать девять"), "29")
        XCTAssertEqual(RussianNumberNormalizer.normalize("двадцать пять"), "25")
        XCTAssertEqual(RussianNumberNormalizer.normalize("двадцать шесть"), "26")
    }

    func test_singleDigits() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("пять"), "5")
        XCTAssertEqual(RussianNumberNormalizer.normalize("ноль"), "0")
    }

    func test_teens() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("пятнадцать"), "15")
        XCTAssertEqual(RussianNumberNormalizer.normalize("девятнадцать"), "19")
    }

    func test_hundredsAndCompound() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("сто пятьдесят три"), "153")
        XCTAssertEqual(RussianNumberNormalizer.normalize("девятьсот девяносто девять"), "999")
    }

    func test_thousandsAndMillions() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("две тысячи двадцать шесть"), "2026")
        XCTAssertEqual(RussianNumberNormalizer.normalize("один миллион"), "1000000")
    }

    func test_nonNumberTextUnchanged() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("привет, как дела?"), "привет, как дела?")
    }

    func test_numberEmbeddedInSentencePreservesSurroundingText() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("мне двадцать пять лет"), "мне 25 лет")
    }

    func test_ambiguousStandaloneOneLeftUnchanged() {
        // "один" here means "one [of the ways]", not a quantity being dictated —
        // conservative fallback: only convert when followed by end-of-phrase or
        // another recognized number/unit word, never bare mid-sentence "one".
        XCTAssertEqual(RussianNumberNormalizer.normalize("один из способов"), "один из способов")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RussianNumberNormalizerCardinalTests` from `swift/`.
Expected: FAIL — `RussianNumberNormalizer` does not exist yet.

- [ ] **Step 3: Implement the tokenizer and cardinal parser**

```swift
import Foundation

// Ports the token-classification approach used by established Russian ITN
// tools (NVIDIA NeMo text-processing's Russian grammar, natasha/yargy number
// extractors) as native Swift pattern matching — no external runtime, see
// docs/superpowers/specs/2026-07-29-clipboard-race-and-number-itn-design.md
// for the full rationale. Deliberately conservative: a numeral word sequence
// is only converted when it's unambiguous; anything else is left as the
// original dictated words.
enum RussianNumberNormalizer {
    enum NumberWordCategory {
        case unit, teen, ten, hundred, thousandMultiplier, millionMultiplier
    }

    // Every literal inflected wordform we recognize, lowercased, mapped to
    // its numeric value and structural role. Deliberately covers nominative/
    // accusative forms (by far the most common in dictated cardinal counts)
    // plus the oblique forms needed for money/date phrasing added in later
    // tasks. Case forms beyond this table are a known, documented gap — an
    // unrecognized inflection simply falls through to the "leave as-is"
    // fallback rather than being guessed at.
    static let numberWordValues: [String: (value: Int, category: NumberWordCategory)] = {
        var table: [String: (value: Int, category: NumberWordCategory)] = [:]

        let units: [(words: [String], value: Int)] = [
            (["ноль", "нуля", "нулю", "нулём", "нуле"], 0),
            (["один", "одного", "одному", "одним", "одном", "одна", "одной", "одну", "одно"], 1),
            (["два", "двух", "двум", "двумя", "две"], 2),
            (["три", "трёх", "трех", "трём", "трем", "тремя"], 3),
            (["четыре", "четырёх", "четырех", "четырём", "четырем", "четырьмя"], 4),
            (["пять", "пяти", "пятью"], 5),
            (["шесть", "шести", "шестью"], 6),
            (["семь", "семи", "семью"], 7),
            (["восемь", "восьми", "восемью"], 8),
            (["девять", "девяти", "девятью"], 9),
        ]
        for group in units {
            for word in group.words { table[word] = (group.value, .unit) }
        }

        let teens: [(words: [String], value: Int)] = [
            (["десять", "десяти", "десятью"], 10),
            (["одиннадцать", "одиннадцати", "одиннадцатью"], 11),
            (["двенадцать", "двенадцати", "двенадцатью"], 12),
            (["тринадцать", "тринадцати", "тринадцатью"], 13),
            (["четырнадцать", "четырнадцати", "четырнадцатью"], 14),
            (["пятнадцать", "пятнадцати", "пятнадцатью"], 15),
            (["шестнадцать", "шестнадцати", "шестнадцатью"], 16),
            (["семнадцать", "семнадцати", "семнадцатью"], 17),
            (["восемнадцать", "восемнадцати", "восемнадцатью"], 18),
            (["девятнадцать", "девятнадцати", "девятнадцатью"], 19),
        ]
        for group in teens {
            for word in group.words { table[word] = (group.value, .teen) }
        }

        let tens: [(words: [String], value: Int)] = [
            (["двадцать", "двадцати", "двадцатью"], 20),
            (["тридцать", "тридцати", "тридцатью"], 30),
            (["сорок", "сорока"], 40),
            (["пятьдесят", "пятидесяти", "пятьюдесятью"], 50),
            (["шестьдесят", "шестидесяти", "шестьюдесятью"], 60),
            (["семьдесят", "семидесяти", "семьюдесятью"], 70),
            (["восемьдесят", "восьмидесяти", "восемьюдесятью"], 80),
            (["девяносто", "девяноста"], 90),
        ]
        for group in tens {
            for word in group.words { table[word] = (group.value, .ten) }
        }

        let hundreds: [(words: [String], value: Int)] = [
            (["сто", "ста"], 100),
            (["двести", "двухсот", "двумстам", "двумястами", "двухстах"], 200),
            (["триста", "трёхсот", "трехсот", "трёмстам", "тремстам", "тремястами", "трёхстах", "трехстах"], 300),
            (["четыреста", "четырёхсот", "четырехсот", "четырёмстам", "четыремстам", "четырьмястами", "четырёхстах", "четырехстах"], 400),
            (["пятьсот", "пятисот", "пятистам", "пятьюстами", "пятистах"], 500),
            (["шестьсот", "шестисот", "шестистам", "шестьюстами", "шестистах"], 600),
            (["семьсот", "семисот", "семистам", "семьюстами", "семистах"], 700),
            (["восемьсот", "восьмисот", "восьмистам", "восемьюстами", "восьмистах"], 800),
            (["девятьсот", "девятисот", "девятистам", "девятьюстами", "девятистах"], 900),
        ]
        for group in hundreds {
            for word in group.words { table[word] = (group.value, .hundred) }
        }

        for word in ["тысяча", "тысячи", "тысяч", "тысячу", "тысяче", "тысячей", "тысячам", "тысячами", "тысячах"] {
            table[word] = (1_000, .thousandMultiplier)
        }
        for word in ["миллион", "миллиона", "миллионов", "миллиону", "миллионом", "миллионе", "миллионам", "миллионами", "миллионах"] {
            table[word] = (1_000_000, .millionMultiplier)
        }

        return table
    }()

    /// Greedily parses as many leading words as form one valid cardinal
    /// number (e.g. ["две", "тысячи", "двадцать", "шесть"] -> 2026, consuming
    /// all 4). Returns nil if `words.first` isn't a recognized number word.
    /// Malformed continuations (e.g. a second hundred-word after one was
    /// already consumed) stop the run rather than erroring — the caller
    /// treats a shorter `consumedWordCount` as "that's as far as the number
    /// goes" and leaves the rest of the sentence untouched.
    static func parseCardinalRun(_ words: [String]) -> (value: Int, consumedWordCount: Int)? {
        guard let first = words.first, let firstEntry = numberWordValues[first] else { return nil }
        _ = firstEntry

        var total = 0
        var currentGroup = 0
        var consumed = 0
        var lastCategory: NumberWordCategory?

        for word in words {
            guard let entry = numberWordValues[word] else { break }

            switch entry.category {
            case .unit, .teen:
                if lastCategory == .unit || lastCategory == .teen { break }
                currentGroup += entry.value
            case .ten:
                if lastCategory == .ten || lastCategory == .unit || lastCategory == .teen { break }
                currentGroup += entry.value
            case .hundred:
                if lastCategory == .hundred || lastCategory == .ten || lastCategory == .unit || lastCategory == .teen { break }
                currentGroup += entry.value
            case .thousandMultiplier, .millionMultiplier:
                if lastCategory == .thousandMultiplier || lastCategory == .millionMultiplier { break }
                let multiplier = entry.category == .thousandMultiplier ? 1_000 : 1_000_000
                let groupValue = currentGroup == 0 ? 1 : currentGroup
                total += groupValue * multiplier
                currentGroup = 0
                lastCategory = entry.category
                consumed += 1
                continue
            }
            lastCategory = entry.category
            consumed += 1
        }

        let finalValue = total + currentGroup
        guard consumed > 0 else { return nil }
        return (finalValue, consumed)
    }

    static func normalize(_ text: String) -> String {
        let tokens = tokenize(text)
        var result = ""
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if case .word(let word) = token, numberWordValues[word.lowercased()] != nil {
                let remainingWords: [String] = tokens[index...].compactMap {
                    if case .word(let w) = $0 { return w.lowercased() }
                    return nil
                }
                if let parsed = parseCardinalRun(remainingWords), isConfidentStandaloneNumber(tokens, at: index, consumedWordTokens: parsed.consumedWordCount) {
                    result += String(parsed.value)
                    index = advance(tokens, from: index, byWordTokenCount: parsed.consumedWordCount)
                    continue
                }
            }
            result += token.rawText
            index += 1
        }
        return result
    }

    /// Guards against converting a bare "one"/"два" that's actually being
    /// used as a pronoun/quantifier ("один из способов" = "one of the
    /// ways") rather than a dictated count. Conservative rule: a
    /// single-word match on `.unit` category is only converted if it's not
    /// immediately followed by "из"/"из-за" (the common "one of ..."
    /// construction); everything else (teens, tens, hundreds, multi-word
    /// runs) is always converted since those are unambiguous.
    private static func isConfidentStandaloneNumber(_ tokens: [Token], at index: Int, consumedWordTokens: Int) -> Bool {
        guard consumedWordTokens == 1,
              case .word(let word) = tokens[index],
              let entry = numberWordValues[word.lowercased()],
              entry.category == .unit else {
            return true
        }
        var lookahead = index + 1
        while lookahead < tokens.count, case .whitespace = tokens[lookahead] {
            lookahead += 1
        }
        guard lookahead < tokens.count, case .word(let next) = tokens[lookahead] else { return true }
        return !["из", "из-за"].contains(next.lowercased())
    }

    private static func advance(_ tokens: [Token], from index: Int, byWordTokenCount count: Int) -> Int {
        var remaining = count
        var cursor = index
        while cursor < tokens.count, remaining > 0 {
            if case .word = tokens[cursor] { remaining -= 1 }
            cursor += 1
        }
        return cursor
    }

    enum Token {
        case word(String)
        case whitespace(String)
        case punctuation(String)

        var rawText: String {
            switch self {
            case .word(let s), .whitespace(let s), .punctuation(let s): return s
            }
        }
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord = false

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(currentIsWord ? .word(current) : .punctuation(current))
            current = ""
        }

        for character in text {
            if character.isWhitespace {
                flush()
                tokens.append(.whitespace(String(character)))
                continue
            }
            let isWordCharacter = character.isLetter || character == "-"
            if current.isEmpty {
                currentIsWord = isWordCharacter
            } else if isWordCharacter != currentIsWord {
                flush()
                currentIsWord = isWordCharacter
            }
            current.append(character)
        }
        flush()
        return tokens
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RussianNumberNormalizerCardinalTests` from `swift/`.
Expected: PASS, all tests green. If any fail on a specific inflected form, fix the table entry (not the parsing logic) — the tests in this task only exercise nominative/accusative forms, so failures here mean a typo in the literal word tables, not an algorithm bug.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/RussianNumberNormalizer.swift swift/Tests/ParakeyTests/RussianNumberNormalizerCardinalTests.swift
git commit -m "Add Russian cardinal-number ITN parser"
```

---

### Task B2: Ordinal number support

**Files:**
- Modify: `swift/Sources/Parakey/RussianNumberNormalizer.swift` (extend, same file/enum from Task B1)
- Test: `swift/Tests/ParakeyTests/RussianNumberNormalizerOrdinalTests.swift`

**Interfaces:**
- Consumes: `numberWordValues`, `NumberWordCategory`, `Token`, `tokenize(_:)` from Task B1.
- Produces: `ordinalWordSuffixes: [String: (value: Int, digitSuffix: String)]` (maps a literal ordinal wordform, e.g. `"пятого"`, to its base value `5` and the short digit-notation suffix to render, e.g. `"-го"`) and `parseOrdinalRun(_ words: [String]) -> (value: Int, digitSuffix: String, consumedWordCount: Int)?`, which reuses `parseCardinalRun` for every word except the last (compound Russian ordinals only inflect their final word — "двадцать пятый", not "двадцатый пятый") and matches the last word against `ordinalWordSuffixes`.

- [ ] **Step 1: Write the failing ordinal tests**

```swift
import XCTest
@testable import Parakey

final class RussianNumberNormalizerOrdinalTests: XCTestCase {
    func test_simpleOrdinal() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("пятый"), "5-й")
        XCTAssertEqual(RussianNumberNormalizer.normalize("третий"), "3-й")
    }

    func test_compoundOrdinalOnlyLastWordInflects() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("двадцать пятый"), "25-й")
        XCTAssertEqual(RussianNumberNormalizer.normalize("двадцать пятого"), "25-го")
        XCTAssertEqual(RussianNumberNormalizer.normalize("двадцать пятое"), "25-е")
    }

    func test_ordinalInSentence() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("это был двадцать пятый раз"), "это был 25-й раз")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter RussianNumberNormalizerOrdinalTests` from `swift/`.
Expected: FAIL — `parseOrdinalRun`/`ordinalWordSuffixes` don't exist yet, so ordinal words fall through `normalize` unconverted.

- [ ] **Step 3: Add the ordinal table and parser, and wire it into `normalize`**

Add to `RussianNumberNormalizer` (same file):

```swift
    static let ordinalWordSuffixes: [String: (value: Int, digitSuffix: String)] = {
        var table: [String: (value: Int, digitSuffix: String)] = [:]

        // (value, [(wordform, digitSuffix)]) — units 1-3 are irregular
        // stems; 4-10 follow the regular "cardinal-derived stem + ending"
        // pattern. Endings covered: -ый/-ой (masc nom), -ое (neut nom),
        // -ая (fem nom), -ого (masc/neut gen), -ому (dat), -ым (instr),
        // -ом (prep).
        let entries: [(value: Int, forms: [(word: String, suffix: String)])] = [
            (1, [("первый", "-й"), ("первое", "-е"), ("первая", "-я"), ("первого", "-го"), ("первому", "-му"), ("первым", "-м"), ("первом", "-м")]),
            (2, [("второй", "-й"), ("второе", "-е"), ("вторая", "-я"), ("второго", "-го"), ("второму", "-му"), ("вторым", "-м"), ("втором", "-м")]),
            (3, [("третий", "-й"), ("третье", "-е"), ("третья", "-я"), ("третьего", "-го"), ("третьему", "-му"), ("третьим", "-м"), ("третьем", "-м")]),
            (4, [("четвёртый", "-й"), ("четвертый", "-й"), ("четвёртое", "-е"), ("четвертое", "-е"), ("четвёртая", "-я"), ("четвертая", "-я"), ("четвёртого", "-го"), ("четвертого", "-го"), ("четвёртому", "-му"), ("четвертому", "-му"), ("четвёртым", "-м"), ("четвертым", "-м"), ("четвёртом", "-м"), ("четвертом", "-м")]),
            (5, [("пятый", "-й"), ("пятое", "-е"), ("пятая", "-я"), ("пятого", "-го"), ("пятому", "-му"), ("пятым", "-м"), ("пятом", "-м")]),
            (6, [("шестой", "-й"), ("шестое", "-е"), ("шестая", "-я"), ("шестого", "-го"), ("шестому", "-му"), ("шестым", "-м"), ("шестом", "-м")]),
            (7, [("седьмой", "-й"), ("седьмое", "-е"), ("седьмая", "-я"), ("седьмого", "-го"), ("седьмому", "-му"), ("седьмым", "-м"), ("седьмом", "-м")]),
            (8, [("восьмой", "-й"), ("восьмое", "-е"), ("восьмая", "-я"), ("восьмого", "-го"), ("восьмому", "-му"), ("восьмым", "-м"), ("восьмом", "-м")]),
            (9, [("девятый", "-й"), ("девятое", "-е"), ("девятая", "-я"), ("девятого", "-го"), ("девятому", "-му"), ("девятым", "-м"), ("девятом", "-м")]),
            (10, [("десятый", "-й"), ("десятое", "-е"), ("десятая", "-я"), ("десятого", "-го"), ("десятому", "-му"), ("десятым", "-м"), ("десятом", "-м")]),
            (20, [("двадцатый", "-й"), ("двадцатое", "-е"), ("двадцатая", "-я"), ("двадцатого", "-го"), ("двадцатому", "-му"), ("двадцатым", "-м"), ("двадцатом", "-м")]),
            (30, [("тридцатый", "-й"), ("тридцатое", "-е"), ("тридцатая", "-я"), ("тридцатого", "-го"), ("тридцатому", "-му"), ("тридцатым", "-м"), ("тридцатом", "-м")]),
        ]
        for entry in entries {
            for form in entry.forms {
                table[form.word] = (entry.value, form.suffix)
            }
        }
        return table
    }()

    static func parseOrdinalRun(_ words: [String]) -> (value: Int, digitSuffix: String, consumedWordCount: Int)? {
        guard !words.isEmpty else { return nil }

        // Find the longest prefix (all but a trailing ordinal word) that
        // parses as a cardinal run, then require the very next word to be
        // a recognized ordinal wordform. Try shrinking the prefix from the
        // full remaining span down to zero so "двадцать пятый" (prefix
        // "двадцать" + ordinal "пятый") and "пятый" alone (empty prefix)
        // both work.
        var prefixLength = words.count - 1
        while prefixLength >= 0 {
            let prefixWords = Array(words[0..<prefixLength])
            let prefixValue: Int
            if prefixWords.isEmpty {
                prefixValue = 0
            } else if let parsed = parseCardinalRun(prefixWords), parsed.consumedWordCount == prefixWords.count {
                prefixValue = parsed.value
            } else {
                prefixLength -= 1
                continue
            }

            guard prefixLength < words.count, let ordinalEntry = ordinalWordSuffixes[words[prefixLength]] else {
                prefixLength -= 1
                continue
            }
            return (prefixValue + ordinalEntry.value, ordinalEntry.digitSuffix, prefixLength + 1)
        }
        return nil
    }
```

Then in `normalize(_:)`, before the existing cardinal-run check inside the `while` loop, try the ordinal parse first (an ordinal match is always at least as long as the cardinal match for the same starting word, since it consumes the same prefix plus the ordinal word itself):

```swift
            if case .word(let word) = token,
               (numberWordValues[word.lowercased()] != nil || ordinalWordSuffixes[word.lowercased()] != nil) {
                let remainingWords: [String] = tokens[index...].compactMap {
                    if case .word(let w) = $0 { return w.lowercased() }
                    return nil
                }
                if let ordinal = parseOrdinalRun(remainingWords) {
                    result += "\(ordinal.value)\(ordinal.digitSuffix)"
                    index = advance(tokens, from: index, byWordTokenCount: ordinal.consumedWordCount)
                    continue
                }
                if let parsed = parseCardinalRun(remainingWords), isConfidentStandaloneNumber(tokens, at: index, consumedWordTokens: parsed.consumedWordCount) {
                    result += String(parsed.value)
                    index = advance(tokens, from: index, byWordTokenCount: parsed.consumedWordCount)
                    continue
                }
            }
```

(This replaces the equivalent `if case .word(let word) = token, numberWordValues[...] ...` block from Task B1 — same `while` loop, just the condition and the added ordinal branch.)

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter RussianNumberNormalizerOrdinalTests` from `swift/`.
Expected: PASS, all 3 tests green.

- [ ] **Step 5: Re-run Task B1's cardinal tests to confirm no regression**

Run: `swift test --filter RussianNumberNormalizerCardinalTests` from `swift/`.
Expected: PASS, all still green (ordinal parsing must not have broken plain cardinal conversion).

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/Parakey/RussianNumberNormalizer.swift swift/Tests/ParakeyTests/RussianNumberNormalizerOrdinalTests.swift
git commit -m "Add Russian ordinal-number ITN support"
```

---

### Task B3: Date and money context recognizers

**Files:**
- Modify: `swift/Sources/Parakey/RussianNumberNormalizer.swift` (extend, same file)
- Test: `swift/Tests/ParakeyTests/RussianNumberNormalizerContextTests.swift`

**Interfaces:**
- Consumes: `parseOrdinalRun`, `parseCardinalRun`, `Token`, `tokenize(_:)` from Tasks B1/B2.
- Produces: no new public API — these are internal refinements layered into `normalize(_:)`'s existing word-scanning loop. Money/date phrases are recognized as a *side effect* of the existing cardinal/ordinal parsing already converting each numeral run — this task only adds the trailing context words (`месяц`/currency names) to a lookup so they're recognized as valid sentence content around a converted number (they already pass through unchanged as plain words; verify this with tests rather than adding new branching logic).

- [ ] **Step 1: Write the failing context tests**

```swift
import XCTest
@testable import Parakey

final class RussianNumberNormalizerContextTests: XCTestCase {
    func test_dateWithOrdinalDayAndCardinalYear() {
        XCTAssertEqual(
            RussianNumberNormalizer.normalize("двадцать девятое июля две тысячи двадцать шестого года"),
            "29-е июля 2026-го года"
        )
    }

    func test_moneyPhrase() {
        XCTAssertEqual(RussianNumberNormalizer.normalize("пятьсот рублей"), "500 рублей")
        XCTAssertEqual(RussianNumberNormalizer.normalize("сто долларов"), "100 долларов")
    }

    func test_moneyAmountWithCompoundNumber() {
        XCTAssertEqual(
            RussianNumberNormalizer.normalize("это стоит две тысячи пятьсот рублей"),
            "это стоит 2500 рублей"
        )
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail (or pass) and diagnose accordingly**

Run: `swift test --filter RussianNumberNormalizerContextTests` from `swift/`.
Expected: the date test and compound-money test should already PASS if Tasks B1/B2 are correctly composing (a date/money phrase is just cardinal/ordinal runs with ordinary words around them). If they FAIL, the failure will point at whichever specific word wasn't tokenized/converted as expected — treat any failure here as a bug in B1/B2's tables (e.g. a missing "года"/"рублей" is NOT a number word and should never appear in `numberWordValues`; if it does, remove it) rather than adding new date/money-specific parsing logic.

- [ ] **Step 3: Fix any failures found in Step 2**

If a currency or date word (e.g. "года", "рублей", "июля") was accidentally added to `numberWordValues` or `ordinalWordSuffixes` in a prior task, remove it — these are plain context words, not numerals, and must pass through `normalize` unchanged via the existing "not a recognized number word" fallback path.

If instead a genuine number word is failing to combine correctly across the `тысячи ... года` boundary, fix the specific bug in `parseCardinalRun`'s group-boundary logic (Task B1) — do not add special-case date logic.

- [ ] **Step 4: Run the full normalizer test suite**

Run: `swift test --filter RussianNumberNormalizer` from `swift/`.
Expected: PASS across all three test files (Cardinal, Ordinal, Context).

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/RussianNumberNormalizer.swift swift/Tests/ParakeyTests/RussianNumberNormalizerContextTests.swift
git commit -m "Verify Russian ITN composes correctly for dates and money phrases"
```

---

### Task B4: Settings flag, Control Panel toggle, and pipeline wiring

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`:
  - `Settings` class: add key constant near main.swift:2821 and computed property near main.swift:3466-3468
  - `processedDictationText` (main.swift:6325-6343): add the new stage
  - `ControlPanelSettingsDraft` (main.swift:21958-21985): add field
  - `makeSettingsContentView` (main.swift:22239+): add row
  - New row-building function, modeled on `alternateCompletionRow` (main.swift:23012-23062)
  - New `@objc` toggle handler, modeled on `toggleAlternateCompletion` (main.swift:23708-23713)
  - `saveSettingsClicked` (main.swift:23773-23789): persist the new draft field
- Test: `swift/Tests/ParakeyTests/ProcessedDictationTextITNTests.swift`

**Interfaces:**
- Consumes: `RussianNumberNormalizer.normalize(_:) -> String` from Tasks B1-B3.
- Produces: `Settings.normalizeNumbersToDigits: Bool` and an extra `normalizeNumbersToDigits: Bool` parameter on `processedDictationText`, defaulted to `false` so the three existing call sites (main.swift:10869, 12392, 12596) keep compiling — update each to pass `settings.normalizeNumbersToDigits` explicitly rather than relying on the default, since the default only exists for source compatibility with the test call sites at main.swift:20888-20937 that don't care about this flag.

- [ ] **Step 1: Write the failing pipeline test**

```swift
import XCTest
@testable import Parakey

final class ProcessedDictationTextITNTests: XCTestCase {
    func test_normalizesNumbersWhenEnabled() {
        let result = processedDictationText(
            rawTranscript: "мне двадцать пять лет",
            corrections: [],
            removeFillerWords: false,
            normalizeNumbersToDigits: true,
            language: .russian
        )
        XCTAssertEqual(result.text, "мне 25 лет")
    }

    func test_leavesNumbersAsWordsWhenDisabled() {
        let result = processedDictationText(
            rawTranscript: "мне двадцать пять лет",
            corrections: [],
            removeFillerWords: false,
            normalizeNumbersToDigits: false,
            language: .russian
        )
        XCTAssertEqual(result.text, "мне двадцать пять лет")
    }

    func test_itnRunsBeforeUserCorrections() {
        let correction = TranscriptCorrection(source: "25 лет", replacement: "25 years old")
        let result = processedDictationText(
            rawTranscript: "мне двадцать пять лет",
            corrections: [correction],
            removeFillerWords: false,
            normalizeNumbersToDigits: true,
            language: .russian
        )
        XCTAssertEqual(result.text, "мне 25 years old")
    }
}
```

(If `TranscriptCorrection`'s actual initializer differs from `TranscriptCorrection(source:replacement:)`, check its declaration near `TranscriptCorrector` (main.swift:6079) and adjust the test to match the real initializer — do not guess at unrelated fields.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ProcessedDictationTextITNTests` from `swift/`.
Expected: FAIL — `processedDictationText` doesn't accept a `normalizeNumbersToDigits` parameter yet.

- [ ] **Step 3: Add the settings key**

Near main.swift:2821 (alongside `keyRemoveFillerWords`):

```swift
    private static let keyNormalizeNumbersToDigits = "normalize_numbers_to_digits"
```

Near main.swift:3466-3468 (alongside `removeFillerWords`):

```swift
    var normalizeNumbersToDigits: Bool {
        get { defaults.bool(forKey: Self.keyNormalizeNumbersToDigits) }
        set { defaults.set(newValue, forKey: Self.keyNormalizeNumbersToDigits) }
    }
```

- [ ] **Step 4: Wire the normalizer into `processedDictationText`**

Replace main.swift:6325-6343 with:

```swift
private func processedDictationText(rawTranscript: String,
                                    corrections: [TranscriptCorrection],
                                    removeFillerWords: Bool,
                                    normalizeNumbersToDigits: Bool = false,
                                    language: DictationLanguage = .auto) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = ParakeetTranscriptRepair.apply(to: trimmed, language: language)

    let numberNormalized: String
    switch language {
    case .auto, .russian:
        numberNormalized = normalizeNumbersToDigits ? RussianNumberNormalizer.normalize(repaired) : repaired
    default:
        numberNormalized = repaired
    }

    let corrected = TranscriptCorrector.apply(to: numberNormalized, corrections: corrections)

    guard removeFillerWords else {
        return DictationTextProcessingResult(text: corrected.text,
                                             appliedCorrectionCount: corrected.appliedCount,
                                             removedFillerWordCount: 0)
    }

    let stripped = FillerWordRemover.apply(to: corrected.text)
    return DictationTextProcessingResult(text: stripped.text,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         removedFillerWordCount: stripped.removedCount)
}
```

- [ ] **Step 5: Update the three production call sites**

At main.swift:10869, 12392, 12596 (each currently passes `removeFillerWords: settings.removeFillerWords,`), add immediately after it:

```swift
                                                       normalizeNumbersToDigits: settings.normalizeNumbersToDigits,
```

(Check each call site's actual surrounding argument list/indentation before editing — these three are independent call sites in different functions, not one shared block.)

- [ ] **Step 6: Run the pipeline tests to verify they pass**

Run: `swift test --filter ProcessedDictationTextITNTests` from `swift/`.
Expected: PASS, all 3 tests green.

- [ ] **Step 7: Add the Control Panel toggle — draft field**

In `ControlPanelSettingsDraft` (main.swift:21958-21985), add:

```swift
    var normalizeNumbersToDigits: Bool
```

and in its `init(settings:)`:

```swift
        normalizeNumbersToDigits = settings.normalizeNumbersToDigits
```

- [ ] **Step 8: Add the row-building function**

Modeled on `alternateCompletionRow` (main.swift:23012-23062), add a new function in the same area:

```swift
    private func normalizeNumbersRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            t("Числа цифрами", "Numbers as digits"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Записывать продиктованные числа цифрами (25) вместо слов (двадцать пять). Только для русского языка.",
              "Write dictated numbers as digits (25) instead of words (twenty five). Russian only."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleNormalizeNumbers(_:))
        toggle.state = draft.normalizeNumbersToDigits ? .on : .off
        toggle.toolTip = t("Включить преобразование чисел в цифры.",
                           "Enable converting numbers to digits.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        return row
    }
```

Add the call to it in `makeSettingsContentView` (main.swift:22258, right after `root.addArrangedSubview(alternateCompletionRow(draft))`):

```swift
        root.addArrangedSubview(normalizeNumbersRow(draft))
```

- [ ] **Step 9: Add the toggle handler**

Modeled on `toggleAlternateCompletion` (main.swift:23708-23713), add:

```swift
    @objc private func toggleNormalizeNumbers(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.normalizeNumbersToDigits = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }
```

- [ ] **Step 10: Persist the draft on save**

In `saveSettingsClicked` (main.swift:23773-23789), add alongside the other `settings.x = draft.x` lines:

```swift
        settings.normalizeNumbersToDigits = draft.normalizeNumbersToDigits
```

- [ ] **Step 11: Build the whole app target to confirm no compile errors**

Run: `swift build` from `swift/`.
Expected: builds cleanly — this touches many call sites across a 24k-line file, so a full build (not just `swift test`) is the only way to catch a missed call site or signature mismatch.

- [ ] **Step 12: Run the full test suite**

Run: `swift test` from `swift/`.
Expected: PASS, no regressions anywhere (including Part A's tests and the pre-existing suite).

- [ ] **Step 13: Manual verification**

Launch the app (see this repo's own run instructions/skill if one exists), open the Control Panel, confirm the new "Числа цифрами" toggle appears, toggle it on, dictate a phrase containing a number, and confirm it's inserted as digits; toggle it off and confirm it reverts to word form.

- [ ] **Step 14: Commit**

```bash
git add swift/Sources/Parakey/main.swift swift/Tests/ParakeyTests/ProcessedDictationTextITNTests.swift
git commit -m "Add Control Panel toggle to render dictated numbers as digits"
```
