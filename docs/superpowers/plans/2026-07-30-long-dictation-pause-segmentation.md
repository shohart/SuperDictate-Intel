# Pause-Based Long-Dictation Segmentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop long dictations from hanging/vanishing by splitting the captured audio into pause-bounded segments before sending it to Parakeet, and by never silently discarding a recording when the transcript comes back empty.

**Architecture:** A new pure, dependency-free `PauseSegmenter` splits a captured `[Float]` PCM buffer into `AudioSegment`s along natural silence gaps (never mid-phrase), capped at a safe duration well under the empirically-confirmed danger zone. A new pure `transcribeSegments` orchestrator feeds each segment through the existing single-shot ASR call in order, retries an unexpectedly-empty *non-silent* segment once, and reports whether any segment ultimately failed. `main.swift`'s three call sites that invoke ASR (hotkey release, non-standard-termination recovery, startup pending-dictation recovery) are rewired to go through this orchestrator instead of a single whole-buffer call, and their empty-result handling is changed to retain the recovery audio and signal a visible failure instead of silently deleting it.

**Tech Stack:** Swift 6 (SwiftPM), existing `TranscriptionWorker`/`ParakeetEngine` (no changes to the C/C++ bridge or vendored `parakeet.cpp`), existing `--self-test` harness (`#if DEBUG`-gated, see `main.swift:16931`/`22807`).

## Global Constraints

- Root-caused and approved design: `docs/superpowers/specs/2026-07-30-long-dictation-pause-segmentation-design.md`. Follow it; this plan implements it task-by-task.
- Do **not** modify `swift/Sources/parakeet_cpp/**` (vendored, commit-pinned upstream) — the fix is entirely on the Swift side.
- Do **not** implement fixed-time chunking — cuts must only happen at detected silence, or as a last-resort forced cut at the safety cap (25s) when no pause is found in time.
- Safety cap: 25 seconds per segment (`PauseSegmenter.defaultMaxSegmentSeconds`).
- Pause qualification: a silent run of at least 0.4 seconds (`PauseSegmenter.defaultPauseThresholdSeconds`), and the current segment must already hold at least 15 seconds (`PauseSegmenter.defaultMinSegmentSeconds`) before a pause is allowed to end it — keeps ordinary short dictations (which have plenty of normal inter-sentence pauses) as a single ASR call, so only genuinely long dictations are ever split.
- All builds/tests run on the real Intel Mac used throughout this project (`shohart@192.168.1.246`), synced via `git archive HEAD | ssh ... tar -x` into a scratch directory — never `git clone`. This matches the workflow already used earlier in this session and documented project-wide.
- `SAMPLE_RATE` is `16_000.0` (`main.swift:41`) — all new code takes sample rate as a parameter rather than hardcoding it, but production call sites always pass `SAMPLE_RATE`.
- New Swift files go under `swift/Sources/Parakey/` (same target as `main.swift`, so `internal` default access is sufficient — no `public` needed).
- Self-tests are added under the existing `#if DEBUG` `ParakeySelfTest` harness in `main.swift` (lines ~16931-22807) following its established `case "<name>": return runSuite("<name>", testX)` / `try testX()` in `testAll()` pattern.

---

### Task 1: `PauseSegmenter` — pure pause-detection and segmentation algorithm

**Files:**
- Create: `swift/Sources/Parakey/PauseSegmenter.swift`
- Test: self-test group `pause-segmentation` added to `swift/Sources/Parakey/main.swift` (inside the existing `#if DEBUG` `ParakeySelfTest` block)

**Interfaces:**
- Produces: `struct AudioSegment: Sendable, Equatable { let samples: [Float]; let hasSignal: Bool }` and `enum PauseSegmenter { static func segment(samples: [Float], sampleRate: Double, maxSegmentSeconds: Double = 25.0, minSegmentSeconds: Double = 15.0, pauseThresholdSeconds: Double = 0.4, windowSeconds: Double = 0.02, silenceRMSThreshold: Float = 0.02) -> [AudioSegment] }` — consumed by Task 2 and Task 3.

- [ ] **Step 1: Write `PauseSegmenter.swift`**

