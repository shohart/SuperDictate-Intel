# Phase 5 — Vulkan add-on, integrated and verified on real hardware

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`, Phase 5
(Checkpoint D). Spec: `docs/parakeet-intel-backend.md` §6.3, §6.4, §9.1,
§9.3, §11.2-§11.4. Builds directly on the Phase 5 pre-spike report
(`phase-5-vulkan-prespike-report.md`) and Phase 3's CPU-only integration
(`phase-3-integration-report.md`). Everything below that claims to be
verified ran for real on the Intel Mac (`shohart@192.168.1.246`: Intel
Xeon E5-2678 v3, AMD Radeon RX 6600, macOS 15.7.7, x86_64), synced from
this worktree via `git archive | ssh ... tar -x` into
`~/scratch/parakeet-phase5/repo`, matching this project's established
methodology.

## 1. What was built

- **`scripts/vendor-parakeet-cpp.sh`** extended with `vendor_vulkan_backend()`:
  copies `ggml-vulkan.cpp`/`.h` unconditionally, and — only when `cmake`
  and `glslc` are on `PATH` — runs parakeet.cpp's own unmodified upstream
  CMake build (`-DPARAKEET_GGML_VULKAN=ON`, the exact pre-spike-proven
  configuration) far enough to build the `ggml-vulkan` target, harvests the
  real compiled `.spv` corpus that build produces as a byproduct, invokes
  the same built `vulkan-shaders-gen` tool once more in "aggregate" mode to
  get a ground-truth header of shader symbol names, and runs
  `scripts/gen-vulkan-shader-runtime.py` against it to produce a runtime
  loader header/cpp pair.
- **`scripts/vulkan-shader-runtime/`** (new, hand-authored, not vendored
  from upstream): `ggml-vulkan-shaders-runtime.h`/`.cpp`, a lazy
  file-loading proxy layer (`lazy_data`/`lazy_len`) that declares the exact
  same identifier names `ggml-vulkan.cpp`'s macro-generated call sites
  reference, backed by reading `<name>.spv` from disk on first use instead
  of a compiled-in byte array. Copied into the vendored tree by the vendor
  script on every run.
- **`scripts/gen-vulkan-shader-runtime.py`** (new): pure text-parsing
  generator that turns `vulkan-shaders-gen`'s own aggregate-mode header
  output into the runtime-loader header/cpp pair above.
- **`swift/Package.swift`**: `parakeet_cpp` target gets `GGML_USE_VULKAN`,
  a Homebrew `vulkan-headers` include path, an exclude entry for the loose
  `.spv` corpus (never through SwiftPM `resources:`), and static MoltenVK
  linking (`/usr/local/opt/molten-vk/lib/libMoltenVK.a` passed directly as
  a linker flag) plus the IOSurface/IOKit/AppKit/QuartzCore/
  CoreFoundation/CoreGraphics frameworks + `objc`/`c++` libs — mirroring
  the deleted `whisper_cpp` target's proven approach exactly (`git show
  1bb8ae4^:swift/Package.swift`).
- **C bridge** (`superdictate_parakeet.h`/`.cpp`): `sd_parakeet_create` now
  sets `PARAKEET_DEVICE` (the env var parakeet.cpp's `pk::Backend` reads at
  construction) before loading the model, and does a cheap
  `sd_parakeet_vulkan_available()` registry probe up front so a
  Vulkan-on-CPU-only-build request fails immediately without even
  attempting a load. `sd_parakeet_warm_up` performs the **mandatory
  post-init device check** the pre-spike flagged as missing: after forcing
  one real inference (which is what actually constructs parakeet.cpp's
  process-global compute backend — see §2 below), it reads the backend's
  real device name and, if Vulkan was requested but the name doesn't start
  with `"Vulkan"`, treats it as a hard `SD_PARAKEET_ERR_VULKAN_UNAVAILABLE`
  failure (not a silent CPU success) and calls `pk::shutdown_backend()` so
  a subsequent CPU context in the same process gets a clean construction.
  Added `sd_parakeet_backend_device_name()`, `sd_parakeet_vulkan_available()`,
  `sd_parakeet_vulkan_device_description()` (all registry-based, zero
  IOKit, zero side effects relative to model loading), and a test-only
  `sd_parakeet_test_reset_backend()` hook (ended up unused by the final
  self-test — see §5).
- **`ParakeetEngine.swift`**: `device: ParakeetDevice` now actually reaches
  the bridge; `.vulkanFellBackToCPU` is a distinct error case from
  `.vulkanUnavailable`; `warmUp()` records `actualDeviceName` and surfaces
  the post-init check's failure; `configureVulkanShaderDirectoryIfPresent()`
  points the C++ runtime shader loader at `Contents/Resources/vulkan-shaders`
  before any Vulkan context is ever requested, guarded by an existence
  check (unconditional would break the dev-build fallback, the same
  regression this fork already hit once for whisper.cpp).
- **`TranscriptionWorker` (`main.swift`)**: `load()` implements the full
  spec §9.1 algorithm — read the GPU preference, skip Vulkan entirely if it
  already failed once this session, attempt Vulkan with a 30s warm-up
  timeout (`withTimeout`, new `TaskGroup`-based helper), on ANY failure
  destroy the partial attempt and build a fresh CPU engine + CPU warm-up,
  record the fallback reason, never retry Vulkan again this session, never
  mutate the persisted preference. `transcribe()` adds the §9.3 mid-session
  path: a Vulkan engine that initialized fine but fails during a real
  transcription retains the captured PCM, destroys the Vulkan engine,
  builds + warms a fresh CPU engine, and retries the SAME dictation once on
  CPU. A new `ParakeetRuntimeStatus` enum + `ParakeetRuntimeStatusCache`
  (thread-safe, updated on every status change) back the exact §11.4
  status strings (RU+EN) for synchronous UI reads. The "Use GPU (Vulkan)"
  menu item is now localized (RU/EN) and disabled with an explanatory
  tooltip when `parakeetVulkanAvailable()` returns false; a new "ASR
  backend: ..." line was added to both the menu and `diagnosticsText()`.
  A `parakeet-vulkan` self-test group (env-gated, real hardware) and a
  `parakeet-vulkan-bench` group (§8 below) were added.
- **`scripts/build-app.sh`**: copies the vendored `vulkan-shaders/`
  directory into `Contents/Resources/vulkan-shaders` so `codesign --deep`
  covers it.
- **README.md** updated with the real measured table (§8) and the real
  disabled/localized checkbox behavior, replacing the "not wired yet"
  placeholder text Phase 6's report confirmed was still accurate before
  this phase.

## 2. The device-selection-safety fix, and how it was actually proven

The pre-spike's central finding was that `pk::Backend::Backend()` silently
falls back to CPU when a requested `PARAKEET_DEVICE` name isn't found,
logging a line but returning success. Tracing `backend.cpp`/`ggml_graph.cpp`
directly (not from memory) surfaced the exact mechanism this bridge now
exploits and had to respect:

- `pk::global_backend()` is a **lazily-created, process-lifetime singleton**
  (`ggml_graph.cpp`'s `g_backend`), constructed on the FIRST graph compute
  performed by ANY context in the process — not at model load time. Once
  constructed, it stays alive and is **not reconstructed** on a later
  request with a different `PARAKEET_DEVICE`, unless `pk::shutdown_backend()`
  is called first (its own doc comment: "a later `global_backend()` call
  recreates it").
- This directly resolves what the advisor flagged as the blocking design
  question for Phase 5 (can CPU fallback happen in-process at all, or does
  the process commit to a device forever): yes, in-process fallback is
  possible, via `shutdown_backend()`, and the bridge's `sd_parakeet_warm_up`
  now calls it exactly once, on the one path where it matters (a detected
  Vulkan-fell-back-to-CPU failure).
- This same singleton behavior is what made the `parakeet-vulkan` self-test
  genuinely tricky to get right (see §5) — a real, previously-hit bug in
  this phase's own test development, not just theory.

**Proof the fix works, from real log output** (debug build,
`--self-test parakeet-vulkan`, `SD_PARAKEET_TEST_FORCE_DEVICE_NAME`
requesting a nonexistent device name):

```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon RX 6600 (MoltenVK) | ...
register_device: registered device Vulkan0 (AMD Radeon RX 6600)
[parakeet] pk::Backend: PARAKEET_DEVICE=Vulkan9-does-not-exist not found; falling back to CPU
```
followed by the Swift-level assertion passing:
```
threwFellBackToCPU == true
```
i.e. the bridge's post-init check caught upstream's own silent fallback and
turned it into `ParakeetEngineError.vulkanFellBackToCPU`, exactly as
required — never a silent "GPU success" report.

## 3. Shader-shipping mechanism: two attempts, second one used

**First attempt (superseded): embedded C arrays.** Following the pre-spike's
observation that ggml v0.13.0's own CMake path defaults to compiling SPIR-V
straight into C arrays, the first vendor run generated and checked in that
shape. It worked (compiled, linked, real Vulkan inference ran correctly on
the RX 6600) but produced **~230MB of generated C++ source** for the full
shader corpus.

**Second attempt (used): loose `.spv` + runtime loader, matching this
fork's own whisper.cpp precedent exactly.** Re-reading this fork's own git
history (`b0ab800` "Load Vulkan SPIR-V shaders from bundled resource files
at runtime", plus follow-up fixes `5e11856`/`14efc8d`) showed this fork
already solved the identical problem for whisper.cpp's Vulkan backend, and
had already measured the loose-`.spv` shape at only 48MB for 1785 files —
a clear, concrete reason to prefer it over the embedded-array shape's
230MB, contra this agent's own earlier assumption that embedding would be
"simpler." The mechanism (ported essentially unmodified, since parakeet's
pinned ggml v0.13.0 uses the identical `vulkan-shaders-gen.cpp` shape as
whisper's ggml vintage did):
- `vulkan-shaders-gen`'s `write_output_files()` always declares every
  shader symbol as `extern const uint64_t <name>_len;`/`extern const
  unsigned char <name>_data[];`, and only *emits byte data* into the paired
  `.cpp` when `--source` is given — so one extra invocation with no
  `--source` produces a header with the ground-truth symbol names and zero
  byte data.
- `scripts/gen-vulkan-shader-runtime.py` turns that ground-truth header
  into a drop-in replacement declaring the SAME identifier names, backed by
  `lazy_data`/`lazy_len` proxy objects that read `<name>.spv` from disk on
  first use. **`ggml-vulkan.cpp` itself needs zero source edits** — its own
  `#include "ggml-vulkan-shaders.hpp"` resolves to this generated
  substitute by filename alone.
