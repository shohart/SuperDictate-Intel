# Parakeet TDT v3 backend for Intel macOS

## Decision

The target backend for SuperDictate on Intel macOS is `parakeet.cpp` with ggml Vulkan through statically linked MoltenVK. CPU inference remains mandatory as a fallback and a benchmark baseline.

NVIDIA Parakeet TDT 0.6B v3 can run without CUDA. The application should not ship the original NeMo/PyTorch runtime. It should use a converted GGUF model and a native C++ inference helper.

Recommended order:

1. Add a persistent Parakeet helper process with CPU and Vulkan device selection.
2. Make Vulkan the preferred experimental Parakeet mode on supported Intel Macs with AMD GPUs.
3. Retry once on CPU after any Vulkan initialization or inference failure.
4. Keep the current Whisper backend available until Parakeet passes quality and stability gates.

## Why `parakeet.cpp`

`parakeet.cpp` is a C++17 ggml implementation supporting the multilingual `parakeet-tdt-0.6b-v3` model, quantized GGUF weights, CPU execution and ggml GPU backends including Vulkan. It accepts raw 16 kHz mono float PCM and can retain a loaded model across repeated transcriptions.

This matches the current project better than NeMo/Python or ONNX Runtime:

- no Python runtime;
- one GGUF model file;
- ggml Vulkan backend;
- direct x86_64 builds;
- raw PCM input;
- persistent load-once model context;
- static MoltenVK packaging is already proven in this fork.

## Process architecture

Do not link a second independent ggml copy directly into the main Swift executable. SuperDictate already embeds ggml through whisper.cpp. A second statically linked ggml backend in the same image creates duplicate-symbol, registry and upgrade risks.

Use a helper process:

```text
SuperDictate.app
├── Contents/MacOS/SuperDictate
└── Contents/Helpers/SuperDictateParakeet
```

The helper contains `parakeet.cpp`, ggml CPU and ggml Vulkan. It is launched once when Parakeet is selected and remains alive while the model is loaded.

Device selection:

```text
PARAKEET_DEVICE=Vulkan0   preferred mode
PARAKEET_DEVICE=cpu       fallback and benchmark mode
```

The parent process sends raw PCM over pipes or a Unix-domain socket. It must not create a WAV file or launch a CLI for every dictation.

## Framed protocol

Request:

```text
magic             4 bytes   "SDPK"
protocol_version  u32
request_id        u64
sample_rate       u32
sample_count      u64
language_length   u16
language          UTF-8
samples           float32 little-endian
```

Response:

```text
magic             4 bytes   "SDPR"
protocol_version  u32
request_id        u64
status            i32
processing_ms     u64
text_length       u64
text              UTF-8
error_length      u32
error             UTF-8
```

The helper must validate all lengths before allocating memory and impose an audio-duration limit matching the application.

## Vulkan behavior

The helper is built with:

```text
-DPARAKEET_GGML_VULKAN=ON
```

and linked against MoltenVK statically. No Homebrew dylib may remain in the shipped app.

Vulkan is preferred only when:

- the user enabled the Parakeet Vulkan backend;
- ggml enumerates a Vulkan device;
- the helper loads the model successfully on that device;
- a warm-up request completes within the configured timeout.

Unsupported ggml operations may fall back to CPU. This is acceptable, but measurements must prove that the full path is faster than pure CPU for typical 3–30 second dictations.

Expected risks:

- first-run shader pipeline compilation;
- model upload and VRAM pressure;
- CPU/GPU transfer overhead on short clips;
- incomplete acceleration of TDT decoding operations;
- MoltenVK/ggml regressions;
- a GPU speedup smaller than the encoder-heavy Whisper speedup.

## CPU fallback

CPU is not optional. On Vulkan helper failure, SuperDictate should:

1. terminate the failed helper;
2. start it again with `PARAKEET_DEVICE=cpu`;
3. retry the active dictation exactly once;
4. record the Vulkan failure in diagnostics;
5. keep Parakeet CPU active for the rest of the session unless the user manually retries Vulkan.

Use an x86_64 build with AVX2/FMA and Accelerate where supported. Start with a `q8_0` GGUF. Consider `q6_k` only after measuring accuracy and memory.

## Swift abstraction

Replace the concrete Whisper-only engine enum with a backend-neutral protocol:

