# Upstream Low-Risk Commit Portability Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port four low-risk upstream (`shlgd/SuperDictate`) commits — install/permission hardening, single-instance enforcement, microphone selection in settings, and a real CoreAudio capture bugfix — into this fork, in dependency order, without disturbing the fork's whisper.cpp/Vulkan engine work.

**Architecture:** These four commits live entirely in subsystems the fork's whisper.cpp port never touched (app install/signing, launchd single-instance lifecycle, AVAudioEngine/CoreAudio capture) — confirmed via an actual test cherry-pick of each commit against this fork's `main` during a prior research pass. Three cherry-pick cleanly or near-cleanly; the fourth (`f80fe6a`, microphone selection) depends on a small piece of upstream commit `e9ee631` ("Avoid unnecessary speech model restarts") that this plan does NOT port wholesale — that commit is entangled with FluidAudio-specific download-telemetry fields incompatible with this fork's whisper.cpp loading path, and is explicitly OUT OF SCOPE. Instead, Task 3 below reimplements only the minimal live-settings-reload mechanism `f80fe6a` needs, scoped to audio-input device changes only.

**Tech Stack:** Swift 6, `git cherry-pick`, AVAudioEngine/CoreAudio, launchd (LaunchAgent single-instance semantics).

## Global Constraints

- Upstream remote is already configured in this repo as `upstream` (`git@github.com:shlgd/SuperDictate.git`), already fetched. The four commits to port, in dependency order, are:
  1. `27efe17` — "Stabilize local installs and permission handling"
  2. `3b6a641` — "Keep the control panel and agent single-instance"
  3. (no upstream commit — Task 3 is fork-original, see below)
  4. `f80fe6a` — "Add microphone selection to settings"
  5. `17998b5` — "Fix capture from explicitly selected microphones"
- Do NOT cherry-pick or port `c539ded` ("Show model download telemetry and network guidance"), `e9ee631` ("Avoid unnecessary speech model restarts"), or `e9f9848` ("Show explicit startup stages") — all three are tightly coupled to FluidAudio's `DownloadUtils.DownloadProgress` phase/callback shape and CoreML/"Neural Engine" terminology, incompatible with this fork's whisper.cpp model-loading path. These were assessed and explicitly deferred to a separate, future reimplementation effort — out of scope for this plan.
- A prior research pass already test-cherry-picked all four commits (on a throwaway branch, since deleted) and found:
  - `27efe17` applies with exactly ONE trivial conflict: a property-declaration hunk near `audioInputPreferenceAtLastEngineStart`/`audioConfigurationRecoveryWorkItem` — resolve by keeping BOTH added lines (the conflict is spurious, caused by `audioInputPreferenceAtLastEngineStart` being introduced by the *later* `f80fe6a` commit and appearing as diff context, not a real logical conflict).
  - `3b6a641` applies with ZERO conflicts.
  - `f80fe6a` conflicts only in one hunk calling `reloadSettingsWhenIdle()`, which doesn't exist in this fork (it's from the out-of-scope `e9ee631`) — Task 3 provides a fork-native replacement with a compatible enough call site that Task 4 can adapt the one conflicting hunk to call it instead.
  - `17998b5` conflicts in 4 hunks when applied standalone, dropping to 2 once `27efe17` is already present (both remaining conflicts are due to `f80fe6a`'s `shouldRestartAudioInputForSettingsChange`/`Settings(defaults:)`/self-test fixtures not existing yet) — apply this LAST, after both `27efe17` and `f80fe6a` are in place, and the actual bugfix logic itself (`installCaptureTap`'s `inputFormat` vs `outputFormat` fix, `waitForSelectedInputDevice`) needed NO conflict resolution once its prerequisites were present.
