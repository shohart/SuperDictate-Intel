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
