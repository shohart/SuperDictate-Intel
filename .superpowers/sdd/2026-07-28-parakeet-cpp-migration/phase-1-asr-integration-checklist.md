# Phase 1 — ASR integration point checklist

Grep'd from `swift/Sources/Parakey/main.swift` (22,775 lines) and
`swift/Sources/Parakey/WhisperEngine.swift` (235 lines) on
`agent/parakeet-intel-backend-architecture`@`901c71c`. For later phases
(3 and 6) to use as a starting map — not exhaustive prose, just grouped
file:line references. Re-grep at the start of each later phase since line
numbers will drift.

## 1. Vendored source tree / build

- `swift/Sources/whisper_cpp/` — entire vendored whisper.cpp + its own ggml
  copy. Target for full deletion in Phase 6.
- `swift/Package.swift`
  - line 26: `whisper_cpp` target definition
  - line 57: comment referencing `scripts/vendor-whisper-cpp.sh`
  - lines 93, 122: `WHISPER_VERSION` compile define (`"080bbbe8"`)
  - line 173: `Parakey` executable's `dependencies: ["whisper_cpp"]` — the
    Phase 3 rollback point (spec's "swap dependencies" instruction).
- `scripts/vendor-whisper-cpp.sh` — vendoring script, superseded by
  `scripts/vendor-parakeet-cpp.sh` in Phase 3.
- `scripts/build-app.sh` — references Whisper resources/shader copy step.
- `scripts/dev-run.sh`, `install.sh`, `uninstall.sh` — grep for `whisper`
  turned up no hits in these at Phase 1 time; re-check at Phase 6 in case
  drift occurred.
- Vulkan shader corpus: `swift/Sources/whisper_cpp/vulkan-shaders/` (1785
  `.spv` files, generated against whisper's ggml vintage — explicitly noted
  in the plan as not reusable for parakeet.cpp's ggml v0.13.0).

## 2. Model download / cache / integrity (main.swift)

- `enum WhisperModelDownloadError` — main.swift:1612
- `WHISPER_MODEL_URL` — main.swift:1631-1633 (pinned commit
  `5359861c739e955e79d9a303bcbc70fb988958b1`, `ggml-large-v3-turbo.bin`)
- `WHISPER_MODEL_SHA256` — main.swift:1634
- `WHISPER_MODEL_SIZE_BYTES` — main.swift:1635 (1,624,555,275 bytes / ~1.6GB)
- `downloadWhisperModelIfNeeded()` — main.swift:1652-1682 (download +
  atomic move + SHA-256 verify-on-every-call, including the cached-file
  path — this cost showed up directly in Phase 1's baseline measurements,
  see the Phase 1 report)
- `resolvedWhisperSupportDirectory(_:)` — main.swift:1684
- `isSafeSpeechModelCacheDirectory` family — main.swift:1691, 1714 (symlink/
  `..`/unexpected-root rejection logic — spec §4.2 wants equivalent
  guarantees preserved for Parakeet)
- `whisperModelCacheDirectory()` — main.swift:1752 (`~/Library/Application
  Support/Whisper/Models`)
- `whisperModelPath()` — main.swift:1759-1760
  (`ggml-large-v3-turbo.bin`)
- `assertSufficientDiskSpaceForSpeechModelDownload(profile:)` —
  main.swift:1805 area, disk-space headroom check
- `speechModelCacheExists(for:)` — main.swift:1801
- Legacy-cache handling: nothing currently deletes the Whisper cache — spec
  §4.4 wants Parakeet to optionally clean up this exact file, never the
  whole directory, only after Parakeet has itself succeeded.

## 3. Model identity / profile (main.swift)

- `enum SpeechModelProfile` — main.swift:433 (`CaseIterable`; UI-facing
  names/descriptions live here)
  - line 452: `"Multilingual (Whisper large-v3-turbo)"` (display name)
  - line 461: `"Whisper large-v3-turbo"` (short name)
  - line 470: `"whisper.cpp · large-v3-turbo multilingual (CPU)"` (technical
    description string)
  - line 485: reset-model confirmation copy mentioning "Whisper
    large-v3-turbo model cache"
- `ModelFileDigest` / `verifyParakeetV3Model` (main.swift:1356-1430ish) —
  **dead code from the old CoreML/ANE/FluidAudio Parakeet stack**, per the
  plan's own note. Not the same runtime as parakeet.cpp+GGUF. Do not wire
  into the new integration without empirical re-verification; likely a
  Phase 6 deletion candidate alongside Whisper, not a Phase 3 reuse
  candidate.

## 4. Engine wrapper (WhisperEngine.swift)

- `enum WhisperEngineError` — WhisperEngine.swift:4
- `struct WhisperTranscription` — WhisperEngine.swift:18 (`text`,
  `encodeSeconds`, `totalSeconds` — compare against spec §8's
  `ParakeetTranscriptionResult` shape, which adds `frontendSeconds`/
  `encoderSeconds`/`decoderSeconds`/`usedGPU`)
- `actor WhisperEngine` — WhisperEngine.swift:27
  - `init(modelPath:useGPU:)` — WhisperEngine.swift:37, calls
    `configureVulkanShaderDirectory()` unconditionally (important
    dev-build-vs-shipped-app existence-check pattern, see doc comment at
    WhisperEngine.swift:66-101 — directly relevant to any Parakeet Vulkan
    shader-loading code in Phase 5)
  - `transcribe(samples:languageCode:)` — WhisperEngine.swift:111168
    (`nil` language → `"auto"` string quirk is whisper.cpp-specific;
    Parakeet's own auto-detect contract must be independently verified,
    not assumed identical)
  - `audioContextFrames(forSampleCount:modelMaxAudioCtx:)` —
    WhisperEngine.swift:205 (whisper.cpp-specific `audio_ctx` window-sizing
    hack; almost certainly has no Parakeet equivalent — parakeet.cpp's
    encoder is not the same architecture)
  - `deinit` — WhisperEngine.swift:170, calls `whisper_free(context)`

## 5. TranscriptionWorker (main.swift)

- `enum LoadedSpeechEngine` — main.swift:5499-5512, single case
  `.whisperLargeV3Turbo(WhisperEngine)` today; Phase 3 spec wants a single
  `ParakeetEngine?` field instead of an enum (no engine-picker).
- `actor TranscriptionWorker` — main.swift:5538
  - `load(profile:progressHandler:)` — main.swift:5547-5573 (reads
    `Settings.shared.useGPU`, compares against `loadedProfile`/
    `loadedUseGPU` to skip redundant reloads — the "load once" contract
    Phase 3 must preserve for Parakeet)
  - `loadWhisperEngine(useGPU:progressHandler:)` — main.swift:5576-5581
  - `transcribe(samples:language:resolveViaKeyboard:requestedAt:)` —
    main.swift:5584-5626 (the single call site into `WhisperEngine
    .transcribe`; `resolveEffectiveWhisperLanguage` hop happens here)
  - `warmUp()` — main.swift:5629-5638 (silence-buffer warm-up pattern
    Parakeet's own warm-up, spec §11.3, should mirror)
  - `unload()` — main.swift:5641-5647

## 6. Text repair (main.swift)

- `enum SpeechModelTextRepair` — main.swift:5659 area, `apply(to:language:)`
  — already has the `<unk>` → `ё`/`Ё` Cyrillic-repair logic and doc comment
  explicitly attributing it to "Parakeet TDT v3" (the **old** CoreML
  runtime, not parakeet.cpp). Phase 3's job: empirically confirm or refute
  against parakeet.cpp's actual output before reusing/renaming this
  (spec §13 suggests `ParakeetTranscriptRepair`).
- Existing repair test coverage lives in the self-test block, e.g.
  main.swift:19821-19860ish (`removedUnkPunctuation`, `removedUnkMultiSpace`,
  `removedUnkFrench`, `autoYo`, etc.) — reusable pattern for Phase 3's own
  test additions.

## 7. Settings / UI (main.swift)

- `Settings.useGPU` — main.swift:3384-3387 (`keyUseGPU = "use_gpu"`,
  defaults false). Spec §10 requires a **new** persisted key
  (`parakeetUseGPU`) rather than reusing/inheriting this one.
- Menu item — main.swift:14020-14026: `"Use GPU (Vulkan) — experimental"`
  checkbox, tooltip explicitly says "Runs whisper.cpp's Vulkan backend".
- Toggle handler — main.swift:15495-15501 (`settings.useGPU.toggle()`,
  reload-after-change log line).
- Startup/model-status strings are already Whisper-neutral ("speech
  model…", not "whisper model…") — main.swift:6012-6017, 9808, 10464,
  22371-22381 — good news for Phase 3, less churn needed here than the
  spec assumed.
- Reset-model confirmation copy naming Whisper explicitly — main.swift:485.
- Setup-checklist row text — main.swift:16950ish, `"Whisper large-v3-turbo
  is loaded locally."`

## 8. Self-tests referencing Whisper (main.swift, all inside `#if DEBUG`,
   lines 16154-20818)

- `--self-test model-status` assertions — main.swift:16577, 16595 (checks
  the literal string `"Speech model: Multilingual (Whisper large-v3-turbo)"`)
- `--self-test model-integrity` — main.swift:18556-18880ish: SHA-256/size
  checks against `WHISPER_MODEL_SIZE_BYTES`/`WHISPER_MODEL_SHA256`, cache-
  path safety checks against `~/Library/Application Support/Whisper`,
  symlink/`..`-escape rejection tests referencing
  `ggml-large-v3-turbo.bin` paths directly. This whole suite needs a
  Parakeet-shaped equivalent in Phase 3 (spec §18.1's "model path/deletion
  safety" + "download size/SHA verification" groups).
- Language-mapping self-test — main.swift:18496-18554: exercises
  `DictationLanguage.whisperLanguageCode` and
  `resolveEffectiveWhisperLanguage`, plus `WhisperEngine.audioContextFrames`
  boundary tests (18565-18590) — whisper-specific, no direct Parakeet
  equivalent expected (no `audio_ctx` trimming concept in parakeet.cpp).
- History-timing tooltip test — main.swift:17357-17359, asserts
  `"whisper.cpp  286.0 ms"` appears in the tooltip string.
- No existing self-test group is named `parakeet-*` yet — spec §18 wants
  `parakeet-bridge` / `parakeet-model` / `parakeet-cpu` / `parakeet-vulkan`
  / `parakeet-text-repair` added in Phase 3, none of which exist today.

## 9. README.md

- Line 182: "whisper.cpp вместо этого использует бэкенд Vulkan…" (Vulkan
  architecture section)
- Line 192: "whisper.cpp считает декодер на CPU (BLAS)…"
- Line 237: "(`ggml-large-v3-turbo`, движок whisper.cpp, только CPU)"
  (benchmark table)
- Line 240: "относились к предыдущему движку FluidAudio/CoreML и для
  whisper.cpp не…" (historical note about the even-older CoreML engine)
- Line 246: "Модель whisper.cpp: `~/Library/Application Support/Whisper/Models`."
  (model location doc)

## 10. Not yet touched, but relevant later

- `docs/parakeet-intel-backend.md` — the target-state spec itself; §22
  lists `docs/parakeet-intel-backend.md` among files "at minimum modify",
  presumably to update anything that drifts from the actual implementation
  once it lands (Phase 7).
- No CI/release workflow files reference Whisper paths as of Phase 1 (not
  present in this repo layout beyond the scripts already listed).
