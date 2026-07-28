// Umbrella header for the parakeet_cpp SwiftPM target.
//
// This deliberately exports ONLY SuperDictate's own C bridge
// (superdictate_parakeet.h), never upstream's parakeet_capi.h/parakeet.h
// directly — Swift never sees `parakeet_ctx`, `pk::Model`, or any other
// upstream C++ type. See docs/parakeet-intel-backend.md §7 ("Do not expose
// upstream C++ types directly to Swift").
//
// ggml-vulkan-shaders-runtime.h IS included below (Phase 5 / Vulkan
// add-on): it is not a backend API surface, just the runtime SPIR-V
// shader directory configuration point — ggml_vk_shaders_set_directory()
// must be reachable from Swift (ParakeetEngine.init calls it, resolving
// Contents/Resources/vulkan-shaders/ via Bundle.main, before ever
// requesting a Vulkan-device context) or every shader symbol silently
// resolves to null/zero-length, which is a Vulkan/MoltenVK-level crash
// risk deep inside ggml-vulkan.cpp, not a graceful CPU fallback — same
// bug class this fork already hit and fixed once for whisper.cpp
// (commit 14efc8d).
#ifndef PARAKEET_CPP_MODULE_H
#define PARAKEET_CPP_MODULE_H

#include "superdictate_parakeet.h"
#include "ggml-vulkan-shaders-runtime.h"

#endif
