import AppKit
import ApplicationServices

// Polls the currently AX-focused element's value until dictated text
// actually appears in it (or a timeout elapses), so the clipboard-restore
// step in ClipboardPasteInserter can wait for real paste completion instead
// of guessing a fixed delay. See main.swift ClipboardPasteInserter for the
// caller and the race this closes.
enum PasteConfirmationPoller {
    static func waitForPasteConfirmation(expectedSubstring: String,
                                         pollInterval: TimeInterval = 0.05,
                                         timeout: TimeInterval = 2.0,
                                         valueReader: @Sendable () -> String?) -> Bool {
        if expectedSubstring.isEmpty { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = valueReader(), value.contains(expectedSubstring) {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    static func currentFocusedElementValueReader() -> @Sendable () -> String? {
        {
            guard let target = try? FocusedTextTargetResolver().captureTarget() else {
                return nil
            }
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
