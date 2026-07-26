# Keyboard-Language Detection, Fast Short-Clip Encoding, and GPU Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dictation faster by (a) forcing the transcription language from the user's currently active keyboard input source instead of relying on whisper.cpp's own (unreliable-under-trimmed-context) auto-detect, (b) sizing whisper's encoder context (`audio_ctx`) to the actual recording length instead of always paying for the full fixed 30-second window whenever a concrete language is known, and (c) adding an opt-in "Use GPU" setting that loads the whisper.cpp Metal backend instead of CPU+BLAS, off by default.

**Architecture:** Three independent, additive changes to the existing whisper.cpp-based `WhisperEngine`/`TranscriptionWorker` pipeline (`swift/Sources/Parakey/main.swift`, `swift/Sources/Parakey/WhisperEngine.swift`):
1. A new small helper resolves the current keyboard input source to an ISO-639-1 code via Carbon's Text Input Sources API, used to override `.auto` before it reaches whisper.
2. `WhisperEngine.transcribe` computes `whisper_full_params.audio_ctx` from the real sample count whenever a concrete (non-nil) language is being used, with a safety margin and a hard clamp derived from whisper.cpp's own validation, to avoid the `WHISPER_ASSERT(n_frames <= n_audio_ctx * 2)` crash.
3. The `whisper_cpp` SwiftPM target gains a vendored `ggml-metal` backend (currently entirely absent), gated behind a new persisted `useGPU` setting and a menu checkbox; the model context is reloaded when the setting changes.

**Tech Stack:** Swift 6 / SwiftPM, vendored whisper.cpp/ggml C/C++/Objective-C++/Metal sources, Carbon Text Input Sources API (`TISCopyCurrentKeyboardInputSource`), macOS `NSMenuItem`/`UserDefaults`.

## Global Constraints

- Whisper's audio sample rate is `WHISPER_SAMPLE_RATE = 16000` (`swift/Sources/whisper_cpp/include/whisper.h:33`). Frame rate for `audio_ctx` purposes is 50 frames/second (1500 frames = 30s), i.e. `framesNeeded = ceil(durationSeconds * 50)`.
- whisper.cpp hard-validates `audio_ctx`: `whisper_full` rejects (returns an error code, does not crash) any `params.audio_ctx > whisper_n_audio_ctx(ctx)` (the model max, 1500 for `large-v3-turbo`). Never exceed this.
- whisper.cpp separately hard-asserts (process-terminating `WHISPER_ASSERT`, NOT a recoverable error) if `n_frames > n_audio_ctx * 2` during encoding (`whisper.cpp:9000`). The chosen `audio_ctx` MUST always satisfy `audio_ctx >= ceil(realFrameCount / 2)` with margin — real frame count here is the mel frame count, itself `ceil(samples.count / 16000 * 100)` (10ms mel hop) — treat this as the hard floor, computed generously (round up, add margin), never the ceiling.
- Trimming `audio_ctx` is only safe to combine with an explicitly forced (non-nil, non-"auto") language string. It must NEVER be applied when whisper.cpp is asked to auto-detect the language itself — verified on real hardware that trimmed-context auto-detect silently mistranslates/garbles multilingual (e.g. Russian) audio into English, while the same trimmed context transcribes correctly once the language is forced. See `docs/superpowers/specs/2026-07-26-intel-mac-support-design.md` history and this session's benchmarks for the evidence trail.
- `DictationLanguage`'s raw value IS whisper.cpp's ISO-639-1 language string (`swift/Sources/Parakey/main.swift:382-407`) — reuse this mapping, do not invent a new one.
- GPU (Metal) support must be strictly opt-in and default OFF. `WhisperEngine.init` currently hardcodes `params.use_gpu = false` (`swift/Sources/Parakey/WhisperEngine.swift:39`) — this stays the behavior unless the new setting is explicitly enabled.
- Never touch `/Applications/SuperDictate.app` or the live LaunchAgent during development/testing — all testing happens via fresh builds in scratch directories on the real Intel Mac (`shohart@192.168.1.246`), exactly as done for every prior task in this project.
- All benchmarking must happen on the real Intel Mac Pro hardware (SSH: `shohart@192.168.1.246`, password `n0tn33d3d`) — this environment cannot compile or run Swift/macOS code.
- Preserve existing behavior for users who never touch the new setting: default language resolution behavior changes (see Task 1) but is intended to be a strict quality/speed improvement with a safe fallback to today's `"auto"` string when keyboard-language detection fails or maps to an unsupported language.

