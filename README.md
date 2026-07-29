# 🎙️ SuperDictate

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#-one-minute-install)
[![Latest release](https://img.shields.io/github/v/release/shohart/SuperDictate-Intel?label=release)](https://github.com/shohart/SuperDictate-Intel/releases/latest)
[![100% local](https://img.shields.io/badge/speech%20processing-100%25%20local-success.svg)](#-privacy--data)

**Fast, private, local dictation for macOS.** Hold a hotkey, speak, and your
words are typed into whatever field is focused — no cloud, no account, no
audio ever leaving your Mac.

**[Читать по-русски](README.ru.md)**

## 🚀 One-minute install

**Requires an Apple Silicon Mac (`M1` or newer) or Intel, running macOS 14+.**

1. Open the **Terminal** app.
2. Paste this command and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Intel/main/install.sh | /bin/bash
```

3. When SuperDictate opens, click `Allow` for **Microphone**,
   **Accessibility**, and **Input Monitoring**.
4. Wait for the status to read `Ready`, press **right Command**, and speak.
   Press **right Command** again to insert the text.

On first launch, SuperDictate downloads a local speech-recognition model once
(Parakeet TDT 0.6B v3, via the parakeet.cpp engine). It takes about 940 MB on
disk; plan for at least 1.5 GB of free space during installation. After the
download completes, dictation works fully offline.

SuperDictate is fast, local dictation for macOS. Your audio and transcripts
are never sent to a cloud API.

## ⬆️ Updating

**If SuperDictate already shows an `Update` button:** open the app from the
Applications folder and click it. The app downloads and verifies the new
version, replaces the old one, and relaunches on its own.

**If SuperDictate was installed before the update button existed:** don't
delete anything. Open Terminal and run the same command again:

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Intel/main/install.sh | /bin/bash
```

The command only replaces `/Applications/SuperDictate.app`. Your history,
settings, and already-downloaded model stay in place. After this, future
updates can be installed straight from the app.

The latest published version is always visible on the
[GitHub Releases](https://github.com/shohart/SuperDictate-Intel/releases/latest)
page (this fork hasn't cut its first release yet).

## ⌨️ Hotkeys

- **Right Command** — start dictating; press again to stop the recording.
- Settings let you choose what a second press does: just insert the text, or
  insert the text and then press Enter.
- **Right Option + right Command** — an alternate way to stop the active
  recording. It does the opposite of the primary hotkey: if the primary key
  presses Enter, this one stops without Enter, and vice versa. The alternate
  hotkey can be turned off.
- **Right Shift + right Command** — open or close the quick history.
- All three shortcuts can be changed independently. Single keys, function
  keys, regular combinations, and modifier-only combinations (e.g.
  `Option + Command`) are all supported.
- Left and right variants of a modifier are distinct: a right-Command
  shortcut will not fire from the left Command key.
- While the shortcut-recording window is open, global dictation is
  temporarily paused. Keys you press are only recorded as the new hotkey and
  don't trigger anything else.
- Open `SuperDictate` from Applications to check the background service,
  permissions, and updates. Settings open via the gear button.

## 🖥️ Control panel

The main panel is compact: it shows the background service status, any
missing permissions, and an available update. Service controls sit to the
right of the status; hovering shows a tooltip for each button.

The gear button opens a separate window with the three shortcuts, the
stop-action behavior, capsule size, colors, and indicator background. The
`RU / EN` toggle instantly switches the language of both panels. Changes stay
as a draft first; the `Save and Restart` button applies them together and
restarts only the background service — history and the model are left
untouched.

The panel can be closed entirely. The background service keeps running
separately and launches automatically after the next macOS login.

## 🔐 Why the permissions are needed

macOS doesn't let an app grant these to itself:

- **Microphone** — records your voice while dictation is active.
- **Accessibility** — locates the focused field and inserts the finished
  text.
- **Input Monitoring** — detects the global hotkey.

If the status doesn't change to `Ready` after granting permissions, open
SuperDictate and click `Restart` on the background service. If the app
doesn't show up in the system list, click `Try Again` next to the relevant
permission.

## 📦 What the installer does

The installer:

1. Downloads `SuperDictate.zip` from
   [GitHub Releases](https://github.com/shohart/SuperDictate-Intel/releases).
2. Verifies a pinned SHA-256, version, bundle ID, architecture (Apple Silicon
   or Intel), code signature, and microphone entitlements.
3. Safely replaces `/Applications/SuperDictate.app` and opens the panel.

Xcode and the Command Line Tools are not required for a normal install.
History, settings, and the already-downloaded model are preserved across
updates.

## 🛠️ Building from source

### The easiest way

This command downloads the open-source code, builds it locally, and installs
the result into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Intel/main/install.sh | SUPERDICTATE_BUILD_FROM_SOURCE=1 /bin/bash
```

You'll need the free Apple Command Line Tools. If they're missing, the
installer opens the standard installation dialog; run the command again once
that finishes. A clean first build usually takes a few minutes.

By default, building from source downloads the exact release source commit
and verifies it against GitHub. For development, you can pass your own
`SUPERDICTATE_REF` and `SUPERDICTATE_SOURCE_COMMIT`; without a matching
commit, the installer won't run the downloaded `scripts/build-app.sh`.

### Manual build for development

```bash
xcode-select --install
git clone https://github.com/shohart/SuperDictate-Intel.git
cd SuperDictate
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
open ./dist/SuperDictate.app
```

By default, a local build is signed ad-hoc. To use your own certificate, pass
its name:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-app.sh ./dist/SuperDictate.app
```

Don't move or delete `dist/SuperDictate.app` while the background service is
running from that build. For regular use, prefer the
`SUPERDICTATE_BUILD_FROM_SOURCE=1` command, which installs the app into
`/Applications`.

## 🗣️ Speech recognition: Parakeet TDT 0.6B v3

SuperDictate uses NVIDIA Parakeet TDT 0.6B v3 (a multilingual model, GGUF
format, q8_0 quantization) via the
[parakeet.cpp](https://github.com/mudler/parakeet.cpp) engine. Whisper.cpp
and large-v3-turbo are no longer used — this is the only production speech
recognition model in the app.

Recognition runs on CPU by default. The app's settings (under the behavior
toggles) include a `Use GPU (Vulkan)` option — a real switch wired to
parakeet.cpp's Vulkan backend (ggml v0.13.0 + MoltenVK), verified on real
hardware (Intel Xeon E5-2678 v3 + AMD Radeon RX 6600, macOS 15.7.7). The menu
item is disabled, with an explanatory tooltip, when no Vulkan device is
detected by the ggml registry — the toggle never reports GPU use when CPU is
actually running: if Vulkan was requested but the effective backend turned
out to be CPU (including when parakeet.cpp itself silently falls back to CPU
after failing to find the requested device — a confirmed upstream behavior),
the app switches to CPU and remembers this for the current session only,
never changing the saved setting automatically.

Real measurements on the RX 6600 (the full path through the app — the
Swift/actor/C bridge, not a standalone CLI tool; `-c release` build), 4 clips
from the Phase 1 corpus:

| Clip | Audio, s | CPU, ms | Vulkan, ms | Latency change |
|---|---:|---:|---:|---:|
| `01_ru_short_command` | 1.67 | 330.9 | 422.9 | −27.8% (slower) |
| `02_en_short_command` | 1.69 | 279.0 | 179.8 | 35.5% |
| `03_ru_numbers` | 7.87 | 1095.2 | 809.7 | 26.1% |
| `11_ru_paragraph_30s` | 25.58 | 3550.0 | 1529.1 | 56.9% |

On very short clips (around 1.7 s), the Swift/actor/C bridge overhead and
Vulkan pipeline warm-up outweigh the GPU gain — Vulkan is slower than CPU
here. On clips of ~2 s and longer, the gain is real and grows with audio
length (26–57% in this run), which falls within the spec's target range
(≥15–20%) for those clips. Transcript text is identical between CPU and
Vulkan across all 4 clips. Full details, including measurements from a
separate CMake build (without the Swift/bridge overhead, where Vulkan speeds
up even short clips by 30%+), are in
`.superpowers/sdd/2026-07-28-parakeet-cpp-migration/phase-5-vulkan-integration-report.md`.

## ✅ Checks before a pull request

```bash
bash -n install.sh uninstall.sh scripts/*.sh
plutil -lint swift/Info.plist entitlements.plist
swift run -c debug --package-path swift Parakey --self-test all
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
otool -L ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
file ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
lipo -info ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
```

`otool -L` must not list `/usr/local`, `/opt/homebrew`, `Cellar`,
`MoltenVK.dylib`, or `libvulkan` (MoltenVK and all of ggml/parakeet.cpp are
statically linked into the executable — the only runtime dependencies are
Apple's system frameworks).

GitHub Actions repeats the self-tests, builds the bundle, runs the installer
on a clean macOS runner, and verifies uninstallation.

### Parakeet CPU vs Vulkan benchmark

`scripts/benchmark-parakeet.sh` is a persistent, re-runnable script (not a
one-off spike): it synthesizes a fixed corpus via `say`/`afconvert`
(RU/EN/mixed, short commands, numbers, technical terms, ~30s and ~120s
segments), runs each clip through the real `--benchmark-transcribe` entry
point (a permanent entry point in `main.swift`, checked before
`NSApplication` is created, so it never falls through to a normal app
launch) on both CPU and Vulkan, and prints a table with cold load, warm-up,
first transcription, warm median/p95 latency, RTF, peak RSS, and the
effectively selected device. Results from a real run are in
`.superpowers/sdd/2026-07-28-parakeet-cpp-migration/FINAL-IMPLEMENTATION-REPORT.md`.

## ⚠️ Limitations

- Apple Silicon and Intel Macs on macOS 14 or newer are supported. Windows
  and Linux are not supported yet. Intel support in this fork has only been
  manually tested on one specific machine (Xeon E5-2678 v3 + AMD Radeon RX
  6600, macOS 15.7.7), not through CI: hosted GitHub macOS runners are only
  available on Apple Silicon, so there's no automated coverage of this path
  yet.
- The public build is signed ad-hoc and not notarized by Apple. Installing
  via the command above is verified, but a ZIP downloaded manually through a
  browser may trigger a Gatekeeper warning.
- Because there's no stable Developer ID signature, macOS sometimes
  re-prompts for permissions after an update. Notarization requires a paid
  Apple Developer account.
- The first launch needs internet access to download the model. The panel
  checks for updates when opened; the background auto-check, if enabled,
  hits the public GitHub API once every six hours.
- A single recording ends automatically after 20 minutes. If the app crashes,
  an unfinished recording is saved for history recovery.
- Protected password fields and apps that hide Accessibility data may not
  expose caret coordinates. This affects the animation's position but doesn't
  always prevent text insertion.
- Resource footprint on the current build: about 940 MB on disk for the model
  (`parakeet-tdt-0.6b-v3-q8_0.gguf`, parakeet.cpp engine, CPU-only in this
  version). Peak resident memory is about 940 MB–1.2 GB depending on
  recording length (measured on real Intel hardware, see the migration
  report). Older numbers for previous engines (whisper.cpp, FluidAudio/
  CoreML) don't apply to parakeet.cpp.

## 🔒 Privacy & data

- History and settings: `~/Library/Application Support/SuperDictate`.
- The parakeet.cpp model: `~/Library/Application Support/SuperDictate/Models`.
  (An old whisper.cpp cache, if left over from a previous version, lives
  separately in `~/Library/Application Support/Whisper/Models` and is not
  used by the current version.)
- LaunchAgent: `~/Library/LaunchAgents/com.local.superdictate.agent.plist`.
- Logs: `~/Library/Logs/SuperDictate*`.
- No analytics, accounts, or telemetry.

More details: [PRIVACY.md](PRIVACY.md).

## 🗑️ Uninstalling

```bash
curl -fsSL https://raw.githubusercontent.com/shohart/SuperDictate-Intel/main/uninstall.sh | bash
```

The app and the background service are removed. History, settings, and the
model are kept, so you don't lose data or need to re-download the model by
accident.

## 📜 Origin and license

SuperDictate is based on the open-source
[Parakey](https://github.com/rcourtman/parakey) project by Richard Courtman.
The original and modified code is distributed under the MIT License. See
[LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).

## 🤝 Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the checks to run before opening one, and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community guidelines.
