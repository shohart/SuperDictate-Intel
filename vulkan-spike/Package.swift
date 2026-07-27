// swift-tools-version: 6.0
//
// VulkanSpike — a fully separate, throwaway SwiftPM package for the
// intel-mac-vulkan-backend spike. Deliberately NOT a target inside
// swift/Package.swift: SwiftPM 6 builds every executableTarget by
// default on a bare `swift build` regardless of whether it's listed in
// `products`, so nesting this inside the real package would mean
// scripts/build-app.sh (which runs a bare `swift build -c release`)
// and any plain `swift build` in swift/ would try to build this too —
// and hard-fail on any machine that doesn't have the exact Homebrew
// Cellar paths below (e.g. the Apple Silicon dev machine, which uses
// /opt/homebrew, not /usr/local; or this same Intel Mac after a `brew
// upgrade` bumps the pinned version directories). Keeping it in its own
// package directory means it is only ever built by explicitly running
// `swift build` from inside vulkan-spike/ — it cannot be reached from
// the app's normal build path.
//
// Delete this whole directory once the spike's findings are folded into
// a real implementation plan; nothing else in the repo references it.
import PackageDescription

let package = Package(
    name: "VulkanSpike",
    platforms: [
        .macOS("14.0"),
    ],
    targets: [
        // Header/lib search paths point at this dev machine's Homebrew
        // Cellar (vulkan-headers, molten-vk) — fine for a throwaway spike
        // package that is never part of the app's build graph. A real
        // implementation should vendor the small set of needed Vulkan
        // headers instead of reaching into /usr/local/Cellar at build
        // time (see swift/Sources/whisper_cpp for the vendoring
        // precedent), and would need a build-machine-independent way to
        // locate libMoltenVK.a (Homebrew prefix differs between Intel
        // /usr/local and Apple Silicon /opt/homebrew, and this .a is
        // x86_64-only — see the spike's final report for the arm64
        // universal-binary implication).
        .executableTarget(
            name: "VulkanSpike",
            cxxSettings: [
                .unsafeFlags([
                    "-I/usr/local/Cellar/vulkan-headers/1.4.350.1/include",
                ]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedLibrary("objc"),
                .linkedLibrary("c++"),
                // Statically link MoltenVK itself (the actual Vulkan
                // implementation) rather than -lMoltenVK/-lvulkan, which
                // would resolve to Homebrew's dylibs and the Vulkan
                // loader/ICD mechanism at runtime. Passing the .a path
                // directly avoids any ambiguity between the .a and .dylib
                // Homebrew installs side by side in the same lib dir.
                .unsafeFlags([
                    "/usr/local/Cellar/molten-vk/1.4.2/lib/libMoltenVK.a",
                ]),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