- Result: **2202 loose `.spv` files, 60MB**, checked in under
  `swift/Sources/parakeet_cpp/upstream/ggml-vulkan/vulkan-shaders/` —
  matching the whisper.cpp precedent's order of magnitude almost exactly
  (that repo's own comment in the ported generator predicted "154 top-level
  `.comp` files expand to several hundred typed/quantization variants";
  the actual count landed at 2202, close to the pre-spike's own
  independent observation of "2203 .spv intermediate files").

One real friction point building this: Swift's Clang importer, which
compiles `parakeet_cpp_module.h` (the SwiftPM umbrella header) as its own
module-compilation unit, does **not** honor `Package.swift`'s
`headerSearchPath` entries for that specific compilation the way normal
C/C++ translation units in the target do — confirmed empirically after the
first `swift build` attempt failed with `'ggml-vulkan-shaders-runtime.h'
file not found` despite the same search path resolving fine for
`ggml-vulkan.cpp`'s own identical `#include`. Fixed by placing a second
copy of that header directly in `swift/Sources/parakeet_cpp/include/`
(same directory as the umbrella header, resolved via plain
same-directory quote-include) — the vendor script keeps both copies in
sync on every run.

## 4. Static MoltenVK linking — verified via `otool -L` on the FINAL app binary

