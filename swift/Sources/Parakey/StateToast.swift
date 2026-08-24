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
/// disabled), `.neutral` — HUD accent color (mode/informational).
enum StateToastTone {
    case on
    case off
    case neutral
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

    func show(text: String, tone: StateToastTone) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let panel = Self.makePanel()
        let lightBackground = Self.shouldUseLightBackground()
        let accentColor = Settings.shared.recordingHUDRecordingColor.resolvedColor(lightBackground: lightBackground)
        let statusColor: NSColor
        switch tone {
        case .on: statusColor = .systemGreen
        case .off: statusColor = NSColor.systemGray
        case .neutral: statusColor = accentColor
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
        Self.positionBottomRight(panel, width: pillWidth)

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
