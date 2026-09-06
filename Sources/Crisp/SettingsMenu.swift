import AppKit

/// The gear's dropdown.
///
/// Crisp has two settings, which is not a window's worth. A dropdown keeps them
/// where the click already is — the same shape InOut's gear uses — and costs the
/// user no context switch to a separate dialog and back.
@MainActor
final class SettingsMenu: NSObject {
    private let restore: () -> Void

    /// - Parameter restore: runs `Restore Defaults`. Injected rather than
    ///   reached for, so this menu never touches a display itself — the
    ///   controller owns every write to the hardware.
    init(restore: @escaping () -> Void) {
        self.restore = restore
    }

    /// Built fresh on every click, because `LaunchAtLogin` is read from the
    /// system rather than remembered and its answer can change between opens.
    ///
    /// - Parameter gear: the button this drops out of. It stays on screen, and
    ///   so does the panel behind it — see `StatusMenuController.openSettings`.
    func show(from gear: NSView) {
        let menu = NSMenu()

        let launch = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        // Approval is the system's to give; clicking again cannot grant it.
        launch.isEnabled = LaunchAtLogin.status != .requiresApproval
        // The explanation lives in a tooltip rather than a line of its own: a
        // disabled toggle with no reason is a dead end, but a permanent caption
        // under a two-item menu is clutter for the case that never needs it.
        launch.toolTip = LaunchAtLogin.note
        menu.addItem(launch)

        let restoreItem = NSMenuItem(
            title: "Restore Defaults", action: #selector(restorePressed), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        menu.addItem(Self.note("Crisp \(version as? String ?? "—")"))

        // The point is in the gear's own coordinates, and a view's origin is its
        // bottom-left, so a small negative y puts the menu's top-left just under
        // the glyph.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.gap), in: gear)
    }

    /// Breathing room between the gear and the menu that drops out of it.
    private static let gap: CGFloat = 4

    /// The version line at the bottom: information, not a command.
    ///
    /// `isEnabled = false` alone is not enough: AppKit re-enables items that have
    /// no action, so the nil action is what actually keeps this unclickable.
    private static func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        return item
    }

    @objc private func toggleLaunch() {
        let wanted = !LaunchAtLogin.isEnabled
        do {
            try LaunchAtLogin.set(wanted)
        } catch {
            // The next open re-reads the system, so the toggle corrects itself.
            // Saying nothing would be the worst outcome: the user would believe
            // Crisp will start at login when it will not.
            let alert = NSAlert()
            alert.messageText = wanted
                ? "Crisp could not be set to start at login"
                : "Crisp could not be removed from login items"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func restorePressed() {
        restore()
    }
}
