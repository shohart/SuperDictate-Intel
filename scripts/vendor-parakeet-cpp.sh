#!/bin/bash
# scripts/vendor-parakeet-cpp.sh — deterministically vendor the pinned
# parakeet.cpp + its own pinned ggml v0.13.0 submodule (CPU backend only, this
# phase) into swift/Sources/parakeet_cpp/. Re-run this and commit the result
# to update the pin; never hand-edit files under
# swift/Sources/parakeet_cpp/upstream/ — this script wipes and regenerates
# that whole directory (see `rm -rf "$UPSTREAM_DEST"` below).
#
# The hand-authored SwiftPM module glue (module.modulemap, umbrella header)
# and the SuperDictate C bridge (swift/Sources/parakeet_cpp/bridge/,
# swift/Sources/parakeet_cpp/include/superdictate_parakeet.h) are NOT touched
# by this script — they live outside $UPSTREAM_DEST specifically so a
# re-vendor never discards them. Edit those files directly.
#
# CPU backend vendoring (everything up to and including PROVENANCE.md below)
# requires only git — no C/C++ toolchain, no Vulkan SDK. Re-run this and
# commit the result to update the CPU pin from any machine.
#
# Phase 5 (Vulkan add-on) extends this same script with a SEPARATE,
# Mac/Homebrew-toolchain-gated step (vendor_vulkan_backend, invoked at the
# bottom of this script): it copies the Vulkan backend's own device-agnostic
# C++ sources (ggml-vulkan.cpp/.h — no toolchain needed for that copy) AND,
# only if `cmake`+`glslc` are found on PATH, regenerates the embedded SPIR-V
# shader corpus (swift/Sources/parakeet_cpp/upstream/ggml-vulkan/generated/)
# by running parakeet.cpp's OWN unmodified upstream CMake build once (the
# exact same `-DPARAKEET_GGML_VULKAN=ON` configuration this fork's Phase 5
# pre-spike already proved builds cleanly, zero source patches) and then
# harvesting the generated `<shader>.comp.cpp` translation units +
# `ggml-vulkan-shaders.hpp` it writes under its own CMake build directory.
# This mirrors ggml v0.13.0's own CMake path exactly (see
# third_party/ggml/src/ggml-vulkan/CMakeLists.txt's `vulkan-shaders-gen`
# ExternalProject + per-.comp add_custom_command loop) rather than
# reimplementing or patching that generator — the generated corpus is
# embedded C arrays compiled directly into the parakeet_cpp SwiftPM target,
# NOT loose `.spv` resource files (see PROVENANCE.md / the Phase 5
# integration report for why this fork chose embedded arrays over the
# loose-`.spv`-plus-Bundle.main pattern this fork used for whisper.cpp:
# ggml v0.13.0's generator only supports the embedded-array output shape
# without a from-scratch patch, and embedding avoids the
# Contents/Resources + codesign-coverage surface entirely).
#
# If `cmake`/`glslc` are NOT found (e.g. running this on a non-Mac CI box to
# refresh just the CPU pin), vendor_vulkan_backend still copies the
# device-agnostic ggml-vulkan.cpp/.h sources but SKIPS shader regeneration
# and leaves whatever generated/ corpus is already committed untouched — so
# a plain CPU-only re-vendor never requires Homebrew and never silently
# deletes a working, already-committed shader corpus.
set -euo pipefail

PARAKEET_CPP_COMMIT="e747acdaee69b916cef62263ae5f718bda9ff3f3"
PARAKEET_CPP_REMOTE="https://github.com/mudler/parakeet.cpp.git"
# Expected pinned ggml submodule revision/tag, verified after checkout below.
# Do not override independently of PARAKEET_CPP_COMMIT — this is whatever
# commit parakeet.cpp's own .gitmodules/index pins at PARAKEET_CPP_COMMIT,
# recorded here only so the script can fail loudly on drift, never as an
# independent input.
EXPECTED_GGML_COMMIT="e705c5fed490514458bdd2eaddc43bd098fcce9b"
EXPECTED_GGML_TAG="v0.13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT_DIR/swift/Sources/parakeet_cpp"
UPSTREAM_DEST="$DEST/upstream"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "vendor-parakeet-cpp.sh: cloning parakeet.cpp @ $PARAKEET_CPP_COMMIT ..."
git clone --quiet "$PARAKEET_CPP_REMOTE" "$WORK_DIR/src"
git -C "$WORK_DIR/src" checkout --quiet "$PARAKEET_CPP_COMMIT"

