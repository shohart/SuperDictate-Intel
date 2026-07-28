# Plan: migrate ASR from whisper.cpp to parakeet.cpp (NVIDIA Parakeet TDT 0.6B v3)

Branch: `agent/parakeet-intel-backend-architecture` (worktree
`.worktrees/parakeet-migration`), synced to `main`@`3449355` (v0.3.1).

Detailed target-state spec: `docs/parakeet-intel-backend.md` (already on this
branch, 1236 lines, written before this plan). That document is the
authoritative reference for API shapes, error contracts, and the Definition
of Done checklist. This plan sequences it into gated phases that match how
this project actually ships changes (real-hardware verification at every
step, SDD implement→review→fix-round cycles, no step that can't be measured
before the next one starts).

## Why re-sequence the existing spec instead of executing it as written

Advisor + fresh research (2026-07-28) surfaced four corrections to the
spec's own Phase 1-6 ordering:

1. **`parakeet.cpp` is real and well-grounded** — confirmed via
   `github.com/mudler/parakeet.cpp` (MIT, 727 stars, actively maintained,
   last push same day as this research). It ships a real flat C-API
   (`include/parakeet_capi.h`), GGUF quantizations including `q8_0`, and a
   `PARAKEET_GGML_VULKAN` CMake option. The spec's premise is sound — no
   need to re-verify it.
2. **Russian is confirmed supported**: `nvidia/parakeet-tdt-0.6b-v3`'s model
   card lists `ru` explicitly among its 25 languages (not inferred from
   "European").
3. **Vulkan-on-macOS-x64 is explicitly untested upstream.** parakeet.cpp's
   own `AGENTS.md`: *"targets CPU (GPU backends are wired but not exercised
   in CI)"*, and its release matrix ships macOS x64 as CPU-only (Linux/
   Windows x64 get Vulkan builds; macOS arm64 gets Metal). This is the same
   shape as the Metal-on-AMD failure this fork already root-caused once.
   Sequence so a Vulkan failure is a non-event: Parakeet CPU must be
   independently shippable, and gets measured *before* any Vulkan work.
4. **Two ggml copies in one binary is a real link hazard, not
   theoretical.** parakeet.cpp pins its own ggml submodule at `v0.13.0`,
   unrelated in vintage to this fork's vendored whisper ggml. The spec's own
   phase order keeps both trees compiling into the same executable through
   its Phase 4. Fix: from the first phase that touches the `Parakey`
   executable target, the target depends on **exactly one** of
   `whisper_cpp` / `parakeet_cpp` at a time — never both. Whisper's source
   stays on disk (compiled or not) until the final removal phase, giving a
   one-line rollback (`dependencies:` swap in `Package.swift`) at every
   intermediate phase.

Additionally: `main.swift` already contains a real, working
`SpeechModelTextRepair.apply(to:language:)` (main.swift:5659-5714) with the
comment *"Parakeet TDT v3 emits `<unk>` for Cyrillic 'ё' in Russian text"*.
This is leftover from the **old CoreML/ANE/FluidAudio** Parakeet stack (the
`verifyParakeetV3Model`/`ModelFileDigest`/`.mlmodelc` machinery nearby is
Apple-Silicon-only and dead on this Intel fork) — a different runtime than
`parakeet.cpp`+GGUF, so it must not be assumed to apply as-is. But it's
strong corroborating evidence the `<unk>`→`ё` quirk is a real, known
property of Parakeet's tokenizer/vocab (likely shared across NeMo-derived
runtimes), and the logic + tests are free to reuse *if* the same quirk is
empirically confirmed against parakeet.cpp's actual output — not assumed.

## Non-negotiable decisions (unchanged from the existing spec, restated)

- Parakeet is the only production ASR engine once the migration completes.
  No hidden Whisper fallback, no automatic engine picker.
- In-process static integration — no helper process, no subprocess, no
  local HTTP/socket server, matching this fork's existing whisper.cpp
  architecture and rationale (single process, single ggml instance).
- Model loaded once per session, reused for every dictation.
- CPU is the default and must work standalone; `Use GPU (Vulkan)` is
  opt-in and must fall back to Parakeet CPU on any failure — never to
  Whisper.
