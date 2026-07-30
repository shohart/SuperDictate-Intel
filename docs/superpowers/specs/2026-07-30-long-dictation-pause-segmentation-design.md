# Design: Pause-based long-dictation segmentation + no-silent-data-loss safety net

Date: 2026-07-30

## Background

The user reports that dictating continuous speech longer than roughly 30-40
seconds sometimes causes the whole dictation to be lost: no text is inserted,
nothing is saved to history, and the experience feels like the app crashed.

### Root cause (empirically confirmed on the target Intel Mac)

This is **not** a hard duration limit, a crash, or a speech-detection/VAD
quality issue, and it is **not** fixed by using a less-quantized model
(the model's numeric precision is irrelevant to this bug).

Two independent, compounding problems were found:

1. **Superlinear compute cost in the Parakeet encoder for long, continuous
   audio.** `parakeet.cpp`'s encoder (`upstream/encoder.cpp`,
   `upstream/relpos_attention.cpp`) uses full ("regular", non-local)
   relative-position self-attention for any audio shorter than ~11 minutes
   (`local_attn_window()` in `encoder.cpp` only switches to a cheaper banded
   window above `Tp > 8192` frames). The full-attention path emits O(Tp)
   graph nodes per conformer layer via a per-position loop
   (`relpos_attention.cpp`, ~lines 380-434), where `Tp` (encoder frame count)
   grows with audio duration. This was confirmed empirically: a 0.5s test
   clip transcribes in ~1.25s, but a 43-second real-speech clip (synthesized
   via macOS `say`, fed through the exact same `ParakeetEngine`/bridge path
   the app uses, both in debug and in a release build) did not finish within
   5+ minutes — a wildly disproportionate slowdown that only a superlinear
   (worse than O(duration)) cost curve explains. From the user's perspective
   this presents as an indefinite hang, indistinguishable from a crash.

2. **Silent data loss on any non-successful transcription.** In
   `main.swift`, the hotkey-release completion handler
   (~line 12588-12724) only calls `addToHistory(...)` and performs text
   insertion when `cleaned` (the post-processed transcript) is non-empty.
   When it's empty — regardless of *why* (a genuine empty-speech recording,
   or a future segment failure) — the code takes the `else` branch (line
   12722-12724) and does exactly one thing:
   `PendingDictationRecovery.remove(captured.recoveryURL)` — deleting the
   on-disk crash-recovery audio for that recording. No history entry, no
   user-visible error, no retry. `dictationFailed` is never set on this
   path, so the menu bar returns to `.idle` with no signal anything went
   wrong. This is why the user experiences it as "the dictation vanished."

Neither problem is duration-*threshold* based in a clean, fixed-seconds
sense — but recordings that stay well under ~25-30 seconds per continuous,
uninterrupted speech span reliably avoid the expensive regime in practice
(confirmed against the app's own `~/Library/Logs/SuperDictate.log` history:
every recording ≤35s in the sampled log completed normally).

### Why not fixed-length chunking

A naive fixed-time chunk (e.g., always cut every 20s) would frequently cut
mid-sentence or mid-clause. The Parakeet model produces punctuation and
local grammatical structure using the context of the *single* ASR call it
sees; cutting mid-phrase measurably degrades that structure (lost commas,
wrong sentence boundaries, a question turned into a statement). The user
explicitly rejected this approach for that reason.

### Why not patching parakeet.cpp/ggml directly

Increasing the `kGraphSize` budget or unconditionally lowering the
local-attention threshold would touch the vendored upstream C++/ggml tree
that is deliberately pinned to a specific commit (see
`scripts/vendor-parakeet-cpp.sh` / `PARAKEET_CPP_COMMIT`), and would need to
be re-validated after any future upstream re-vendor. It's a legitimate
longer-term fix but out of scope here — it doesn't fit as a scoped,
low-risk change, and the pause-based segmentation below sidesteps the
performance cliff entirely without touching upstream code.

---

## Design

### 1. Pause-based segmentation (new)

After `endRecording()` produces the full captured PCM buffer (as it does
today) and **before** the existing `asr.transcribe(samples:)` call, split
the buffer into 1..N segments along natural pauses in the speech, instead
of sending the whole buffer as one ASR call.

**Pause detection.** Reuse the existing RMS-based level metering already in
the codebase (`normalizedAudioLevel`/`channelRMSValues`, main.swift
~2026-2110) — no new signal-processing primitive is needed. Compute RMS
over short sliding windows (~20ms hops) across the captured buffer. A
candidate pause boundary is a run of low-RMS windows lasting at least
~300-500ms (tunable) — long enough to reliably fall between sentences/
clauses rather than between words or a normal breath pause.

