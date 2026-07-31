import Foundation

/// Result of assembling one multi-window dictation's per-window word lists
/// into a single transcript. `seamSplitSamples` is purely diagnostic (one
/// entry per interior seam, in absolute sample offsets) — logged and
/// asserted on by self-tests, never consumed by production text handling.
struct OverlapAssemblyResult: Sendable, Equatable {
    let text: String
    let seamSplitSamples: [Int]
    /// How many words the seam dedup dropped in total. Diagnostic only.
    let droppedAtSeams: Int
}

enum OverlapAssemblyError: LocalizedError {
    case shapeMismatch(windows: Int, wordLists: Int)
    case noWindows
    /// A window whose underlying segment carried real signal produced no
    /// usable words. Deliberately fatal FOR THE OVERLAP PATH ONLY: it makes
    /// the caller fall back to the plain `transcribeSegments` path, which
    /// has the shipped per-segment retry and `hadSegmentFailure` accounting
    /// this path deliberately does not reimplement.
    case signalBearingWindowProducedNoWords(windowIndex: Int)
    /// Every window produced nothing at all. Same reasoning as above.
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .shapeMismatch(let windows, let wordLists):
            return "overlap assembly got \(wordLists) word lists for \(windows) windows"
        case .noWindows:
            return "overlap assembly got no windows"
        case .signalBearingWindowProducedNoWords(let index):
            return "overlap window \(index) carried signal but produced no words"
        case .emptyTranscript:
            return "overlap assembly produced an empty transcript"
        }
    }
}

