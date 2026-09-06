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
    /// - Parameter topLeft: where the dropdown's top-left corner goes, in
    ///   screen coordinates. The caller measures the gear before closing the
    ///   menu around it; by the time this runs there is no view left to
    ///   anchor to.
    func show(at topLeft: NSPoint) {
        let menu = NSMenu()

        let launch = NSMenuItem(
            title: "Start at Login", action: #selector(toggleLaunch), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        // Approval is the system's to give; clicking again cannot grant it.
        launch.isEnabled = LaunchAtLogin.status != .requiresApproval
        menu.addItem(launch)

        if let note = LaunchAtLogin.note {
            menu.addItem(Self.note(note))
        }

        menu.addItem(.separator())

        let restoreItem = NSMenuItem(
            title: "Restore Defaults", action: #selector(restorePressed), keyEquivalent: "")
        restoreItem.target = self
        menu.addItem(restoreItem)
        menu.addItem(
            Self.note("Returns every display to the resolution macOS chose for it."))

        menu.addItem(.separator())

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        menu.addItem(Self.note("Crisp \(version as? String ?? "—")"))

        // A nil view means `topLeft` is read in screen coordinates, which is the
        // whole reason the caller measured it: `popUp` refuses outright — it
        // returns false and nothing appears — while another menu is still
        // tracking, so the gear's menu has to close before this one can open,
        // and by then the gear itself is gone.
        menu.popUp(positioning: nil, at: topLeft, in: nil)
    }

    /// A line of explanation, not a command.
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
