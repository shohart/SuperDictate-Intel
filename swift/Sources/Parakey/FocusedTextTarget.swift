// Resolves the real system-wide Accessibility focus (AXUIElementCreateSystemWide
// → kAXFocusedApplicationAttribute → kAXFocusedUIElementAttribute) instead of
// trusting `NSWorkspace.shared.frontmostApplication`. The two disagree for
// WKWebView-hosted popovers (e.g. SwiftBar's menu-bar popover): the popover
// owns the real AX focus while NSWorkspace still reports whatever app was
// frontmost before the popover opened. See FocusedInsertionTargetLocator
// (main.swift) for the existing per-application AX target search this
// complements — that locator is handed a `pid_t` by its caller and assumes
// it already points at the right application; this resolver is how the
// caller finds that pid_t in the first place.

import AppKit
import ApplicationServices

struct FocusedTextTarget {
    let application: AXUIElement
    let element: AXUIElement

    let applicationPID: pid_t
    let elementPID: pid_t

    let applicationName: String?
    let role: String?
    let subrole: String?
}

// AXUIElement (an opaque CFTypeRef) isn't Sendable by default, so this
// struct doesn't get the compiler's automatic internal-type Sendable
// inference. Accessibility calls are documented by Apple as safe from any
// thread/queue — this resolver's own doc comment above assumes exactly
// that, expecting callers to hop actors around `captureTarget()`'s result
// — so `@unchecked` here just asserts what was already the design intent.
extension FocusedTextTarget: @unchecked Sendable {}

enum FocusedTargetError: Error {
    case accessibilityPermissionMissing
    case focusedApplicationUnavailable(AXError)
    case focusedElementUnavailable(AXError)
    case invalidApplicationElement
    case invalidFocusedElement
}

// Not @MainActor: AX round-trips are cross-process IPC and can stall for the
// duration of `AXUIElementSetMessagingTimeout` (up to ~160ms per call, more
// under retry) when the target app is slow/hung. Blocking the main actor for
// that long would freeze menu-bar UI. FocusedInsertionTargetTracker
// (main.swift) makes the same call for the same reason, wrapping its locator
// in an `actor` rather than running it on @MainActor. `captureTarget()` is
// synchronous and carries no isolation of its own, so callers are expected
// to invoke it off the main thread/actor (e.g. from a background queue or
// their own `actor`/`Task.detached`) and hop back with `await MainActor.run`
// only once they have the result, mirroring how callers of that tracker use
// it today.
final class FocusedTextTargetResolver {
    // kAXIdentifierAttribute/kAXSelectedTextAttribute aren't vended as Swift
    // constants by ApplicationServices on this toolchain; the rest of this
    // codebase hits the same gap (see `editableAttributeName` and friends in
    // FocusedInsertionTargetLocator, main.swift) and works around it with
    // raw-string CFString literals, so we follow the same pattern here.
    private let identifierAttributeName = "AXIdentifier"
    private let selectedTextAttributeName = "AXSelectedText"

    private let systemWide = AXUIElementCreateSystemWide()
    private let messagingTimeout: Float = 0.16
    private let retryDelaySeconds: TimeInterval = 0.04
    private let maxRetryAttempts = 5

    init() {
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
    }

    func captureTarget() throws -> FocusedTextTarget {
        guard AXIsProcessTrusted() else {
            throw FocusedTargetError.accessibilityPermissionMissing
        }

        let application = try copyElement(
            from: systemWide,
            attribute: kAXFocusedApplicationAttribute as CFString,
            errorBuilder: { .focusedApplicationUnavailable($0) },
            invalidTypeError: .invalidApplicationElement
        )
        AXUIElementSetMessagingTimeout(application, messagingTimeout)

        let focusedElement = try copyElementWithRetry(
            from: application,
            attribute: kAXFocusedUIElementAttribute as CFString
        )
        AXUIElementSetMessagingTimeout(focusedElement, messagingTimeout)

        var applicationPID: pid_t = 0
        var elementPID: pid_t = 0
        AXUIElementGetPid(application, &applicationPID)
        AXUIElementGetPid(focusedElement, &elementPID)

        let role = stringAttribute(focusedElement, attribute: kAXRoleAttribute as CFString)
        let subrole = stringAttribute(focusedElement, attribute: kAXSubroleAttribute as CFString)
        let runningApplication = NSRunningApplication(processIdentifier: applicationPID)

        let target = FocusedTextTarget(
            application: application,
            element: focusedElement,
            applicationPID: applicationPID,
            elementPID: elementPID,
            applicationName: runningApplication?.localizedName,
            role: role,
            subrole: subrole
        )
        logCapture(target)
        return target
    }