- Model pinned by immutable revision, exact filename, exact byte size,
  exact SHA-256. No `main`/`latest` references.

## Pinned versions (captured 2026-07-28, re-verify at Phase 2 kickoff)

```
PARAKEET_CPP_COMMIT       = e747acdaee69b916cef62263ae5f718bda9ff3f3   (github.com/mudler/parakeet.cpp @ master)
GGML_COMMIT                = pinned internally by parakeet.cpp's own submodule at v0.13.0 (do not override)
PARAKEET_MODEL_REPOSITORY  = mudler/parakeet-cpp-gguf   (Hugging Face)
PARAKEET_MODEL_REVISION    = bf0af9f425fa01809cadec671b3cb672709d13e9
PARAKEET_MODEL_FILENAME    = tdt-0.6b-v3-q8_0.gguf
PARAKEET_MODEL_SIZE_BYTES  = 940663680
PARAKEET_MODEL_SHA256      = <TO BE COMPUTED IN PHASE 2 from the real downloaded bytes -- do not trust any hash from an API response>
PARAKEET_MODEL_ARCH        = parakeet (TDT, hybrid)
PARAKEET_MODEL_QUANTIZATION = q8_0
```

## Phase gates (explicit stop/go points)

- **Gate A (end of Phase 2)**: standalone CPU spike produces a correct
  transcript from real audio on the real Intel Mac, outside the app. If
  this fails, nothing else in this plan proceeds.
- **Gate B (end of Phase 3)**: Parakeet CPU is fully wired into the real
  application (hotkey → capture → transcribe → paste → history) end to end
  on real hardware, Whisper is compile-time excluded from the executable
  (source untouched on disk), self-tests pass.
- **Gate C (end of Phase 4 — the accuracy/perf gate)**: a real A/B on the
  user's own Russian audio (names, numbers, technical terms, mixed
  RU/EN, short commands, a long monologue) comparing Parakeet CPU against
  the currently-shipped Whisper+Vulkan v0.3.1. **This is presented to the
  user for a decision before Phase 6 (Whisper deletion) starts.** A newer
  model is not assumed better for this specific language/use case; if the
  A/B shows a regression, the plan stops here (or Vulkan is added first
  and re-measured) rather than deleting Whisper on faith.
- **Gate D (end of Phase 5, optional)**: Parakeet Vulkan measured against
  Parakeet CPU on the real RX 6600. Only pursued if Gate C's CPU numbers
  are promising enough that GPU speedup is worth the added risk (matches
  the spec's own §20 target: ≥15-20% latency reduction over CPU, reported
  honestly either way).
- **Gate E (end of Phase 6)**: Whisper fully removed — only entered after
  explicit user sign-off on Gate C's results.

## Phases

### Phase 0 — sync (done)

Merged `main`@`3449355` into this branch (worktree
`.worktrees/parakeet-migration`), clean merge, no conflicts.

### Phase 1 — freeze the baseline

- Run and record the current self-test suite (`swift run -c debug
  --package-path swift Parakey --self-test all`) on real hardware as the
  pre-migration baseline.
- Assemble the Russian-heavy benchmark corpus (§19 of the spec: 3s/10s/
  30s/120s clips, RU/EN/mixed, names, numbers, addresses, technical terms,
  short commands, one long monologue) — record how the *current shipped*
  Whisper+Vulkan v0.3.1 transcribes each clip (text + latency), on the real
  Mac. This is Gate C's comparison baseline. No private user recordings
  committed to the repo; store fixtures outside git or synthesize/record
  neutral content.
- Identify every ASR integration point in `main.swift`/`WhisperEngine.swift`
  (model download/cache, `TranscriptionWorker`, settings, self-tests,
  README) as a checklist for Phase 3/6, without editing anything yet.

### Phase 2 — standalone parakeet.cpp CPU spike (Gate A)

Mirrors this project's own established spike pattern (the Vulkan work did
the same thing first, as a fully separate SwiftPM package — see commits
`c9b1b5e`/`874c034` in this repo's history — and this branch's own prior,
now-removed, helper-process spike attempted something similar but was
rejected for being out-of-process).

