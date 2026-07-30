import Foundation

/// Result of running every segment of a (possibly multi-segment) dictation
/// through ASR. `hadSegmentFailure` is true iff at least one segment that
/// DID contain real signal (`AudioSegment.hasSignal == true`) still came
/// back empty after a retry — i.e., a genuine loss, as opposed to a
/// segment that was legitimately silent, OR at least one segment whose ASR
/// call threw and never recovered (a throw is never "legitimate silence,"
/// so it counts as a failure regardless of `hasSignal`).
struct SegmentedTranscriptionOutcome: Sendable {
    let text: String
    let hadSegmentFailure: Bool
    /// `localizedDescription` of the most recent error thrown by
    /// `transcribeOne`, or nil if nothing ever threw. Purely for logging —
    /// a non-nil value does NOT by itself mean the run failed (a throw
    /// whose retry succeeded still records the error here while
    /// `hadSegmentFailure` stays false).
    let lastErrorDescription: String?
}

/// Transcribes each segment in order through `transcribeOne`.
///
/// Two distinct "nothing came back" cases, deliberately NOT collapsed
/// together:
/// - **The closure threw.** Always retried once and, if it's still
///   failing/empty afterwards, always counted as a failure — regardless of
///   `hasSignal`. An engine that throws is broken, never "this was just
///   silence," and treating it as silence is exactly how audio gets
///   silently deleted with no failure signal.
/// - **The closure returned an empty string.** Retried once and counted as
///   a failure only if the segment was flagged as carrying real signal; an
///   all-silent segment returning empty text is expected, not a failure.
///
/// One segment failing (by throwing or by returning nothing) never discards
/// text already produced by earlier segments.
///
/// Pure orchestration: takes no dependency on `TranscriptionWorker` or any
/// other production type, so it's fully testable with a mock closure.
func transcribeSegments(
    _ segments: [AudioSegment],
    transcribeOne: (_ samples: [Float]) async throws -> String
) async -> SegmentedTranscriptionOutcome {
    var pieces: [String] = []
    var hadFailure = false
    var lastErrorDescription: String?

    /// Runs the closure once, converting a throw into `nil` (as opposed to
    /// `""` for a legitimate empty return) and recording the error text.
    func attempt(_ samples: [Float]) async -> String? {
        do {
            return try await transcribeOne(samples)
        } catch {
            lastErrorDescription = error.localizedDescription
            return nil
        }
    }

    for segment in segments {
        var result = await attempt(segment.samples)
        var threw = (result == nil)
        // Retry when the call threw (always) or when it returned empty on a
        // segment that carried real signal.
        if threw || ((result ?? "").isEmpty && segment.hasSignal) {
            result = await attempt(segment.samples)
            threw = threw || (result == nil)
        }

        let text = result ?? ""
        if text.isEmpty {
            // A throw is never legitimate silence — always a failure, even
            // when the segment's RMS never crossed the signal threshold.
            if threw || segment.hasSignal { hadFailure = true }
        } else {
            pieces.append(text)
        }
    }

    return SegmentedTranscriptionOutcome(text: pieces.joined(separator: " "),
                                         hadSegmentFailure: hadFailure,
                                         lastErrorDescription: lastErrorDescription)
}
