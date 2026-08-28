#!/bin/bash
# scripts/vendor-whisper-cpp.sh — refresh the vendored whisper.cpp/ggml
# CPU-only sources. Re-run this and commit the result to update the pin;
# never hand-edit files under swift/Sources/whisper_cpp/ — this script
# wipes and regenerates that whole directory (see `rm -rf "$DEST"` below),
# including copying in the two hand-authored (not from upstream) runtime
# SPIR-V loader files this script's Vulkan section maintains permanently at
# scripts/vulkan-shader-runtime/ for exactly that reason: edit them there,
# not under swift/Sources/whisper_cpp/, or a re-vendor will silently
# discard the edit.
#
# Prerequisite for the Vulkan section below (see "Pre-compiling the
# Vulkan SPIR-V shader corpus"): `glslc` must be on PATH. On the real
# Mac this comes from `brew install shaderc` (already done there during
# the intel-mac-vulkan-backend feasibility investigation/spike). This
# script only needs a working C++17 compiler beyond that — it does not
# require the Vulkan SDK or cmake to build the shader-compiler tool.
set -euo pipefail

PIN_COMMIT="080bbbe85230f624f0b52127f1ae1218247989f9"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/swift/Sources/whisper_cpp"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

git clone --quiet https://github.com/ggml-org/whisper.cpp.git "$WORK_DIR/src"
git -C "$WORK_DIR/src" checkout --quiet "$PIN_COMMIT"

rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/ggml-cpu"

# whisper.cpp core (no Parakeet, no CoreML/OpenVINO glue)
cp "$WORK_DIR/src/src/whisper.cpp"       "$DEST/whisper.cpp"
cp "$WORK_DIR/src/src/whisper-arch.h"    "$DEST/whisper-arch.h"
cp "$WORK_DIR/src/include/whisper.h"     "$DEST/include/whisper.h"

# ggml core (backend-agnostic)
#
# ggml-backend-dl.h/.cpp and ggml-backend-meta.cpp were missing from this
# list until this pass (Task 1's original vendoring missed them;
# commit c25f5d8 hand-copied them straight from the pinned commit to fix
# undefined-symbol link errors, but never updated this script — so every
# re-vendor before this fix silently deleted them again). Listed here now
# so the script's output matches what's actually needed to link.
for f in ggml.c ggml.cpp ggml-alloc.c ggml-backend.cpp ggml-backend-reg.cpp \
         ggml-backend-impl.h ggml-backend-dl.h ggml-backend-dl.cpp \
         ggml-backend-meta.cpp ggml-common.h ggml-impl.h ggml-opt.cpp \
         ggml-quants.c ggml-quants.h ggml-threading.cpp ggml-threading.h \
         gguf.cpp; do
    cp "$WORK_DIR/src/ggml/src/$f" "$DEST/$f"
done
cp "$WORK_DIR/src/ggml/include/"*.h "$DEST/include/"

# ggml BLAS backend (Accelerate cblas_sgemm acceleration on macOS)
cp "$WORK_DIR/src/ggml/src/ggml-blas/ggml-blas.cpp" "$DEST/ggml-blas.cpp"

# ggml Metal backend — registered so ggml_backend_reg_count()/
# whisper_print_system_info() report a METAL backend, but NOT enabled by
# default (WhisperEngine.init hardcodes params.use_gpu = false; a later
# task adds the actual on/off toggle). Vendor the backend .cpp/.m/.h
# sources flat into $DEST (same pattern as ggml-blas.cpp above), skipping
# ggml-metal's own CMakeLists.txt.
METAL_SRC="$WORK_DIR/src/ggml/src/ggml-metal"
for f in ggml-metal.cpp ggml-metal-common.cpp ggml-metal-common.h \
         ggml-metal-context.h ggml-metal-context.m \
         ggml-metal-device.cpp ggml-metal-device.h ggml-metal-device.m \
         ggml-metal-impl.h ggml-metal-ops.cpp ggml-metal-ops.h; do
    cp "$METAL_SRC/$f" "$DEST/$f"