- Never touch `/Applications/SuperDictate.app` or the live LaunchAgent during development/testing — all testing happens via fresh scratch builds on the real Intel Mac (`shohart@192.168.1.246`, password `n0tn33d3d`, reachable via `sshpass -p 'n0tn33d3d' ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no shohart@192.168.1.246 '<command>'`).
- Run builds as single synchronous foreground SSH commands with generous timeouts (5-10 minutes) — never background a build and poll separately.
- Only use debug builds (`swift build`/`swift run`, never `-c release`) for iteration and self-tests, to avoid triggering the app's real control-panel startup (a prior task's implementer accidentally triggered this via a release build's `--self-test` flag, which is compiled out in release).
- This fork also builds/runs on Intel Macs via a vendored whisper.cpp with an opt-in Vulkan GPU backend, none of which any of these four commits touch — do not let that context distract from the actual (audio-capture/install/lifecycle) scope of this plan.
- Preserve this fork's own prior work exactly — do not revert or weaken the keyboard-language menu item, GPU toggle menu item, or any whisper.cpp-related code while resolving conflicts; if a conflict resolution is ambiguous about which side should "win" in a shared function, prefer keeping BOTH sides' additions (this fork's whisper.cpp/menu additions AND upstream's new behavior) rather than dropping either.

---

### Task 1: Cherry-pick `27efe17` — stabilize local installs and permission handling

**Files:**
- Create (via cherry-pick): `AGENTS.md`, `scripts/install-local.sh`
- Modify (via cherry-pick): `swift/Sources/Parakey/main.swift`

**Interfaces:**
- Produces: `installCaptureTap()` (extracted from `AudioCapture.startEngine`) and `recoverAfterConfigurationChange()` — Task 5 (`17998b5`) depends on `installCaptureTap()` existing with this exact name/shape.
- Removes: the `TCC.reset`/auto-tccutil-reset flow (replaced with "Open Settings" links in the main menu and control panel).

- [ ] **Step 1: Cherry-pick**

```bash
git cherry-pick 27efe17
```

- [ ] **Step 2: Resolve the one expected conflict**

The conflict is in `swift/Sources/Parakey/main.swift`, near a property-declaration hunk for `audioInputPreferenceAtLastEngineStart`/`audioConfigurationRecoveryWorkItem`. Per the Global Constraints, this is a spurious conflict — resolve by keeping BOTH added lines from both sides of the conflict marker (do not drop either). After resolving, search the whole file for any remaining reference to the removed `TCC` enum/auto-reset flow (`grep -n "TCC\."` or similar) and confirm none remain outside of what the commit intentionally removed.

- [ ] **Step 3: Continue the cherry-pick and verify**

```bash
git add swift/Sources/Parakey/main.swift
git cherry-pick --continue
```

Build on the real Mac (fresh scratch dir, never `/Applications`): `swift build --package-path swift`, then `swift run --package-path swift Parakey --self-test all` → PASS. Confirm `scripts/install-local.sh` and `AGENTS.md` are present and unmodified from upstream's version (no reason for this plan to touch their content).

- [ ] **Step 4: Report**

No separate commit needed — the cherry-pick IS the commit (with `--continue` finalizing it, preserving the original commit message/authorship per normal `git cherry-pick` behavior).

---

### Task 2: Cherry-pick `3b6a641` — keep the control panel and agent single-instance

**Files:**
- Modify (via cherry-pick): `swift/Sources/Parakey/main.swift`

**Interfaces:**
- Consumes: nothing new from Task 1 (independent).
- Produces: atomic `O_CREAT|O_EXCL` PID-file single-instance claim, `controlPanelLaunchInProgress`/`terminationHandler` de-dupe tracking — no downstream task in this plan depends on these symbols directly.

- [ ] **Step 1: Cherry-pick**

```bash
git cherry-pick 3b6a641
```

