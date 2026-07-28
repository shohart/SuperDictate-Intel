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
    int32_t used_gpu;         // 1 iff this context's actual selected backend is Vulkan
} SDParakeetResult;

// Loads a GGUF model once and returns an owning context, or NULL on failure
// (see sd_parakeet_last_error_message for the reason). `options` may be NULL
// to use CPU with the bridge's default thread policy.
//
// Device selection itself does not happen here — parakeet.cpp's own
// pk::Backend is constructed lazily on the FIRST graph compute (not at
// model load), driven by the process-global PARAKEET_DEVICE environment
// variable (see upstream/backend.cpp). This function stashes the requested
// device on the context and sets that environment variable so the backend
// that gets lazily constructed during the next call (normally
// sd_parakeet_warm_up) is the one requested. It does NOT by itself prove
// Vulkan was actually selected — see sd_parakeet_warm_up, which forces
// backend construction and performs the real post-init check.
SDParakeetStatus sd_parakeet_create(
    const char *model_path,
    const SDParakeetOptions *options,
    SDParakeetContext **out_context
);

// Runs a short synthetic-silence inference to force one-time initialization
// (thread pool spin-up, first-call allocator warm paths, and — the first
// time any context in this process performs an inference — construction of
// parakeet.cpp's process-global compute backend) before real dictation.
// Never produces a transcript history item; an empty/near-empty result is
// not an error.
//
// If this context requested SD_PARAKEET_DEVICE_VULKAN, this call ALSO
// performs the mandatory post-init device check (spec section on GPU
// checkbox behavior / do not report Vulkan success merely because it was
// requested): it inspects parakeet.cpp's actual selected compute device
// name and, if it does not start with "Vulkan" (case-insensitive) —
// i.e. upstream silently fell back to CPU, which is upstream's own default
// behavior when a requested device isn't found — this call resets the
// process-global backend (so a subsequent CPU context in the SAME process
// can construct a fresh one) and returns SD_PARAKEET_ERR_VULKAN_UNAVAILABLE.
// The context must be destroyed by the caller in that case; it is not
// usable for CPU either (create a fresh CPU-device context instead).
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
// sd_parakeet_create + sd_parakeet_warm_up (before warm-up, this reflects
// only the REQUESTED device, since parakeet.cpp's backend has not been
// constructed yet — see sd_parakeet_create's doc comment). Diagnostic-only,
// not a promise of upstream behavior.
SDParakeetDevice sd_parakeet_backend_device(const SDParakeetContext *context);

// Actual selected device name from parakeet.cpp's own backend registry
// (e.g. "cpu", "Vulkan0"), valid only after a successful warm-up. Never
// NULL (empty string "" before warm-up runs, or if context is NULL).
// Human-readable device identity for spec 11.4-style runtime status
// strings ("Vulkan — AMD Radeon RX 6600") — pair this with
// sd_parakeet_vulkan_device_description() for the marketing/model name.
const char *sd_parakeet_backend_device_name(const SDParakeetContext *context);

// Capability probe: does ggml's OWN backend device registry (source of
// truth per the "never infer from IOKit alone" rule) currently enumerate at
// least one usable GPU/IGPU device? Side-effect-free relative to any model
// load — safe to call before any context exists (e.g. to decide whether
// the "Use GPU (Vulkan)" checkbox should be enabled), and does not
// construct parakeet.cpp's process-global compute backend. Returns 1 if at
// least one GGML_BACKEND_DEVICE_TYPE_GPU or _IGPU device is registered, 0
// otherwise (including CPU-only builds, where the Vulkan backend was never
// compiled in and therefore never registers any device).
int32_t sd_parakeet_vulkan_available(void);

// Human-readable name of the first enumerated GPU/IGPU device (e.g. "AMD
// Radeon RX 6600 (MoltenVK)"), or "" if sd_parakeet_vulkan_available()
// would return 0. Never NULL. Does not require a loaded context.
const char *sd_parakeet_vulkan_device_description(void);

// Last error message for `context`, or "" if none / context is NULL. Owned
// by the context; valid until the next call on it or until
// sd_parakeet_destroy.
const char *sd_parakeet_last_error_message(const SDParakeetContext *context);

// parakeet.cpp's own version string (e.g. "0.0.1"). Never NULL.
const char *sd_parakeet_runtime_version(void);

// Test-only: resets parakeet.cpp's process-global compute backend
// (pk::shutdown_backend()) so the NEXT context's first inference
// reconstructs it from whatever PARAKEET_DEVICE is set at that moment,
// instead of reusing an already-alive backend from an earlier context in
// the same process. Production code never needs this — sd_parakeet_warm_up
// already calls it internally on the one path where it matters (a
// detected Vulkan-fell-back-to-CPU failure). Exists so a self-test can
// exercise the forced-failure path deterministically after a prior
// sub-test already constructed a real, working backend in the same
// process (see the parakeet-vulkan self-test group).
void sd_parakeet_test_reset_backend(void);

#ifdef __cplusplus
}
#endif

#endif // SUPERDICTATE_PARAKEET_H
