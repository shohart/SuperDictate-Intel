import Foundation
import parakeet_cpp

/// `.vulkan` requests parakeet.cpp's ggml Vulkan/MoltenVK backend (Phase 5).
/// Requesting it does NOT guarantee it's what actually ends up running:
/// `ParakeetEngine.init` calls `sd_parakeet_vulkan_available()` (a
/// side-effect-free probe of ggml's own device registry) before even
/// attempting a load, and `warmUp()` performs the mandatory post-init check
/// (parakeet.cpp's own actual selected device name must start with
/// "Vulkan") — either failing means `ParakeetEngineError.vulkanUnavailable`
/// / `.vulkanFellBackToCPU`, never a silent CPU run reported as GPU success.
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
    /// Distinct from `.vulkanUnavailable` (no device registered at all):
    /// this means a Vulkan device WAS enumerated and requested, but
    /// parakeet.cpp's own post-init check (bridge `sd_parakeet_warm_up`)
    /// found the actual selected backend was CPU anyway — upstream's own
    /// silent-fallback behavior, turned into a hard typed error here per
    /// the "never report Vulkan success merely because it was requested"
    /// contract.
    case vulkanFellBackToCPU(String)
    case warmUpFailed(String)
    case inferenceFailed(String)
    case tokenDecodeFailed(String)
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
        case .vulkanFellBackToCPU(let detail):
            return "Vulkan was requested but the native runtime silently selected CPU: \(detail)"
        case .warmUpFailed(let detail):
            return "Parakeet warm-up failed: \(detail)"
        case .inferenceFailed(let detail):
            return "Parakeet transcription failed: \(detail)"
        case .tokenDecodeFailed(let detail):
            return "Failed to decode token timestamps: \(detail)"
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

/// Side-effect-free capability probe (spec §11.2): does ggml's OWN backend
/// device registry currently enumerate a usable GPU/IGPU device? Safe to
/// call before any model is loaded — does not construct parakeet.cpp's
/// process-global compute backend, does not touch IOKit. Drives the
/// settings checkbox's enabled/disabled state.
func parakeetVulkanAvailable() -> Bool {
    sd_parakeet_vulkan_available() != 0
}

/// Human-readable description of the first enumerated GPU/IGPU device
/// (e.g. "AMD Radeon RX 6600 (MoltenVK)"), or "" if none is available.
func parakeetVulkanDeviceDescription() -> String {
    String(cString: sd_parakeet_vulkan_device_description())
}

