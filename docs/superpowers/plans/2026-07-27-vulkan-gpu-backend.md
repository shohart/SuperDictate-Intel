# Vulkan GPU Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the existing, unreliable Metal GPU backend with ggml's Vulkan backend (run via MoltenVK, a Vulkan-to-Metal translation layer), which a real-hardware feasibility investigation and a follow-up SwiftPM integration spike both confirmed produces correct, faster transcription on the target hardware (AMD Radeon RX 6600) with genuine GPU engagement — unlike Metal, which has a confirmed, root-caused, unresolved reliability bug on this GPU (ggml-metal's `has_simdgroup_mm` capability check is gated behind `MTLGPUFamilyApple7`, an Apple-Silicon-only family, so Metal silently reports no support for `GGML_OP_FLASH_ATTN_EXT` on this AMD card and the scheduler falls most attention compute back to CPU/BLAS across a non-unified-memory boundary — the likely source of the intermittent corruption).

**Architecture:** Vendor ggml-vulkan into the `whisper_cpp` SwiftPM target (parallel to the existing ggml-blas/ggml-metal vendoring), statically link `libMoltenVK.a` (proven at the spike to expose the Vulkan C ABI directly with no ICD-loader/Homebrew-path runtime dependency), embed the compiled SPIR-V shader corpus as raw binary files copied into the app bundle's `Contents/Resources/` at build time (NOT via SwiftPM's `resources:` mechanism — Package.swift already documents that this breaks `codesign --deep`), and change the existing "Use GPU" setting so it drives Vulkan instead of Metal. Metal's vendored code and Task 3/4's implementation stay in git history but are removed from the active build — this project targets AMD GPUs on Intel Macs specifically, where Vulkan-via-MoltenVK has now been shown to work better than Metal, and maintaining two GPU backends only multiplies test surface for no benefit.

**Tech Stack:** Swift 6 / SwiftPM, vendored ggml-vulkan C++/GLSL→SPIR-V sources, MoltenVK (Homebrew `molten-vk` package, statically linked via `libMoltenVK.a`), `glslc`/`vulkan-shaders-gen` (Homebrew `shaderc` + the upstream ggml shader-generator tool) for one-time SPIR-V compilation at vendor time.

## Global Constraints

