import AppKit
import CoreGraphics
import DisplayCore

/// The menu bar item, its menu, and the confirm-or-revert countdown.
///
/// This is the "caller" that `RevertCoordinator`'s documentation talks about:
/// nothing inside DisplayCore fires a revert on its own, so the entire safety
/// property of the app lives in `tick()` below. If that timer stops, an
/// unreadable mode stays on screen until logout.
///
/// Everything here is main-actor confined, which is also what `RevertCoordinator`
/// requires — it is explicitly not thread-safe and must be driven from a single
/// execution context.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let enumerator: DisplayEnumerating
    private let configurator: DisplayConfiguring
    private let coordinator: RevertCoordinator
    private let statusItem: NSStatusItem
    private let panel = ConfirmationPanel()
    private lazy var settings = SettingsMenu(restore: { [weak self] in self?.restoreDefaults() })

    /// The same page InOut's footer points at — one tip jar for both apps.
    private static let coffeeURL = URL(string: "https://buymeacoffee.com/benjamintan")!

    private var pending: PendingChange?
    private var ticker: Timer?

    init(
        enumerator: DisplayEnumerating = CoreGraphicsEnumerator(),
        configurator: DisplayConfiguring = CoreGraphicsConfigurator()
    ) {
        self.enumerator = enumerator
        self.configurator = configurator
        self.coordinator = RevertCoordinator(configurator: configurator, clock: SystemClock())
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "display", accessibilityDescription: "Crisp")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu construction

    /// Rebuilt every time the menu opens.
    ///
    /// This is how hot-plug is handled in this version: a display attached or
    /// removed while the menu was closed simply appears or disappears the next
    /// time it is opened, with no reconfiguration callback, no debounce, and no
    /// self-inflicted-event suppression to get wrong. A live-updating menu is a
    /// later feature; this one cannot show a stale list at the moment of use,
    /// which is the property that actually matters.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        do {
            let ids = try enumerator.onlineDisplayIDs()
            let showHeadings = MenuModel.showsHeadings(displayCount: ids.count)

            for (index, id) in ids.enumerated() {
                if index > 0 { menu.addItem(.separator()) }

                let device = try enumerator.device(for: id)
                let current = try enumerator.currentMode(for: id)
                let modes = try enumerator.modes(for: id)

                if showHeadings {
                    menu.addItem(disabledItem(device.localizedName))
                }

                // One item for the whole grid. The columns are a single view, so
                // this is the last point at which the display's rows can be
                // described as menu items at all.
                let grid = NSMenuItem()
                grid.view = ResolutionGridView(
                    groups: MenuModel.groups(for: modes, current: current),
                    pick: { [weak self] signature in
                        self?.apply(signature, on: id)
                    })
                menu.addItem(grid)
            }
        } catch {
            menu.addItem(disabledItem(ErrorText.describe(error)))
        }

        menu.addItem(.separator())

        // Restore Defaults moved into Settings. It is a rare, deliberate action,
        // and the countdown — not a menu item — is what rescues an unreadable
        // screen, so it does not need to be one click away.
        let footerView = MenuFooterView(
            target: self,
            settings: #selector(openSettings(_:)),
            coffee: #selector(openCoffee),
            quit: #selector(quit))
        let footer = NSMenuItem()
        footer.view = footerView
        menu.addItem(footer)

        // A custom view swallows ⌘Q, so the shortcut gets its own hidden item.
        let quitShortcut = NSMenuItem(title: "Quit Crisp", action: #selector(quit), keyEquivalent: "q")
        quitShortcut.target = self
        quitShortcut.isHidden = true
        menu.addItem(quitShortcut)

        // Last, once every resolution row has had its say about how wide the
        // menu is. Asking earlier would measure a menu that is still growing.
        footerView.fit(toMenuWidth: menu.size.width)
    }

    /// A label, not a command.
    ///
    /// `isEnabled = false` alone is not enough: AppKit re-enables items with no
    /// action when the menu has no delegate-driven validation, so the nil action
    /// is what actually keeps a heading unclickable.
    ///
    /// Small, semibold and uppercased — the standard macOS section-header
    /// treatment. It has to read as a label at a glance, because it sits in the
    /// same column as rows that *are* clickable.
    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        return item
    }

    /// The `NSScreen` backing a CoreGraphics display, if AppKit knows it.
    ///
    /// `NSScreenNumber` is the documented bridge between the two ID spaces. It
    /// can legitimately miss — a display that went offline between enumeration
    /// and the click — so the caller falls back to the main screen rather than
    /// treating nil as an error.
    private func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
    }

    // MARK: - Actions

    /// Apply one resolution and start the countdown.
    ///
    /// Called from a row inside the grid view rather than from a menu item's
    /// action, so there is no `sender` to unpack — the row closes the menu
    /// before calling this.
    private func apply(_ signature: ModeSignature, on displayID: CGDirectDisplayID) {
        // One change at a time. A second change begun while the first is still
        // unconfirmed would leave `pending` pointing at the newer one and strand
        // the older, whose revert nothing would ever fire.
        guard pending == nil else {
            presentAlert(
                "Finish the current change first",
                "Crisp is still waiting for you to keep or revert the last resolution.")
            return
        }

        do {
            let modes = try enumerator.modes(for: displayID)
            guard let target = modes.first(where: { $0.signature == signature }) else {
                throw DisplayError.modeUnavailable(signature)
            }
            let previous = try enumerator.currentMode(for: displayID)
            guard previous.signature != target.signature else { return }

            let change = try coordinator.begin(
                target: [displayID: target],
                previous: [displayID: previous])
            pending = change

            panel.show(
                headline: MenuModel.headline(for: target),
                secondsRemaining: coordinator.secondsRemaining(for: change),
                on: screen(for: displayID),
                onKeep: { [weak self] in self?.keep() },
                onRevert: { [weak self] in self?.revertNow() })
            startTicking()
        } catch {
            presentAlert("The resolution could not be changed", ErrorText.describe(error))
        }
    }

    @objc private func restoreDefaults() {
        do {
            try configurator.restoreDefaults()
        } catch {
            presentAlert("Restore failed", ErrorText.describe(error))
        }
    }

    /// Measure the gear now; open the dropdown once this menu has gone.
    ///
    /// `NSMenu.popUp` refuses outright while another menu is tracking — it
    /// returns false and nothing appears — and `cancelTracking` is not
    /// instantaneous, so neither calling it here nor deferring by one runloop
    /// turn is enough. `menuDidClose` is the moment AppKit says the session is
    /// over. By then the gear is gone, which is why its position is taken here.
    @objc private func openSettings(_ sender: NSButton) {
        guard let window = sender.window else { return }
        let onScreen = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        settingsAnchor = NSPoint(x: onScreen.minX, y: onScreen.minY - Self.dropdownGap)
    }

    /// Where the settings dropdown goes, set while the gear still exists and
    /// consumed when the menu around it closes.
    private var settingsAnchor: NSPoint?

    /// Breathing room between the gear and the menu that drops out of it.
    private static let dropdownGap: CGFloat = 4

    func menuDidClose(_ menu: NSMenu) {
        guard let anchor = settingsAnchor else { return }
        settingsAnchor = nil
        // Still asynchronous: this runs inside the closing menu's own teardown,
        // and a menu opened from there would be opening into the session that
        // has not quite finished ending.
        DispatchQueue.main.async { [settings] in settings.show(at: anchor) }
    }

    @objc private func openCoffee() {
        NSWorkspace.shared.open(Self.coffeeURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - The countdown

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let change = pending else {
            stopTicking()
            return
        }
        panel.update(secondsRemaining: coordinator.secondsRemaining(for: change))
        do {
            if try coordinator.expireIfNeeded(change) {
                finish()
            }
        } catch {
            // The revert failed and the deadline has passed. Nothing will retry
            // on its own, so stop pretending a countdown is still running and
            // tell the user how to recover.
            finish()
            panel.showFailure(ErrorText.revertFailure(error))
        }
    }

    private func keep() {
        guard let change = pending else { return }
        do {
            // Permanent, not session-scoped. The user has demonstrably seen the
            // screen — that is what the button means — and a resolution that
            // silently evaporated at the next logout would be a worse surprise
            // than the one this countdown exists to prevent.
            try coordinator.confirm(change, scope: .permanent)
            finish()
        } catch {
            finish()
            presentAlert("The resolution was not kept", ErrorText.describe(error))
        }
    }

    private func revertNow() {
        guard let change = pending else { return }
        do {
            try coordinator.revert(change)
            finish()
        } catch {
            finish()
            panel.showFailure(ErrorText.revertFailure(error))
        }
    }

    private func finish() {
        stopTicking()
        pending = nil
        panel.close()
    }

    private func presentAlert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