```swift
protocol SpeechRecognitionEngine: Sendable {
    var identifier: String { get }
    func transcribe(samples: [Float], language: DictationLanguage?) async throws -> ASRResult
    func warmUp() async throws
    func shutdown() async
}

struct ASRResult: Sendable {
    let text: String
    let processingSeconds: Double
}
```

Implementations:

```text
WhisperCPPRecognitionEngine
ParakeetHelperRecognitionEngine
```

Persisted selections:

```text
automatic
whisperCPU
whisperVulkan
parakeetCPU
parakeetVulkan
```

During the experimental phase, `automatic` must continue to resolve to the current stable backend. After validation it may resolve to Parakeet Vulkan when a compatible GPU is present, otherwise Parakeet CPU.

The existing `TranscriptionWorker` actor remains the serialization boundary and owns exactly one loaded engine.

## Model download

Pin all model inputs:

- immutable model repository revision;
- exact filename;
- expected byte size;
- SHA-256;
- compatible helper protocol/runtime version.

Store the GGUF under:

```text
~/Library/Application Support/SuperDictate/models/parakeet-tdt-0.6b-v3/
```

The update process must never silently replace a model with a newer unpinned artifact.

## Language and transcript processing

Resolve `DictationLanguage` inside the backend adapter. Keep `auto` as the default. Do not expose implementation-specific locale handling to the rest of the UI.

Retain the current deterministic transcript correction and filler-removal pipeline. Model-specific repairs must be conditional on the selected backend. In particular, test the current `<unk>`/Cyrillic `ё` repair against Parakeet output before applying it globally.

## Packaging and signing

The build must:

1. build the Swift executable for x86_64;
2. build `SuperDictateParakeet` for x86_64 with CPU+Vulkan;
3. statically link MoltenVK;
4. copy the helper to `Contents/Helpers`;
5. copy required Vulkan shader resources if the pinned ggml revision does not embed them;
6. sign the helper first with hardened runtime;
7. sign the outer app last;
8. verify with `codesign --verify --deep --strict`;
9. verify with `otool -L` that no `/usr/local` or Homebrew dylib remains.

## Failure contract

Handle explicitly:

- helper startup timeout;
- protocol/version mismatch;
- invalid or truncated frame;
- helper crash;
- model checksum failure;
- insufficient RAM or VRAM;
- Vulkan initialization failure;
- inference timeout;
- empty transcript;
- parent-process cancellation.

Do not retry indefinitely. One Vulkan-to-CPU retry per dictation is the maximum.

## Validation gates

Test on the target Intel Mac and Radeon RX 6600 with Russian and English audio.

Collect:

- cold model load time;
- Vulkan pipeline warm-up time;
- warm CPU and Vulkan processing time;
- real-time factor for 3 s, 10 s, 30 s and 120 s clips;
- peak resident RAM;
- peak VRAM;
- first and subsequent request latency;
- accuracy on a fixed local corpus;
- punctuation and capitalization quality;
- mixed Russian/English names and technical vocabulary;
- 100 consecutive dictations;
- restart, helper crash, model reset and update behavior.

Initial acceptance targets:

- warm RTF below 1.0 on CPU and Vulkan;
- Vulkan median end-to-end latency at least 20% below Parakeet CPU on 10–30 second clips;
- no material accuracy regression relative to the current Whisper backend;
- deterministic fallback after Vulkan failure;
- no unsigned or external runtime dependency;
- no leaked helper process after application exit or backend change.

## Implementation sequence

### Phase 1 — helper spike

- Vendor a pinned `parakeet.cpp` revision and its ggml submodule.
- Build an x86_64 helper with CPU+Vulkan.
- Add a `--self-test`, `--device-list` and framed-stdio server mode.
- Download a pinned q8_0 Parakeet TDT v3 GGUF.
- Benchmark CPU and Vulkan on the target Mac.

### Phase 2 — application adapter

- Add `SpeechRecognitionEngine`.
- Wrap the current Whisper engine without changing behavior.
- Add the persistent Parakeet helper client.
- Add model download and checksum verification.
- Add CPU fallback and diagnostics.

### Phase 3 — settings and packaging

- Add Parakeet CPU and Parakeet Vulkan choices.
- Package and sign the helper.
- Add updater and uninstall coverage for the new model directory.
- Add CI checks for protocol tests and CPU helper build.

### Phase 4 — promotion

- Run the fixed corpus and stability suite.
- Make Parakeet Vulkan the default only on verified compatible hardware.
- Keep a user-selectable Whisper fallback.