---

### Task 1: Resolve `.auto` dictation language from the active keyboard input source

**Files:**
- Create: `swift/Sources/Parakey/KeyboardLanguage.swift`
- Modify: `swift/Sources/Parakey/main.swift` (the `transcribe(samples:language:requestedAt:)` call site, ~line 5350-5369)
- Test: existing self-test block in `main.swift` (search for `// exercise the DictationLanguage → whisperLanguageCode half of that` around line 17967) — add cases there.

**Interfaces:**
- Produces: `func currentKeyboardLanguageCode() -> String?` — a free function (not actor-isolated; Carbon TIS calls are main-thread-safe, synchronous, cheap) returning a lowercased ISO-639-1 code (e.g. `"ru"`, `"en"`) if the current keyboard input source's primary language maps to one, or `nil` if undetectable/unmapped.
- Produces: `func resolveEffectiveWhisperLanguage(setting: DictationLanguage) -> String?` — if `setting != .auto`, returns `setting.whisperLanguageCode` unchanged (existing behavior for explicit selections). If `setting == .auto`, calls `currentKeyboardLanguageCode()`; if it returns a code matching some `DictationLanguage.allCases` `rawValue` (excluding `.auto` itself), returns that code; otherwise returns `nil` (falls through to whisper.cpp's own auto-detect, today's existing behavior, so nothing regresses when detection is unavailable/unsupported).
- Consumes: `DictationLanguage.allCases`, `DictationLanguage(rawValue:)` (existing, `main.swift:382-407`).

- [ ] **Step 1: Write `KeyboardLanguage.swift`**

```swift
import Carbon
import Foundation

/// Reads the language of the user's *currently active keyboard input source*
/// (e.g. "Russian", "U.S.") via Carbon's Text Input Sources API — the same
/// signal macOS itself uses to label the input menu. This is a much cheaper
/// and more reliable signal for "what language is the user typing/speaking"
/// than asking whisper.cpp to auto-detect it from audio, especially once
/// `audio_ctx` is trimmed for speed (see WhisperEngine.swift): whisper's own
/// auto-detect was found to become unreliable under a trimmed encoder
/// context, silently mistranslating non-English speech into English.
func currentKeyboardLanguageCode() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
        return nil
    }
    guard let languagesPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
        return nil
    }
    let languages = Unmanaged<CFArray>.fromOpaque(languagesPtr).takeUnretainedValue() as NSArray
    guard let first = languages.firstObject as? String else {
        return nil
    }
    // BCP-47 tags like "en-US" or "ru" — whisper.cpp/DictationLanguage only
    // care about the primary subtag.
    let primary = first.split(separator: "-").first.map(String.init) ?? first
    return primary.lowercased()
}

/// See KeyboardLanguage.swift's file doc comment for why this exists.
/// Falls back to whisper.cpp's own auto-detect (returns nil) whenever the
/// keyboard signal is unavailable or maps to a language this app doesn't
/// know how to force — never regresses on today's behavior in that case.
func resolveEffectiveWhisperLanguage(setting: DictationLanguage) -> String? {
    guard setting == .auto else {
        return setting.whisperLanguageCode
    }
    guard let keyboardCode = currentKeyboardLanguageCode(),
          DictationLanguage(rawValue: keyboardCode) != nil else {
        return nil
    }
    return keyboardCode
}
```

- [ ] **Step 2: Wire it into the transcription call site**

In `swift/Sources/Parakey/main.swift`, inside `TranscriptionWorker.transcribe(samples:language:requestedAt:)`, change:

```swift
            let result = try await whisper.transcribe(
                samples: samples,
                languageCode: language?.whisperLanguageCode
            )
```

to:

```swift
            let result = try await whisper.transcribe(
                samples: samples,
                languageCode: resolveEffectiveWhisperLanguage(setting: language ?? .auto)
            )
```

(`language` is already optional at this call site with `.auto`-equivalent meaning when nil — confirm by reading the caller of `transcribe(samples:language:requestedAt:)` and preserve whatever nil means there; if nil already means "use `settings.dictationLanguage`" resolved earlier, resolve against that value instead of hardcoding `.auto` — read the surrounding ~30 lines above the call site before editing to get this right.)

- [ ] **Step 3: Add self-test coverage**

