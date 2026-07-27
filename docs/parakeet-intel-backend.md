# SuperDictate Intel: complete migration from Whisper to Parakeet TDT 0.6B v3

## 1. Objective

This branch must replace the existing Whisper ASR stack completely with NVIDIA Parakeet TDT 0.6B v3.

The finished application must preserve the current SuperDictate user experience and application lifecycle:

- global push-to-talk hotkeys;
- microphone capture;
- recording and transcribing HUD states;
- insertion into the focused text field;
- clipboard restoration and direct-Unicode fallback;
- transcript history;
- user-defined transcript corrections;
- filler-word removal;
- language selection and keyboard-layout resolution;
- pending-dictation recovery;
- permissions and TCC recovery;
- launch agent behavior;
- settings UI;
- updater, installer and uninstaller behavior;
- diagnostics and self-tests.

Only the speech-recognition implementation changes:

```text
whisper.cpp + Whisper large-v3-turbo
```

is replaced by:

```text
parakeet.cpp + NVIDIA Parakeet TDT 0.6B v3 + GGUF q8_0
```

The production default is Parakeet on CPU. The user may enable `Use GPU (Vulkan)` in Settings. Vulkan failure must fall back to Parakeet CPU, never to Whisper.

## 2. Non-negotiable decisions

### 2.1 Parakeet is the only ASR engine

Do not add Parakeet alongside Whisper. Remove Whisper from the source tree, Swift package, application binary, model downloader, settings, tests, documentation and shipped resources.

There must be no production code path for:

- Whisper CPU;
- Whisper Vulkan;
- Whisper model loading;
- Whisper language forcing;
- Whisper tokenization;
- Whisper shader resources;
- an automatic choice between Whisper and Parakeet;
- a hidden Whisper fallback.

The only runtime modes are:

```text
Parakeet CPU
Parakeet Vulkan
```

The only fallback is:

```text
Parakeet Vulkan -> Parakeet CPU
```

### 2.2 In-process static integration

Do not use a helper process, command-line subprocess, local HTTP server, Unix socket or framed IPC.

Because Whisper and its independent ggml copy are removed, there is no longer a duplicate-ggml reason to isolate Parakeet in another process. Statically link `parakeet.cpp`, ggml CPU, ggml Vulkan and MoltenVK into the main SuperDictate executable through a small stable C bridge.

Target data flow:

```text
AVAudioEngine
    -> mono Float32 PCM at 16 kHz
    -> TranscriptionWorker actor
    -> ParakeetEngine Swift wrapper
    -> SuperDictate Parakeet C bridge
    -> parakeet.cpp load-once model
    -> ggml CPU or ggml Vulkan
    -> MoltenVK
    -> compatible AMD GPU
```

### 2.3 Load the model once

The GGUF model must be loaded once per agent/backend session and reused for every dictation.

Do not call an upstream convenience API that reloads the model for every transcription. Hold a persistent `pk::Model` or equivalent load-once context.

Destroy and recreate the context only when:

- the agent exits;
- the model is reset;
- `Use GPU (Vulkan)` changes;
- Vulkan fails and the session switches to CPU;
- the model/runtime version becomes incompatible;
- model initialization fails irrecoverably.

### 2.4 Preserve the surrounding application

Do not rewrite unrelated application architecture. Keep the current `TranscriptionWorker` actor as the serialization boundary. Keep existing audio capture, hotkeys, insertion, history, updater and UI behavior unless an ASR-specific adaptation is necessary.

The user-visible principle is:

> The same SuperDictate application, with Parakeet replacing Whisper.

## 3. Target model

Use NVIDIA Parakeet TDT 0.6B v3, multilingual, converted to GGUF and supported by the pinned `parakeet.cpp` revision.

Initial production quantization:

```text
q8_0
```

Do not make `q4_k` the default without a separate Russian-language accuracy comparison. `q6_k` or other variants may be benchmarked later but are outside the initial migration unless required by measured constraints.

The implementation must pin all model metadata in source code:

```text
PARAKEET_MODEL_REPOSITORY
PARAKEET_MODEL_REVISION
PARAKEET_MODEL_FILENAME
PARAKEET_MODEL_URL
PARAKEET_MODEL_SHA256
PARAKEET_MODEL_SIZE_BYTES
PARAKEET_MODEL_ARCH
PARAKEET_MODEL_QUANTIZATION
```

