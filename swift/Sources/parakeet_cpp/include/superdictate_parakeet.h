#ifndef SUPERDICTATE_PARAKEET_H
#define SUPERDICTATE_PARAKEET_H

// SuperDictate's own thin C bridge over parakeet.cpp's real, already
// flat/exception-free C-API (upstream/include/parakeet_capi.h). This is NOT
// a from-scratch reinvention of that ABI — parakeet.cpp's own
// `parakeet_capi_*` functions already provide load-once, PCM-in/UTF-8-out,
// exception-free semantics equivalent to what docs/parakeet-intel-backend.md
// §7 originally sketched as an aspirational `SDParakeet*` surface (written
// before this had been confirmed). This header exists only to:
//   - give SuperDictate-specific, stable names Swift imports via the
//     `parakeet_cpp` module (kept separate from upstream's own headers, which
//     are not exported through the module map — see include/module.modulemap);
//   - add the one piece upstream's C-API does not expose: per-call thread
//     count and coarse timing breakdown, plus an explicit CPU/Vulkan device
//     enum for forward-compatibility with Phase 5 (Vulkan is not implemented
//     yet in this phase; requesting SD_PARAKEET_DEVICE_VULKAN today fails
//     context creation with SD_PARAKEET_VULKAN_UNAVAILABLE).
//   - guarantee single-flight (no concurrent inference on one context) at
//     the C level in addition to whatever Swift-side actor isolation exists.
//
// All functions are extern "C", never let a C++ exception cross the ABI
// boundary (every entry point in bridge/superdictate_parakeet.cpp is wrapped
// in try/catch(...)), and return a stable numeric status code.

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

typedef enum {
    SD_PARAKEET_OK = 0,
    SD_PARAKEET_ERR_NULL_ARGUMENT = 1,
    SD_PARAKEET_ERR_MODEL_LOAD_FAILED = 2,
    SD_PARAKEET_ERR_EMPTY_AUDIO = 3,
    SD_PARAKEET_ERR_AUDIO_TOO_LONG = 4,
    SD_PARAKEET_ERR_INFERENCE_FAILED = 5,
    SD_PARAKEET_ERR_INVALID_UTF8 = 6,
    SD_PARAKEET_ERR_BUSY = 7,
    SD_PARAKEET_ERR_VULKAN_UNAVAILABLE = 8,
    SD_PARAKEET_ERR_NATIVE_EXCEPTION = 9
} SDParakeetStatus;

typedef struct {
    SDParakeetDevice device;
    int32_t num_threads; // <= 0 means "use the bridge's own default policy"
} SDParakeetOptions;

typedef struct {
    char *text;              // malloc'd UTF-8, owned by caller; NULL on failure
    double total_seconds;
    double inference_seconds; // native parakeet_capi_transcribe_pcm() wall time
    int32_t used_gpu;         // always 0 in this phase (CPU-only)
} SDParakeetResult;

// Loads a GGUF model once and returns an owning context, or NULL on failure
// (see sd_parakeet_last_error_message for the reason). `options` may be NULL
// to use CPU with the bridge's default thread policy.
SDParakeetStatus sd_parakeet_create(
    const char *model_path,
    const SDParakeetOptions *options,
    SDParakeetContext **out_context
);

// Runs a short synthetic-silence inference to force one-time initialization
// (thread pool spin-up, first-call allocator warm paths) before real
// dictation. Never produces a transcript history item; an empty/near-empty
// result is not an error.
SDParakeetStatus sd_parakeet_warm_up(SDParakeetContext *context);

// Transcribes mono Float32 PCM at `sample_rate` Hz (resampled internally by
// parakeet.cpp if not already 16 kHz). Rejects `sample_count == 0` and
// enforces a maximum duration (see SD_PARAKEET_MAX_AUDIO_SECONDS below).
// Blocks concurrent calls on the same context (SD_PARAKEET_ERR_BUSY).
SDParakeetStatus sd_parakeet_transcribe(
    SDParakeetContext *context,
    const float *samples,
    uint64_t sample_count,
    uint32_t sample_rate,
    SDParakeetResult *out_result
);

// The application's own enforced ceiling on a single dictation's audio
// duration (independent of whatever limit, if any, upstream enforces) —
// mirrors the "enforce the application's maximum recording duration" bridge
// requirement. 20 minutes: generous relative to real dictation usage, tight
// enough to bound worst-case memory/latency from a runaway capture.
#define SD_PARAKEET_MAX_AUDIO_SECONDS 1200.0

void sd_parakeet_result_destroy(SDParakeetResult *result);
void sd_parakeet_destroy(SDParakeetContext *context);

// Actual selected backend/device, valid only after a successful
// sd_parakeet_create. Diagnostic-only, not a promise of upstream behavior.
SDParakeetDevice sd_parakeet_backend_device(const SDParakeetContext *context);

// Last error message for `context`, or "" if none / context is NULL. Owned
// by the context; valid until the next call on it or until
// sd_parakeet_destroy.
const char *sd_parakeet_last_error_message(const SDParakeetContext *context);

// parakeet.cpp's own version string (e.g. "0.0.1"). Never NULL.
const char *sd_parakeet_runtime_version(void);

#ifdef __cplusplus
}
#endif

#endif // SUPERDICTATE_PARAKEET_H
