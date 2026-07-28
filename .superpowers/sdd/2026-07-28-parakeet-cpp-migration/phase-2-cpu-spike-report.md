# Phase 2 — standalone parakeet.cpp CPU spike (Checkpoint A)

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md`.
Branch: `agent/parakeet-intel-backend-architecture`, worktree
`.worktrees/parakeet-migration`. Everything below ran for real on the Intel
Mac (`shohart@192.168.1.246`: Intel Xeon E5-2678 v3, macOS 15.7.7,
x86_64), from a fresh scratch directory `~/scratch/parakeet-phase2/`. This
spike is entirely standalone — no changes were made to this worktree's
`swift/` tree, `Package.swift`, or any file other than the two touched by
this report (the plan file's `PARAKEET_MODEL_SHA256` line and this report).

## 1. Clone + pin verification

```
cd ~/scratch/parakeet-phase2
git clone --recursive https://github.com/mudler/parakeet.cpp.git
cd parakeet.cpp
git checkout e747acdaee69b916cef62263ae5f718bda9ff3f3
git submodule update --init --recursive
```

- `git rev-parse HEAD` → `e747acdaee69b916cef62263ae5f718bda9ff3f3` — **exact
  match** to the plan's pinned `PARAKEET_CPP_COMMIT`. (This commit was in
  fact `master`'s tip at clone time, so no upstream drift was needed — the
  pin is still real and explicit, just happens to equal HEAD today.)
- `git submodule status` → ` e705c5fed490514458bdd2eaddc43bd098fcce9b
  third_party/ggml (v0.13.0)` — matches the plan's "pinned internally by
  parakeet.cpp's own submodule at v0.13.0" note exactly (tag `v0.13.0`,
  commit `e705c5fe`).
- No pin changes were needed. Both commits confirmed exact.

## 2. CPU-only build

```
export PATH=/usr/local/bin:$PATH   # cmake lives here on this Mac but isn't
                                     # on PATH for non-interactive ssh shells