Requirements:

- never download from `main`, `master`, `latest` or another moving reference;
- use an immutable repository commit/revision in the URL;
- record the exact filename;
- calculate SHA-256 from the exact downloaded artifact;
- record the exact byte size;
- verify the model license and include all required notices;
- verify that the chosen artifact is Parakeet TDT 0.6B v3 and not a different Parakeet architecture;
- verify compatibility with the pinned `parakeet.cpp` revision.

Canonical UI name:

```text
Parakeet TDT 0.6B v3
```

Canonical technical description:

```text
parakeet.cpp · NVIDIA Parakeet TDT 0.6B v3 multilingual · GGUF q8_0
```

## 4. Model storage and download

### 4.1 New location

Do not use `~/Library/Application Support/Whisper` for the new model.

Use:

```text
~/Library/Application Support/SuperDictate/Models/
```

Preferred final path:

```text
~/Library/Application Support/SuperDictate/Models/parakeet-tdt-0.6b-v3-q8_0.gguf
```

A versioned subdirectory is acceptable if it is used consistently and covered by tests.

### 4.2 Integrity and atomic installation

Retain or improve the current model-integrity guarantees:

1. Treat the destination as a known regular file only.
2. Reject symlinks, directories and special files.
3. Verify the expected byte size.
4. Verify SHA-256.
5. Download to a temporary file on the same volume.
6. Verify the temporary file before publishing it.
7. Atomically rename the verified file into place.
8. Never expose a partially downloaded file under the production filename.
9. Remove only the exact corrupted or temporary file.
10. Refuse unsafe deletion paths containing symlink hops, `..` components or an unexpected root.
11. Check available disk space using model size plus download/preparation headroom.

Use Parakeet-neutral names such as:

```swift
SpeechModelDownloadProgressHandler
ParakeetModelDownloadError
downloadParakeetModelIfNeeded()
```

Remove Whisper-specific downloader types and messages.

Expected startup text:

```text
Checking Parakeet model…
Downloading Parakeet model… 42%
Verifying Parakeet model…
Loading Parakeet model…
Preparing Parakeet model…
```

Add equivalent Russian strings using the existing localization mechanism.

### 4.3 Model reset

The existing reset-model action must:

1. block new inference;
2. finish or cancel the current operation according to current application rules;
3. destroy the Parakeet context;
4. safely delete only the known GGUF path;
5. redownload and verify it;
6. create the selected CPU/Vulkan context;
7. run warm-up;
8. return to Ready only after success.

### 4.4 Legacy Whisper cache

The Parakeet runtime must never read or use the old Whisper model.

Preferred migration behavior: leave the legacy cache untouched. It is not required for Parakeet operation.

Optionally, after Parakeet has downloaded, verified, loaded and completed warm-up successfully, remove only this exact known legacy file if it exists:

```text
~/Library/Application Support/Whisper/Models/ggml-large-v3-turbo.bin
```

Never recursively remove the whole `~/Library/Application Support/Whisper` directory. Failure to remove the old file must not prevent application startup.

## 5. Pin and vendor parakeet.cpp

Choose immutable commits for:

```text
PARAKEET_CPP_COMMIT
GGML_COMMIT
```

Create:

```text
scripts/vendor-parakeet-cpp.sh
```

The script must:

1. fetch the pinned `parakeet.cpp` revision into a temporary directory;
2. verify the checked-out commit exactly;
3. initialize and verify the pinned ggml submodule/revision;
4. copy only the inference sources, headers and required backend code;
5. exclude examples, server code, Docker files, Python runtime and upstream test corpora from the shipped target;
6. apply minimal documented local patches;
7. prepare or embed Vulkan shaders as required by the pinned ggml revision;
8. generate provenance/version metadata;
9. fail on any revision mismatch;
10. produce a deterministic vendor tree.

Normal application builds must not fetch source code from the network. The required vendored source must already exist in the repository.

Suggested structure:

```text
swift/Sources/parakeet_cpp/
├── include/
│   └── superdictate_parakeet.h
├── bridge/
│   └── superdictate_parakeet.cpp
├── upstream/
│   ├── include/
│   ├── src/
│   └── third_party/
│       └── ggml/
└── vulkan-shaders/
```