```swift
import Foundation

/// One contiguous slice of a captured recording, produced by
/// `PauseSegmenter.segment(...)`. `hasSignal` is true iff at least one
/// analysis window inside this segment was NOT judged silent — used
/// downstream (see `SegmentedTranscription.swift`) to tell "the model
/// returned nothing because this really was silence" apart from "the
/// model returned nothing despite real speech being present," which is
/// the failure mode this whole feature exists to catch.
struct AudioSegment: Sendable, Equatable {
    let samples: [Float]
    let hasSignal: Bool
}

/// Splits a captured mono PCM buffer into segments cut only at natural
/// pauses in speech (never mid-phrase), with a hard safety cap so a
/// single unbroken run of speech can't grow long enough to hit the
/// Parakeet encoder's superlinear-cost regime (see
/// docs/superpowers/specs/2026-07-30-long-dictation-pause-segmentation-design.md).
/// Pure and synchronous — no I/O, no audio-hardware or model dependency,
/// safe to unit test directly.
enum PauseSegmenter {
    static let defaultMaxSegmentSeconds: Double = 25.0
    static let defaultMinSegmentSeconds: Double = 3.0
    static let defaultPauseThresholdSeconds: Double = 0.4
    static let defaultWindowSeconds: Double = 0.02
    static let defaultSilenceRMSThreshold: Float = 0.02

    static func segment(
        samples: [Float],
        sampleRate: Double,
        maxSegmentSeconds: Double = defaultMaxSegmentSeconds,
        minSegmentSeconds: Double = defaultMinSegmentSeconds,
        pauseThresholdSeconds: Double = defaultPauseThresholdSeconds,
        windowSeconds: Double = defaultWindowSeconds,
        silenceRMSThreshold: Float = defaultSilenceRMSThreshold
    ) -> [AudioSegment] {
        guard !samples.isEmpty else { return [] }

        let windowSize = max(1, Int(windowSeconds * sampleRate))
        let maxSegmentSamples = max(windowSize, Int(maxSegmentSeconds * sampleRate))
        let minSegmentSamples = max(0, Int(minSegmentSeconds * sampleRate))
        let pauseWindowCount = max(1, Int((pauseThresholdSeconds / windowSeconds).rounded()))

        // Per-window silence flags across the whole buffer, computed once
        // up front so both the cut logic and the later hasSignal check can
        // reuse them without recomputing RMS.
        var windowIsSilent: [Bool] = []
        windowIsSilent.reserveCapacity(samples.count / windowSize + 1)
        var scanOffset = 0
        while scanOffset < samples.count {
            let end = min(scanOffset + windowSize, samples.count)
            var sumSquares: Double = 0
            for i in scanOffset..<end {
                let v = Double(samples[i])
                sumSquares += v * v
            }
            let rms = Float(sqrt(sumSquares / Double(end - scanOffset)))
            windowIsSilent.append(rms < silenceRMSThreshold)
            scanOffset = end
        }

        func sampleIndex(forWindow w: Int) -> Int { w * windowSize }

        func allWindowsSilent(in range: Range<Int>) -> Bool {
            guard range.lowerBound < range.upperBound else { return true }
            let startWindow = range.lowerBound / windowSize
            let endWindow = min(windowIsSilent.count, (range.upperBound + windowSize - 1) / windowSize)
            guard startWindow < endWindow else { return true }
            return windowIsSilent[startWindow..<endWindow].allSatisfy { $0 }
        }

        var segments: [AudioSegment] = []
        var segmentStartSample = 0

        func makeSegment(endSample: Int) {
            let end = min(endSample, samples.count)
            guard end > segmentStartSample else { return }
            let range = segmentStartSample..<end
            segments.append(AudioSegment(samples: Array(samples[range]),
                                         hasSignal: !allWindowsSilent(in: range)))
            segmentStartSample = end
        }

        var windowIndex = 0
        var silentRunStart: Int?

        while windowIndex < windowIsSilent.count {
            if windowIsSilent[windowIndex] {
                if silentRunStart == nil { silentRunStart = windowIndex }
            } else {
                silentRunStart = nil
            }

            let currentSegmentLength = sampleIndex(forWindow: windowIndex + 1) - segmentStartSample

            if let runStart = silentRunStart,
               (windowIndex - runStart + 1) >= pauseWindowCount,
               currentSegmentLength >= minSegmentSamples {
                // A long-enough pause, and the segment so far is already
                // substantial — cut at the START of the silent run so the
                // pause itself doesn't get glued onto either segment.
                makeSegment(endSample: sampleIndex(forWindow: runStart))
                silentRunStart = nil
            } else if currentSegmentLength >= maxSegmentSamples {
                // No qualifying pause arrived before the safety cap — force
                // a cut here so a single unbroken run of speech can never
                // exceed the cap.
                makeSegment(endSample: sampleIndex(forWindow: windowIndex + 1))
                silentRunStart = nil
            }

            windowIndex += 1
        }

        makeSegment(endSample: samples.count)
        return segments
    }
}
```

- [ ] **Step 2: Add the self-test group to `main.swift`**

Find the `switch arguments[1] {` block inside `private enum ParakeySelfTest` (`main.swift:16947`) and add a new case near the other `parakeet-*` cases (after the `case "parakeet-bridge":` line, `main.swift:~17004`):

```swift
        case "pause-segmentation":
            return runSuite("pause-segmentation", testPauseSegmentation)
```

Add `try testPauseSegmentation()` to `testAll()` (`main.swift:17047-17081`), next to `try testParakeetBridge()`.

Add the test function itself near `testParakeetBridge` (search for `private static func testParakeetBridge`) — insert a new function right after it:

```swift
    /// Pure algorithm coverage for `PauseSegmenter.segment` — no model, no
    /// audio hardware. Every case asserts the coverage invariant (segments
    /// exactly tile the input, no samples dropped or duplicated) plus the
    /// specific behavior under test.
    private static func testPauseSegmentation() throws {
        let sampleRate = 16_000.0

        // Empty input -> no segments.
        try expect(PauseSegmenter.segment(samples: [], sampleRate: sampleRate).count,
                   equals: 0, "empty input produces zero segments")

        // Short, uninterrupted "speech" (no silence anywhere) well under
        // both the min and max thresholds -> exactly one segment, and nothing
        // is dropped.
        let shortSpeech = [Float](repeating: 0.2, count: Int(2.0 * sampleRate))
        let shortSegments = PauseSegmenter.segment(samples: shortSpeech, sampleRate: sampleRate)
        try expect(shortSegments.count, equals: 1, "short uninterrupted speech stays a single segment")
        try expect(shortSegments.reduce(0) { $0 + $1.samples.count }, equals: shortSpeech.count,
                   "single-segment case preserves every sample")
        try expect(shortSegments[0].hasSignal, equals: true, "non-silent audio is flagged as having signal")

        // Continuous non-silent audio longer than the safety cap -> forced
        // cuts, no segment exceeds the cap, and total sample count is
        // preserved exactly (coverage invariant).
        let longSpeech = [Float](repeating: 0.2, count: Int(70.0 * sampleRate))
        let longSegments = PauseSegmenter.segment(samples: longSpeech, sampleRate: sampleRate,
                                                   maxSegmentSeconds: 25.0)
        try expect(longSegments.count >= 3, equals: true,
                   "70s of unbroken speech with a 25s cap forces at least 3 segments")
        let maxAllowedSamples = Int(25.0 * sampleRate)
        for seg in longSegments {
            try expect(seg.samples.count <= maxAllowedSamples, equals: true,
                       "no forced segment exceeds the safety cap")
        }
        try expect(longSegments.reduce(0) { $0 + $1.samples.count }, equals: longSpeech.count,
                   "forced-cut segments cover the whole buffer with no gaps or overlap")

        // A qualifying pause (600ms of silence) placed after 5s of speech,
        // followed by 5 more seconds of speech -> exactly two segments,
        // split at the pause, nothing dropped.
        var withPause = [Float](repeating: 0.2, count: Int(5.0 * sampleRate))
        withPause.append(contentsOf: [Float](repeating: 0.0, count: Int(0.6 * sampleRate)))
        withPause.append(contentsOf: [Float](repeating: 0.2, count: Int(5.0 * sampleRate)))
        let pausedSegments = PauseSegmenter.segment(samples: withPause, sampleRate: sampleRate)
        try expect(pausedSegments.count, equals: 2, "a qualifying pause after the minimum splits into two segments")
        try expect(pausedSegments.reduce(0) { $0 + $1.samples.count }, equals: withPause.count,
                   "pause-split segments cover the whole buffer with no gaps or overlap")

        // A pause before the minimum segment length is NOT a
        // qualifying cut point -> stays a single segment.
        var earlyPause = [Float](repeating: 0.2, count: Int(1.0 * sampleRate))
        earlyPause.append(contentsOf: [Float](repeating: 0.0, count: Int(0.6 * sampleRate)))
        earlyPause.append(contentsOf: [Float](repeating: 0.2, count: Int(1.0 * sampleRate)))
        let earlyPauseSegments = PauseSegmenter.segment(samples: earlyPause, sampleRate: sampleRate)
        try expect(earlyPauseSegments.count, equals: 1,
                   "a pause before the minimum segment length is not a qualifying cut point")

        // All-silent buffer -> a single segment flagged as having no signal.
        let silence = [Float](repeating: 0.0, count: Int(4.0 * sampleRate))
        let silentSegments = PauseSegmenter.segment(samples: silence, sampleRate: sampleRate)
        try expect(silentSegments.count, equals: 1, "an all-silent buffer stays a single segment")
        try expect(silentSegments[0].hasSignal, equals: false, "an all-silent segment is flagged as having no signal")
    }
```

- [ ] **Step 3: Run the new self-test on the Mac**

Sync and run (same pattern used throughout this project):

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-impl && mkdir -p ~/scratch/sd-impl && tar -x -C ~/scratch/sd-impl'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && swift run -c debug --package-path . Parakey --self-test pause-segmentation'
```

Expected: `PASS pause-segmentation`.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/PauseSegmenter.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add PauseSegmenter: pure pause-detection audio segmentation

Splits a captured PCM buffer into segments cut only at natural speech
pauses (never mid-phrase), capped at 25s so a single ASR call can never
grow long enough to hit the Parakeet encoder's confirmed superlinear
cost blowup on continuous audio. First piece of
docs/superpowers/specs/2026-07-30-long-dictation-pause-segmentation-design.md.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `transcribeSegments` — retry/concatenation orchestrator

**Files:**
- Create: `swift/Sources/Parakey/SegmentedTranscription.swift`
- Test: self-test group `segmented-transcription` added to `main.swift`

**Interfaces:**
- Consumes: `AudioSegment` (Task 1).
- Produces: `struct SegmentedTranscriptionOutcome: Sendable { let text: String; let hadSegmentFailure: Bool }` and `func transcribeSegments(_ segments: [AudioSegment], transcribeOne: (_ samples: [Float]) async throws -> String) async -> SegmentedTranscriptionOutcome` — consumed by Task 3.

- [ ] **Step 1: Write `SegmentedTranscription.swift`**

```swift
import Foundation

/// Result of running every segment of a (possibly multi-segment) dictation
/// through ASR. `hadSegmentFailure` is true iff at least one segment that
/// DID contain real signal (`AudioSegment.hasSignal == true`) still came
/// back empty after a retry — i.e., a genuine loss, as opposed to a
/// segment that was legitimately silent.
struct SegmentedTranscriptionOutcome: Sendable {
    let text: String
    let hadSegmentFailure: Bool
}

