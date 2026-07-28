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
            name: "parakeet_cpp",
            // No excludes: unlike whisper_cpp's ggml-cpu tree, non-x86 arch
            // variants were already stripped by scripts/vendor-parakeet-cpp.sh
            // at vendor time (see that script's `rm -rf` block), so nothing
            // needs excluding here at the SwiftPM level. amx/ is kept
            // in-tree and compiled (ggml-cpu.cpp calls
            // ggml_backend_amx_buffer_type()/ggml_cpu_has_amx_int8()
            // unconditionally — same as this fork's already-proven
            // whisper_cpp target, which also compiled it in unguarded);
            // its actual AMX codegen paths stay inert without
            // __AMX_INT8__/__AVX512VNNI__, which this target does not
            // define.
            cSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_USE_LLAMAFILE"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_VERSION", to: "\"0.13.0\""),
                .define("GGML_COMMIT", to: "\"e705c5fed490514458bdd2eaddc43bd098fcce9b\""),
                .define("PARAKEET_VERSION", to: "\"0.0.1\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml-cpu"),
                // Same Intel-ISA flags this fork already carries for
                // whisper_cpp's ggml build (see git history / the removed
                // whisper_cpp target this replaces) — proven on the real
                // target machine (Intel Xeon E5-2678 v3).
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                ]),
            ],
            cxxSettings: [
                .define("GGML_USE_ACCELERATE"),
                .define("GGML_USE_CPU"),
                .define("GGML_USE_BLAS"),
                .define("GGML_USE_LLAMAFILE"),
                .define("GGML_BLAS_USE_ACCELERATE"),
                .define("ACCELERATE_NEW_LAPACK"),
                .define("ACCELERATE_LAPACK_ILP64"),
                .define("GGML_VERSION", to: "\"0.13.0\""),
                .define("GGML_COMMIT", to: "\"e705c5fed490514458bdd2eaddc43bd098fcce9b\""),
                .define("PARAKEET_VERSION", to: "\"0.0.1\""),
                .headerSearchPath("upstream"),
                .headerSearchPath("upstream/include"),
                .headerSearchPath("upstream/ggml-cpu"),
                .unsafeFlags([
                    "-mavx2", "-mfma", "-mf16c", "-mbmi2", "-msse4.2",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "Parakey",
            dependencies: ["parakeet_cpp"]
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