done

# --- Embedding the Metal shader source (ggml-metal.metal) ---
#
# Upstream's own CMakeLists.txt (ggml/src/ggml-metal/CMakeLists.txt) offers
# two ways to get the shader source into the binary when
# GGML_METAL_EMBED_LIBRARY is set:
#   1. Merge ggml-common.h and ggml-metal-impl.h into ggml-metal.metal via
#      sed (replacing the `__embed_ggml-common.h__` marker and the
#      `#include "ggml-metal-impl.h"` line with the real file contents).
#   2. Turn that merged file into a `.s` assembly file using
#      `.incbin` directives inside a `__DATA,__ggml_metallib` section,
#      exposing it as the symbols `ggml_metallib_start`/`ggml_metallib_end`
#      (computed via pointer subtraction between the two symbols).
#
# Step 2 needs `enable_language(ASM)` and a linker section trick that
# SwiftPM has no equivalent for (no custom build steps, and pointer
# arithmetic between two separately-linked symbols isn't something we can
# safely reproduce without the linker guaranteeing their layout). So
# instead we do our own step 2': generate a portable C++ translation unit,
# once, right here at vendor time, containing the merged shader source as
# a `const char[]` (built from per-line raw string literals, each one
# re-including its own trailing newline so the concatenated string is
# byte-identical to the merged .metal file) plus an explicit
# `ggml_metallib_size` (a plain byte count — no pointer subtraction, so no
# reliance on symbol layout). ggml-metal-device.m is patched with a tiny,
# well-scoped sed to consume `ggml_metallib_size` instead of the
# start/end-pointer-subtraction it uses upstream; everything else in that
# file (including the `#if GGML_METAL_EMBED_LIBRARY` branching itself) is
# untouched. This file is checked in as generated output — regenerate it
# by re-running this script, never hand-edit it.
#
# Re-run this whole script (which re-clones whisper.cpp at $PIN_COMMIT) to
# regenerate ggml-metal-embed.cpp if that pin ever moves.
COMMON_H="$WORK_DIR/src/ggml/src/ggml-common.h"
MERGED_METAL="$WORK_DIR/merged-ggml-metal.metal"
sed -e "/__embed_ggml-common.h__/r $COMMON_H" -e "/__embed_ggml-common.h__/d" \
    < "$METAL_SRC/ggml-metal.metal" \
    | sed -e "/#include \"ggml-metal-impl.h\"/r $METAL_SRC/ggml-metal-impl.h" \
          -e "/#include \"ggml-metal-impl.h\"/d" \
    > "$MERGED_METAL"

{
    echo "// GENERATED FILE — regenerated by scripts/vendor-whisper-cpp.sh at re-vendor"
    echo "// time (never hand-edit). Embeds ggml-metal.metal, merged with"
    echo "// ggml-common.h and ggml-metal-impl.h exactly as upstream's"
    echo "// GGML_METAL_EMBED_LIBRARY CMake path does, as a C string — so"
    echo "// ggml-metal-device.m can compile the Metal shader library from"
    echo "// source at runtime with no bundled .metal resource file and no"
    echo "// metallib build step (SwiftPM can do neither)."
    echo "#include <cstddef>"
    echo
    echo 'extern "C" {'
    echo
    echo "extern const char ggml_metallib_start[] ="
    awk '{ printf "R\"GGMLMETAL(%s\n)GGMLMETAL\"\n", $0 }' "$MERGED_METAL"
    echo ";"
    echo
    echo "extern const size_t ggml_metallib_size = sizeof(ggml_metallib_start) - 1;"
    echo
    echo '} // extern "C"'
} > "$DEST/ggml-metal-embed.cpp"

# Patch two spots in ggml-metal-device.m. Everything else in the file,
# including all the `#if GGML_METAL_EMBED_LIBRARY` branching, is untouched.
python3 - "$DEST/ggml-metal-device.m" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()

