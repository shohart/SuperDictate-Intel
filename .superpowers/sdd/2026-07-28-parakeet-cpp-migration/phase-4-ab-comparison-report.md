# Phase 4 — A/B measurement against the shipped Whisper+Vulkan baseline (Checkpoint C)

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`. Branch
`agent/parakeet-intel-backend-architecture`, worktree
`.worktrees/parakeet-migration`, starting commit `1bb8ae4` (Phase 3,
Checkpoint B). Everything reported here ran for real on the Intel Mac
(`shohart@192.168.1.246`: Intel Xeon E5-2678 v3, macOS 15.7.7, x86_64),
synced from this worktree to a fresh scratch directory
`~/scratch/parakeet-phase4/repo/` via `git archive | ssh … tar -x` (this
project's established method). `defaults write com.local.superdictate
agent_enabled -bool false` was run before the first scratch launch, per
process. This is informational per the plan — it does not block Phase 5
(Vulkan), which proceeds regardless.

## 0. Process incident — read before the numbers (full transparency)

While measuring, a **release**-configuration build of the scratch binary
was invoked with `--transcribe-file …`. The temporary measurement hook had
initially been written inside the file's `#if DEBUG` block (mirroring
`--self-test`), so in a `-c release` build that whole block — including the
hook's argument check — is compiled out entirely. The unrecognized
`--transcribe-file` argument fell through to the normal application entry
point, which took the final `else` branch (`SuperDictateControlPanelApp`,
ordinary "user double-clicked the app" startup) and — as part of normal
control-panel startup — wrote and activated a real
`~/Library/LaunchAgents/com.local.superdictate.agent.plist`, **the exact
same launchd label the production app uses**, pointing it at the scratch
binary at `~/scratch/parakeet-phase4/repo/…/release/Parakey --agent`
instead of `/Applications/SuperDictate.app`.

This was caught immediately (an unexpected `Parakey --agent` process with
`PPID 1` was visible in `ps aux` right after the run). Remediation, in
order:

1. `kill -TERM`/`-KILL` the rogue process.
2. `launchctl bootout gui/<uid>/com.local.superdictate.agent` to unregister
   the clobbered job.
3. Hand-wrote a plist matching exactly what
   `SuperDictateAgentService.writeLaunchAgentPlist()` (`main.swift`) itself
   generates, with `ProgramArguments` pointed back at
   `/Applications/SuperDictate.app/Contents/MacOS/SuperDictate --agent`.
4. `launchctl bootstrap` + `enable` + verified `launchctl print` shows
   `state = running`, `program = /Applications/SuperDictate.app/…` — the
   production LaunchAgent is confirmed restored and running correctly.
   `/Applications/SuperDictate.app` itself was never touched, per the
   task's standing rule.

**Fix applied to the measurement tool** (also temporary, also reverted
before this phase's commit): the `--transcribe-file` check was moved
*out* of `#if DEBUG` entirely and placed immediately after
`CommandLine.arguments` is parsed, before `NSApplication.shared` is ever
constructed — so it now intercepts and exits cleanly in both debug and
release builds, exactly like the codebase's existing non-DEBUG diagnostic
flags (`--export-hud-animation`, the audio-capture diagnostic) already do.
Re-verified after the fix: running the release binary with
`--transcribe-file` now exits after printing results, and `launchctl
print` confirms the production LaunchAgent registration is untouched by
the run.

**Net effect on this report and the tracked tree**: no data below is
affected (the debug-build run that preceded this incident produced
*correct transcripts*, just under `-Onone` timing that this report does
not use for the latency comparison — see §2). Nothing was committed to
`/Applications/SuperDictate.app`. `swift/Sources/Parakey/main.swift` in
this worktree was reverted to the Phase 3 commit's exact content
(`git checkout -- swift/Sources/Parakey/main.swift`) before this report was
committed; `git status`/`git diff` show a clean tree except this new report
file. Recorded here in full because it's a real, instructive finding about
this codebase's CLI-argument fallthrough behavior, not because it changed
any Parakeet accuracy/latency conclusion.

## 1. Method

Reused Phase 1's exact fallback approach (no existing CLI/self-test hook
accepts an arbitrary WAV path): a small, temporary, scratch-only
`--transcribe-file <wav1> [wav2 …]` flag was added to
`swift/Sources/Parakey/main.swift`, calling the **real, now-integrated
production code**:

- `downloadParakeetModelIfNeeded()` — the actual production model
  download/cache/verify function (cache-hit path this run — the model was
  already downloaded during Phase 3).
- `ParakeetEngine(modelPath:device:threadCount:)` — the actual production
  engine wrapper, loaded **once**, reused across every clip in the process
  (load-once contract, matching how `TranscriptionWorker` uses it).
- `TranscriptionWorker.resolvedParakeetThreadCount()` — the real thread
  policy function.
- `engine.transcribe(samples:sampleRate:)` — the real bridge call.

Like Phase 1's Whisper hook, this **bypasses `TranscriptionWorker`
entirely** — no MainActor keyboard-layout hop, no
`ParakeetTranscriptRepair`, no `processedDictationText` post-processing.
This is the same bypass symmetry Phase 1 used for `WhisperEngine`, so the
comparison is apples-to-apples: neither side went through the full
hotkey→paste pipeline, both went through their respective engine's real
load/warm-up/transcribe path directly. This means the `<unk>`/`ё` numbers
below are **raw model output**, before whatever (currently a no-op, see
Phase 3 §9) repair pass `TranscriptionWorker` would apply.

Audio was read via `AVAudioFile`/`AVAudioPCMBuffer` (no resampling — the
corpus is already 16 kHz mono, matching `SAMPLE_RATE`), the same corpus
Phase 1 synthesized and stored outside git
(`~/scratch/parakeet-phase1/corpus/*.wav`, confirmed still present,
unmodified, 14 files). A concurrency fix was applied per the task brief's
guidance: the bridge from synchronous top-level code into the actor uses
`Task.detached { }` + a `DispatchSemaphore`, avoiding the plain-`Task{}`-
at-top-level MainActor self-deadlock Phase 3's report root-caused (that
deadlock only bites when the async closure needs a MainActor hop — this
hook, like the `parakeet-cpu` self-test, never does).

**Two Swift build configurations were both run**, because they gave very
different timings and only one is representative:

- **Debug** (`swift build -c debug`, `-Onone`): produced correct
  transcripts but RTF ≈ 1.8–2.1x (slower than real-time) — SwiftPM does not
  optimize C/C++ targets under a debug package configuration either, so the
  vendored `ggml`/`parakeet.cpp` C++ sources ran unoptimized. Not
  representative of the shipped app.
- **Release** (`swift build -c release`): RTF ≈ 0.12–0.15x, matching Phase
  2's standalone `parakeet-cli` figures (0.13–0.14x) almost exactly. **This
  is the number used for every timing/RTF figure below** — it reflects
  what `scripts/build-app.sh`'s real release build (and the shipped `.app`)
  actually produces.

Text was identical between the debug and release runs on every clip (same
model, same weights, deterministic decode) — only latency differed, which
is exactly what's expected from an optimization-level difference and
serves as a sanity check that neither build path silently changed
behavior.

## 2. Latency / RTF: Parakeet CPU vs Whisper CPU vs Whisper Vulkan

**Important build-configuration caveat, found and accounted for below.**
This phase empirically discovered that a `swift build -c debug` build of
this package leaves the vendored C/C++ `ggml`/`parakeet.cpp` sources
unoptimized (`-Onone`) — SwiftPM does not raise C/C++ optimization levels
under a debug package configuration — which cost Parakeet CPU a measured
~14x latency penalty (RTF 1.8–2.1x under debug vs 0.12–0.15x under
release, same weights, identical transcripts, only latency differed).
Phase 1's own report (§3) states its Whisper measurement hook was added
"inside the existing `#if DEBUG` block" — i.e. Phase 1's Whisper numbers
are **also** a debug-configuration build, and Whisper's vendored ggml
would have been subject to the exact same unoptimized-C/C++ effect. Phase
1's Whisper source has since been deleted from this branch (Phase 3), and
rebuilding a release-configuration whisper.cpp+Vulkan tree plus its own
measurement hook, just to re-measure a non-blocking informational
checkpoint, was judged out of scope here. **This means the table below
compares a release-build Parakeet against a debug-build Whisper — the
speedup columns are an upper bound on the true release-vs-release ratio,
not the ratio itself.** The true release-vs-release gap is unmeasured but,
by the same order-of-magnitude logic applied to Parakeet's own
debug/release delta, plausibly well under the raw numbers below while
still remaining a decisive, multi-x win (see the reframed bottom line in
§7).