    private func logCapture(_ target: FocusedTextTarget) {
        let workspaceFrontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
        let description = stringAttribute(target.element, attribute: kAXDescriptionAttribute as CFString) ?? "nil"
        let identifier = stringAttribute(target.element, attribute: identifierAttributeName as CFString) ?? "nil"
        let focused = boolAttribute(target.element, attribute: kAXFocusedAttribute as CFString)
        let selectedTextSettable = isAttributeSettable(target.element, selectedTextAttributeName as CFString)
        let valueSettable = isAttributeSettable(target.element, kAXValueAttribute as CFString)
        log("""
            FocusedTextTargetResolver: workspaceFrontmost=\(workspaceFrontmost) \
            axFocusedApplication=\(target.applicationName ?? "nil") \
            axApplicationPID=\(target.applicationPID) axElementPID=\(target.elementPID) \
            role=\(target.role ?? "nil") subrole=\(target.subrole ?? "nil") \
            axDescription=\(description) axIdentifier=\(identifier) axFocused=\(String(describing: focused)) \
            selectedTextSettable=\(selectedTextSettable) valueSettable=\(valueSettable)
            """)
    }

    private func copyElement(from parent: AXUIElement, attribute: CFString,
                              errorBuilder: (AXError) -> FocusedTargetError,
                              invalidTypeError: FocusedTargetError) throws -> AXUIElement {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(parent, attribute, &value)
        guard result == .success else { throw errorBuilder(result) }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw invalidTypeError
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Retries only the AX errors that are known to be transient (the
    /// system-wide/focused-app AX round-trip can momentarily race an app's
    /// own focus-change handling). `.invalidUIElement` means the element the
    /// caller was looking at is already gone — retrying it makes no sense,
    /// it can only fail the same way again. `.attributeUnsupported` means
    /// the element will never have this attribute — also not retryable.
    ///
    /// Budget: up to `maxRetryAttempts` (5) attempts, sleeping
    /// `retryDelaySeconds` (0.04s) between them — ~160ms of sleep in the
    /// worst case, matching the "≤ ~200ms" retry budget from the bug
    /// report. Each individual `AXUIElementCopyAttributeValue` call can
    /// still block up to `messagingTimeout` (0.16s) if the target app is
    /// genuinely hung and doesn't answer at all — that's a pre-existing
    /// per-call cap set via `AXUIElementSetMessagingTimeout`, not part of
    /// the retry budget, and matches how `FocusedInsertionTargetLocator`
    /// (main.swift) treats its own `messagingTimeout`.
    private func copyElementWithRetry(from parent: AXUIElement, attribute: CFString) throws -> AXUIElement {
        var lastError: AXError = .failure
        for attempt in 0..<maxRetryAttempts {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(parent, attribute, &value)
            if result == .success {
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    throw FocusedTargetError.invalidFocusedElement
                }
                return unsafeDowncast(value, to: AXUIElement.self)
            }
            lastError = result
            switch result {
            case .cannotComplete, .noValue:
                if attempt < maxRetryAttempts - 1 {
                    Thread.sleep(forTimeInterval: retryDelaySeconds)
                }
            default:
                throw FocusedTargetError.focusedElementUnavailable(result)
            }
        }
        throw FocusedTargetError.focusedElementUnavailable(lastError)
    }

    private func stringAttribute(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? Bool
    }

    private func isAttributeSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }
}