def patch(text, old, new, what):
    if old not in text:
        sys.exit(
            "vendor-whisper-cpp.sh: expected snippet for '%s' not found in "
            "ggml-metal-device.m — upstream layout changed, update the patch "
            "in scripts/vendor-whisper-cpp.sh" % what
        )
    return text.replace(old, new)

# Patch 1: consume ggml_metallib_size instead of the upstream
# start/end-pointer-subtraction embedding (see the embedding comment above).
text = patch(
    text,
    (
        "        extern const char ggml_metallib_start[];\n"
        "        extern const char ggml_metallib_end[];\n"
        "\n"
        "        src = [[NSString alloc] initWithBytes:ggml_metallib_start length:(ggml_metallib_end-ggml_metallib_start) encoding:NSUTF8StringEncoding];\n"
    ),
    (
        "        extern const char ggml_metallib_start[];\n"
        "        extern const size_t ggml_metallib_size;\n"
        "\n"
        "        src = [[NSString alloc] initWithBytes:ggml_metallib_start length:ggml_metallib_size encoding:NSUTF8StringEncoding];\n"
    ),
    "metallib start/end -> size",
)

# Patch 2: defer the full embedded-shader-library compile (~30s on this
# project's Intel Mac Pro target) out of ggml_metal_device_init(), which
# runs unconditionally and eagerly for every compiled-in backend as part
# of ggml-backend-reg.cpp's function-local-static registry singleton —
# i.e. on *every* whisper_init_from_file*() call (whisper_backend_init()
# touches ggml_backend_dev_count()/ggml_backend_init_by_type(), which
# construct that singleton), regardless of whether GPU use is requested.
# Compare ggml-cuda.cu's ggml_backend_cuda_reg(): it only queries cheap
# per-device properties (cudaGetDeviceProperties/cudaDeviceGetPCIBusId) at
# registration time and defers real context/module init — this pinned
# commit's ggml-metal.cpp has no equivalent lazy split at the device level
# (ggml_metal_device_init() unconditionally calls ggml_metal_library_init()
# inline), so it's reproduced here: `dev->library` is left NULL at device
# construction and only compiled on first real access, i.e. the first time
# a Metal *context* is actually created (ggml-metal-context.m calls
# ggml_metal_device_get_library() at context-init time, which upstream's
# own code only reaches when a backend is scheduled for compute — normal
# CPU-only `whisper_init_from_file*()`/registry construction never reaches
# it). This keeps GPU support strictly opt-in / zero-cost-when-unused, per
# the parent plan's binding constraint, without touching anything else in
# ggml_metal_device_init()'s device/property probing.
text = patch(
    text,
    (
        "            dev->library = ggml_metal_library_init(dev);\n"
        "            if (!dev->library) {\n"
        "                GGML_LOG_ERROR(\"%s: error: failed to create library\\n\", __func__);\n"
        "            }\n"
    ),
    (
        "            // Deferred (see the lazy-library-init comment in\n"
        "            // scripts/vendor-whisper-cpp.sh): compiled lazily by\n"
        "            // ggml_metal_device_get_library() on first real use,\n"
        "            // not eagerly here at device/registry construction time.\n"
        "            dev->library = NULL;\n"
    ),
    "eager library init in ggml_metal_device_init",
)
text = patch(
    text,
    (
        "ggml_metal_library_t ggml_metal_device_get_library(ggml_metal_device_t dev) {\n"
        "    return dev->library;\n"
        "}\n"
    ),
    (
        "ggml_metal_library_t ggml_metal_device_get_library(ggml_metal_device_t dev) {\n"
        "    // Lazy: this is the first point at which Metal compute is\n"
        "    // actually about to happen (a context is being created), so this\n"
        "    // is where the one-time embedded-shader-library compile cost is\n"
        "    // paid — never at mere backend registration/enumeration time.\n"
        "    // Not thread-safe against concurrent first-callers by construction\n"
        "    // (matches upstream's own lack of per-device locking elsewhere in\n"
        "    // this file); whisper.cpp only ever creates one context per device.\n"
        "    if (dev->library == NULL) {\n"
        "        dev->library = ggml_metal_library_init(dev);\n"
        "        if (!dev->library) {\n"
        "            GGML_LOG_ERROR(\"%s: error: failed to create library\\n\", __func__);\n"
        "        }\n"
        "    }\n"
        "\n"
        "    return dev->library;\n"
        "}\n"
    ),
    "lazy accessor in ggml_metal_device_get_library",
)

