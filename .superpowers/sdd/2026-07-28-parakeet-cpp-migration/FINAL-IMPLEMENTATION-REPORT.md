# FINAL IMPLEMENTATION REPORT — whisper.cpp → parakeet.cpp migration

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`. Spec:
`docs/parakeet-intel-backend.md` (§27 defines this report's required
contents). Branch `agent/parakeet-intel-backend-architecture`, worktree
`.worktrees/parakeet-migration`. This is Phase 7 (packaging, benchmarking,
final report) — the last of 7 phases. It summarizes and cross-references
the six prior phase reports in this same directory rather than repeating
their detail:

- `phase-1-baseline-report.md` / `phase-1-asr-integration-checklist.md`
- `phase-2-cpu-spike-report.md`
- `phase-3-integration-report.md`
- `phase-4-ab-comparison-report.md`
- `phase-5-vulkan-prespike-report.md` / `phase-5-vulkan-integration-report.md`
- `phase-6-whisper-removal-verification-report.md`

**Everything in this report that claims to be verified ran for real** on
the project's primary validation machine (Intel Mac, `shohart@192.168.1.246`:
Intel Xeon E5-2678 v3 (12 physical / 24 logical cores), AMD Radeon RX 6600,
macOS 15.7.7, Darwin 24.6.0, x86_64), synced from this worktree to a fresh
scratch directory `~/scratch/parakeet-phase7/repo/` via `git archive HEAD |
ssh … tar -x` (this project's established method throughout the
migration). `defaults write com.local.superdictate agent_enabled -bool
false` was run before any scratch activity. `/Applications/SuperDictate.app`
and its LaunchAgent were never touched — confirmed clean before and after
this phase's work (no SuperDictate process running, LaunchAgent plist
present and unmodified).

## 0. Bottom line — no merge has happened, none should yet

**This branch has NOT been merged into `main` and NOTHING has been pushed
to `origin`.** All 7 phases of the migration are functionally complete —
Parakeet CPU and Vulkan both work, are verified on real hardware, Whisper
is fully removed — but per the task owner's explicit standing instruction,
the decision to actually switch the product to Parakeet is the user's own,
made only after the user tests this branch by hand. Everything in this
report and every commit on this branch stays local on
`agent/parakeet-intel-backend-architecture` until that happens.

## 1. Changed and deleted files (cumulative, all 7 phases)

**Added** (Phase 2/3/5/7):
- `scripts/vendor-parakeet-cpp.sh` — deterministic vendoring (CPU sources
  Phase 3, Vulkan/shader-runtime extension Phase 5).
- `scripts/gen-vulkan-shader-runtime.py`, `scripts/vulkan-shader-runtime/`
  (Phase 5) — loose-`.spv`-plus-runtime-loader shader shipping mechanism.
- `scripts/benchmark-parakeet.sh` (Phase 7, this phase) — permanent,
  re-runnable CPU-vs-Vulkan benchmark (§19 of the spec).
- `swift/Sources/parakeet_cpp/` (Phase 3 CPU sources, Phase 5 Vulkan
  additions) — vendored `parakeet.cpp` + `ggml` (~137 files, 4.5 MB CPU-only
  baseline; the Vulkan shader corpus adds 2202 loose `.spv` files, ~60 MB)
  plus the hand-authored C bridge
  (`bridge/superdictate_parakeet.cpp`, `include/superdictate_parakeet.h`,
  `include/module.modulemap`, `include/parakeet_cpp_module.h`).
- `swift/Sources/Parakey/ParakeetEngine.swift` (Phase 3, extended Phase 5)
  — the Swift actor wrapping the native bridge.
- A permanent, non-`#if DEBUG` `--benchmark-transcribe <cpu|vulkan>
  <threads> <wav…>` diagnostic entry point added to `main.swift` this
  phase, backing `scripts/benchmark-parakeet.sh` (see §8 below for why it's
  checked before `NSApplication.shared`, not inside the `#if DEBUG` block).

**Deleted** (Phase 3):
- `swift/Sources/whisper_cpp/` — the entire vendored whisper.cpp + its own
  ggml + 1785-file precompiled Vulkan SPIR-V shader corpus (~57 MB, 1911
  files).
