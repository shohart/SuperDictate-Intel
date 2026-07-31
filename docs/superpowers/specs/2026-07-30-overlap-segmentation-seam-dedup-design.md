# Design: Overlapping segment windows + timestamp-based seam dedup

Date: 2026-07-30

## Background

v0.4.6 shipped pause-based segmentation (`PauseSegmenter`): long dictations are
split into non-overlapping segments cut only at natural speech pauses, capped
at 25 seconds each, to avoid the Parakeet encoder's confirmed superlinear
compute-cost blowup on long continuous audio. This fixed the hanging/vanishing
bug, but a multi-segment dictation now loses some cross-segment context at
each cut: punctuation and clause structure at a segment boundary can be
slightly worse than if the model had seen a little audio from both sides of
the cut.

The user wants to close this gap by giving each segment a small window of
audio *overlap* with its neighbors, so the model has boundary context on both
sides, while avoiding the duplicate/dropped words a naive overlap would cause
at the seam.

### Reference: `achetronic/parakeet` (local Docker container `parakeet-stt`)

A local reference ASR server (`ghcr.io/achetronic/parakeet`, Go + ONNX
Runtime, also serving the Parakeet TDT 0.6B model) solved exactly this
problem for its own long-audio mode. Its design record
(`.agents/DESIGN_DECISIONS.md`, DD-013/DD-014) is the model for this design:

- **DD-013** confirms the underlying encoder limitation is architectural, not
  runtime-specific: *"the encoder runs in a single pass, so peak memory
  scales with audio length... very long inputs can exceed device memory...
  Chunked/streaming encoding is the future fix."* This is true of the
  Parakeet Conformer encoder in non-streaming/full-attention mode regardless
  of whether it's run through ONNX Runtime or `parakeet.cpp`/ggml — switching
  runtimes would not remove the need for this work (see "Why not switch to
  ONNX Runtime" below).
- **DD-014** ("VAD-Aware Chunk Boundaries and Seam Token Dedup") is the
  design being ported here: overlapping windows, a boundary-oracle cascade
  (Silero VAD → mel-energy → arithmetic midpoint) that picks the best
  ownership split point *inside* the overlap, and a timestep-based seam
  token dedup as an always-on second safety net. Their own "Rejected
  alternatives" section explicitly rejects naive text-based LCS/sequence
  stitching of overlapping transcripts as "fragile on repeated words" —
  confirming timestamp-based dedup, not text comparison, is the right
  approach.

### Why not switch to ONNX Runtime (considered and rejected)

Raised and rejected during design: adopting `achetronic`'s ONNX Runtime
stack wholesale instead of porting the technique.

- It would not remove the root problem — per DD-013 above, achetronic's own
  ONNX-based encoder has the identical single-pass, cost-scales-with-length
  limitation, which is *why* they built DD-014 in the first place. The
  overlap/dedup work is required either way.
- It would very likely regress GPU acceleration on the target Mac. This
  project's Vulkan/MoltenVK GPU path (targeting the AMD Radeon RX 6600) was
  substantial, deliberate work; achetronic's GPU path is CUDA (NVIDIA-only,
  via ONNX Runtime's CUDA execution provider — see their DD-013), which does
  not run on this hardware. ONNX Runtime does not have a Vulkan execution
  provider anywhere near as mature as the Vulkan backend already working in
  this project's `parakeet.cpp` integration.
- It would require redoing the entire ASR backend migration (vendoring,
  C bridge, packaging, codesign, self-tests) that was already completed at
  significant cost, for no confirmed accuracy benefit — both runtimes serve
  the same underlying NeMo-exported Parakeet TDT 0.6B weights, just in
  different formats (GGUF/q8_0 vs ONNX).

Decision: stay on `parakeet.cpp`/ggml. Port DD-014's *technique*
(overlap + boundary oracle + timestamp dedup), not achetronic's runtime.

---

## Design

### 1. Overlap budget: carved out of the existing 25s cap, never added on top

**This is a safety-critical correction to a literal port of achetronic's
numbers.** achetronic's ~15s overlap is added *on top of* their window
length: a window is `nominal_length + overlap` long. Doing the same here —
stacking 15s of overlap onto our already-25s-capped segments — could produce
windows up to ~55s long, which is squarely back inside the empirically
confirmed hang zone (~30-40s) that `PauseSegmenter`'s 25s cap exists to stay
under.

Instead: **the 25-second cap (`PauseSegmenter.defaultMaxSegmentSeconds`)
remains the hard ceiling on any single ASR call, unchanged.** A configurable
overlap (`defaultOverlapSeconds = 4.0`, a named constant alongside
`PauseSegmenter`'s other `default*` constants) is carved out of that same
budget: a non-edge segment's windowed audio is its nominal pause-cut span,
extended by up to `overlapSeconds` into each neighbor,
clamped so the total windowed length never exceeds 25s and never exceeds the
neighbor's own actual length. A segment with no neighbor on a given side
(the first or last segment of a dictation) gets no overlap on that side. A
dictation that segments into exactly one piece (the overwhelming majority of
everyday dictations, per the already-shipped 15s minimum-before-cut rule)
is completely unaffected by any of this — no overlap, no boundary oracle, no
token timestamps, byte-identical to today.

### 2. Per-segment transcription now requests token timestamps

Today (`transcribeSegmented`) each segment is transcribed via the plain-text
bridge call (`sd_parakeet_transcribe`, wrapping
`parakeet_capi_transcribe_pcm`). This design adds a second, richer bridge
entry point for overlapping (i.e., non-single-segment) dictations, wrapping
the vendored `parakeet_capi_transcribe_pcm_batch_json` (already present in
`swift/Sources/parakeet_cpp/upstream/include/parakeet_capi.h`, unused today)
to return each token's text, absolute-in-window start timestamp, and
confidence, in addition to the plain concatenated text.

**Bridge stays thin.** Per this project's established convention (all new
segmentation logic in Task 1-6 of the prior plan lived in pure, testable
Swift; the C bridge was touched only where strictly necessary), the new
bridge function returns the JSON string produced by the vendored API
essentially as-is (a thin wrapper doing NULL/error handling, the same
pattern `sd_parakeet_transcribe` already follows) — the JSON is decoded on
the Swift side with `Codable`, not parsed in C++.

**Graceful degradation.** If the JSON call fails, or JSON decoding fails, for
a specific overlapping segment, that segment falls back to the existing
plain-text bridge call and is treated as having no usable timestamps for
seam dedup purposes (its full text is kept, dedup at its seam(s) is skipped
for that side). This means an overlap/timestamp-path bug can degrade
solely to today's already-shipped, tested v0.4.6 behavior for the affected
seam — it can never resurrect the pre-0.4.6 hang/vanish bug or lose a whole
dictation.

### 3. Boundary oracle cascade (ported from DD-014)

For each overlap region between adjacent segments, a chain of oracles picks
the best split point (in absolute sample/timestamp terms) for handing
"ownership" of that overlapped audio's text to one side or the other, tried
in order until one decides:

1. **VAD oracle** — runs a ggml-ported Silero VAD (see §4) over the overlap
   region's raw waveform, picks the center of the longest run of low
   speech-probability windows. Declines if nothing in the overlap scores
   below the silence-probability threshold.
2. **Mel-energy oracle** — pure Swift, reuses this project's existing
   RMS/energy-level code (`normalizedAudioLevel`/`channelRMSValues`,
   already used by `PauseSegmenter` itself) smoothed over a short window,
   returns the quietest point in the overlap. Always decides when energy
   data is available, so it is the robust fallback when VAD is unavailable
   or declines.
3. **Midpoint oracle** — pure Swift, trivial arithmetic midpoint of the
   overlap region. Always decides, so the chain never blocks.

This mirrors DD-014's `chainBoundaryOracle` structure directly. All three
are pure, independently unit-testable functions over synthetic
probability/energy arrays — no model or hardware dependency in their own
tests (the VAD oracle's *own* neural-net inference is tested separately,
gated behind real-hardware/model availability the same way this project
already gates Parakeet CPU/Vulkan integration tests).

### 4. Silero VAD via a ggml port (not ONNX Runtime)

Vendored analogously to `parakeet.cpp` itself: a new
`scripts/vendor-silero-vad.sh` pins a specific ggml-based Silero VAD port
(the same style of ggml Silero integration used in the `whisper.cpp`
ecosystem) at a fixed commit, vendors only the needed source under
`swift/Sources/parakeet_cpp/upstream/` (or a sibling target if warranted by
size — decided during implementation), and downloads/verifies a pinned VAD
model file the same way the Parakeet model downloader already verifies
size/SHA-256 before use.

**Missing VAD model is not fatal.** Exactly as DD-014 specifies: log a
warning once, degrade permanently to the mel-energy oracle for that run.
This keeps overlap+dedup fully functional (at slightly lower boundary
precision) even before/without the VAD model being staged, and never blocks
startup or a dictation.

A small new C bridge surface (e.g. `sd_silero_vad_speech_probabilities(...)`)
exposes per-window speech probabilities to the Swift-side VAD oracle,
following the same `SDParakeetStatus`-style error-code contract as the
existing bridge functions.

### 5. Seam token dedup (always on, no model dependency)

Ported from DD-014's `dedupSeam`: operating on tokens tagged with their
*absolute* (dictation-relative, not window-relative) timestamps, a token at
the start of segment *i+1* is dropped if its timestamp falls within a small
tolerance (~3 encoder frames / ~240ms, matching DD-014's tuned constant) of
one of segment *i*'s last few tokens. Same-text-same-position is a plain
duplicate (dropped); different-text-same-position is a collision, resolved
in favor of segment *i* (its decoder state was already warmed up approaching
that point; segment *i+1*'s decoder is still warming up at the very start of
its window) — identical reasoning and resolution rule to DD-014.

This is a pure, deterministic Swift function over token-timestamp lists —
independently unit-testable with synthetic token streams covering: an exact
duplicate at the seam, a collision (different text, same timestamp) to be
resolved in favor of the earlier segment, and a token far enough from the
tolerance window to be correctly kept on both sides (no false-positive drop).

*(Terminology note: the shipped path consumes the JSON's already-decoded
`words` array rather than raw SentencePiece tokens, so "token" throughout
this section is effectively "word" in the actual implementation —
`dedupAcrossSeam` operates on `AbsoluteToken` values built from those words,
not sub-word tokens.)*

### 6. Assembly

For each segment, after the boundary oracle has decided (or defaulted to)
an ownership split with each neighbor, keep only the tokens whose absolute
timestamp falls inside that segment's owned span. Seam dedup then runs once
*per seam boundary*, not as a single pass over the whole ordered stream:
at each boundary it compares only the earlier window's trailing kept words
against the later window's leading candidate words that fall inside that
seam's tolerance band (per §5), and drops/resolves duplicates locally
before the two sides are joined. The deduped, ownership-split segments are
then joined in order to produce one final transcript exactly as
`transcribeSegmented` does today — downstream (`processedDictationText`,
history, insertion) is unchanged, consuming a single assembled string as
before.

> **Correction:** an earlier draft of this section described dedup as
> running "as the always-on second pass over the full ordered token stream" —
> i.e. globally across the whole transcript. That formulation was found
> during implementation (Task 9) to be destructive: on a real dictation,
> roughly 18% of ordinary consecutive word pairs anywhere in the transcript
> happen to fall within the ~240ms tolerance window, so a whole-stream pass
> would drop large numbers of legitimate words that have nothing to do with
> a segment seam. The shipped implementation instead follows §5's original
> scoping — strictly local to each seam boundary — as implemented in
> `dedupAcrossSeam` (`swift/Sources/Parakey/SeamDedup.swift`). This section
> has been updated to match; §5 was already correct.

### Error handling

- Any failure anywhere in the new overlap/VAD/dedup path (bridge JSON
  failure, VAD model/bridge failure, decode failure) degrades that specific
  segment or seam to its pre-overlap v0.4.6 behavior (plain text, no seam
  refinement) — never to a dictation-level failure. The existing
  `hadSegmentFailure`/retry/retain-on-loss safety net from the prior plan is
  completely unaffected and continues to apply beneath this feature.
- A single-segment dictation (no neighbors) never invokes any part of this
  design — zero behavior change, zero added latency, for the majority of
  everyday dictations, exactly as today.

### Out of scope

- Live/incremental partial-transcript display while still recording
  (streaming UX) — declined earlier in this project and still out of scope
  here; this design only changes how already-segmented, already-recorded
  audio is transcribed and stitched, not when/how text appears on screen.
- A user-facing settings toggle — this feature is always active wherever
  `PauseSegmenter` already produces more than one segment, with no new
  Control Panel setting, per explicit decision.
- Switching the ASR runtime to ONNX Runtime — considered and rejected above.
- Any change to `swift/Sources/parakeet_cpp/upstream/**`'s existing
  Parakeet/ggml vendored sources — the new Silero VAD source is additive
  vendoring, not a modification of the pinned Parakeet tree.

## Testing

- Self-test groups (pure logic, no model/hardware): boundary-oracle chain
  (each of the three oracles individually, plus the chain's fallthrough
  ordering, over synthetic probability/energy arrays), seam-dedup (synthetic
  token streams: exact duplicate, collision, correctly-kept-far-token),
  overlap-windowing (coverage/budget invariant: total windowed segment
  length never exceeds the 25s cap; single-segment dictations produce
  identical output to the non-overlap path).
- Real-hardware integration tests, gated behind environment variables the
  same way this project's existing Parakeet CPU/Vulkan integration tests
  are gated (skipped, not failed, when the model/VAD file isn't staged):
  end-to-end overlap+dedup against a real multi-segment recording, VAD
  oracle against real audio, confirming no dropped/duplicated words at a
  seam compared to the plain (pre-overlap) transcript.
