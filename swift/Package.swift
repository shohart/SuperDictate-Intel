// swift-tools-version: 6.0
//
// SuperDictate — a Swift push-to-talk dictation app
// for macOS Apple Silicon. Native AppKit / AVFoundation, FluidAudio
// driving Parakeet TDT v3 on the Apple Neural Engine. macOS 14
// (Sonoma) minimum. The Hardened Runtime microphone entitlement
// (`com.apple.security.device.audio-input` in `entitlements.plist`)
// is what Tahoe 26 checks before exposing the app in Privacy &
// Security → Microphone; on macOS 14–25 the legacy sandbox key
// (`com.apple.security.device.microphone`) is the fallback. Both
// ship in the same build so a single notarised binary works
// across the supported range.
import PackageDescription

let package = Package(
    name: "Parakey",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .executable(name: "Parakey", targets: ["Parakey"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "whisper_cpp",
            exclude: [
                "ggml-cpu/arch/arm",
                "ggml-cpu/arch/riscv",
                "ggml-cpu/arch/powerpc",
                "ggml-cpu/arch/s390",
                "ggml-cpu/arch/wasm",
                "ggml-cpu/arch/loongarch",
                "ggml-cpu/spacemit",
                // Metal backend removed from the active build (Task 5 of
                // the intel-mac-vulkan-backend plan — Vulkan replaces it
                // as the GPU backend on this fork). The vendored Metal
                // sources are deliberately NOT deleted (git history plus
                // this exclude entry keeps re-enabling them a one-line
                // change), just excluded from compilation now that
                // GGML_USE_METAL is gone from cSettings/cxxSettings below
                // and Metal/MetalKit are gone from linkerSettings — several
                // of these .m/.cpp files call Metal APIs unconditionally
                // (not all gated behind #ifdef GGML_USE_METAL), so leaving
                // them compiled-but-unlinked would fail the build once the
                // framework is gone. Headers (ggml-metal*.h) aren't listed
                // here; SwiftPM only auto-compiles .c/.cpp/.m/.mm sources,
                // so headers need no exclude entry.
                "ggml-metal-common.cpp",
                "ggml-metal-context.m",
                "ggml-metal.cpp",
                "ggml-metal-device.cpp",
                "ggml-metal-device.m",
                "ggml-metal-embed.cpp",
                "ggml-metal-ops.cpp",
                // Raw .spv binaries (48MB, 1785 files) pre-compiled by
                // scripts/vendor-whisper-cpp.sh. Excluded (not source,
                // not Swift) so SwiftPM neither tries to compile them nor
                // auto-bundles them as a resource — this project loads
                // them by explicit file path at runtime instead (see the
                // vendoring script's SPIR-V section; per the parent
                // plan's global constraints, `resources:` must never
                // reference this directory). Same rationale as the
                // menubar-PNG precedent in the Parakey target below: keep
                // SwiftPM's own resource-bundling mechanism out of it
                // entirely. This entry is permanent, unlike the one above.
                "vulkan-shaders",
            ],
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                // Vulkan backend define (Task 3 of the intel-mac-vulkan-backend
                // plan; Metal's equivalent GGML_USE_METAL/GGML_METAL_EMBED_LIBRARY
                // defines were removed in Task 5, which replaces Metal with
                // Vulkan as this fork's GPU backend). This is what
                // ggml-backend-reg.cpp's #ifdef GGML_USE_VULKAN gates
                // registration on (calling ggml_backend_vk_reg(), declared in
                // ggml-vulkan.h and defined in ggml-vulkan.cpp, now compiled
                // into this target — see the removed exclude entry above).
                // The header search path below points at Homebrew's
                // vulkan-headers package (vulkan/vulkan_core.h,
                // vulkan/vulkan.hpp) that ggml-vulkan.cpp/.h include; see
                // vulkan-spike/Package.swift (deleted in Task 5; see git
                // history) for the proven-working reference this was
                // transcribed from.
                .define("GGML_USE_VULKAN"),
                .define("GGML_VERSION", to: "\"080bbbe8\""),
                .define("GGML_COMMIT", to: "\"080bbbe85230f624f0b52127f1ae1218247989f9\""),
                .define("WHISPER_VERSION", to: "\"080bbbe8\""),
                .headerSearchPath("."),
                .headerSearchPath("ggml-cpu"),
                // The vulkan-headers -I flag is Task 3's addition (see the
                // GGML_USE_VULKAN comment above). Uses Homebrew's `opt/`
                // symlink (not the versioned Cellar path the throwaway
                // vulkan-spike package used) so this doesn't break on the
                // next `brew upgrade`; resolves to the same files the spike
                // proved work. (The `-fno-objc-arc` flag this list used to
                // carry existed only for the now-excluded Metal .m sources
                // — ggml-metal-context.m/ggml-metal-device.m — and has been
                // dropped along with them; no other .m/.mm sources remain
                // in this target.)
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-I/usr/local/opt/vulkan-headers/include",
                ]),
            ],
            cxxSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                // See the GGML_USE_VULKAN comment in cSettings above.
                .define("GGML_USE_VULKAN"),
                .define("GGML_VERSION", to: "\"080bbbe8\""),
                .define("GGML_COMMIT", to: "\"080bbbe85230f624f0b52127f1ae1218247989f9\""),
                .define("WHISPER_VERSION", to: "\"080bbbe8\""),
                .headerSearchPath("."),
                .headerSearchPath("ggml-cpu"),
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                    "-I/usr/local/opt/vulkan-headers/include",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                // Vulkan/MoltenVK (Task 3 of the intel-mac-vulkan-backend
                // plan; Task 5 removed the Metal/MetalKit frameworks this
                // list used to also link, now that Metal has been replaced
                // by Vulkan as the GPU backend). Frameworks + libraries
                // below are the exact set vulkan-spike/Package.swift proved
                // sufficient for statically-linked MoltenVK on this
                // machine: `otool -L` on the spike's built binary showed
                // only these system frameworks plus libc++/libobjc/
                // libSystem — no Homebrew dylib paths — and the binary ran
                // correctly with Homebrew's Vulkan install hidden,
                // confirming no runtime dependency on it. IOSurface/IOKit/
                // AppKit/QuartzCore/CoreFoundation/CoreGraphics are
                // additional to the Accelerate/Foundation frameworks
                // above.
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("objc"),
                .linkedLibrary("c++"),
                // Statically link MoltenVK itself (the actual Vulkan
                // implementation) rather than -lMoltenVK/-lvulkan, which
                // would resolve to Homebrew's dylibs and the Vulkan
                // loader/ICD mechanism at runtime. Passing the .a path
                // directly avoids any ambiguity between the .a and .dylib
                // Homebrew installs side by side in the same lib dir. Uses
                // Homebrew's `opt/` symlink rather than the versioned
                // Cellar path vulkan-spike/Package.swift used, for the same
                // brew-upgrade-resilience reason as the cSettings -I flag
                // above; resolves to the identical file the spike proved
                // works (confirmed via `ls -l`/`lipo -info` on the real Mac).
                .unsafeFlags([
                    "/usr/local/opt/molten-vk/lib/libMoltenVK.a",
                ]),
            ]
        ),
        .executableTarget(
            name: "Parakey",
            dependencies: ["whisper_cpp"]
            // No `resources:` here on purpose. SwiftPM bundles them as
            // a `<Package>_<Target>.bundle` directory next to the
            // executable, which `codesign --deep` won't accept as a
            // signable component because it lacks Info.plist. Instead,
            // the menubar PNGs are copied into Contents/Resources/ by
            // dev-run.sh and ship-swift.sh — the canonical .app layout
            // where Bundle.main finds them via the standard search
            // path. Source PNGs live in swift/Resources/ at the repo
            // root, NOT in the SwiftPM target, so SwiftPM never sees them.
        ),
    ],
    cLanguageStandard: .c17,
    cxxLanguageStandard: .cxx17
)
