// SuperDictate's C bridge implementation over parakeet.cpp's own C-API
// (upstream/include/parakeet_capi.h). Hand-authored, not vendored — never
// touched by scripts/vendor-parakeet-cpp.sh.
//
// Every entry point catches all C++ exceptions before returning through the
// C ABI (parakeet_capi_* itself already does this internally too, per its
// own header doc comments — this is defense in depth, not a substitute).

#include "superdictate_parakeet.h"
#include "parakeet_capi.h"
#include "parakeet.h"
#include "ggml_graph.hpp" // pk::set_num_threads — process-global thread override,
                           // same mechanism examples/cli uses (see PROVENANCE.md).

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <new>
#include <string>
#include <vector>

struct SDParakeetContext {
    parakeet_ctx *native = nullptr;
    SDParakeetDevice device = SD_PARAKEET_DEVICE_CPU;
    std::atomic<bool> busy{false};
    std::string last_error;
};

namespace {

// Default policy from docs/parakeet-intel-backend.md §10:
// max(2, min(8, activeProcessorCount / 2)). The Swift side
// (ParakeetEngine.init) already computes this using
// ProcessInfo.processInfo.activeProcessorCount and passes it down via
// SDParakeetOptions.num_threads; this fallback only applies if a caller
// passes num_threads <= 0 or a NULL options struct (defensive — every
// current Swift call site does pass an explicit positive value).
int32_t clampThreadCount(int32_t requested) {
    if (requested > 0) {
        return requested;
    }
    return 8; // matches parakeet.cpp's own kDefaultThreads (examples/cli).
}

char *dupUTF8(const std::string &s) {
    char *buf = static_cast<char *>(std::malloc(s.size() + 1));
    if (!buf) return nullptr;
    std::memcpy(buf, s.data(), s.size());
    buf[s.size()] = '\0';
    return buf;
}

} // namespace

extern "C" SDParakeetStatus sd_parakeet_create(
    const char *model_path,
    const SDParakeetOptions *options,
    SDParakeetContext **out_context
) {
    if (!out_context) return SD_PARAKEET_ERR_NULL_ARGUMENT;
    *out_context = nullptr;
    if (!model_path) return SD_PARAKEET_ERR_NULL_ARGUMENT;

    SDParakeetDevice device = options ? options->device : SD_PARAKEET_DEVICE_CPU;
    if (device == SD_PARAKEET_DEVICE_VULKAN) {
        // Vulkan is not vendored/compiled in this phase (see
        // scripts/vendor-parakeet-cpp.sh's header comment and Package.swift —
        // no PARAKEET_GGML_VULKAN sources are part of this target yet).
        // Fail fast and explicitly rather than silently running on CPU while
        // claiming Vulkan, per the "never report Vulkan success merely
        // because the caller asked" bridge requirement.
        return SD_PARAKEET_ERR_VULKAN_UNAVAILABLE;
    }

    try {
        int32_t threads = clampThreadCount(options ? options->num_threads : 0);
        pk::set_num_threads(threads);

        parakeet_ctx *native = parakeet_capi_load(model_path);
        if (!native) {
            return SD_PARAKEET_ERR_MODEL_LOAD_FAILED;
        }

        auto *ctx = new (std::nothrow) SDParakeetContext();
        if (!ctx) {
            parakeet_capi_free(native);
            return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
        }
        ctx->native = native;
        ctx->device = SD_PARAKEET_DEVICE_CPU;
        *out_context = ctx;
        return SD_PARAKEET_OK;
    } catch (...) {
        return SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }
}

extern "C" SDParakeetStatus sd_parakeet_warm_up(SDParakeetContext *context) {
    if (!context || !context->native) return SD_PARAKEET_ERR_NULL_ARGUMENT;

    bool expected = false;
    if (!context->busy.compare_exchange_strong(expected, true)) {
        return SD_PARAKEET_ERR_BUSY;
    }

    SDParakeetStatus status = SD_PARAKEET_OK;
    try {
        // A short (0.5s) synthetic silence buffer at 16 kHz — enough to
        // exercise the real mel front end + encoder + decoder graph paths
        // once (forcing allocator/thread-pool warm paths) without a real
        // recording. An empty/near-empty transcript is expected and NOT an
        // error (spec §11.3): parakeet.cpp legitimately returns "" for
        // silence.
        std::vector<float> silence(8000, 0.0f);
        char *text = parakeet_capi_transcribe_pcm(
            context->native, silence.data(),
            static_cast<int>(silence.size()), 16000, /*decoder=*/0
        );
        if (!text) {
            context->last_error = parakeet_capi_last_error(context->native);
            status = SD_PARAKEET_ERR_INFERENCE_FAILED;
        } else {
            parakeet_capi_free_string(text);
        }
    } catch (...) {
        context->last_error = "native exception during warm-up";
        status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }

    context->busy.store(false);
    return status;
}

extern "C" SDParakeetStatus sd_parakeet_transcribe(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetResult *out_result
) {
    if (!out_result) return SD_PARAKEET_ERR_NULL_ARGUMENT;
    out_result->text = nullptr;
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
    // parakeet_capi_transcribe_pcm takes `int n_samples` — guard the
    // narrowing conversion explicitly rather than relying on silent
    // truncation for pathological inputs (also unreachable in practice given
    // the duration cap above, but validated defensively per the bridge
    // requirements: "validate sample count and integer conversions").
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
        char *text = parakeet_capi_transcribe_pcm(
            context->native, samples, static_cast<int>(sample_count),
            static_cast<int>(sample_rate), /*decoder=*/0
        );
        auto finished = std::chrono::steady_clock::now();
        double seconds = std::chrono::duration<double>(finished - started).count();

        if (!text) {
            context->last_error = parakeet_capi_last_error(context->native);
            status = SD_PARAKEET_ERR_INFERENCE_FAILED;
        } else {
            out_result->text = dupUTF8(std::string(text));
            parakeet_capi_free_string(text);
            if (!out_result->text) {
                status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
            } else {
                out_result->total_seconds = seconds;
                out_result->inference_seconds = seconds;
                out_result->used_gpu = 0;
            }
        }
    } catch (...) {
        context->last_error = "native exception during transcription";
        status = SD_PARAKEET_ERR_NATIVE_EXCEPTION;
    }

    context->busy.store(false);
    return status;
}

extern "C" void sd_parakeet_result_destroy(SDParakeetResult *result) {
    if (!result) return;
    if (result->text) {
        std::free(result->text);
        result->text = nullptr;
    }
}

extern "C" void sd_parakeet_destroy(SDParakeetContext *context) {
    if (!context) return;
    if (context->native) {
        parakeet_capi_free(context->native);
    }
    delete context;
}

extern "C" SDParakeetDevice sd_parakeet_backend_device(const SDParakeetContext *context) {
    if (!context) return SD_PARAKEET_DEVICE_CPU;
    return context->device;
}

extern "C" const char *sd_parakeet_last_error_message(const SDParakeetContext *context) {
    if (!context) return "";
    return context->last_error.c_str();
}

extern "C" const char *sd_parakeet_runtime_version(void) {
    return parakeet_version();
}