/// Points the vendored ggml-vulkan runtime SPIR-V loader
/// (ggml_vk_shaders_set_directory, declared in
/// ggml-vulkan-shaders-runtime.h and reachable via the parakeet_cpp
/// umbrella header) at `Contents/Resources/vulkan-shaders` in the current
/// app bundle, IF that directory actually exists — safe to call more than
/// once (the most recent call wins) and a correctly-behaved no-op in a
/// `swift run`/`swift build` dev build with no `.app` bundle yet (the C++
/// loader's own source-relative fallback finds the real corpus at
/// swift/Sources/parakeet_cpp/upstream/ggml-vulkan/vulkan-shaders/ in that
/// case — see ggml-vulkan-shaders-runtime.cpp). MUST be called before the
/// first Vulkan pipeline is created (i.e. before any inference on a
/// `.vulkan`-device context) or every shader symbol silently resolves to
/// null/zero-length.
private func configureVulkanShaderDirectoryIfPresent() {
    guard let resourceURL = Bundle.main.resourceURL else { return }
    let shaderDir = resourceURL.appendingPathComponent("vulkan-shaders", isDirectory: true)
    guard FileManager.default.fileExists(atPath: shaderDir.path) else { return }
    shaderDir.path.withCString { ggml_vk_shaders_set_directory($0) }
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
    /// Actual selected device name from parakeet.cpp's own backend registry
    /// (e.g. "cpu", "Vulkan0"), filled in by `warmUp()`. Empty until then.
    private(set) var actualDeviceName: String = ""

    /// `threadCount` should already be resolved by the caller using the
    /// policy in docs/parakeet-intel-backend.md §10:
    /// `max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))`,
    /// with an optional `SUPERDICTATE_ASR_THREADS` override (validated to
    /// `1...32`) — see `TranscriptionWorker.resolvedParakeetThreadCount()`.
    ///
    /// A `.vulkan` request that succeeds here is NOT yet proven to actually
    /// be running on Vulkan — parakeet.cpp's own compute backend is
    /// constructed lazily on the first inference (see the bridge header's
    /// doc comments), not at load time. `warmUp()` is what forces that
    /// construction and performs the mandatory post-init device check;
    /// callers MUST call `warmUp()` before treating a `.vulkan` engine as
    /// usable.
    init(modelPath: String, device: ParakeetDevice = .cpu, threadCount: Int) throws {
        if device == .vulkan {
            // Cheap, side-effect-free registry probe: fail fast (without
            // even attempting a model load) if no Vulkan device is
            // enumerated at all (CPU-only build, or no usable GPU on this
            // machine). This mirrors the bridge's own early-out in
            // sd_parakeet_create, kept here too so the error surfaces
            // before any file-existence/model-load work.
            guard parakeetVulkanAvailable() else {
                throw ParakeetEngineError.vulkanUnavailable
            }
            // Must happen before parakeet.cpp's backend (and therefore
            // ggml-vulkan's shader pipeline) is ever constructed — see
            // ggml_vk_shaders_set_directory's doc comment. Guarded by an
            // existence check (not an unconditional call): this fork hit a
            // real regression once already for whisper.cpp where an
            // unconditional call broke the C++ loader's own dev-build
            // source-relative fallback when Contents/Resources/vulkan-shaders
            // didn't exist yet (every shader failed to load, ~37s Vulkan
            // init instead of ~2s) — only override the directory when a real
            // bundled corpus is actually there.
            configureVulkanShaderDirectoryIfPresent()
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw ParakeetEngineError.modelNotFound(path: modelPath)
        }

        let nativeDevice: SDParakeetDevice = device == .vulkan ? SD_PARAKEET_DEVICE_VULKAN : SD_PARAKEET_DEVICE_CPU
        var options = SDParakeetOptions(device: nativeDevice, num_threads: Int32(threadCount))
        var outContext: OpaquePointer?
        let status = withUnsafePointer(to: &options) { optionsPtr in
            modelPath.withCString { pathPtr in
                sd_parakeet_create(pathPtr, optionsPtr, &outContext)
            }
        }
        if status == SD_PARAKEET_ERR_VULKAN_UNAVAILABLE {
            throw ParakeetEngineError.vulkanUnavailable
        }
        guard status == SD_PARAKEET_OK, let created = outContext else {
            throw ParakeetEngineError.modelLoadFailed("bridge status \(status.rawValue)")
        }
        context = created
        self.device = device
    }

    /// Forces one-time native initialization AND, for `.vulkan` engines,
    /// performs the mandatory post-init device check (spec: never report
    /// Vulkan success merely because it was requested). Throws
    /// `.vulkanFellBackToCPU` — NOT a silent success — if parakeet.cpp's
    /// actual selected backend turned out to be CPU despite Vulkan being
    /// requested (upstream's own default fallback behavior). Callers MUST
    /// treat that as a hard failure: destroy this engine and construct a
    /// fresh `.cpu` one (see `TranscriptionWorker.load`).
    func warmUp() async throws {
        guard let context else {
            throw ParakeetEngineError.warmUpFailed("engine already shut down")
        }
        let status = sd_parakeet_warm_up(context)
        actualDeviceName = String(cString: sd_parakeet_backend_device_name(context))
        if status == SD_PARAKEET_ERR_VULKAN_UNAVAILABLE {
            let message = String(cString: sd_parakeet_last_error_message(context))
            throw ParakeetEngineError.vulkanFellBackToCPU(message)
        }
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

    /// Like `transcribe`, but returns per-token timestamps + confidence as JSON,
    /// decoded into a `TokenTranscription` struct. `samples` must be non-empty
    /// mono Float32 PCM at `sampleRate` Hz (16 kHz throughout this app's capture
    /// pipeline; parakeet.cpp resamples internally if it ever isn't).
    func transcribeWithTokens(samples: [Float], sampleRate: UInt32 = UInt32(SAMPLE_RATE)) throws -> TokenTranscription {
        guard !samples.isEmpty else {
            throw ParakeetEngineError.emptyAudio
        }
        guard let context else {
            throw ParakeetEngineError.inferenceFailed("engine already shut down")
        }

        var result = SDParakeetTokenResult(json: nil, total_seconds: 0, inference_seconds: 0, used_gpu: 0)
        let status = samples.withUnsafeBufferPointer { buffer -> SDParakeetStatus in
            sd_parakeet_transcribe_with_tokens(context, buffer.baseAddress, UInt64(buffer.count), sampleRate, &result)
        }
        defer { sd_parakeet_token_result_destroy(&result) }

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

        guard let jsonPointer = result.json else {
            throw ParakeetEngineError.inferenceFailed("native call succeeded but returned no JSON")
        }
        guard let jsonString = String(validatingCString: jsonPointer) else {
            throw ParakeetEngineError.invalidUTF8
        }

        do {
            return try decodeTokenTranscription(json: jsonString)
        } catch let error as TokenTranscriptionDecodeError {
            switch error {
            case .emptyArray:
                throw ParakeetEngineError.tokenDecodeFailed("JSON response contained empty clips array")
            case .malformedJSON(let underlying):
                throw ParakeetEngineError.tokenDecodeFailed("JSON decode failed: \(underlying.localizedDescription)")
            }
        } catch {
            throw ParakeetEngineError.tokenDecodeFailed("JSON decode failed: \(error.localizedDescription)")
        }
    }

    /// Actual runtime backend, for diagnostics/UI (spec §11.4). Reflects
    /// `actualDeviceName` (set by `warmUp()`), not just the requested
    /// `device` — an engine constructed with `device == .vulkan` whose
    /// warm-up hasn't run yet (or that never got past construction) has no
    /// actual device to report. Callers that need the exact GPU model name
    /// for a status string like "Vulkan — AMD Radeon RX 6600" should pair
    /// this with `parakeetVulkanDeviceDescription()`.
    func backendDescription() -> String {
        actualDeviceName.isEmpty ? (device == .cpu ? "CPU" : "unknown") : actualDeviceName
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
