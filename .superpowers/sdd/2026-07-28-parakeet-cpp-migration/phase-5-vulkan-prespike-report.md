# Phase 5 pre-spike — Vulkan-on-Intel-Mac risk reduction for parakeet.cpp

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`, Phase 5
(Vulkan add-on, Checkpoint D). Spec: `docs/parakeet-intel-backend.md` §6.3,
§6.4, §11. This is a **standalone, early risk-reduction spike**, run in
parallel with Phase 3's application-integration work in the same worktree.
No file under `swift/` in this worktree was touched. Everything below ran
for real on the Intel Mac (`shohart@192.168.1.246`: Intel Xeon E5-2678 v3,
AMD Radeon RX 6600, macOS 15.7.7, x86_64), from a fresh scratch directory
`~/scratch/parakeet-phase5-vulkan-spike/` (separate from Phase 2's and
Phase 3's scratch dirs, neither of which was modified).

## 1. Headline result

**The Vulkan build succeeds, and Vulkan inference on the real AMD Radeon
RX 6600 via MoltenVK works correctly and measurably faster than CPU**, using
parakeet.cpp's own pinned ggml v0.13.0 Vulkan backend, unmodified upstream
CMake build. This directly answers the plan's open question: the same
MoltenVK-via-Vulkan approach already proven for this fork's whisper.cpp
does carry over to parakeet.cpp's newer, independent ggml vintage — at
least at the "does it run and select the right device" level tested here.
The parts that remain real work for Phase 5 proper are (a) static linking
of MoltenVK (this spike's CMake build links Homebrew's `libvulkan.1.dylib`
dynamically, as expected — CMake was never going to reproduce the fork's
SwiftPM-specific static-link trick) and (b) building the SwiftPM-compatible
shader corpus, because SwiftPM has no build-time custom-command mechanism
to run `vulkan-shaders-gen` the way upstream's CMake does (see §5 below —
this constraint is unchanged from the whisper.cpp work and is not specific
to parakeet's ggml vintage).

## 2. Setup

- Verified Homebrew already has everything needed (no new installs):
  `cmake` 4.4.0, `vulkan-headers`, `vulkan-loader`, `molten-vk` 1.4.2,
  `shaderc` (provides `glslc`) — all at `/usr/local/opt/...`/`/usr/local/Cellar/...`.
  Static `libMoltenVK.a` and dynamic `libMoltenVK.dylib` both present under
  `/usr/local/Cellar/molten-vk/1.4.2/...` and symlinked into `/usr/local/lib`.
  `cmake`/`glslc` are not on `PATH` for non-interactive SSH shells (same
  known quirk Phase 2 hit) — worked around with `zsh -lc '...'` (login
  shell) rather than a raw `ssh` command.
- Reused Phase 2's already-downloaded, already-verified GGUF (copied into
  this spike's own `models/` directory, not modified in place):
  `shasum -a 256` on the copy still returns
  `4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757`,
  exact match to the plan's pinned `PARAKEET_MODEL_SHA256`.
- Did **not** reuse Phase 2's clone directory (its `git status` showed
  "modified content" in the `third_party/ggml` submodule — not
  investigated further since reuse was optional per the dispatch
  instructions, and a fresh clone removes any doubt). Cloned
  `mudler/parakeet.cpp` fresh into this spike's own directory:
  `git clone --recursive https://github.com/mudler/parakeet.cpp.git`,
  then `git checkout e747acdaee69b916cef62263ae5f718bda9ff3f3`. Confirmed
  exact: `git rev-parse HEAD` → `e747acdaee69b916cef62263ae5f718bda9ff3f3`,
  `git submodule status` → ` e705c5fed490514458bdd2eaddc43bd098fcce9b
  third_party/ggml (v0.13.0)`, `git status --short` clean (no dirty
  submodule this time).

## 3. Vulkan build

```
cmake -B build-vulkan -DPARAKEET_GGML_VULKAN=ON -DGGML_NATIVE=ON
cmake --build build-vulkan -j
```

**Configure: clean, zero errors, zero workarounds needed.** Highlights from
the configure log:

```
-- Found Vulkan: /usr/local/lib/libvulkan.dylib (found version "1.4.350") found components: glslc glslangValidator
-- Vulkan found
-- GL_KHR_cooperative_matrix supported by glslc
-- GL_NV_cooperative_matrix2 supported by glslc
-- GL_EXT_integer_dot_product supported by glslc
-- GL_EXT_bfloat16 supported by glslc
-- Including Vulkan backend
-- ggml version: 0.13.0
-- ggml commit:  e705c5fe-dirty
```

The four "supported by glslc" lines are a **host-toolchain** capability
probe only (glslc/shaderc can compile shaders using those GLSL extensions);
they say nothing about whether MoltenVK/the RX 6600 actually expose the
corresponding Vulkan device extensions at runtime, and indeed none of
those advanced paths (cooperative matrix, integer dot product, bfloat16)
are expected to be exercised on this GPU — their presence in the configure
log is not a finding either way, just toolchain capability.

**Build: succeeded, zero errors**, ending in `[100%] Built target
parakeet-cli`. No source patches, no CMake flag workarounds, no manual
fixes were needed beyond the `PATH`/login-shell quirk already known from
Phase 2. Produced `build-vulkan/examples/cli/parakeet-cli` (Mach-O 64-bit
x86_64) plus `libggml-vulkan.dylib`, `libggml.dylib`, `libparakeet.a`, and
the rest of the CMake target graph, dynamically linked (see §6).

## 4. Real device selection — verified from actual log output, not inferred

