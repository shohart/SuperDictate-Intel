import Foundation
import whisper_cpp

enum WhisperEngineError: LocalizedError {
    case modelLoadFailed(path: String)
    case transcriptionFailed(code: Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load whisper.cpp model at \(path)"
        case .transcriptionFailed(let code):
            return "whisper_full failed with code \(code)"
        }
    }
}

struct WhisperTranscription: Sendable {
    let text: String
    let encodeSeconds: Double
    let totalSeconds: Double
}

/// Owns one loaded whisper.cpp context. Not re-entrant — `TranscriptionWorker`
/// (main.swift) is the single caller and already serializes transcribe calls;
/// see the comment above that actor for why re-entrancy would corrupt state.
actor WhisperEngine {
    // `OpaquePointer` doesn't conform to `Sendable`, which under Swift 6
    // strict concurrency would otherwise block reading this property from
    // `deinit` (always nonisolated) and from the C interop calls below.
    // Safety is still provided by the actor: `context` is only ever mutated
    // once (in `init`) and every other access is serialized through
    // `WhisperEngine`'s actor isolation — `nonisolated(unsafe)` just tells
    // the compiler what's already true.
    private nonisolated(unsafe) let context: OpaquePointer

    init(modelPath: String, useGPU: Bool) throws {
        // Must happen before whisper_init_from_file_with_params below, which
        // is this project's single entry point into whisper.cpp's backend
        // machinery (whisper_backend_init -> ggml-backend-reg.cpp's registry
        // singleton -> ggml_backend_vk_reg()). Registration itself only
        // creates a VkInstance and enumerates physical devices — it does
        // NOT touch any shader — but the first *pipeline* a Vulkan device
        // actually creates (reachable only once a GPU device is selected,
        // i.e. only when useGPU is true) resolves every shader by name
        // through the runtime loader in ggml-vulkan-shaders-runtime.h. If
        // that loader hasn't been pointed at a real directory by then, every
        // shader silently resolves to a null pointer + zero length instead
        // of failing cleanly — see the Package.swift comment above the
        // (now-removed) ggml-vulkan.cpp exclude entry and
        // include/ggml-vulkan-shaders-runtime.h's doc comment for why this
        // call is not optional. Calling it unconditionally (not just when
        // useGPU is true) is deliberate and cheap: it only stores a string
        // for the loader to consult later, matching the doc comment's
        // "safe to call more than once, most recent call wins" contract.
        WhisperEngine.configureVulkanShaderDirectory()

        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelPath, params) else {
            throw WhisperEngineError.modelLoadFailed(path: modelPath)
        }
        context = ctx
    }

    /// Resolves `Contents/Resources/vulkan-shaders/` in the running app
    /// bundle (the canonical .app layout scripts/build-app.sh copies the
    /// shader corpus into per Task 4 of the intel-mac-vulkan-backend plan —
    /// same `Bundle.main`-relative pattern `configureStatusItemImage()` in
    /// main.swift uses for the menubar PNGs) and hands it to the C++ shader
    /// loader — but ONLY if that directory actually exists on disk.
    ///
    /// This existence check is not optional, and was added after an
    /// on-device test proved the naive "always call down, let the C++ side
    /// sort it out" version wrong: `ggml-vulkan-shaders-runtime.cpp`'s
    /// 3-tier fallback (env var, then the explicitly configured directory,
    /// then a source-relative dev path) treats "configured" and "exists"
    /// as the same thing — once `ggml_vk_shaders_set_directory()` has been
    /// called with ANY non-empty string, that string permanently outranks
    /// tier 3's source-relative fallback for the rest of the process,
    /// even if the path doesn't exist. In a `swift run`/`swift build` dev
    /// build (no real .app bundle yet), `Bundle.main.resourceURL` still
    /// resolves to *something* (the build products directory), just not
    /// one containing `vulkan-shaders/` — calling down with that path
    /// unconditionally silently defeated the dev-build fallback entirely:
    /// measured on real hardware, every one of the 1785 shaders failed to
    /// load (logged to stderr) and `useGPU: true` model init went from the
    /// expected ~2s to 37.6s. Checking existence here keeps the shipped-app
    /// path (where the directory genuinely exists, copied in by
    /// scripts/build-app.sh) working exactly as before, while leaving dev
    /// builds to fall through to the source-relative fallback as intended.
    private static func configureVulkanShaderDirectory() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let shaderDir = resourceURL.appendingPathComponent("vulkan-shaders", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: shaderDir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }
        shaderDir.path.withCString { ggml_vk_shaders_set_directory($0) }
    }

    /// `languageCode` is `nil` for auto-detect (i.e. `DictationLanguage.auto`).
    /// `nil` MUST be turned into the literal string `"auto"` before it reaches
    /// `whisper_full_params.language` — `whisper_full_default_params()` sets
    /// that field to whisper.cpp's compiled-in default `"en"`, not `nullptr`,
    /// so leaving `params.language` untouched on `nil` would silently force
    /// every auto-detect transcription through the English decoder path
    /// instead of actually detecting the spoken language. Only the literal
    /// strings `"auto"`, `nullptr`, or `""` make whisper.cpp auto-detect.
    func transcribe(samples: [Float], languageCode: String?) throws -> WhisperTranscription {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.no_timestamps = true
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))

        // Always route through strdup/free, even for the nil (auto-detect)
        // case — assigning a Swift string literal's contents directly to
        // params.language would create a dangling pointer once the literal's
        // backing storage is released.
        let languageCString = strdup(languageCode ?? "auto")
        defer { free(languageCString) }
        params.language = UnsafePointer(languageCString)

        // Only trim the encoder window when a concrete language is being
        // forced — never when whisper.cpp itself will auto-detect the
        // language. Checked against `languageCode` (the Swift parameter)
        // directly rather than the strdup'd C string, so this matches all
        // three values whisper.cpp itself treats as "auto-detect" (per the
        // doc comment above `transcribe`: nullptr, "", and "auto") instead
        // of only excluding the literal "auto" string — today's callers
        // (KeyboardLanguage.swift, DictationLanguage.whisperLanguageCode)
        // never produce "", but this keeps the guard correct by construction
        // rather than relying on that. Trimming during auto-detect was found
        // on real hardware to silently mistranslate/garble non-English audio.
        // See `audioContextFrames` doc comment for the margin this relies on.
        if let languageCode, languageCode != "auto", !languageCode.isEmpty {
            let modelMaxAudioCtx = whisper_n_audio_ctx(context)
            params.audio_ctx = Self.audioContextFrames(
                forSampleCount: samples.count,
                modelMaxAudioCtx: modelMaxAudioCtx
            )
        }

        let encodeStartedAt = ProcessInfo.processInfo.systemUptime
        let result = Self.runWhisperFull(context: context, params: params, samples: samples)
        let encodeCompletedAt = ProcessInfo.processInfo.systemUptime
        guard result == 0 else {
            throw WhisperEngineError.transcriptionFailed(code: result)
        }

        var text = ""
        let segmentCount = whisper_full_n_segments(context)
        for i in 0..<segmentCount {
            if let segmentText = whisper_full_get_segment_text(context, i) {
                text += String(cString: segmentText)
            }
        }

        return WhisperTranscription(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            encodeSeconds: encodeCompletedAt - encodeStartedAt,
            totalSeconds: ProcessInfo.processInfo.systemUptime - requestedAt
        )
    }

    deinit {
        whisper_free(context)
    }

    /// whisper.cpp encodes a fixed 1500-frame (30s) window by default
    /// regardless of real audio length — the dominant cost for short
    /// dictation clips. `audio_ctx` lets us request a smaller window, cutting
    /// encode time roughly proportionally, but two constraints from
    /// whisper.cpp itself bound how small we can safely go:
    ///   1. `whisper_full` rejects (recoverable error) any audio_ctx above
    ///      the model's max (`whisper_n_audio_ctx`, 1500 for large-v3-turbo).
    ///   2. The encoder's conv/attention graph (`whisper_build_graph_conv`,
    ///      whisper.cpp:2393-2398) clamps an undersized audio_ctx via
    ///      `std::min(mel_offset + 2*n_ctx, mel_inp.n_len)` — it will not
    ///      crash, but if `audio_ctx` is sized too tightly relative to the
    ///      real audio duration (e.g. from an imprecise duration estimate),
    ///      the encoder silently truncates trailing speech out of the
    ///      window, dropping the end of the utterance from the transcript.
    ///      The 2x margin below exists to keep normal duration estimates
    ///      far from that truncation boundary, not to dodge a crash.
    ///      (Separately, whisper.cpp:9000 has a real `WHISPER_ASSERT(n_frames
    ///      <= n_audio_ctx * 2)` that looks similar, but it only runs inside
    ///      `whisper_exp_compute_token_level_timestamps_dtw`, gated behind
    ///      `dtw_token_timestamps`/`dtw_aheads_preset` — both left at their
    ///      default-off values here, so that assert is not reachable via
    ///      this code path today. If DTW token timestamps are ever enabled,
    ///      this margin should be re-validated against that assert
    ///      specifically, since it hasn't been exercised against it.)
    /// This sizing is ONLY safe to apply when the language is being
    /// explicitly forced (non-nil, non-"auto", non-empty `languageCode`,
    /// resolved either from an explicit user selection or from the
    /// keyboard-layout signal in KeyboardLanguage.swift) — trimming the
    /// context while asking whisper to auto-detect the language itself was
    /// found to silently mistranslate/garble non-English audio into English
    /// on real hardware.
    static func audioContextFrames(forSampleCount sampleCount: Int, modelMaxAudioCtx: Int32) -> Int32 {
        let framesPerSecond = 50.0 // 1500 frames / 30s
        // WHISPER_SAMPLE_RATE (whisper.h:33) is a simple integer #define and
        // is bridged into Swift by the Clang importer, so it's usable directly.
        let durationSeconds = Double(sampleCount) / Double(WHISPER_SAMPLE_RATE)
        // Generous margin: double the naive requirement, to keep real usage
        // (which relies on an estimated/rounded duration) far from the point
        // where the encoder's mel-window clamp would start silently cutting
        // off trailing audio — see the constraint (2) note above.
        let neededFrames = Int32((durationSeconds * framesPerSecond * 2.0).rounded(.up))
        return min(modelMaxAudioCtx, max(neededFrames, 256))
    }

    /// A `static` (hence non-actor-isolated) helper so the `withUnsafeBufferPointer`
    /// closure below isn't treated as capturing actor-isolated state — under Swift 6
    /// strict concurrency, a closure defined inside an actor-isolated instance method
    /// that captures a `whisper_full_params` value is flagged as "sending" a
    /// non-Sendable value across isolation even though the closure is synchronous
    /// and non-escaping. Moving the call into a plain (non-isolated) static function
    /// sidesteps that false positive; `context` stays safe to read here because it
    /// is `nonisolated(unsafe)` and, per the actor's own contract, never mutated
    /// after `init` and never called concurrently (see the doc comment above this
    /// actor and above `TranscriptionWorker` in main.swift).
    private static func runWhisperFull(context: OpaquePointer,
                                       params: whisper_full_params,
                                       samples: [Float]) -> Int32 {
        samples.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
        }
    }
}