- Pinned whisper.cpp/ggml commit stays `080bbbe85230f624f0b52127f1ae1218247989f9` — vendor ggml-vulkan from the exact same commit as everything else already vendored, never a different one.
- **Never use SwiftPM's `resources:` target parameter.** `swift/Package.swift`'s `Parakey` target has a standing comment explaining why: SwiftPM bundles declared resources as a `<Package>_<Target>.bundle` directory next to the executable, which `codesign --deep` refuses to sign because it lacks an `Info.plist`. The existing PNG resources are instead copied into `Contents/Resources/` directly by `scripts/build-app.sh` (see its `cp` lines copying `swift/Resources/*.png`) — follow this exact established pattern for the SPIR-V shader files: check them into the repo (NOT inside a SwiftPM target's resource-eligible path — keep them under `swift/Sources/whisper_cpp/vulkan-shaders/` or similar, loaded by explicit file path from Swift/C++ code, never auto-discovered by SwiftPM as a resource), and add a `cp`/`ditto` step to `scripts/build-app.sh` that copies them into the built `.app`'s `Contents/Resources/`.
- **Homebrew's `libMoltenVK.a` (from `brew install molten-vk`) is x86_64-only** (confirmed via `otool -l` at the spike — no arm64 slice). This is fine: this project targets Intel Macs exclusively (Apple Silicon Macs already have FluidAudio/Parakeet on ANE via the upstream, unmodified SuperDictate) — do not add arm64 handling for this dependency.
- The spike proved `libMoltenVK.a` links the Vulkan C ABI directly with **zero runtime dependency on Homebrew-installed paths or an ICD JSON** — verified by temporarily hiding the Homebrew Vulkan install and confirming the statically-linked spike binary still worked. Any implementation that reintroduces a dependency on `/usr/local/opt/vulkan-loader/...` or similar Homebrew absolute paths at **runtime** (build-time linking against Homebrew's `.a`/headers is fine and expected) is a regression from what the spike validated — the shipped app must not require end users to install Homebrew/Vulkan SDK.
- **Do not use SwiftPM `resources:` or a build-time `glslc` toolchain dependency for shipped builds.** The spike measured the full shader corpus (168 `.comp` source files → 1785 SPIR-V variants) at 48MB raw binary — compile it ONCE via `scripts/vendor-whisper-cpp.sh` (using the real upstream `vulkan-shaders-gen` tool, exactly as the spike did to produce a working `cpy_f32_f32.spv`) and check the resulting `.spv` binaries into the repo, the same "compile once, check in, no build-time toolchain dependency" philosophy already used for Metal's embedded shader library. Do NOT re-encode the 48MB as C++ literal source (the spike measured this at 191MB of generated `.cpp` — too large and slow to compile) — load the raw `.spv` files from disk at runtime instead (see Task 2).
- Vulkan (GPU) support must remain strictly opt-in, matching the existing "Use GPU" setting's default-off behavior — this plan changes what the toggle *does* (drives Vulkan, not Metal) but not its default state or its opt-in nature.
- **Apply Task 3's lazy-initialization lesson.** The original Metal vendoring shipped with `ggml_backend_metal_reg()` eagerly compiling the entire embedded shader library (~33s) at backend-*registration* time (triggered by every model load, regardless of `use_gpu`), which was found in code review to violate the "opt-in, no default-behavior-change" constraint and had to be fixed in a dedicated follow-up commit deferring the compile into `ggml_metal_device_get_library()` (lazy, only reached when a device is actually scheduled for compute). Before wiring up Vulkan's registration, explicitly check whether `ggml_backend_vk_reg()`/the Vulkan device-init path in the vendored `ggml-vulkan.cpp` has the same eager-cost problem (SPIR-V shader module creation, `vkCreateInstance`/`vkCreateDevice` calls, etc. all happening at registration vs. at first actual use) and apply the same lazy-deferral fix if needed — do not repeat this mistake.
- Never touch `/Applications/SuperDictate.app` or the live LaunchAgent during development/testing — all testing happens via fresh scratch builds on the real Intel Mac (`shohart@192.168.1.246`, password `n0tn33d3d`, reachable via `sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 '<command>'`).
- Run builds as single synchronous foreground SSH commands with generous timeouts (5-10 minutes) — never background a build and poll separately. This wasted enormous time/tokens across multiple prior tasks in this project.
- Only use debug builds (`swift build`/`swift run`, never `-c release`) for iteration and self-tests — a prior task's implementer accidentally triggered the app's real control-panel startup (spawning a stray `--agent` daemon) by running a release build's `--self-test` flag, which is compiled out (`#if DEBUG`-gated) in release.
- The spike's proof-of-concept code lives at `vulkan-spike/` (a separate SwiftPM package, isolated deliberately — SwiftPM 6 builds every `executableTarget` on a bare `swift build` regardless of `products:` declarations, so nesting it inside the real package would make `scripts/build-app.sh`'s `swift build -c release` try to build it too and fail on machines without the exact spike's hardcoded paths). Reference it for working code (Vulkan instance/device creation, SPIR-V loading, static MoltenVK linking) but do not ship it — delete `vulkan-spike/` once its lessons are absorbed into the real `whisper_cpp` target (Task 5).

---

### Task 1: Vendor ggml-vulkan sources and pre-compile the SPIR-V shader corpus

**Files:**
- Modify: `scripts/vendor-whisper-cpp.sh`
- Create (via the vendoring script, not by hand): `swift/Sources/whisper_cpp/ggml-vulkan.cpp` (or whatever the pinned commit's main Vulkan backend source file is named — confirm exact filename from the pinned commit's `ggml/src/ggml-vulkan/` directory), supporting headers, and `swift/Sources/whisper_cpp/vulkan-shaders/*.spv` (the pre-compiled SPIR-V binaries).

**Interfaces:**
- Produces: vendored ggml-vulkan C++ source compiled into the `whisper_cpp` target (Task 5 wires this into `Package.swift`), plus a checked-in directory of `.spv` binary files the vendored source loads by file path at runtime (Task 2 implements the loading mechanism, since upstream's default embedding is a C-array/CMake-orchestrated scheme this project can't use per the Global Constraints).
- Consumes: the pinned whisper.cpp commit `080bbbe85230f624f0b52127f1ae1218247989f9`'s `ggml/src/ggml-vulkan/` directory, and the `vulkan-shaders-gen` tool from that same directory (a small C++ program upstream's CMake build compiles and runs to turn `.comp` GLSL sources into `.spv` via `glslc`, the same mechanism validated at `/tmp/whispercpp_bench/build_vulkan_test` on the real Mac during the feasibility investigation, and again at the spike for a single real shader, `cpy_f32_f32.spv`).

- [ ] **Step 1: Inspect the pinned commit's ggml-vulkan layout and confirm the exact source file list**

On the real Mac (or via a fresh local clone at the pinned commit, whichever is faster), inspect `ggml/src/ggml-vulkan/`. Identify: the main backend `.cpp` file(s), any headers, and the `vulkan-shaders/` subdirectory containing the 168 `.comp` GLSL source files and the `vulkan-shaders-gen.cpp` generator tool. Cross-reference against `/tmp/whispercpp_bench/build_vulkan_test` on the Mac (already built successfully during the feasibility investigation) and `vulkan-spike/` in this worktree (already proved the generator tool and a real shader compile end-to-end) — both are working references for exactly which files/commands are needed; don't rediscover this from scratch.

- [ ] **Step 2: Update `scripts/vendor-whisper-cpp.sh` to copy ggml-vulkan's C++ sources**

Follow this script's existing pattern exactly (read the whole script first — it already has a documented, presence-checked approach for Metal's source patches and the `ggml-blas.cpp` addition). Add copying of the main ggml-vulkan backend source(s) and headers identified in Step 1, alongside the existing ggml-blas/ggml-metal copies. Do NOT copy the `.comp` GLSL sources or `vulkan-shaders-gen.cpp` into the SwiftPM target's source tree (they're build-time-only tools, not compiled into the app) — Step 3 handles shader compilation as a separate vendoring sub-step, not as part of the normal per-file copy loop.

