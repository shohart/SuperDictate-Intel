import Foundation

/// A token with its ABSOLUTE (dictation-relative, not window-relative)
/// timestamp and already-resolved text (a token id alone isn't human text
/// -- by the time tokens reach this function they've already been mapped
/// to their text pieces via whatever text-segment logic Task 9 uses; see
/// Task 9 for exactly how `Token.id`-based pieces become `text` here).
struct AbsoluteToken: Sendable, Equatable {
    let text: String
    let absoluteSeconds: Double
}

/// Ported from achetronic/parakeet's DD-014 dedupSeam: operating on tokens
/// already tagged with ABSOLUTE timestamps (not per-window-relative), drops
/// a token if its timestamp falls within `toleranceSeconds` of one of the
/// PRECEDING `lookbackCount` tokens already kept -- same text at the same
/// position is a duplicate (dropped); different text at the same position
/// is a collision, resolved in favor of the EARLIER token (its producing
/// window's decoder had more context leading up to that point; the later
/// window's decoder was still warming up at the very start of its span) --
/// i.e. always keep the earlier one, always drop the later one, regardless
/// of whether text matches. A token further apart than the tolerance is
/// always kept.
///
/// Pure and deterministic -- no model, no I/O.
func dedupSeam(_ orderedTokens: [AbsoluteToken], toleranceSeconds: Double = 0.24, lookbackCount: Int = 3) -> [AbsoluteToken] {
    var kept: [AbsoluteToken] = []
    kept.reserveCapacity(orderedTokens.count)

    for candidate in orderedTokens {
        let recentWindow = kept.suffix(lookbackCount)
        let collidesWithRecent = recentWindow.contains { recent in
            abs(recent.absoluteSeconds - candidate.absoluteSeconds) <= toleranceSeconds
        }
        if collidesWithRecent {
            continue  // earlier token already kept -- always wins, per DD-014
        }
        kept.append(candidate)
    }

    return kept
}