An alternative layout is acceptable if upstream code remains separated from the local bridge and vendoring remains reproducible.

## 6. SwiftPM and native build

### 6.1 Remove Whisper

Delete the `whisper_cpp` SwiftPM target and the entire vendored Whisper source tree.

Remove:

- Whisper source/header paths;
- Whisper compile definitions;
- `WHISPER_VERSION` and Whisper commit metadata;
- Whisper C bridge;
- Whisper model constants;
- Whisper Vulkan shaders;
- Whisper-specific resource copying;
- comments and tests describing Whisper behavior;
- old model-profile cases used only for Whisper/legacy Parakeet selection.

### 6.2 Add Parakeet target

Add a native SwiftPM target named `parakeet_cpp` or an equivalently clear name. The `Parakey` executable target must depend on it.

Build support must include:

```text
GGML CPU
Accelerate/BLAS where supported
GGML Vulkan
static MoltenVK
```

Retain Intel optimizations already required by this fork where compatible with the pinned ggml code:

```text
-mavx2
-mfma
-mf16c
-mbmi2
-msse4.2
```

Do not add CUDA, HIP, Metal, Core ML, PyTorch, NeMo runtime or ONNX Runtime.

### 6.3 MoltenVK

Homebrew may supply Vulkan headers and `libMoltenVK.a` during development/build, but the shipped application must not depend on Homebrew at runtime.

Statically link MoltenVK. After building, `otool -L` must not contain:

```text
/usr/local/
/opt/homebrew/
Cellar
libMoltenVK.dylib
libvulkan.dylib
```

System Apple frameworks are allowed.

### 6.4 Vulkan shaders

Use the mechanism required by the pinned ggml revision:

- prefer embedded shaders when supported;
- otherwise ship the exact SPIR-V resources in `Contents/Resources/vulkan-shaders`;
- load app resources via `Bundle.main`, not `Bundle.module`;
- make codesigning and integrity checks cover the shipped resources;
- do not retain Whisper shader files.

### 6.5 Build scripts

Update at least:

```text
scripts/build-app.sh
scripts/dev-run.sh
install.sh
uninstall.sh
```

Also update release and CI workflows that reference Whisper files or resources.

The final build flow must:

1. build the x86_64 Swift executable;
2. compile the Parakeet/ggml CPU+Vulkan target;
3. statically link MoltenVK;
4. copy only required resources;
5. sign the final application with the existing hardened-runtime policy;
6. run `codesign --verify --deep --strict`;
7. run `otool -L` dependency checks;
8. verify that Parakeet symbols exist;
9. verify that Whisper symbols do not exist.

## 7. Stable C bridge

Do not expose upstream C++ types directly to Swift. Add a small owned C ABI.

Required capabilities:

```c
#ifndef SUPERDICTATE_PARAKEET_H
#define SUPERDICTATE_PARAKEET_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SDParakeetContext SDParakeetContext;

typedef enum {
    SD_PARAKEET_DEVICE_CPU = 0,
    SD_PARAKEET_DEVICE_VULKAN = 1
} SDParakeetDevice;

typedef struct {
    SDParakeetDevice device;
    int32_t num_threads;
} SDParakeetOptions;

typedef struct {
    char *text;
    double total_seconds;
    double frontend_seconds;
    double encoder_seconds;
    double decoder_seconds;
    int32_t used_gpu;
} SDParakeetResult;

int32_t sd_parakeet_create(
    const char *model_path,
    const SDParakeetOptions *options,
    SDParakeetContext **out_context,
    char **out_error
);

int32_t sd_parakeet_warm_up(
    SDParakeetContext *context,
    char **out_error
);

int32_t sd_parakeet_transcribe(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetResult *out_result,
    char **out_error
);

void sd_parakeet_result_destroy(SDParakeetResult *result);
void sd_parakeet_destroy(SDParakeetContext *context);
void sd_parakeet_free_string(char *value);

int32_t sd_parakeet_vulkan_available(void);
const char *sd_parakeet_version(void);
const char *sd_parakeet_backend_description(
    const SDParakeetContext *context
);

#ifdef __cplusplus
}
#endif

#endif
```

