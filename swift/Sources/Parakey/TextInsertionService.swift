import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Which mechanism `TextInsertionService.insert` ended up using, or why it
/// gave up entirely. Every tier here targets `FocusedTextTarget`'s specific
/// process directly — this is the primary AX-based insertion path, meant to
/// run ahead of `TextInserter`'s global-post fallback (wired in by the
/// integration layer, not here).
enum TextInsertionResult: Equatable {
    case insertedUsingSelectedText
    case insertedUsingValueAndRange
    case insertedUsingKeyboardEvents
    case failed(TextInsertionError)
}

enum TextInsertionError: Error, Equatable {
    case targetNoLongerValid
    case noSupportedInsertionMethod
    case accessibilityError(operation: String, error: AXError)
}

@MainActor
final class TextInsertionService {
    private let retryAttempts = 5
    private let retryDelays: [UInt64] = [30_000_000, 35_000_000, 40_000_000, 45_000_000, 50_000_000]  // ns; ~200ms ceiling
    private let maxUTF16UnitsPerEvent = 20
    private let interChunkDelay: UInt64 = 5_000_000  // ns — postToPid delivers via the target's own event queue rather than the shared HID tap, so a short gap avoids the target coalescing/dropping back-to-back synthetic keys

    func insert(_ text: String, into target: FocusedTextTarget) -> TextInsertionResult {
        guard isProcessAlive(target.applicationPID) else {
            log("text insertion (AX target) failed: target process no longer alive")
            return .failed(.targetNoLongerValid)
        }
        restoreAccessibilityFocus(target)

        if insertUsingSelectedText(text, element: target.element) {
            log("text insertion (AX target) succeeded: selected-text attribute")
            return .insertedUsingSelectedText
        }
        if insertUsingValueAndRange(text, element: target.element) {
            log("text insertion (AX target) succeeded: value+range attributes")
            return .insertedUsingValueAndRange
        }
        if insertUsingKeyboardEvents(text, pid: target.applicationPID) {
            log("text insertion (AX target) succeeded: targeted keyboard events")
            return .insertedUsingKeyboardEvents
        }
        log("text insertion (AX target) failed: no supported insertion method")
        return .failed(.noSupportedInsertionMethod)
    }

    // MARK: - Tier 1: kAXSelectedTextAttribute

    private func insertUsingSelectedText(_ text: String, element: AXUIElement) -> Bool {
        guard isSettable(element, attribute: kAXSelectedTextAttribute as CFString) else { return false }
        let error = setAttributeWithRetry(element,
                                          attribute: kAXSelectedTextAttribute as CFString,
                                          value: text as CFString)
        return error == .success
    }

    // MARK: - Tier 2: kAXValueAttribute + kAXSelectedTextRangeAttribute

    private func insertUsingValueAndRange(_ text: String, element: AXUIElement) -> Bool {
        guard isSettable(element, attribute: kAXValueAttribute as CFString) else { return false }

        guard let sourceValue = copyStringAttribute(element, kAXValueAttribute as CFString) else { return false }
        let source = sourceValue as NSString

        guard let selectedRange = copyRangeAttribute(element, kAXSelectedTextRangeAttribute as CFString) else {
            return false
        }
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= source.length,
              selectedRange.location + selectedRange.length <= source.length else {
            return false
        }

        let updated = source.replacingCharacters(in: NSRange(location: selectedRange.location, length: selectedRange.length),
                                                  with: text)
        let setValueError = setAttributeWithRetry(element,
                                                   attribute: kAXValueAttribute as CFString,
                                                   value: updated as CFString)
        guard setValueError == .success else { return false }

        if isSettable(element, attribute: kAXSelectedTextRangeAttribute as CFString) {
            let insertedLength = (text as NSString).length
            var newRange = CFRange(location: selectedRange.location + insertedLength, length: 0)
            if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
                _ = setAttributeWithRetry(element,
                                          attribute: kAXSelectedTextRangeAttribute as CFString,
                                          value: newRangeValue)
            }
        }
        return true
    }

    // MARK: - Tier 3: targeted keyboard events

    private func insertUsingKeyboardEvents(_ text: String, pid: pid_t) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var didPostAll = true
        let chunks = unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: maxUTF16UnitsPerEvent)

        for (index, chunk) in chunks.enumerated() {
            didPostAll = post(chunk, source: source, pid: pid) && didPostAll
            if index < chunks.count - 1 {
                Thread.sleep(forTimeInterval: Double(interChunkDelay) / 1_000_000_000)
            }
        }
        return didPostAll && !chunks.isEmpty
    }

    private func post(_ units: [UInt16], source: CGEventSource?, pid: pid_t) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.flags = []
        up.flags = []
        for event in [down, up] {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        // The bug this service exists to fix: `event.post(tap: .cghidEventTap)`
        // delivers globally, to whatever the OS currently treats as
        // keyboard-focused — which can diverge from the AX-focused element
        // we resolved (e.g. SwiftBar's WKWebView popover). `postToPid`
        // delivers straight to the target process's own event queue,
        // bypassing OS keyboard-focus routing entirely.
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    // MARK: - Shared AX helpers

    private func restoreAccessibilityFocus(_ target: FocusedTextTarget) {
        if isSettable(target.element, attribute: kAXFocusedAttribute as CFString) {
            _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func isSettable(_ element: AXUIElement, attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute, &settable)
        return result == .success && settable.boolValue
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success else { return nil }
        return raw as? String
    }

    private func copyRangeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    /// Retries `kAXErrorCannotComplete` a handful of times — apps
    /// occasionally return it transiently while they're mid-update — before
    /// giving up so the next insertion tier can take over.
    @discardableResult
    private func setAttributeWithRetry(_ element: AXUIElement, attribute: CFString, value: CFTypeRef) -> AXError {
        var lastError: AXError = .failure
        for attempt in 0..<retryAttempts {
            let error = AXUIElementSetAttributeValue(element, attribute, value)
            if error != .cannotComplete {
                return error
            }
            lastError = error
            if attempt < retryDelays.count {
                Thread.sleep(forTimeInterval: Double(retryDelays[attempt]) / 1_000_000_000)
            }
        }
        return lastError
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }
}
