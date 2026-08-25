// SuperDictate — small color-coded state toast for restart-free mode
// switches (correction on/off, rewrite on/off, rewrite style change),
// triggered from the global hotkeys. Purely informational: no buttons, no
// event taps, no key focus — appears, holds ~2 s, fades out.
//
// Visual language mirrors VocabularyLearnedToastController (same panel
// geometry, HUD palette, positioning and entry/exit animations) with one
// addition: tone-based color coding (see StateToastTone).

import AppKit
import CoreGraphics
import Foundation

/// Color coding of the state toast (docs/specs/state-toasts-rewrite-hotkeys-spec.md §1):
/// `.on` — green (feature enabled), `.off` — neutral gray (feature
/// disabled), `.style` — the rewrite style's OWN color, so the active
/// mode is recognizable at a glance (polish=teal, task=orange,
/// official=indigo).
enum StateToastTone {
    case on
    case off
    case style(RewriteStyle)
    /// User-created mode: carries its own identity color (hex).
    case custom(hex: String)

    /// Convenience: tone for a unified style selection.
    static func selection(_ sel: RewriteStyleSelection) -> StateToastTone {
        switch sel {
        case .builtin(let style): return .style(style)
        case .custom(let custom): return .custom(hex: custom.colorHex)
        }
    }
}

/// Per-style identity colors — the whole point is that the user learns
/// «teal = Причесать, orange = Задача, indigo = Официальный» and never
/// has to read the toast to know the mode.
@MainActor
func stateToastColor(for style: RewriteStyle) -> NSColor {
    switch style {
    case .polish: return .systemTeal
    case .structuredTask: return .systemOrange
    case .official: return .systemIndigo
    }
}

@MainActor
final class StateToastController {
    private static let autoDismissSeconds: TimeInterval = 2
    private static let pillHeight: CGFloat = 44
    private static let horizontalPadding: CGFloat = 24
    private static let minPillWidth: CGFloat = 160
    private static let entryExitScale: CGFloat = 0.85

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(text: String, tone: StateToastTone, targetFrame: NSRect? = nil) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let panel = Self.makePanel()
        let lightBackground = Self.shouldUseLightBackground()
        let statusColor: NSColor
        switch tone {
        case .on: statusColor = .systemGreen
        case .off: statusColor = NSColor.systemGray
        case .style(let style): statusColor = stateToastColor(for: style)
        case .custom(let hex):
            statusColor = Self.nsColor(fromHex: hex)
                ?? Settings.shared.recordingHUDRecordingColor.resolvedColor(lightBackground: lightBackground)
        }