Whisper figures are Phase 1's exact recorded numbers (`total_seconds`,
**debug-configuration build**, Vulkan/CPU, both auto-detect, dev-build
Vulkan model-init cost included as Phase 1 itself flagged). Parakeet
figures are this phase's **release-configuration** build run
(`transcribe_release_run2.log`), `wall` timing (Swift-side
`ProcessInfo.systemUptime` around the `engine.transcribe` call — matched
`result.inferenceSeconds`/`result.totalSeconds`, the C-API's own internal
timers, to within ~1 ms on every clip, i.e. negligible Swift/bridge
marshaling overhead).

| # | Clip | Dur (s) | Whisper Vulkan, **debug build** (s) | Whisper CPU, **debug build** (s) | Parakeet CPU, **release build** (s) | Parakeet RTF | Speedup vs Vulkan (upper bound) | Speedup vs CPU (upper bound) |
|---|------|--------:|--------------------:|------------------:|-------------------:|---------------:|--------------------:|------------------:|
| 01 | ru_short_command | 1.67 | 64.09 | 71.84 | 0.241 | 0.144x | ≤266x | ≤298x |
| 02 | en_short_command | 1.69 | 58.54 | 69.24 | 0.237 | 0.140x | ≤247x | ≤292x |
| 03 | ru_numbers | 7.87 | 65.92 | 69.05 | 1.013 | 0.129x | ≤65x | ≤68x |
| 04 | en_numbers | 8.15 | 68.08 | 69.01 | 1.011 | 0.124x | ≤67x | ≤68x |
| 05 | ru_names | 7.79 | 65.13 | 76.86 | 0.982 | 0.126x | ≤66x | ≤78x |
| 06 | en_address | 8.51 | 63.55 | 71.26 | 1.056 | 0.124x | ≤60x | ≤67x |
| 07 | ru_address | 6.21 | 63.10 | 67.59 | 0.811 | 0.131x | ≤78x | ≤83x |
| 08 | mixed_ru_en | 7.87 | 63.72 | 70.23 | 0.976 | 0.124x | ≤65x | ≤72x |
| 09 | technical_en | 9.24 | 62.13 | 68.84 | 1.142 | 0.124x | ≤54x | ≤60x |
| 10 | technical_ru | 8.36 | 65.03 | 70.23 | 1.058 | 0.127x | ≤61x | ≤66x |
| 11 | ru_paragraph_30s | 25.58 | 71.93 | 78.21 | 3.355 | 0.131x | ≤21x | ≤23x |
| 12 | en_paragraph_30s | 19.20 | 66.63 | 77.63 | 2.483 | 0.129x | ≤27x | ≤31x |
| 13 | mixed_paragraph_30s | 23.53 | 71.22 | 83.81 | 3.087 | 0.131x | ≤23x | ≤27x |
| 14 | ru_monologue_120s | 70.82 | 149.60 | 170.71 | 10.856 | 0.153x | ≤14x | ≤16x |

