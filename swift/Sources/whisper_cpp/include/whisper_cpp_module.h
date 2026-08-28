// Umbrella header for the whisper_cpp SwiftPM target.
//
// This intentionally only pulls in the C headers whisper.cpp/ggml
// actually need to be *called* from Swift (Task 3's WhisperEngine).
// It deliberately does NOT include ggml-cpp.h (C++-only, std::unique_ptr,
// would fail import as C), nor ggml-vulkan.h/ggml-metal.h/ggml-cuda.h/etc
// themselves — this project always selects its GPU backend implicitly via
// whisper_context_params.use_gpu (whisper_backend_init_gpu picks whichever
// GPU-type device is registered; see WhisperEngine.swift), never by calling
// a backend-specific header's API directly, so those stay unreachable from
// Swift. ggml-vulkan-shaders-runtime.h IS included below, as of Task 5 of
// the intel-mac-vulkan-backend plan: it's not a backend API surface, just
// the plain C function (ggml_vk_shaders_set_directory) WhisperEngine.swift
// must call before whisper_init_from_file_with_params — see that header's
// doc comment and WhisperEngine.swift's init for why.
#ifndef WHISPER_CPP_MODULE_H
#define WHISPER_CPP_MODULE_H

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-opt.h"
#include "gguf.h"
#include "whisper.h"
#include "ggml-vulkan-shaders-runtime.h"

#endif