with open(path, "w") as fh:
    fh.write(text)
PYEOF

# ggml Vulkan backend — vendored alongside Metal (same status: compiled
# in but not enabled by default; a later task wires the actual runtime
# enablement). Unlike ggml-metal, upstream's Vulkan backend is a single
# translation unit; ggml-vulkan.h itself doesn't need a separate cp here
# — it's already picked up by the `cp .../ggml/include/*.h` glob in the
# "ggml core" section above.
VULKAN_SRC="$WORK_DIR/src/ggml/src/ggml-vulkan"
cp "$VULKAN_SRC/ggml-vulkan.cpp" "$DEST/ggml-vulkan.cpp"

# --- Pre-compiling the Vulkan SPIR-V shader corpus ---
#
# Upstream compiles GLSL compute shaders (ggml-vulkan/vulkan-shaders/*.comp)
# to SPIR-V at *build* time via a CMake ExternalProject step (builds a
# helper tool, vulkan-shaders-gen, then runs it once per .comp file,
# invoking glslc under the hood) and embeds the results as generated C++
# byte arrays compiled straight into libggml-vulkan. SwiftPM has no
# build-time custom-command equivalent (same limitation documented above
# for ggml-metal-embed.cpp), so this project instead compiles the whole
# shader corpus once, here, at vendor time.
#
# Unlike the Metal shader library (a single merged source small enough to
# embed as a C++ string literal), re-encoding the Vulkan SPIR-V corpus as
# C++ byte-array source is NOT viable: the intel-mac-vulkan-backend
# spike (vulkan-spike/, commit 874c034) measured the full corpus at 1785
# .spv variants / 48MB of raw SPIR-V vs. 191MB if text-encoded as C++
# literals the way ggml's own generator does — too large to check in as
# source. So instead the raw .spv binaries are checked in directly under
# swift/Sources/whisper_cpp/vulkan-shaders/ and loaded by explicit file
# path at runtime (Task 2 of the vulkan-gpu-backend plan implements that
# loader; this script's job ends at producing the .spv files). This
# directory must never be referenced by Package.swift's `resources:` —
# SwiftPM resource bundling is explicitly out per the parent plan's
# global constraints.
#
# The vulkan-shaders-gen tool itself (vulkan-shaders-gen.cpp) is small,
# self-contained (std::thread + fork/execvp to shell out to glslc — no
# Vulkan SDK headers, no cmake needed) and is NOT vendored into the
# SwiftPM target: it's a build-time-only host tool, analogous to how
# glslc itself isn't vendored either.
#
# Extension-gated shader variants (cooperative matrix, integer dot
# product, bfloat16) are only enabled by upstream's CMakeLists.txt after
# probing glslc: it compiles each of vulkan-shaders/feature-tests/*.comp
# (which just `#extension ... : require`s the relevant GLSL extension)
# and checks stderr for "extension not supported". Reproduced here by
# hand (same glslc invocation as upstream's test_shader_extension_support
# CMake function) instead of running the full ggml-vulkan CMakeLists.txt,
# which would need find_package(Vulkan)/SPIRV-Headers wired up — this
# vendoring script only needs the pass/fail outcome of each probe. Note
# this only tells us glslc can *assemble* SPIR-V using the extension, not
# that the RX 6600/MoltenVK can actually execute it at runtime — matching
# upstream's own probe, which has the same limitation.
command -v glslc >/dev/null || {
    echo "vendor-whisper-cpp.sh: glslc not found on PATH (brew install shaderc) — required to pre-compile the Vulkan shader corpus" >&2
    exit 1
}