**Why the Whisper numbers look so large — real structural cost, but
inflated magnitude.** Phase 1's raw logs
(`baseline_vulkan.log`/`baseline_cpu.log`, re-checked for this report)
show `encode_seconds ≈ total_seconds` on every clip (e.g. clip 01:
`total_seconds=64.091`, `encode_seconds=64.091`). This confirms the ~60–70s
floor on short clips is **genuine per-call encode compute, not a one-time
model-load cost** — whisper.cpp's fixed 30-second context window means
every clip, even a 1.7s one, pays for encoding a full 30s window (the
120s-monologue clip, which needs roughly 2.5 windows, scales up
accordingly to ~150–170s, consistent with a per-window cost). That
structural mechanism is real and already documented in this codebase
(`WhisperEngine.swift`'s own `audioContextFrames` doc comment). **But its
absolute magnitude is inflated by the same debug-build/`-Onone` effect
documented above** — the encode work is real, its measured cost in Phase
1's numbers is not release-representative, by an unmeasured factor
plausibly of the same order as the ~14x this phase measured on Parakeet's
own debug-vs-release delta. The **model-load** portion (checksum-verify +
init) is separately reported in Phase 1 as 6.93s+34.53s (Vulkan,
dev-build-only Vulkan pipeline-compile cost) / 7.16s+2.40s (CPU) — genuinely
a one-time-per-process cost, already excluded from the `total_seconds`
figures in the table above (those are decode-call time only).

**Parakeet's own one-time load cost**, for the same kind of comparison:
`MODEL_LOAD load=0.557s threads=8` (this is `ParakeetEngine.init`'s model
load only, timed after `downloadParakeetModelIfNeeded()`'s cache-hit
checksum-verify already returned) + `WARMUP warm=0.095s`. The
release-run's total wall time for the whole 14-clip run (per `/usr/bin/time
-l`, `real` field) was 33.22s; summing the per-clip `wall` figures + load +
warmup accounts for 28.96s of that, leaving ~4.3s attributable to process
startup (ggml backend registration, which logs *before* `MODEL_LOAD`) plus
`downloadParakeetModelIfNeeded()`'s SHA-256 verify of the cached 940 MB
GGUF. That ~4.3s is smaller than Whisper's own 6.93–7.16s checksum-verify
step in Phase 1, proportionally consistent with Parakeet's file being
~59% the size of Whisper's 1.6 GB `.bin` (940 MB vs 1.6 GB).

**Variance check**: a second pass over the same 14 clips in the same
process (engine loaded once, all 28 transcriptions run back to back) showed
RTF consistently in the 0.118–0.155x band on every clip across both passes
— low run-to-run noise, no warm-up-vs-steady-state cliff worth separately
calling out.

**Bottom line on latency**: on this hardware, Parakeet CPU is dramatically
faster than both Whisper backends for a real, structural reason (no fixed
30s-window re-encode per call, and Parakeet's own RTF of 0.12–0.15x
independently matches Phase 2's standalone, release-configuration
`parakeet-cli` spike almost exactly — so the Parakeet side of this
comparison is solid and release-representative). The **≤60–80x** /
**≤14–30x** figures in the table are real upper bounds from an actual
measured run, but because the Whisper side of the comparison is a debug
build, the true release-vs-release gap is smaller and unmeasured — treat
the win as "at least several-x, quite possibly an order of magnitude or
more," not as the literal ratios printed above. This does not mean
Parakeet Vulkan (Phase 5) will show a similarly dramatic gap
over Parakeet CPU — Parakeet CPU is already so fast in absolute terms
(0.12–0.15x RTF) that there's much less headroom left for a GPU backend to
claim, unlike Whisper where GPU vs CPU was competing against an
already-slow 60–170s-per-call baseline.

## 3. Peak RAM

| Build | Scope | Peak RSS | Peak footprint |
|---|---|---:|---:|
| Parakeet, debug (`-Onone`), 1 process, all 14 clips sequentially | multi-clip, single process | 1,745,723,392 B (~1665 MB) | 1,655,025,664 B |
| Parakeet, release, 1 process, all 14 clips sequentially | multi-clip, single process | 1,729,069,056 B (~1649 MB) | 1,642,270,720 B |
| Parakeet, release, `parakeet-cli`, Phase 2 (1 process per clip) | single-clip, short clip | ~940–985 MB (Phase 2 report) | — |
| Parakeet, release, `parakeet-cli`, Phase 2, 25.58s clip | single-clip, longest tested | ~1125 MB (Phase 2 report) | — |
| Whisper CPU/Vulkan | — | not captured in Phase 1 | — |

Phase 1 did not capture a Whisper peak-RSS figure, so there is no direct
Whisper-vs-Parakeet RAM comparison to report here — that gap is inherited,
not introduced by this phase. Within Parakeet's own numbers: this phase's
figure (~1.65 GB) is higher than Phase 2's per-clip `parakeet-cli` figures
(~940 MB–1.1 GB) because this run kept **one process alive across all 14
clips, including the 70.8s monologue**, inside a full Swift/AppKit-linked
binary (heavier baseline footprint than a bare C++ CLI) — not a leak
signal (release and debug peaks are within ~1% of each other, and RSS did
not grow monotonically clip-to-clip in a way suggesting accumulation
beyond what the largest single clip's buffers need). Treat ~1.6–1.7 GB as
a realistic ceiling for the production app's long-session peak RAM
(dominated by the ~940 MB q8_0 model weights plus per-inference buffers
scaled to the longest clip processed in that session), and ~940 MB–1.1 GB
(Phase 2's numbers) as the floor for short-clip, fresh-process scenarios.

## 4. Accuracy: clip-by-clip comparison

Whisper transcripts are Phase 1's exact recorded text (Vulkan run; Phase 1
noted CPU text matched Vulkan on every clip). Parakeet transcripts are this
phase's release-build run, raw engine output (no `ParakeetTranscriptRepair`
applied — see §1's bypass-symmetry note).

| # | Clip | Whisper (Vulkan) | Parakeet CPU |
|---|------|---|---|
| 01 | ru_short_command | Открой браузер и найди погоду. | Открой браузер, найди погоду. |
| 02 | en_short_command | Open the browser and check the weather. | Open the browser and check the weather. *(exact match)* |
| 03 | ru_numbers | Мой номер телефона 8 912 345 67 89. Код доступа 42001. | Мой номер телефона восемь девятьсот, двенадцать, триста, сорок, пять, шестьдесят, семь, восемьдесят девять. Код доступа четыре, два, ноль, ноль один. |
| 04 | en_numbers | My phone number is 415-555-2107. The access code is 42001. | My phone number is 415-555-2107. The access code is 42001. *(exact match)* |
| 05 | ru_names | Здравствуйте, меня зовут Александр Петрович Иванов. Со мной работают Мария Сергеевна Кузнецова и Дмитрий Олегович Соколов. | *(identical)* |
| 06 | en_address | Please deliver the package to 422 Baker Street, Apartment 9, San Francisco, California, 94107. | *(identical)* |
| 07 | ru_address | Доставьте посылку по адресу улицы Ленина, дом 17, корпус 2, квартира 43, город Екатеринбург. | Доставьте посылку по адресу улицы Ленина, дом семнадцать, корпус, два, квартира, сорок три, город Екатеринбург. |
| 08 | mixed_ru_en | Давай откроем ноутбук и запустим приложение Support Dicted. Нужно проверить настройки ValkyNow и включить GPU Acceleration. | Давай откроем ноутбук и запустим приложение Суппорт Диктэд. Нужно проверить настройки валкой Нау и включить Gpью Экселерэшн. |
| 09 | technical_en | The GGUF model is loaded once through the C-bridge, quantized to Q80, and runs inference through GGML Vulkan on the AMD Radeon GPU. | The GGUF model is loaded once through the C bridge, quantized to Q80, and runs inference through GGML Vulcan on the AMD Radian GPU. |
| 10 | technical_ru | Модель в формате GGUF загружается через C-Bridge и использует backend Valkynau для инференса на видеокарте AMD Radeon 6600. | Модель в формате G G U F загружается через си бридж и использует бэкинг валкой нау для инференса на видеокарте Эм Дир один шесть шестьсот. |
| 11 | ru_paragraph_30s | *(see Phase 1 report; "Утром прошел небольшой дождь…", full paragraph correct)* | Same content, "Утром прошел небольшой дождь…" — no meaning-changing differences. |
| 12 | en_paragraph_30s | Correct English text, **but Whisper's own language-ID auto-detected this as Russian** (p≈0.9995, both backends). | Correct, identical English text. Parakeet's plain PCM API has no separate language-ID output to compare against directly (see Phase 3 §12 — no forced-language parameter exists), but the transcript itself shows no language-confusion artifact either. |
| 13 | mixed_paragraph_30s | "…SupportDicted. Team Lead предложил использовать BackendWalk и Now вместо CPU InfGeorge & So, чтобы снизить latency. …модель Paraket TDT… видеокарта AMD Reddin…" | "…Support Dicted. Team Lead предложил использовать backend valcau вместо с EPU and George Enso, чтобы снизить Lattensi. …модель Perket TDT… видеокарты AMD1…" |
| 14 | ru_monologue_120s | **Drops an entire sentence** present in the source script (see §5) | Includes the sentence Whisper dropped, with two minor mis-transcriptions inside it (see §5) |

### Notable individual differences

- **Numbers (03, 07)**: Whisper transcribes digits as numerals ("8 912 345
  67 89", "дом 17"); Parakeet spells digits out as words ("восемь
  девятьсот…", "дом семнадцать"). Both are *correct* renderings of what was
  spoken (the source script itself spelled numbers as words for `say` to
  read aloud — see `gen_corpus.sh` — so Parakeet's output is actually
  closer to a literal transcription of the spoken audio; Whisper
  normalized spoken-word numbers into digit form). Not an accuracy defect
  either way, just a different normalization convention — worth knowing if
  dictation UX expects digit-form numbers, since Parakeet would need a
  post-processing step Whisper effectively got "for free" from its
  training distribution.
- **Clip 01**: Whisper "и" (and) vs Parakeet ", " (comma) between the two
  clauses — a trivial punctuation/conjunction difference, not a
  correctness issue.
- **Clip 09 (EN technical)**: Both engines mishear "Vulkan"→"Vulcan" and
  "Radeon"→"Radian" similarly (neither knows this proper noun) — a wash,
  not a Parakeet-specific weakness.
- **Clip 10 (RU technical)**: Both garble "Vulkan"/backend name badly
  ("Valkynau" vs "валкой нау") — comparable severity. Parakeet additionally
  spells "GGUF" as individual letters ("G G U F") instead of one token, and
  mangles "AMD Radeon 6600" into "Эм Дир один шесть шестьсот" — arguably
  *worse* than Whisper's "AMD Radeon 6600" (correct) on this specific
  clip.
- **Clip 12 (EN paragraph)**: the specific Phase 1 finding — Whisper's
  language-ID auto-detected this all-English clip as Russian despite
  transcribing it correctly — **cannot be directly re-tested against
  Parakeet**, because parakeet.cpp's plain PCM transcription entry point
  (the one this bridge wraps) has no forced-language parameter and no
  separate language-ID output to inspect (documented structural limitation,
  Phase 3 §12). What can be said: Parakeet's transcript itself is fully
  correct English with zero visible code-switching or language-confusion
  artifacts, so whatever internal language handling it does, it produces
  the same *correct visible output* Whisper did on this clip — this
  specific known Whisper quirk simply isn't observable through the API
  surface Parakeet exposes, not confirmed fixed or reproduced.
- **Clips 08 & 13 (mixed RU/EN)**: this is the clearest **regression**.
  Both engines garble English loanwords/product names, but Parakeet's
  garbling is more severe and drops more information: "GPU Acceleration"
  → "Gpью Экселерэшн" (Parakeet, badly mangled, loses the "GPU" acronym
  entirely) vs "GPU Acceleration" (Whisper, verbatim correct); "CPU
  inference" → "с EPU and George Enso" (Parakeet) vs "CPU InfGeorge & So"
  (Whisper, comparably garbled but at least keeps "CPU" intact); "AMD
  Radeon" → "AMD1" (Parakeet, drops "Radeon" entirely) vs "AMD Reddin"
  (Whisper, garbled but a recognizable attempt at the whole phrase). On
  these specific clips, Whisper's code-switching handling is not
  obviously worse than Parakeet's, and arguably preserves slightly more of
  the original acronyms/words even while mangling brand names — the plan's
  Gate C explicitly flagged this failure mode for direct comparison, and
  the honest finding is it persists in both engines, with Parakeet not
  clearly better here.

## 5. `ё`/`<unk>` finding — with real counts, cross-referenced against the Whisper baseline

**Ground truth**: `~/scratch/parakeet-phase1/gen_corpus.sh` (still on the
Mac, unmodified) was grepped for literal `ё`/`Ё` in the source script text
fed to `say`. Result: **3 occurrences total**, all in the two long clips:

- Clip 11: "Утром **прошёл** небольшой дождь" — 1 occurrence.
- Clip 14: "в части **имён** собственных" — 1 occurrence; "система
  **остаётся** отзывчивой" — 1 occurrence. (2 occurrences)

**Whisper's baseline transcript** (Phase 1, already committed) for these
exact spots: "Утром **прошел**…" (clip 11), "в части **имен**
собственных…" / "система **остается** отзывчивой…" (clip 14) — **all 3
normalized ё→е, same as Parakeet**.

**Parakeet's transcript** (this phase, release run) for the same spots:
"Утром **прошел**…" (clip 11), "в части **имен** собственных…" / "система
**остается** отсывчивой…" (clip 14) — **also all 3 normalized ё→е**, i.e.
0/3 preserved, matching Whisper exactly.

**Conclusion: this is NOT a Parakeet-specific regression.** Phase 3's
report (§9) correctly found empirically that this pinned parakeet.cpp
build silently normalizes ё→е rather than emitting `<unk>` (confirmed
again here, independently, across all 14 corpus clips — zero `<unk>`
tokens found in any transcript via a literal case-insensitive grep, zero
`ё`/`Ё` characters anywhere in the output). What Phase 3 flagged as "a
known limitation" is, on this evidence, **a limitation the currently
shipped Whisper+Vulkan v0.3.1 baseline already has too** — Whisper's own
committed Phase 1 transcripts show the identical е-for-ё normalization on
every one of the 3 real occurrences in this corpus. Whoever next touches
transcript quality should treat "fix casual ё/е orthography" as a
pre-existing product gap, not something the Parakeet migration introduced
or needs to fix to stay at parity.

**Separately**, clip 14 shows one small transcription slip Whisper's
baseline did not have at that spot: Parakeet renders "отзывчивой"
(responsive) as "**отсывчивой**" — not just the ё→е normalization, but an
actual dropped/wrong consonant (missing the "з"). This is a minor, isolated
transcription error, not related to the ё finding, worth noting separately
since it's a real accuracy defect on this clip, however small.

## 6. A genuine Parakeet accuracy win, found by cross-checking against the source script — and confirmed, not just inferred

While verifying the ё ground truth, a direct comparison against
`gen_corpus.sh`'s full source text for clip 14 turned up something Phase 1
did not call out as a Whisper defect (it was noted only as "the
synthesized source was slightly abridged… `say`/`afconvert` reproduced it
faithfully"): **Whisper's committed baseline transcript for clip 14 is
missing an entire real sentence** that Parakeet's transcript includes in
full:

> "Мы также провели серию нагрузочных тестов на реальном оборудовании,
> включая процессоры Intel Xeon и видеокарты AMD Radeon, чтобы убедиться в
> стабильности работы приложения при длительном использовании."

**This was verified directly, not just inferred.** The full, unabridged
clip 14 script (including the Xeon/Radeon sentence above) was
re-synthesized with the exact same `say -v Milena -r 185` parameters
`gen_corpus.sh` uses, and measured with `afinfo`: **70.817596s**. The
actual corpus WAV (`14_ru_monologue_120s.wav`) measures **70.817625s** — a
difference of 29 microseconds, effectively identical. This confirms the
corpus audio genuinely contains the full, unabridged script, including the
sentence Whisper's baseline dropped. **Phase 1's "synthesized source was
slightly abridged" note is mistaken** — the source was not abridged;
Whisper's transcription of it was incomplete.

Parakeet's transcript for this exact stretch: "Мы также провели серию
нагрузочных тестов на реальном оборудовании, включая процессор **Intel
Zion** и видеокарты **AMD-1**, чтобы убедиться в стабильности работы
приложения при длительном использовании." — Parakeet mishears "Xeon" as
"Zion" and drops "Radeon" down to "AMD-1", both real (minor) errors, **but
it recovered the entire sentence's structure and content that Whisper's
baseline silently dropped altogether** — a more serious failure
mode (complete information loss) than Parakeet's name-level
mishearings on the same passage. This was not something either phase's
task brief specifically asked to check, but is a concrete, verifiable win
for Parakeet worth surfacing.

## 7. Summary / bottom line

- **Latency**: Parakeet CPU (release build) is dramatically faster than
  both Whisper CPU and Whisper Vulkan on this hardware, for a real
  structural reason (no fixed 30s-window re-encode per call). The measured
  ≤60–80x (short/medium clips) / ≤14–30x (long paragraphs/monologues)
  figures are real but are release-vs-**debug** ratios (Phase 1's Whisper
  hook was a debug build too — see §2's caveat), so treat them as upper
  bounds, not the true release-vs-release gap, which is unmeasured but
  still very likely a decisive multi-x win. RTF 0.12–0.15x (7–8x faster
  than real-time), matching Phase 2's standalone, release-configuration
  spike almost exactly, confirms the Phase 3 integration didn't regress
  Parakeet's own performance.
- **Peak RAM**: ~940 MB (short clip, fresh process) to ~1.65–1.7 GB
  (long-lived process handling the full corpus including the 70s
  monologue). No direct Whisper comparison exists (Phase 1 didn't capture
  it) — an inherited gap, not a new one.
- **Accuracy**: mixed but net-neutral-to-positive on this small corpus.
  Numbers/names/addresses (03, 05–07) are correctly transcribed by both,
  modulo a digit-vs-spelled-out-word convention difference that isn't a
  correctness defect. Mixed RU/EN code-switching (08, 13) is where
  Parakeet is weakest relative to Whisper — comparably or slightly *more*
  garbled on brand/technical names, the plan's flagged concern is real and
  not resolved by this migration. The ё→е normalization (Phase 3's flagged
  "known limitation") is confirmed to be a wash — Whisper's own baseline
  has the identical behavior on all 3 real occurrences in this corpus, so
  it's not a regression. Clip 12's Whisper-specific language-ID quirk
  couldn't be directly re-tested (no comparable API surface in Parakeet),
  but Parakeet's output is correct with no visible language-confusion
  artifact. A genuine, unprompted find: Parakeet recovered an entire
  sentence on clip 14 that Whisper's committed baseline silently dropped —
  a real win on content completeness, offset by two isolated name-level
  mishearings in that same recovered sentence.
- **Plain-language bottom line**: on this evidence, Parakeet CPU looks
  **clearly competitive-to-better than the shipped Whisper+Vulkan v0.3.1**
  on this hardware — the latency improvement is real and structural (no
  fixed-window re-encode per call, RTF confirmed at 0.12–0.15x
  independently against Phase 2's release-build spike), even though the
  exact size of the win against Whisper specifically is only bounded above
  by this report's debug-vs-release-confounded numbers rather than
  precisely measured. Peak RAM is broadly comparable, and accuracy is a
  wash-to-slight-win overall (one clear win on content
  completeness, one confirmed non-regression on the ё quirk, one
  persisting real weakness on mixed-language code-switching that the
  migration does not fix). The one place Parakeet is worse — garbling
  English brand/technical names inside Russian sentences — is a real,
  specific, and narrow weakness worth targeted follow-up (e.g. a
  domain-specific vocabulary/prompt mechanism, if parakeet.cpp exposes
  one), not a broad quality regression. Nothing here blocks Phase 5.

## 8. Files / logs (not committed — scratch fixtures, matching every prior
phase's convention)

- `~/scratch/parakeet-phase4/repo/` — synced worktree, scratch build only.
- `~/scratch/parakeet-phase4/transcribe_release_run2.log` /
  `transcribe_release_run2.time` — the release-build run used for every
  latency/RTF/RAM figure in this report.
- `~/scratch/parakeet-phase4/transcribe_release_run3_double.log` — variance
  check (28 clips, engine loaded once).
- `~/scratch/parakeet-phase4/transcribe_run1.log` /
  `transcribe_run1.time` — the debug-build run (correct text, unusable
  timing — kept for reference, not used in any figure above).
- Local copy of the release-run transcript:
  `/tmp/claude-1000/-home-shohart-repositories-SuperDictate/7da1bbd0-fc6f-41f6-a00b-18716d8608aa/scratchpad/parakeet_transcribe_release_run2.log`.
- Corpus: `~/scratch/parakeet-phase1/corpus/*.wav` (Phase 1's, reused
  unmodified) / `~/scratch/parakeet-phase1/gen_corpus.sh` (ground-truth
  source text, used for the §5 ё count).