`scripts/build-app.sh` release build (`swift build -c release` +
`codesign --deep`), `otool -L` on
`~/scratch/parakeet-phase5/dist/SuperDictate.app/Contents/MacOS/SuperDictate`:

```
/System/Library/Frameworks/Accelerate.framework/...
/System/Library/Frameworks/Foundation.framework/...
/System/Library/Frameworks/IOSurface.framework/...
/System/Library/Frameworks/IOKit.framework/...
/System/Library/Frameworks/AppKit.framework/...
/System/Library/Frameworks/QuartzCore.framework/...
/System/Library/Frameworks/CoreFoundation.framework/...
/System/Library/Frameworks/CoreGraphics.framework/...
/usr/lib/libc++.1.dylib
/usr/lib/libobjc.A.dylib
/usr/lib/libSystem.B.dylib
... (AVFoundation/AudioToolbox/Carbon/CoreAudio/CryptoKit/Metal/
     ServiceManagement/Swift runtime dylibs — all Apple-system or
     Swift-runtime, unrelated to this phase)
```

`grep -iE "usr/local|opt/homebrew|Cellar|libMoltenVK.dylib|libvulkan"` on
that output: **zero matches (CLEAN)**. `codesign --verify --deep --strict`:
**passes**. This confirms the pre-spike's open item (it only verified the
Homebrew-dynamic-linked starting point of a raw CMake build, explicitly
deferring the static-link verification to Phase 5) — the actual SwiftPM
target really does link MoltenVK's static archive directly with no runtime
Homebrew dependency, on the real shipped app binary, not just a debug
build product.