ACTUAL_COMMIT="$(git -C "$WORK_DIR/src" rev-parse HEAD)"
if [[ "$ACTUAL_COMMIT" != "$PARAKEET_CPP_COMMIT" ]]; then
    echo "vendor-parakeet-cpp.sh: FATAL: checked out $ACTUAL_COMMIT, expected $PARAKEET_CPP_COMMIT" >&2
    exit 1
fi

git -C "$WORK_DIR/src" submodule update --init --recursive --quiet

ACTUAL_GGML_COMMIT="$(git -C "$WORK_DIR/src/third_party/ggml" rev-parse HEAD)"
if [[ "$ACTUAL_GGML_COMMIT" != "$EXPECTED_GGML_COMMIT" ]]; then
    echo "vendor-parakeet-cpp.sh: FATAL: ggml submodule is $ACTUAL_GGML_COMMIT, expected $EXPECTED_GGML_COMMIT ($EXPECTED_GGML_TAG) — parakeet.cpp's own pin moved; update EXPECTED_GGML_COMMIT/EXPECTED_GGML_TAG in this script after confirming the new pin is intentional, not a re-vendor of a moving target" >&2
    exit 1
fi
GGML_DESCRIBE="$(git -C "$WORK_DIR/src/third_party/ggml" describe --tags --always 2>/dev/null || echo "$ACTUAL_GGML_COMMIT")"
if [[ "$GGML_DESCRIBE" != "$EXPECTED_GGML_TAG" ]]; then
    echo "vendor-parakeet-cpp.sh: WARNING: ggml submodule commit matches but 'git describe' reports '$GGML_DESCRIBE', expected tag '$EXPECTED_GGML_TAG' (non-fatal: commit pin is exact, this is only a human-readable check)" >&2
fi

SRC="$WORK_DIR/src"
GGML_SRC="$SRC/third_party/ggml"

rm -rf "$UPSTREAM_DEST"
mkdir -p "$UPSTREAM_DEST/include" "$UPSTREAM_DEST/ggml-cpu"

# --- parakeet.cpp's own public headers ---
cp "$SRC/include/parakeet_capi.h" "$UPSTREAM_DEST/include/parakeet_capi.h"
cp "$SRC/include/parakeet.h"      "$UPSTREAM_DEST/include/parakeet.h"

