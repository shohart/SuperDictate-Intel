# Phase 6 — verify Whisper is fully gone (Checkpoint E)

Plan: `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md` (Phase 6
section). Spec: `docs/parakeet-intel-backend.md` §17 (removal requirement)
and §24 (required validation commands). Branch
`agent/parakeet-intel-backend-architecture`, worktree
`.worktrees/parakeet-migration`, run against commit `1bb8ae4` (Phase 3's
"replace Whisper with Parakeet CPU throughout the app" commit — the tip of
the branch at the start of this phase).

This is a **fresh, independent final sweep**, not a first pass — Phase 3
already deleted `swift/Sources/whisper_cpp/` (~57 MB, 1911 files) and its
SwiftPM target, and reported zero `nm`/`strings` Whisper hits as part of
its own commit. Every check below was re-run independently in this phase,
not taken on trust from that report.

## Environment

All commands ran for real on the Intel Mac (`shohart@192.168.1.246`:
Darwin 24.6.0 / macOS 15.7.7, x86_64, Swift 6.1.2 / Xcode Command Line
Tools), synced from this worktree to a fresh scratch directory
`~/scratch/parakeet-phase6/repo/` via `git archive HEAD | ssh ... tar -x`
(same method as every prior phase, distinct directory from Phase 4/5's own
scratch checkouts to avoid collision). `defaults write
com.local.superdictate agent_enabled -bool false` was run before any
scratch activity; the real production app at `/Applications/SuperDictate.app`
and its LaunchAgent were never touched.

## 1. Repo-wide grep for Whisper references

```
$ rg -n -i "whisper|large-v3-turbo|whisper_cpp" . --hidden
```

(`--hidden` needed because `.superpowers/` is a dot-directory that `rg`
otherwise skips by default; the plain `.` invocation without `--hidden`
undercounts — confirmed by running both and diffing. `grep -rniE
--exclude-dir=.git` on the remote Mac, which has no `.gitignore`-aware
default, gave the same 309-line total as local `rg --hidden`, cross-checking
the result.)

**309 matches total**, falling into exactly these categories:

- **252 matches** — planning/report documents that legitimately discuss
  Whisper as the thing being replaced: `docs/parakeet-intel-backend.md`
  (71, the target-state spec, explicitly instructs Whisper removal and
  documents §17/§24 with the word "Whisper" as its own subject),
  `docs/superpowers/plans/2026-07-28-parakeet-cpp-migration.md` (32, this
  plan itself), and the `.superpowers/sdd/2026-07-28-parakeet-cpp-migration/`
  phase reports (168 across phase-1/2/3/5 reports — historical narration of
  what was replaced/measured/deleted). These are explicitly carved out by
  the plan's own Phase 6 instruction ("no matches, or narrowly-justified
  changelog mentions") and by this task's brief.