VULKAN_SHADERS_SRC="$VULKAN_SRC/vulkan-shaders"
VULKAN_GEN_BIN="$WORK_DIR/vulkan-shaders-gen"
VULKAN_SPV_OUT="$WORK_DIR/vulkan-shaders-spv"
mkdir -p "$VULKAN_SPV_OUT"

VULKAN_GEN_DEFINES=()
probe_shader_extension() {
    local feature_test="$1" define_name="$2"
    local stderr_out
    stderr_out="$(glslc -o - -fshader-stage=compute --target-env=vulkan1.3 \
        "$VULKAN_SHADERS_SRC/feature-tests/$feature_test" 2>&1 >/dev/null || true)"
    if [[ "$stderr_out" != *"extension not supported"* ]]; then
        VULKAN_GEN_DEFINES+=("-D${define_name}")
    fi
}
probe_shader_extension "coopmat.comp"                   "GGML_VULKAN_COOPMAT_GLSLC_SUPPORT"
probe_shader_extension "coopmat2.comp"                  "GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT"
probe_shader_extension "coopmat2_decode_vector.comp"    "GGML_VULKAN_COOPMAT2_DECODE_VECTOR_GLSLC_SUPPORT"
probe_shader_extension "integer_dot.comp"               "GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT"
probe_shader_extension "bfloat16.comp"                  "GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT"

c++ -std=c++17 -O2 -pthread \
    "${VULKAN_GEN_DEFINES[@]}" \
    -o "$VULKAN_GEN_BIN" \
    "$VULKAN_SHADERS_SRC/vulkan-shaders-gen.cpp"