Exact names may differ, but the contract must provide equivalent functionality.

Bridge requirements:

- retain a load-once `pk::Model` or equivalent context;
- accept raw mono Float32 PCM;
- accept or enforce the sample rate;
- use `transcribe_pcm`, not a temporary WAV;
- never spawn a subprocess;
- catch every C++ exception before returning through C ABI;
- return stable numeric error codes and allocated UTF-8 error strings;
- provide matching free functions for every allocated result;
- validate all pointers;
- validate sample count and integer conversions;
- enforce the application's maximum recording duration;
- reject invalid/empty input consistently;
- prevent concurrent inference on one context;
- remain safe after partial initialization failure;
- expose actual selected backend/device information.

If upstream device selection currently relies on `PARAKEET_DEVICE`, encapsulate it inside the bridge. Set it only before context/model creation and never mutate it during inference. Prefer a local upstream patch that passes an explicit backend/device selection rather than relying on process-global environment state.

Requesting Vulkan must fail initialization if the actual selected backend is CPU-only. Do not report Vulkan success merely because the user checked a box.

## 8. Swift ParakeetEngine

Add a Swift wrapper similar to:

```swift
enum ParakeetDevice: Sendable {
    case cpu
    case vulkan
}

struct ParakeetTranscriptionResult: Sendable {
    let text: String
    let totalSeconds: Double
    let frontendSeconds: Double?
    let encoderSeconds: Double?
    let decoderSeconds: Double?
    let usedGPU: Bool
}

final class ParakeetEngine: @unchecked Sendable {
    init(modelPath: String, device: ParakeetDevice, threadCount: Int) throws
    func warmUp() async throws
    func transcribe(samples: [Float]) async throws -> ParakeetTranscriptionResult
    func shutdown()
}
```

Requirements:

- create and own exactly one native context;
- destroy it deterministically and from `deinit` as a backstop;
- run native work off MainActor;
- pass PCM with a scoped unsafe buffer pointer;
- never submit an empty Swift array to native inference;
- convert native strings to UTF-8 safely;
- always free native strings/results;
- map native codes to typed Swift errors;
- guard against overlapping calls;
- expose actual runtime backend/device for diagnostics and UI.

## 9. TranscriptionWorker migration

Retain the existing actor and reentrancy protections.

Replace the Whisper-only engine enum with a single Parakeet engine field:

```swift
private var engine: ParakeetEngine?
private var loadedUseGPU: Bool?
private var runtimeUsedGPU = false
private var gpuFallbackReason: String?
private(set) var ready = false
private var inFlight = false
```

### 9.1 Loading algorithm

1. Read the new Parakeet GPU preference.
2. Verify/download the GGUF if needed.
3. If GPU is disabled:
   - create CPU engine;
   - run warm-up;
   - record actual backend as CPU.
4. If GPU is enabled:
   - probe Vulkan through ggml;
   - create Vulkan engine;
   - verify actual selected backend/device;
   - run warm-up with timeout;
   - on success record Vulkan runtime state;
   - on any failure destroy the partial Vulkan context;
   - create CPU engine;
   - run CPU warm-up;
   - record session fallback reason.
5. Set `ready = true` only after a successful warm-up on the active backend.

### 9.2 Transcription algorithm

1. Validate loaded engine and reentrancy state.
2. Set `inFlight = true` and clear it with `defer`.
3. Pass the captured PCM directly to `ParakeetEngine`.
4. Receive text and timings.
5. Run the existing deterministic text-processing pipeline.
6. Continue through the unchanged insertion/history path.

Do not change `ParakeyApp.isBusy`, pending recording recovery or insertion behavior without a demonstrated requirement.

### 9.3 Vulkan inference failure

If Vulkan initialized successfully but a real transcription fails:

1. retain the current captured PCM;
2. destroy the Vulkan engine;
3. create the CPU engine;
4. run CPU warm-up;
5. retry the same dictation exactly once on CPU;
6. keep CPU active for the remainder of the current agent session;
7. record the Vulkan error in diagnostics;
8. do not automatically retry Vulkan again in that session;
9. do not change the persisted user preference.

On the next full agent restart, the application may test Vulkan again because the user setting remains enabled.

