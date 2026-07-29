import AppKit
import ApplicationServices

// Polls the currently AX-focused element's value until dictated text
// actually appears in it (or a timeout elapses), so the clipboard-restore
// step in ClipboardPasteInserter can wait for real paste completion instead
// of guessing a fixed delay. See main.swift ClipboardPasteInserter for the
// caller and the race this closes.
enum PasteConfirmationPoller {
    // Waits for `valueReader()` to report a value that (a) differs from
    // `baselineValue` -- the value captured before/immediately after the
    // paste keystroke was posted -- and (b) contains `expectedSubstring`.
    //
    // The `baselineValue` check exists because `contains(expectedSubstring)`
    // alone can't distinguish "this paste just landed" from "the field
    // already happened to contain matching text" (e.g. dictating the same
    // short phrase twice into the same field, or dictating a word that's
    // already present elsewhere in a long field) -- without it, the very
    // first poll tick could confirm against pre-existing content before the
    // real paste has been processed by a slow target app, reintroducing the
    // exact premature-restore race this poller exists to close.
    //
    // Separately, `unreadableValueBailout` guards against apps whose
    // Accessibility tree never exposes a readable value at all (some
    // Electron/Chromium apps, terminal emulators, custom-drawn text views):
    // for those, `valueReader()` returns nil on every tick, and without this
    // guard the poller would burn the entire `timeout` (2s) before falling
    // back to restore -- worse than the original fixed 0.35s delay for that
    // whole category of apps. If no readable value has EVER been observed
    // by `unreadableValueBailout` seconds in, give up early; once at least
    // one readable (even if non-matching) value has been seen, this early
    // exit no longer applies and the full `timeout` budget is used, since
    // the target clearly can expose a value and just hasn't updated it yet.
    static func waitForPasteConfirmation(expectedSubstring: String,
                                         baselineValue: String?,
                                         pollInterval: TimeInterval = 0.05,
                                         timeout: TimeInterval = 2.0,
                                         unreadableValueBailout: TimeInterval = 0.35,
                                         valueReader: @Sendable () -> String?) -> Bool {
        if expectedSubstring.isEmpty { return true }
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let unreadableDeadline = start.addingTimeInterval(unreadableValueBailout)
        var everReadValue = false

        while Date() < deadline {
            if let value = valueReader() {
                everReadValue = true
                if value != baselineValue, value.contains(expectedSubstring) {
                    return true
                }
            } else if !everReadValue, Date() >= unreadableDeadline {
                return false
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    // Builds a valueReader that resolves the currently AX-focused element
    // ONCE, on its first invocation, and caches it for every subsequent
    // call -- rather than re-running FocusedTextTargetResolver().captureTarget()
    // (which has its own internal retry loop of up to 5 attempts x 0.04s,
    // plus unconditional verbose logging on every successful capture, see
    // FocusedTextTarget.swift) on every single poll tick. A worst-case poll
    // (near the full 2s timeout at the default 0.05s interval) is ~40 ticks;
    // re-resolving that many times would mean up to ~40 full
    // resolution-plus-logging cycles for one paste.
    //
    // The returned closure is called from a single background queue in
    // strictly sequential order (never concurrently), so the plain
    // (non-atomic) cache on this reference-type box is safe: there is only
    // ever one active caller at a time.
    static func currentFocusedElementValueReader() -> @Sendable () -> String? {
        final class TargetCache: @unchecked Sendable {
            var attemptedResolve = false
            var target: FocusedTextTarget?
        }
        let cache = TargetCache()

        return {
            if !cache.attemptedResolve {
                cache.attemptedResolve = true
                cache.target = try? FocusedTextTargetResolver().captureTarget()
            }
            guard let target = cache.target else { return nil }

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(target.element,
                                                        kAXValueAttribute as CFString,
                                                        &value)
            if result == .success, let stringValue = value as? String {
                return stringValue
            }
            var selectedText: CFTypeRef?
            let selectedResult = AXUIElementCopyAttributeValue(target.element,
                                                                "AXSelectedText" as CFString,
                                                                &selectedText)
            if selectedResult == .success, let stringValue = selectedText as? String {
                return stringValue
            }
            return nil
        }
    }
}
