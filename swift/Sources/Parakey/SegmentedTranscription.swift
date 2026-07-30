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