Never retry indefinitely and never fall back to Whisper.

## 10. CPU mode

CPU is the default for clean installs and for users upgrading from the Whisper build.

Do not inherit the old Whisper `useGPU` storage value. Introduce a new persisted key, for example:

```text
parakeetUseGPU
```

The Swift property may remain named `useGPU`, but the persisted key must be new so an old installation with Whisper Vulkan enabled starts Parakeet on CPU after upgrading.

Do not add a thread-count control to Settings in this task.

Default internal policy:

```swift
max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
```

Allow a diagnostic/test override:

```text
SUPERDICTATE_ASR_THREADS
```

Validate the override, for example within `1...32`.

## 11. Vulkan mode

### 11.1 Settings behavior

Keep a single checkbox:

```text
Use GPU (Vulkan)
Использовать GPU (Vulkan)
```

The checkbox only changes the backend for the same Parakeet model:

```text
off -> Parakeet CPU
on  -> Parakeet Vulkan
```

Do not add a user-facing device picker or expose ggml backend identifiers.

Apply the change using the existing `Save and Restart` / `Сохранить и перезапустить` behavior so the agent unloads and recreates the model context cleanly.

### 11.2 Capability probe

Use ggml's registered devices as the source of truth. Do not infer Vulkan availability only from IOKit or the presence of an AMD GPU.

Expose a native probe such as:

```text
sd_parakeet_vulkan_available()
```

Settings behavior:

- enable the checkbox when a usable Vulkan device is actually enumerated;
- disable it with a clear explanation when no device is available;
- avoid claiming availability until probing completes.

Example message:

```text
Vulkan GPU was not detected. Parakeet will use CPU.
```

### 11.3 Warm-up

Warm-up must occur before Ready and should:

- construct representative compute graphs;
- trigger Vulkan/MoltenVK pipeline compilation;
- validate model execution;
- verify the actual backend/device;
- complete within a defined timeout;
- never create a transcript history item or paste text.

A short generated silence buffer is acceptable. An empty transcript for silence is not a warm-up error.

### 11.4 Runtime status

Expose actual runtime state, not only the saved preference:

```text
CPU
Vulkan — AMD Radeon RX 6600
CPU fallback after Vulkan error
```

When GPU is requested but CPU fallback is active, show a concise status such as:

```text
GPU requested, CPU fallback active
GPU включён в настройках, но используется CPU
```

## 12. Language behavior

Keep the existing `DictationLanguage` model and language UI.

Do not pretend to force a decoder language unless the pinned Parakeet model/runtime truly supports it.

Rules:

- `.auto` remains the default;
- preserve the selected language setting;
- preserve keyboard-layout resolution where it affects current application behavior;
- pass a language to native code only when the selected model/API genuinely supports it;
- use the selected/effective language for deterministic post-processing;
- do not implement fake language forcing by filtering output tokens.

Document any limitation if Parakeet TDT v3 only performs its own multilingual detection in the chosen runtime.

## 13. Transcript processing

Preserve the current pipeline:

```text
raw transcript
-> trim
-> model-specific repair
-> user corrections
-> filler-word removal
-> paste suffix
-> insertion
-> history
```

Retain the Parakeet-specific `<unk>` repair used for Russian Cyrillic `ё`:

- for `.russian` and `.auto`, replace `<unk>` with `ё` or `Ё` using existing sentence-capitalization logic;
- for other languages, remove the unknown token and normalize surrounding spaces/punctuation.

Rename the implementation to make ownership explicit, for example:

```swift
ParakeetTranscriptRepair
```

Add tests for:

- sentence-initial `<unk>`;
- mid-word/mid-sentence replacement;
- punctuation around `<unk>`;
- repeated unknown tokens;
- Russian, auto and non-Russian modes.

Do not change user corrections or filler-word removal unless required to preserve existing behavior.

## 14. Settings and UI cleanup

There is one speech model, so do not show a model picker.

Remove UI and saved choices referring to:

- Whisper;
- large-v3-turbo;
- deprecated Parakeet Unified;
- multiple speech-model profiles;
- automatic backend/model selection.

Display:

```text
Speech model: Parakeet TDT 0.6B v3
```

About text:

```text
Parakeet TDT 0.6B v3 runs locally through parakeet.cpp.
Audio and transcripts are not sent to an online API.
```

