// SuperDictate's C bridge implementation over Task 1's vendored Silero VAD
// implementation (upstream-vad/whisper_vad.cpp, extracted from
// ggml-org/whisper.cpp — see upstream-vad/PROVENANCE.md). Hand-authored,
// not vendored — never touched by scripts/vendor-silero-vad.sh.
//
// Every entry point catches all C++ exceptions before returning through
// the C ABI, mirroring superdictate_parakeet.cpp's own pattern exactly.

#include "superdictate_silero_vad.h"
#include "whisper_vad.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>
#include <vector>

struct SDSileroVadContext {
    whisper_vad_context *native = nullptr;
    // Determined once at create-time by probing the loaded model (see
    // probeWindowSizeSamples below) — upstream's public header does not
    // expose whisper_vad_context's internal n_window field directly.
    uint64_t window_size_samples = 0;
    std::string last_error;
};

namespace {

// whisper_vad_detect_speech's own internal chunking (whisper_vad.cpp,
// whisper_vad_detect_speech_no_reset) computes:
//   n_chunks = n_samples / n_window; if (n_samples % n_window != 0) n_chunks++;
// i.e. n_chunks == ceil(n_samples / n_window). That means, as a function of
// n_samples, whisper_vad_n_probs() (== n_chunks) is 1 for every
// 1 <= n_samples <= n_window, and first becomes 2 exactly at
// n_samples == n_window + 1. This probe finds that exact transition point
// via bounded doubling + binary search, using only whisper_vad_detect_speech
// (which resets LSTM state before each call — see whisper_vad.cpp — so
// probing does not leave the context in a dirty streaming state), then
// returns n_window == (transition point - 1).
//
// This is a handful of tiny synthetic-buffer inferences against the real,
// already-loaded model (cheap — Silero VAD is a very small network) done
// once at sd_silero_vad_create time; it is not on any per-utterance hot
// path.
//
// Returns 0 if the probe fails to find a transition within the bound
// (should not happen for any real Silero VAD model; window sizes are on
// the order of hundreds of samples, far under the cap below) — callers
// treat 0 as "unknown", not a hard error, since out_window_size_samples is
// documented as best-effort diagnostic/convenience metadata, not something
// whose absence should block a real probabilities call.
uint64_t probeWindowSizeSamples(whisper_vad_context *native) {
    constexpr int kCap = 1 << 20; // ~64s at 16kHz; far above any real window size.

    auto probsAt = [&](int n) -> int {
        std::vector<float> buf(static_cast<size_t>(n), 0.0f);
        if (!whisper_vad_detect_speech(native, buf.data(), n)) {
            return -1;
        }
        return whisper_vad_n_probs(native);
    };

    // n_samples == 1 must yield exactly 1 chunk for any n_window >= 1.
    if (probsAt(1) != 1) {
        return 0;
    }

    // Doubling search for an upper bound where n_probs >= 2.
    int lo = 1;   // known: probsAt(lo) == 1
    int hi = 2;
    while (hi < kCap) {
        int p = probsAt(hi);
        if (p < 0) return 0;
        if (p >= 2) break;
        lo = hi;
        hi *= 2;
    }
    if (hi >= kCap) {
        return 0;
    }

    // Binary search the exact boundary: largest n with n_probs(n) == 1.
    while (hi - lo > 1) {
        int mid = lo + (hi - lo) / 2;
        int p = probsAt(mid);
        if (p < 0) return 0;
        if (p == 1) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    // lo is the largest n_samples with exactly 1 chunk, i.e. lo == n_window.
    return static_cast<uint64_t>(lo);
}

} // namespace

extern "C" SDSileroVadStatus sd_silero_vad_create(
    const char *model_path,
    SDSileroVadContext **out_context
) {
    if (!out_context) return SD_SILERO_VAD_ERR_NULL_ARGUMENT;
    *out_context = nullptr;
    if (!model_path) return SD_SILERO_VAD_ERR_NULL_ARGUMENT;

    try {
        whisper_vad_context_params params = whisper_vad_default_context_params();
        whisper_vad_context *native = whisper_vad_init_from_file_with_params(model_path, params);
        if (!native) {
            return SD_SILERO_VAD_ERR_MODEL_LOAD_FAILED;
        }

        auto *ctx = new (std::nothrow) SDSileroVadContext();
        if (!ctx) {
            whisper_vad_free(native);
            return SD_SILERO_VAD_ERR_NATIVE_EXCEPTION;
        }
        ctx->native = native;
        ctx->window_size_samples = probeWindowSizeSamples(native);

        *out_context = ctx;
        return SD_SILERO_VAD_OK;
    } catch (...) {
        return SD_SILERO_VAD_ERR_NATIVE_EXCEPTION;
    }
}

extern "C" SDSileroVadStatus sd_silero_vad_speech_probabilities(
    SDSileroVadContext *context,
    const float *samples,
    uint64_t sample_count,
    float **out_probabilities,
    uint64_t *out_count,
    uint64_t *out_window_size_samples
) {
    if (out_probabilities) *out_probabilities = nullptr;
    if (out_count) *out_count = 0;
    if (out_window_size_samples) *out_window_size_samples = 0;

    if (!context || !context->native || !samples || !out_probabilities || !out_count) {
        return SD_SILERO_VAD_ERR_NULL_ARGUMENT;
    }
    if (sample_count == 0) {
        return SD_SILERO_VAD_ERR_EMPTY_AUDIO;
    }
    // whisper_vad_detect_speech takes `int n_samples` — guard the narrowing
    // conversion explicitly rather than relying on silent truncation for
    // pathological inputs (same defensive pattern as
    // sd_parakeet_transcribe's sample_count > INT32_MAX guard).
    if (sample_count > static_cast<uint64_t>(INT32_MAX)) {
        context->last_error = "sample_count exceeds INT32_MAX";
        return SD_SILERO_VAD_ERR_INFERENCE_FAILED;
    }

    SDSileroVadStatus status = SD_SILERO_VAD_OK;
    try {
        bool ok = whisper_vad_detect_speech(
            context->native, samples, static_cast<int>(sample_count)
        );
        if (!ok) {
            context->last_error = "whisper_vad_detect_speech failed";
            return SD_SILERO_VAD_ERR_INFERENCE_FAILED;
        }

        int n_probs = whisper_vad_n_probs(context->native);
        float *probs = whisper_vad_probs(context->native);
        if (n_probs < 0 || (n_probs > 0 && !probs)) {
            context->last_error = "whisper_vad_probs returned an inconsistent result";
            return SD_SILERO_VAD_ERR_INFERENCE_FAILED;
        }

        uint64_t count = static_cast<uint64_t>(n_probs);
        float *out = nullptr;
        if (count > 0) {
            out = static_cast<float *>(std::malloc(count * sizeof(float)));
            if (!out) {
                context->last_error = "allocation failed for output probabilities";
                return SD_SILERO_VAD_ERR_NATIVE_EXCEPTION;
            }
            std::memcpy(out, probs, count * sizeof(float));
        }

        *out_probabilities = out;
        *out_count = count;
        if (out_window_size_samples) {
            *out_window_size_samples = context->window_size_samples;
        }
        status = SD_SILERO_VAD_OK;
    } catch (...) {
        context->last_error = "native exception during VAD inference";
        status = SD_SILERO_VAD_ERR_NATIVE_EXCEPTION;
    }

    return status;
}

extern "C" void sd_silero_vad_free_probabilities(float *probabilities) {
    if (!probabilities) return;
    std::free(probabilities);
}

extern "C" void sd_silero_vad_destroy(SDSileroVadContext *context) {
    if (!context) return;
    if (context->native) {
        whisper_vad_free(context->native);
    }
    delete context;
}

extern "C" const char *sd_silero_vad_last_error_message(const SDSileroVadContext *context) {
    if (!context) return "";
    return context->last_error.c_str();
}