- [ ] **Step 3: Add SPIR-V pre-compilation to the vendoring script**

Add a script section (clearly commented, following the Global Constraints' "compile once, check in" requirement) that: builds the upstream `vulkan-shaders-gen` tool from the pinned commit's source (requires `glslc` on the machine running the vendor script — the real Mac already has this via `brew install shaderc` from the feasibility investigation; document this prerequisite in the script's header comment), runs it to compile all `.comp` shaders into `.spv` files, and copies the resulting `.spv` binaries into `swift/Sources/whisper_cpp/vulkan-shaders/` (a plain directory of binary files, NOT inside anything SwiftPM would treat as a `resources:`-eligible path — confirm this by checking that `Package.swift`'s `whisper_cpp` target has no `resources:` parameter referencing this directory, per the Global Constraints). Reuse the exact command sequence already proven working in `vulkan-spike/`'s commits and at `/tmp/whispercpp_bench/build_vulkan_test` — don't reinvent this.

- [ ] **Step 4: Run the vendoring script on the real Mac and verify output**

Run the updated `scripts/vendor-whisper-cpp.sh` via SSH on the real Mac (it needs network access to clone whisper.cpp, and the Homebrew Vulkan toolchain already installed there from the feasibility investigation). Confirm: the ggml-vulkan `.cpp`/`.h` files appear under `swift/Sources/whisper_cpp/`, and `swift/Sources/whisper_cpp/vulkan-shaders/` contains the expected `.spv` files (spot-check the total size is in the same ballpark as the spike's measured 48MB, and that a handful of files are non-empty valid SPIR-V — `file` or a hex-dump magic-number check, SPIR-V binaries start with the magic number `0x07230203`).

- [ ] **Step 5: Commit**

```bash
git add scripts/vendor-whisper-cpp.sh swift/Sources/whisper_cpp/
git commit -m "Vendor ggml-vulkan backend sources and pre-compiled SPIR-V shader corpus"
```

---

### Task 2: Implement SPIR-V loading from bundled resource files

**Files:**
- Modify: the vendored ggml-vulkan source (from Task 1) — specifically wherever it currently expects embedded/compiled-in shader byte arrays.
- Create: a small shim (in whichever vendored file is cleanest, or a new small `.cpp`/`.h` pair alongside the vendored sources — use judgment) that resolves the runtime path to `Contents/Resources/vulkan-shaders/` and loads each `.spv` file into memory as ggml-vulkan expects it.

**Interfaces:**
- Consumes: `swift/Sources/whisper_cpp/vulkan-shaders/*.spv` (Task 1's output), and whatever function signature the vendored ggml-vulkan code calls to obtain each shader's SPIR-V bytecode (upstream's default is a generated header with `unsigned char shader_name_data[] = {...}` arrays — Task 1/2 together replace this with a runtime file-read).
- Produces: a working shader-loading path that Task 5's full build will exercise end-to-end.

- [ ] **Step 1: Identify exactly how upstream ggml-vulkan consumes compiled shaders**

Read the vendored `ggml-vulkan.cpp` (from Task 1) to find where it references shader bytecode — likely a call like `ggml_vk_create_pipeline(..., shader_name_data, shader_name_len, ...)` or similar, generated per-shader by `vulkan-shaders-gen`'s default C-array-header output mode. Check whether `vulkan-shaders-gen` has a documented alternate output mode that writes raw `.spv` files instead of C headers (the spike may have already used one — check `vulkan-spike/`'s commits and `scripts/spike-embed-spirv.sh` if it exists from the spike, for the exact invocation used there).

- [ ] **Step 2: Implement the runtime loader**

Write a small function (e.g. `std::vector<uint32_t> load_spirv_shader(const std::string & name)`) that: resolves the app bundle's `Contents/Resources/vulkan-shaders/<name>.spv` path at runtime (for the shipped app) with a fallback to a path relative to the built binary for debug/dev builds (check how the existing PNG-resource-loading code in `main.swift`, if any, resolves `Contents/Resources/` paths via `Bundle.main`, and mirror that pattern from the C++ side — likely via `NSBundle`/`CFBundle` APIs callable from Objective-C++, or by having Swift resolve the path and pass it down to the C++ layer through a new small bridging function, whichever fits this codebase's existing whisper_cpp/Swift boundary better), reads the file, and returns its bytes. Patch the vendored ggml-vulkan source's shader-pipeline-creation call sites (identified in Step 1) to call this loader instead of referencing a generated C array.

- [ ] **Step 3: Build and smoke-test on the real Mac**

This task's own build won't compile standalone yet (Package.swift isn't updated until Task 5) — coordinate with whoever picks up Task 5 next, or (preferred, to keep this task independently verifiable) temporarily wire a minimal test harness reusing `vulkan-spike/`'s existing SwiftPM package structure (which already proves static MoltenVK linking and SPIR-V loading work) to exercise this task's loader function specifically, confirming it can locate and load at least one real `.spv` file from Task 1's output using the resolved-path logic from Step 2, before Task 5 does the full integration. Never touch `/Applications/SuperDictate.app`.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/whisper_cpp/
git commit -m "Load Vulkan SPIR-V shaders from bundled resource files at runtime"
```

---

### Task 3: Statically link MoltenVK and add Vulkan build configuration to Package.swift

**Files:**
- Modify: `swift/Package.swift`

**Interfaces:**
- Produces: the `whisper_cpp` target compiles with `GGML_USE_VULKAN` (or whatever define the pinned commit's ggml-vulkan code expects — confirm exact name from Task 1's source inspection) and links `libMoltenVK.a` statically, plus any Vulkan headers needed at compile time (Homebrew's `vulkan-headers` package, already installed on the Mac from the feasibility investigation).
- Consumes: Task 1's vendored sources, the spike's (`vulkan-spike/Package.swift`) proven linker-flag pattern for static MoltenVK linking.

- [ ] **Step 1: Read the spike's exact linking configuration**

Read `vulkan-spike/Package.swift` and `vulkan-spike/Sources/VulkanSpike/main.cpp` in full — this is the proven, working reference for exactly which headers, defines, and linker flags make static MoltenVK linking succeed on this machine. Do not guess at flags; transcribe the working configuration.

- [ ] **Step 2: Add Vulkan settings to the `whisper_cpp` target**

Following the exact pattern already used for BLAS/Metal (`cSettings`/`cxxSettings` with `.define(...)`, `.headerSearchPath(...)`, `.unsafeFlags([...])`, and `linkerSettings` with `.linkedFramework(...)`/`.linkedLibrary(...)`/`.unsafeFlags([...])` for the static archive path), add whatever Task 1's vendored ggml-vulkan source needs to compile (its own `GGML_USE_VULKAN`-equivalent define plus any Vulkan-SDK header search paths) and whatever the spike proved necessary to link `libMoltenVK.a` statically (likely an `unsafeFlags` linker argument pointing at the Homebrew-installed static archive's path, plus whatever system frameworks MoltenVK itself depends on — check `otool -L`/`otool -l` on the spike's built binary for the exact list, matching what the spike's report already found: "only system frameworks + libc++/libobjc/libSystem").

- [ ] **Step 3: Build the `whisper_cpp` target alone (not the full app yet) and verify it compiles**

On the real Mac, `swift build --target whisper_cpp --package-path swift` (or equivalent) in a fresh scratch copy. This won't produce a working app yet (Tasks 4-5 wire the rest), but should compile cleanly, proving the Package.swift changes are syntactically and link-time correct in isolation before layering more changes on top.

- [ ] **Step 4: Commit**

```bash
git add swift/Package.swift
git commit -m "Add Vulkan backend build configuration with statically-linked MoltenVK"
```

---

### Task 4: Copy SPIR-V resources into the app bundle at build time

**Files:**
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `swift/Sources/whisper_cpp/vulkan-shaders/*.spv` (Task 1).
- Produces: those files present at `Contents/Resources/vulkan-shaders/` in the built `.app`, matching what Task 2's runtime loader expects to find.

- [ ] **Step 1: Add the resource-copy step**

Following the exact existing pattern for the PNG/icon resources (`cp "$ROOT_DIR/swift/Resources/parakey-menubar.png" "$STAGE_APP/Contents/Resources/"` and neighboring lines), add a step copying the entire `swift/Sources/whisper_cpp/vulkan-shaders/` directory into `$STAGE_APP/Contents/Resources/vulkan-shaders/` (likely `ditto` rather than `cp` for a directory copy — check which this script already uses elsewhere for directory-shaped resources, or use `cp -R` if simpler and consistent with the script's existing style).

- [ ] **Step 2: Verify the codesign step still succeeds**

Run `scripts/build-app.sh` on the real Mac (fresh scratch build, never `/Applications`), confirm the build completes and `codesign --verify`/`codesign -dv` on the resulting `.app` succeeds with the new resource files present — this is the specific failure mode the Global Constraints warn about (SwiftPM's own `resources:` bundling breaks `codesign --deep`), so explicitly confirm this manual-copy approach does NOT hit the same problem.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-app.sh
git commit -m "Copy Vulkan SPIR-V shaders into the app bundle at build time"
```

---

### Task 5: Wire Vulkan into WhisperEngine, replacing Metal; verify lazy initialization

**Files:**
- Modify: `swift/Sources/Parakey/WhisperEngine.swift`
- Modify: `swift/Sources/Parakey/main.swift` (menu label text only, if it currently says "Metal" anywhere — check `buildBehaviorSettingsItem()`'s GPU toggle item text from the prior GPU-toggle plan)
- Delete: `vulkan-spike/` (its lessons are now absorbed into the real target; per Global Constraints, don't ship it)

**Interfaces:**
- Consumes: Task 3's Package.swift changes (ggml-vulkan compiled into `whisper_cpp`), Task 1/2's shader loading.
- Modifies: `WhisperEngine.init(modelPath:useGPU:)`'s existing `params.use_gpu = useGPU` — this doesn't change (whisper.cpp's device-selection logic already picks whichever GPU-type backend is registered; since this task removes Metal's registration and Vulkan's takes its place, `use_gpu = true` now means Vulkan automatically, no new Swift-level API needed) UNLESS Task 1's source inspection found that whisper.cpp needs an explicit backend-type selector when multiple GPU backends could theoretically be registered — confirm this from the vendored `whisper_backend_init_gpu`/`whisper_backend_init` code (already read during the earlier GPU-corruption investigation, at `whisper.cpp:1290-1359`) and handle accordingly.

- [ ] **Step 1: Remove Metal from the active build**

In `swift/Package.swift`, remove `GGML_USE_METAL`/`GGML_METAL_EMBED_LIBRARY` defines and the `Metal`/`MetalKit` linked frameworks from the `whisper_cpp` target (both `cSettings` and `cxxSettings`, and `linkerSettings`). Do NOT delete the vendored Metal source files from `swift/Sources/whisper_cpp/` in this step — leaving them present but uncompiled (simply excluded from the target's active defines/build) keeps the option to re-enable easily later per this plan's stated rationale (git history preserves the code either way; check whether `exclude:` needs updating or whether the files simply stop being referenced/compiled once the defines are gone — match whatever the existing `exclude:` list convention in `Package.swift` already does for the CPU-arch directories).

- [ ] **Step 2: Check for and fix Vulkan's registration-time cost, per the Global Constraints' explicit warning**

Before considering this task done, verify (by reading the vendored `ggml-vulkan.cpp`'s registration/device-init functions, and by testing on real hardware with timing) whether `ggml_backend_vk_reg()` or equivalent eagerly does expensive work (Vulkan instance/device creation, shader module compilation, memory allocation) at backend-*registration* time — i.e., on every `WhisperEngine.init` regardless of `useGPU`, exactly like Task 3's original Metal mistake. If so, apply the same fix pattern Task 3 used for Metal: defer the expensive work into whatever function is only reached when a device is actually selected for compute (`params.use_gpu = true`), not at mere enumeration/registration time. Verify with a timed comparison (a normal `useGPU: false` init before and after this task's changes should show no new startup cost).

- [ ] **Step 3: Update any user-facing "Metal" text to "GPU" or "Vulkan"**

Check `main.swift`'s GPU-toggle menu item (added in the prior GPU-toggle plan, likely titled something like "Use GPU (Metal) — experimental") — update the label to reflect Vulkan instead (or just "Use GPU" if the plan owner prefers not naming the backend in the UI — use judgment, but don't leave stale "Metal" text visible to users).

- [ ] **Step 4: Delete the spike**

```bash
git rm -r vulkan-spike/
```

- [ ] **Step 5: Full build and self-test on the real Mac**

Fresh scratch build (never `/Applications`), `swift build --package-path swift`, `swift run Parakey --self-test all` (debug build only, per Global Constraints) → PASS.

- [ ] **Step 6: Commit**

```bash
git add swift/Package.swift swift/Sources/Parakey/ vulkan-spike/
git commit -m "Wire Vulkan into WhisperEngine, replacing Metal as the GPU backend"
```

---

### Task 6: Real-hardware correctness, reliability, and performance verification

**Files:**
- Test only — no source changes expected unless verification surfaces a defect.
- Modify: `README.md` (document the GPU backend change).

**Interfaces:**
- Consumes: everything from Tasks 1-5.

- [ ] **Step 1: Correctness and reliability — repeat the same rigor as the Metal investigation**

On the real Mac, using the real app's `WhisperEngine.transcribe` path (a benchmark harness reusing the pattern from prior investigation tasks, e.g. `--gpu-bench gpu ru <wav>`, is acceptable and expected — check `/tmp/superdictate-intel-*` scratch dirs on the Mac for reusable harness code before writing new code), run all 3 Russian samples (`/tmp/whispercpp_bench/samples/ru_sample{,2,3}.wav`, forced `lang=ru`, matching production's audio_ctx-trimming behavior) through `useGPU: true` at least 10 times each (30 total), comparing output against the known-correct CPU baselines established throughout this project's history:
  - ru_sample.wav: "Добрый день! Сегодня мы обсудим перенос приложения для диктовки на компьютеры с процессором Intel. Нужно проверить точность распознавания русской речи."
  - ru_sample2.wav: "В понедельник он позвонил мне и предупредил, что встреча переносится на вторник из-за срочной командировки в другой город."
  - ru_sample3.wav: "Она быстро закрыла окно, потому что на улице начался сильный ветер и первые капли осеннего дождя застучали по стеклу."

  Any corruption (hallucination, garbling, wrong words) in ANY of the 30 runs is a blocking finding — stop and report it as such rather than proceeding, per this project's established standard (the Metal investigation treated even intermittent corruption as disqualifying). The spike's smaller-scale testing (5+ runs, no corruption) is encouraging but not sufficient sample size to ship on.

- [ ] **Step 2: Real GPU engagement verification**

Reuse the `ioreg -l | grep -i "GPU Activity\|Device Utilization\|Fan Speed"` polling technique from the earlier investigation to confirm Vulkan shows meaningfully *higher and more sustained* GPU utilization than Metal did (Metal showed sporadic single-digit-to-64% spikes with zero sustained load and no fan response — the spike's Vulkan test showed 43-63% activity with real clock/power ramp, a qualitatively different pattern worth reconfirming on the full app path, not just the spike's isolated shader test).

- [ ] **Step 3: Speed comparison**

Record `encodeSeconds` for all 3 samples on GPU (Vulkan) vs the existing CPU+BLAS baseline, confirming a real, reproducible speedup (the spike measured Vulkan at 5.6-5.8s vs CPU's 8.0s on one sample — confirm this holds across all 3 samples with multiple runs each for noise-averaging, given this project's history of highly variable timing on this particular Mac).

- [ ] **Step 4: First-use cost check**

Time a normal `useGPU: false → true` toggle transition (matching Task 5 Step 2's lazy-init verification, but end-to-end through the real menu toggle path added in the prior GPU-toggle plan) to characterize any first-use Vulkan instance/shader-compile cost the user would actually experience, and note it in the README (Step 5) if non-trivial (Metal's was ~33s of shader compile on first real use — check whether Vulkan has an analogous one-time cost).

- [ ] **Step 5: Update README**

Update the GPU-toggle documentation added in the prior plan to describe Vulkan (not Metal) as the backend, remove any "may produce incorrect transcripts" warning language from that plan IF Step 1's 30-run verification came back clean (replace with accurate, current information — don't leave stale warnings about a backend that's no longer in use, but don't overclaim reliability beyond what Step 1 actually demonstrated either).

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "Document Vulkan as the GPU backend, verified on real hardware"
```