/// Composes Tasks 5-8 into one transcript. **Pure and synchronous** — no
/// `TranscriptionWorker`, no `async`, no I/O of its own. Everything that
/// needs a model (token transcription) has already happened by the time
/// this is called; the only model-backed thing it may touch is whatever
/// `BoundaryOracle`s the caller hands it, and every oracle is contractually
/// allowed to decline (the chain always ends in `MidpointBoundaryOracle`).
/// That makes this whole function unit-testable with synthetic data and
/// zero models — see the `overlap-assembly` self-test group.
///
/// Steps, matching the design doc's §6:
/// 1. For each interior seam, ask the oracle chain where ownership should
///    actually split inside the two windows' shared overlap zone.
/// 2. Keep only each window's words whose absolute start falls inside that
///    window's (possibly oracle-refined) owned span.
/// 3. Dedup ACROSS each seam (see `dedupAcrossSeam`).
/// 4. Join the survivors with single spaces, matching how
///    `transcribeSegments` already joins its per-segment texts.
///
/// - Parameters:
///   - windows: straight from `OverlapWindower.addOverlap(to:...)`, which
///     in turn must have been given `PauseSegmenter.segment(...)`'s direct
///     output — every `startSample`/`ownedStartSample`/`ownedEndSample`
///     here is an absolute offset into `fullSamples` and is meaningless if
///     that chain was broken by filtering or reordering segments.
///   - perWindowWords: window-relative words, one list per window, same
///     order and count as `windows`.
///   - fullSamples: the ORIGINAL captured buffer the segments came from —
///     overlap zones are sliced out of this, not out of the windows.
func assembleOverlapTranscript(
    windows: [AudioWindow],
    perWindowWords: [[TranscribedWord]],
    fullSamples: [Float],
    sampleRate: Double,
    boundaryOracles: [BoundaryOracle],
    toleranceSeconds: Double = 0.24,
    lookbackCount: Int = 3
) throws -> OverlapAssemblyResult {
    guard !windows.isEmpty else { throw OverlapAssemblyError.noWindows }
    guard windows.count == perWindowWords.count else {
        throw OverlapAssemblyError.shapeMismatch(windows: windows.count, wordLists: perWindowWords.count)
    }

    let chooseSplit = chainBoundaryOracle(boundaryOracles)

    // --- Step 1: one ownership split per interior seam ---------------
    //
    // `splitSamples[i]` (for i in 1..<count) is where window i-1 stops
    // owning and window i starts. The overlap zone for that seam is the
    // region BOTH windows have audio for: window i's audio starts at
    // `windows[i].startSample` (already `ownedStart - overlapBefore`) and
    // window i-1's audio ends at `startSample + samples.count` (already
    // `ownedEnd + overlapAfter`). The nominal (pre-refinement) seam,
    // `windows[i-1].ownedEndSample == windows[i].ownedStartSample`, always
    // lies inside that zone.
    var splitSamples: [Int] = []
    splitSamples.reserveCapacity(max(0, windows.count - 1))
    for index in 1..<windows.count {  // empty range when there is a single window
        let previous = windows[index - 1]
        let current = windows[index]
        let nominalSeam = previous.ownedEndSample
        let rawZoneStart = min(current.startSample, nominalSeam)
        let rawZoneEnd = max(previous.startSample + previous.samples.count, nominalSeam)
        let zoneStart = max(0, min(rawZoneStart, fullSamples.count))
        let zoneEnd = max(zoneStart, min(rawZoneEnd, fullSamples.count))

        if zoneEnd <= zoneStart {
            // Zero-width zone (no overlap budget was available at all, e.g.
            // two back-to-back max-length segments) — nothing to refine,
            // keep the nominal seam.
            splitSamples.append(max(0, min(nominalSeam, fullSamples.count)))
            continue
        }
        let zone = Array(fullSamples[zoneStart..<zoneEnd])
        splitSamples.append(chooseSplit(zone, zoneStart, zoneEnd, sampleRate))
    }

    // --- Step 2: ownership filter ------------------------------------
    //
    // Window i owns [leftBound, rightBound): the first window has no left
    // clip and the last has no right clip, so the union of owned spans
    // always covers the whole dictation with no gap and no double-cover.
    var perWindowKept: [[AbsoluteToken]] = []
    perWindowKept.reserveCapacity(windows.count)
    for (index, window) in windows.enumerated() {
        let leftBound = index == 0 ? Int.min : splitSamples[index - 1]
        let rightBound = index == windows.count - 1 ? Int.max : splitSamples[index]

        var kept: [AbsoluteToken] = []
        for word in perWindowWords[index] {
            let text = word.w.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            // Guard against a malformed/corrupted bridge response handing us
            // a non-finite or absurd timestamp: the `Int(...)` conversion
            // below traps on overflow/NaN, which would crash the whole
            // process instead of falling back to the plain segmentation
            // path like every other failure mode in this function does.
            // Skipping just this one word (same as the empty-text case
            // above) keeps the rest of the window's words intact.
            guard word.start.isFinite, word.start.magnitude < 1e6 else { continue }
            let absoluteSeconds = Double(window.startSample) / sampleRate + word.start
            let absoluteSample = window.startSample + Int((word.start * sampleRate).rounded())
            guard absoluteSample >= leftBound, absoluteSample < rightBound else { continue }
            kept.append(AbsoluteToken(text: text, absoluteSeconds: absoluteSeconds))
        }

        // A window built from a segment that carried real signal must
        // produce something. If it doesn't, bail out of this whole path so
        // the caller re-runs the dictation on the shipped plain path,
        // which retries and accounts for the loss properly.
        if kept.isEmpty && window.hasSignal {
            throw OverlapAssemblyError.signalBearingWindowProducedNoWords(windowIndex: index)
        }
        perWindowKept.append(kept)
    }

    // --- Step 3: dedup across each seam ------------------------------
    var assembled: [AbsoluteToken] = perWindowKept[0]
    var dropped = 0
    for index in 1..<perWindowKept.count {  // empty range when there is a single window
        let splitSeconds = Double(splitSamples[index - 1]) / sampleRate
        let next = perWindowKept[index]
        // Only words inside the seam's tolerance band can possibly collide
        // with the previous window's tail; everything past the band is
        // appended untouched and can never be dropped.
        let bandEnd = splitSeconds + toleranceSeconds
        let bandCount = next.prefix { $0.absoluteSeconds <= bandEnd }.count
        let band = Array(next.prefix(bandCount))
        let rest = Array(next.dropFirst(bandCount))

        let survivors = dedupAcrossSeam(previouslyKept: assembled,
                                        candidates: band,
                                        toleranceSeconds: toleranceSeconds,
                                        lookbackCount: lookbackCount)
        dropped += band.count - survivors.count
        assembled.append(contentsOf: survivors)
        assembled.append(contentsOf: rest)
    }

    // --- Step 4: join ------------------------------------------------
    let text = assembled.map(\.text).joined(separator: " ")
    guard !text.isEmpty else { throw OverlapAssemblyError.emptyTranscript }

    return OverlapAssemblyResult(text: text,
                                 seamSplitSamples: splitSamples,
                                 droppedAtSeams: dropped)
}
