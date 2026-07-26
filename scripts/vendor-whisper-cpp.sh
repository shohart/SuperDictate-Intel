#!/bin/bash
# scripts/vendor-whisper-cpp.sh — refresh the vendored whisper.cpp/ggml
# CPU-only sources. Re-run this and commit the result to update the pin;
# never hand-edit files under swift/Sources/whisper_cpp/.
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

# Patch the one spot in ggml-metal-device.m that assumes the upstream
# start/end-pointer-subtraction embedding; everything else is untouched.
python3 - "$DEST/ggml-metal-device.m" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
old = (
    "        extern const char ggml_metallib_start[];\n"
    "        extern const char ggml_metallib_end[];\n"
    "\n"
    "        src = [[NSString alloc] initWithBytes:ggml_metallib_start length:(ggml_metallib_end-ggml_metallib_start) encoding:NSUTF8StringEncoding];\n"
)
new = (
    "        extern const char ggml_metallib_start[];\n"
    "        extern const size_t ggml_metallib_size;\n"
    "\n"
    "        src = [[NSString alloc] initWithBytes:ggml_metallib_start length:ggml_metallib_size encoding:NSUTF8StringEncoding];\n"
)
if old not in text:
    sys.exit("vendor-whisper-cpp.sh: expected embedded-library snippet not found in ggml-metal-device.m — upstream layout changed, update the patch in scripts/vendor-whisper-cpp.sh")
with open(path, "w") as fh:
    fh.write(text.replace(old, new))
PYEOF

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