# vulkan-shaders-gen only compiles shaders for ONE .comp source file per
# invocation (string_to_spv() in vulkan-shaders-gen.cpp skips compiling
# anything at all when --source is omitted — it only emits header
# declarations in that mode, it does NOT mean "compile everything";
# confirmed empirically: an --source-less run produced zero .spv files).
# So, same as the CMake foreach loop in ggml-vulkan/CMakeLists.txt, drive
# it once per top-level .comp file (non-recursive — vulkan-shaders/*.comp
# only, matching upstream's own `file(GLOB ... "${_ggml_vk_input_dir}/*.comp")`;
# vulkan-shaders/feature-tests/*.comp are probe-only shaders, not real
# ggml ops, and must NOT be compiled into the corpus). --target-hpp/
# --target-cpp are omitted: both are only written when --source is set
# in a way that needs them (see the write_output_files() guards in
# vulkan-shaders-gen.cpp), and this project discards the generated
# header/byte-array-embedding output anyway — only the raw .spv files in
# --output-dir are kept.
for comp_file in "$VULKAN_SHADERS_SRC"/*.comp; do
    "$VULKAN_GEN_BIN" \
        --glslc "$(command -v glslc)" \
        --source "$comp_file" \
        --output-dir "$VULKAN_SPV_OUT"
done

mkdir -p "$DEST/vulkan-shaders"
cp "$VULKAN_SPV_OUT"/*.spv "$DEST/vulkan-shaders/"

spv_count=$(find "$DEST/vulkan-shaders" -name '*.spv' | wc -l | tr -d ' ')
spv_size=$(du -sh "$DEST/vulkan-shaders" | cut -f1)
echo "Compiled $spv_count SPIR-V shaders ($spv_size) into $DEST/vulkan-shaders"

# --- Generating the runtime SPIR-V loader's symbol table (Task 2) ---
#
# ggml-vulkan.cpp #includes "ggml-vulkan-shaders.hpp" expecting upstream's
# generated per-shader `<name>_data`/`<name>_len` extern declarations (see
# the "Pre-compiling..." comment above for why this project doesn't ship
# upstream's compiled-in-byte-array version of that header). Reuse the same
# $VULKAN_GEN_BIN this script just built — with the exact same
# GGML_VULKAN_*_GLSLC_SUPPORT defines probed above, so the symbol set
# matches the .spv corpus this run just produced — in its aggregate mode
# (no --source: per string_to_spv()'s `input_filepath == ""` branch, this
# only emits extern declarations, no glslc/Vulkan-SDK dependency, see
# scripts/gen-vulkan-shader-runtime.py's module docstring for the full
# explanation) to get the ground-truth identifier list, then hand it to
# gen-vulkan-shader-runtime.py to turn into this project's runtime-loaded
# replacement header + .cpp.
VULKAN_GROUND_TRUTH_HPP="$WORK_DIR/ggml-vulkan-shaders-ground-truth.hpp"
VULKAN_GROUND_TRUTH_CPP="$WORK_DIR/ggml-vulkan-shaders-ground-truth.cpp"
"$VULKAN_GEN_BIN" \
    --output-dir "$VULKAN_SPV_OUT" \
    --target-hpp "$VULKAN_GROUND_TRUTH_HPP" \
    --target-cpp "$VULKAN_GROUND_TRUTH_CPP"

python3 "$ROOT_DIR/scripts/gen-vulkan-shader-runtime.py" \
    "$VULKAN_GROUND_TRUTH_HPP" \
    "$DEST/ggml-vulkan-shaders.hpp" \
    "$DEST/ggml-vulkan-shaders.cpp"

# The loader implementation these generated files depend on
# (ggml_vk_shaders_detail::get_data/get_len, ggml_vk_shaders_set_directory)
# is hand-authored, not derived from upstream or from vulkan-shaders-gen's
# output — permanently maintained at scripts/vulkan-shader-runtime/ (see
# this script's header comment) specifically so it survives this script's
# `rm -rf "$DEST"` at the top. Copy it into place same as every other
# $DEST file this script produces.
cp "$ROOT_DIR/scripts/vulkan-shader-runtime/ggml-vulkan-shaders-runtime.h" "$DEST/include/"
cp "$ROOT_DIR/scripts/vulkan-shader-runtime/ggml-vulkan-shaders-runtime.cpp" "$DEST/"

# ggml CPU backend only — no cuda/vulkan/etc. (Metal handled above.)
cp -R "$WORK_DIR/src/ggml/src/ggml-cpu/." "$DEST/ggml-cpu/"

# Strip anything that would drag in non-CPU backends or build tooling.
rm -rf "$DEST/ggml-cpu/kleidiai" "$DEST/ggml-cpu/cmake" "$DEST/ggml-cpu/CMakeLists.txt"

# whisper_cpp SwiftPM module glue — hand-authored for this project, not
# from upstream (upstream has no SwiftPM target at all). Written here
# rather than left for a human to restore by hand, since `rm -rf "$DEST"`
# above would otherwise silently delete it on every re-vendor (as it did
# for ggml-backend-dl.*/ggml-backend-meta.cpp before this pass — see the
# comment above). Registering the Metal backend does NOT change this file:
# `import whisper_cpp` from Swift still only sees the CPU-facing API;
# ggml-metal.h is compiled into the target but deliberately not exported
# through this umbrella header.
cat > "$DEST/include/module.modulemap" <<'EOF'
module whisper_cpp {
    header "whisper_cpp_module.h"
    export *
}
EOF
cat > "$DEST/include/whisper_cpp_module.h" <<'EOF'
// Umbrella header for the whisper_cpp SwiftPM target.
//
// This intentionally only pulls in the C headers whisper.cpp/ggml
// actually need to be *called* from Swift (Task 3's WhisperEngine).
// It deliberately does NOT include ggml-cpp.h (C++-only, std::unique_ptr,
// would fail import as C), nor any backend header other than the CPU
// one (ggml-metal.h / ggml-cuda.h / ggml-vulkan.h / etc. must never be
// reachable from this module — this fork is CPU-only, see
// Package.swift's GGML_USE_CPU / GGML_USE_ACCELERATE defines).
#ifndef WHISPER_CPP_MODULE_H
#define WHISPER_CPP_MODULE_H

#include "ggml.h"
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml-opt.h"
#include "gguf.h"
#include "whisper.h"

#endif
EOF

echo "Vendored whisper.cpp/ggml @ $PIN_COMMIT into $DEST"
