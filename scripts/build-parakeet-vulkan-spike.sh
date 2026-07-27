#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${PARAKEET_SOURCE_DIR:-$ROOT_DIR/vendor/parakeet.cpp}"
BUILD_DIR="${PARAKEET_BUILD_DIR:-$ROOT_DIR/.build/parakeet-vulkan}"
INSTALL_DIR="${PARAKEET_INSTALL_DIR:-$ROOT_DIR/dist/parakeet-vulkan-spike}"
BUILD_JOBS="${PARAKEET_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 8)}"

say() {
    printf 'SuperDictate Parakeet spike: %s\n' "$*"
}

fail() {
    printf 'SuperDictate Parakeet spike: %s\n' "$*" >&2
    exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS is required."
[[ "$(uname -m)" == "x86_64" ]] || fail "This spike currently targets Intel macOS (x86_64)."
command -v cmake >/dev/null 2>&1 || fail "cmake is required. Install it with Homebrew for development."
command -v otool >/dev/null 2>&1 || fail "otool is required. Install Apple Command Line Tools."

[[ -f "$SOURCE_DIR/CMakeLists.txt" ]] || fail "parakeet.cpp source not found at $SOURCE_DIR"
[[ -f "$SOURCE_DIR/third_party/ggml/CMakeLists.txt" ]] || fail "parakeet.cpp ggml submodule is missing. Clone/update it recursively."

MOLTENVK_PREFIX="${MOLTENVK_PREFIX:-/usr/local/opt/molten-vk}"
VULKAN_HEADERS_PREFIX="${VULKAN_HEADERS_PREFIX:-/usr/local/opt/vulkan-headers}"

[[ -f "$MOLTENVK_PREFIX/lib/libMoltenVK.a" ]] || fail "Static MoltenVK not found at $MOLTENVK_PREFIX/lib/libMoltenVK.a"
[[ -f "$VULKAN_HEADERS_PREFIX/include/vulkan/vulkan.h" ]] || fail "Vulkan headers not found under $VULKAN_HEADERS_PREFIX/include"

rm -rf "$BUILD_DIR" "$INSTALL_DIR"
mkdir -p "$BUILD_DIR" "$INSTALL_DIR/bin"

say "Configuring CPU + Vulkan helper spike..."
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DPARAKEET_BUILD_TESTS=OFF \
    -DPARAKEET_BUILD_CLI=ON \
    -DPARAKEET_BUILD_SERVER=OFF \
    -DPARAKEET_SHARED=OFF \
    -DPARAKEET_GGML_VULKAN=ON \
    -DPARAKEET_GGML_METAL=OFF \
    -DGGML_NATIVE=ON \
    -DGGML_LLAMAFILE=ON \
    -DVulkan_INCLUDE_DIR="$VULKAN_HEADERS_PREFIX/include" \
    -DVulkan_LIBRARY="$MOLTENVK_PREFIX/lib/libMoltenVK.a" \
    -DCMAKE_EXE_LINKER_FLAGS="-framework AppKit -framework CoreFoundation -framework CoreGraphics -framework Foundation -framework IOSurface -framework IOKit -framework Metal -framework QuartzCore -lobjc -lc++"

say "Building with $BUILD_JOBS jobs..."
cmake --build "$BUILD_DIR" --config Release --parallel "$BUILD_JOBS"

CLI=""
while IFS= read -r candidate; do
    CLI="$candidate"
    break
done < <(find "$BUILD_DIR" -type f -name parakeet-cli -perm -111 | sort)

[[ -n "$CLI" && -x "$CLI" ]] || fail "Build succeeded but parakeet-cli was not found."
cp "$CLI" "$INSTALL_DIR/bin/parakeet-cli"
chmod 755 "$INSTALL_DIR/bin/parakeet-cli"

say "Checking architecture..."
file "$INSTALL_DIR/bin/parakeet-cli"
file "$INSTALL_DIR/bin/parakeet-cli" | grep -q 'x86_64' || fail "Built binary is not x86_64."

say "Checking runtime dependencies..."
otool -L "$INSTALL_DIR/bin/parakeet-cli" | tee "$INSTALL_DIR/otool.txt"
if grep -E '/(usr/local|opt/homebrew|Cellar)/' "$INSTALL_DIR/otool.txt"; then
    fail "The spike has a Homebrew runtime dependency. It is not suitable for app packaging yet."
fi

say "Enumerating available backends/devices..."
(
    export PARAKEET_DEVICE="${PARAKEET_DEVICE:-Vulkan0}"
    "$INSTALL_DIR/bin/parakeet-cli" --help
) >"$INSTALL_DIR/help.txt" 2>&1 || true

cat >"$INSTALL_DIR/run-example.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL="${1:?usage: run-example.sh MODEL.gguf AUDIO.wav [cpu|Vulkan0]}"
AUDIO="${2:?usage: run-example.sh MODEL.gguf AUDIO.wav [cpu|Vulkan0]}"
DEVICE="${3:-Vulkan0}"
export PARAKEET_DEVICE="$DEVICE"
exec "$HERE/bin/parakeet-cli" transcribe --model "$MODEL" --input "$AUDIO" --decoder tdt
EOF
chmod 755 "$INSTALL_DIR/run-example.sh"

say "Built spike at $INSTALL_DIR"
say "Run: $INSTALL_DIR/run-example.sh MODEL.gguf AUDIO.wav Vulkan0"
say "CPU baseline: $INSTALL_DIR/run-example.sh MODEL.gguf AUDIO.wav cpu"
