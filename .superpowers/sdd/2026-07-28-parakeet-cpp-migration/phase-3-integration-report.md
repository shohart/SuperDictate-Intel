# Phase 3 — application integration, CPU only, Whisper deleted (Checkpoint B)

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`. Spec:
`docs/parakeet-intel-backend.md`. Branch
`agent/parakeet-intel-backend-architecture`, worktree
`.worktrees/parakeet-migration`. Everything reported here ran for real on
the Intel Mac (`shohart@192.168.1.246`: Intel Xeon E5-2678 v3, macOS
15.7.7, x86_64), synced from this worktree to a fresh scratch directory
`~/scratch/parakeet-phase3/repo/` via `tar` over SSH (same method as every
prior phase). `defaults write com.local.superdictate agent_enabled -bool
false` was run before every scratch launch; the real production app at
`/Applications/SuperDictate.app` and its LaunchAgent were never touched.

## 1. What's vendored

`scripts/vendor-parakeet-cpp.sh` (new) clones `mudler/parakeet.cpp` at the
pinned commit, verifies the checkout and its pinned ggml submodule exactly,
and writes a deterministic tree into
`swift/Sources/parakeet_cpp/upstream/`:

- `upstream/include/` — `parakeet_capi.h`, `parakeet.h` (upstream's own
  public headers) + ggml's public headers (`ggml.h`, `ggml-alloc.h`,
  `ggml-backend.h`, `ggml-cpu.h`, `ggml-blas.h`, `gguf.h`, etc.).
- `upstream/*.cpp` / `*.hpp` — parakeet.cpp's own inference sources
  (`parakeet.cpp`, `model.cpp`, `encoder.cpp`, `tdt.cpp`, `tokenizer.cpp`,
  `transcription.cpp`, …), flat, matching upstream's own single-directory
  `src/` layout — plus `dr_wav.h` (a separate single-header WAV-decode
  dependency parakeet.cpp itself vendors).
- `upstream/*.c` / `*.cpp` (ggml core) — `ggml.c`, `ggml.cpp`,
  `ggml-alloc.c`, `ggml-backend.cpp`, `ggml-backend-reg.cpp`,
  `ggml-backend-dl.*`, `ggml-backend-meta.cpp`, `ggml-opt.cpp`,
  `ggml-quants.*`, `ggml-threading.*`, `gguf.cpp`, `ggml-blas.cpp` — the
  same file set this fork's existing `scripts/vendor-whisper-cpp.sh`
  already established as sufficient for a CPU+Accelerate/BLAS ggml build,
  reused here since it's the same ggml lineage's layout.
- `upstream/ggml-cpu/` — the CPU backend directory, non-x86 arch variants
  (`arm`, `riscv`, `powerpc`, `s390`, `wasm`, `loongarch`) and build tooling
  (`kleidiai`, `spacemit`, `cmake`, `CMakeLists.txt`) stripped, `amx/` and
  `llamafile/` kept (same exclusion set as the whisper vendor script).
- `upstream/LICENSE-parakeet-cpp.txt`, `upstream/LICENSE-ggml.txt` — exact
  upstream MIT notices at the pinned commits (named `.txt`, not `.cpp`/`.c`,
  after a real build failure the first time: SwiftPM auto-compiles anything
  under the target with a `.c`/`.cpp` extension, and a file literally named
  `LICENSE-parakeet.cpp` was picked up as an invalid C++ translation unit).
- `upstream/PROVENANCE.md` — generated commit/vintage metadata.

No Vulkan/CUDA/HIP/Metal/CoreML sources are vendored this phase (CPU only).

Hand-authored, NOT touched by the vendor script (lives outside
`upstream/`, so a re-vendor never discards it):

- `swift/Sources/parakeet_cpp/include/superdictate_parakeet.h` — the
  SuperDictate C bridge's own header.
- `swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp` — the
  bridge implementation.
- `swift/Sources/parakeet_cpp/include/module.modulemap` +
  `parakeet_cpp_module.h` — the SwiftPM module glue, exporting ONLY the
  SuperDictate bridge header to Swift (upstream's `parakeet_capi.h` /
  `parakeet.h` are never directly visible from Swift).

**Vendored tree size**: 137 files, 4.5 MB (`upstream/`), vs. the deleted
`whisper_cpp` tree's ~57 MB (dominated by its 1785-file precompiled Vulkan
SPIR-V shader corpus, which had no Vulkan-capable successor to carry over
this phase).

**Pin verification** (re-confirmed for real, matching Phase 2 exactly):
`parakeet.cpp` @ `e747acdaee69b916cef62263ae5f718bda9ff3f3`, ggml submodule @
`e705c5fed490514458bdd2eaddc43bd098fcce9b` (tag `v0.13.0`). Both re-checked
by the vendor script's own fail-on-mismatch logic and by direct `git
rev-parse`/`git describe` during this phase's actual run — exact match, no
drift since Phase 2.

## 2. SwiftPM target

`swift/Package.swift`: `whisper_cpp` target deleted outright, replaced with
a `parakeet_cpp` target. `Parakey`'s `dependencies` changed from
`["whisper_cpp"]` to `["parakeet_cpp"]` — exactly one ggml copy in the tree
at all times, per the plan's non-negotiable constraint.

- **cSettings/cxxSettings**: `GGML_USE_ACCELERATE`, `GGML_USE_CPU`,
  `GGML_USE_BLAS`, `GGML_USE_LLAMAFILE` (parakeet.cpp's own default —
  tinyBLAS SGEMM, ~25% free speedup per its own CMakeLists comment),
  `GGML_BLAS_USE_ACCELERATE`, `ACCELERATE_NEW_LAPACK`,
  `ACCELERATE_LAPACK_ILP64`, `GGML_VERSION`/`GGML_COMMIT`/
  `PARAKEET_VERSION` string defines, header search paths
  `upstream`/`upstream/include`/`upstream/ggml-cpu`, and the same
  Intel-ISA flags this fork already carried for `whisper_cpp`:
  `-mavx2 -mfma -mf16c -mbmi2 -msse4.2`.
- **linkerSettings**: `Accelerate`, `Foundation` frameworks, `c++` library.
  No Vulkan/MoltenVK linking this phase (no `-I`/`-l` flags for it at all —
  clean removal, not just unused).
- No excludes needed at the SwiftPM level (unlike `whisper_cpp`'s Metal
  exclude list) — non-x86 arch variants were already stripped by the
  vendor script itself. `amx/` is compiled in unguarded (same as
  `whisper_cpp` did) — `ggml-cpu.cpp` calls `ggml_backend_amx_buffer_type()`
  /`ggml_cpu_has_amx_int8()` unconditionally, so excluding the directory
  would break the link; its actual AMX codegen paths stay inert without
  `__AMX_INT8__`/`__AVX512VNNI__` defines, which this target does not set.

## 3. Bridge design

`docs/parakeet-intel-backend.md` §7 sketched an aspirational `SDParakeet*`
C ABI, written before this branch's research had confirmed parakeet.cpp's
own C-API (`upstream/include/parakeet_capi.h`) already provides equivalent
load-once, PCM-in/UTF-8-out, exception-free semantics
(`parakeet_capi_load`, `parakeet_capi_transcribe_pcm`,
`parakeet_capi_free_string`, `parakeet_capi_free`,
`parakeet_capi_last_error` — all real, confirmed by reading the actual
pinned header). Per the task brief's explicit direction, the bridge built
here is a thin wrapper over that real API, not a from-scratch reinvention:

- `sd_parakeet_create(model_path, options, out_context)` — loads the model
  once via `parakeet_capi_load`, sets the process-global thread count via
  `pk::set_num_threads()` (the same mechanism `examples/cli`'s own
  `--threads` flag uses) before loading. Requesting
  `SD_PARAKEET_DEVICE_VULKAN` fails immediately with
  `SD_PARAKEET_ERR_VULKAN_UNAVAILABLE` — checked BEFORE the model-path
  check (an ordering bug found and fixed during this phase's own
  self-testing: the reverse order returned `modelNotFound` first for a
  simultaneously-nonexistent-and-Vulkan test case, masking the real
  Vulkan-unavailable signal).
- `sd_parakeet_warm_up(context)` — runs one real inference over a 0.5s
  synthetic silence buffer through `parakeet_capi_transcribe_pcm`, guarded
  by an atomic "busy" flag (single-flight per context, independent of
  whatever Swift-side actor isolation also enforces it).
- `sd_parakeet_transcribe(context, samples, sample_count, sample_rate,
  out_result)` — validates null pointers, zero sample count, a
  20-minute (`SD_PARAKEET_MAX_AUDIO_SECONDS`) duration ceiling, and the
  `uint64_t` → native `int n_samples` narrowing conversion, all before
  calling down; times the native call with `std::chrono::steady_clock`;
  every call site is wrapped in `try { … } catch (...) { … }`, matching
  parakeet_capi's own internal exception containment as defense in depth.
- `sd_parakeet_result_destroy` / `sd_parakeet_destroy` — matching free
  functions for every allocation.
- `sd_parakeet_backend_device` / `sd_parakeet_last_error_message` /
  `sd_parakeet_runtime_version` — diagnostics, the last proxying
  `parakeet_version()`.

Real build note: `include/module.modulemap` exports only
`superdictate_parakeet.h` to Swift — `parakeet_ctx`, `pk::Model`, and every
other upstream C++ type stay invisible to Swift, per spec §7's "do not
expose upstream C++ types directly to Swift".

## 4. `ParakeetEngine` Swift wrapper

`swift/Sources/Parakey/ParakeetEngine.swift` (new; replaces
`WhisperEngine.swift`, which is deleted). An `actor`, same
single-loaded-context shape as `WhisperEngine`:

- `init(modelPath:device:threadCount:) throws` — synchronous (actor inits
  don't need `await`), checks the requested device before the model path
  (mirroring the bridge fix above), throws typed `ParakeetEngineError`.
- `func warmUp() async throws`
- `func transcribe(samples:sampleRate:) throws -> ParakeetTranscriptionResult`
  — scoped `withUnsafeBufferPointer`, never called with an empty array
  (checked before the native call), converts the returned C string via
  `String(validatingCString:)`, always calls `sd_parakeet_result_destroy`
  via `defer`.
- `func shutdown()` / `deinit` — both route through a private
  `destroy(context:)` that nils the stored `OpaquePointer?` before freeing,
  so a `deinit` running after an explicit `shutdown()` cannot double-free
  (the earlier `WhisperEngine`-style `deinit { whisper_free(context) }`
  pattern would have double-freed here since this actor's `shutdown()` is
  also called explicitly from `TranscriptionWorker.unload()`).
- `nonisolated func backendDescription() -> String` — always `"CPU"` this
  phase; kept as a method (not just the stored `device` property) so
  Phase 5 can make it reflect a real fallback decision without changing
  call sites.

Typed errors (`ParakeetEngineError`): `.modelNotFound`, `.modelLoadFailed`,
`.vulkanUnavailable`, `.warmUpFailed`, `.inferenceFailed`, `.invalidUTF8`,
`.emptyAudio`, `.busy`, `.nativeBridgeFailure` — trimmed from spec §15's
full list to what's reachable without GPU code in this phase (no
`modelChecksumMismatch`/`requestedDeviceNotSelected` cases inside the
engine itself — checksum verification lives in the downloader, and
"requested device not selected" reduces to `.vulkanUnavailable` since
Vulkan can never be silently substituted for CPU this phase).

## 5. TranscriptionWorker migration

`main.swift`'s `LoadedSpeechEngine` enum (`.whisperLargeV3Turbo(WhisperEngine)`,
the plan's single-case-enum-instead-of-engine-picker precedent) is gone
entirely — `TranscriptionWorker` now holds `private var engine:
ParakeetEngine?` directly, matching spec §9's shape.

- `load(profile:progressHandler:)` reads `Settings.shared.useGPU`, logs an
  honest note if it's `true` ("Vulkan is not yet implemented in this
  build — using Parakeet CPU") and always loads CPU this phase (the
  Vulkan probe/fallback branch from spec §9.1 step 4 is Phase 5's job, per
  the plan's explicit "skip the Vulkan branch this phase" instruction).
  Logs the full spec §16 startup line set (`ASR model:`, `ASR runtime:`,
  `ASR device requested:`, `ASR device selected:`, `ASR threads:`,
  `ASR warm-up:`).
- `loadParakeetEngine(progressHandler:)` downloads/verifies the GGUF,
  resolves the thread count via
  `TranscriptionWorker.resolvedParakeetThreadCount()` (spec §10's
  `max(2, min(8, activeProcessorCount/2))` policy with a validated
  `SUPERDICTATE_ASR_THREADS` override, `1...32`), constructs the engine,
  and runs its internal warm-up BEFORE returning — so `ready = true` is
  only set after a real successful warm-up, per spec §11.3/§9.1 step 5.
  After a successful load, calls `removeLegacyWhisperModelFileIfPresent()`
  (best-effort, never blocks startup on failure) — spec §4.3/§4.4's
  optional legacy-cleanup step.
- `transcribe(samples:language:resolveViaKeyboard:requestedAt:)` keeps the
  existing `inFlight` reentrancy backstop and the actor-hop-to-MainActor
  for the Carbon keyboard-layout call, but no longer passes a language
  string into the native call — parakeet.cpp's plain PCM transcription
  entry point (`parakeet_capi_transcribe_pcm`, the one this bridge wraps)
  does not accept a forced-language parameter at all, unlike
  `whisper_full_params.language`. The resolved effective language is still
  computed (for `ParakeetTranscriptRepair`'s Russian/`ё` branch selection),
  just not forwarded to native code. This is a real, documented limitation
  (see §9 below), not an oversight.
- `unload()` now calls `await engine.shutdown()` before clearing the
  field, so the native context is always destroyed deterministically on
  unload (Whisper's actor `deinit` alone used to be the only cleanup
  path; Parakeet's needed an explicit synchronous shutdown call because
  Swift actor `deinit` cannot be `async`, and `shutdown()` needing to call
  a native `_destroy` function should not be left to `deinit`-only timing).

## 6. Model storage and downloader

New location per spec §4.1:
`~/Library/Application Support/SuperDictate/Models/tdt-0.6b-v3-q8_0.gguf`
(NOT the old `~/Library/Application Support/Whisper/Models`).

`downloadParakeetModelIfNeeded()` (replaces `downloadWhisperModelIfNeeded`,
same file section, renamed per spec §4.2's suggested naming
— `SpeechModelDownloadProgressHandler`, `ParakeetModelDownloadError`):

1. Rejects a cached destination that isn't a plain regular file
   (`isPlainRegularFile`, an `lstat`-based check that doesn't follow
   symlinks — new, stricter than the Whisper downloader's simple
   `fileExists` check, added per spec §4.2 item 1-2).
2. Verifies both byte size AND SHA-256 of an existing cached file (the old
   Whisper downloader only checked SHA-256; size is now checked first,
   cheaply, before paying for a full-file hash).
3. Runs the existing disk-space check
   (`assertSufficientDiskSpaceForSpeechModelDownload`) before downloading.
4. Downloads via `URLSession.shared.download`, then explicitly moves the
   result to a same-volume temp file (a dotfile,
   `.tdt-0.6b-v3-q8_0.gguf.download-<uuid>`, in the destination directory)
   before verifying — guaranteeing the final `replaceItemAt` is a
   same-volume atomic rename, never a cross-volume copy, even though the
   system temp directory `URLSession` itself uses could in principle be a
   different volume.
5. Verifies size AND SHA-256 of the temp file before the atomic
   `FileManager.replaceItemAt(_:withItemAt:)` swap into the production
   filename — the file is never exposed under its production name until
   fully verified.
6. On any verification failure, removes only the exact temp file.

`isSafeSpeechModelCacheDirectory`/`isExistingSpeechModelCacheDirectorySafeForRemoval`
(the symlink/`..`/unexpected-root rejection logic, unchanged algorithm)
now anchor under `~/Library/Application Support/SuperDictate` (renamed
parameter `parakeetSupportDirectory`, was `whisperSupportDirectory`) instead
of `~/Library/Application Support/Whisper`. `removeSpeechModelCacheDirectory`
(used by the existing "Reset Speech Model Cache" menu action) needed no
changes — it's already generic over whatever `speechModelCacheDirectory(for:)`
resolves to.

**Legacy Whisper cache**: `~/Library/Application Support/Whisper` is left
completely alone (spec §4.4) — confirmed for real: after this phase's real
download+load+warm-up run, `~/Library/Application Support/Whisper/Models/ggml-large-v3-turbo.bin`
(1,624,555,275 bytes, from an earlier, unrelated phase's testing on this
same Mac) was still present, unmodified, untouched. `removeLegacyWhisperModelFileIfPresent()`
exists (best-effort, only removes that exact known file, never the
directory) but wasn't triggered to actually delete it in this run's
specific test path (the model-download hook used for verification called
`downloadParakeetModelIfNeeded`+`ParakeetEngine.warmUp()` directly, not
the full `TranscriptionWorker.load()` path that calls the cleanup — see
§10 below for what was and wasn't exercised through which path).

**Real download verified end to end** (see §10): 940,663,680 bytes
downloaded in 88.58s over this machine's real network connection,
SHA-256 `4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757`
— exact match to the pinned value, computed fresh from the real downloaded
file at the new path, not reused from Phase 2's separate scratch copy.

## 7. Whisper removal

`swift/Sources/whisper_cpp/` (the entire vendored whisper.cpp+ggml+Vulkan
shader tree, ~57 MB, 1911 files) deleted outright, along with:

- `swift/Sources/Parakey/WhisperEngine.swift` — deleted, replaced by
  `ParakeetEngine.swift`.
- `scripts/vendor-whisper-cpp.sh`, `scripts/gen-vulkan-shader-runtime.py`,
  `scripts/vulkan-shader-runtime/` — deleted (all whisper/its-Vulkan-vintage
  specific; superseded by `scripts/vendor-parakeet-cpp.sh`, which has no
  Vulkan section this phase).
- `scripts/build-app.sh` — the `cp -R .../whisper_cpp/vulkan-shaders
  .../Contents/Resources/vulkan-shaders` resource-copy step removed (no
  Vulkan shader corpus exists this phase to copy).
- `swift/Package.swift` — `whisper_cpp` target, `WHISPER_VERSION`/
  `GGML_VERSION`/`GGML_COMMIT` (whisper's own values) compile defines, the
  Vulkan/MoltenVK linker flags all removed.
- `main.swift`/`KeyboardLanguage.swift` — every Whisper-specific type,
  function, and constant renamed or removed: `SpeechModelProfile` reduced
  from a 2-case enum (`.multilingualV3`/`.englishUnified`, with Whisper
  display strings) to a single `.parakeetTDTv3` case (spec §14: "there is
  one speech model, so do not show a model picker" — no picker UI existed
  to remove, since this app never had one; the enum itself just needed its
  content updated); `WHISPER_MODEL_URL`/`_SHA256`/`_SIZE_BYTES` →
  `PARAKEET_MODEL_URL`/`_SHA256`/`_SIZE_BYTES` (+ `_REPOSITORY`/
  `_REVISION`/`_FILENAME`/`_ARCH`/`_QUANTIZATION`, per spec §3);
  `WhisperModelDownloadError` → `ParakeetModelDownloadError`;
  `WhisperDownloadProgressHandler` → `SpeechModelDownloadProgressHandler`;
  `resolveEffectiveWhisperLanguage`/`whisperLanguageCode` →
  `resolveEffectiveDictationLanguage`/`isoLanguageCode`/
  `dictationLanguageCode(forKeyboardLanguageTag:)`; `SpeechModelTextRepair`
  → `ParakeetTranscriptRepair`; the `WhisperEngine.audioContextFrames`
  self-tests (no Parakeet equivalent — parakeet.cpp's encoder architecture
  has no `audio_ctx` window-trimming concept) removed rather than ported.

**Verification** (real commands, on the actual built release binary):

```
$ rg -n -i "whisper|large-v3-turbo|whisper_cpp" . 
```
Remaining matches are exclusively: (a) this report and the plan/checklist
documents describing the migration itself, (b) narrowly-scoped legacy-cache
handling code/comments (`resolvedParakeetSupportDirectory`'s sibling —
actually the legacy path helper — `legacyWhisperModelFilePath()`,
`removeLegacyWhisperModelFileIfPresent()`, and their doc comments,
deliberately referencing the OLD path so it can be cleaned up), (c) a
handful of self-test assertions that intentionally exercise migration
behavior (old raw UserDefaults values like `"multilingual_v3"`/
`"english_unified"` should still normalize to the Parakeet default — the
whole point of that test is proving the OLD value is *not* trusted
anymore), and (d) README's "old Whisper cache… not used in this version"
note. No production Whisper runtime code path remains.

```
$ nm -gU ./dist/SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
(no output)
$ strings ./dist/SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
(no output)
```

Both empty, confirmed on the real built binary.

## 8. New GPU-preference key

`Settings.useGPU`'s backing `UserDefaults` key changed from `"use_gpu"` to
`"parakeet_use_gpu"` (spec §10) — the Swift property name is unchanged
(`useGPU`) but the persisted key is new, so an upgraded install with the
old Whisper Vulkan preference enabled starts Parakeet on CPU (reads the new
key, which is unset, defaults `false`). The `Use GPU (Vulkan)` menu item's
tooltip was updated to state plainly that Vulkan isn't implemented in this
build yet and that enabling it currently has no effect beyond a log note
(honest UI state, not a dead/misleading control — Phase 5 wires the actual
behavior).

## 9. `<unk>`/`ё` empirical finding

**`<unk>` does NOT appear.** Empirically confirmed across two independent
tests on the real Intel Mac, using the exact pinned model/commit:

1. All 14 clips of the Phase 1 Russian/English benchmark corpus
   (`~/scratch/parakeet-phase1/corpus/*.wav`, still present unmodified),
   transcribed via `parakeet-cli` (Phase 2's proven build, same pinned
   commit/model) — zero `<unk>` tokens in any transcript, matching Phase
   2's smaller 6-clip sample.
2. A NEW, targeted test clip specifically engineered to contain "ё": `say
   -v Milena "Я ем мёд каждый день. Её зовут Алёна. Ёлка стоит в углу возле
   её дома. Мой пёс бежит за ней."` (sentence-initial, mid-word, and
   mid-sentence occurrences), converted to 16 kHz mono WAV, transcribed
   through the same real pinned `parakeet-cli`/model.

**Actual output**: `"Я ем мед каждый день. Ее зовут Алена. Елка стоит в
углу возле ее дома. Мой пес бежит за ней."` — every "ё" was silently
normalized to "е" (мёд→мед, Её→Ее, Алёна→Алена, Ёлка→Елка, её→ее, пёс→пес).
**No `<unk>` token appeared anywhere.** This is a different quirk than the
old CoreML/ANE Parakeet stack's documented `<unk>`-for-`ё` behavior
(itself a different runtime, per the plan's own caveat) — this pinned
parakeet.cpp+GGUF combination's vocabulary/tokenizer appears to simply
treat ё/е as equivalent (a common casual-Russian-orthography simplification
NeMo-family models are known to pick up from training data), not as an
unknown token.

**Decision, per the plan's explicit instruction**: since the `<unk>` quirk
was NOT confirmed, no new repair logic was written speculatively.
`ParakeetTranscriptRepair` (the renamed `SpeechModelTextRepair`) was kept
in the pipeline exactly as-is — it's already guarded by
`text.localizedCaseInsensitiveContains("<unk>")` at its very first line,
so it's a genuine no-op given this build's real output, not
dead/speculative code. Its existing test coverage (now under the new name,
plus a new dedicated `parakeet-text-repair` self-test group — see §11)
still passes and still matters as a safety net in case a different
model/quantization/future parakeet.cpp version ever does emit `<unk>`.

**The е/ё normalization itself is a known, documented limitation** (not
addressed by new repair logic in this phase — it wasn't in scope, and
"fix casual Russian orthography" is a much broader, separately-designed
feature than the specific `<unk>` quirk this phase was asked to verify).
Recorded here for whoever picks this up next.

## 10. Self-test results

Full suite, real hardware:

```
$ swift run -c debug --package-path swift Parakey --self-test all
...
PASS all
```

New groups added this phase (spec §18's `parakeet-bridge`/`parakeet-model`/
`parakeet-cpu`/`parakeet-vulkan`/`parakeet-text-repair` — `parakeet-model`
folded into `parakeet-bridge` since model metadata/download-safety
assertions were small enough to share a group; `parakeet-vulkan` is not
implemented — no Vulkan code exists this phase to test):

- **`parakeet-bridge`** (spec §18.1, no large model needed): invalid model
  path → `.modelNotFound`; requesting Vulkan → `.vulkanUnavailable`
  (deterministic, not silent CPU fallback); `parakeet.cpp` runtime version
  string non-empty; the full `resolvedParakeetThreadCount` policy matrix
  (floor/cap/mid-range/valid-override/out-of-range-override/non-numeric-override);
  pinned model size/SHA-256/filename match the values verified in Phase 2.
  **PASS.**
- **`parakeet-text-repair`**: sentence-initial, mid-word,
  punctuation-adjacent, repeated-token, non-Russian, and no-op cases for
  `ParakeetTranscriptRepair.apply`, verified against the function's actual
  traced behavior (not just expected-looking assertions — each expected
  string was derived by hand-tracing the real capitalization/spacing
  logic). **PASS.**
- **`parakeet-cpu`** (spec §18.2, real model via
  `SUPERDICTATE_PARAKEET_MODEL`): loads the real pinned GGUF, warms up,
  transcribes a fixed near-silence PCM fixture, repeats inference on the
  SAME loaded context, destroys and recreates the context. Skipped (not
  failed) when the env var isn't set, matching spec §18.2/§18.3's "mark
  skipped, not passed" requirement. **PASS** (real run):
  `load 0.56s, threads 8, infer 1.214s, RTF 2.429` (near-silence input, so
  RTF > 1 is expected — real speech RTF is far below 1, see the Phase 2
  report's 0.13-0.14 figures on real corpus clips through the same
  model/commit).

`--self-test all` includes `testParakeetTranscriptRepair` and
`testParakeetBridge` (both fast, no model needed); `testParakeetCPUIntegration`
is intentionally excluded from `--self-test all` (same pattern as the
existing `audio-input-live`/`insertion-target-live` groups) since it needs
the ~940 MB model pre-staged — it's run explicitly via
`--self-test parakeet-cpu`.

An ordering bug was found and fixed during this self-testing (see §3):
`ParakeetEngine.init`/the bridge's `sd_parakeet_create` originally checked
model-path existence before device validity, so a simultaneously-invalid
path + Vulkan-requested test case reported `.modelNotFound` instead of
`.vulkanUnavailable`, masking the real signal. Fixed by reordering the
guards; caught by the very self-test written to verify the behavior, before
it ever reached the Mac's `swift run` — real value of writing the test
first.

## 11. End-to-end verification method and result

**What was verified through the real, actual application code path (not
just self-tests):**

1. **Real self-test suite** (`swift run -c debug --package-path swift
   Parakey --self-test all`) — PASS, on real hardware, including real
   native-bridge calls for `parakeet-bridge` and a real model load/warm-up/
   transcribe/repeat/destroy-recreate cycle for `parakeet-cpu`.
2. **Real release build** (`./scripts/build-app.sh ./dist/SuperDictate.app`)
   — succeeded (220.66s wall time for the release compile, matching this
   project's own documented slow-single-file-compile characteristic for
   `main.swift`'s ~23,000 lines — see the plan's "Future work" note).
3. **`codesign --verify --deep --strict ./dist/SuperDictate.app`** — passed.
4. **`otool -L`** on the built binary — only system frameworks + Swift
   runtime dylibs + `libc++`/`libobjc`/`libSystem`. Zero Homebrew/MoltenVK/
   Vulkan dependencies (expected — none are linked this phase).
5. **`file`/`lipo -info`** — confirmed `x86_64` Mach-O executable.
6. **Whisper-absence checks** — `nm -gU`/`strings` both return zero matches
   for "whisper" on the actual built binary.
7. **Real model download, through the ACTUAL production
   `downloadParakeetModelIfNeeded()` function** (not a mock, not a
   pre-staged file): a temporary debug CLI hook (`--download-parakeet-model`,
   reverted before this commit — see below) called the real function
   against the real pinned Hugging Face URL. Result: 940,663,680 bytes
   downloaded to the real new path
   (`~/Library/Application Support/SuperDictate/Models/tdt-0.6b-v3-q8_0.gguf`)
   in 88.58s, SHA-256 verified to match the pinned value exactly, file
   atomically renamed into place. Then loaded via the real
   `ParakeetEngine.init` + `warmUp()` against that just-downloaded file:
   warm-up completed in 1.27s. The legacy Whisper cache file at
   `~/Library/Application Support/Whisper/Models/ggml-large-v3-turbo.bin`
   was confirmed present and untouched afterward.

**What was NOT separately verified beyond self-tests** (honest gap):

- The full `TranscriptionWorker` actor path (hotkey → capture → transcribe
  → paste → history) was not exercised through a live GUI dictation with a
  physical keypress this phase. An attempt to build a temporary
  `--transcribe-file` debug hook that decoded a real WAV fixture via
  `AVAudioFile`/`AVAudioConverter` and ran it through the full
  `TranscriptionWorker.load()`/`.transcribe()` actor path hung
  indefinitely (see the root-cause note below) and was abandoned in favor
  of the narrower, successful `--download-parakeet-model` hook plus the
  `parakeet-cpu` self-test (which does exercise the real
  `ParakeetEngine.transcribe()` path, just not through
  `TranscriptionWorker` itself, and not via a real audio file — a
  synthetic near-silence buffer). `TranscriptionWorker.transcribe()`'s own
  logic (delegating to `ParakeetEngine.transcribe`, computing timing
  breakdowns, the reentrancy guard) is otherwise unchanged in shape from
  the already-proven `WhisperEngine` call site it replaces, and was code-
  reviewed carefully rather than re-verified live.
- A live GUI dictation via the real hotkey (right Command) → HUD →
  paste-at-cursor → history flow was not performed interactively in this
  session (no physical keypress, per the task brief's own allowance for
  this substitute evidence path when that's awkward headlessly).

**Root cause note on the abandoned `--transcribe-file` hook** (kept here
since it's a real, instructive finding, not just a dead end): a `sample`
trace on the hung process showed the main thread permanently blocked in
`semaphore_wait_trap`, with **zero other threads ever created** —
confirming the `Task { }` closure body never started executing at all.
Root cause: Swift 6's default top-level-code MainActor isolation. A plain
`Task { }` created at true top-level file scope in this executable
inherits the enclosing (implicitly MainActor-isolated) context; with no
run loop pumping in a bare command-line invocation, the only thread that
can ever run MainActor-isolated work (the main thread) was itself
synchronously blocked on `semaphore.wait()` immediately after creating the
Task — a self-deadlock. Confirmed and fixed for the (simpler,
AVFoundation-free) `--download-parakeet-model` hook by switching to
`Task.detached { }`, which breaks isolation inheritance and always runs on
the global concurrent executor; that hook then worked correctly and
produced the real download result reported above. This is a property of
writing a bare top-level debug CLI entry point in this specific Swift 6
executable, not a bug in `TranscriptionWorker`/`ParakeetEngine`/the bridge
— production code paths run under `NSApplication`'s real run loop, where
MainActor-isolated `Task`s make progress normally. Both temporary hooks
(the abandoned AVAudioFile one and the working download-only one) were
fully removed before this phase's commit, per the task brief's explicit
"revert before final commit" instruction — nothing in `main.swift` reflects
either any longer.

## 12. Known limitations / what's left for later phases

- **Vulkan is not implemented this phase** (by design — Phase 5's job).
  `ParakeetDevice.vulkan` and the bridge's `SD_PARAKEET_DEVICE_VULKAN`
  enum case exist as stable shape for Phase 5, but requesting them fails
  deterministically today. A separate, standalone Phase 5 pre-spike
  (`.superpowers/sdd/2026-07-28-parakeet-cpp-migration/phase-5-vulkan-prespike-report.md`,
  committed to this same branch by a parallel effort during this phase's
  own work, not touching anything under `swift/`) already confirms the
  Vulkan build succeeds against this exact pinned ggml v0.13.0 and the
  real RX 6600 beats CPU by 30-63% on a small benchmark — real head start
  for whoever picks up Phase 5.
- **No forced-language decoding.** parakeet.cpp's plain PCM transcription
  entry point doesn't accept a language parameter; only the
  `_lang`-suffixed variants do (for prompt-conditioned "nemotron" models —
  this pinned model's arch is `hybrid_tdt_ctc`, not confirmed to be a
  prompt model). This app never forced whisper.cpp's language decoding for
  auto-detect either, but it DID trim whisper's `audio_ctx` window when a
  language was explicitly selected; there's no equivalent lever for
  Parakeet. Documented as a real, structural limitation rather than
  worked around with fake token-filtering (which spec §12 explicitly
  forbids).
- **е/ё casual-orthography normalization** (see §9) is real, observed
  behavior, NOT specifically addressed by new repair logic this phase —
  flagged for whoever next touches transcript quality.
- **RU localization of a few newer strings** (e.g. the `Use GPU (Vulkan)`
  tooltip's new "not yet implemented" wording) was written English-only;
  the pre-existing startup-progress strings (`Проверяю…`/`Скачиваю…`/etc.)
  were already model-neutral and needed no changes.
- **About-dialog text** was NOT rewritten to spec §14's exact suggested RU/EN
  wording — the existing About panel already surfaces
  `settings.speechModelProfile.aboutModelText` (now correctly
  "parakeet.cpp · NVIDIA Parakeet TDT 0.6B v3 multilingual · GGUF q8_0")
  plus a generic "Local-only dictation. No cloud transcription, no
  telemetry." line, which is accurate but not a literal match to spec
  §14's suggested paragraph. Not revisited given the time budget; low risk
  since the substance (local-only, no telemetry, correct model name) is
  already there.
- **CPU thread count / RTF on real speech** wasn't independently
  re-benchmarked this phase beyond the near-silence `parakeet-cpu`
  self-test's numbers — Phase 2's report already has real-speech RTF
  figures (0.13-0.14, i.e. 7-8x faster than real-time) against the exact
  same pinned commit/model/hardware; Phase 4 is the plan's dedicated A/B
  benchmarking phase and will re-measure through the now-integrated Swift
  path specifically.

## 13. Files changed (summary; see `git diff`/`git status` for the exact
list)

**Added**: `scripts/vendor-parakeet-cpp.sh`,
`swift/Sources/parakeet_cpp/` (vendored + hand-authored bridge, ~140
files), `swift/Sources/Parakey/ParakeetEngine.swift`.

**Deleted**: `swift/Sources/whisper_cpp/` (entire tree, ~1911 files),
`swift/Sources/Parakey/WhisperEngine.swift`,
`scripts/vendor-whisper-cpp.sh`, `scripts/gen-vulkan-shader-runtime.py`,
`scripts/vulkan-shader-runtime/`.

**Modified**: `swift/Package.swift`, `swift/Sources/Parakey/main.swift`
(model profile/downloader/cache-safety/TranscriptionWorker/settings-key/
self-tests), `swift/Sources/Parakey/KeyboardLanguage.swift` (renamed
whisper-specific function/property names), `scripts/build-app.sh`
(removed the whisper Vulkan-shader resource copy), `README.md` (model
name/size/location, replaced the whisper.cpp Vulkan benchmark section with
an honest "not implemented yet" note).

## 14. Definition-of-done checklist against this phase's scope (spec §25,
items relevant to Phase 3; Vulkan/benchmark items are explicitly Phase
4/5's job)

- [x] Whisper removed from runtime, build, and shipped resources.
- [x] Parakeet TDT 0.6B v3 is the only ASR model (source-level; no picker).
- [x] Exact GGUF pinned by immutable revision, filename, size, SHA-256 —
      re-verified for real this phase (downloaded fresh, hash matched).
- [x] Model downloads and verifies automatically — real download proven.
- [x] Model stored under `Application Support/SuperDictate`.
- [x] Parakeet statically integrated in the main process (no helper/CLI
      subprocess/temp WAV/local server).
- [x] Model loaded once and reused (`ParakeetEngine` holds one context;
      `parakeet-cpu` self-test explicitly re-uses the same context for a
      second inference).
- [x] CPU is the default for clean installs and upgrades (new
      `parakeet_use_gpu` key, defaults false, never inherits `use_gpu`).
- [ ] `Use GPU (Vulkan)` setting controls Parakeet Vulkan — key exists,
      behavior is Phase 5.
- [x] No fallback to Whisper (impossible — the code doesn't exist).
- [x] Existing hotkeys/capture/HUD/insertion/history/corrections
      untouched in shape (code-reviewed; not independently re-verified via
      live GUI dictation this phase — see §11's honest gap).
- [x] `<unk>`→`ё` repair remains covered by tests (renamed, retained,
      empirically found to be a no-op against this pinned model/commit —
      documented, not deleted).
- [x] Full self-tests pass.
- [x] CPU integration passes on Intel macOS (real model, real hardware).
- [x] Codesign verification passes.
- [x] Runtime dependency checks pass (no Homebrew/MoltenVK/Vulkan deps).
- [ ] CPU/Vulkan benchmark results — Phase 4/5's job.
- [ ] README/architecture docs fully match spec §14's exact suggested
      wording — substantively accurate, not a literal match (see §12).
