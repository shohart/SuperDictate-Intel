import Foundation
import parakeet_cpp

/// CPU-only in this phase (Phase 3 of the parakeet.cpp migration plan) —
/// `.vulkan` exists so `ParakeetEngine.init` and the native bridge already
/// have a stable shape for Phase 5, but requesting it today fails
/// deterministically (`ParakeetEngineError.vulkanUnavailable`) rather than
/// silently running on CPU while claiming GPU use.
enum ParakeetDevice: Sendable {
    case cpu
    case vulkan
}

struct ParakeetTranscriptionResult: Sendable {
    let text: String
    let totalSeconds: Double
    let inferenceSeconds: Double
    let usedGPU: Bool
}

enum ParakeetEngineError: LocalizedError {
    case modelNotFound(path: String)
    case modelLoadFailed(String)
    case vulkanUnavailable
    case warmUpFailed(String)
    case inferenceFailed(String)
    case invalidUTF8
    case emptyAudio
    case busy
    case nativeBridgeFailure(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Parakeet model file not found at \(path)"
        case .modelLoadFailed(let detail):
            return "Failed to load Parakeet model: \(detail)"
        case .vulkanUnavailable:
            return "Vulkan GPU was not detected. Parakeet will use CPU."
        case .warmUpFailed(let detail):
            return "Parakeet warm-up failed: \(detail)"
        case .inferenceFailed(let detail):
            return "Parakeet transcription failed: \(detail)"
        case .invalidUTF8:
            return "Parakeet returned a transcript that was not valid UTF-8"
        case .emptyAudio:
            return "No audio samples to transcribe"
        case .busy:
            return "Parakeet is already transcribing"
        case .nativeBridgeFailure(let code, let message):
            return "Parakeet native bridge error \(code): \(message)"
        }
    }
}

