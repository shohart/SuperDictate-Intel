import Foundation

/// Picks the best "ownership split" sample offset inside an overlap zone
/// between two adjacent AudioWindows -- i.e., up to (not including) the
/// returned offset belongs to the earlier window's transcript, at/after it
/// belongs to the later window's. `samples` covers exactly
/// [zoneStartSample, zoneEndSample) in absolute-sample terms (the caller is
/// responsible for slicing the right region out of the original captured
/// buffer). Returns nil to decline (defer to the next oracle in the
/// chain); a declining oracle must not have side effects.
protocol BoundaryOracle {
    func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int?
}

/// Always decides (when the zone is non-empty): returns the sample offset
/// of the quietest short window inside the zone, using the same RMS
/// approach PauseSegmenter itself already uses for pause detection --
/// reused here, not reimplemented, so the two "what counts as quiet"
/// definitions in this codebase can't drift apart.
struct MelEnergyBoundaryOracle: BoundaryOracle {
    var windowSeconds: Double = PauseSegmenter.defaultWindowSeconds

    func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? {
        guard zoneEndSample > zoneStartSample, !samples.isEmpty else { return nil }
        let windowSize = max(1, Int(windowSeconds * sampleRate))
        var bestOffset = zoneStartSample
        var bestRMS = Float.greatestFiniteMagnitude
        var offset = 0
        while offset < samples.count {
            let end = min(offset + windowSize, samples.count)
            var sumSquares: Double = 0
            for i in offset..<end { sumSquares += Double(samples[i]) * Double(samples[i]) }
            let rms = Float(sqrt(sumSquares / Double(end - offset)))
            if rms < bestRMS {
                bestRMS = rms
                bestOffset = zoneStartSample + offset
            }
            offset = end
        }
        return bestOffset
    }
}

/// Always decides -- the guaranteed last link in the chain, so the chain
/// itself never returns nil.
struct MidpointBoundaryOracle: BoundaryOracle {
    func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? {
        guard zoneEndSample >= zoneStartSample else { return nil }
        return zoneStartSample + (zoneEndSample - zoneStartSample) / 2
    }
}

/// Tries each oracle in order, returning the first non-nil answer, clamped
/// into [zoneStartSample, zoneEndSample] regardless of which oracle
/// produced it (defensive -- a buggy oracle must never be able to move
/// ownership outside the zone it was asked about). Always includes
/// MidpointBoundaryOracle as a final, unconditional fallback even if the
/// caller's own `oracles` list doesn't -- so the chain can never fail to
/// produce an answer for a non-empty zone.
func chainBoundaryOracle(_ oracles: [BoundaryOracle]) -> (_ samples: [Float], _ zoneStartSample: Int, _ zoneEndSample: Int, _ sampleRate: Double) -> Int {
    let chain = oracles + [MidpointBoundaryOracle()]
    return { samples, zoneStartSample, zoneEndSample, sampleRate in
        for oracle in chain {
            if let split = oracle.chooseSplit(samples: samples, zoneStartSample: zoneStartSample, zoneEndSample: zoneEndSample, sampleRate: sampleRate) {
                return min(max(split, zoneStartSample), zoneEndSample)
            }
        }
        // Unreachable in practice (MidpointBoundaryOracle only returns nil
        // for an inverted zone), but a zero-width zone still needs an
        // answer -- default to its start.
        return zoneStartSample
    }
}