**Cut rule.** Grow the current segment until either:
- a candidate pause boundary is found and the segment has reached a
  reasonable minimum size (avoid over-fragmenting on every short pause), or
- the segment reaches a safety cap (~25s, chosen with margin below the
  empirically-observed ~30-40s danger zone) — if no pause boundary has
  occurred by the cap, force a cut at the cap so a single unbroken speech
  run longer than the cap still can't reach the expensive compute regime.

**Recordings shorter than the cap** produce exactly one segment — i.e., the
overwhelming majority of everyday dictations go through the ASR exactly
once, exactly as today, with no behavior change and no added latency.

### 2. Sequential per-segment transcription (modified call site)

Segments are transcribed one at a time, in order, through the existing
single-shot `ParakeetEngine.transcribe(samples:)` / bridge call — unchanged.
This matches the engine's existing single-context, `busy`-guarded design
(`superdictate_parakeet.cpp`'s `context->busy` compare-exchange already
rejects concurrent calls), so no engine/bridge/C++ changes are required.

Resulting per-segment texts are concatenated with a single space to form
the final transcript. All existing post-processing (`processedDictationText`
— corrections, filler-word removal, ITN) runs once, on the **full
concatenated text**, exactly as it does today on a single-call transcript —
no change to that pipeline's behavior or inputs' shape.

### 3. No-silent-data-loss safety net (independent fix, applies regardless of segmentation)

- If any segment's ASR call returns an empty transcript, retry that segment
  once before accepting the empty result (cheap: the segment is short by
  construction).
- The on-disk recovery journal (`PendingDictationRecovery`) is **not**
  removed until the entire multi-segment dictation has been resolved
  (either fully inserted, or explicitly marked failed) — not on the first
  empty segment result, as today.
- If a segment is still empty after the retry, the dictation is **not**
  silently discarded: whatever segments *did* produce text are still
  inserted/saved, `dictationFailed` is set to `true` so the existing
  `signalDictationFailure()` path fires (audible/visual error indicator the
  user already has for other failure modes), and the recovery audio is
  retained on disk rather than deleted — giving the user both a visible
  signal that something went wrong and a recoverable copy of the audio,
  instead of the current silent, total loss.

### Data flow (end to end)

```
endRecording() -> full PCM buffer (unchanged)
   -> segmentByPause(buffer) -> [segment_1 ... segment_n]
   -> for each segment (sequential):
        asr.transcribe(segment) -> text_i
        if text_i empty: retry once
   -> join(text_1 ... text_n, separator: " ") -> raw transcript
   -> processedDictationText(raw transcript, ...) (unchanged, single pass)
   -> if non-empty: history + insertion (unchanged), recovery journal removed
   -> if any segment ultimately empty: insert partial text (if any),
      dictationFailed = true, recovery journal retained
```

### Error handling

- A thrown Swift error from any segment's `transcribe()` call is handled
  the same way a whole-call error is handled today (`catch { dictationFailed
  = true }`), except only that segment is affected — segments already
  transcribed are not discarded.
- The existing 20-minute (`MAX_RECORDING_SECONDS`) and 1200-second
  (`SD_PARAKEET_MAX_AUDIO_SECONDS`) hard caps are unaffected and remain as
  outer bounds; segmentation operates entirely inside those limits.
- `recoverActiveRecordingToHistory` (the separate non-standard-termination
  recovery path, main.swift ~12746) and
  `recoverPendingDictationsAfterStartup` (crash-recovery-on-relaunch) call
  the same segmentation + transcription path so a previously-unrecovered
  long recording benefits from the same fix on retry, rather than repeating
  the single-call failure.

### Testing

- Extend the self-test suite with a `pause-segmentation` group covering:
  segment-boundary detection on a synthetic buffer with known silence gaps,
  the safety-cap force-cut on continuous non-silent audio, single-segment
  passthrough for short recordings (no behavior change), and the retry/
  partial-failure/recovery-retention logic using a mocked ASR that returns
  empty for a specific segment.
- Manual verification on the real Intel Mac: dictate a >60s continuous
  passage and confirm it completes promptly (no multi-minute hang) and
  produces a full, correctly-punctuated transcript with no obviously
  dropped clause at segment boundaries.

## Out of scope

- Any change to `parakeet.cpp`/ggml/vendored upstream code (graph size
  budget, local-attention threshold, or per-step allocator behavior).
- Live/incremental display of partial transcript text while still
  recording (streaming UX) — explicitly declined by the user; this design
  only changes how the audio is *sent* to the existing offline ASR call,
  not the UI/timing of when text appears.
- Switching model quantization (q8_0 -> f16/f32) — investigated and ruled
  out as irrelevant to this bug (the cost/hang is algorithmic/graph-shape
  driven, not a numeric-precision effect).
