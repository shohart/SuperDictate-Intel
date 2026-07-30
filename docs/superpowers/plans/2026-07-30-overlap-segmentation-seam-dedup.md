# Overlapping Segment Windows + Timestamp Seam Dedup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give multi-segment (long) dictations a small audio overlap between neighboring `PauseSegmenter` segments so Parakeet sees boundary context on both sides of a cut, while never duplicating or dropping words at the seam — using a boundary-oracle cascade (Silero VAD → mel-energy → midpoint) to pick the best ownership split inside each overlap, and a timestamp-based token dedup as an always-on second safety net.

**Architecture:** `PauseSegmenter`'s existing non-overlapping segments gain absolute sample offsets, then a new pure `OverlapWindower` extends each non-edge segment's audio into its neighbors by an amount carved OUT of the existing 25s safety cap (never added on top). Each window is transcribed through a new token-timestamp-returning bridge call (wrapping `parakeet.cpp`'s already-vendored, currently-unused `parakeet_capi_transcribe_pcm_batch_json`). A `BoundaryOracle` chain (Silero VAD, ported from `ggml-org/whisper.cpp`'s VAD implementation — mel-energy fallback — midpoint fallback) picks each overlap's ownership split; a pure `SeamDedup` pass removes any residual duplicate/colliding tokens at each boundary using absolute timestamps, never text comparison. Everything degrades gracefully to the already-shipped v0.4.6 plain-text segmented path on any failure, and single-segment dictations (the majority case) are completely untouched.

**Tech Stack:** Swift 6 (SwiftPM), C++17 (parakeet_cpp target), a newly-vendored ggml port of Silero VAD (from `ggml-org/whisper.cpp`), existing `--self-test` harness.

## Global Constraints