cmake -B build -DPARAKEET_BUILD_TESTS=ON -DGGML_NATIVE=ON
cmake --build build -j
```

- **Only workaround needed on this Mac**: `cmake` (4.4.0) is installed at
  `/usr/local/bin/cmake` but is not on `PATH` for non-interactive `ssh`
  command invocations (`brew` itself was also not found in that same
  non-interactive shell, so the install mechanism wasn't independently
  confirmed — only the binary's location and version were). Prefixing
  `export PATH=/usr/local/bin:$PATH` (or using the full path) fixed it. No
  source changes, no other workarounds — the pinned commit builds cleanly
  out of the box on this hardware/OS.
- Configure log highlights: AppleClang 17.0.0, `GGML_SYSTEM_ARCH: x86`,
  `-march=native` CPU backend variant added, **Accelerate framework found**
  and wired in as the BLAS backend, ggml's own 4 local patches applied
  cleanly (`0001`-`0004`, unrelated to CPU/Vulkan selection — conv2d/pad
  kernel fixes), `ggml version: 0.13.0` / `ggml commit: e705c5fe-dirty`
  (dirty only because the patch step modifies the submodule checkout
  in-place, expected). OpenMP not found (non-fatal, ggml falls back to its
  own thread pool — this matches the existing Whisper build's profile on
  the same machine).
- No GPU flags passed (`PARAKEET_GGML_VULKAN` etc. all default `OFF`) —
  confirmed CPU-only per the plan's Phase 2 scope.
- Build completed with **zero errors**: `grep -in error` over the complete,
  finished build log (273 lines, ending in `[100%] Built target
  parakeet-server`) returned no matches (exit code 1, confirmed after the
  build process had actually exited — not checked mid-build). Produced
  `build/examples/cli/parakeet-cli`, a Mach-O 64-bit x86_64 executable,
  plus `parakeet-server` and the full `PARAKEET_BUILD_TESTS=ON` ctest suite
  (not run in this phase — out of scope, CLI-based transcription is what
  Checkpoint A requires).

## 3. Model download + real SHA-256

```
URL="https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/bf0af9f425fa01809cadec671b3cb672709d13e9/tdt-0.6b-v3-q8_0.gguf"
curl -L -o tdt-0.6b-v3-q8_0.gguf "$URL"
shasum -a 256 tdt-0.6b-v3-q8_0.gguf
```

- Downloaded size: **940,663,680 bytes** — exact match to the plan's pinned
  `PARAKEET_MODEL_SIZE_BYTES`.
- Computed SHA-256 (from the actual downloaded bytes on this Mac, not
  copied from any API/metadata response):

  ```
  4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757
  ```

  This value has been written into the plan file's "Pinned versions"
  section as `PARAKEET_MODEL_SHA256`.
- `parakeet-cli info tdt-0.6b-v3-q8_0.gguf` confirms the model loads and
  reports its architecture cleanly:

  ```
  parakeet.cpp 0.0.1
  model: tdt-0.6b-v3-q8_0.gguf
    arch            : hybrid_tdt_ctc
    d_model/layers/heads: 1024 / 24 / 8
    conv_kernel/norm: 9 / batch_norm
    xscaling        : false
    subsampling     : x8 (ch=256)
    mel/n_fft/win/hop: 128 / 512 / 400 / 160
    vocab/blank     : 8192 / 8192
    tdt durations   : [0,1,2,3,4]
    att_context     : [-1,-1] regular
    causal ds/conv  : false / false
  ```

## 4. Transcription test — real corpus clips, real output

Used the Phase 1 synthetic benchmark corpus, still present unmodified on
the Mac at `~/scratch/parakeet-phase1/corpus/*.wav` (14 clips, RU/EN/mixed,
16 kHz mono PCM WAV — see the Phase 1 report for generation method). Ran
`parakeet-cli transcribe --model tdt-0.6b-v3-q8_0.gguf --input <clip>.wav
--decoder tdt` against 6 clips (more than the plan's 2-3 minimum, to get
broader RU/EN/mixed/technical/long-form coverage before Phase 3/4):

| Clip | Lang | Real result |
|---|---|---|
| `01_ru_short_command.wav` | RU | `Открой браузер, найди погоду.` |
| `02_en_short_command.wav` | EN | `Open the browser and check the weather.` |
| `03_ru_numbers.wav` | RU | `Мой номер телефона восемь девятьсот, двенадцать, триста, сорок, пять, шестьдесят, семь, восемьдесят девять. Код доступа четыре, два, ноль, ноль, один.` |
| `05_ru_names.wav` | RU | `Здравствуйте, меня зовут Александр Петрович Иванов. Со мной работают Мария Сергеевна Кузнецова и Дмитрий Олегович Соколов.` |
| `09_technical_en.wav` | EN | `The GGUF model is loaded once through the C bridge, quantized to Q80, and runs inference through GGML Vulcan on the AMD Radian GPU.` |
| `11_ru_paragraph_30s.wav` (25.58s) | RU | `Сегодня прекрасная погода для прогулки по городу. Утром прошел небольшой дождь, но сейчас небо чистое и светит солнце. Мы планируем встретиться с друзьями в кафе на главной площади, обсудить рабочие вопросы и составить план на следующую неделю. После обеда нужно заехать в магазин за продуктами и забрать посылку с почты. Вечером будет важная встреча с клиентами, поэтому нужно подготовить презентацию заранее.` |

**Verdict: all six transcripts are real, coherent, non-garbage speech text**
in the correct language, no empty output, no hallucination, no repeated-
token loops. Checkpoint A is satisfied.

Observations worth carrying into Phase 3/4 (informational only, not
Phase-2-blocking):
- Clip 03's spoken digit groups ("8 912 345 67 89") were transcribed as
  spelled-out number words rather than digits — a real behavioral
  difference from the Phase 1 Whisper+Vulkan baseline, which transcribed
  the same clip as digits (`8 912 345 67 89`). Worth comparing again in
  Phase 4's A/B.
- Clip 09's technical/proper nouns were mildly mangled ("Q80" for "Q8_0",
  "Vulcan" for "Vulkan", "Radian" for "Radeon") — comparable in kind (not
  necessarily degree) to the code-switching garbling the Whisper baseline
  showed on similar content in Phase 1.
- **No `<unk>` tokens and no obviously-wrong Cyrillic "ё" substitutions
  appeared in any of the 6 clips tested.** This is a first data point
  against the `SpeechModelTextRepair`/`<unk>`→`ё` quirk referenced in the
  plan — worth re-checking with a larger, ё-focused sample in Phase 3
  before deciding whether to port that repair logic, but nothing in this
  spike's output needed it.
- `--json` output includes per-word/per-token timestamps and confidence
  scores (e.g. clip 01's `"браузер,"` word had `conf: 0.5112`, notably
  lower than its neighbors) — a richer transcription result shape than
  `WhisperTranscription` currently exposes, available for Phase 3's
  `ParakeetTranscriptionResult` if useful.

## 5. Timing

Measured via `parakeet-cli bench --model ... --manifest ... --decoder tdt
--json`, which loads the model once (timed, excluded from per-file
numbers) and reports steady-state per-file `proc_ms` (the first file in
the manifest is run once, untimed, as warm-up, then timed again in the
loop — matching the plan's "load once per session, reused for every
dictation" production shape):

```json
{"model":"tdt-0.6b-v3-q8_0.gguf","threads":8,"load_ms":535.837,
 "files":[
   {"path":".../01_ru_short_command.wav","audio_sec":1.670,"proc_ms":218.914},
   {"path":".../02_en_short_command.wav","audio_sec":1.690,"proc_ms":235.188},
   {"path":".../03_ru_numbers.wav","audio_sec":7.868,"proc_ms":1018.706}
 ]}
```

- **Model load time: 535.8 ms** (cold, single load of the 940.7 MB q8_0
  GGUF, Accelerate/BLAS-backed CPU, default 8 threads). Measured with the
  GGUF freshly downloaded and page-cache-hot on this run, so this is a
  floor, not a cold-disk number — worth re-measuring after a reboot/cache
  drop if Phase 3/4 needs a conservative figure.
- **Steady-state inference (post-warm-up)**: 218.9 ms for a 1.67s clip
  (RTF ≈ 0.13x, i.e. ~7.6x faster than real-time), 235.2 ms for a 1.69s
  clip (RTF ≈ 0.14x), 1018.7 ms for a 7.87s clip (RTF ≈ 0.13x). Unlike the
  Phase 1 Whisper baseline, Parakeet's inference cost scales with actual
  clip duration rather than always paying a fixed 30s-window cost — a
  qualitative difference worth highlighting in Phase 4's A/B.
- **First-inference latency (cold)**: `parakeet-cli`'s stock `bench`
  subcommand always runs one untimed warm-up call on the first manifest
  file before timing anything, so there is no built-in way to time a cold
  inference directly. Derived it instead from a single same-process
  measurement: `/usr/bin/time -l ./parakeet-cli bench --model ... --manifest
  <single 01_ru_short_command.wav clip> --decoder tdt --json` reported
  **1.12 s real** total for the whole process, with `load_ms` = 539.7 ms
  and the (warm, second-call) `proc_ms` = 223.3 ms both coming from the
  same process's own JSON output. The residual — `1120 - 540 - 223 ≈
  357 ms` — is an **estimate** of the cold first-inference call, since it
  also includes process startup and two WAV-decode calls (once for the
  untimed warm-up, once for the timed loop) that aren't separately broken
  out by the CLI. This is consistent in order of magnitude with an earlier,
  cruder cross-process subtraction (single-shot `transcribe` total 0.93 s
  minus the separately-measured 535.8 ms load ≈ 394 ms), but the ~357 ms
  same-process figure is the one to treat as the working number — both are
  derived, not directly measured, and are reported as such.

## 6. Peak RSS

Measured with `/usr/bin/time -l` (macOS) around single-process
`parakeet-cli transcribe` runs (model load + inference together, one
process per clip):

| Clip | Audio (s) | Real time (s) | Peak RSS (maximum resident set size) | Peak memory footprint |
|---|---:|---:|---:|---:|
| `01_ru_short_command.wav` | 1.67 | 0.93 | 985,874,432 B (940.4 MB) | 979,550,208 B |
| `02_en_short_command.wav` | 1.69 | 0.94 | 986,046,464 B (940.4 MB) | 979,722,240 B |
| `05_ru_names.wav` | 7.79 | 1.67 | 1,032,445,952 B (984.5 MB) | 1,023,995,904 B |
| `09_technical_en.wav` | 9.24 | 1.92 | 1,044,152,320 B (995.9 MB) | 1,035,403,264 B |
| `11_ru_paragraph_30s.wav` | 25.58 | 4.08 | 1,179,934,720 B (1125.2 MB) | 1,158,041,600 B |

Peak RSS is dominated by the 940.7 MB q8_0 model weights (baseline ~940 MB
for the shortest clips) and grows modestly with clip length (up to
~1.18 GB for the 25.58s paragraph) from audio/feature buffers and
transducer decode state — no runaway growth observed, no leak signal
across the 6 test runs.

## 7. Summary

- **Build: PASS**, CPU-only, pinned commit and pinned ggml submodule both
  verified exact, zero build errors, only environmental fix needed was
  putting `/usr/local/bin` on `PATH` for the non-interactive ssh session
  (cmake itself required no changes).
- **Real SHA-256** (computed from actual downloaded bytes, not trusted from
  any API): `4d69a4a6683f4f2d952bad794c1357ca6eb628027695b4699c5a9ad4cd07d757`
  — now recorded in the plan file's Pinned versions section.
- **Transcription: PASS**, 6/6 real corpus clips (RU short command, EN
  short command, RU numbers, RU names, EN technical, RU 25.58s paragraph)
  produced coherent, correct-language, non-garbage transcripts.
- **Timing**: model load 535.8 ms (page-cache-hot; a floor, not worst-case);
  steady-state inference RTF ≈ 0.13-0.14x (7-8x faster than real-time) on
  short/medium clips; cold first-inference latency ≈ 357 ms (derived,
  same-process residual — see §5 for the confounds) on a 1.67s clip.
- **Peak RSS**: ~940-985 MB for short clips (dominated by the 940.7 MB
  model), growing to ~1.18 GB for a 25.58s clip.
- **No blocking issues found.** Checkpoint A (per the plan) is satisfied:
  parakeet.cpp builds and transcribes correctly on the real Intel Mac,
  standalone, CPU-only, using the exact pinned commit/model/revision.
