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
# CPU-only in this phase (Phase 3 of the parakeet.cpp migration plan): no
# CUDA/HIP/Metal/CoreML/Vulkan sources are vendored. Vulkan is added by a
# later phase's own script update (spec §5 step 7 / plan Phase 5), which will
# extend this script rather than replace it.
#
# Requires: git, a C/C++ toolchain is NOT required to run this script (pure
# source vendoring, no compilation happens here).
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
- Vendored: CPU backend only (Accelerate/BLAS on macOS). No CUDA, HIP,
  Metal, CoreML, or Vulkan sources are included in this vendor pass.
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

upstream_file_count=$(find "$UPSTREAM_DEST" -type f | wc -l | tr -d ' ')
upstream_size=$(du -sh "$UPSTREAM_DEST" | cut -f1)
echo "vendor-parakeet-cpp.sh: vendored $upstream_file_count files ($upstream_size) into $UPSTREAM_DEST"
echo "vendor-parakeet-cpp.sh: parakeet.cpp @ $ACTUAL_COMMIT, ggml @ $ACTUAL_GGML_COMMIT ($GGML_DESCRIBE)"