# --- parakeet.cpp's own inference sources (flat, matching this fork's
#     established whisper_cpp vendoring convention — every source in this
#     upstream project already lives directly under src/ with no further
#     subdirectory nesting, so a flat copy preserves upstream's own
#     same-directory quote-include layout without needing path rewrites) ---
for f in "$SRC"/src/*.cpp "$SRC"/src/*.hpp; do
    cp "$f" "$UPSTREAM_DEST/$(basename "$f")"
done

# --- third_party/dr_wav.h (WAV decode helper parakeet's src/audio_io.cpp
#     depends on; NOT vendored from ggml, a separate single-header upstream
#     dependency parakeet.cpp itself vendors under third_party/) ---
cp "$SRC/third_party/dr_wav.h" "$UPSTREAM_DEST/dr_wav.h"

# --- ggml core (backend-agnostic), same file set this fork's
#     scripts/vendor-whisper-cpp.sh already established as sufficient to
#     link a CPU+Accelerate/BLAS ggml build ---
for f in ggml.c ggml.cpp ggml-alloc.c ggml-backend.cpp ggml-backend-reg.cpp \
         ggml-backend-impl.h ggml-backend-dl.h ggml-backend-dl.cpp \
         ggml-backend-meta.cpp ggml-common.h ggml-impl.h ggml-opt.cpp \
         ggml-quants.c ggml-quants.h ggml-threading.cpp ggml-threading.h \
         gguf.cpp; do
    cp "$GGML_SRC/src/$f" "$UPSTREAM_DEST/$f"
done
cp "$GGML_SRC/include/"*.h "$UPSTREAM_DEST/include/"

# --- ggml BLAS backend (Accelerate cblas_sgemm acceleration on macOS) ---
cp "$GGML_SRC/src/ggml-blas/ggml-blas.cpp" "$UPSTREAM_DEST/ggml-blas.cpp"

# --- ggml CPU backend only — no cuda/vulkan/metal/etc. this phase ---
cp -R "$GGML_SRC/src/ggml-cpu/." "$UPSTREAM_DEST/ggml-cpu/"

# Strip non-x86 arch variants, build tooling, and the KleidiAI/SpaceMiT
# optional accelerator sources this fork does not build (same exclusion set
# as scripts/vendor-whisper-cpp.sh, since this is the same ggml lineage's
# ggml-cpu/ layout).
rm -rf \
    "$UPSTREAM_DEST/ggml-cpu/arch/arm" \
    "$UPSTREAM_DEST/ggml-cpu/arch/riscv" \
    "$UPSTREAM_DEST/ggml-cpu/arch/powerpc" \
    "$UPSTREAM_DEST/ggml-cpu/arch/s390" \
    "$UPSTREAM_DEST/ggml-cpu/arch/wasm" \
    "$UPSTREAM_DEST/ggml-cpu/arch/loongarch" \
    "$UPSTREAM_DEST/ggml-cpu/spacemit" \
    "$UPSTREAM_DEST/ggml-cpu/kleidiai" \
    "$UPSTREAM_DEST/ggml-cpu/cmake" \
    "$UPSTREAM_DEST/ggml-cpu/CMakeLists.txt"

# --- provenance metadata (generated, never hand-edited) ---
cat > "$UPSTREAM_DEST/PROVENANCE.md" <<EOF
# Vendored upstream provenance (generated by scripts/vendor-parakeet-cpp.sh)

Do not hand-edit anything under this directory — re-run the vendor script.

- parakeet.cpp: https://github.com/mudler/parakeet.cpp
  commit: $ACTUAL_COMMIT
- ggml (parakeet.cpp's own pinned submodule, third_party/ggml):
  commit: $ACTUAL_GGML_COMMIT ($GGML_DESCRIBE)
- Vendored: CPU backend (Accelerate/BLAS on macOS) plus the Vulkan backend
  (ggml-vulkan/, device-agnostic sources + an embedded SPIR-V shader corpus
  under ggml-vulkan/generated/, regenerated only when cmake+glslc were
  available at vendor time — see this script's vendor_vulkan_backend
  function). No CUDA, HIP, Metal, or CoreML sources are included.
- License: both parakeet.cpp and ggml are MIT-licensed. See
  LICENSE-parakeet-cpp.txt and LICENSE-ggml.txt in this directory for the
  exact upstream notices at the pinned commits above.
- Vendored on: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
# .txt extensions deliberately (not e.g. "LICENSE-parakeet.cpp") — SwiftPM
# auto-compiles anything under the target with a .c/.cpp/.m/.mm extension,
# so a license file literally named "...parakeet.cpp" was picked up as a
# (invalid) C++ translation unit the first time this was tried.
cp "$SRC/LICENSE" "$UPSTREAM_DEST/LICENSE-parakeet-cpp.txt"
cp "$GGML_SRC/LICENSE" "$UPSTREAM_DEST/LICENSE-ggml.txt"

# --- Vulkan backend (Phase 5) ---
#
# Copies the device-agnostic ggml-vulkan.cpp/.h sources unconditionally (pure
# copy, no toolchain needed), and — only if cmake+glslc are on PATH —
# regenerates the embedded SPIR-V shader corpus by running parakeet.cpp's own
# unmodified CMake build (`-DPARAKEET_GGML_VULKAN=ON`, the exact configuration
# this fork's Phase 5 pre-spike already proved builds cleanly against this
# exact pinned commit, zero source patches) far enough to produce the
# `ggml-vulkan` CMake target's generated sources, then harvesting them. This
# deliberately reuses upstream's own generator rather than re-implementing or
# patching vulkan-shaders-gen.
vendor_vulkan_backend() {
    local vk_src="$GGML_SRC/src/ggml-vulkan"
    local vk_dest="$UPSTREAM_DEST/ggml-vulkan"
    mkdir -p "$vk_dest"

    cp "$vk_src/ggml-vulkan.cpp" "$vk_dest/ggml-vulkan.cpp"
    # ggml-vulkan.h itself is already vendored by the blanket
    # `cp "$GGML_SRC/include/"*.h "$UPSTREAM_DEST/include/"` copy above (it
    # lives under ggml's own include/, like every other public ggml header) --
    # not re-copied here to avoid two on-disk copies of the same header.

    if ! command -v cmake >/dev/null 2>&1 || ! command -v glslc >/dev/null 2>&1; then
        echo "vendor-parakeet-cpp.sh: cmake and/or glslc not found on PATH -- skipping Vulkan shader (re)generation." >&2
        echo "vendor-parakeet-cpp.sh: ggml-vulkan.cpp/.h were still (re)vendored above; any already-committed" >&2
        echo "vendor-parakeet-cpp.sh: $vk_dest/generated/ shader corpus is left untouched." >&2
        return 0
    fi

    echo "vendor-parakeet-cpp.sh: cmake+glslc found -- regenerating the Vulkan SPIR-V shader corpus (this runs parakeet.cpp's own upstream CMake build; can take a few minutes) ..."
    local vk_build="$WORK_DIR/vk-build"
    # PARAKEET_GGML_VULKAN is parakeet.cpp's own CMake option (proven working
    # by the Phase 5 pre-spike); GGML_NATIVE=OFF here because vendoring must be
    # host-independent -- the actual app build's ISA flags are set separately
    # in swift/Package.swift, not baked into the vendored shader corpus (the
    # shader corpus is GPU-side SPIR-V and has no dependency on host CPU ISA
    # flags in the first place; OFF just keeps this cmake invocation itself
    # reproducible across machines).
    cmake -S "$SRC" -B "$vk_build" -DPARAKEET_GGML_VULKAN=ON -DGGML_NATIVE=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
    cmake --build "$vk_build" --target ggml-vulkan -j

    local gen_dir="$vk_build/third_party/ggml/src/ggml-vulkan"
    local header="$gen_dir/ggml-vulkan-shaders.hpp"
    if [[ ! -f "$header" ]]; then
        echo "vendor-parakeet-cpp.sh: FATAL: expected generated header not found at $header -- upstream's CMake output layout may have changed" >&2
        exit 1
    fi

    rm -rf "$vk_dest/generated"
    mkdir -p "$vk_dest/generated"
    cp "$header" "$vk_dest/generated/ggml-vulkan-shaders.hpp"
    local comp_cpp_count=0
    for f in "$gen_dir"/*.comp.cpp; do
        [[ -e "$f" ]] || continue
        cp "$f" "$vk_dest/generated/$(basename "$f")"
        comp_cpp_count=$((comp_cpp_count + 1))
    done
    if [[ "$comp_cpp_count" -eq 0 ]]; then
        echo "vendor-parakeet-cpp.sh: FATAL: no generated *.comp.cpp shader translation units found under $gen_dir -- upstream's CMake output layout may have changed" >&2
        exit 1
    fi
    echo "vendor-parakeet-cpp.sh: vendored $comp_cpp_count generated shader translation units + header into $vk_dest/generated/"
}
vendor_vulkan_backend

upstream_file_count=$(find "$UPSTREAM_DEST" -type f | wc -l | tr -d ' ')
upstream_size=$(du -sh "$UPSTREAM_DEST" | cut -f1)
echo "vendor-parakeet-cpp.sh: vendored $upstream_file_count files ($upstream_size) into $UPSTREAM_DEST"
echo "vendor-parakeet-cpp.sh: parakeet.cpp @ $ACTUAL_COMMIT, ggml @ $ACTUAL_GGML_COMMIT ($GGML_DESCRIBE)"