Russian:

```text
Parakeet TDT 0.6B v3 работает локально через parakeet.cpp.
Аудио и расшифровки не отправляются в облачный API.
```

The model download size shown in UI/README must use the actual pinned GGUF size, not the old Whisper 1.6 GB value.

## 15. Error contract

Add typed errors equivalent to:

```swift
enum ParakeetEngineError: LocalizedError {
    case modelNotFound
    case modelChecksumMismatch
    case modelLoadFailed(String)
    case vulkanUnavailable
    case requestedDeviceNotSelected(String)
    case warmUpFailed(String)
    case inferenceFailed(String)
    case invalidUTF8
    case emptyAudio
    case nativeBridgeFailure(code: Int32, message: String)
}
```

Explicitly handle:

- download transport failures;
- non-200 HTTP response;
- insufficient disk space;
- size/checksum mismatch;
- corrupt or incompatible GGUF;
- unsupported CPU/ISA;
- insufficient RAM;
- no Vulkan device;
- MoltenVK initialization failure;
- missing/invalid shaders;
- insufficient VRAM;
- native exception;
- inference timeout;
- cancellation;
- empty transcript;
- unload/reset during inference.

Do not use `fatalError` for recoverable runtime failures. Do not leak C++ exceptions through C ABI. Do not retry indefinitely.

## 16. Logging and diagnostics

Replace Whisper-specific log messages with `ASR:` or `Parakeet:`.

At startup log:

```text
ASR model: Parakeet TDT 0.6B v3 q8_0
ASR runtime: parakeet.cpp <version>
ASR device requested: CPU/Vulkan
ASR device selected: <actual backend/device>
ASR threads: N
ASR model load: X.XX s
ASR warm-up: X.XX s
```

Per transcription log timing without logging private transcript content by default:

- audio duration;
- total end-to-end latency;
- native engine processing time;
- frontend/encoder/decoder timings when available;
- real-time factor;
- actual backend;
- fallback state.

Do not log raw audio, clipboard content, full user correction dictionaries or full transcripts by default.

## 17. Complete Whisper removal

Remove the entire Whisper vendor tree, expected at or under:

```text
swift/Sources/whisper_cpp/
```

Remove all source, resources, settings, constants, comments and tests that are only for Whisper.

Before completion run:

```bash
rg -n -i "whisper|large-v3-turbo|whisper_cpp" .
```

The preferred result is no matches. A narrowly documented migration/changelog mention may remain only when necessary.

Also inspect the final binary:

```bash
nm -gU SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
strings SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
```

Neither command should find Whisper runtime symbols/strings.

## 18. Self-tests

Keep the existing command working:

```bash
swift run -c debug --package-path swift Parakey --self-test all
```

Add groups equivalent to:

```text
parakeet-bridge
parakeet-model
parakeet-cpu
parakeet-vulkan
parakeet-text-repair
```

### 18.1 Tests without the large model

Normal CI must cover:

- C bridge compilation;
- null pointer validation;
- invalid model path;
- invalid PCM input;
- oversized sample count;
- error/result memory release;
- prevention of C++ exception leakage;
- device enum mapping;
- Swift error mapping;
- model path/deletion safety;
- download size/SHA verification;
- new GPU storage key/default migration;
- text repair;
- absence of Whisper references in the built target where practical.

### 18.2 CPU integration test

When set:

```text
SUPERDICTATE_PARAKEET_MODEL=/absolute/path/model.gguf
```

run a real CPU test that:

1. loads the model;
2. runs warm-up;
3. transcribes a fixed WAV/PCM fixture;
4. verifies a non-empty result;
5. prints timings and real-time factor;
6. repeats inference using the same loaded context;
7. destroys and recreates the context safely.

### 18.3 Vulkan integration test

When set:

```text
SUPERDICTATE_PARAKEET_MODEL=/absolute/path/model.gguf
SUPERDICTATE_TEST_VULKAN=1
```

run a real Vulkan test that:

1. enumerates a Vulkan device;
2. creates a Vulkan context;
3. verifies actual Vulkan selection;
4. runs warm-up;
5. transcribes the fixture;
6. verifies a non-empty result;
7. reports CPU/Vulkan timings;
8. destroys the context cleanly.

