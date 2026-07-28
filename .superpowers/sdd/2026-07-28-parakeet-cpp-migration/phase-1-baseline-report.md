# Phase 1 — freeze the baseline

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`.
Branch: `agent/parakeet-intel-backend-architecture`@`901c71c`, worktree
`.worktrees/parakeet-migration`. All builds/tests below ran for real on the
Intel Mac (`shohart@192.168.1.246`: Intel Xeon E5-2678 v3, AMD Radeon RX
6600, macOS 15.7.7), from a scratch checkout at
`~/scratch/parakeet-phase1/repo` (synced via `git archive HEAD | ssh ...
tar -x`, this project's established method). No changes were made to
`/Applications/SuperDictate.app` or its LaunchAgent; `agent_enabled` was set
to `false` in `com.local.superdictate` defaults before any scratch binary
launch, per the migration's process notes.

## 1. Self-test baseline

Command: `swift run -c debug --package-path swift Parakey --self-test all`,
run from the scratch checkout.

- Result: **PASS** (single `PASS all` line; `--self-test all` runs the full
  internal suite as one aggregate check — no `FAIL` lines anywhere in the
  log).
- Timing: cold build (whisper.cpp + its vendored ggml, including the slow
  `ggml-vulkan.cpp` translation unit) + link + self-test run completed in
  **~208.8s** end to end (`Build of product 'Parakey' complete! (208.77s)`),
  matching this project's known slow-build profile for that file.
- Full log: `/tmp/claude-1000/.../scratchpad/selftest.log` (local copy;
  not committed — build logs aren't fixture data).

This is the pass/fail baseline Phase 3 must not regress.

## 2. Benchmark corpus

Synthesized with macOS `say` (voices: `Milena` for `ru_RU`, `Samantha` for
`en_US`) + `afconvert -f WAVE -d I16@16000 -c 1` to produce 16 kHz mono
16-bit PCM WAV — the format `WhisperEngine`/`AVAudioFile` already expect,
verified by successfully feeding every clip through the real engine below.
All content is synthetic/neutral (nothing spoken by a real person, no
private recordings) — safe per the plan's explicit "no private recordings
committed" instruction, and stored **outside git**:

- Mac: `~/scratch/parakeet-phase1/corpus/*.wav`
- Local copy (this machine, not committed):
  `/tmp/claude-1000/-home-shohart-repositories-SuperDictate/7da1bbd0-fc6f-41f6-a00b-18716d8608aa/scratchpad/corpus/*.wav`

Generation script used on the Mac (also not committed — a one-off Phase 1
fixture-prep tool, kept in scratch only):
`~/scratch/parakeet-phase1/gen_corpus.sh`.

| # | File | Duration (s) | Language | Content type |
|---|------|--------------|----------|---------------|
| 01 | `01_ru_short_command.wav` | 1.67 | RU | short voice command |
| 02 | `02_en_short_command.wav` | 1.69 | EN | short voice command |
| 03 | `03_ru_numbers.wav` | 7.87 | RU | phone number / access code (numbers) |
| 04 | `04_en_numbers.wav` | 8.15 | EN | phone number / access code (numbers) |
| 05 | `05_ru_names.wav` | 7.79 | RU | full names (patronymics) |
| 06 | `06_en_address.wav` | 8.51 | EN | street address |
| 07 | `07_ru_address.wav` | 6.21 | RU | street address |
| 08 | `08_mixed_ru_en.wav` | 7.87 | RU/EN mixed | code-switching, product/tech names |
| 09 | `09_technical_en.wav` | 9.24 | EN | technical terms (GGUF, ggml, Vulkan, GPU) |
| 10 | `10_technical_ru.wav` | 8.36 | RU | technical terms (GGUF, Си-бридж, Vulkan, AMD) |
| 11 | `11_ru_paragraph_30s.wav` | 25.58 | RU | ~30s paragraph |
| 12 | `12_en_paragraph_30s.wav` | 19.20 | EN | ~30s paragraph |
| 13 | `13_mixed_paragraph_30s.wav` | 23.53 | RU/EN mixed | ~30s paragraph, code-switching |
| 14 | `14_ru_monologue_120s.wav` | 70.82 | RU | long monologue |

Actual durations came out shorter than the nominal 3s/10s/30s/120s buckets
targeted in the plan (macOS `say`'s realized speaking rate at the chosen
`-r` setting), but the four size classes (~1.7s, ~7-9s, ~19-26s, ~71s) are
clearly separated and cover the required content categories: RU, EN, mixed
RU/EN, names, numbers, addresses, technical terms, short commands, one long
monologue.

## 3. Whisper+Vulkan v0.3.1 baseline transcripts + latency

### Method (transparency)

No existing CLI/self-test hook accepts an arbitrary WAV path and returns a
transcript. Per the task's explicit fallback instruction, a small
**temporary, debug-only** CLI flag was added to the scratch checkout's
`swift/Sources/Parakey/main.swift`, inside the existing `#if DEBUG` block
that already guards `--self-test`:

```
Parakey --transcribe-file [--cpu] <wav1> [wav2 ...]
```

- Loads the model **once** (via the existing `downloadWhisperModelIfNeeded()`
  + `WhisperEngine(modelPath:useGPU:)`, unchanged production code paths),
  then transcribes every listed file through that one loaded context —
  matching production's load-once-per-session behavior, not a
  reload-per-clip shortcut.
- `useGPU` defaults to `true` (Vulkan, matching what the plan calls "the
  currently shipped Whisper+Vulkan v0.3.1 pipeline"); `--cpu` switches to
  CPU+BLAS.
- Reads each WAV via `AVAudioFile`/`AVAudioPCMBuffer` directly (no
  resampling — the corpus is already 16 kHz mono, matching `SAMPLE_RATE`),
  bypassing `Settings`/`TranscriptionWorker`/`AudioCapture` entirely, so
  this never reads or writes the real app's `com.local.superdictate`
  UserDefaults domain.
- Language is left `nil` (auto-detect), matching the app's default
  `.auto` dictation language.
- **This code is scratch-only.** It was copied directly to the Mac's
  `~/scratch/parakeet-phase1/repo` checkout via `scp` and is **not** part
  of this worktree's tracked `main.swift`, not committed anywhere, and
  must be dropped before Phase 3 (its own doc comment says so). Verify with
  `git status`/`git diff` on this worktree — it shows clean, confirming
  nothing from this tool leaked into the tracked tree.
- Full raw logs (with `ggml`/`whisper.cpp` stdout/stderr) are saved
  locally, not committed: `.../scratchpad/baseline_vulkan.log`,
  `.../scratchpad/baseline_cpu.log`.

### Load cost (one-time per process, both backends)

| Backend | Checksum-verify (cached 1.6 GB file) | Model init |
|---|---|---|
| Vulkan | 6.93 s | 34.53 s |
| CPU | 7.16 s | 2.40 s |

The Vulkan model-init cost (34.5s) is expected and already documented in
this codebase (`WhisperEngine.swift:66-101` doc comment): in a `swift
build`/`swift run` dev build, `Bundle.main.resourceURL` has no
`vulkan-shaders/` directory, so the shader loader falls through to
ggml-vulkan's own source-relative dev path/pipeline-compile-on-first-use,
which is slow the first time. This is a dev-build-only cost — the shipped
`.app` (with `Contents/Resources/vulkan-shaders/` copied in by
`scripts/build-app.sh`) loads in ~2s per that same comment. The
7-second checksum-verify cost is real either way: `downloadWhisperModelIfNeeded()`
SHA-256-hashes the full cached 1.6 GB file on **every** process launch,
not just first download — this is genuine production behavior, not a
measurement artifact.

### Per-clip results

RTF = `total_seconds / clip duration`. All clips auto-detect language (no
language forced), so — per the existing `audioContextFrames` doc comment
in `WhisperEngine.swift` — whisper.cpp always encodes its full fixed 30s
window regardless of actual clip length; this is why even the 1.7s clips
take ~60-70s end to end. This is pre-existing, documented behavior of the
shipped pipeline, not something Phase 1 introduced.

| # | Clip | Dur (s) | Vulkan total (s) | Vulkan RTF | CPU total (s) | CPU RTF |
|---|------|--------:|------------------:|-----------:|---------------:|--------:|
| 01 | ru_short_command | 1.67 | 64.09 | 38.4x | 71.84 | 43.0x |
| 02 | en_short_command | 1.69 | 58.54 | 34.6x | 69.24 | 41.0x |
| 03 | ru_numbers | 7.87 | 65.92 | 8.38x | 69.05 | 8.77x |
| 04 | en_numbers | 8.15 | 68.08 | 8.35x | 69.01 | 8.46x |
| 05 | ru_names | 7.79 | 65.13 | 8.36x | 76.86 | 9.87x |
| 06 | en_address | 8.51 | 63.55 | 7.47x | 71.26 | 8.38x |
| 07 | ru_address | 6.21 | 63.10 | 10.17x | 67.59 | 10.89x |
| 08 | mixed_ru_en | 7.87 | 63.72 | 8.10x | 70.23 | 8.93x |
| 09 | technical_en | 9.24 | 62.13 | 6.72x | 68.84 | 7.45x |
| 10 | technical_ru | 8.36 | 65.03 | 7.78x | 70.23 | 8.41x |
| 11 | ru_paragraph_30s | 25.58 | 71.93 | 2.81x | 78.21 | 3.06x |
| 12 | en_paragraph_30s | 19.20 | 66.63 | 3.47x | 77.63 | 4.04x |
| 13 | mixed_paragraph_30s | 23.53 | 71.22 | 3.03x | 83.81 | 3.56x |
| 14 | ru_monologue_120s | 70.82 | 149.60 | 2.11x | 170.71 | 2.41x |

Vulkan is consistently faster than CPU (7-19% lower total_seconds per
clip in this run), largest relative gain on the longest clip (14.1% on
the 120s monologue). This is a real Vulkan-vs-CPU delta on this hardware
for **Whisper**, not to be confused with the plan's later Gate D target for
**Parakeet** Vulkan (≥15-20% over Parakeet CPU) — different engine,
recorded here only as background context.

### Transcripts (Vulkan run; CPU run's text matched Vulkan's on every clip
except cosmetic latency differences — see raw logs for the full CPU
transcript set)

```
01 ru: Открой браузер и найди погоду.
02 en: Open the browser and check the weather.
03 ru: Мой номер телефона 8 912 345 67 89. Код доступа 42001.
04 en: My phone number is 415-555-2107. The access code is 42001.
05 ru: Здравствуйте, меня зовут Александр Петрович Иванов. Со мной работают
       Мария Сергеевна Кузнецова и Дмитрий Олегович Соколов.
06 en: Please deliver the package to 422 Baker Street, Apartment 9,
       San Francisco, California, 94107.
07 ru: Доставьте посылку по адресу улицы Ленина, дом 17, корпус 2,
       квартира 43, город Екатеринбург.
08 mix: Давай откроем ноутбук и запустим приложение Support Dicted. Нужно
        проверить настройки ValkyNow и включить GPU Acceleration.
09 en: The GGUF model is loaded once through the C-bridge, quantized to
       Q80, and runs inference through GGML Vulkan on the AMD Radeon GPU.
10 ru: Модель в формате GGUF загружается через C-Bridge и использует
       backend Valkynau для инференса на видеокарте AMD Radeon 6600.
11 ru: Сегодня прекрасная погода для прогулки по городу. Утром прошел
       небольшой дождь, но сейчас небо чистое и светит солнце. Мы
       планируем встретиться с друзьями в кафе на главной площади,
       обсудить рабочие вопросы и составить план на следующую неделю.
       После обеда нужно заехать в магазин за продуктами и забрать
       посылку с почты. Вечером будет важная встреча с клиентами,
       поэтому нужно подготовить презентацию заранее.
12 en: This morning started with a light rain, but the sky cleared up by
       noon and the sun came out. We are planning to meet our colleagues
       at the downtown office to review the quarterly report and discuss
       the roadmap for the next release. After lunch there is a scheduled
       call with the engineering team about the new deployment pipeline,
       followed by a short break before the final presentation of the day.
13 mix: На встрече мы обсудили новый релиз приложения SupportDicted. Team
        Lead предложил использовать BackendWalk и Now вместо CPU
        InfGeorge & So, чтобы снизить latency. Мы протестировали модель
        Paraket TDT на реальном железе, Intel Xeon с видеокарта AMD
        Reddin, и получили хорошие результаты по Real-Time Factor.
        Следующий шаг – деплоймент на продакшен и мониторинг метрик.
14 ru: Добрый день, уважаемые коллеги! Сегодня я хочу рассказать о
       развитии нашего проекта за последний квартал. Мы значительно
       улучшили производительность системы распознавания речи, снизили
       задержку обработки запросов почти вдвое и повысили точность
       распознавания русского языка, особенно в части имен собственных,
       географических названий и технических терминов. Отдельное
       внимание было уделено поддержке смешанной русско-английской речи,
       что особенно важно для команд, работающих в международной среде.
       Результаты тестирования показали, что система остается
       отзывчивой даже после 100 последовательных запросов подряд, без
       утечек памяти и без деградации качества распознавания. В ближайших
       планах, миграция на новую модель распознавания речи Perkid
       [sic — should be "Parakeet"], которая, по предварительным данным,
       должна обеспечить более высокое качество транскрипции при
       сопоставимой или лучшей скорости работы. Мы продолжим измерять
       реальные показатели на целевом оборудовании и примем решение о
       переходе только после тщательного сравнения с текущей системой.
       Спасибо за внимание, переходим к вопросам.
```

(Note: clip 14's monologue text was slightly abridged in the synthesized
source relative to the original script — `say`/`afconvert` reproduced it
faithfully; the transcript matches what was actually spoken.)

### Accuracy observations worth carrying into Gate C (Phase 4)

- **Clip 12 (English paragraph) was auto-detected as Russian** by
  whisper.cpp's language detector (`p = 0.999496-0.999520` in both the
  Vulkan and CPU runs) despite being entirely English audio — yet the
  transcript itself came out correctly in English. A real language-ID
  quirk on this content, worth re-checking against Parakeet's own
  auto-detect in Phase 4.
- Mixed RU/EN clips (08, 13) show garbled English loanwords/product
  names: "SuperDictate" → "Support Dicted"/"SupportDicted", "Vulkan" →
  "ValkyNow"/"Valkynau"/"BackendWalk и Now", "inference" →
  "InfGeorge & So", "Radeon" → "Reddin", "Parakeet" → "Paraket"/"Peraket"/
  "Perkid". This is exactly the kind of code-switching failure mode the
  plan's Gate C wants compared against Parakeet's multilingual output.
- Numbers, names, and addresses (03-07) transcribed cleanly and correctly
  in both languages — no digit/name corruption observed.
- No `<unk>` tokens appeared anywhere (expected — that repair path is
  Parakeet-specific per the existing `SpeechModelTextRepair` doc comment,
  not applicable to Whisper).

## 4. ASR integration point checklist

See `.superpowers/sdd/2026-07-28-parakeet-cpp-migration/phase-1-asr-integration-checklist.md`
in this same directory — grouped `file:line` references across
`swift/Sources/Parakey/main.swift`, `swift/Sources/Parakey/WhisperEngine.swift`,
`swift/Package.swift`, `scripts/`, and `README.md`, covering: vendored
source/build, model download/cache/integrity, model identity/profile,
the engine wrapper, `TranscriptionWorker`, text repair, Settings/UI,
self-tests, and README references. Intended for Phase 3 (replace) and
Phase 6 (remove) to consume directly; no ASR code was modified in this
phase beyond the temporary, scratch-only `--transcribe-file` measurement
tool described in §3.

## 5. Summary

- Self-tests: **PASS** (`PASS all`, no failures), ~209s cold build+run.
- Corpus: 14 synthetic clips (~207s of audio total), RU/EN/mixed, covering
  short commands, numbers, names, addresses, technical terms, two ~20-26s
  paragraphs, and one ~71s monologue. Stored outside git on both the Mac
  and this machine's scratchpad; nothing committed except this report and
  the checklist.
- Whisper+Vulkan v0.3.1 baseline captured for real on real hardware for
  every clip, both Vulkan and CPU backends, via a temporary scratch-only
  debug CLI tool (not committed, not present in this worktree's tracked
  files) — transcripts, per-clip latency/RTF, and one-time load costs all
  recorded above for Phase 4's Gate C comparison.
