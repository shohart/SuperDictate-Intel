import Foundation

/// One (possibly overlapping) window of audio to send to ASR, produced by
/// `OverlapWindower.addOverlap(to:...)` from a list of non-overlapping
/// `AudioSegment`s. `samples` may include up to `overlapSeconds` of audio
/// borrowed from each neighbor; `ownedStartSample`/`ownedEndSample` mark
/// this window's ORIGINAL (pre-overlap, pre-boundary-oracle-refinement)
/// nominal span in absolute sample terms -- the boundary oracle (see
/// BoundaryOracle.swift) may move these in toward the overlap when it finds
/// a better split point, but they start here.
struct AudioWindow: Sendable, Equatable {
    let samples: [Float]
    /// Absolute sample offset of `samples[0]` in the original captured
    /// buffer -- i.e. `ownedStartSample - overlapBeforeSamples`.
    let startSample: Int
    let ownedStartSample: Int
    let ownedEndSample: Int
    let hasSignal: Bool
}

enum OverlapWindower {
    static let defaultOverlapSeconds: Double = 4.0

    /// Extends each non-edge segment's audio into its neighbors by up to
    /// `overlapSeconds`, carved OUT of `maxSegmentSeconds` (never added on
    /// top -- see the safety-critical note in
    /// docs/superpowers/specs/2026-07-30-overlap-segmentation-seam-dedup-design.md).
    /// A segment with 0 or 1 total segments in the input is returned with
    /// zero overlap on every side (single-segment dictations are
    /// completely unaffected). The first segment gets no leading overlap;
    /// the last segment gets no trailing overlap.
    static func addOverlap(
        to segments: [AudioSegment],
        sampleRate: Double,
        overlapSeconds: Double = defaultOverlapSeconds,
        maxSegmentSeconds: Double = PauseSegmenter.defaultMaxSegmentSeconds
    ) -> [AudioWindow] {
        guard segments.count > 1 else {
            return segments.map { seg in
                AudioWindow(samples: seg.samples,
                           startSample: seg.startSample,
                           ownedStartSample: seg.startSample,
                           ownedEndSample: seg.startSample + seg.samples.count,
                           hasSignal: seg.hasSignal)
            }
        }

        let maxSegmentSamples = Int(maxSegmentSeconds * sampleRate)
        let requestedOverlapSamples = Int(overlapSeconds * sampleRate)

        return segments.enumerated().map { index, seg in
            let ownedStart = seg.startSample
            let ownedEnd = seg.startSample + seg.samples.count
            let budget = max(0, maxSegmentSamples - seg.samples.count)
            let halfBudget = budget / 2

            var overlapBefore = 0
            if index > 0 {
                let prev = segments[index - 1]
                overlapBefore = min(requestedOverlapSamples, halfBudget, prev.samples.count)
            }
            var overlapAfter = 0
            if index < segments.count - 1 {
                let next = segments[index + 1]
                overlapAfter = min(requestedOverlapSamples, halfBudget, next.samples.count)
            }

            var windowed = [Float]()
            windowed.reserveCapacity(overlapBefore + seg.samples.count + overlapAfter)
            if overlapBefore > 0 {
                let prev = segments[index - 1]
                windowed.append(contentsOf: prev.samples.suffix(overlapBefore))
            }
            windowed.append(contentsOf: seg.samples)
            if overlapAfter > 0 {
                let next = segments[index + 1]
                windowed.append(contentsOf: next.samples.prefix(overlapAfter))
            }

            return AudioWindow(samples: windowed,
                               startSample: ownedStart - overlapBefore,
                               ownedStartSample: ownedStart,
                               ownedEndSample: ownedEnd,
                               hasSignal: seg.hasSignal)
        }
    }
}
