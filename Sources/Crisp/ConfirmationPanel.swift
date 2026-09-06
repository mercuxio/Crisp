import AppKit

/// The panel that stands between a mode change and keeping it.
///
/// It holds no timer and makes no decision. `StatusMenuController` drives the
/// countdown and owns the revert, exactly as `RevertCoordinator` expects — this
/// type only draws what it is told and reports which button was pressed.
///
/// The default button is **Revert**, and Return triggers it. This is deliberate
/// and mirrors both macOS's own resolution dialog and the `displayctl` prompt:
/// a keystroke made blind, by someone who cannot read the screen they just
/// changed, must never be the keystroke that keeps the change. Keeping requires
/// a deliberate click or ⌘K.
@MainActor
final class ConfirmationPanel {
    private enum Metrics {
        /// Standard macOS alert margins, so the panel sits correctly next to
        /// system dialogs rather than looking like a debug window.
        static let margin: CGFloat = 20
        static let width: CGFloat = 400
        static let height: CGFloat = 176
    }

    private let panel: NSPanel
    private let headline = NSTextField(labelWithString: "")
    private let countdown = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var onKeep: (() -> Void)?
    private var onRevert: (() -> Void)?
    private var totalSeconds = 1

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: Metrics.height),
            // No close button: the only ways out are Keep, Revert, or letting
            // the countdown finish. A dismissable panel would strand a pending
            // change with its countdown invisible.
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        panel.title = "Crisp"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true

        headline.font = .systemFont(ofSize: 13, weight: .semibold)
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 2
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countdown.font = .systemFont(ofSize: 11)
        countdown.textColor = .secondaryLabelColor
        countdown.lineBreakMode = .byWordWrapping
        countdown.maximumNumberOfLines = 2

        progress.isIndeterminate = false
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let keep = NSButton(title: "Keep", target: self, action: #selector(keepPressed))
        keep.bezelStyle = .rounded
        keep.keyEquivalent = "k"
        keep.keyEquivalentModifierMask = [.command]

        let revert = NSButton(title: "Revert", target: self, action: #selector(revertPressed))
        revert.bezelStyle = .rounded
        // Return reverts. See the type comment: the blind keystroke must be the
        // safe one. This also gives Revert the default-button styling, which is
        // the correct visual emphasis for the safe choice.
        revert.keyEquivalent = "\r"

        // Buttons sit bottom-trailing with the default rightmost — the macOS
        // convention, and the reason this is a constraint-based layout rather
        // than one stack pinned to every edge.
        let buttons = NSStackView(views: [keep, revert])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let text = NSStackView(views: [headline, countdown, progress])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8

        let content = NSView()
        for view in [icon, text, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: Metrics.margin),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.margin),
            icon.widthAnchor.constraint(equalToConstant: 32),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Metrics.margin),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: Metrics.margin),

            progress.widthAnchor.constraint(equalTo: text.widthAnchor),

            buttons.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -Metrics.margin),
            buttons.bottomAnchor.constraint(
                equalTo: content.bottomAnchor, constant: -Metrics.margin),
            buttons.topAnchor.constraint(
                greaterThanOrEqualTo: text.bottomAnchor, constant: 18),
        ])
        panel.contentView = content
    }

    /// - Parameter screen: the display whose mode just changed. The panel must
    ///   open there: on a two-screen setup, a confirmation shown on the screen
    ///   that still works is useless for judging the one that may not.
    func show(
        headline text: String,
        secondsRemaining: Int,
        on screen: NSScreen?,
        onKeep: @escaping () -> Void,
        onRevert: @escaping () -> Void
    ) {
        self.onKeep = onKeep
        self.onRevert = onRevert
        totalSeconds = max(1, secondsRemaining)
        headline.stringValue = text
        progress.maxValue = Double(totalSeconds)
        update(secondsRemaining: secondsRemaining)
        position(on: screen)
        // A menu bar agent has no dock icon and is not the active app, so the
        // panel would otherwise open behind whatever the user was looking at —
        // the one window that must never be missed.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func update(secondsRemaining: Int) {
        let unit = secondsRemaining == 1 ? "second" : "seconds"
        countdown.stringValue =
            "Reverting in \(secondsRemaining) \(unit) unless you keep it."
        progress.doubleValue = Double(secondsRemaining)
    }

    func close() {
        onKeep = nil
        onRevert = nil
        panel.orderOut(nil)
    }

    /// Shown when a revert itself fails — the screen is stuck on the new mode
    /// and the user needs to be told what to do about it, not shown an error
    /// code. Mirrors `displayctl`'s recovery message.
    func showFailure(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Crisp could not restore the previous mode"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Centred horizontally, and high on the screen rather than dead centre —
    /// a panel in the vertical middle of a screen that just changed resolution
    /// is the hardest place to find it.
    private func position(on screen: NSScreen?) {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - frame.height * 0.18))
    }

    @objc private func keepPressed() {
        let action = onKeep
        close()
        action?()
    }

    @objc private func revertPressed() {
        let action = onRevert
        close()
        action?()
    }
}