/// Transcribes each segment in order through `transcribeOne`, retrying a
/// segment exactly once if it comes back empty AND it was flagged as
/// having real signal (an all-silent segment returning empty text is
/// expected, not a failure, and is not retried). A segment whose
/// `transcribeOne` call throws is treated the same as an empty result for
/// retry/failure purposes — one segment failing (by throwing or by
/// returning nothing) never discards text already produced by earlier
/// segments.
///
/// Pure orchestration: takes no dependency on `TranscriptionWorker` or any
/// other production type, so it's fully testable with a mock closure.
func transcribeSegments(
    _ segments: [AudioSegment],
    transcribeOne: (_ samples: [Float]) async throws -> String
) async -> SegmentedTranscriptionOutcome {
    var pieces: [String] = []
    var hadFailure = false

    for segment in segments {
        var text = (try? await transcribeOne(segment.samples)) ?? ""
        if text.isEmpty && segment.hasSignal {
            text = (try? await transcribeOne(segment.samples)) ?? ""
        }
        if text.isEmpty {
            if segment.hasSignal { hadFailure = true }
        } else {
            pieces.append(text)
        }
    }

    return SegmentedTranscriptionOutcome(text: pieces.joined(separator: " "), hadSegmentFailure: hadFailure)
}
```

- [ ] **Step 2: Add the self-test group to `main.swift`**

Add the case (next to `pause-segmentation` added in Task 1):

```swift
        case "segmented-transcription":
            return runSuite("segmented-transcription", testSegmentedTranscription)
```

Add `try testSegmentedTranscription()` to `testAll()`, next to `try testPauseSegmentation()`.

Add the test function next to `testPauseSegmentation`. `ParakeySelfTest.run(arguments:)` is synchronous (`main.swift:16943`, `-> Int32?`, no `async`), so — matching this file's established pattern for calling `async` code from a synchronous self-test (see `runParakeetEngineSynchronously`, `main.swift:20981`, used by `testParakeetCPUIntegration` and others) — bridge through that same helper instead of making this test function `async`. Each mock `transcribeOne` closure below needs a mutable call counter; matching the file's existing justification for `ParakeetSyncBridgeBox`'s `@unchecked Sendable` (single-writer-before-semaphore-signal, single-reader-after-wait — no real concurrent access), mark each counter `nonisolated(unsafe)`:

```swift
    /// Pure orchestration coverage for `transcribeSegments` using a mock
    /// `transcribeOne` closure — no model, no engine, no audio hardware.
    /// Bridged through `runParakeetEngineSynchronously` since this test
    /// suite's entry point is synchronous (see that helper's doc comment).
    private static func testSegmentedTranscription() throws {
        // All segments succeed on the first try -> concatenated with a
        // single space, no failure flagged.
        let allOk: [AudioSegment] = [
            AudioSegment(samples: [0.1], hasSignal: true),
            AudioSegment(samples: [0.1], hasSignal: true),
        ]
        nonisolated(unsafe) var callIndex = 0
        let okTexts = ["hello", "world"]
        let okOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(allOk) { _ in
                defer { callIndex += 1 }
                return okTexts[callIndex]
            }
        }
        try expect(okOutcome.text, equals: "hello world", "successful segments are joined with a space")
        try expect(okOutcome.hadSegmentFailure, equals: false, "no failure flagged when every segment succeeds")

        // A signal-bearing segment that returns empty on the first call but
        // real text on the retry -> succeeds, no failure flagged, and the
        // closure was actually called twice for that segment.
        let retrySucceeds: [AudioSegment] = [AudioSegment(samples: [0.1], hasSignal: true)]
        nonisolated(unsafe) var retryCallCount = 0
        let retryOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(retrySucceeds) { _ in
                retryCallCount += 1
                return retryCallCount == 1 ? "" : "recovered"
            }
        }
        try expect(retryCallCount, equals: 2, "an empty signal-bearing segment is retried exactly once")
        try expect(retryOutcome.text, equals: "recovered", "a successful retry contributes its text")
        try expect(retryOutcome.hadSegmentFailure, equals: false, "a retry that succeeds is not a failure")

        // A signal-bearing segment that stays empty after the retry ->
        // flagged as a failure, contributes nothing to the joined text, but
        // does not discard an earlier segment's text.
        let stillFails: [AudioSegment] = [
            AudioSegment(samples: [0.1], hasSignal: true),
            AudioSegment(samples: [0.1], hasSignal: true),
        ]
        nonisolated(unsafe) var stillFailsCallIndex = 0
        let failOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(stillFails) { _ in
                defer { stillFailsCallIndex += 1 }
                // Segment 0 always succeeds; segment 1 (calls 2 and 3, since
                // segment 0 only ever calls once) always returns empty.
                return stillFailsCallIndex == 0 ? "kept" : ""
            }
        }
        try expect(failOutcome.text, equals: "kept",
                   "a persistently-empty segment doesn't discard an earlier segment's text")
        try expect(failOutcome.hadSegmentFailure, equals: true,
                   "a signal-bearing segment still empty after retry is flagged as a failure")

        // A segment with no signal (silence) that returns empty is NOT
        // retried and is NOT flagged as a failure.
        let silentSegment: [AudioSegment] = [AudioSegment(samples: [0.0], hasSignal: false)]
        nonisolated(unsafe) var silentCallCount = 0
        let silentOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(silentSegment) { _ in
                silentCallCount += 1
                return ""
            }
        }
        try expect(silentCallCount, equals: 1, "a silent segment is not retried")
        try expect(silentOutcome.text, equals: "", "a silent segment contributes no text")
        try expect(silentOutcome.hadSegmentFailure, equals: false, "a silent segment is never a failure")

        // A segment whose transcribeOne throws is treated like an empty
        // result: retried once (since it has signal), and doesn't crash the
        // whole run.
        let throwing: [AudioSegment] = [AudioSegment(samples: [0.1], hasSignal: true)]
        nonisolated(unsafe) var throwCallCount = 0
        struct DummyError: Error {}
        let throwOutcome = try runParakeetEngineSynchronously {
            await transcribeSegments(throwing) { _ in
                throwCallCount += 1
                throw DummyError()
            }
        }
        try expect(throwCallCount, equals: 2, "a throwing segment is retried exactly once, same as empty text")
        try expect(throwOutcome.hadSegmentFailure, equals: true, "a segment that keeps throwing is flagged as a failure")
    }