## 5. Forced-CPU-fallback test — real result, and a real bug found while building it

Per the task's request to "temporarily point at a bogus device name to
force the failure path," a `SD_PARAKEET_TEST_FORCE_DEVICE_NAME` bridge hook
was added so a self-test can request a guaranteed-nonexistent device name
(the public `SDParakeetOptions` API has no device-name field — production
always requests `"Vulkan0"`/`"cpu"` — this hook only overrides that inside
`sd_parakeet_create`, and only when set).

**First version of the test failed, honestly, for a real reason**: running
a real-device sub-test followed by a forced-failure sub-test in the SAME
process reused the already-alive process-global backend from the first
sub-test (§2's singleton behavior) — the forced device name was never even
consulted, so the assertion failed not because the safety check is broken,
but because the test's own ordering didn't account for the singleton. Fixed
by reordering: the forced-failure attempt now runs FIRST in a fresh
process, before any real backend exists, and the real-device verification
runs second (parakeet.cpp's own post-init check calls
`pk::shutdown_backend()` on the forced-failure path, so the second
sub-test gets a genuinely fresh construction). This is documented in the
test's own comments as a "gotcha" worth remembering for anyone extending
it later — a small `sd_parakeet_test_reset_backend()` bridge hook was also
added as available infrastructure but ended up unused once the reordering
fix worked.

**Final result** (debug build, `--self-test parakeet-vulkan`, real GGUF
model, real hardware):
```
[parakeet] pk::Backend: PARAKEET_DEVICE=Vulkan9-does-not-exist not found; falling back to CPU
... (bogus attempt correctly throws .vulkanFellBackToCPU)
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon RX 6600 (MoltenVK) | ...
[parakeet] pk::Backend using device: Vulkan0
PARAKEET VULKAN: load 1.36s, device Vulkan0, threads 8, infer 0.273s, RTF 0.546, text="Yeah."
PASS parakeet-vulkan
```
Deterministic recovery to CPU confirmed via the assertion passing; correct
output confirmed on the subsequent real-device attempt in the same run.

## 6. VRAM evidence

`ggml-vulkan`'s own allocator log during a real Vulkan compute pass:
```
ggml_gallocr_reserve_n_impl: reallocating Vulkan0 buffer from size 1.28 MiB to 3.58 MiB
```
This is direct, unambiguous evidence of a real device-side buffer
allocation on `Vulkan0` (the RX 6600), from ggml's own instrumentation, not
inferred. A clean before/after `ioreg -l | grep inUseVidMemoryBytes` delta
(this fork's own established methodology from the Whisper Vulkan work) was
**attempted but not cleanly captured**: the single-shot self-test's real
Vulkan warm-up+inference completes in under ~2 seconds, and sampling
`ioreg` via a separate SSH round-trip against a background process on this
timescale proved unreliable (the process had often already finished by the
time the sample landed). This is an honest gap — the ggml allocator log
line is real evidence of GPU memory activity, but it is not the same as an
independently-measured system-level VRAM delta.

## 7. Shader "compiled once, not per-request" — timing evidence

From the release-optimized benchmark (§8): warm-up (which forces the first
Vulkan pipeline compilation — 374 `ggml_vk_create_pipeline` call sites in
upstream's own `ggml_vk_load_shaders`, matching what this fork's whisper.cpp
work measured at ~35-39s cold on Metal/Vulkan) happens once per
`ParakeetEngine` construction, not per transcription call. The first real
clip after warm-up (`01_ru_short_command`, 422.9ms) is slower per-second-
of-audio than later, longer clips (`11_ru_paragraph_30s`, 1529.1ms for
25.58s of audio — far better than linear scaling from the first clip would
predict), consistent with warm-up having already absorbed the bulk of the
one-time pipeline-compile cost rather than each request re-paying it. A
dedicated cold-vs-warm split wasn't measured separately (matches a
limitation Phase 2's own report already noted for `parakeet-cli bench`,
which also doesn't split load-time from first-inference time).

## 8. Benchmark: Parakeet Vulkan vs Parakeet CPU, full app path

Per the task's explicit instruction to measure "once wired into the full
app+bridge+Swift overhead" (not the standalone CLI the pre-spike used), a
new `parakeet-vulkan-bench` self-test group runs one device per process
invocation through the real `ParakeetEngine`/bridge/actor path (one device
per process because of §2's singleton constraint — exactly matching how
`TranscriptionWorker` itself never holds two engines alive at once
either). Ran on the Phase 1 corpus (4 clips), **`-c release` build with
`-Xswiftc -DDEBUG`** (release optimization for both Swift and the
C/C++ target, with the `#if DEBUG`-gated self-test harness still
compiled in — a debug-config run was also done first and is noted below
for comparison):

| Clip | Audio (s) | CPU (ms) | Vulkan (ms) | Latency change |
|---|---:|---:|---:|---:|
| `01_ru_short_command` | 1.67 | 330.9 | 422.9 | **−27.8% (Vulkan slower)** |
| `02_en_short_command` | 1.69 | 279.0 | 179.8 | 35.5% |
| `03_ru_numbers` | 7.87 | 1095.2 | 809.7 | 26.1% |
| `11_ru_paragraph_30s` | 25.58 | 3550.0 | 1529.1 | 56.9% |

Transcript text was **byte-identical between CPU and Vulkan on all 4
clips** (better than the pre-spike's own result, which had a one-comma
divergence on `03_ru_numbers` — not reproduced here).

**Honest finding: the ≥15-20% spec §20 target is met on 3 of 4 clips
(26-57%, growing with clip length, consistent with the pre-spike's own
shape), but the shortest clip regresses** — Vulkan is measurably slower
than CPU on a 1.67s command-length clip once real Swift/actor/bridge
marshalling and per-call Vulkan dispatch overhead are included, versus the
pre-spike's raw CLI measurement of the same-length clip showing a 31.9%
*reduction* with none of that overhead. This is a genuine, non-fabricated
divergence from the pre-spike's numbers, not a regression in the pre-spike
itself — the pre-spike explicitly scoped out "full app+bridge+Swift
overhead" as future Phase 5 work, and this is exactly what that overhead
looks like on short clips. For typical dictation lengths in this app (this
fork's own product is push-to-talk short-command dictation, not long-form
transcription), this means Vulkan's real-world benefit is genuinely
clip-length-dependent, not a flat win — worth surfacing honestly rather
than only reporting the favorable longer-clip numbers.

A first pass was also run under a plain debug build (`-c debug`, no
optimization for the C/C++ target) and showed CPU times 8-14x higher than
the release numbers above (e.g. `01_ru_short_command` CPU: 3330ms debug vs
330.9ms release) while Vulkan times were comparatively much less affected
by the optimization level (GPU-side compute dominates Vulkan's wall time,
not host-side scalar code) — this produced misleadingly large "reductions"
(71-96%) that do not reflect real shipped performance and are NOT used as
this phase's reported numbers; only the release-optimized run above is.

## 9. Self-test results

- `swift run -c debug --self-test all`: **PASS** (includes `parakeet-bridge`,
  which now conditionally asserts either `.vulkanUnavailable` or
  `.modelNotFound` for a bogus path depending on whether a real Vulkan
  device is enumerated — updated from Phase 3's unconditional
  `.vulkanUnavailable` assertion, which is no longer universally true now
  that Vulkan is real).
- `swift run -c debug --self-test parakeet-cpu` (`SUPERDICTATE_PARAKEET_MODEL`
  set to the real GGUF): **PASS**.
- `swift run -c debug --self-test parakeet-vulkan` (`SUPERDICTATE_TEST_VULKAN=1`
  + real model + real hardware): **PASS** — real device verification and
  the forced-failure fallback path both covered (§5).
- `swift run -c debug --self-test parakeet-vulkan-bench`: **PASS** (both
  device passes; not a pass/fail regression test by design, see §8).
- `bash -n install.sh uninstall.sh scripts/build-app.sh
  scripts/vendor-parakeet-cpp.sh`: clean.
- `plutil -lint swift/Info.plist entitlements.plist`: both OK.

## 10. What was NOT fully completed / honest gaps

- **Clean before/after VRAM delta via `ioreg`** was attempted but not
  reliably captured over the remote SSH round-trip on this fast a
  workload (§6) — the ggml allocator log line stands in as real, but
  less precise, evidence.
- **100-sequential-dictations stress testing** (spec §20's CPU acceptance
  criterion, mentioned as still-open by the pre-spike for Vulkan too) was
  **not** run against the Vulkan backend in this phase — out of scope
  given time; a reasonable next-phase or manual follow-up item.
- **Full GUI-level verification** (actually toggling "Use GPU (Vulkan)" in
  the running menu-bar app and watching `TranscriptionWorker.load()`'s
  real branching end-to-end) was **not** performed against a live app
  instance. This was a deliberate, documented scoping decision: the
  release `.app` bundle's `bundleIdentifier` is shared with the production
  install, and `UserDefaults` are keyed by bundle ID, not by binary path —
  toggling `parakeet_use_gpu` via `defaults write` against this scratch
  build's identifier would write into the SAME `UserDefaults` domain
  production reads, an unacceptable risk given the task's explicit warning
  about not touching production state. `ParakeetEngine` (which
  `TranscriptionWorker.load()` delegates every device decision to) WAS
  verified directly and repeatedly via the self-test suite instead, using
  the identical bridge/backend code paths.
- **The `parakeet-vulkan-bench` self-test group is a measurement tool, not
  a permanent CI-friendly regression benchmark** — `scripts/benchmark-parakeet.sh`
  (spec §19, a permanent re-runnable script) is explicitly scoped to Phase
  7 by the plan and was not built here.
- **`PARAKEET_CPP_COMMIT`/model pins**: unchanged from Phases 2-4
  (`e747acdaee69b916cef62263ae5f718bda9ff3f3` / ggml
  `e705c5fed490514458bdd2eaddc43bd098fcce9b`, v0.13.0) — confirmed via the
  vendor script's own fatal-on-drift check, which did not fire.

## 11. Summary

- **Build**: PASS, debug and release, on the real Intel Mac.
- **Device-selection safety**: PASS — the pre-spike's silent-CPU-fallback
  finding is fixed and proven via a real forced-failure test, not just
  code review.
- **Shader mechanism**: switched from embedded C arrays (230MB, worked but
  wasteful) to loose `.spv` + runtime loader (60MB), matching this fork's
  own proven whisper.cpp precedent, with the rationale and a real
  friction point (umbrella-header search-path limitation) documented.
- **Static linking**: PASS, verified via `otool -L` on the actual shipped
  app binary — zero forbidden runtime dependencies.
- **Real hardware verification**: PASS — real device enumeration and
  selection, real inference, real forced-fallback recovery, all with log
  evidence from the actual RX 6600.
- **Benchmark**: honest mixed result — spec target met on 3/4 clips,
  missed (regression) on the shortest clip, once real app overhead is
  included. This is the most important finding of this phase to carry
  forward: Vulkan's benefit for this specific product (short push-to-talk
  commands) is not guaranteed and should not be oversold in user-facing
  copy — the README's RU section states this plainly rather than only
  quoting the favorable longer-clip numbers.
- **Self-tests**: full suite green, including the new `parakeet-vulkan`
  and `parakeet-vulkan-bench` groups.