/// Owns exactly one loaded parakeet.cpp context (`SDParakeetContext`, from
/// the `parakeet_cpp` SwiftPM target's C bridge — see
/// swift/Sources/parakeet_cpp/bridge/superdictate_parakeet.cpp). Mirrors
/// `WhisperEngine`'s actor-based single-context-per-instance shape (which
/// this type replaces): `TranscriptionWorker` (main.swift) is the single
/// caller and already serializes transcribe calls; the native bridge itself
/// additionally refuses concurrent inference on one context as a second,
/// independent guard (`SD_PARAKEET_ERR_BUSY`).
actor ParakeetEngine {
    // `OpaquePointer` doesn't conform to `Sendable`, which under Swift 6
    // strict concurrency would otherwise block reading this property from
    // `deinit` (always nonisolated) and from the C interop calls below.
    // Safety is still provided by the actor: `context` is only ever mutated
    // once (in `init`) and every other access is serialized through this
    // actor's isolation — `nonisolated(unsafe)` just tells the compiler
    // what's already true.
    // `var`, not `let`: `shutdown()` nils this out after freeing so a
    // subsequent `deinit` (or a defensive double-call to `shutdown()`)
    // cannot double-free the native context. Every other access happens
    // through this actor's isolation except `deinit`, which is always
    // nonisolated — safe here because by the time `deinit` runs there are
    // no other references to `self` left to race with it.
    private nonisolated(unsafe) var context: OpaquePointer?
    let device: ParakeetDevice

    /// `threadCount` should already be resolved by the caller using the
    /// policy in docs/parakeet-intel-backend.md §10:
    /// `max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))`,
    /// with an optional `SUPERDICTATE_ASR_THREADS` override (validated to
    /// `1...32`) — see `TranscriptionWorker.resolvedParakeetThreadCount()`.
    init(modelPath: String, device: ParakeetDevice = .cpu, threadCount: Int) throws {
        // Device check BEFORE the file-existence check: Vulkan
        // unavailability is a build/hardware-configuration fact independent
        // of whether a particular model path happens to exist, and should
        // be reported as such regardless of model path validity.
        guard device == .cpu else {
            // Vulkan is not vendored/compiled into the parakeet_cpp target
            // this phase (see scripts/vendor-parakeet-cpp.sh and
            // Package.swift — no PARAKEET_GGML_VULKAN sources yet). The
            // native bridge itself would also refuse this
            // (SD_PARAKEET_ERR_VULKAN_UNAVAILABLE), but failing here avoids
            // even calling down for a mode that can never succeed today.
            throw ParakeetEngineError.vulkanUnavailable
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ParakeetEngineError.modelNotFound(path: modelPath)
        }

        var options = SDParakeetOptions(device: SD_PARAKEET_DEVICE_CPU, num_threads: Int32(threadCount))
        var outContext: OpaquePointer?
        let status = withUnsafePointer(to: &options) { optionsPtr in
            modelPath.withCString { pathPtr in
                sd_parakeet_create(pathPtr, optionsPtr, &outContext)
            }
        }
        guard status == SD_PARAKEET_OK, let created = outContext else {
            throw ParakeetEngineError.modelLoadFailed("bridge status \(status.rawValue)")
        }
        context = created
        self.device = .cpu
    }

    func warmUp() async throws {
        guard let context else {
            throw ParakeetEngineError.warmUpFailed("engine already shut down")
        }
        let status = sd_parakeet_warm_up(context)
        guard status == SD_PARAKEET_OK else {
            throw ParakeetEngineError.warmUpFailed("bridge status \(status.rawValue)")
        }
    }

    /// `samples` must be non-empty mono Float32 PCM at `sampleRate` Hz
    /// (16 kHz throughout this app's capture pipeline; parakeet.cpp
    /// resamples internally if it ever isn't).
    func transcribe(samples: [Float], sampleRate: UInt32 = UInt32(SAMPLE_RATE)) throws -> ParakeetTranscriptionResult {
        guard !samples.isEmpty else {
            throw ParakeetEngineError.emptyAudio
        }
        guard let context else {
            throw ParakeetEngineError.inferenceFailed("engine already shut down")
        }

        var result = SDParakeetResult(text: nil, total_seconds: 0, inference_seconds: 0, used_gpu: 0)
        let status = samples.withUnsafeBufferPointer { buffer -> SDParakeetStatus in
            sd_parakeet_transcribe(context, buffer.baseAddress, UInt64(buffer.count), sampleRate, &result)
        }
        defer { sd_parakeet_result_destroy(&result) }

        switch status {
        case SD_PARAKEET_OK:
            break
        case SD_PARAKEET_ERR_EMPTY_AUDIO:
            throw ParakeetEngineError.emptyAudio
        case SD_PARAKEET_ERR_BUSY:
            throw ParakeetEngineError.busy
        default:
            let message = String(cString: sd_parakeet_last_error_message(context))
            throw ParakeetEngineError.inferenceFailed(message.isEmpty ? "bridge status \(status.rawValue)" : message)
        }

        guard let textPointer = result.text else {
            throw ParakeetEngineError.inferenceFailed("native call succeeded but returned no text")
        }
        guard let text = String(validatingCString: textPointer) else {
            throw ParakeetEngineError.invalidUTF8
        }

        return ParakeetTranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            totalSeconds: result.total_seconds,
            inferenceSeconds: result.inference_seconds,
            usedGPU: result.used_gpu != 0
        )
    }

    /// Actual runtime backend, for diagnostics/UI (spec §11.4). CPU-only in
    /// this phase, so always `.cpu` — kept as a method (not just the stored
    /// `device` property) so Phase 5 can make this reflect a real fallback
    /// decision without changing the call sites.
    nonisolated func backendDescription() -> String {
        device == .cpu ? "CPU" : "Vulkan"
    }

    /// Deterministic shutdown — the normal path, called from
    /// `TranscriptionWorker.unload()`. Safe to call more than once (a no-op
    /// after the first call) and safe to have `deinit` also reach, since
    /// both go through `destroy(context:)`, which nils the stored pointer
    /// before freeing it.
    func shutdown() {
        Self.destroy(context: &context)
    }

    deinit {
        // Backstop: if an engine is ever dropped without an explicit
        // `unload()`/`shutdown()` call, this still releases native memory
        // deterministically — matches WhisperEngine's
        // `deinit { whisper_free(context) }` precedent. Not a double-free
        // when `shutdown()` already ran: `context` is nil by then, and
        // `destroy(context:)` treats nil as already-freed.
        Self.destroy(context: &context)
    }

    private static func destroy(context: inout OpaquePointer?) {
        guard let toFree = context else { return }
        context = nil
        sd_parakeet_destroy(toFree)
    }
}

/// parakeet.cpp's own version string (e.g. "0.0.1"), for the startup log
/// line "ASR runtime: parakeet.cpp <version>" (spec §16).
func parakeetRuntimeVersion() -> String {
    String(cString: sd_parakeet_runtime_version())
}