```

No changes needed to `runSuite` or `ParakeySelfTest.run` — `testSegmentedTranscription` is a plain `throws` function like every other suite in this file, so `case "segmented-transcription": return runSuite("segmented-transcription", testSegmentedTranscription)` (added above) needs no `await`.

- [ ] **Step 3: Run the new self-test on the Mac**

```bash
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && swift run -c debug --package-path . Parakey --self-test segmented-transcription'
```

Expected: `PASS segmented-transcription`.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/SegmentedTranscription.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add transcribeSegments: retry-once + partial-failure orchestration

Pure orchestrator over AudioSegment: retries an unexpectedly-empty
signal-bearing segment once, never lets one failed segment discard
text already produced by earlier segments, and never retries/flags a
genuinely silent segment as a failure.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Wire segmentation into `TranscriptionWorkerResult` and add the production adapter

**Files:**
- Modify: `swift/Sources/Parakey/main.swift:5630-5646` (`TranscriptionWorkerResult`)
- Modify: `swift/Sources/Parakey/main.swift` (new function, placed directly after `TranscriptionWorker`'s closing brace, i.e. after line 6006)

**Interfaces:**
- Consumes: `PauseSegmenter.segment(...)` (Task 1), `transcribeSegments(...)` (Task 2), `TranscriptionWorker.transcribe(samples:language:resolveViaKeyboard:requestedAt:)` (existing, `main.swift:5903`).
- Produces: `func transcribeSegmented(samples: [Float], worker: TranscriptionWorker, language: DictationLanguage?, resolveViaKeyboard: Bool, requestedAt: TimeInterval) async throws -> TranscriptionWorkerResult` — consumed by Task 4, 5, 6.

- [ ] **Step 1: Add `hadSegmentFailure` to `TranscriptionWorkerResult`**

In `main.swift`, change (lines 5630-5646):

```swift
private struct TranscriptionWorkerResult: Sendable {
    let text: String
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let engineCallSeconds: Double
    let engineProcessingSeconds: Double

    func timing(totalSeconds: Double) -> ASRTimingBreakdown {
        ASRTimingBreakdown(
            totalSeconds: totalSeconds,
            workerQueueSeconds: workerQueueSeconds,
            decoderPreparationSeconds: decoderPreparationSeconds,
            engineCallSeconds: engineCallSeconds,
            engineProcessingSeconds: engineProcessingSeconds
        )
    }
}
```

to:

```swift
private struct TranscriptionWorkerResult: Sendable {
    let text: String
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let engineCallSeconds: Double
    let engineProcessingSeconds: Double
    /// True iff `transcribeSegmented(...)` had at least one signal-bearing
    /// segment that stayed empty even after a retry (see
    /// SegmentedTranscription.swift). Always false for a plain single-call
    /// `TranscriptionWorker.transcribe(...)` result — only
    /// `transcribeSegmented` ever sets it true.
    var hadSegmentFailure: Bool = false

    func timing(totalSeconds: Double) -> ASRTimingBreakdown {
        ASRTimingBreakdown(
            totalSeconds: totalSeconds,
            workerQueueSeconds: workerQueueSeconds,
            decoderPreparationSeconds: decoderPreparationSeconds,
            engineCallSeconds: engineCallSeconds,
            engineProcessingSeconds: engineProcessingSeconds
        )
    }
}
```

This is purely additive (default value) — every existing construction of `TranscriptionWorkerResult` (e.g. `main.swift:5975-5981` inside `TranscriptionWorker.transcribe`) still compiles unchanged and gets `hadSegmentFailure == false`.

- [ ] **Step 2: Add the `transcribeSegmented` adapter**

Insert directly after `TranscriptionWorker`'s closing `}` (after line 6006, before the `// MARK: - Transcript corrections` comment at line 6008):

