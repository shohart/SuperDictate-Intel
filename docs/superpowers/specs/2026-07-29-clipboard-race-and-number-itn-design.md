# Design: Clipboard-restore race fix + Russian number ITN toggle

Date: 2026-07-29

## Background

Two independent issues raised by the user while using SuperDictate:

1. **Clipboard bug**: if the system clipboard already holds content (text, file,
   or other object) from another app when dictation starts, pasting the
   dictation result sometimes inserts the *old* clipboard content instead of
   the freshly dictated text.
2. **Feature request**: a Control Panel setting to render dictated numbers as
   digits ("25") instead of the words the Parakeet ASR model currently
   produces ("двадцать пять").

Both are scoped as independent workstreams and can be implemented in parallel.

---

## Part 1 — Clipboard-restore race fix

### Root cause

`ClipboardPasteInserter.insert` (main.swift:7252-7298) already clears and
writes the pasteboard correctly before pasting — the "doesn't clear the
clipboard" theory is not the actual bug. The real defect is in
`restorePasteboard` (main.swift:7273-7291): after posting the synthetic
Cmd+V keystroke, the code waits a **fixed 0.35s** (`restoreDelay`) and then
restores the pre-dictation clipboard snapshot (`PasteboardSnapshot`,
main.swift:7259/7302-7332), guarded only by a `changeCount`/string-equality
check on the pasteboard itself — not by any confirmation that the target
app actually consumed the paste.

If the focused application is slow to process the synthetic Cmd+V (busy
main thread, heavy UI, background work, etc.) for longer than 0.35s, the
restore fires first, the pasteboard reverts to the pre-dictation content,
and when the target app finally reads the clipboard for its paste, it reads
the *old* content. This matches the reported symptom exactly.

### Fix

Replace the fixed-delay restore with a confirmation-based restore:

- After posting the Cmd+V event steps, poll the focused UI element's value
  via the Accessibility API (`kAXFocusedUIElementAttribute` →
  `kAXValueAttribute`, falling back to `kAXSelectedTextAttribute` if value
  is unavailable) at a short interval (~50ms) to detect that the dictated
  text has actually landed.
- Only call `restorePasteboard` once that confirmation succeeds.
- Keep a safety-net timeout (e.g. 2s, up from the current 0.35s) so that if
  AX access to the target element is unavailable or inconclusive, the
  clipboard is still restored eventually rather than left permanently
  overwritten.
- This reuses the existing AX read-access plumbing already present in
  `TextInsertionService.swift`/`FocusedTextTarget.swift` (currently only
  wired for the disabled AX-focused *insertion* path) but only for
  **read-only confirmation** here — the insertion path itself
  (`ClipboardPasteInserter` + global `.cghidEventTap` paste) is unchanged.

### Testing

- Unit/integration test simulating a slow-to-process target (delay the
  mock AX value update past the old 0.35s window) and asserting the
  clipboard is *not* restored until the value confirms.
- Regression test for the existing fast-path (target updates immediately)
  to confirm restore still happens promptly.
- Manual test: dictate into a deliberately slow/busy app with clipboard
  pre-populated from another app; confirm correct text lands and original
  clipboard content reappears afterward.

---

## Part 2 — Russian number ITN (inverse text normalization) toggle

### Scope

- Cardinal numerals: "двадцать пять" → "25"
- Ordinal numerals: "двадцать пятый/пятого/пятой" → "25-й/25-го/25-й" (case
  suffix preserved)
- Dates: "двадцать девятое июля две тысячи двадцать шестого года" →
  "29 июля 2026 года"
- Money: "пятьсот рублей" → "500 рублей"
- Phone numbers are explicitly **out of scope** (no reliable spoken-grammar
  marker distinguishes a phone-number digit run from adjacent unrelated
  numbers; the only benefit would be inserting separators, which isn't
  worth the false-positive risk).
- Russian only. English dictation is out of scope (not currently a target
  usage mode for this user).

### Approach

Port the *grammar logic* used by established Russian ITN tools (NeMo
text-processing's Russian grammar, natasha/yargy number extractors) into
native Swift — reimplementing their token-classification rules directly,
rather than embedding their runtimes (Python + pynini/OpenFst or a Python
interpreter via PythonKit). This avoids adding a Python/WFST dependency
(startup cost, binary size, macOS packaging complexity) to what is
currently a dependency-light Swift app, at the cost of the same
grammar-implementation effort a from-scratch parser would need — but with
a proven rule structure to follow instead of designing one from zero.

### Structure

New standalone file, e.g. `swift/Sources/Parakey/RussianNumberNormalizer.swift`:

1. **Tokenizer** — splits text into words while preserving whitespace/
   punctuation for exact reassembly of non-matched spans.
2. **Cardinal parser** — unit/teen/ten/hundred/thousand/million lookup
   tables with gender (два/две) and case (пять/пяти/пятью/...) variants;
   folds consecutive numeral tokens into one integer value.
3. **Ordinal parser** — built on the cardinal tables, separate lookup for
   ordinal word forms per case/gender, emits `"<digits>-<case suffix>"`.
4. **Context recognizers layered on top of (2)+(3)**:
   - Date pattern: `<ordinal day> <month word> <cardinal year> года`
   - Money pattern: `<cardinal> <currency word: рублей/долларов/евро/...>`
5. **Conservative fallback** — any numeral sequence not matched with high
   confidence by one of the above is left as the original dictated words;
   the normalizer never guesses.

### Pipeline integration

- New `Settings` key `normalizeNumbersToDigits` (pattern matches existing
  `removeFillerWords` at main.swift:2821/3466-3468), exposed as a toggle in
  the Control Panel (`ControlPanelSettingsDraft` + `makeSettingsContentView()`,
  main.swift:21958-22239) — **not** a menu-bar-only toggle.
- Runs inside `dictationTextProcessing(...)` (main.swift:6319-6342),
  **before** `TranscriptCorrectionApplier.apply` and after filler-word
  removal, so user-authored corrections can still adjust the ITN output if
  needed.

### Testing

- Table-driven unit tests: input phrase → expected digit-form output, one
  table per category (cardinals, ordinals, dates, money).
- Negative-case tests: numerals that must NOT be converted (e.g. "один из
  способов", "по одному") to guard against over-eager matching.
- Manual dictation test end-to-end with the toggle on/off in the Control
  Panel.
