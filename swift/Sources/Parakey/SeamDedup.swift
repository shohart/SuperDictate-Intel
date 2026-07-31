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
        if seamCollides(candidate: candidate, withKept: kept.suffix(lookbackCount), toleranceSeconds: toleranceSeconds) {
            continue  // earlier token already wins, per DD-014
        }
        kept.append(candidate)
    }

    return kept
}

/// DD-014's collision test, factored out so `dedupSeam` (whole-list form)
/// and `dedupAcrossSeam` (seam-scoped form, used by the real assembly)
/// cannot drift apart: `candidate` is a duplicate iff its absolute
/// timestamp is within `toleranceSeconds` of one of the already-kept
/// tokens it is compared against.
func seamCollides(candidate: AbsoluteToken,
                  withKept kept: ArraySlice<AbsoluteToken>,
                  toleranceSeconds: Double) -> Bool {
    kept.contains { abs($0.absoluteSeconds - candidate.absoluteSeconds) <= toleranceSeconds }
}

/// **The form the real overlap assembly uses.** Applies DD-014's rule
/// STRICTLY ACROSS ONE SEAM -- exactly as the design doc's §5 states it
/// ("a token at the start of segment *i+1* is dropped if its timestamp
/// falls within a small tolerance of one of segment *i*'s last few
/// tokens") -- rather than over the whole dictation's token stream.
///
/// **Why not `dedupSeam` over the full ordered stream** (which the design
/// doc's §6 "Assembly" paragraph loosely suggests): `dedupSeam`'s collision
/// test is text-agnostic and unconditional, so run over a whole transcript
/// it drops ANY word starting within `toleranceSeconds` (240 ms) of one of
/// the last few kept words. At real speech rates a large fraction of
/// consecutive words are that close together (measured on this project's
/// own t95.wav fixture -- see task-9-report.md), so the whole-stream form
/// would silently delete a large share of every long dictation. §5's
/// cross-seam scoping is the correct reading; §6's wording over-generalizes
/// it. See task-9-report.md for the measurement and the decision.
///
/// `previouslyKept` is the earlier window's kept words (in order);
/// `candidates` is the later window's kept words that lie inside the
/// seam's tolerance band (the caller narrows this -- words further from
/// the split than the tolerance can never collide, so they are never even
/// offered here and can never be dropped).
///
/// Candidates are compared ONLY against `previouslyKept`, never against
/// each other: two genuinely distinct words on the later side of a seam
/// are not evidence of a duplicated emission, and §5's rule is explicitly
/// about segment *i+1*'s head versus segment *i*'s tail.
///
/// Only the last `lookbackCount` of `previouslyKept` are consulted, which
/// is not merely a cost bound but exactly equivalent to consulting all of
/// them: timestamps are monotonically ordered and every candidate is at or
/// after the split, so if a candidate is within tolerance of an earlier
/// reference it is necessarily within tolerance of a later one too.
func dedupAcrossSeam(previouslyKept: [AbsoluteToken],
                     candidates: [AbsoluteToken],
                     toleranceSeconds: Double = 0.24,
                     lookbackCount: Int = 3) -> [AbsoluteToken] {
    let references = previouslyKept.suffix(lookbackCount)
    guard !references.isEmpty else { return candidates }
    return candidates.filter {
        !seamCollides(candidate: $0, withKept: references, toleranceSeconds: toleranceSeconds)
    }
}