        // Text: the status word carries the tone color, the rest stays in
        // the base text color — «Коррекция · <вкл>».
        let baseColor: NSColor = lightBackground
            ? NSColor(calibratedWhite: 0.0, alpha: 0.85)
            : NSColor(calibratedWhite: 1.0, alpha: 0.92)
        let font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let separator = " · "
        let attributed = NSMutableAttributedString()
        if let range = text.range(of: separator) {
            let head = String(text[text.startIndex..<range.lowerBound])
            let tail = String(text[range.upperBound...])
            attributed.append(NSAttributedString(string: head, attributes: [
                .font: font, .foregroundColor: baseColor,
            ]))
            attributed.append(NSAttributedString(string: separator, attributes: [
                .font: font, .foregroundColor: baseColor.withAlphaComponent(0.5),
            ]))
            attributed.append(NSAttributedString(string: tail, attributes: [
                .font: font, .foregroundColor: statusColor,
            ]))
        } else {
            attributed.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: statusColor,
            ]))
        }

        let label = NSTextField(labelWithAttributedString: attributed)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let measuredWidth = attributed.size().width + (Self.horizontalPadding * 2)
        let pillWidth = min(max(measuredWidth, Self.minPillWidth), 480)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: Self.pillHeight))
        container.wantsLayer = true
        let palette = Self.backgroundPalette(lightBackground: lightBackground)
        container.layer?.backgroundColor = palette.fill.cgColor
        container.layer?.cornerRadius = Self.pillHeight / 2
        container.layer?.borderWidth = 1.5
        container.layer?.borderColor = statusColor.withAlphaComponent(0.65).cgColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Self.horizontalPadding),
        ])

        panel.setContentSize(container.frame.size)
        panel.contentView = container
        if let targetFrame, let screen = Self.screenFor(point: NSPoint(x: targetFrame.midX, y: targetFrame.midY)) {
            Self.positionAboveTarget(panel, targetFrame: targetFrame, screen: screen)
        } else {
            Self.positionBottomRight(panel, width: pillWidth)
        }

        if let layer = container.layer {
            let bounds = layer.bounds
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        panel.alphaValue = 0
        container.layer?.setAffineTransform(CGAffineTransform(scaleX: Self.entryExitScale, y: Self.entryExitScale))
        panel.invalidateShadow()
        panel.orderFrontRegardless()
        self.panel = panel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        let scaleIn = CABasicAnimation(keyPath: "transform")
        scaleIn.fromValue = CATransform3DMakeScale(Self.entryExitScale, Self.entryExitScale, 1)
        scaleIn.toValue = CATransform3DIdentity
        scaleIn.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
        scaleIn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scaleIn.fillMode = .forwards
        scaleIn.isRemovedOnCompletion = false
        container.layer?.add(scaleIn, forKey: "stateToastScaleIn")
        container.layer?.setAffineTransform(.identity)

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard let panel else { return }
        dismissTask?.cancel()
        dismissTask = nil
        self.panel = nil
        let content = panel.contentView
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        content?.layer?.removeAnimation(forKey: "stateToastScaleIn")
        let scaleOut = CABasicAnimation(keyPath: "transform")
        scaleOut.fromValue = CATransform3DIdentity
        scaleOut.toValue = CATransform3DMakeScale(Self.entryExitScale, Self.entryExitScale, 1)
        scaleOut.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
        scaleOut.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scaleOut.fillMode = .forwards
        scaleOut.isRemovedOnCompletion = false
        content?.layer?.add(scaleOut, forKey: "stateToastScaleOut")
        content?.layer?.setAffineTransform(CGAffineTransform(scaleX: Self.entryExitScale, y: Self.entryExitScale))
    }

    /// Static resolver for UI swatches outside this controller (the
    /// custom-modes management rows).
    static func color(forColorHex hex: String) -> NSColor {
        nsColor(fromHex: hex) ?? .systemTeal
    }

    /// Parses "#RRGGBB" (the CustomRewriteStyle.colorHex format); returns
    /// nil for malformed values so the caller can fall back to the accent.
    private static func nsColor(fromHex hex: String) -> NSColor? {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else { return nil }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0,
                       alpha: 1)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: minPillWidth, height: pillHeight),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func backgroundPalette(lightBackground: Bool) -> (fill: NSColor, stroke: NSColor) {
        if lightBackground {
            return (
                NSColor(calibratedWhite: 1.0, alpha: 0.84),
                NSColor(calibratedWhite: 0.0, alpha: 0.14)
            )
        }
        return (
            NSColor(calibratedWhite: 0.0, alpha: 0.96),
            NSColor(calibratedWhite: 0.22, alpha: 0.26)
        )
    }

    private static func positionBottomRight(_ panel: NSPanel, width: CGFloat) {
        guard let screenFrame = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: screenFrame.maxX - width - 24,
            y: screenFrame.minY + 24
        )
        panel.setFrameOrigin(origin)
    }

    /// Positions the panel just above `targetFrame` (the field the user is
    /// typing in), falling back to below it if there isn't room above,
    /// clamped to the target's screen's visible frame — same mechanism as
    /// VocabularyLearnedToastController.positionAboveTarget.
    private static func positionAboveTarget(_ panel: NSPanel, targetFrame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        let size = panel.frame.size
        let preferredX = targetFrame.minX
        let preferredY = targetFrame.maxY + gap
        let fallbackY = targetFrame.minY - gap - size.height
        let y = preferredY + size.height <= visible.maxY - 8 ? preferredY : fallbackY
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let clampedY = min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    private static func screenFor(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func shouldUseLightBackground() -> Bool {
        switch Settings.shared.recordingHUDBackgroundStyle {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return appearance == .aqua
        }
    }
}