- **52 matches in `swift/Sources/Parakey/main.swift`** — all doc comments
  or legacy-cache-handling code, not active Whisper runtime logic:
  `legacyWhisperModelFilePath()` / `removeLegacyWhisperModelFileIfPresent()`
  (spec §4.4's required best-effort cleanup of the *old* Whisper model
  file — deliberately still named/pathed after the legacy location so it
  can find it), a self-test assertion proving an old raw
  `"multilingual_v3"`/Whisper-era UserDefaults value no longer takes effect
  (the point of the test is that it's *not* trusted), and comments
  explaining migration history (e.g. "matches WhisperEngine's `deinit`
  precedent", "unlike whisper.cpp's forced-language parameter").
- **5 matches in `README.md`** — the "Whisper.cpp и large-v3-turbo больше не
  используются" sentence (explicitly stating they're gone), a note that old
  benchmark numbers for whisper.cpp/FluidAudio don't apply to parakeet.cpp,
  and the legacy-cache paragraph documenting that
  `~/Library/Application Support/Whisper/Models` may still exist from a
  prior install and is unused — required disclosure, not active use.
- **4 matches in `swift/Package.swift`, 3 in `ParakeetEngine.swift`, 3 in
  `scripts/vendor-parakeet-cpp.sh`, 3 in `scripts/build-app.sh`, 1 in
  `KeyboardLanguage.swift`** — all comments explaining what was removed or
  what precedent was mirrored, not executable Whisper logic.
- **1 match in `swift/Sources/parakeet_cpp/upstream/include/ggml.h`** —
  third-party vendored code, untouched by this fork: ggml's own top-of-file
  doc comment links to `github.com/ggml-org/whisper.cpp/issues/40` (ggml's
  own project history — it originated inside whisper.cpp). This file is
  regenerated verbatim by `scripts/vendor-parakeet-cpp.sh` from upstream's
  pinned ggml submodule; editing it would be pointless (a re-vendor would
  restore it) and it is not SuperDictate's own code.

**No production runtime code path remains that reads, loads, links, or
executes Whisper.** `swift/Sources/whisper_cpp/` does not exist
(`test -d swift/Sources/whisper_cpp` → `GONE`, confirmed both locally and
on the synced Mac scratch tree).

## 2. Full clean release build

```
$ ./scripts/build-app.sh ./dist/SuperDictate.app
```

Ran fresh from the exact synced commit (`rm -rf dist` first, no reuse of
Phase 3's own build artifacts). Real output on the Mac:

```
Build complete! (228.68s)
SuperDictate: Signing the app...
SuperDictate: Built ./dist/SuperDictate.app
```

`dist/SuperDictate.app/Contents/MacOS/SuperDictate` produced, 3,483,936
bytes; app bundle 3.4 MB total. Compile warnings were limited to 5
pre-existing `-Wambiguous-macro` `static_assert` redefinition warnings in
vendored `ggml-quants.c` (macOS SDK's `_static_assert.h` vs. ggml's own
`ggml-common.h` macro) — not new, not Whisper-related, harmless (both
expansions agree).

## 3. Codesign verification

```
$ codesign --verify --deep --strict ./dist/SuperDictate.app
```

Passed silently (exit 0, `CODESIGN_OK` echoed by the wrapper). Ad-hoc
signed (`SIGN_IDENTITY` defaulted to `-`), matching this fork's standard
local build behavior.

## 4. Binary Whisper-symbol/string sweep

```
$ nm -gU ./dist/SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
(no output, exit 1)
$ strings ./dist/SuperDictate.app/Contents/MacOS/SuperDictate | grep -i whisper
(no output, exit 1)
```

Both independently re-verified on this phase's own fresh build (not
Phase 3's binary) — zero Whisper symbols or strings in the shipped
executable.

## 5. `otool -L` dependency check

```
$ otool -L ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
```

Full output: only Apple system frameworks/dylibs —
`Accelerate.framework`, `Foundation.framework`, `AVFAudio.framework`,
`AVFoundation.framework`, `AppKit.framework`, `ApplicationServices.framework`,
`AudioToolbox.framework`, `Carbon.framework`, `CoreAudio.framework`,
`CoreFoundation.framework`, `CoreGraphics.framework`, `CryptoKit.framework`,
`QuartzCore.framework`, `ServiceManagement.framework`, `libobjc.A.dylib`,
`libc++.1.dylib`, `libSystem.B.dylib`, and the standard Swift runtime
dylibs (`libswift*.dylib`) under `/usr/lib/swift/`.

Forbidden-dependency check:

```
$ otool -L ./dist/SuperDictate.app/Contents/MacOS/SuperDictate \
  | grep -E "/usr/local|/opt/homebrew|Cellar|MoltenVK\.dylib|libvulkan"
(no output, exit 1)
```

No Homebrew paths, no `Cellar`, no MoltenVK/Vulkan dylibs — expected, since
this phase's tree has no Vulkan wiring at all yet (CPU-only), and matches
this fork's static-linking discipline (ggml/parakeet.cpp statically linked
into the executable, only system frameworks as runtime deps).

`file`/`lipo` architecture check:

```
$ file ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
Mach-O 64-bit executable x86_64
$ lipo -info ./dist/SuperDictate.app/Contents/MacOS/SuperDictate
Non-fat file: ... is architecture: x86_64
```

Single-arch `x86_64`, matching this build being produced natively on the
Intel Mac.

## 6. Build/dev scripts, install/uninstall, README review

Checked `scripts/build-app.sh`, `install.sh`, `uninstall.sh`, `README.md`
for Whisper-specific logic Phase 3 might have missed. (Note:
`scripts/dev-run.sh` does not exist in this repo — `scripts/` contains only
`build-app.sh`, `check.sh`, `install-local.sh`, `vendor-parakeet-cpp.sh`;
there is no separate dev-run script to check.)

**Result: no fixes needed. Phase 3 already left all of these clean:**

- `install.sh` / `uninstall.sh`: zero matches for `whisper|large-v3|1\.6|model`
  (grep'd explicitly for stale download-size or model-path references) —
  clean.
- `scripts/build-app.sh`: only a comment explaining that no
  `vulkan-shaders` resource-copy step exists this phase, referencing
  `whisper_cpp` by name to explain *why* (its precompiled SPIR-V corpus
  targeted whisper's own ggml vintage and wasn't reusable). No active
  Whisper resource-copying or model-path logic remains — the app bundle
  step copies only `Info.plist`, two menubar PNGs, and the `.icns` icon.
- `README.md`: already accurately describes Parakeet TDT 0.6B v3
  (multilingual, GGUF, q8_0) via `parakeet.cpp`, states "CPU is the
  default" and that `Use GPU (Vulkan)` exists as a menu item but "is not
  yet connected to a real Vulkan backend... enabling the toggle does not
  yet change behavior, recognition still runs on CPU" — correctly **not**
  claiming GPU support that isn't wired into the app yet, matching this
  task's explicit instruction. States the ~940 MB download size (matching
  the pinned `PARAKEET_MODEL_SIZE_BYTES = 940663680`), the new model
  storage path (`~/Library/Application Support/SuperDictate/Models`), and
  explicitly disclaims the old whisper.cpp/FluidAudio benchmark numbers as
  inapplicable. This matches spec §21's checklist item-for-item. No edits
  needed.
- `scripts/vendor-parakeet-cpp.sh`: only comments citing
  `scripts/vendor-whisper-cpp.sh` as the established precedent this
  script's vendoring conventions mirror — historical/explanatory, no
  active Whisper logic (that script no longer exists; it was deleted with
  `whisper_cpp` in Phase 3).

## 7. `Info.plist` / `entitlements.plist`

```
$ grep -i -c whisper swift/Info.plist entitlements.plist
swift/Info.plist:0
entitlements.plist:0
```

Both zero. Manual read of `swift/Info.plist` confirms no Whisper-specific
keys, model paths, or usage-description strings — `CFBundleIdentifier`,
version strings, `NSMicrophoneUsageDescription` etc. are all
engine-agnostic or already Parakeet-neutral ("transcribes it locally on
your Mac").

## 8. Static sanity checks

```
$ bash -n install.sh uninstall.sh scripts/*.sh
BASH_SYNTAX_OK
$ plutil -lint swift/Info.plist entitlements.plist
swift/Info.plist: OK
entitlements.plist: OK
```

Both clean.

## Legacy model cache

Per spec §4.4 and this phase's own instruction, `~/Library/Application
Support/Whisper` was not touched — no recursive deletion of that user
directory was performed or attempted. `main.swift`'s
`removeLegacyWhisperModelFileIfPresent()` (Phase 3's code, unchanged this
phase) only removes the single known legacy model file, never the
directory itself.

## Note on a concurrent worktree conflict avoided

While this phase's checks were running, `git status` showed an *uncommitted*
modification to `swift/Sources/Parakey/main.swift` in this shared
worktree — a temporary `--transcribe-file` debug tool, explicitly commented
in its own source as "TEMPORARY, Phase 4 A/B measurement tool ONLY ...
Reverted before this phase's commit — never present in the tracked tree at
HEAD." This is another agent's in-progress Phase 4 work landing in the same
worktree mid-session (not the separate scratch checkout the dispatch brief
described, but harmless as long as it isn't committed by this phase). This
report and its commit do **not** touch, stage, or include that change —
only this report file was staged, via an explicit `git add <path>` rather
than `git add -A`/`git commit -a`, so Phase 4's in-flight, self-reverting
edit is left exactly as that agent left it.

## Conclusion

All Phase 6 / Checkpoint E requirements are satisfied:

1. `rg -n -i "whisper|large-v3-turbo|whisper_cpp" .` → 309 matches, every
   one either a planning/report document explicitly describing the
   migration (carved out by the plan), a justified legacy-cache-handling
   comment/function, a README disclosure statement, or one third-party
   vendored-file comment (`ggml.h`, not our code). **Zero active Whisper
   production code paths.**
2. Full clean release build via `scripts/build-app.sh` — succeeds
   (`Build complete! (228.68s)`).
3. `codesign --verify --deep --strict` — passes.
4. `nm -gU ... | grep -i whisper` and `strings ... | grep -i whisper` —
   both empty, independently re-verified on this phase's own fresh binary.
5. `otool -L` — only Apple system frameworks/dylibs; the forbidden-pattern
   grep (`/usr/local|/opt/homebrew|Cellar|MoltenVK\.dylib|libvulkan`)
   returns no matches.
6. `scripts/build-app.sh`, `install.sh`, `uninstall.sh`, `README.md`
   reviewed — already fully clean from Phase 3's own work; **no edits were
   required or made this phase**.
7. `swift/Info.plist` / `entitlements.plist` — no Whisper-specific content.
8. `plutil -lint` and `bash -n` sanity checks — both pass.

**This phase made no source, script, or documentation changes** — Phase 3's
removal work was already complete and accurate. This is the intended,
honest outcome for a final-sweep verification phase that finds nothing
left to clean up; only this report is added to the tree.