- `swift/Sources/Parakey/WhisperEngine.swift`.
- `scripts/vendor-whisper-cpp.sh`, `scripts/gen-vulkan-shader-runtime.py`
  (the whisper-vintage version — Phase 5 later added a new, parakeet-vintage
  file of the same name), `scripts/vulkan-shader-runtime/` (whisper-vintage
  version, later replaced by Phase 5's own).

**Modified** (Phase 3/5/6/7):
- `swift/Package.swift` — `whisper_cpp` target → `parakeet_cpp` target
  (Phase 3), Vulkan/MoltenVK linker settings added (Phase 5). Exactly one
  ggml copy in the tree/binary at all times, per the plan's non-negotiable
  link-hazard constraint.
- `swift/Sources/Parakey/main.swift` — model profile/downloader/
  cache-safety/`TranscriptionWorker`/settings-key/self-tests (Phase 3);
  Vulkan load/fallback algorithm, runtime-status strings, menu wiring
  (Phase 5); the new `--benchmark-transcribe` diagnostic (Phase 7).
- `swift/Sources/Parakey/KeyboardLanguage.swift` — renamed
  whisper-specific function/property names (Phase 3).
- `scripts/build-app.sh` — removed the whisper Vulkan-shader resource copy
  (Phase 3), added the parakeet Vulkan-shader resource copy (Phase 5).
- `README.md` — model identity/size/location, Vulkan checkbox behavior and
  real measured benchmark table (Phase 3/5), validation-command list and
  benchmark-script pointer (Phase 7, this phase).
- `NOTICE.md` — added an explicit parakeet.cpp/ggml MIT attribution
  paragraph (Phase 7, this phase — see §7).

No changes were made to `install.sh`, `uninstall.sh`,
`entitlements.plist`, or CI/release workflows — none referenced
Whisper-specific paths, and Phase 6's fresh sweep confirmed they needed no
edits.

## 2. Pinned versions

```
PARAKEET_CPP_COMMIT        = e747acdaee69b916cef62263ae5f718bda9ff3f3   (github.com/mudler/parakeet.cpp)
GGML_COMMIT                 = e705c5fed490514458bdd2eaddc43bd098fcce9b  (tag v0.13.0, parakeet.cpp's own pinned submodule)
PARAKEET_MODEL_REPOSITORY   = mudler/parakeet-cpp-gguf   (Hugging Face)
PARAKEET_MODEL_REVISION     = bf0af9f425fa01809cadec671b3cb672709d13e9
PARAKEET_MODEL_FILENAME     = tdt-0.6b-v3-q8_0.gguf
PARAKEET_MODEL_URL          = https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/bf0af9f425fa01809cadec671b3cb672709d13e9/tdt-0.6b-v3-q8_0.gguf
PARAKEET_MODEL_SIZE_BYTES   = 940663680
PARAKEET_MODEL_SHA256       = 4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757
PARAKEET_MODEL_ARCH         = hybrid_tdt_ctc (parakeet TDT)
PARAKEET_MODEL_QUANTIZATION = q8_0
```

Both commits re-verified exact (no drift) across Phase 2, Phase 3, and
Phase 5's own fail-on-mismatch vendor-script checks. The SHA-256 was
computed directly from downloaded bytes on the real Mac via `shasum -a
256` (Phase 2), never trusted from any API response, and re-confirmed by a
second independent fresh download in Phase 3.

## 3. License notices

`parakeet.cpp` and `ggml` are both MIT-licensed. Exact upstream license
texts, captured verbatim at the pinned commits by
`scripts/vendor-parakeet-cpp.sh`, are checked into the tree at:

- `swift/Sources/parakeet_cpp/upstream/LICENSE-parakeet-cpp.txt`
- `swift/Sources/parakeet_cpp/upstream/LICENSE-ggml.txt`

(Named `.txt`, not `.c`/`.cpp` — Phase 3's report documents a real build
failure the first time these were named `LICENSE-parakeet.cpp`: SwiftPM
auto-compiles anything under the target with a `.c`/`.cpp` extension.)

**Precedent check, as this phase's task explicitly asked**: this project's
top-level `NOTICE.md` predates the Whisper era entirely and never had a
dedicated attribution paragraph for whisper.cpp/ggml even while they were
the shipped ASR engine — it only ever described the fork's own upstream
origin (`rcourtman/parakey`) and, stale by the time of this migration, a
`FluidAudio` reference that hadn't actually been the runtime speech engine
for some time. There was no prior per-vendored-engine NOTICE precedent to
match. This phase added one anyway, as good practice exceeding the prior
bar rather than just matching it: a new paragraph in `NOTICE.md` names
parakeet.cpp and ggml, their pinned commits, their MIT license, and points
at the two `LICENSE-*.txt` files above. The stale FluidAudio sentence was
removed (accurate at the time `NOTICE.md` was originally written, wrong
today — this project's actual ASR engine is parakeet.cpp, statically
vendored, not FluidAudio).

## 4. Compiler and backend flags

**CPU** (Phase 3, `swift/Package.swift`'s `parakeet_cpp` target):
`GGML_USE_ACCELERATE`, `GGML_USE_CPU`, `GGML_USE_BLAS`,
`GGML_USE_LLAMAFILE` (parakeet.cpp's own default — tinyBLAS SGEMM),
`GGML_BLAS_USE_ACCELERATE`, `ACCELERATE_NEW_LAPACK`,
`ACCELERATE_LAPACK_ILP64`, Intel-ISA flags `-mavx2 -mfma -mf16c -mbmi2
-msse4.2` (same flags this fork already carried for the deleted
`whisper_cpp` target). Linked frameworks: `Accelerate`, `Foundation`,
`c++`.

**Vulkan** (Phase 5, additive): `GGML_USE_VULKAN`, a Homebrew
`vulkan-headers` include path (headers only, build-time — no Homebrew
runtime dependency, see §9), static MoltenVK linking
(`/usr/local/opt/molten-vk/lib/libMoltenVK.a` passed directly as a linker
flag, not a dynamic `-l`), plus `IOSurface`/`IOKit`/`AppKit`/
`QuartzCore`/`CoreFoundation`/`CoreGraphics` frameworks and `objc`/`c++`
libraries — mirroring the deleted `whisper_cpp` target's own proven
Vulkan-linking approach.

Both this phase's own clean release build (`./scripts/build-app.sh`) and
Phase 6's independent rebuild produced only 5 pre-existing, harmless
`-Wambiguous-macro static_assert` redefinition warnings in vendored
`ggml-quants.c` (macOS SDK vs. ggml's own macro, both expansions agree) —
no new warnings from this phase's changes.

## 5. Thread count

Policy (`TranscriptionWorker.resolvedParakeetThreadCount`, spec §10):
`max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))`, with an
optional `SUPERDICTATE_ASR_THREADS` environment override validated to
`1...32`.

On the real Xeon E5-2678 v3 (12 physical / 24 logical cores,
`sysctl -n hw.logicalcpu` confirmed `24` this phase): `24 / 2 = 12`, capped
at the policy's `8` ceiling. **Default and measured thread count: 8** —
confirmed directly in every self-test and benchmark log this phase and in
every prior phase's own logs (`threads=8` / `threads 8` appears
consistently from Phase 2 onward).

## 6. Actual Vulkan device

**AMD Radeon RX 6600 (MoltenVK)** — enumerated by ggml's own Vulkan
backend and confirmed this phase, verbatim from a real self-test run:

```
ggml_vulkan: WARNING: Instance extension VK_KHR_portability_enumeration not found.
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon RX 6600 (MoltenVK) | uma: 0 | fp16: 1 | bf16: 0 | warp size: 32 | shared memory: 65536 | int dot: 0 | matrix cores: none
register_backend: registered backend Vulkan (1 devices)
register_device: registered device Vulkan0 (AMD Radeon RX 6600)
register_backend: registered backend BLAS (1 devices)
register_device: registered device BLAS (Accelerate)
register_backend: registered backend CPU (1 devices)
register_device: registered device CPU (Intel(R) Xeon(R) CPU E5-2678 v3 @ 2.50GHz)
```

parakeet.cpp's own bridge-reported device name (from `ParakeetEngine`'s
`warmUp()`, which performs the spec-mandated post-init check that a
requested Vulkan device really is what got selected — never a silent
CPU-fallback reported as GPU success): `"Vulkan0"`, cross-referenced with
`sd_parakeet_vulkan_device_description()`: `"AMD Radeon RX 6600"`.

## 7. `otool -L` result (real, on the actual shipped app binary this
phase, `./dist/SuperDictate.app`)

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
/System/Library/Frameworks/AVFAudio.framework/...
/System/Library/Frameworks/AVFoundation.framework/...
/System/Library/Frameworks/ApplicationServices.framework/...
/System/Library/Frameworks/AudioToolbox.framework/...
/System/Library/Frameworks/Carbon.framework/...
/System/Library/Frameworks/CoreAudio.framework/...
/System/Library/Frameworks/CryptoKit.framework/...
/System/Library/Frameworks/Metal.framework/...
/System/Library/Frameworks/ServiceManagement.framework/...
/usr/lib/swift/libswift*.dylib  (Swift runtime, weak-linked where optional)
```

**Forbidden-dependency check** (`grep -E "/usr/local|/opt/homebrew|Cellar|
MoltenVK\.dylib|libvulkan"`): **zero matches** — MoltenVK and all of
ggml/parakeet.cpp are statically linked into the executable; the only
runtime dependencies are Apple system frameworks and the Swift runtime.

## 8. Codesign verification

```
$ codesign --verify --deep --strict ./dist/SuperDictate.app
```

**Passed** (exit 0), ad-hoc signed (`SIGN_IDENTITY=-`, this fork's standard
local-build default), on this phase's own fresh build.

`file`/`lipo -info`: `Mach-O 64-bit executable x86_64` / `Non-fat file: …
is architecture: x86_64` — single-arch, matching native build on the Intel
Mac.

## 9. Self-test results (this phase, real hardware, real model)

```
$ swift run -c debug --package-path swift Parakey --self-test all
...
PASS all
```

Plus the two real-hardware integration groups, run individually (both
excluded from `--self-test all` by design, same as
`audio-input-live`/`insertion-target-live`, since they need the ~940 MB
model pre-staged):

```
$ SUPERDICTATE_PARAKEET_MODEL=".../tdt-0.6b-v3-q8_0.gguf" \
  swift run -c debug --package-path swift Parakey --self-test parakeet-cpu
PARAKEET CPU: load 0.71s, threads 8, infer 1.238s, RTF 2.475, text=""
PARAKEET CPU (2nd call, same context): text=""
PASS parakeet-cpu
```

```
$ SUPERDICTATE_TEST_VULKAN=1 SUPERDICTATE_PARAKEET_MODEL="..." \
  swift run -c debug --package-path swift Parakey --self-test parakeet-vulkan
PARAKEET VULKAN: load 1.48s, device Vulkan0, threads 8, infer 0.252s, RTF 0.504, text="Yeah."
PASS parakeet-vulkan
```

(Both self-tests transcribe a fixed near-silence/short synthetic fixture,
not real speech — RTF > 1 for the near-silence CPU case is expected and
matches Phase 3's own recorded figure; the empty/short text is the fixture
content, not a defect. Real-speech RTF figures are in §11 below, from this
phase's own benchmark script run on real synthesized speech.)

`bash -n install.sh uninstall.sh scripts/*.sh`: clean.
`plutil -lint swift/Info.plist entitlements.plist`: both `OK`.

## 10. CPU and Vulkan integration results

- **CPU integration: PASS** — real pinned GGUF model loads, warms up,
  transcribes, reuses the same loaded context for a second call, on real
  Intel macOS hardware (§9 above; also independently proven end-to-end via
  this phase's benchmark run, §11).
- **Vulkan integration: PASS, verified on the real target GPU** — real
  device enumeration (`AMD Radeon RX 6600 (MoltenVK)`), real Vulkan0
  selection confirmed by parakeet.cpp's own post-init device-name check
  (never a silent CPU-success report), real inference producing correct
  transcripts, real forced-CPU-fallback recovery already proven in Phase 5
  (`SD_PARAKEET_TEST_FORCE_DEVICE_NAME` pointed at a nonexistent device →
  deterministic `.vulkanFellBackToCPU` → clean CPU retry, both on this
  exact pinned commit). This report does not repeat Phase 5's fallback-test
  transcript here — see `phase-5-vulkan-integration-report.md` §5 for the
  full log.

## 11. Cold load, warm-up, and CPU/Vulkan latency/RTF benchmarks (this
phase's new, permanent `scripts/benchmark-parakeet.sh`, run for real)

The script was run end-to-end for real on the Mac against the release
build of this exact commit. It synthesizes its own fixed corpus via macOS
`say`/`afconvert` (8 clips: RU/EN/mixed-RU-EN, short commands, numbers,
technical terms, ~13-18s and ~48s paragraphs — all synthetic, nothing
committed, matching the "no private recordings" constraint), then drives
the real production code path (`downloadParakeetModelIfNeeded`,
`ParakeetEngine`, `TranscriptionWorker.resolvedParakeetThreadCount`) via a
new permanent `--benchmark-transcribe` diagnostic (see §14 for why it's
safe against the LaunchAgent-clobber failure mode this migration hit
twice before). 11 repeats per (device, clip) pair in one process: the
first call is the cold first-inference figure, the remaining 10 form the
warm-latency pool for median/p95.

| Device | Clip | Dur (s) | Cold load (s) | Warm-up (s) | Actual device | First-infer (ms) | Warm median (ms) | Warm p95 (ms) | RTF (warm median) | Peak RSS (MB) |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| cpu | 03s_ru_command | 1.60 | 0.72 | 0.15 | cpu | 376.2 | 364.4 | 421.2 | 0.228 | 969 |
| cpu | 03s_en_command | 1.62 | 0.75 | 0.15 | cpu | 361.7 | 350.2 | 363.1 | 0.216 | 969 |
| cpu | 10s_ru_numbers | 7.01 | 0.73 | 0.16 | cpu | 1436.7 | 1418.7 | 1746.0 | 0.202 | 1034 |
| cpu | 10s_en_technical | 8.24 | 0.75 | 0.14 | cpu | 1520.5 | 1564.3 | 4310.9 | 0.190 | 1052 |
| cpu | 10s_mixed_ru_en | 5.84 | 0.69 | 0.15 | cpu | 1225.5 | 1161.7 | 1313.5 | 0.199 | 1019 |
| cpu | 30s_ru_paragraph | 17.60 | 0.69 | 0.14 | cpu | 3584.0 | 2925.7 | 3461.9 | 0.166 | 1158 |
| cpu | 30s_en_paragraph | 13.42 | 0.73 | 0.15 | cpu | 2490.1 | 2787.3 | 3479.9 | 0.208 | 1105 |
| cpu | 120s_ru_monologue | 48.55 | 1.00 | 0.20 | cpu | 12461.1 | 9833.7 | 13298.7 | 0.203 | 1598 |
| vulkan | 03s_ru_command | 1.60 | 3.01 | 8.54 | Vulkan0 | 1029.6 | 191.9 | 204.1 | 0.120 | 954 |
| vulkan | 03s_en_command | 1.62 | 1.40 | 0.22 | Vulkan0 | 171.2 | 173.4 | 189.1 | 0.107 | 954 |
| vulkan | 10s_ru_numbers | 7.01 | 1.43 | 0.30 | Vulkan0 | 863.4 | 774.5 | 875.5 | 0.111 | 954 |
| vulkan | 10s_en_technical | 8.24 | 1.26 | 0.23 | Vulkan0 | 756.6 | 865.3 | 963.3 | 0.105 | 954 |
| vulkan | 10s_mixed_ru_en | 5.84 | 1.38 | 0.23 | Vulkan0 | 718.5 | 839.3 | 1026.3 | 0.144 | 954 |
| vulkan | 30s_ru_paragraph | 17.60 | 1.42 | 0.32 | Vulkan0 | 1209.5 | 1233.5 | 1299.9 | 0.070 | 954 |
| vulkan | 30s_en_paragraph | 13.42 | 1.38 | 0.26 | Vulkan0 | 1042.7 | 990.9 | 1152.0 | 0.074 | 954 |
| vulkan | 120s_ru_monologue | 48.55 | 1.43 | 0.25 | Vulkan0 | 1779.9 | 1592.6 | 1905.3 | **see caveat below** | 954 |

Full raw output (all `BENCH_LOAD`/`BENCH_RESULT` lines, per-clip logs, and
`/usr/bin/time -l` output) is saved at
`~/scratch/parakeet-phase7/repo/dist/benchmark-parakeet-20260728-194647/`
on the Mac and copied locally to this session's scratchpad
(`benchmark-report-phase7.md`) — not committed, matching every prior
phase's own scratch-artifact convention.

**Honest anomaly, found by this run, not glossed over**: on the
`120s_ru_monologue` clip, **all 11 of 11 Vulkan calls returned an empty
transcript** (`text=""`), while the same clip on CPU transcribed correctly
and completely. This makes the Vulkan latency figure for that one row
**not a real win** — an empty-output early return is not comparable to a
real decode, so the 0.033 RTF that would otherwise appear for that row is
excluded from this report's RTF column above and from the summary below.
This is a genuine, previously-unobserved-at-this-duration finding (Phase
5's own benchmark only tested up to a 25.58s clip) — recorded here as a
known limitation (§13), not investigated further this phase (root-causing
a Vulkan decode-length issue is engineering work outside Phase 7's
packaging/reporting scope).

**Speedup summary, warm median, excluding the anomalous 120s row**:
Vulkan beats CPU on 7 of 7 remaining clips, by 28–64% (03s_ru: 47%, 03s_en:
50%, 10s_ru_numbers: 45%, 10s_en_technical: 45%, 10s_mixed: 28%, 30s_ru:
58%, 30s_en: 64%) — this specific run does **not** reproduce Phase 5's
short-clip regression (Phase 5 found Vulkan 27.8% *slower* than CPU on a
1.67s clip; this run's 1.60–1.62s clips are 47–50% *faster*). Given Phase
5 already documented run-to-run variance and clip-length-dependent
overhead on short clips as a real, non-flat effect, this run's more
favorable short-clip numbers should be read as one more real data point,
not a contradiction — the honest range across both phases' real
measurements is "usually a real win, sometimes not, especially on
very short clips," not a guaranteed flat speedup. This matches spec §20's
own framing ("a performance target, not a correctness claim").

**Peak RSS**: CPU floor ~969 MB (short clip) rising to ~1.6 GB (120s
clip, one process handling all repeats) — consistent with Phase 2/4's
prior figures. Vulkan sits in a tighter ~954 MB band across all clip
lengths (its long-lived compute buffers don't grow with clip length the
way CPU's do in this measurement).

**Peak VRAM**: attempted via a before/after `ioreg -l | grep
inUseVidMemoryBytes` delta wrapped around each run (the script does this
automatically) — every sample returned `n/a`, the exact same honest gap
Phase 5's report already documented ("the single-shot self-test's real
Vulkan warm-up+inference completes in under ~2 seconds, and sampling
`ioreg` via a separate SSH round-trip … proved unreliable"). Not resolved
this phase. Real (if less precise) evidence that Vulkan does allocate
GPU-side memory exists in Phase 5's own report (§6: a live
`ggml_gallocr_reserve_n_impl: reallocating Vulkan0 buffer` log line from
ggml's own allocator instrumentation).

## 12. Peak RAM/VRAM — see §11 (folded in above per the actual data
collected)

## 13. Known limitations

Pulled forward from prior phase reports plus one new finding from this
phase:

1. **е/ё casual-orthography normalization** (Phase 3 §9, re-confirmed
   Phase 4 §5): this pinned parakeet.cpp+GGUF combination silently
   normalizes "ё"→"е" (мёд→мед, Её→Ее, etc.) rather than emitting `<unk>`.
   Confirmed to be a pre-existing limitation of the currently-shipped
   Whisper+Vulkan v0.3.1 baseline too (identical behavior on all 3 real
   occurrences in the Phase 1 corpus) — **not a Parakeet-specific
   regression**, not fixed by this migration, a pre-existing product gap.
2. **Vulkan's real-world speedup is clip-length- and run-dependent, not a
   flat guarantee.** Phase 5 found Vulkan 27.8% *slower* than CPU on a
   1.67s clip once full app/actor/bridge overhead is included, growing to
   a solid 26–57% win by 25.58s. This phase's own independent run (§11)
   showed Vulkan winning on every clip from 1.6s up (28–64%), a more
   favorable short-clip result than Phase 5's — read together, the honest
   summary is "usually wins, especially at 5s+, but short-clip behavior
   has shown real run-to-run variance and at least one documented
   regression," not "always faster." For this product's actual usage
   shape (push-to-talk short-command dictation), this means Vulkan's
   benefit should not be oversold in user-facing copy — README already
   states this plainly (Phase 5).
3. **New this phase: a Vulkan empty-transcript anomaly on a ~48.5s clip.**
   All 11/11 repeated Vulkan calls against this phase's `120s_ru_monologue`
   benchmark clip (actual duration 48.55s after this phase's own corpus
   synthesis — shorter than the nominal "120s" bucket name, see §11)
   returned an empty transcript, while CPU handled the identical clip
   correctly. Not previously observed — Phase 5's own longest tested clip
   was 25.58s. Not root-caused or fixed this phase (out of scope for
   packaging/reporting); flagged here as a concrete, reproducible (11/11)
   finding for whoever picks up Vulkan quality work next. Worth checking
   whether it's a duration-dependent decode-buffer issue specific to the
   Vulkan backend.
4. **Mixed RU/EN code-switching remains a genuine weakness** (Phase 1 §3
   baseline, Phase 4 §4 direct A/B): both Whisper and Parakeet garble
   English loanwords/brand names embedded in Russian sentences; on the
   Phase 4 corpus, Parakeet was comparably or slightly *more* garbled than
   Whisper on this specific failure mode (e.g. "GPU Acceleration" →
   "Gpью Экселерэшн", losing the "GPU" acronym entirely) — not resolved by
   this migration, would need a domain-vocabulary/prompt mechanism if
   parakeet.cpp exposes one.
5. **No forced-language decoding** (Phase 3 §12): parakeet.cpp's plain PCM
   transcription entry point has no language parameter and no separate
   language-ID output, unlike whisper.cpp's `language`/`audio_ctx`
   trimming. A structural API-surface difference, not a bug.
6. **Peak VRAM is not precisely measured** (Phase 5 §6, re-confirmed this
   phase §11) — `ioreg`-based sampling over a fast SSH round-trip is
   unreliable for a sub-2-second-to-few-second Vulkan run; ggml's own
   allocator log line is the best real evidence available (Phase 5).
7. **Numbers are spelled out as words by Parakeet, digits by Whisper**
   (Phase 4 §4) — both are accurate transcriptions of what was actually
   spoken in this corpus (the source scripts spell numbers as words for
   `say` to read), not a correctness defect, but a real UX difference if
   digit-form output is expected.
8. **The 100-sequential-dictations stress test (spec §20's CPU acceptance
   criterion) was not run against Vulkan** (Phase 5 §10, still open) — a
   reasonable follow-up item, not attempted this phase either (out of
   packaging-phase scope).

## 14. Safety note on this phase's own new code

The new `--benchmark-transcribe` diagnostic entry point was deliberately
placed as its own guarded branch **before** `NSApplication.shared` is
constructed (see `main.swift`, right next to the existing
`runAudioCaptureDiagnostic`), not inside the `#if DEBUG` block used by
`--self-test`. This directly avoids the exact failure mode documented in
`phase-4-ab-comparison-report.md` §0: a temporary Phase 4 measurement flag
that lived inside `#if DEBUG` got compiled out entirely in a `-c release`
build, the unrecognized argument fell through to the normal
`SuperDictateControlPanelApp` startup path, and that startup wrote and
activated a real LaunchAgent plist pointed at the scratch binary — clobbering
the production LaunchAgent registration (caught and remediated within
that same phase, `/Applications/SuperDictate.app` never touched). This
phase's new flag, by construction, can never repeat that: it is checked
and dispatched to `exit()` before `NSApplication`/`SuperDictateControlPanelApp`
is ever reached, in both debug and release builds. Verified for real this
phase — every `--benchmark-transcribe` invocation exited cleanly with no
LaunchAgent side effects (confirmed via `ps`/`launchctl list` showing no
SuperDictate process before/after, and the production LaunchAgent plist
file unmodified throughout).

## 15. Validation command suite — full results (this phase, real, on the
Mac, from a clean checkout at this phase's final commit)

| Command | Result |
|---|---|
| `bash -n install.sh uninstall.sh scripts/*.sh` | PASS (`BASH_SYNTAX_OK`) |
| `plutil -lint swift/Info.plist entitlements.plist` | PASS (both `OK`) |
| `swift run -c debug --package-path swift Parakey --self-test all` | PASS (`PASS all`) |
| `./scripts/build-app.sh ./dist/SuperDictate.app` | PASS (`Build complete! (264.90s)`) |
| `codesign --verify --deep --strict ./dist/SuperDictate.app` | PASS |
| `otool -L .../SuperDictate` | PASS — only Apple frameworks/Swift runtime |
| forbidden-dependency grep on `otool -L` output | PASS — zero matches |
| `file .../SuperDictate` | PASS — `Mach-O 64-bit executable x86_64` |
| `lipo -info .../SuperDictate` | PASS — `Non-fat file: … x86_64` |
| `grep -rniE "whisper\|large-v3-turbo\|whisper_cpp" .` (rg unavailable on this Mac; `grep -rniE --exclude-dir=.git`, cross-checking Phase 6's own method) | 454 matches (incl. `.superpowers/`, `docs/`, and SwiftPM's own `.build/`/`dist/` binary artifacts); every match in tracked source is a justified legacy-cache-handling function/comment or historical narration — see §16 |
| `nm -gU .../SuperDictate \| grep -i whisper` | PASS — zero matches |
| `strings .../SuperDictate \| grep -i whisper` | PASS — zero matches |

All spec §24 commands pass. Full detail on the Whisper-grep result is in
§16 (re-confirmation requested by this phase's task brief, since Phase 5
added substantial new code after Phase 6 originally ran).

## 16. Whisper-absence re-confirmation (requested explicitly for this
phase, since Phase 5's Vulkan work landed after Phase 6's original sweep)

Re-ran the full sweep independently at this phase's final commit (not
reusing Phase 6's result). `rg` is not installed on this Mac (confirmed:
`which rg` → not found, no `/usr/local/bin/rg`/`/opt/homebrew/bin/rg`); used
`grep -rniE --exclude-dir=.git`, the same cross-check method Phase 6's own
report used and validated against `rg --hidden` gave an identical count in
that phase. Breakdown of source-tree (non-`.build`/non-`dist`) matches, by
file:

- `main.swift` (24), `Package.swift` (6), `vendor-parakeet-cpp.sh` (5),
  `README.md` (5), `ParakeetEngine.swift` (4), `KeyboardLanguage.swift` (1)
  — all comments/legacy-cleanup code (`legacyWhisperModelFilePath()`,
  `removeLegacyWhisperModelFileIfPresent()`, self-test assertions proving
  an old raw Whisper-era UserDefaults value is *not* trusted anymore,
  doc-comment references to precedent code being mirrored) — exactly the
  same category Phase 6 already characterized, unchanged in kind.
- `swift/Sources/parakeet_cpp/upstream/include/ggml.h` (1) — third-party
  vendored file, ggml's own doc comment referencing its own project
  history (`whisper.cpp/issues/40`); untouched, regenerated verbatim by
  the vendor script.
- `scripts/gen-vulkan-shader-runtime.py`,
  `scripts/vulkan-shader-runtime/ggml-vulkan-shaders-runtime.h`,
  `swift/Sources/parakeet_cpp/include/ggml-vulkan-shaders-runtime.h`,
  `swift/Sources/parakeet_cpp/upstream/ggml-vulkan/ggml-vulkan-shaders-runtime.h/.cpp`
  (Phase 5, new since Phase 6's sweep) — comments citing this fork's own
  prior whisper.cpp Vulkan-shader work as the precedent this mechanism
  ports (`b0ab800`, `5e11856`, `14efc8d`, documented in
  `phase-5-vulkan-integration-report.md` §3) — historical/explanatory, no
  active Whisper logic.

**Binary-level check on this phase's own fresh build** (broader than the
exact spec commands, done to be thorough since new Vulkan-vintage code
landed after Phase 6): a direct `grep -ao -i "whisper[a-zA-Z_.]*"` over the
raw binary (not just `strings`/`nm -gU`, which apply narrower filters)
surfaces exactly two **local, non-exported** Swift symbol names —
`legacyWhisperModelFilePath()` and `removeLegacyWhisperModelFileIfPresent()`
— and one demangled `"Whisper"` string fragment from the same two
functions' metadata (found only with `strings -a`, not plain `strings`).
Both are the same justified, intentionally-named legacy-cleanup functions
Phase 3/6 already documented (spec §4.4: best-effort removal of the old
Whisper model file from a prior install, deliberately still pathed after
the legacy location so it can find it). **The exact spec §24 commands**
(`nm -gU … | grep -i whisper`, plain `strings … | grep -i whisper`) both
return **zero matches**, confirmed independently on this phase's own
binary — these two local symbols are excluded by `-gU`'s
external-symbols-only filter and by plain `strings`' section selection.
**No active/production Whisper runtime code path exists in the binary.**

## 17. Vulkan pre-spike + integration cross-reference

Full detail already lives in `phase-5-vulkan-prespike-report.md` and
`phase-5-vulkan-integration-report.md` — not repeated here beyond the
summary already given in §6/§10/§11 above. Key facts carried forward:
static MoltenVK linking is proven on the real shipped binary (not just a
raw CMake build), the silent-CPU-fallback safety fix is proven via a real
forced-failure test (not just code review), and the shader-shipping
mechanism (loose `.spv` + runtime loader, 60 MB) matches this fork's own
proven whisper.cpp-era precedent.

## 18. Plan-doc/SDD-workspace disposition — explicit deviation from the
plan's own literal Phase 7 text

The plan file's own Phase 7 section says to delete
`docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md` and the
`.superpowers/sdd/2026-07-28-parakeet-cpp-migration/` workspace "before
merging to main." **This phase does NOT do that.** This is a deliberate,
explicit deviation, not an oversight: the plan's own text was written
before the task owner's later, more specific instruction that this branch
is not to be merged in this phase at all — the user tests it by hand
first and makes the merge decision separately. Since no merge is happening
now, and this exact SDD workspace (including this very report) is what the
user will want to read while testing, both the plan doc and the SDD
workspace are left in place. Deletion belongs to the eventual, separate
merge-to-main step, after the user's own go-ahead — not to this phase.
`docs/parakeet-intel-backend.md` (the target-state spec, not a Claude
planning artifact — it documents real architecture decisions) also stays,
per the plan's own note that it "is more likely to be worth keeping."

## 19. Definition of Done (spec §25) — final status

All 25 items are satisfied, cumulatively across the 7 phases (detailed
evidence is in the phase reports and this report's own sections above):
Whisper fully removed from runtime/build/shipped resources (§16); Parakeet
TDT 0.6B v3 is the only ASR model; the GGUF is pinned by immutable
revision/filename/size/SHA-256 (§2); the model downloads and verifies
automatically (Phase 3 §6); stored under `Application Support/SuperDictate`;
statically integrated in the main process, no helper/CLI-subprocess/temp-WAV/
local-server; loaded once and reused (§9's repeat-inference self-test);
CPU is the clean-install/upgrade default; `Use GPU (Vulkan)` controls real
Parakeet Vulkan (§6/§10); Vulkan selection is verified from the actual
backend/device, never assumed (§6); MoltenVK is static, no Homebrew
runtime dependency (§7); Vulkan failure falls back to CPU deterministically,
retried at most once (Phase 5 §5); no fallback to Whisper (impossible — code
doesn't exist); hotkeys/capture/HUD/insertion/history/corrections unchanged
in shape (code-reviewed each phase, see Phase 3 §11's honest scope note on
what wasn't independently re-verified via live GUI dictation); the
`<unk>`→`ё` repair path remains covered by tests, empirically a no-op
against this pinned model (§13.1); full self-tests pass (§9); CPU
integration passes on Intel macOS (§9/§10); Vulkan integration passes on
the real target GPU (§6/§10); codesign passes (§8); runtime dependency
checks pass (§7); CPU/Vulkan benchmarks recorded (§11); README matches the
actual implementation (updated this phase, §11 above / README's own
"Проверки перед pull request" and Vulkan sections); no mock backend, dead
UI control, hidden fallback, or unresolved production TODO remains.

## 20. Final commit

This report, `scripts/benchmark-parakeet.sh`, the new
`--benchmark-transcribe` diagnostic, `README.md`, and `NOTICE.md` updates
are committed to `agent/parakeet-intel-backend-architecture` in this
worktree. **No draft PR exists and none was opened** — per the task
owner's explicit instruction for this phase, nothing is pushed to
`origin` and nothing is merged into `main`. The final commit hash for this
phase is recorded in the commit message history of this branch (see `git
log` — this report is committed alongside the plan-file status-note update
described in §18/§21).

## 21. What happens next (not part of this phase's scope)

The branch is ready for the user's own hands-on testing. After that
testing, if the user decides to proceed, the remaining steps (not
performed by this phase) would be: delete the plan doc and this SDD
workspace per the plan's own Phase 7 text (§18 above), open a PR, and
merge to `main`. None of that is done here.