```swift
/// Adapts `transcribeSegments` (pure orchestration) to the real
/// `TranscriptionWorker`: splits `samples` with `PauseSegmenter`, feeds
/// each piece through `worker.transcribe(...)` in order (the worker's own
/// `inFlight` guard makes concurrent calls impossible anyway, so strictly
/// sequential segment processing costs nothing extra there), and merges
/// the per-segment `TranscriptionWorkerResult`s into one aggregate result
/// with the same shape a single whole-buffer call would have produced —
/// every existing caller of `TranscriptionWorker.transcribe(...)` downstream
/// of this (post-processing, latency logging, history) needs no changes.
/// For a recording short enough to produce exactly one segment (the
/// overwhelming majority of dictations), this is one ASR call, identical
/// to today's behavior.
func transcribeSegmented(
    samples: [Float],
    worker: TranscriptionWorker,
    language: DictationLanguage?,
    resolveViaKeyboard: Bool,
    requestedAt: TimeInterval
) async throws -> TranscriptionWorkerResult {
    let segments = PauseSegmenter.segment(samples: samples, sampleRate: SAMPLE_RATE)

    var totalEngineCallSeconds = 0.0
    var totalEngineProcessingSeconds = 0.0
    var firstWorkerQueueSeconds = 0.0
    var haveFirstTiming = false

    let outcome = await transcribeSegments(segments) { segmentSamples in
        let result = try await worker.transcribe(
            samples: segmentSamples,
            language: language,
            resolveViaKeyboard: resolveViaKeyboard,
            requestedAt: requestedAt
        )
        totalEngineCallSeconds += result.engineCallSeconds
        totalEngineProcessingSeconds += result.engineProcessingSeconds
        if !haveFirstTiming {
            firstWorkerQueueSeconds = result.workerQueueSeconds
            haveFirstTiming = true
        }
        return result.text
    }

    return TranscriptionWorkerResult(
        text: outcome.text,
        workerQueueSeconds: firstWorkerQueueSeconds,
        decoderPreparationSeconds: 0,
        engineCallSeconds: totalEngineCallSeconds,
        engineProcessingSeconds: totalEngineProcessingSeconds,
        hadSegmentFailure: outcome.hadSegmentFailure
    )
}
```

- [ ] **Step 3: Build to confirm it compiles (no self-test needed — pure wiring over already-tested pieces)**

```bash
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && swift build -c debug --product Parakey'
```

Expected: `Build of product 'Parakey' complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add transcribeSegmented adapter wiring PauseSegmenter into TranscriptionWorker

Bridges the pure segmentation/retry pieces to the real ASR worker.
Not yet called from any production call site — that's Tasks 4-6.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Wire the hotkey-release call site + no-silent-data-loss safety net

**Files:**
- Modify: `swift/Sources/Parakey/main.swift:12556-12569` (transcription task creation)
- Modify: `swift/Sources/Parakey/main.swift:12588-12724` (result handling — empty/non-empty branches)

**Interfaces:**
- Consumes: `transcribeSegmented(...)` (Task 3).

- [ ] **Step 1: Swap the whole-buffer call for the segmented adapter**

Change (`main.swift:12556-12569`):

```swift
        let asrRequestedAt = ProcessInfo.processInfo.systemUptime
        let transcriptionWorker = asr
        let language = settings.dictationLanguage
        let transcriptionTask = Task.detached(priority: .userInitiated) {
            let transcription = try await transcriptionWorker.transcribe(
                samples: samples,
                language: language,
                requestedAt: asrRequestedAt
            )
            return CompletedTranscriptionWorkerResult(
                transcription: transcription,
                completedAt: ProcessInfo.processInfo.systemUptime
            )
        }
```

to:

```swift
        let asrRequestedAt = ProcessInfo.processInfo.systemUptime
        let transcriptionWorker = asr
        let language = settings.dictationLanguage
        let transcriptionTask = Task.detached(priority: .userInitiated) {
            let transcription = try await transcribeSegmented(
                samples: samples,
                worker: transcriptionWorker,
                language: language,
                resolveViaKeyboard: true,
                requestedAt: asrRequestedAt
            )
            return CompletedTranscriptionWorkerResult(
                transcription: transcription,
                completedAt: ProcessInfo.processInfo.systemUptime
            )
        }
```

(`resolveViaKeyboard: true` matches the default the direct call used implicitly before — see `TranscriptionWorker.transcribe`'s `resolveViaKeyboard: Bool = true` default at `main.swift:5905`.)

- [ ] **Step 2: Flag `dictationFailed` for a partially-successful (but flawed) result**

Immediately after `let cleaned = processed.text` (`main.swift:12602`, right before the existing `log("\(...) chars")` line), add:

```swift
                    if completed.transcription.hadSegmentFailure {
                        dictationFailed = true
                    }
```

- [ ] **Step 3: Stop silently discarding recovery audio on a genuinely empty result**

Change the `else` branch at `main.swift:12722-12724`:

```swift
                    } else {
                        PendingDictationRecovery.remove(captured.recoveryURL)
                    }
```

to:

```swift
                    } else if completed.transcription.hadSegmentFailure {
                        // At least one segment that DID contain real speech
                        // still came back empty after a retry — this is a
                        // genuine loss, not an empty (silent) recording.
                        // Keep the recovery audio on disk instead of
                        // deleting it, and make sure the user sees an
                        // error rather than a silent return to idle.
                        log("dictation lost after retry: 0 chars from \(String(format: "%.2f", dur)) s audio with real speech detected — recovery audio retained at \(captured.recoveryURL?.path ?? "?")")
                        dictationFailed = true
                    } else {
                        // No segment had detectable speech at all — a
                        // legitimately silent/empty recording, not a
                        // failure. Preserve today's quiet behavior.
                        PendingDictationRecovery.remove(captured.recoveryURL)
                    }