If the environment variable or device is absent, mark the integration test skipped, not passed.

## 19. Benchmark script

Replace the deleted one-off spike with a production-oriented script:

```text
scripts/benchmark-parakeet.sh
```

It must compare the same fixed corpus on:

```text
Parakeet CPU
Parakeet Vulkan
```

Test audio durations:

```text
3 s
10 s
30 s
120 s
```

Collect:

- cold load time;
- warm-up time;
- first inference latency;
- median warm latency;
- p95 warm latency;
- real-time factor;
- peak resident memory;
- peak VRAM where measurable;
- actual selected backend/device;
- transcript output for quality comparison.

The corpus should cover Russian, English, mixed Russian/English, names, numbers, addresses, technical terms, short commands and a long monologue. Do not commit private user recordings.

## 20. Target-machine acceptance

Primary validation machine:

```text
Intel Xeon E5-2678 v3
AMD Radeon RX 6600
Intel macOS installation
```

CPU acceptance:

- model loads successfully;
- warm 10–30 second dictation is faster than real time;
- the model is not reloaded per request;
- the application remains responsive;
- 100 sequential dictations complete without crash or unbounded memory growth.

Vulkan acceptance:

- ggml actually selects the Vulkan device;
- model execution causes measurable GPU/VRAM use;
- expensive shader/pipeline compilation occurs during warm-up rather than every request;
- later requests reuse the initialized context;
- Vulkan and CPU transcripts do not materially diverge solely because of backend selection;
- CPU fallback works deterministically after a forced Vulkan failure;
- resources are released after context destruction.

Performance target, not a correctness claim:

```text
Vulkan median latency for 10–30 second recordings should be at least 15–20% below Parakeet CPU.
```

If Vulkan is not faster, report the actual result. Do not reuse old Whisper benchmark numbers.

## 21. README and documentation

Update README to state accurately:

- Parakeet TDT 0.6B v3 is the only ASR model;
- inference is local;
- CPU is the default;
- `Use GPU (Vulkan)` is optional;
- Vulkan targets compatible Intel Macs with AMD GPUs;
- CPU fallback is automatic after Vulkan failure;
- the exact first-run model download size;
- internet is not required for dictation after the model is installed.

Remove the Whisper section and all large-v3-turbo references.

Update the Vulkan performance section only after real Parakeet CPU/Vulkan measurements.

## 22. Expected repository changes

At minimum modify:

```text
swift/Package.swift
swift/Sources/Parakey/main.swift
scripts/build-app.sh
scripts/dev-run.sh
install.sh
uninstall.sh
README.md
docs/parakeet-intel-backend.md
```

Add:

```text
scripts/vendor-parakeet-cpp.sh
scripts/benchmark-parakeet.sh
swift/Sources/parakeet_cpp/...
```

Delete:

```text
swift/Sources/whisper_cpp/...
scripts/build-parakeet-vulkan-spike.sh
```

Update CI/release workflows that refer to Whisper source paths, model names or Vulkan shader resources.

## 23. Implementation sequence

### Phase 1 — freeze the old behavior

- Run and record existing self-tests.
- Identify all ASR-specific integration points.
- Avoid unrelated refactoring.

### Phase 2 — vendor and build Parakeet CPU

- Pin `parakeet.cpp` and ggml commits.
- Add deterministic vendoring.
- Add the native SwiftPM target.
- Add the C bridge.
- Build CPU inference on Intel macOS.
- Verify persistent load-once raw-PCM transcription.

### Phase 3 — replace Whisper application integration

- Add `ParakeetEngine`.
- Replace `WhisperEngine` in `TranscriptionWorker`.
- Replace model metadata/downloader/cache path.
- Preserve post-processing, insertion and history.
- Remove old model-profile selection.
- Make CPU the clean-install and upgrade default.

### Phase 4 — add Vulkan to the same engine

- Enable ggml Vulkan.
- Statically link MoltenVK.
- Add actual device probing and verification.
- Connect the existing `Use GPU (Vulkan)` UI to Parakeet.
- Add warm-up and CPU fallback.
- Validate real RX 6600 use.

### Phase 5 — remove all Whisper code