Find the existing self-test block near `main.swift:17967` (`// exercise the DictationLanguage → whisperLanguageCode half of that`). Add assertions there (adapt to that block's existing assertion style — read it first) covering:
- `resolveEffectiveWhisperLanguage(setting: .russian) == "ru"` (explicit selection unaffected).
- `resolveEffectiveWhisperLanguage(setting: .auto)` does not crash and returns either `nil` or a valid `DictationLanguage.allCases` rawValue (can't assert a specific keyboard layout in CI/SSH-only testing, but must not throw/crash).

- [ ] **Step 4: Build and run self-test on the real Mac**

SSH to `shohart@192.168.1.246` (password `n0tn33d3d`), build the package (`swift build` or existing `scripts/build-app.sh` debug path used earlier in this project — check `.superpowers/sdd/2026-07-26-intel-mac-whisper-port/progress.md` for the exact command pattern used previously), run the self-test target, confirm PASS.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/KeyboardLanguage.swift swift/Sources/Parakey/main.swift
git commit -m "Resolve auto-detect dictation language from active keyboard input source"
```

---

### Task 2: Size whisper's encoder context to the real recording length

**Files:**
- Modify: `swift/Sources/Parakey/WhisperEngine.swift`

**Interfaces:**
- Consumes: `samples: [Float]` (already a parameter of `transcribe(samples:languageCode:)`), `languageCode: String?` (already a parameter; after Task 1, callers pass a concrete code far more often than before).
- Produces: sets `params.audio_ctx` (an `Int32` field on `whisper_full_params`, `swift/Sources/whisper_cpp/include/whisper.h:515`) before calling `Self.runWhisperFull`.

- [ ] **Step 1: Add the sizing helper**

In `WhisperEngine.swift`, add (as a private static function on the `WhisperEngine` actor, or a free function in the same file — either is fine, match existing file style):

```swift
    /// whisper.cpp encodes a fixed 1500-frame (30s) window by default
    /// regardless of real audio length — the dominant cost for short
    /// dictation clips. `audio_ctx` lets us request a smaller window, cutting
    /// encode time roughly proportionally, but two hard constraints from
    /// whisper.cpp itself bound how small we can safely go:
    ///   1. `whisper_full` rejects (recoverable error) any audio_ctx above
    ///      the model's max (`whisper_n_audio_ctx`, 1500 for large-v3-turbo).
    ///   2. whisper.cpp *hard-asserts* (crashes the process) if the real mel
    ///      frame count exceeds `audio_ctx * 2` — so audio_ctx must always
    ///      generously cover the real audio length, never just barely.
    /// This is ONLY safe to use when the language is being explicitly forced
    /// (non-nil `languageCode`, resolved either from an explicit user
    /// selection or from the keyboard-layout signal in KeyboardLanguage.swift)
    /// — trimming the context while asking whisper to auto-detect the
    /// language itself was found to silently mistranslate/garble non-English
    /// audio into English on real hardware.
    private static func audioContextFrames(forSampleCount sampleCount: Int, modelMaxAudioCtx: Int32) -> Int32 {
        let framesPerSecond = 50.0 // 1500 frames / 30s
        let durationSeconds = Double(sampleCount) / Double(WHISPER_SAMPLE_RATE)
        // Generous margin: double the naive requirement, since the hard
        // assert triggers at audio_ctx * 2 real frames — this keeps real
        // usage far from that boundary even for imprecise duration estimates.
        let neededFrames = Int32((durationSeconds * framesPerSecond * 2.0).rounded(.up))
        return min(modelMaxAudioCtx, max(neededFrames, 256))
    }
```

(Confirm `WHISPER_SAMPLE_RATE` is visible from Swift — it's a C `#define`, likely not bridged; if unavailable, hardcode `16000.0` with a comment pointing at `whisper.h:33` instead.)

- [ ] **Step 2: Call it from `transcribe(samples:languageCode:)`**

After the existing `params.language = UnsafePointer(languageCString)` line and before `Self.runWhisperFull(...)`, add:

```swift
        if let languageCString, String(cString: languageCString) != "auto" {
            let modelMax = whisper_n_audio_ctx(context)
            params.audio_ctx = Self.audioContextFrames(forSampleCount: samples.count, modelMaxAudioCtx: modelMax)
        }
```

(Adjust the exact condition to match Step's actual variable names in the file — the key invariant is: only set `audio_ctx` when the resolved language string is a real concrete language, never for the literal `"auto"` string that reaches `params.language` today.)

- [ ] **Step 3: Add unit-style coverage in the self-test block**

Add assertions to the existing self-test block (same location as Task 1 Step 3, or wherever `WhisperEngine`-adjacent pure-function tests already live) for `audioContextFrames`:
- A 2-second clip (`sampleCount = 32000`) returns something small and well above `256` but far below `1500`.
- A 35-second clip (`sampleCount = 560000`, longer than the model max window) clamps to `1500` (the `modelMaxAudioCtx` passed in), never exceeds it.
- A near-zero sample count (`sampleCount = 0` or a few hundred samples) returns at least `256` (the floor), never `0` or negative.

- [ ] **Step 4: Benchmark on real hardware — verify speed AND correctness**

Using the standalone reference build or a fresh SwiftPM debug build on `shohart@192.168.1.246`:
- Re-run the existing 3 Russian samples (`/tmp/whispercpp_bench/samples/ru_sample{,2,3}.wav`) end-to-end through the actual app code path (not just `whisper-cli`) with a concrete forced language, confirm output text matches the known-correct baseline transcripts from this session's earlier benchmarking, and confirm total time drops meaningfully versus the unmodified (full 1500-context) baseline.
- Test at least one longer clip (30s+) to confirm no regression/crash when `durationSeconds` approaches or exceeds the model's max window.
- Test a very short clip (1-2s) to confirm the floor clamp prevents any assert-crash.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/WhisperEngine.swift
git commit -m "Size whisper's audio_ctx to the real recording length for forced-language transcriptions"
```

---

### Task 3: Vendor the ggml-metal backend

**Files:**
- Modify: `scripts/vendor-whisper-cpp.sh`
- Modify: `swift/Package.swift`
- Create (via the vendoring script, not by hand): `swift/Sources/whisper_cpp/ggml-metal.cpp` (or `.m`/`.mm`, whichever the pinned commit `080bbbe85230f624f0b52127f1ae1218247989f9` uses) and its Metal shader source.

**Interfaces:**
- Produces: the `whisper_cpp` target compiles with `GGML_USE_METAL` defined and links `Metal`/`MetalKit`/`Foundation` frameworks, making `ggml_backend_metal_reg()` register at runtime — but registering a backend does NOT change default behavior; `WhisperEngine.init`'s `params.use_gpu` still controls whether it's actually used (Task 4 wires that).
- Consumes: the pinned whisper.cpp commit already used by `scripts/vendor-whisper-cpp.sh` (`080bbbe85230f624f0b52127f1ae1218247989f9`) — vendor Metal files from the exact same commit, never a different one, to avoid version drift with the rest of the already-vendored sources.

- [ ] **Step 1: Inspect the pinned commit's Metal backend file layout**

On a machine with the whisper.cpp reference checkout already available (the Mac has one at `/tmp/whispercpp_bench` from this session's benchmarking, or clone fresh at the pinned commit), inspect `ggml/src/ggml-metal/` — note exact filenames (typically `ggml-metal.cpp` or `ggml-metal.m`, `ggml-metal-impl.h`, `ggml-metal.metal` or a generated embedded-library `.cpp`, depending on the exact pinned commit's structure) and how upstream's own `CMakeLists.txt`/`Makefile` builds it (in particular how the `.metal` shader source gets embedded — recent whisper.cpp versions generate a C string literal from the `.metal` file at build time via a small script or `xxd`-equivalent, since SwiftPM cannot invoke arbitrary custom build steps the way CMake can).

- [ ] **Step 2: Update `scripts/vendor-whisper-cpp.sh`**

Add copying of the Metal backend source files identified in Step 1, alongside the existing `ggml-blas.cpp` copy this script already performs (added in the earlier BLAS fix — read the script to match its existing style exactly). If the `.metal` shader needs embedding as a string literal (rather than a runtime-loaded resource), either:
- Vendor the already-generated embedded-library `.cpp`/`.h` from the pinned commit if the whisper.cpp build system produces one and checks it in, or
- Write a small, well-commented conversion step in the vendoring script that generates the embedded C string from the `.metal` source at vendor time (checked into the repo as a generated file, regenerated only when re-vendoring) — do NOT attempt a SwiftPM build-time code generation step; SwiftPM plugins are out of scope here.

Document whichever approach is taken directly in the vendoring script's comments, since this is the one piece of this plan most likely to need adaptation once the real file layout is inspected in Step 1.

- [ ] **Step 3: Update `swift/Package.swift`**

Add to the `whisper_cpp` target's `cSettings`/`cxxSettings` unsafe flags/defines list (alongside the existing `GGML_USE_BLAS`, `GGML_USE_ACCELERATE`, etc.): `GGML_USE_METAL`, and `GGML_METAL_EMBED_LIBRARY` if Step 2 embeds the shader as a string literal. Add `Metal` and `MetalKit` to the target's `linkerSettings` frameworks list (alongside the existing `Accelerate`). Do not remove or weaken any existing CPU/BLAS configuration — Metal is additive.

- [ ] **Step 4: Build and confirm the backend registers without being used**

On the real Mac, in a fresh scratch build directory (never `/Applications`), `swift build`, then run the app's existing self-test / a small debug harness that calls `whisper_print_system_info()` or checks `ggml_backend_reg_count()`/backend names to confirm a Metal backend is now registered. Confirm the app still runs CPU-only end-to-end with today's default settings (no behavior change yet — Task 4 adds the toggle).

- [ ] **Step 5: Commit**

```bash
git add scripts/vendor-whisper-cpp.sh swift/Package.swift swift/Sources/whisper_cpp/
git commit -m "Vendor the ggml-metal backend (registered but not enabled by default)"
```

---

### Task 4: "Use GPU" setting, wired to `WhisperEngine`'s `use_gpu` and engine reload

**Files:**
- Modify: `swift/Sources/Parakey/WhisperEngine.swift` (init signature)
- Modify: `swift/Sources/Parakey/main.swift` (Settings key + property, menu item, `TranscriptionWorker.load`/`loadWhisperEngine`)

**Interfaces:**
- Produces: `Settings.useGPU: Bool` (persisted via a new `keyUseGPU` UserDefaults key, default `false`), following the exact pattern of `Settings.dictationLanguage`/`removeFillerWords` (`main.swift` around line 2624-2645 and their property implementations — read an existing simple `Bool` setting like `removeFillerWords` for the exact getter/setter pattern before writing this one).
- Consumes: `WhisperEngine.init(modelPath:)` — extend to `WhisperEngine.init(modelPath: String, useGPU: Bool)`, setting `params.use_gpu = useGPU` instead of the hardcoded `false` (`WhisperEngine.swift:39`).
- Consumes/Modifies: `TranscriptionWorker.load(profile:progressHandler:)` — currently reloads only when `loadedProfile != profile`; must also reload when the GPU setting has changed since the last load. Add a `private var loadedUseGPU: Bool?` alongside the existing `loadedProfile`, and include it in the "already ready, skip reload" check.

- [ ] **Step 1: Add the `Settings.useGPU` property**

Read `removeFillerWords`'s getter/setter in `main.swift` for the exact pattern (likely `defaults.bool(forKey:)` / `defaults.set(_:forKey:)`), and add:

```swift
    private static let keyUseGPU = "use_gpu"
```

alongside the other `private static let key...` declarations (~line 2630), and a `var useGPU: Bool { get { ... } set { ... } }` computed property following the exact style of the nearest existing `Bool` setting, defaulting to `false` when the key is unset.

- [ ] **Step 2: Thread `useGPU` through `WhisperEngine.init` and `loadWhisperEngine`**

```swift
    init(modelPath: String, useGPU: Bool) throws {
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperEngineError.modelLoadFailed(path: modelPath)
        }
        context = ctx
    }
```

Update `loadWhisperEngine(progressHandler:)` to pass `settings.useGPU` (or however `Settings.shared` is accessed at that call site — match existing style) into `WhisperEngine(modelPath:useGPU:)`.

- [ ] **Step 3: Reload the engine when the setting changes**

In `TranscriptionWorker`, add `private var loadedUseGPU: Bool?`. In `load(profile:progressHandler:)`, change:

```swift
        if ready, engine != nil, loadedProfile == profile {
```

to also require `loadedUseGPU == currentUseGPUSetting` (read the setting the same way `loadWhisperEngine` will), and set `loadedUseGPU = currentUseGPUSetting` alongside `loadedProfile = profile` after a successful load. The existing `if engine != nil { await unload() }` path already handles tearing down the old engine before constructing the new one — confirm `unload()` frees the whisper context (`whisper_free`, via `WhisperEngine.deinit`) before the new one loads, so there's never two contexts (one CPU, one GPU) resident at once.

Find wherever `TranscriptionWorker.load(...)` already gets re-invoked in response to other settings changes (search for other `settings.dictationLanguage =` / `rebuildMenu()` call sites triggering a reload, if any exist) to decide whether the GPU toggle needs an explicit `Task { try? await worker.load(profile: ...) }` kick after flipping the setting, or whether the next natural `load` call (e.g. on next dictation) picks it up automatically via the changed-setting check added above. Prefer triggering an explicit reload immediately after the toggle so the user doesn't hit an unexpected multi-second delay mid-dictation the first time they record after toggling.

- [ ] **Step 4: Add the menu checkbox**

Following the exact pattern of `buildBehaviorSettingsItem()`'s `waveform` item (`main.swift` ~13714-13722), add a "Use GPU (Metal) — experimental" `NSMenuItem` with a new `@objc private func toggleUseGPU(_ sender: NSMenuItem)` action (mirroring `toggleRecordingWaveform`), that flips `settings.useGPU`, triggers the reload from Step 3, and calls `rebuildMenu()`. Place it in whichever settings submenu makes sense given the existing menu structure (`buildBehaviorSettingsItem` or a new dedicated item next to `buildDictationLanguageSettingsItem` — use judgment matching the existing menu's organization).

- [ ] **Step 5: Build, and hardware-verify GPU on/off both work without crashing**

On the real Mac, fresh scratch build (never `/Applications`):
- Default (GPU off): confirm identical behavior/output to before this task.
- Toggle GPU on: confirm the app reloads the engine, transcribes correctly (compare output text against the known-correct baseline transcripts), and does not crash — across the 3 Russian samples and at least one English sample.
- Toggle back off: confirm it reloads back to CPU+BLAS correctly.
- Watch for the earlier-observed Metal correctness risk: run each GPU-on test at least twice to catch any intermittent garbling; if ANY run produces wrong-language or garbled output, stop and report it as a blocking finding rather than proceeding — this was an open risk flagged during this session's research and this is the first time it's exercised through the app's actual vendored code path rather than the standalone reference `whisper-cli`.

- [ ] **Step 6: Commit**

```bash
git add swift/Sources/Parakey/WhisperEngine.swift swift/Sources/Parakey/main.swift
git commit -m "Add opt-in 'Use GPU' setting wired to whisper.cpp's Metal backend"
```

---

### Task 5: End-to-end real-hardware verification and README update

**Files:**
- Modify: `README.md` (mention the new GPU toggle as experimental/opt-in, and that language auto-detect now prefers the active keyboard layout)
- Test: full app build + install to a scratch location (never `/Applications`) on `shohart@192.168.1.246`

**Interfaces:**
- Consumes: everything from Tasks 1-4.

- [ ] **Step 1: Full self-test suite**

Run the app's complete existing self-test target on the real Mac; confirm 100% pass, including the new assertions added in Tasks 1 and 2.

- [ ] **Step 2: Manual multi-language keyboard-layout test**

With the real Mac's keyboard input source switched to at least two different layouts corresponding to `DictationLanguage` cases (e.g. U.S. English and Russian), record short dictation samples with `.auto` selected in the app's language menu, and confirm each transcribes in the language matching the active keyboard layout at the time — this is the one behavior this plan cannot verify via SSH-only scripting (requires physically switching the input source and either live speech or an injected audio path exercising the real `.auto` menu state), so this step requires the user's direct participation on the physical machine.

- [ ] **Step 3: Regression check against the BLAS-fix and focus-fix benchmarks**

Re-run the same before/after style comparison used for the earlier BLAS fix (same-machine, same-model, byte-identical-transcript check) to confirm this plan's changes are a pure improvement and haven't reintroduced the earlier-fixed slowness or the focus/paste-target bug — those two fixes are unrelated to this plan's changes but share code paths (`TranscriptionWorker`, `WhisperEngine`) worth a quick smoke-test pass.

- [ ] **Step 4: Update README**

Add a short paragraph noting: dictation language now follows the active keyboard layout when "Auto-detect" is selected (falling back to whisper's own detection if the layout is unrecognized), and an experimental opt-in "Use GPU" setting exists for users who want to try Metal acceleration (off by default; CPU+BLAS remains the default and recommended path given mixed real-hardware evidence on the AMD GPU).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document keyboard-layout language detection and the experimental GPU toggle"
```