```

- [ ] **Step 4: Build to confirm it compiles**

```bash
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && swift build -c debug --product Parakey'
```

Expected: `Build of product 'Parakey' complete!` with no errors.

- [ ] **Step 5: Manual verification on the real Mac**

This is a real-hardware, real-model behavior change — run it through the app itself, not just the self-test suite:

```bash
ssh shohart@192.168.1.246 './scripts/build-app.sh ~/scratch/sd-impl-dist/SuperDictate.app' # or the project's existing dev-run.sh, per scripts/dev-run.sh
```

Then, physically on the Mac (not over SSH — dictation needs a real mic/hotkey session):
1. Dictate a continuous ~60-90 second passage without long pauses in the middle (read a paragraph aloud without stopping). Confirm it completes within a few seconds of releasing the hotkey (no multi-minute hang) and the inserted/history text reads as one coherent, correctly-punctuated passage with no obviously dropped clause at a segment boundary.
2. Check `~/Library/Logs/SuperDictate.log` for that dictation and confirm multiple `N.NN s audio -> ...` engine-call lines are no longer produced as a single call spanning the whole duration — the aggregate timing in the final `latency: ...` line should reflect the sum of per-segment engine time, and total wall-clock should be roughly proportional to duration (no runaway blowup).
3. Dictate a short (~2s) phrase as before and confirm behavior is unchanged (still exactly one ASR call, same latency profile as before this change).

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Route hotkey-release dictation through segmented transcription

Long continuous dictations now go through PauseSegmenter instead of a
single whole-buffer ASR call, avoiding the encoder's confirmed
superlinear-cost hang on continuous audio past ~30-40s. A dictation
that comes back empty despite containing real speech now keeps its
recovery audio and signals a visible failure instead of silently
vanishing.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Wire `recoverActiveRecordingToHistory`

**Files:**
- Modify: `swift/Sources/Parakey/main.swift:12779-12812`

**Interfaces:**
- Consumes: `transcribeSegmented(...)` (Task 3).

- [ ] **Step 1: Swap the direct `asr.transcribe` call**

Change (`main.swift:12779-12791`):

```swift
        Task { @MainActor in
            var recoveryFailed = false
            do {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: captured.samples,
                    language: settings.dictationLanguage,
                    // See recoverPendingDictationsAfterStartup(): this is
                    // also recovering a previous session's audio, so the
                    // current keyboard layout must not be forced onto it.
                    resolveViaKeyboard: false,
                    requestedAt: requestedAt
                )
```

to:

```swift
        Task { @MainActor in
            var recoveryFailed = false
            do {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await transcribeSegmented(
                    samples: captured.samples,
                    worker: asr,
                    language: settings.dictationLanguage,
                    // See recoverPendingDictationsAfterStartup(): this is
                    // also recovering a previous session's audio, so the
                    // current keyboard layout must not be forced onto it.
                    resolveViaKeyboard: false,
                    requestedAt: requestedAt
                )
```

- [ ] **Step 2: Apply the same keep-audio-on-real-failure rule**

Change (`main.swift:12800-12810`):

```swift
                    if !processed.text.isEmpty {
                        addToHistory(
                            processed.text,
                            transcriptionDurationSeconds: timing.totalSeconds,
                            asrTiming: timing
                        )
                        recordDictationUsage(text: processed.text,
                                             audioSeconds: duration,
                                             asrSeconds: timing.totalSeconds)
                    }
                    PendingDictationRecovery.remove(captured.recoveryURL)
```

to:

```swift
                    if !processed.text.isEmpty {
                        addToHistory(
                            processed.text,
                            transcriptionDurationSeconds: timing.totalSeconds,
                            asrTiming: timing
                        )
                        recordDictationUsage(text: processed.text,
                                             audioSeconds: duration,
                                             asrSeconds: timing.totalSeconds)
                    }
                    if transcription.hadSegmentFailure {
                        log("recovered dictation lost part of its audio after retry — recovery file retained at \(captured.recoveryURL?.path ?? "?")")
                        recoveryFailed = true
                    } else {
                        PendingDictationRecovery.remove(captured.recoveryURL)
                    }
```

Note: `timing` is computed from `transcription.timing(totalSeconds:)` a few lines above this block (unchanged) — `transcription` here is now the `TranscriptionWorkerResult` returned by `transcribeSegmented`, which carries `hadSegmentFailure` (Task 3), so no new variable needs threading in.

- [ ] **Step 3: Build to confirm it compiles**

```bash
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && swift build -c debug --product Parakey'
```

Expected: `Build of product 'Parakey' complete!` with no errors.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Route non-standard-termination recovery through segmented transcription

recoverActiveRecordingToHistory (e.g. permission lost mid-recording)
now benefits from the same pause segmentation and keep-audio-on-real-
failure behavior as the normal hotkey-release path.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Wire `recoverPendingDictationsAfterStartup`

**Files:**
- Modify: `swift/Sources/Parakey/main.swift:11039-11082`

**Interfaces:**
- Consumes: `transcribeSegmented(...)` (Task 3).

- [ ] **Step 1: Swap the direct `asr.transcribe` call and apply the keep-on-failure rule**

Change (`main.swift:11041-11082`):

```swift
            do {
                let samples = try PendingDictationRecovery.loadSamples(from: url)
                guard !samples.isEmpty else {
                    PendingDictationRecovery.remove(url)
                    continue
                }
                let duration = Double(samples.count) / SAMPLE_RATE
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: samples,
                    language: settings.dictationLanguage,
                    // Recovered audio is from a *previous* session — the
                    // keyboard layout active right now at recovery time has
                    // no bearing on what language that stale recording was
                    // spoken in, so keep today's plain nil-passthrough
                    // behavior for `.auto` instead of forcing the current
                    // layout.
                    resolveViaKeyboard: false,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                let processed = processedDictationText(rawTranscript: transcription.text,
                                                       corrections: settings.transcriptCorrections,
                                                       removeFillerWords: settings.removeFillerWords,
                                                       normalizeNumbersToDigits: settings.normalizeNumbersToDigits,
                                                       language: settings.dictationLanguage)
                if !processed.text.isEmpty {
                    addToHistory(
                        processed.text,
                        transcriptionDurationSeconds: timing.totalSeconds,
                        asrTiming: timing
                    )
                    recordDictationUsage(text: processed.text,
                                         audioSeconds: duration,
                                         asrSeconds: timing.totalSeconds)
                }
                PendingDictationRecovery.remove(url)
                log("pending dictation recovered: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
            } catch {
                log("pending dictation recovery deferred: \(error.localizedDescription)")
            }
```

to:

```swift
            do {
                let samples = try PendingDictationRecovery.loadSamples(from: url)
                guard !samples.isEmpty else {
                    PendingDictationRecovery.remove(url)
                    continue
                }
                let duration = Double(samples.count) / SAMPLE_RATE
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await transcribeSegmented(
                    samples: samples,
                    worker: asr,
                    language: settings.dictationLanguage,
                    // Recovered audio is from a *previous* session — the
                    // keyboard layout active right now at recovery time has
                    // no bearing on what language that stale recording was
                    // spoken in, so keep today's plain nil-passthrough
                    // behavior for `.auto` instead of forcing the current
                    // layout.
                    resolveViaKeyboard: false,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                let processed = processedDictationText(rawTranscript: transcription.text,
                                                       corrections: settings.transcriptCorrections,
                                                       removeFillerWords: settings.removeFillerWords,
                                                       normalizeNumbersToDigits: settings.normalizeNumbersToDigits,
                                                       language: settings.dictationLanguage)
                if !processed.text.isEmpty {
                    addToHistory(
                        processed.text,
                        transcriptionDurationSeconds: timing.totalSeconds,
                        asrTiming: timing
                    )
                    recordDictationUsage(text: processed.text,
                                         audioSeconds: duration,
                                         asrSeconds: timing.totalSeconds)
                }
                if transcription.hadSegmentFailure {
                    log("pending dictation recovery lost part of its audio after retry — leaving \(url.lastPathComponent) in place for the next launch")
                } else {
                    PendingDictationRecovery.remove(url)
                }
                log("pending dictation recovered: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
            } catch {
                log("pending dictation recovery deferred: \(error.localizedDescription)")
            }
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && swift build -c debug --product Parakey'
```

Expected: `Build of product 'Parakey' complete!` with no errors.

- [ ] **Step 3: Run the full self-test suite one more time**

```bash
ssh shohart@192.168.1.246 'cd ~/scratch/sd-impl/swift && SUPERDICTATE_PARAKEET_MODEL="$HOME/Library/Application Support/SuperDictate/Models/tdt-0.6b-v3-q8_0.gguf" swift run -c debug --package-path . Parakey --self-test all'
```

Expected: every suite prints `PASS <name>` (or `SKIP <name>` for the hardware-gated ones), no `FAIL` lines.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Route startup pending-dictation recovery through segmented transcription

recoverPendingDictationsAfterStartup (the crash-recovery-on-relaunch
path) now benefits from the same pause segmentation and keep-audio-on-
real-failure behavior as the normal hotkey-release path — completing
the rollout to all three ASR call sites named in the design doc.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** pause-based segmentation (Task 1), sequential per-segment transcription with existing single-shot bridge call unchanged (Task 2/3), concatenation before post-processing (Task 3 — `transcribeSegmented` returns one merged `TranscriptionWorkerResult`, so `processedDictationText` downstream still runs exactly once on the full text, unchanged), retry-once on empty (Task 2), no-silent-data-loss safety net across all three ASR call sites (Task 4/5/6) — every design-doc section maps to a task.
- **Out of scope confirmed:** no task touches `swift/Sources/parakeet_cpp/**`; no task adds live/incremental partial-text UI.
- **Type consistency:** `AudioSegment` (Task 1) is consumed by name in Task 2 and Task 3 exactly as defined; `SegmentedTranscriptionOutcome`/`transcribeSegments` (Task 2) consumed by name in Task 3; `TranscriptionWorkerResult.hadSegmentFailure` (Task 3) consumed by name in Task 4/5/6 — verified no renaming drift across tasks.
