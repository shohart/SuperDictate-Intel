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
            ],
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                // Metal backend is REGISTERED here so it shows up in
                // ggml_backend_reg_count()/whisper_print_system_info(),
                // but it is NOT enabled by default: WhisperEngine.init
                // hardcodes params.use_gpu = false, so ggml never
                // actually schedules work on it until a later task adds
                // a user-facing toggle. GGML_METAL_EMBED_LIBRARY matches
                // the pre-generated ggml-metal-embed.cpp checked in by
                // scripts/vendor-whisper-cpp.sh (see that script for why
                // the shader is embedded as a C string instead of a
                // SwiftPM resource/build step).
                .define("GGML_USE_METAL"),
                .define("GGML_METAL_EMBED_LIBRARY"),
                .define("GGML_VERSION", to: "\"080bbbe8\""),
                .define("GGML_COMMIT", to: "\"080bbbe85230f624f0b52127f1ae1218247989f9\""),
                .define("WHISPER_VERSION", to: "\"080bbbe8\""),
                .headerSearchPath("."),
                .headerSearchPath("ggml-cpu"),
                // ggml-metal-context.m/ggml-metal-device.m are upstream
                // Objective-C written for manual retain/release (they
                // guard their explicit `release` calls with
                // `#if !__has_feature(objc_arc)` and cast raw `void *`
                // Metal handles to `id<...>` without `__bridge`).
                // SwiftPM compiles .m sources under ARC by default, which
                // makes both of those patterns compile errors, so ARC is
                // disabled for the whole target to match upstream's own
                // (non-ARC) build. Harmless no-op for the plain C/C++
                // sources also built with these flags.
                .unsafeFlags(["-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2", "-fno-objc-arc"]),
            ],
            cxxSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                // See the matching comment in cSettings above.
                .define("GGML_USE_METAL"),
                .define("GGML_METAL_EMBED_LIBRARY"),
                .define("GGML_VERSION", to: "\"080bbbe8\""),
                .define("GGML_COMMIT", to: "\"080bbbe85230f624f0b52127f1ae1218247989f9\""),
                .define("WHISPER_VERSION", to: "\"080bbbe8\""),
                .headerSearchPath("."),
                .headerSearchPath("ggml-cpu"),
                .unsafeFlags(["-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
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