- New, fully isolated SwiftPM package (not wired into the `Parakey`
  executable's dependency graph at all — no shared `Package.swift` target).
- Clone `mudler/parakeet.cpp` at the pinned commit with submodules
  (`--recursive`, pulling its own pinned ggml v0.13.0), build CPU-only
  (`PARAKEET_BUILD_TESTS=ON`, no GPU flags), on the real Intel Mac over
  SSH.
- Download the pinned GGUF for real, verify its actual SHA-256 against
  what's recorded above (compute it fresh — do not trust a value copied
  from an API response), fill in `PARAKEET_MODEL_SHA256` in this plan.
- Run `parakeet-cli transcribe` against 2-3 fixture clips from the Phase 1
  corpus and confirm non-garbage Russian and English output.
- Record: pinned commit (re-confirmed), real SHA-256, model load time,
  first-inference latency, peak RSS.

**Gate A must pass on real hardware before Phase 3 starts.**

### Phase 3 — application integration, CPU only (Gate B)

- `scripts/vendor-parakeet-cpp.sh` per spec §5: deterministic vendoring
  into `swift/Sources/parakeet_cpp/` (inference sources + the pinned ggml
  submodule's CPU backend only at this phase; exclude examples/server/
  Python/test corpora from the shipped tree).
- New SwiftPM target `parakeet_cpp` in `Package.swift`. Wrap
  `include/parakeet_capi.h` directly rather than re-inventing a bridge
  (the spec's `SDParakeet*` naming in §7 is aspirational; parakeet.cpp's
  own `parakeet_capi_*` functions already provide equivalent load-once,
  exception-free, PCM-in/UTF-8-out semantics — a thin Swift-facing rename/
  wrapper is enough, not a from-scratch C ABI).
- **Change the `Parakey` executable target's `dependencies` from
  `whisper_cpp` to `parakeet_cpp`.** `whisper_cpp`'s source tree and
  `Package.swift` target definition stay on disk untouched — this is the
  rollback point for the rest of the migration, until Phase 6.
- `ParakeetEngine` Swift wrapper (spec §8), new model storage path
  (`~/Library/Application Support/SuperDictate/Models/`, spec §4), new
  downloader with the same integrity guarantees the Whisper downloader
  already has (atomic temp-file + rename, symlink/special-file rejection,
  disk-space check).
- Replace `WhisperEngine` usage in `TranscriptionWorker` with
  `ParakeetEngine` (spec §9), CPU-only branch of the loading algorithm
  only (skip the Vulkan branch this phase).
- New persisted GPU-preference key (`parakeetUseGPU`, spec §10) — do not
  inherit the old Whisper `useGPU` value; clean installs and upgrades both
  default to CPU. (The setting exists in storage/model terms this phase;
  the UI checkbox and actual Vulkan branch land in Phase 5.)
- Empirically test the `<unk>`/`ё` quirk against parakeet.cpp's actual
  Russian output on real audio. If confirmed, adapt/reuse
  `SpeechModelTextRepair` (rename per spec §13 if helpful) with the same
  test coverage (sentence-initial, mid-word, punctuation-adjacent, repeated
  tokens, RU/auto/non-RU). If not confirmed, drop that assumption from the
  plan and document what parakeet.cpp actually emits instead.
- Full self-test suite green, end-to-end real-hardware dictation (hotkey →
  capture → Parakeet CPU transcribe → paste → history) proven live, same
  as every prior real-hardware verification in this project's history.

**Gate B must pass on real hardware before Phase 4 starts.**

### Phase 4 — A/B measurement against the shipped baseline (Gate C)

- Run the full Phase 1 corpus through the now-integrated Parakeet CPU path
  on the real Mac; compare text and latency against the Phase 1 Whisper
  baseline, clip by clip.
- Report to the user: accuracy (qualitative, since there's no ground-truth
  transcript, but flag any garbled/hallucinated/wrong-language output),
  latency/RTF, peak RAM, and the `<unk>`/`ё` finding from Phase 3.
- **Stop and present this to the user before Phase 6.** Possible outcomes:
  continue to Phase 5 (Vulkan) then Phase 6 (removal); skip Vulkan and go
  straight to Phase 6; or stop the migration here if Parakeet regresses on
  the user's actual dictation content.

### Phase 5 — Vulkan add-on (optional, only if Gate C looks promising)