- Approved design: `docs/superpowers/specs/2026-07-30-overlap-segmentation-seam-dedup-design.md`. Follow it.
- **Safety-critical**: total windowed audio for any single ASR call must never exceed `PauseSegmenter.defaultMaxSegmentSeconds` (25.0s) — overlap is carved out of that existing budget, never added on top. Every task touching window sizing must preserve this invariant and test it explicitly.
- `defaultOverlapSeconds = 4.0` (new named constant, alongside `PauseSegmenter`'s other `default*` constants).
- Seam dedup tolerance: ~3 encoder frames (~240ms) between a segment's last few tokens and the next segment's first tokens — port `achetronic/parakeet`'s tuned constant, named `seamTimestepToleranceSeconds = 0.24`.
- Do **not** modify `swift/Sources/parakeet_cpp/upstream/**` (the existing, commit-pinned `parakeet.cpp`/ggml v0.13.0 vendor tree from `mudler/parakeet.cpp`) — Silero VAD is vendored as an **additive**, separately-pinned source tree, not a merge into that tree.
- Missing/unavailable Silero VAD model or bridge failure is never fatal — degrade to the mel-energy oracle (§3 of the design doc) and log a warning once.
- Any per-segment JSON/timestamp/VAD failure degrades that specific segment to the plain-text, no-timestamp bridge call already shipped in v0.4.6 (`sd_parakeet_transcribe`) — this feature can only ever degrade toward the already-shipped, tested behavior, never below it.
- A dictation that segments into exactly one piece (still the overwhelming majority — the 15s minimum-before-cut rule is unchanged) must be byte-identical to today: no overlap, no boundary oracle, no token timestamps, no added latency.
- All builds/tests run on the real Intel Mac (`shohart@192.168.1.246`), synced via `git archive HEAD | ssh ... tar -x` into a scratch directory — never `git clone`. **Never execute the compiled `Parakey` binary except as `Parakey --self-test <exact-group-name>`** — never `--agent`, never with zero arguments, never `--self-test all` (has been directly implicated in a real production-LaunchAgent incident during this project's prior plan; run specific groups only). After any self-test invocation, run the safety check:
  ```bash
  ssh shohart@192.168.1.246 'ps aux | grep -i "[p]arakey\|[s]uperdictate"; echo "---launchctl---"; launchctl list | grep -i superdictate'
  ```
  The only acceptable output is exactly one process, `/Applications/SuperDictate.app/Contents/MacOS/SuperDictate --agent`, registered in `launchctl list`. Anything else: STOP and report BLOCKED, do not attempt to fix it.
- `SAMPLE_RATE` is `16_000.0` (`main.swift:41`).
- New Swift files go under `swift/Sources/Parakey/`. New C++ files go under `swift/Sources/parakeet_cpp/` following that target's existing `bridge/`/`include/`/`upstream/` layout (a new `upstream-vad/` sibling directory for the additively-vendored Silero VAD source is appropriate — decide the exact name during Task 1 and use it consistently in later tasks).
- Self-tests are added under the existing `#if DEBUG` `ParakeySelfTest` harness in `main.swift`, following its established `case "<name>": return runSuite("<name>", testX)` / `try testX()` in `testAll()` pattern.

---

### Task 1: Vendor Silero VAD (ggml port) + model

**Files:**
- Create: `scripts/vendor-silero-vad.sh`
- Create: `swift/Sources/parakeet_cpp/upstream-vad/` (vendored source tree, generated by the script — exact contents determined at implementation time, see below)
- Create: `swift/Sources/parakeet_cpp/upstream-vad/PROVENANCE.md` (generated by the script, same pattern as `swift/Sources/parakeet_cpp/upstream/PROVENANCE.md`)

**Interfaces:**
- Produces: a buildable C++ translation unit (or a small set of them) exposing, at minimum, a way to (1) load a Silero VAD ggml model file from a path, (2) run inference over a buffer of mono Float32 16kHz samples, (3) retrieve per-analysis-window speech probabilities. Exact function names are whatever this task's extraction produces — Task 2 wraps them, so document the actual names in the PROVENANCE.md / a short comment for Task 2's implementer to consume, rather than assuming names in advance.

**This is a research-grounded vendoring task, not a copy-paste task** — unlike most tasks in this plan, the exact source is real, third-party code this plan's author has not read verbatim (only researched via GitHub API metadata). Verified facts to work from:

- Upstream: `ggml-org/whisper.cpp` (https://github.com/ggml-org/whisper.cpp), MIT-licensed. Silero VAD support is **not a standalone file** — it's embedded inside `src/whisper.cpp` (~9,000 lines) and declared in `include/whisper.h`. As of this research (2026-07-30), the relevant symbols (verify exact current line numbers/signatures against the live file before extracting — they will have drifted):
  - `struct whisper_vad_context` — distinct from `whisper_context`/`whisper_state`, has its own model loader, not entangled with whisper's ASR mel/encoder/decoder pipeline.
  - `whisper_vad_init_from_file_with_params()` / `whisper_vad_init_with_params()` — load the VAD model.
  - `whisper_vad_detect_speech()` / `whisper_vad_detect_speech_no_reset()` — run inference on raw PCM.
  - `whisper_vad_n_probs()` / `whisper_vad_probs()` — raw per-window speech probabilities (this is the primary output this project needs — the boundary oracle wants a probability array, not pre-segmented speech regions).
  - `whisper_vad_reset_state()`, `whisper_vad_free()` — lifecycle.
  - Full public declarations: `include/whisper.h`, roughly lines 192–750 (verify against live file).
  - A real, pinnable commit was current `master` HEAD at research time: `4523d0ce373ee4b2176b3251fff29fd4864fcf38` ("parakeet : verify hparams loaded from parakeet model bin file (#3950)", merged 2026-07-30). Use `git ls-remote` or the GitHub API to confirm this commit (or a newer one, if time has passed) still exists and still contains the `whisper_vad_*` symbols before pinning — do not pin blind.
- Model: `models/convert-silero-vad-to-ggml.py` (in the whisper.cpp repo) converts upstream `snakers4/silero-vad` (MIT-licensed) PyTorch weights into a small custom ggml-compatible binary format. Pre-converted models are hosted at `https://huggingface.co/ggml-org/whisper-vad` (MIT-licensed repo card):
  - `https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin`
  - `https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin`
  - Both were 885,098 bytes at research time — verify the actual Content-Length and compute the real SHA-256 of whichever version you pin, exactly as `scripts/vendor-parakeet-cpp.sh`/the Parakeet model downloader already do (immutable URL, no `main`/`latest`, verified checksum, verified size).

**Steps:**

- [ ] **Step 1: Confirm the pin, live**

Before writing any script logic, verify against the real, current upstream (not this plan's cached research):

```bash
git ls-remote https://github.com/ggml-org/whisper.cpp.git HEAD
```

Pick a specific commit SHA (the current HEAD, or a slightly older one if you want extra stability margin — either is fine as long as it's real and you've confirmed it exists). Then confirm the VAD symbols still exist at that commit:

```bash
git clone --no-checkout https://github.com/ggml-org/whisper.cpp.git /tmp/whisper-cpp-probe
cd /tmp/whisper-cpp-probe && git checkout <chosen-sha> -- src/whisper.cpp include/whisper.h
grep -n "whisper_vad_" include/whisper.h | head -30
```

If `whisper_vad_` symbols are not present at your chosen SHA, pick a different one (e.g. the current `master` tip) and re-verify. Record the confirmed SHA — this is `SILERO_VAD_SOURCE_COMMIT` in the script below.

- [ ] **Step 2: Write `scripts/vendor-silero-vad.sh`**

Mirror `scripts/vendor-parakeet-cpp.sh`'s existing structure and conventions (pinned commit constant at the top, `rm -rf` + regenerate the vendored directory, a generated `PROVENANCE.md`, no network access required at *build* time — only at *vendor* time). Concretely:

1. Accept (or hardcode, matching the existing script's style) `SILERO_VAD_SOURCE_COMMIT` (from Step 1) and `SILERO_VAD_MODEL_URL`/`SILERO_VAD_MODEL_SHA256`/`SILERO_VAD_MODEL_SIZE_BYTES` (from your verified model download).
2. Shallow-fetch `src/whisper.cpp` and `include/whisper.h` at the pinned commit into a temp dir (`git archive` over the network via `git archive --remote` if the host supports it, or a full shallow clone + checkout of just those two paths — match whatever `vendor-parakeet-cpp.sh` already does for fetching a pinned tree without a floating `master` reference).
3. Extract ONLY the `whisper_vad_*` implementation and its direct dependencies from `src/whisper.cpp`/`include/whisper.h` into new, minimal files under `swift/Sources/parakeet_cpp/upstream-vad/` (e.g. `whisper_vad.cpp`/`whisper_vad.h`, renamed/namespaced if needed to avoid any symbol collision with `parakeet.cpp`'s own vendored ggml tree — check for name collisions against `swift/Sources/parakeet_cpp/upstream/` before finalizing names). Since the VAD code lives inside a much larger file, this step requires actually reading the fetched `src/whisper.cpp` at vendor time to find the true current boundaries of the `whisper_vad_*` implementation (function bodies, any file-local helper functions/structs they depend on, any `ggml_*` calls that need ggml headers already available from the existing parakeet.cpp vendor tree) — do not guess at line ranges from this plan's research notes, which may be stale by the time this task runs.
4. Verify the extracted code actually depends only on ggml core APIs (`ggml.h`, `ggml-alloc.h`, etc. — already vendored under `swift/Sources/parakeet_cpp/upstream/`) and standard C++/libc — no whisper-specific mel-spectrogram/encoder/decoder code should be needed for VAD alone. If extraction turns out to require more of whisper.cpp than expected (e.g. shared helper functions used by both VAD and ASR code), pull in the minimum additional shared code needed, or vendor those specific helpers as small standalone copies — use judgment, but keep the goal ("VAD only, no unrelated ASR code") in mind.
5. Download the pinned model file into a location this project's existing model-download infrastructure can use (check how `downloadParakeetModelIfNeeded()`/`SpeechModelDownloadProgressHandler` work in `main.swift` and place this consistently — likely `~/Library/Application Support/SuperDictate/Models/`, a new filename e.g. `silero-vad-v5.1.2.gguf`-style naming consistent with the existing Parakeet model's naming, or `.bin` matching the ggml-org naming if that's clearer — decide and be consistent), verify size + SHA-256 against your pinned values, atomic rename into place (same safe-download pattern: temp file, verify, atomic rename, never trust a partially-downloaded file) — this can be a SEPARATE small addition to the existing model-download Swift code (not part of this shell script, which only handles the *source code* vendoring) — note this dependency for Task 2/7, which will need the model file present to test the real VAD path.
6. Generate `swift/Sources/parakeet_cpp/upstream-vad/PROVENANCE.md` documenting: the source repo URL, pinned commit SHA, what was extracted (file list), the model URL/SHA256/size, and today's date — matching the style of the existing `swift/Sources/parakeet_cpp/upstream/PROVENANCE.md`.
7. Confirm license notices: copy the MIT license text for both `whisper.cpp` and `silero-vad` into `swift/Sources/parakeet_cpp/upstream-vad/LICENSE-whisper-cpp.txt` and `LICENSE-silero-vad.txt`, matching the existing `LICENSE-parakeet-cpp.txt`/`LICENSE-ggml.txt` pattern.

- [ ] **Step 2: Wire the new source into `Package.swift`**

Read `swift/Package.swift`'s existing `parakeet_cpp` target definition (source paths, excludes, compile flags). Add the new `upstream-vad/` files to that target's sources (or a new sibling SwiftPM target if the existing target's structure makes that cleaner — match whatever's simplest given the actual file layout Step 1 produced). No new external dependencies (Homebrew, ONNX Runtime, etc.) — this must build with only what `vendor-parakeet-cpp.sh`'s CPU path already requires (a C/C++ toolchain, no additional SDK).

- [ ] **Step 3: Build check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
```

Expected: clean build (the new VAD source compiles, even though nothing calls it yet — this task only vendors, Task 2 wires the bridge).

- [ ] **Step 4: Commit**

```bash
git add scripts/vendor-silero-vad.sh swift/Sources/parakeet_cpp/upstream-vad/ swift/Package.swift
git commit -m "$(cat <<'EOF'
Vendor a ggml port of Silero VAD from ggml-org/whisper.cpp

Additive vendoring (does not touch the existing pinned parakeet.cpp/
ggml tree under swift/Sources/parakeet_cpp/upstream/): extracts the
whisper_vad_* implementation and pins a Silero VAD ggml model
download, both MIT-licensed. Not yet wired to any bridge function —
that's the next task.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Silero VAD C bridge (`sd_silero_vad_speech_probabilities`)

**Files:**
- Modify: `swift/Sources/parakeet_cpp/include/superdictate_parakeet.h` (or create a new sibling header, e.g. `superdictate_silero_vad.h`, if that reads more cleanly — match the existing single-header style unless it's clearly better split)
- Modify/Create: corresponding bridge `.cpp` implementation

**Interfaces:**
- Consumes: Task 1's vendored `whisper_vad_*` functions (exact names/signatures as extracted — verify against the actual vendored header, do not assume the names listed in Task 1's research notes are final).
- Produces: a new bridge entry point, matching this project's existing bridge conventions exactly (see `sd_parakeet_transcribe`'s shape in `swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp:234-301` as the pattern to follow — NULL checks first, an opaque owning context type, a stable numeric status enum, `try { ... } catch (...)` around every native call, no C++ exception ever crosses the ABI boundary):

```c
typedef struct SDSileroVadContext SDSileroVadContext;

typedef enum {
    SD_SILERO_VAD_OK = 0,
    SD_SILERO_VAD_ERR_NULL_ARGUMENT = 1,
    SD_SILERO_VAD_ERR_MODEL_LOAD_FAILED = 2,
    SD_SILERO_VAD_ERR_EMPTY_AUDIO = 3,
    SD_SILERO_VAD_ERR_INFERENCE_FAILED = 4,
    SD_SILERO_VAD_ERR_NATIVE_EXCEPTION = 5
} SDSileroVadStatus;

// Loads the pinned Silero VAD ggml model once. `model_path` is the local
// file path Task 1's downloader verified and placed. Returns NULL on
// failure (this is NOT fatal to callers — see sd_parakeet's design: a
// missing/failed VAD model degrades to the mel-energy oracle, never blocks
// a dictation).
SDSileroVadStatus sd_silero_vad_create(
    const char *model_path,
    SDSileroVadContext **out_context
);

// Runs VAD inference over mono Float32 samples at 16kHz (this project's
// fixed SAMPLE_RATE — no resampling performed here, unlike
// sd_parakeet_transcribe; callers must already be at 16kHz, which every
// caller in this project already is). On success, `out_probabilities` is
// malloc'd (owned by caller, free with sd_silero_vad_free_probabilities),
// one probability per analysis window (window size is whatever the
// extracted whisper_vad_* implementation uses internally — expose it via
// `out_window_size_samples` so Swift-side code doesn't have to hardcode
// it), `out_count` is the array length.
SDSileroVadStatus sd_silero_vad_speech_probabilities(
    SDSileroVadContext *context,
    const float *samples,
    uint64_t sample_count,
    float **out_probabilities,
    uint64_t *out_count,
    uint64_t *out_window_size_samples
);

void sd_silero_vad_free_probabilities(float *probabilities);
void sd_silero_vad_destroy(SDSileroVadContext *context);
const char *sd_silero_vad_last_error_message(const SDSileroVadContext *context);
```

**Steps:**

- [ ] **Step 1: Verify the exact upstream signatures**

Read the actual vendored `swift/Sources/parakeet_cpp/upstream-vad/*.h` from Task 1 (not this plan's research notes) to get the real, current parameter types/order for whichever `whisper_vad_init_*`/`whisper_vad_detect_speech*`/`whisper_vad_n_probs`/`whisper_vad_probs` functions Task 1 actually extracted. Adjust the bridge implementation's internal calls accordingly — the *external* C API above (the `sd_silero_vad_*` names/shapes) is this project's own stable surface and should not need to change regardless of upstream's exact internal signatures.

- [ ] **Step 2: Implement the bridge**

Add the struct/enum declarations above to the header, and implement each function in the corresponding `.cpp`, following `sd_parakeet_transcribe`'s exact pattern: NULL-check every pointer argument first, wrap every call into the vendored VAD code in `try { ... } catch (...) { status = SD_SILERO_VAD_ERR_NATIVE_EXCEPTION; }`, store the last error string on the context (same `last_error` field pattern used by `SDParakeetContext`), never let an exception propagate past the `extern "C"` boundary.

- [ ] **Step 3: Add a `parakeet-bridge`-style self-test**

Look at the existing `testParakeetBridge` self-test (search `main.swift` for `private static func testParakeetBridge`) for the pattern: NULL-argument validation, an invalid model path, etc. — no real model needed for these cases. Add an analogous `silero-vad-bridge` self-test group covering: `sd_silero_vad_create` with a NULL path returns `SD_SILERO_VAD_ERR_NULL_ARGUMENT`; with a nonexistent path returns `SD_SILERO_VAD_ERR_MODEL_LOAD_FAILED`; `sd_silero_vad_speech_probabilities` with a NULL context/samples returns `SD_SILERO_VAD_ERR_NULL_ARGUMENT`; with `sample_count == 0` returns `SD_SILERO_VAD_ERR_EMPTY_AUDIO`. Register it in the `switch` in `ParakeySelfTest.run` and in `testAll()`, matching the exact pattern used for `pause-segmentation`/`segmented-transcription` in the prior plan.

- [ ] **Step 4: Real-model integration self-test (gated, skipped without the model)**

Add a `silero-vad-real` self-test group, gated behind an env var the same way `testParakeetCPUIntegration` is gated behind `SUPERDICTATE_PARAKEET_MODEL` (search `main.swift` for that pattern) — e.g. `SUPERDICTATE_SILERO_VAD_MODEL`. When the env var isn't set to an existing file path, `print("SKIP silero-vad-real: ...")` and return, never fail. When it is set: load the model, run `sd_silero_vad_speech_probabilities` over a short synthetic buffer (e.g. 2 seconds of alternating silence/tone, built the same way `testParakeetCPUIntegration` builds its synthetic buffer), and assert `out_count > 0` and the returned probabilities are all in `[0, 1]`.

- [ ] **Step 5: Build + self-test on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test silero-vad-bridge'
```
Then the safety check (per Global Constraints).

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/parakeet_cpp/ swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add thin C bridge for Silero VAD speech probabilities

Wraps Task 1's vendored whisper_vad_* functions behind a stable,
project-owned sd_silero_vad_* C API following the same NULL-safe,
exception-free, opaque-context pattern as sd_parakeet_transcribe.
Not yet called from Swift — that's a later task (the VAD boundary
oracle).

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Parakeet bridge extension for token-timestamp transcription

**Files:**
- Modify: `swift/Sources/parakeet_cpp/include/superdictate_parakeet.h`
- Modify: `swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp`

**Interfaces:**
- Consumes: the already-vendored (unmodified, already present today) `parakeet_capi_transcribe_pcm_batch_json` from `swift/Sources/parakeet_cpp/upstream/include/parakeet_capi.h`, which returns a malloc'd JSON string shaped `{"text":"...", "frame_sec":0.08, "words":[{"w":"...","start":0.48,"end":0.64,"conf":0.91}], "tokens":[{"id":123,"t":0.48,"conf":0.91}]}` for a single clip (call with `n_clips=1`).
- Produces: `sd_parakeet_transcribe_with_tokens`, returning the raw JSON string (thin passthrough — no JSON parsing in C++, matching this project's established "bridge stays thin, Swift decodes" convention).

- [ ] **Step 1: Add the header declaration**

In `swift/Sources/parakeet_cpp/include/superdictate_parakeet.h`, add (near `sd_parakeet_transcribe`):

```c
typedef struct {
    char *json;                // malloc'd UTF-8 JSON (see parakeet_capi_transcribe_pcm_batch_json's
                                // documented shape), owned by caller; NULL on failure.
    double total_seconds;
    double inference_seconds;
    int32_t used_gpu;
} SDParakeetTokenResult;

// Like sd_parakeet_transcribe, but returns per-token/per-word timestamps as
// a raw JSON document instead of plain text — see
// parakeet_capi_transcribe_pcm_batch_json's doc comment
// (swift/Sources/parakeet_cpp/upstream/include/parakeet_capi.h) for the
// exact JSON shape. Used only for multi-segment (overlapping) dictations;
// single-segment dictations keep using the plain sd_parakeet_transcribe.
SDParakeetStatus sd_parakeet_transcribe_with_tokens(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetTokenResult *out_result
);

void sd_parakeet_token_result_destroy(SDParakeetTokenResult *result);
```

- [ ] **Step 2: Implement it**

In `swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp`, add `sd_parakeet_transcribe_with_tokens` directly after `sd_parakeet_transcribe` (`main.swift`... i.e. that same file, near line 301), copying its exact validation/busy-flag/try-catch structure (NULL checks, `sample_count == 0` → `SD_PARAKEET_ERR_EMPTY_AUDIO`, duration cap → `SD_PARAKEET_ERR_AUDIO_TOO_LONG`, `context->busy` compare-exchange → `SD_PARAKEET_ERR_BUSY`), but calling `parakeet_capi_transcribe_pcm_batch_json` instead of `parakeet_capi_transcribe_pcm`:

```cpp
extern "C" SDParakeetStatus sd_parakeet_transcribe_with_tokens(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetTokenResult *out_result
) {
    if (!out_result) return SD_PARAKEET_ERR_NULL_ARGUMENT;
    out_result->json = nullptr;
    out_result->total_seconds = 0.0;
    out_result->inference_seconds = 0.0;
    out_result->used_gpu = 0;

    if (!context || !context->native || !samples || sample_rate == 0) {
        return SD_PARAKEET_ERR_NULL_ARGUMENT;
    }
    if (sample_count == 0) {
        return SD_PARAKEET_ERR_EMPTY_AUDIO;
    }
    double durationSeconds = static_cast<double>(sample_count) / static_cast<double>(sample_rate);
    if (durationSeconds > SD_PARAKEET_MAX_AUDIO_SECONDS) {
        return SD_PARAKEET_ERR_AUDIO_TOO_LONG;
    }
    if (sample_count > static_cast<uint64_t>(INT32_MAX)) {
        return SD_PARAKEET_ERR_AUDIO_TOO_LONG;
    }

    bool expected = false;
    if (!context->busy.compare_exchange_strong(expected, true)) {
        return SD_PARAKEET_ERR_BUSY;
    }

    SDParakeetStatus status = SD_PARAKEET_OK;
    try {
        auto started = std::chrono::steady_clock::now();
        int nSamples = static_cast<int>(sample_count);
        char *json = parakeet_capi_transcribe_pcm_batch_json(
            context->native, samples, &nSamples, /*n_clips=*/1,
            static_cast<int>(sample_rate), /*decoder=*/0
        );
        auto finished = std::chrono::steady_clock::now();
        double seconds = std::chrono::duration<double>(finished - started).count();

        if (!json) {
            context->last_error = parakeet_capi_last_error(context->native);
            status = SD_PARAKEET_ERR_INFERENCE_FAILED;
        } else {
            out_result->json = dupUTF8(std::string(json));
            parakeet_capi_free_string(json);
            if (!out_result->json) {
                status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
            } else {
                out_result->total_seconds = seconds;
                out_result->inference_seconds = seconds;
                out_result->used_gpu =
                    startsWithCaseInsensitive(context->device_name, "Vulkan") ? 1 : 0;
            }
        }
    } catch (...) {
        context->last_error = "native exception during token transcription";
        status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }

    context->busy.store(false);
    return status;
}

extern "C" void sd_parakeet_token_result_destroy(SDParakeetTokenResult *result) {
    if (!result) return;
    if (result->json) {
        std::free(result->json);
        result->json = nullptr;
    }
}
```

Note: `parakeet_capi_transcribe_pcm_batch_json` returns a JSON **array** (one object per clip) even for `n_clips=1` — per its own doc comment ("a JSON ARRAY of n_clips objects"). Confirm this by reading the actual function doc comment in `swift/Sources/parakeet_cpp/upstream/include/parakeet_capi.h` before finalizing — if it's an array, Task 4's Swift-side `Codable` type must decode `[TokenTranscription]` and take `[0]`, not decode a bare object directly.

- [ ] **Step 3: Extend the `parakeet-bridge` self-test**

In the existing `testParakeetBridge` self-test (or a new sibling group `parakeet-bridge-tokens` if cleaner), add NULL/empty-audio/invalid-argument coverage for `sd_parakeet_transcribe_with_tokens` mirroring what already exists for `sd_parakeet_transcribe`.

- [ ] **Step 4: Build check**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
```
Then run the relevant self-test group and the safety check.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/parakeet_cpp/ swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add token-timestamp transcription to the Parakeet bridge

Thin wrapper over the already-vendored (previously unused)
parakeet_capi_transcribe_pcm_batch_json, returning its JSON document
(text + per-word/per-token timestamps) instead of plain text. Bridge
stays thin -- JSON decoding happens in Swift (next task). Not yet
called anywhere in the app.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Swift token decoding + `ParakeetEngine.transcribeWithTokens`

**Files:**
- Create: `swift/Sources/Parakey/TokenTranscription.swift`
- Modify: `main.swift`'s `ParakeetEngine` (find `final class ParakeetEngine`)

**Interfaces:**
- Consumes: Task 3's `sd_parakeet_transcribe_with_tokens` bridge function.
- Produces: `struct Token: Sendable, Decodable { let id: Int; let t: Double; let conf: Double }`, `struct TokenTranscription: Sendable, Decodable { let text: String; let frameSec: Double; let tokens: [Token] }`, and `func ParakeetEngine.transcribeWithTokens(samples: [Float]) async throws -> TokenTranscription` — consumed by Task 9.

- [ ] **Step 1: Write `TokenTranscription.swift`**

```swift
import Foundation

/// One decoded token from `parakeet_capi_transcribe_pcm_batch_json`'s JSON
/// document. `t` is the token's timestamp in seconds, relative to the
/// START of whatever audio buffer was passed to that specific transcribe
/// call (i.e. NOT yet an absolute dictation-relative timestamp — callers
/// convert to absolute time by adding the window's own absolute start
/// offset; see OverlapWindow.swift).
struct Token: Sendable, Decodable, Equatable {
    let id: Int
    let t: Double
    let conf: Double
}

/// Decoded result of a token-timestamp transcription call.
struct TokenTranscription: Sendable, Decodable, Equatable {
    let text: String
    let frameSec: Double
    let tokens: [Token]

    enum CodingKeys: String, CodingKey {
        case text
        case frameSec = "frame_sec"
        case tokens
    }
}

enum TokenTranscriptionDecodeError: Error {
    case emptyArray
    case malformedJSON(Error)
}

/// Decodes `parakeet_capi_transcribe_pcm_batch_json`'s JSON document for a
/// single-clip (`n_clips=1`) call. The upstream API returns a JSON ARRAY
/// even for one clip (per its own doc comment) -- decode the array and take
/// its one element.
func decodeTokenTranscription(json: String) throws -> TokenTranscription {
    guard let data = json.data(using: .utf8) else {
        throw TokenTranscriptionDecodeError.malformedJSON(
            NSError(domain: "TokenTranscription", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "JSON string was not valid UTF-8"]))
    }
    do {
        let clips = try JSONDecoder().decode([TokenTranscription].self, from: data)
        guard let first = clips.first else {
            throw TokenTranscriptionDecodeError.emptyArray
        }
        return first
    } catch let error as TokenTranscriptionDecodeError {
        throw error
    } catch {
        throw TokenTranscriptionDecodeError.malformedJSON(error)
    }
}
```

**Before finalizing this step**, confirm the real JSON key names/nesting against `parakeet_capi_transcribe_pcm_batch_json`'s doc comment in `swift/Sources/parakeet_cpp/upstream/include/parakeet_capi.h` (already quoted in Task 3's Interfaces section above) — if the vendored version at build time differs even slightly from what's quoted there, adjust `CodingKeys`/nesting to match the REAL doc comment/output, not this plan's cached copy of it.

- [ ] **Step 2: Add `ParakeetEngine.transcribeWithTokens`**

Find `ParakeetEngine`'s existing `func transcribe(samples: [Float]) async throws -> ParakeetTranscriptionResult` (search `main.swift`) and add a sibling method following the exact same actor-isolation/`withUnsafeBufferPointer`/native-bridge-call/error-mapping pattern, but calling `sd_parakeet_transcribe_with_tokens` and decoding via `decodeTokenTranscription(json:)` from Step 1. Map any C bridge status the same way the existing `transcribe` method already maps `SDParakeetStatus` to `ParakeetEngineError` cases (reuse those error cases — do not invent new ones unless the JSON-decode failure path needs a new case, e.g. `ParakeetEngineError.tokenDecodeFailed(String)`).

- [ ] **Step 3: Self-test — pure JSON decoding, no model needed**

Add a `token-transcription-decode` self-test group covering: a well-formed single-clip array JSON matching the documented shape decodes correctly (assert `text`, `frameSec`, and each token's `id`/`t`/`conf`); an empty array `[]` throws `TokenTranscriptionDecodeError.emptyArray`; malformed JSON (e.g. `"not json"`) throws `TokenTranscriptionDecodeError.malformedJSON`. This needs no model, no bridge call, no hardware — pure `Codable` round-trip testing, matching the rigor of the prior plan's pure-logic self-tests.

- [ ] **Step 4: Build + self-test + safety check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test token-transcription-decode'
```

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/TokenTranscription.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add Swift token-timestamp decoding and ParakeetEngine.transcribeWithTokens

Codable types + a pure decode function for the JSON shape
sd_parakeet_transcribe_with_tokens returns, plus the ParakeetEngine
method that calls the bridge and decodes the result. Not yet wired
into any production transcription path.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `AudioSegment.startSample` + `OverlapWindower`

**Files:**
- Modify: `swift/Sources/Parakey/PauseSegmenter.swift`
- Create: `swift/Sources/Parakey/OverlapWindower.swift`

**Interfaces:**
- Modifies: `AudioSegment` gains `let startSample: Int = 0` (additive, defaulted — every existing `AudioSegment(samples:hasSignal:)` construction across the codebase, including the ~9 self-test call sites in `main.swift`, continues to compile unchanged).
- Produces: `struct AudioWindow: Sendable, Equatable { let samples: [Float]; let startSample: Int; let ownedStartSample: Int; let ownedEndSample: Int; let hasSignal: Bool }` and `enum OverlapWindower { static func addOverlap(to segments: [AudioSegment], sampleRate: Double, overlapSeconds: Double = 4.0, maxSegmentSeconds: Double = PauseSegmenter.defaultMaxSegmentSeconds) -> [AudioWindow] }` — consumed by Task 9.

- [ ] **Step 1: Add `startSample` to `AudioSegment` and populate it**

In `PauseSegmenter.swift`, change:

```swift
struct AudioSegment: Sendable, Equatable {
    let samples: [Float]
    let hasSignal: Bool
}
```

to:

```swift
struct AudioSegment: Sendable, Equatable {
    let samples: [Float]
    let hasSignal: Bool
    /// This segment's absolute offset (in samples) within the original
    /// captured buffer `PauseSegmenter.segment(...)` was given. Defaults to
    /// 0 for source compatibility with existing single-segment test
    /// literals that don't care about absolute position; real segments
    /// produced by `segment(...)` always set this correctly.
    let startSample: Int = 0
}
```

Wait — a stored property cannot have both a default value AND be settable per-instance via memberwise init while keeping it `let` with a fixed default; Swift's synthesized memberwise initializer for a struct with a defaulted stored property still requires the initializer to accept it as an optional parameter with that default, which DOES allow both `AudioSegment(samples:hasSignal:)` (using the default) and `AudioSegment(samples:startSample:hasSignal:)`-style explicit construction (in whatever parameter order Swift synthesizes — verify by testing on the Mac; if the synthesized initializer's parameter ORDER breaks any existing call site because `startSample` inserts itself alphabetically/positionally between `samples` and `hasSignal`, all existing two-argument call sites like `AudioSegment(samples: [0.1], hasSignal: true)` still work fine since they use keyword arguments and Swift's memberwise init keeps all fields with defaults independently omittable regardless of declaration order — but confirm this compiles as expected on the Mac in Step 4 before assuming it).

Then update `makeSegment` (inside `PauseSegmenter.segment`) to actually populate it:

```swift
func makeSegment(endSample: Int) -> Bool {
    let end = min(endSample, samples.count)
    guard end > segmentStartSample else { return false }
    let range = segmentStartSample..<end
    segments.append(AudioSegment(samples: Array(samples[range]),
                                 hasSignal: hasSignal(in: range),
                                 startSample: segmentStartSample))
    segmentStartSample = end
    return true
}
```

- [ ] **Step 2: Write `OverlapWindower.swift`**

```swift
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
```

- [ ] **Step 3: Self-test — `overlap-windowing`**

Add a self-test group covering:
1. **Single segment**: `addOverlap(to: [oneSegment], ...)` returns exactly one `AudioWindow` whose `samples` equals the input segment's `samples` exactly (no overlap added) — this is the majority-case invariant.
2. **Budget safety invariant**: construct several segments each already at (or near) `maxSegmentSeconds`, call `addOverlap` with a real `overlapSeconds`, and assert EVERY resulting window's `samples.count` is `<= Int(maxSegmentSeconds * sampleRate)`. This is the single most important test in this task — it's the direct regression test for the safety-critical constraint in this plan's Global Constraints.
3. **Normal case**: three segments of moderate length (well under the cap, so overlap isn't budget-constrained), assert the middle window's `samples` actually contains the expected borrowed tail of segment 1 and head of segment 3, and that `startSample`/`ownedStartSample`/`ownedEndSample` are arithmetically correct (hand-compute the expected values in the test, the same way the prior plan's `PauseSegmenter` tests hand-verified sample arithmetic).
4. **Edge segments get no outward overlap**: in a 3-segment case, the first window's `startSample == ownedStartSample` (no leading overlap) and the last window's `samples.count`'s trailing portion has no borrowed audio past `ownedEndSample`.

- [ ] **Step 4: Build + self-test + safety check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test overlap-windowing'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test pause-segmentation'
```
(Re-run `pause-segmentation` too, to confirm the `AudioSegment.startSample` addition didn't regress Task 1-6's original self-tests from the prior plan.)

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/PauseSegmenter.swift swift/Sources/Parakey/OverlapWindower.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add AudioSegment.startSample and OverlapWindower

OverlapWindower extends non-edge segments into their neighbors by up
to 4s, carved OUT of the existing 25s safety cap rather than added on
top -- a single-segment dictation is completely unaffected. Includes
a direct regression test for the budget-safety invariant. Not yet
wired into any production transcription path.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `BoundaryOracle` chain (mel-energy + midpoint, no VAD yet)

**Files:**
- Create: `swift/Sources/Parakey/BoundaryOracle.swift`

**Interfaces:**
- Consumes: `AudioWindow` (Task 5).
- Produces: `protocol BoundaryOracle { func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? }`, `struct MelEnergyBoundaryOracle: BoundaryOracle`, `struct MidpointBoundaryOracle: BoundaryOracle`, `func chainBoundaryOracle(_ oracles: [BoundaryOracle]) -> (samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int` — consumed by Task 7 (which adds the VAD oracle to the chain) and Task 9.

- [ ] **Step 1: Write `BoundaryOracle.swift`**

```swift
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
```

- [ ] **Step 2: Self-test — `boundary-oracle`**

Add a self-test group covering:
1. `MidpointBoundaryOracle`: a zone `[100, 200)` returns `150`.
2. `MelEnergyBoundaryOracle`: a synthetic buffer with a clearly quiet stretch in the middle (e.g. loud-quiet-loud, matching the style of `PauseSegmenter`'s own synthetic silence tests) returns an offset inside the quiet stretch.
3. `chainBoundaryOracle`: an oracle that always returns `nil` is correctly skipped in favor of the next one in the chain; a chain with zero oracles still produces an answer (falls through to the always-appended `MidpointBoundaryOracle`).
4. Clamping: a deliberately-broken test oracle that returns an offset OUTSIDE `[zoneStartSample, zoneEndSample)` gets clamped by `chainBoundaryOracle` before being returned.

- [ ] **Step 3: Build + self-test + safety check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test boundary-oracle'
```

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/BoundaryOracle.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add BoundaryOracle chain: mel-energy and midpoint layers

Pure Swift, no VAD dependency yet -- the VAD layer is added on top of
this chain in the next task without changing this protocol/chain
shape. MelEnergyBoundaryOracle reuses PauseSegmenter's own RMS
approach rather than reimplementing "what counts as quiet."

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `VadBoundaryOracle`

**Files:**
- Create: `swift/Sources/Parakey/VadBoundaryOracle.swift` (or add to `BoundaryOracle.swift` if it stays small — use judgment)

**Interfaces:**
- Consumes: Task 2's `sd_silero_vad_speech_probabilities` bridge function, `BoundaryOracle` protocol (Task 6).
- Produces: `struct VadBoundaryOracle: BoundaryOracle` — added to the chain used by Task 9 (`chainBoundaryOracle([VadBoundaryOracle(...), MelEnergyBoundaryOracle()])`, `MidpointBoundaryOracle` still auto-appended).

- [ ] **Step 1: Load the VAD model once, lazily, at the call site's ownership**

Per this project's "load-once" convention (mirroring `ParakeetEngine`'s single loaded context), `VadBoundaryOracle` should NOT reload the VAD model on every call. Design it to hold (or be handed) an already-created `SDSileroVadContext`-wrapping Swift type — decide during implementation whether that's a small `SileroVadEngine` class (analogous to `ParakeetEngine`, owning the context lifecycle, `warmUp`/`shutdown`) constructed once per app session and injected into `VadBoundaryOracle`, or some other shape — but it must NOT create/destroy a native context per overlap zone (that would reload an ONNX/ggml model on every seam of every long dictation, which is exactly the kind of per-call reload cost `TranscriptionWorker`'s design already deliberately avoids for the main ASR engine).

- [ ] **Step 2: Implement `chooseSplit`**

```swift
struct VadBoundaryOracle: BoundaryOracle {
    /// Below this speech probability, a window counts as "silent" for the
    /// purposes of finding the longest quiet run in the zone -- matches
    /// achetronic's tuned constant (DD-014's vadSilenceThreshold, in the
    /// documented 0.35-0.5 band).
    var silenceProbabilityThreshold: Float = 0.4
    let engine: SileroVadEngine  // exact type name/shape from Step 1

    func chooseSplit(samples: [Float], zoneStartSample: Int, zoneEndSample: Int, sampleRate: Double) -> Int? {
        guard zoneEndSample > zoneStartSample, !samples.isEmpty else { return nil }
        guard let probabilities = try? engine.speechProbabilities(samples: samples) else {
            return nil  // VAD unavailable/failed this call -- decline, chain falls through
        }
        guard let windowSize = probabilities.windowSizeSamples, windowSize > 0 else { return nil }

        // Find the CENTER of the LONGEST run of windows below the silence
        // threshold -- matches DD-014's vadBoundaryOracle exactly.
        var bestRunStart = -1
        var bestRunLength = 0
        var currentRunStart = -1
        var currentRunLength = 0
        for (index, probability) in probabilities.values.enumerated() {
            if probability < silenceProbabilityThreshold {
                if currentRunStart < 0 { currentRunStart = index }
                currentRunLength += 1
                if currentRunLength > bestRunLength {
                    bestRunLength = currentRunLength
                    bestRunStart = currentRunStart
                }
            } else {
                currentRunStart = -1
                currentRunLength = 0
            }
        }
        guard bestRunStart >= 0 else { return nil }  // nothing below threshold -- decline
        let centerWindowIndex = bestRunStart + bestRunLength / 2
        return zoneStartSample + centerWindowIndex * windowSize
    }
}
```

(`probabilities.windowSizeSamples`/`.values` here is a placeholder shape for whatever Swift-side wrapper Step 1 produces around `sd_silero_vad_speech_probabilities`'s raw `out_probabilities`/`out_count`/`out_window_size_samples` triple — adjust field names to match Step 1's actual type.)

- [ ] **Step 3: Self-test — pure logic over synthetic probability arrays, no real model**

Add a `vad-boundary-oracle` self-test group that constructs a **fake** object conforming to whatever minimal protocol `chooseSplit`'s VAD-probability-fetching depends on (inject a mock rather than a real `SileroVadEngine`, the same way Task 2 in the PRIOR plan tested `transcribeSegments` with a mock `transcribeOne` closure instead of a real ASR engine) — covering: a probability array with one clear low-probability run in the middle picks its center; multiple runs of different lengths picks the LONGEST one's center; an array with nothing below the threshold returns nil (declines); a VAD-fetch failure (mock throws) returns nil (declines).

- [ ] **Step 4: Real-model integration self-test (gated)**

A `vad-boundary-oracle-real` self-test group, gated behind `SUPERDICTATE_SILERO_VAD_MODEL` (same pattern as Task 2 Step 4), running the REAL `VadBoundaryOracle` against a short real or synthetic-but-realistic audio buffer with a genuine pause, confirming it picks a split point inside the actual pause.

- [ ] **Step 5: Build + self-test + safety check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test vad-boundary-oracle'
```

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/Parakey/VadBoundaryOracle.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add VadBoundaryOracle: Silero-VAD-refined seam placement

Loads the VAD model once (never per-seam), picks the center of the
longest low-speech-probability run in an overlap zone. Declines
(returns nil, falling through the chain to mel-energy/midpoint) on
any VAD failure or when nothing in the zone reads as silent.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Seam token dedup

**Files:**
- Create: `swift/Sources/Parakey/SeamDedup.swift`

**Interfaces:**
- Consumes: `Token` (Task 4).
- Produces: `struct AbsoluteToken: Sendable, Equatable { let text: String; let absoluteSeconds: Double }`, `func dedupSeam(_ orderedTokens: [AbsoluteToken], toleranceSeconds: Double = 0.24, lookbackCount: Int = 3) -> [AbsoluteToken]` — consumed by Task 9.

- [ ] **Step 1: Write `SeamDedup.swift`**

```swift
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
```

- [ ] **Step 2: Self-test — `seam-dedup`**

Add a self-test group covering:
1. **Exact duplicate**: two tokens with identical text and timestamps within tolerance -> only the first is kept.
2. **Collision**: two tokens with DIFFERENT text but timestamps within tolerance (simulating the same audio position transcribed differently by two overlapping windows) -> only the first (earlier) is kept, regardless of text.
3. **Correctly-kept-far-token**: two tokens whose timestamps differ by MORE than `toleranceSeconds` -> both kept.
4. **Empty input**: `dedupSeam([])` returns `[]`.
5. **Lookback window respected**: a token that collides with something MORE than `lookbackCount` tokens back (i.e. outside the lookback window even though within timestamp tolerance, if constructed adversarially) — confirm the actual intended behavior here: per DD-014 this is a positional lookback (last N *tokens*, not a time window), so a token far ahead in TOKEN COUNT but still within TIME tolerance of a token more than `lookbackCount` positions back should NOT be deduped against it. Write a test that constructs exactly this case and asserts both are kept, to pin this specific (slightly subtle) semantic.

- [ ] **Step 3: Build + self-test + safety check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && ./.build/debug/Parakey --self-test seam-dedup'
```

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/SeamDedup.swift swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Add timestamp-based seam token dedup

Pure, deterministic port of achetronic/parakeet's DD-014 dedupSeam:
operates on absolute token timestamps, never text comparison. Same
text at the same position is a duplicate; different text at the same
position is a collision resolved in favor of the earlier token.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Assembly — wire overlap + boundary oracle + token transcription + dedup into `transcribeSegmented`

**Files:**
- Modify: `main.swift`'s `transcribeSegmented` (lines ~6065-6113, may have shifted slightly — find by function name)

**Interfaces:**
- Consumes: everything from Tasks 1-8 (`OverlapWindower`, `BoundaryOracle`/`chainBoundaryOracle`/`VadBoundaryOracle`/`MelEnergyBoundaryOracle`, `ParakeetEngine.transcribeWithTokens`, `dedupSeam`).
- Produces: `transcribeSegmented`'s existing signature is UNCHANGED — this task only changes its internal behavior for the `segments.count > 1` case. All three existing call sites (hotkey release, `recoverActiveRecordingToHistory`, `recoverPendingDictationsAfterStartup`) need zero changes; they already funnel through this one function.

This is the highest-risk task in this plan — it's the integration point where every other task's pure, independently-tested logic gets composed into the real, production-facing behavior. Follow the plan's literal steps, but where a decision isn't fully pinned down below, make the choice that best preserves the graceful-degradation guarantee in this plan's Global Constraints, and document the choice in your report.

- [ ] **Step 1: Read the current `transcribeSegmented` in full**

Confirm its exact current shape (it may have shifted slightly from what's quoted below since prior commits) before modifying:

```swift
fileprivate func transcribeSegmented(
    samples: [Float],
    worker: TranscriptionWorker,
    language: DictationLanguage?,
    resolveViaKeyboard: Bool,
    requestedAt: TimeInterval
) async throws -> TranscriptionWorkerResult {
    let segments = PauseSegmenter.segment(samples: samples, sampleRate: SAMPLE_RATE)
    // ... (existing plain-text path via transcribeSegments(segments) { ... })
}
```

- [ ] **Step 2: Branch on segment count**

When `segments.count <= 1`, behavior must be completely unchanged (call the existing plain-text path exactly as today — do not even construct an `OverlapWindower`/`BoundaryOracle` call for this case, to guarantee zero added latency for the majority case per this plan's Global Constraints).

When `segments.count > 1`, attempt the new overlap+token+dedup path, described in Steps 3-6 below, WRAPPED such that any failure anywhere in it (a thrown error, a JSON decode failure, a VAD/bridge failure that even `VadBoundaryOracle`'s own internal decline-on-failure doesn't fully absorb, an unexpected empty result) falls back to calling the EXISTING plain-text `transcribeSegments`-based path for this dictation as a whole — i.e., structure this as a `do { <new overlap path> } catch { <existing plain path> }` (or equivalent), so a bug in any new code introduced by this plan degrades a multi-segment dictation to EXACTLY today's v0.4.6 behavior, never below it, and never crashes/hangs the app. Log which path was actually used (`log("overlap transcription path: succeeded")` / `log("overlap transcription path failed (\(error)), falling back to plain segmentation")`), so real-world usage of the new path is observable in `~/Library/Logs/SuperDictate.log` the same way this project already logs its ASR pipeline steps.

- [ ] **Step 3: Build overlap windows and transcribe each with tokens**

```swift
let windows = OverlapWindower.addOverlap(to: segments, sampleRate: SAMPLE_RATE)
var perWindowTranscriptions: [(window: AudioWindow, tokens: TokenTranscription)] = []
for window in windows {
    let tokens = try await worker.engine.transcribeWithTokens(samples: window.samples)  // adjust the exact access path to ParakeetEngine through TranscriptionWorker as the real code requires -- TranscriptionWorker is an actor owning `engine: ParakeetEngine?`; add whatever pass-through method TranscriptionWorker needs (mirroring how it already exposes `transcribe`) rather than reaching into a private property directly
    perWindowTranscriptions.append((window, tokens))
}
```

Note: `TranscriptionWorker.transcribe` already handles Vulkan-failure-mid-session CPU fallback (see its existing `do { ... } catch where isVulkanEngine { ... }` block) — the new `transcribeWithTokens` path Task 4 added to `ParakeetEngine` does NOT have this fallback built in. Decide during implementation whether `TranscriptionWorker` needs an equivalent `transcribeWithTokens` wrapper method that reuses the SAME Vulkan-fallback logic (recommended, for consistency — extract the fallback logic into a small shared helper if duplicating it verbatim would be too much repetition), or whether it's acceptable for a token-transcription call to simply throw on a Vulkan failure and let Step 2's catch-all degrade the WHOLE dictation to the plain path (also acceptable, since that path already handles Vulkan fallback correctly) — either is a reasonable choice; document which one you picked and why in your task report.

- [ ] **Step 4: Convert each window's tokens to absolute time and pick ownership boundaries**

For each pair of adjacent windows, compute the overlap zone in absolute-sample terms (from each window's `startSample`/`ownedStartSample`/`ownedEndSample`) and run it through `chainBoundaryOracle([VadBoundaryOracle(engine: ...), MelEnergyBoundaryOracle()])` (built once, reused across all seams in this dictation) to get a refined absolute split-sample offset per seam. Convert each window's `TokenTranscription.tokens` (window-relative `t` in seconds) to absolute seconds by adding `Double(window.startSample) / SAMPLE_RATE`, and keep only tokens whose absolute time falls within that window's (possibly oracle-refined) owned span.

- [ ] **Step 5: Map kept tokens to text pieces and dedup**

`TokenTranscription.tokens` gives token IDs/timestamps but Parakeet's tokens are SentencePiece pieces, not directly human-readable words on their own (a token doesn't carry its own decoded text string in this JSON shape per Task 3's documented format — only `id`, `t`, `conf`). Confirm the actual JSON shape at implementation time (re-check `parakeet_capi_transcribe_pcm_batch_json`'s doc comment, which also documents a top-level `"words"` array with `"w"`/`"start"`/`"end"`/`"conf"` — i.e. ALREADY-decoded whole words with their own timestamps, which is very likely the more directly useful array for this task's text-assembly purposes rather than raw sub-word tokens). **Prefer using the `words` array over the `tokens` array for seam dedup and text assembly if, after re-confirming the real JSON shape, `words` gives directly usable decoded text with its own timestamps** — adjust `Token`/`TokenTranscription`'s `Decodable` shape (Task 4) if needed to decode `words` instead of (or in addition to) `tokens`, and adjust `AbsoluteToken`'s conceptual source accordingly (an `AbsoluteToken` here would then represent one decoded WORD with its absolute start time, not a raw sub-word token — functionally equivalent for dedup purposes, and much simpler for final text assembly since it avoids SentencePiece detokenization entirely). Document this decision in your task report since it affects how literally Tasks 4's `Token`/`TokenTranscription` types get used here.

Once you have an ordered list of `AbsoluteToken`s spanning the whole dictation (one window's kept tokens/words, followed by the next window's, etc., each already filtered to its owned span from Step 4), run `dedupSeam(...)` (Task 8) over the full ordered list, then join the surviving tokens' text (with a single space between words, matching how `transcribeSegments`'s existing plain-text path already joins segment texts) to produce the final transcript string.

- [ ] **Step 6: Return the same `TranscriptionWorkerResult` shape**

Aggregate `engineCallSeconds`/`engineProcessingSeconds` across all windows (summed, matching the existing plain-text path's aggregation), `workerQueueSeconds` from the first window, and set `hadSegmentFailure` based on the SAME empty/signal logic the plain-text path already uses per window (reuse `AudioSegment.hasSignal` from the underlying segment each window was built from, not the window's overlapped audio) so the existing no-silent-data-loss safety net (retry/retain-on-loss, already shipped) continues to apply identically regardless of which path (overlap or plain) produced the text.

- [ ] **Step 7: Self-tests**

Given this task's heavy dependence on real bridge/model calls (token transcription genuinely needs the ASR engine; VAD needs its model), most of the deep logic here was ALREADY unit-tested in isolation by Tasks 1-8 with mocks/synthetic data. This task's own self-test coverage should focus on what's genuinely NEW at the integration level and can still be tested without a full model:
1. The `segments.count <= 1` short-circuit: confirm (via a mock/stub `TranscriptionWorker`-like seam, matching how the prior plan tested `transcribeSegments` with a mock closure) that a single-segment dictation never touches `OverlapWindower`/`BoundaryOracle` at all — e.g. by asserting call counts on a mock, or simply by code inspection during self-review if a clean mock seam isn't practical here (this project's actual `worker: TranscriptionWorker` dependency is a concrete actor type, not a protocol, so full mocking may require adding a protocol seam — use judgment on how much refactoring is worth it purely for this one test; if it's not practical without disproportionate surgery, note that in your report and rely on the real-hardware integration test below plus code review instead).
2. A gated real-hardware integration self-test (`overlap-transcription-real`, behind `SUPERDICTATE_PARAKEET_MODEL` and optionally `SUPERDICTATE_SILERO_VAD_MODEL`) that dictates (or loads a fixture recording of) a genuinely long, multi-segment passage and confirms: the final text is non-empty, contains no obviously duplicated word run at any known seam location, and total wall-clock time is roughly proportional to audio duration (no runaway blowup — sanity check against the empirically-confirmed danger zone this whole project exists to avoid).

- [ ] **Step 8: Build + self-test + safety check on the Mac**

```bash
git archive HEAD | ssh shohart@192.168.1.246 'rm -rf ~/scratch/sd-overlap && mkdir -p ~/scratch/sd-overlap && tar -x -C ~/scratch/sd-overlap'
ssh shohart@192.168.1.246 'cd ~/scratch/sd-overlap/swift && swift build -c debug --product Parakey'
```
Run whatever self-test groups apply, then the safety check. If `SUPERDICTATE_PARAKEET_MODEL`/`SUPERDICTATE_SILERO_VAD_MODEL` are staged on the Mac (check `~/Library/Application Support/SuperDictate/Models/` and wherever Task 1 placed the VAD model), also run the gated real-hardware test from Step 7.

- [ ] **Step 9: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "$(cat <<'EOF'
Wire overlap windows + boundary oracle + token dedup into transcribeSegmented

Multi-segment dictations now get audio overlap at each seam, refined
ownership boundaries via the VAD/mel-energy/midpoint oracle chain, and
timestamp-based dedup instead of the plain non-overlapping concatenation.
Any failure anywhere in this new path falls back to exactly today's
v0.4.6 plain-segmentation behavior for that dictation. Single-segment
dictations (the majority case) are completely unaffected -- zero added
latency, zero new code paths touched.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage**: overlap carved from existing 25s budget (Task 5), boundary-oracle cascade VAD→mel-energy→midpoint (Tasks 6-7), timestamp-based (not text-based) seam dedup (Task 8), token-timestamp bridge extension (Tasks 2-4), graceful degradation to v0.4.6 plain path on any failure (Task 9 Step 2), single-segment dictations unaffected (Task 5 Step 2 short-circuit, Task 9 Step 2 short-circuit) — every design-doc section maps to a task.
- **Out of scope confirmed**: no task adds a settings toggle; no task touches `swift/Sources/parakeet_cpp/upstream/**` (only the new, additive `upstream-vad/` sibling); no task proposes switching to ONNX Runtime.
- **Honesty about Task 1's nature**: unlike every other task in this plan (and unlike the prior plan's tasks, which all had complete, literal code to transcribe), Task 1 is explicitly flagged as research-grounded rather than copy-paste, because it vendors real third-party source this plan's author has not read verbatim — fabricating exact extraction code would have been worse than being explicit about what's verified fact (repo, commit, function names, model URLs, licenses) versus what requires implementer-time verification (exact current line numbers/signatures, precise extraction boundaries).
- **Type consistency**: `AudioWindow` (Task 5) consumed by name in Tasks 6/7/9; `BoundaryOracle`/`chainBoundaryOracle` (Task 6) consumed by name in Tasks 7/9; `Token`/`TokenTranscription` (Task 4) consumed by name in Tasks 8/9, with Task 9 Step 5 explicitly flagging and resolving the one real ambiguity found during planning (tokens vs. words as the dedup/assembly unit) rather than leaving it silently inconsistent across tasks.