- Delete Whisper source/resources.
- Remove build flags and model constants.
- Remove stale tests/documentation.
- Verify source tree and binary contain no Whisper runtime.

### Phase 6 — package, test and benchmark

- Update build/install/update/uninstall workflows.
- Run self-tests and integration tests.
- Validate codesign and runtime dependencies.
- Benchmark CPU vs Vulkan on the target machine.
- Update README with measured results.

## 24. Required validation commands

Run at minimum:

```bash
bash -n install.sh uninstall.sh scripts/*.sh
plutil -lint swift/Info.plist entitlements.plist
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
otool -L ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
file ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
lipo -info ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
```

Check for forbidden runtime dependencies:

```bash
otool -L ./dist/SuperDictate.app/Contents/MacOS/SuperDictate \
  | grep -E "/usr/local|/opt/homebrew|Cellar|MoltenVK\.dylib|libvulkan"
```

The command must return no matches.

Check complete Whisper removal:

```bash
rg -n -i "whisper|large-v3-turbo|whisper_cpp" .
nm -gU ./dist/SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
strings ./dist/SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
```

The final two commands must return no matches. Source matches require explicit justification and should normally be eliminated.

## 25. Definition of Done

The migration is complete only when all conditions are true:

1. Whisper is removed from runtime, build and shipped resources.
2. Parakeet TDT 0.6B v3 is the only ASR model.
3. The exact GGUF is pinned by immutable revision, filename, size and SHA-256.
4. The model downloads and verifies automatically.
5. The model is stored under `Application Support/SuperDictate`.
6. Parakeet is statically integrated in the main process.
7. No helper, CLI subprocess, temporary WAV or local server is used for dictation.
8. The model is loaded once and reused.
9. CPU is the default for clean installs and upgrades.
10. The existing `Use GPU (Vulkan)` setting controls Parakeet Vulkan only.
11. Vulkan selection is verified from the actual ggml backend/device.
12. MoltenVK is static and the app has no Homebrew runtime dependency.
13. Vulkan initialization/inference failure falls back to Parakeet CPU.
14. The current dictation is retried on CPU at most once.
15. There is no fallback to Whisper.
16. Existing hotkeys, capture, HUD, insertion, history and corrections still work.
17. The Parakeet `<unk>` to Russian `ё` repair remains covered by tests.
18. Full self-tests pass.
19. CPU integration passes on Intel macOS.
20. Vulkan integration passes on the real target GPU or is honestly reported as unverified.
21. Codesign verification passes.
22. Runtime dependency checks pass.
23. CPU/Vulkan benchmark results are recorded.
24. README and architecture documentation match the actual implementation.
25. No mock backend, dead UI control, hidden fallback or unresolved production TODO remains.

## 26. Forbidden shortcuts

Do not:

- retain Whisper “just in case”;
- use Python, PyTorch or NeMo at runtime;
- replace `parakeet.cpp` with ONNX Runtime;
- launch `parakeet-cli` for each dictation;
- write a temporary WAV for each request;
- use a helper process or local HTTP service;
- reload GGUF for every transcription;
- claim Vulkan use without checking the actual backend/device;
- ship Homebrew dynamic libraries;
- use an unpinned model or source revision;
- inherit the old Whisper GPU preference;
- expose a model selector when only one model is supported;
- copy Whisper benchmark claims to Parakeet;
- hide CPU fallback state;
- break unrelated application behavior;
- mark the work complete with documentation or a build spike only.

## 27. Required implementation report

The implementing agent must finish with a report containing:

1. changed and deleted files;
2. pinned `parakeet.cpp` commit;
3. pinned ggml commit;
4. exact GGUF filename;
5. immutable model URL/revision;
6. model size and SHA-256;
7. model/runtime license notices added;
8. compiler and backend flags;
9. default and measured CPU thread count;
10. actual Vulkan device name;
11. `otool -L` result;
12. codesign verification result;
13. self-test results;
14. CPU integration result;
15. Vulkan integration result;
16. cold load and warm-up times;
17. CPU and Vulkan latency/RTF benchmarks;
18. peak RAM and VRAM where measurable;
19. known limitations;
20. final commit and draft PR link.

Do not state that Vulkan is verified unless it was run on a real Intel Mac through MoltenVK with a real enumerated Vulkan device.