- Add `PARAKEET_GGML_VULKAN` to the vendor script and `parakeet_cpp`
  target, forward the same static-MoltenVK linking pattern already proven
  in this fork's Whisper Vulkan work (`opt/`-symlink-based Homebrew paths
  at build time, static link, no runtime Homebrew dependency, verified via
  `otool -L`).
- **A fresh SPIR-V shader corpus is required** — the existing 1785 `.spv`
  files under `whisper_cpp/vulkan-shaders/` were generated against
  whisper's ggml vintage and are not reusable against ggml v0.13.0. Budget
  this as its own sub-step (it was effectively a mini-project during the
  Whisper Vulkan work too).
- Real device probing via ggml's registry (spec §11.2 — never infer from
  IOKit alone), warm-up with timeout, CPU fallback on any Vulkan
  init/inference failure (spec §9.3), wire the existing `Use GPU (Vulkan)`
  checkbox to the new `parakeetUseGPU` key.
- Benchmark Parakeet Vulkan vs Parakeet CPU on the real RX 6600, report
  honestly (spec §20 target is ≥15-20% latency reduction, not guaranteed).

**Gate D**: report results; user decides whether Vulkan ships enabled,
ships but off-by-default, or is deferred.

### Phase 6 — remove Whisper entirely (Gate E, only after user sign-off on Gate C)

- Delete `swift/Sources/whisper_cpp/`, the `whisper_cpp` SwiftPM target,
  all Whisper compile definitions/constants/comments/tests, the old model
  cache path handling (leave the legacy `~/Library/Application
  Support/Whisper` directory alone per spec §4.4 — do not recursively
  delete a user directory).
- `rg -n -i "whisper|large-v3-turbo|whisper_cpp" .` → no matches (or
  narrowly justified changelog mentions only).
- `nm -gU`/`strings` on the built binary → no Whisper symbols/strings.
- Update `scripts/build-app.sh`, `scripts/dev-run.sh`, `install.sh`,
  `uninstall.sh`, README, this plan's own spec doc if anything drifted.

### Phase 7 — packaging, benchmarking, release

- `scripts/benchmark-parakeet.sh` (spec §19) as a permanent, re-runnable
  script (not a one-off spike).
- Full validation command suite (spec §24): shell syntax checks, plist
  lint, self-tests, `build-app.sh`, `codesign --verify --deep --strict`,
  `otool -L` (no Homebrew paths), `file`/`lipo` arch checks, Whisper-absence
  checks.
- Implementation report per spec §27 (pinned commits, model metadata,
  license notices, flags, thread counts, actual Vulkan device if
  applicable, benchmarks, known limitations).
- Delete this plan doc and the `.superpowers/sdd/` workspace before
  merging to `main`, per this project's standing "no internal Claude
  planning docs in the tracked repo" rule (same as every prior plan in
  this project's history). `docs/parakeet-intel-backend.md` (the original
  target-state spec) may be kept or removed at the user's discretion at
  that point — it documents real architecture decisions, unlike this
  phase-sequencing plan, so it is more likely to be worth keeping.

## Process notes carried forward from this session's own hard-won lessons

- Every scratch launch on the Mac during this migration must first run
  `defaults write com.local.superdictate agent_enabled -bool false` (or
  otherwise avoid triggering `installAndStart()`) — the LaunchAgent-plist
  clobber bug is still live and unfixed, fired twice during Task 6 of the
  prior migration, and this migration will launch scratch binaries far
  more often. The user's TCC grants were painful to obtain (SSH-triggered
  TCC requests crash with SIGILL, self-healed via `KeepAlive` respawn) —
  do not spend them again without cause.
- Every background implementer dispatched for this plan must be told
  explicitly, in the dispatch prompt: *"no notification will wake you
  automatically; if you're waiting on a build/process, poll it yourself
  directly over SSH (sleep+ps loop), don't say 'waiting for
  notification.'"* This stalled 4 out of 4 background agents in the prior
  migration and needed a manual resume every time.
- All builds/tests run for real on the Intel Mac (`shohart@192.168.1.246`),
  never assumed or fabricated. Any transcription corruption found during
  hardware verification is a hard blocking finding.