Per the Global Constraints, this was verified to apply with ZERO conflicts in the research pass. If a conflict appears anyway (state may have shifted slightly from Task 1's commit landing first), resolve it following the same "keep both sides' additions" principle from the Global Constraints, but expect none.

- [ ] **Step 2: Verify**

Build and self-test on the real Mac (same process as Task 1, fresh scratch dir): `swift build --package-path swift`, `swift run --package-path swift Parakey --self-test all` → PASS.

- [ ] **Step 3: Report**

No separate commit needed — same as Task 1.

---

### Task 3: Implement a minimal fork-native live-settings-reload hook for audio input changes

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`

**Interfaces:**
- Produces: a function Task 4 can call from the settings-save path when only the microphone selection changed, that restarts audio capture WITHOUT restarting the whisper.cpp speech engine/model. Name it `reloadAudioInputIfNeeded()` (deliberately NOT `reloadSettingsWhenIdle`, to avoid implying feature parity with upstream's broader, out-of-scope settings-live-reload mechanism — this is scoped to audio input only).
- Consumes: whatever this fork's existing settings-save code path already is (read `main.swift` for the current "Save" button / settings-apply logic before writing this — it currently likely triggers a full service restart on any settings change; find that call site).

- [ ] **Step 1: Read the current settings-save flow**

Before writing anything, read how `main.swift` currently handles a settings-window "Save" action — find where it decides whether/how to restart the control panel service or reload the speech model. This fork does NOT have `e9ee631`'s `SETTINGS_CHANGED_NOTIFICATION`/`reloadSettingsWhenIdle` distributed-notification mechanism (explicitly out of scope per Global Constraints) — the current behavior is whatever pre-dated that upstream commit.

- [ ] **Step 2: Add `reloadAudioInputIfNeeded()`**

Add a function that: compares the newly-saved microphone preference against what audio capture is currently using, and if (and only if) it changed, restarts JUST the audio-capture/AVAudioEngine layer (reusing `installCaptureTap()`/`recoverAfterConfigurationChange()` from Task 1's `27efe17` cherry-pick) — explicitly WITHOUT touching `TranscriptionWorker`/the whisper.cpp engine/model state. Wire this into the settings-save path found in Step 1, as an additional check alongside (not replacing) whatever existing restart-decision logic is there.

- [ ] **Step 3: Verify no regression to existing settings-save behavior**

Confirm that changing a NON-audio setting (e.g. hotkey, GPU toggle, dictation language) still behaves exactly as it did before this task — this task must be strictly additive for the audio-input case, not a general rewrite of the settings-save flow. Build and self-test on the real Mac.

- [ ] **Step 4: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "Add a minimal audio-input-only live-reload hook for the upcoming microphone picker"
```

---

### Task 4: Cherry-pick and adapt `f80fe6a` — add microphone selection to settings

**Files:**
- Modify (via cherry-pick + manual fix): `swift/Sources/Parakey/main.swift`

**Interfaces:**
- Consumes: `installCaptureTap()`/`recoverAfterConfigurationChange()` (Task 1), `reloadAudioInputIfNeeded()` (Task 3).
- Produces: `microphoneSettingsRow`, `Settings(defaults:)` initializer, `shouldRestartAudioInputForSettingsChange()`, `testLiveAudioInputEnumeration` self-test — Task 5 (`17998b5`) depends on all of these existing.

- [ ] **Step 1: Cherry-pick**

```bash
git cherry-pick f80fe6a
```

- [ ] **Step 2: Resolve the expected conflict**

Per the Global Constraints, the only conflict is in the hunk that calls upstream's `reloadSettingsWhenIdle()` (which doesn't exist in this fork). Replace that call with Task 3's `reloadAudioInputIfNeeded()` — read both functions' signatures first to adapt the call site correctly (parameter shape may differ; Task 3's function is intentionally narrower in scope, so some of upstream's call-site logic around it may need to be simplified to match, e.g. dropping any branching that assumed the broader notification-based mechanism).

- [ ] **Step 3: Continue and verify**

```bash
git add swift/Sources/Parakey/main.swift
git cherry-pick --continue
```