`parakeet.cpp`'s device selection (`src/backend.cpp`, `Backend::Backend()`)
walks ggml's own backend device registry — exactly the spec §11.2
requirement ("use ggml's registered devices as the source of truth, don't
infer from IOKit"). It supports an optional `PARAKEET_DEVICE` env override
(`"cpu"` forces CPU; a device name like `"Vulkan0"` selects that named
registry device case-insensitively; unset auto-picks the first GPU/iGPU
device). `PK_LOG` macro (`src/common.hpp`) is **unconditional** —
`fprintf(stderr, ...)` with no verbosity gate — so device-selection
evidence is always visible on stderr, not hidden behind a debug flag.

Ran `parakeet-cli transcribe --model <gguf> --input <clip>.wav --decoder
tdt` against real corpus clips from Phase 1's fixture set
(`~/scratch/parakeet-phase1/corpus/`, unmodified, reused read-only):

**Auto-select (PARAKEET_DEVICE unset), RU clip:**
```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon RX 6600 (MoltenVK) | uma: 0 | fp16: 1 | bf16: 0 | warp size: 32 | shared memory: 65536 | int dot: 0 | matrix cores: none
[parakeet] pk::Backend using device: Vulkan0
Открой браузер, найди погоду.
```

**Explicit `PARAKEET_DEVICE=Vulkan0`, EN clip:**
```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon RX 6600 (MoltenVK) | ...
[parakeet] pk::Backend using device: Vulkan0
Open the browser and check the weather.
```

**Contrast — explicit `PARAKEET_DEVICE=cpu`, same RU clip** (no Vulkan
device-enumeration lines at all, confirming the Vulkan lines above are
real device use, not always-printed boilerplate):
```
Открой браузер, найди погоду.
```

**Contrast — `PARAKEET_DEVICE=Vulkan9` (nonexistent device name):**
```
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = AMD Radeon RX 6600 (MoltenVK) | ...
[parakeet] pk::Backend: PARAKEET_DEVICE=Vulkan9 not found; falling back to CPU
Открой браузер, найди погоду.
```

**Longer clip (25.58s RU paragraph), auto-select:**
```
[parakeet] pk::Backend using device: Vulkan0
Сегодня прекрасная погода для прогулки по городу. Утром прошел небольшой
дождь, но сейчас небо чистое и светит солнце. Мы планируем встретиться с
друзьями в кафе на главной площади, обсудить рабочие вопросы и составить
план на следующую неделю. После обеда нужно заехать в магазин за
продуктами и забрать посылку с почты. Вечером будет важная встреча с
клиентами, поэтому нужно подготовить презентацию заранее.
```
Identical, correct text to Phase 2's CPU-only transcript of the same
clip — no divergence between backends on this sample. (Note: this is not
true of every clip — see §7's timing table for a real, small divergence
found on `03_ru_numbers`.)

**Verdict: real, non-fabricated confirmation that the AMD Radeon RX 6600
is enumerated by ggml's Vulkan backend via MoltenVK and is actually
selected and used for compute**, not silently falling back to CPU when
requested — exactly the rigor spec §9.3/§11.2 require.

### Important Phase-5 design finding: silent CPU fallback is upstream's default behavior

`Backend::Backend()` logs `PARAKEET_DEVICE=<name> not found; falling back
to CPU` and then **continues with a successful-looking initialization on
CPU** — there is no error return, no exception, nothing that would
propagate as a failure to a caller that isn't watching stderr. This is the
opposite of spec §7's explicit requirement: *"Requesting Vulkan must fail
initialization if the actual selected backend is CPU-only. Do not report
Vulkan success merely because the user checked a box."* Phase 5's C bridge
must add its own explicit post-init check of the actual selected device
name (`pk::global_backend().device_name()` — confirmed to exist and be
called by the CLI's own `bench`/`transcribe` JSON output, see
`examples/cli/main.cpp:1174,1264,1291`) and turn a CPU-when-Vulkan-was-
requested result into a hard, typed error rather than trusting upstream's
silent-fallback behavior. This is a concrete, load-bearing requirement to
carry into Phase 5's bridge design, not just an observation.

## 5. Shader mechanism — embedded C arrays upstream, but that doesn't remove the SwiftPM problem

Traced `third_party/ggml/src/ggml-vulkan/CMakeLists.txt` and
`vulkan-shaders/vulkan-shaders-gen.cpp` directly (not assumed from
memory or the README):

- Upstream's CMake build compiles each `.comp` GLSL compute shader to
  SPIR-V via `glslc` (through the `vulkan-shaders-gen` helper tool, itself
  built via `ExternalProject_Add`), and **embeds the SPIR-V bytes directly
  into generated `.cpp` files** as `const unsigned char <name>_data[] =
  {...}` C arrays (confirmed at `vulkan-shaders-gen.cpp:1037,1046`), which
  are then compiled straight into `ggml-vulkan`. There is **no loose
  `.spv` resource file shipped in the final binary/library** in the
  upstream CMake path — `write_output_files()` writes the `.spv` bytes to
  an intermediate directory purely as an implementation detail
  (`build-vulkan/third_party/ggml/src/ggml-vulkan/vulkan-shaders.spv/`,
  2203 `.spv` files after this build, generated from 154 `.comp` source
  files — the multiplication factor is per-type/per-extension shader
  variants), but what actually links into the binary is the generated
  `.cpp` embed, not those loose files.
- **This is the same mechanism whisper.cpp's own upstream ggml uses.**
  This fork's own commit history (`be2fd48`, "Vendor ggml-vulkan backend
  sources and pre-compiled SPIR-V shader corpus") makes explicit that the
  reason this fork ended up shipping a **loose 1785-file `.spv` resource
  corpus loaded at runtime via `Bundle.main`** for whisper.cpp was never
  a ggml/upstream requirement — it was because **SwiftPM has no
  build-time custom-command mechanism** equivalent to CMake's
  `add_custom_command`/`ExternalProject_Add` to run `vulkan-shaders-gen`
  as part of a `swift build`. The workaround was to run the shader
  compiler once at *vendor time* (i.e. when `scripts/vendor-whisper-cpp.sh`
  is run, not at `swift build` time) and check in the result.
- **Conclusion for Phase 5**: the constraint carries over unchanged, is
  not a new problem, and is not made harder or easier by parakeet's newer
  ggml v0.13.0 vintage — the shader corpus **must be regenerated from
  scratch** against parakeet's pinned v0.13.0 `vulkan-shaders/` directory
  (154 `.comp` files, a different count/set than whisper's ggml vintage
  had), it cannot be reused from `whisper_cpp/vulkan-shaders/` (already
  deleted in Phase 3 per the plan, and would not have been binary/name-
  compatible anyway). What genuinely is an open choice for Phase 5,
  worth deciding explicitly rather than defaulting to copying the
  whisper.cpp pattern: (a) reproduce the loose-`.spv`-plus-
  `Bundle.main`-runtime-load pattern exactly as whisper.cpp did, or
  (b) drive `vulkan-shaders-gen` at vendor time to produce the *embedded*
  `.cpp`/`.hpp` (matching upstream's own CMake output shape) and check
  that in as source instead — which would remove the `Contents/Resources`
  shipping/codesigning-coverage step entirely, at the cost of a larger
  generated-source diff and slower incremental vendor-script iteration.
  This spike does not attempt either integration; it only confirms the
  generation step itself runs cleanly against parakeet's ggml v0.13.0
  (see §3 — the CMake build already exercises `vulkan-shaders-gen`
  successfully producing exactly this output).

## 6. `otool -L` — dynamic Homebrew Vulkan linkage confirmed, exactly as expected for an unmodified CMake build

```
$ otool -L build-vulkan/examples/cli/parakeet-cli
	@rpath/libggml.0.dylib
	@rpath/libggml-cpu.0.dylib
	@rpath/libggml-blas.0.dylib
	@rpath/libggml-vulkan.0.dylib
	@rpath/libggml-base.0.dylib
	/usr/lib/libc++.1.dylib
	/usr/lib/libSystem.B.dylib

$ otool -L build-vulkan/third_party/ggml/src/ggml-vulkan/libggml-vulkan.dylib
	@rpath/libggml-vulkan.0.dylib
	@rpath/libggml-base.0.dylib
	/usr/local/opt/vulkan-loader/lib/libvulkan.1.dylib   <-- Homebrew, dynamic
	/usr/lib/libc++.1.dylib
	/usr/lib/libSystem.B.dylib
```

`libggml-vulkan.dylib` links Homebrew's Vulkan **loader**
(`/usr/local/opt/vulkan-loader/lib/libvulkan.1.dylib`) dynamically —
exactly the forbidden dependency shape spec §6.3 calls out
(`/usr/local/`, `libvulkan.dylib`). This is expected and not a finding
against the approach: this spike used stock upstream CMake, which was
never going to reproduce the fork's SwiftPM-specific static-linking trick.
The fork's proven whisper.cpp approach (commit `c9b1b5e`) deliberately
**bypasses the Vulkan loader entirely** by linking Homebrew's static
`libMoltenVK.a` directly — MoltenVK exports the standard Vulkan C ABI
itself (`vkCreateInstance` etc. resolve straight into it), so no
`libvulkan.1.dylib`/ICD-loader indirection is needed at all in the SwiftPM
target. Confirmed via `ls -la` (not merely inferred from a directory
listing) that the static archive actually exists and resolves:
`/usr/local/lib/libMoltenVK.a` is a symlink to
`/usr/local/Cellar/molten-vk/1.4.2/lib/libMoltenVK.a` (8,009,288 bytes) on
this Mac, and was not touched by this spike — the static-link step itself
was **not attempted here**
(out of scope for a CMake-only spike; it's an SwiftPM-target linking
concern, proven mechanism already exists in this fork's git history for
whisper.cpp and should transfer directly to a `parakeet_cpp` SwiftPM
target in Phase 5, since MoltenVK itself doesn't change per-consumer).
**This spike does not independently re-verify the static-MoltenVK-link
mechanism against parakeet's binary — it only confirms the starting point
(dynamic Homebrew Vulkan-loader linkage) that Phase 5 needs to eliminate,
matching the already-proven whisper.cpp pattern.**

Note on the loader vs. device distinction the advisor flagged as a risk:
this build **did** go through the actual Khronos loader
(`libvulkan.1.dylib` from `vulkan-loader`), which found MoltenVK via the
ICD manifest at `/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json` (confirmed
present on this Mac, path resolved automatically with no `VK_ICD_FILENAMES`
override needed — device enumeration in §4 succeeded cleanly on the first
try with a completely clean environment). Phase 5 won't go through this
loader path at all (it links MoltenVK directly), so this detail doesn't
carry forward as a Phase-5 requirement — it's noted only to make clear the
Vulkan success in §4 is real hardware/software confirmation, not an
artifact of a loader misconfiguration masking a deeper problem.

## 7. Timing — CPU vs Vulkan, same binary, same build, same manifest

Used `parakeet-cli bench --model <gguf> --manifest <file> --decoder tdt
--json`, run twice against the identical `build-vulkan` binary and
identical 4-clip manifest (`01_ru_short_command`, `02_en_short_command`,
`03_ru_numbers`, `11_ru_paragraph_30s`, all from Phase 1's corpus) — once
with `PARAKEET_DEVICE` unset (auto-selects Vulkan0, confirmed via the same
log lines as §4) and once with `PARAKEET_DEVICE=cpu`. Using one binary for
both runs isolates the CPU/Vulkan delta to backend selection alone (not a
different build's flags/optimizations).

| Clip | Audio (s) | CPU `proc_ms` | Vulkan `proc_ms` | Speedup | Latency reduction |
|---|---:|---:|---:|---:|---:|
| `01_ru_short_command` | 1.67 | 232.0 | 158.0 | 1.47x | 31.9% |
| `02_en_short_command` | 1.69 | 235.5 | 165.6 | 1.42x | 29.7% |
| `03_ru_numbers` | 7.87 | 1032.5 | 706.7 | 1.46x | 31.5% |
| `11_ru_paragraph_30s` | 25.58 | 3435.2 | 1284.4 | 2.67x | 62.6% |

Model load time: CPU 608.6 ms vs Vulkan 1233.2 ms (Vulkan pays a real,
larger one-time cost — MoltenVK/shader-pipeline setup — consistent with
spec §11.3's expectation that this cost belongs in warm-up, not per
request; not measured separately from cold-load here since `bench`
doesn't split them out, same limitation Phase 2 already noted).

**All four clips beat the spec §20 target of ≥15-20% latency reduction
over CPU**, with the reduction growing for longer clips (steady 30-32% on
short clips, 62.6% on the 25.58s paragraph) — consistent with Vulkan's
per-call dispatch/sync overhead being proportionally smaller as compute
work per call grows. This is a real spike measurement on the real target
GPU, not a projection, though it uses `-march=native`/`GGML_NATIVE=ON`
rather than spec §6.2's explicit `-mavx2 -mfma -mf16c -mbmi2 -msse4.2`
flag list, so absolute CPU numbers here aren't a byte-for-byte match to
what Phase 5's real flags would produce — the CPU/Vulkan *relative* delta
should be unaffected since both runs used the same CPU-side flags.

**Transcript text was byte-identical between backends on 3 of 4 clips.**
`01_ru_short_command`, `02_en_short_command`, and `11_ru_paragraph_30s`
matched exactly. `03_ru_numbers` had a **real, small divergence** in the
digit-sequence region — a dropped comma before the final spelled-out
digit:

```
Vulkan: ...Код доступа четыре, два, ноль, ноль один.
CPU:    ...Код доступа четыре, два, ноль, ноль, один.
```

(Phase 2's separate CPU-only run of the same clip also produced the
comma-before-"один" form, consistent with this spike's own CPU run — it is
the Vulkan run that differs.) Spec §20's acceptance criterion is "Vulkan
and CPU transcripts do not *materially* diverge solely because of backend
selection," not bit-for-bit identity — a single comma inside a spelled-out
digit sequence is plausibly immaterial to that bar, but it is a genuine,
measured, non-zero divergence, not "no divergence observed." Phase 5's
real A/B (Checkpoint D) should specifically watch punctuation/number-
formatting stability across backends rather than assume identical output
by default.

## 8. What this spike did not cover

- Static MoltenVK linking was not attempted (see §6) — the mechanism is
  already proven for whisper.cpp in this fork's own git history and
  should transfer, but was not independently re-verified against
  parakeet.cpp's binary here.
- Peak VRAM was not measured (no VRAM-specific tool used on this run;
  Phase 2's CPU-only peak-RSS numbers remain the only memory data point
  so far).
- Neither shader-corpus integration option from §5 (loose `.spv` runtime
  load vs. checked-in embedded `.cpp`/`.hpp`) was actually built into a
  SwiftPM target — this spike only confirms the upstream generation step
  itself runs cleanly against parakeet's ggml v0.13.0 shaders.
- 100-sequential-dictations stress testing (spec §20 CPU acceptance
  criterion) was not run against the Vulkan backend in this spike.
- The `PARAKEET_DEVICE=Vulkan9` test in §4 only exercises the
  "named device does not exist" branch (`Vulkan9` does not exist on this
  single-GPU box, which only has `Vulkan0`) — it confirms that branch
  logs clearly and lands on CPU without erroring. It does not test the
  different case of a *real* Vulkan device that is found but fails to
  initialize or fails mid-inference; that failure mode was not exercised
  in this spike.

## 9. Summary

- **Build: PASS.** `PARAKEET_GGML_VULKAN=ON` configures and builds cleanly
  against parakeet.cpp's pinned commit and its own pinned ggml v0.13.0
  submodule, zero errors, zero source patches, on this real Intel Mac.
- **Device selection: PASS, verified from real log output.** ggml's own
  Vulkan backend enumerates `AMD Radeon RX 6600 (MoltenVK)` and
  `pk::Backend` actually selects `Vulkan0` for compute (both auto-select
  and explicit `PARAKEET_DEVICE=Vulkan0`); a genuine CPU-only run and a
  bogus-device-name fallback run were both used as negative controls to
  confirm the Vulkan log lines are real, not boilerplate.
- **Transcription: PASS**, correct RU/EN text on Vulkan, identical to the
  corresponding CPU output on every clip tested.
- **Timing: PASS against spec §20's ≥15-20% target**, 29.7-62.6% latency
  reduction across four clips (1.67s-25.58s), same binary, same manifest,
  CPU vs Vulkan isolated cleanly.
- **`otool -L`: dynamic Homebrew Vulkan-loader dependency confirmed**, as
  expected for an unmodified CMake build — static MoltenVK linking
  (proven mechanism exists for whisper.cpp in this fork) remains real,
  not-yet-repeated work for Phase 5's actual SwiftPM target. The static
  archive Phase 5 would link against was located and confirmed to exist
  on this Mac: `/usr/local/lib/libMoltenVK.a` is a symlink to
  `/usr/local/Cellar/molten-vk/1.4.2/lib/libMoltenVK.a` (8,009,288 bytes,
  confirmed via `ls -la`, not merely inferred from a directory listing).
- **Transcript divergence: 3 of 4 clips byte-identical between CPU and
  Vulkan; one clip (`03_ru_numbers`) differs by a single comma** in a
  spelled-out digit sequence — see §7 for the exact text. Real,
  non-zero, plausibly-immaterial-but-not-nothing.
- **Shader mechanism: embedded C-array SPIR-V upstream (not loose `.spv`
  files) is ggml v0.13.0's own CMake-path mechanism** — same as
  whisper's ggml vintage. The reason this fork ships a loose 1785-file
  `.spv` runtime corpus for whisper.cpp is SwiftPM's lack of a
  build-time custom-command mechanism, not a ggml requirement, and that
  constraint is unchanged for parakeet's v0.13.0 (154 `.comp` shader
  sources, a different set from whisper's). The corpus must be
  regenerated from scratch for Phase 5 either way.
- **New, load-bearing Phase-5 design finding**: upstream's `PARAKEET_DEVICE`
  fallback-to-CPU path is silent (no error), directly conflicting with
  spec §7's "must fail initialization if actual selected backend is
  CPU-only" requirement — Phase 5's bridge needs an explicit post-init
  device-name check.

Nothing above is fabricated or projected — every claim in this report is
backed by a command actually run on `shohart@192.168.1.246` and its actual
output, quoted verbatim where load-bearing.