Build and self-test on the real Mac. Additionally, manually verify (via the app's actual settings window, on the real Mac, since this needs live CoreAudio device enumeration that a headless self-test may not fully exercise) that the microphone picker lists real input devices and that switching selection doesn't restart the whisper.cpp engine (watch the log output for whisper.cpp init/model-load lines — they should NOT reappear on a mic-only settings save).

- [ ] **Step 4: Report**

No separate commit needed — the cherry-pick IS the commit.

---

### Task 5: Cherry-pick `17998b5` — fix capture from explicitly selected microphones

**Files:**
- Modify (via cherry-pick): `swift/Sources/Parakey/main.swift`

**Interfaces:**
- Consumes: `installCaptureTap()` (Task 1), `Settings(defaults:)`/`shouldRestartAudioInputForSettingsChange`/mic-picker self-test fixtures (Task 4).

- [ ] **Step 1: Cherry-pick**

```bash
git cherry-pick 17998b5
```

Per the Global Constraints, applying this AFTER Tasks 1 and 4 are in place should leave zero conflicts in the actual bugfix logic (`installCaptureTap`'s `inputFormat` vs `outputFormat` fix, `waitForSelectedInputDevice`) — any remaining conflicts should only be in adjacent self-test fixture code, if the exact line numbers shifted due to this plan's Task 3 addition. Resolve any such conflicts by keeping both sides' test assertions.

- [ ] **Step 2: Verify the actual bugfix**

This commit fixes a real, previously-observed bug: `AVAudioInputNode.outputFormat(forBus:)` reporting a stale sample rate after switching `kAudioOutputUnitProperty_CurrentDevice`, causing an exception on `installTap`. On the real Mac, exercise this directly: use the app's new microphone picker (from Task 4) to switch between at least two different real input devices (if this Mac has more than one available — check `system_profiler SPAudioDataType` or similar; if only one physical device exists, the new `--diagnose-audio-capture` CLI flag this commit adds may allow a simulated/diagnostic check instead) and confirm no crash/exception, and that `waitForSelectedInputDevice()` correctly waits for the switch to complete before capture resumes.

- [ ] **Step 3: Full self-test suite**

```bash
swift run --package-path swift Parakey --self-test all
```
→ PASS, including the new/strengthened self-test assertions this commit adds (verify CoreAudio actually switched devices + sample rate matches).

- [ ] **Step 4: Report**

No separate commit needed — the cherry-pick IS the commit.

---

### Task 6: Full branch verification and cleanup

**Files:**
- Test only — no source changes expected.

**Interfaces:**
- Consumes: all of Tasks 1-5.

- [ ] **Step 1: Full clean build + self-test on the real Mac**

Fresh scratch build (never `/Applications`): `swift build --package-path swift`, `swift run --package-path swift Parakey --self-test all` → PASS.

- [ ] **Step 2: Confirm whisper.cpp/Vulkan/keyboard-language/GPU-toggle functionality is untouched**

Spot-check that this fork's own prior features (keyboard-layout language detection, dynamic audio_ctx, GPU/Vulkan toggle, their menu items) are all still present and functionally intact in `main.swift` — grep for their key symbols (`resolveEffectiveWhisperLanguage`, `audioContextFrames`, `useGPU`) to confirm none were accidentally reverted/dropped during conflict resolution across Tasks 1-5.

- [ ] **Step 3: Verify `scripts/build-app.sh` + codesign still succeed**

```bash
bash -n install.sh uninstall.sh scripts/build-app.sh scripts/install-local.sh
plutil -lint swift/Info.plist entitlements.plist
./scripts/build-app.sh ./dist/SuperDictate.app
codesign --verify --deep --strict ./dist/SuperDictate.app
```

- [ ] **Step 4: Commit any final cleanup if needed, otherwise this task is verification-only**

---

### Task 7: Fix the menu bar status icon never being revealed after startup

**Files:**
- Modify: `swift/Sources/Parakey/main.swift`

**Interfaces:**
- Modifies: the `ParakeyApp` (`--agent` process) startup/ready path — the same class that owns `statusItem`, `configureStatusItemImage()`, `concealMenuBarIcon()`, `setMenuBarState(_:)`.

**Context:** A real-hardware investigation (not a hypothesis — confirmed by exhaustively grepping the whole file, and cross-checking against `upstream/main`'s current version of the same code, which has the identical bug) found: `applicationDidFinishLaunching` in `ParakeyApp` calls `concealMenuBarIcon()` once at startup (`statusItem.length = 0`, `statusItem.button?.isHidden = true`), and `setMenuBarState(.loading)`. Later, once startup succeeds, `isReady = true` is set and `setMenuBarState(.idle)` runs — but `setMenuBarState(_:)`'s implementation only ever touches `button.image`/`button.contentTintColor` per-case; it never restores `statusItem.length` or `button.isHidden`. Confirmed via `grep -n "\.length" swift/Sources/Parakey/main.swift | grep -i status` that `statusItem.length` is assigned exactly ONCE in the entire file — the concealment. There is no code path anywhere that reveals the icon again. This means the menu bar status icon is permanently invisible after the app reaches its ready state, on real hardware, confirmed by the plan owner directly (not visible in the menu bar, not in the Control Center overflow chevron either — ruling out a macOS menu-bar-crowding false lead).

- [ ] **Step 1: Locate the exact ready-state transition**

Find where `isReady = true` is set together with the call to `setMenuBarState(.idle)` (search near `isReady = true` in `ParakeyApp` — as of this plan's writing it's around the point where `startStartup`'s success path finishes, calling `clearSpeechModelStartupProgress()`, `stopPermissionReadinessMonitor()`, `setMenuBarState(.idle)`, `refreshActivationPolicy()`, `rebuildMenu()`, `startUpdateCheckLoop()`, in that order — exact line numbers will have shifted from Tasks 1-6 landing first, re-locate by searching for these symbol names together).

- [ ] **Step 2: Add the reveal**

Immediately before or after the `setMenuBarState(.idle)` call in that same success path, add:
```swift
statusItem.length = NSStatusItem.squareLength
statusItem.button?.isHidden = false
```
Match the existing code's comment style — add a short comment explaining this is the counterpart to `concealMenuBarIcon()` (which this fix does not rename or remove), since a future reader needs to understand these two calls are a matched pair now, not one-directional.

- [ ] **Step 3: Consider the failure path too**

Check `startStartup`'s FAILURE path (search for where `startupFailure` gets set to non-nil, or `setMenuBarState(.error)` gets called) — decide whether the icon should also be revealed there (showing an error-state icon the user can click for details) rather than staying invisible forever on a startup failure too. If `setMenuBarState(.error)` is already reachable from a path where the icon was never revealed, apply the same two-line reveal there as well, so a startup failure is at least visible/clickable instead of silently invisible.

- [ ] **Step 4: Build, self-test, and verify on the real Mac**

Fresh scratch build (never `/Applications`), `swift build --package-path swift`, `swift run --package-path swift Parakey --self-test all` → PASS. Since this is a real UI-visibility bug that a headless self-test cannot directly observe (no way to screenshot the actual menu bar over SSH), also do a direct runtime check: launch the built binary with `--agent` in the scratch dir, `tail`/inspect its log output through to the `ASR: ... ready` line (matching the pattern already seen in this project's production logs), and if any way exists to introspect `NSStatusItem.length`/`isHidden` state at runtime (e.g. a temporary debug log line printing `statusItem.length` right after the fix's new code runs, removed before committing, or via a `--self-test` addition that constructs a `ParakeyApp`-equivalent status item path and asserts the post-ready state) — use your judgment on the most reliable way to get real evidence this fix works, given the self-test suite's existing patterns in this file for similar non-trivially-observable state. Do NOT just assert "the two lines are there" — get some form of runtime confirmation given the history of this exact class of claim ("should work by inspection") being wrong for this exact icon-visibility bug at least once already in this project.

- [ ] **Step 5: Commit**

```bash
git add swift/Sources/Parakey/main.swift
git commit -m "Reveal the menu bar status icon once startup completes"
```
