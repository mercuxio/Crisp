import AppKit
import CoreGraphics
import DisplayCore

/// The menu bar item, the panel it drops down, and the confirm-or-revert
/// countdown.
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
final class StatusMenuController: NSObject {
    private enum Metrics {
        /// Above the picker or the grid; the grid contributes 2 more of its own,
        /// and the footer carries its bottom padding internally.
        static let topPadding: CGFloat = 4
        /// Around an error, which replaces the whole list and so has no grid
        /// beneath it to borrow margins from.
        static let messagePadding: CGFloat = 8
    }

    private let enumerator: DisplayEnumerating
    private let configurator: DisplayConfiguring
    private let coordinator: RevertCoordinator
    private let statusItem: NSStatusItem

    /// The resolution list. A window rather than a menu, which is what lets the
    /// gear open its own dropdown without this one vanishing — see `StatusPanel`.
    private let dropdown = StatusPanel()
    private let confirmation = ConfirmationPanel()
    private lazy var settings = SettingsMenu(
        restore: { [weak self] in self?.restoreDefaults() },
        arrange: { [weak self] in self?.openArrangement() })

    /// The same page InOut's footer points at — one tip jar for both apps.
    private static let coffeeURL = URL(string: "https://buymeacoffee.com/benjamintan")!

    /// System Settings' Displays pane, where the Arrange button lives.
    ///
    /// Pitch does not draw its own arrangement grid. Dragging displays around
    /// is not a resolution switcher's job, the system's version already handles
    /// mirroring and the menu bar's home along with placement, and a second
    /// version of it would be one more thing to disagree with the first.
    ///
    /// This opens the pane, not the sheet: the arrangement sheet has no URL of
    /// its own — it is a button inside the pane — and the only ways to reach it
    /// directly would be to script the click, which needs an Accessibility grant
    /// Pitch has no other reason to ask for.
    private static let arrangementURL = URL(
        string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!

    private var pending: PendingChange?
    private var ticker: Timer?

    /// The display whose resolutions the panel is showing.
    ///
    /// Remembered across openings so a user working on the external monitor
    /// does not land back on the built-in one every time. Resolved against the
    /// displays actually online each time the panel is built — see
    /// `MenuModel.selection(from:remembered:)`.
    private var selectedDisplay: CGDirectDisplayID?

    /// The last few resolutions picked on each display, newest first, kept
    /// across launches.
    ///
    /// Not keyed by `CGDirectDisplayID`: that ID is reassigned on replug
    /// (spec §9), so a file keyed on it would eventually hand one monitor's
    /// history to another. `RecentsBook` matches on the stored identity
    /// instead, and declines rather than guessing when two displays tie.
    private let recents: RecentsBook

    init(
        enumerator: DisplayEnumerating = CoreGraphicsEnumerator(),
        configurator: DisplayConfiguring = CoreGraphicsConfigurator(),
        recents: RecentsBook = RecentsBook()
    ) {
        self.enumerator = enumerator
        self.configurator = configurator
        self.recents = recents
        self.coordinator = RevertCoordinator(configurator: configurator, clock: SystemClock())
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "display", accessibilityDescription: "Pitch")
        statusItem.button?.image?.isTemplate = true
        // No `statusItem.menu`: assigning one hands the click to AppKit, which
        // opens a menu — the one thing this app can no longer use.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
    }

    // MARK: - The panel

    @objc private func toggle() {
        if dropdown.isShowing {
            dropdown.close()
            return
        }
        guard let button = statusItem.button else { return }
        dropdown.setContent(buildContent())
        dropdown.show(under: button, quit: { [weak self] in self?.quit() })
    }

    /// Rebuilt every time the panel opens.
    ///
    /// This is how hot-plug is handled in this version: a display attached or
    /// removed while the panel was closed simply appears or disappears the next
    /// time it is opened, with no reconfiguration callback, no debounce, and no
    /// self-inflicted-event suppression to get wrong. A live-updating list is a
    /// later feature; this one cannot show a stale list at the moment of use,
    /// which is the property that actually matters.
    private func buildContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        // Leading, not `.width`: stretching the grid would pull its two columns
        // apart. The views that *do* want the full width ask for it below.
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(
            top: Metrics.topPadding, left: 0, bottom: 0, right: 0)

        do {
            let ids = try enumerator.onlineDisplayIDs()
            // Nil means the list came back empty, which a Mac showing this menu
            // bar should never manage. Routed through the same catch as any
            // other failure rather than given a branch of its own.
            guard let id = MenuModel.selection(from: ids, remembered: selectedDisplay) else {
                throw DisplayError.noSuchDisplay(CGMainDisplayID())
            }
            selectedDisplay = id

            // Drawn even for a single display, where it cannot switch to
            // anything: one icon naming the screen these resolutions belong to
            // is worth more than the two points of height it costs, and a panel
            // that grows a header the moment a monitor is plugged in reads as a
            // different panel.
            // Asked once for the whole header rather than per icon: it walks
            // every attached screen, and the answer cannot change midway
            // through building one panel.
            let names = DisplayNames.system()

            Self.addFullWidth(
                DisplayPickerView(
                    items: try ids.map { id in
                        DisplayPickerView.Item(
                            id: id,
                            // The positional label is the fallback, not the
                            // answer — see `DisplayNames`.
                            name: try names[id] ?? enumerator.device(for: id).localizedName)
                    },
                    selected: id,
                    pick: { [weak self] picked in self?.select(picked) }),
                to: stack)
            Self.addFullWidth(Self.separator(), to: stack)

            let current = try enumerator.currentMode(for: id)
            let modes = try enumerator.modes(for: id)

            stack.addArrangedSubview(
                ResolutionGridView(
                    groups: MenuModel.groups(
                        for: modes, current: current, recents: recents.recents(for: id)),
                    pick: { [weak self] signature in
                        // Closed first: the countdown opens from `apply`, and
                        // this panel floats above it otherwise.
                        self?.dropdown.close()
                        self?.apply(signature, on: id)
                    }))
        } catch {
            stack.addArrangedSubview(Self.message(ErrorText.describe(error)))
        }

        Self.addFullWidth(Self.separator(), to: stack)

        // Restore Defaults lives in Settings. It is a rare, deliberate action,
        // and the countdown — not a list item — is what rescues an unreadable
        // screen, so it does not need to be one click away.
        Self.addFullWidth(
            MenuFooterView(
                target: self,
                settings: #selector(openSettings(_:)),
                coffee: #selector(openCoffee),
                quit: #selector(quit)),
            to: stack)

        return stack
    }

    /// Add a view that should span the panel rather than hug its own content.
    ///
    /// A separator that stopped short of the edges would read as a stray line,
    /// and the footer cannot push quit out to the right margin without knowing
    /// where that margin is.
    private static func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private static func separator() -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        // A horizontal separator has no intrinsic height, so without this it
        // collapses to an invisible zero-height line.
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }

    /// Switch the panel to another display, in place.
    ///
    /// The panel stays open and simply rebuilds around the new list, which is
    /// why `setContent` pins its top-left: two displays rarely offer the same
    /// number of modes, so the panel changes height under a pointer that is
    /// still resting on the icon that was just clicked.
    private func select(_ id: CGDirectDisplayID) {
        guard id != selectedDisplay else { return }
        selectedDisplay = id
        dropdown.setContent(buildContent())
    }

    /// Shown in place of the list when the displays cannot be read at all.
    private static func message(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .menuFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 240
        return inset(label, top: Metrics.messagePadding, bottom: Metrics.messagePadding)
    }

    /// Indent a label to where the resolutions start, and give it room above and
    /// below.
    ///
    /// The leading inset comes from the grid so the two cannot drift apart: a
    /// heading that does not line up with the rows under it reads as a mistake
    /// rather than as a heading.
    private static func inset(_ label: NSView, top: CGFloat, bottom: CGFloat) -> NSView {
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: ResolutionGridView.contentInset),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor,
                constant: -ResolutionGridView.contentInset),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: top),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -bottom),
        ])
        return container
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
    /// Called from a row inside the grid rather than from a control with a
    /// sender, so there is nothing to unpack — and the row has already closed
    /// the panel by the time this runs.
    private func apply(_ signature: ModeSignature, on displayID: CGDirectDisplayID) {
        // One change at a time. A second change begun while the first is still
        // unconfirmed would leave `pending` pointing at the newer one and strand
        // the older, whose revert nothing would ever fire.
        guard pending == nil else {
            presentAlert(
                "Finish the current change first",
                "Pitch is still waiting for you to keep or revert the last resolution.")
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

            // Recorded on selection, not on keep. A resolution you tried and
            // reverted is still one you went looking for, and the dots are for
            // finding a row again — not a record of what you settled on, which
            // is what the checkmark is for.
            recents.record(
                target.signature, for: displayID,
                // Only ever read by a human opening the file, so the
                // enumerator's own name is enough — no need for the header's
                // richer lookup.
                name: (try? enumerator.device(for: displayID).localizedName) ?? "")

            confirmation.show(
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

    /// The panel deliberately stays open behind this.
    ///
    /// It is the whole reason the resolution list is a window: a menu opened
    /// during another menu's tracking session never appears — `popUp` returns
    /// false and nothing happens — so the list used to have to tear itself down
    /// before the gear could show anything. Anchored to a plain view in a plain
    /// window, this is just a menu, and the list underneath is undisturbed.
    @objc private func openSettings(_ sender: NSButton) {
        // Asked at open time rather than remembered: a display can be plugged in
        // while the panel is sitting there, and the menu is rebuilt per click
        // anyway. A failed enumeration reports one display, which hides the
        // arrangement item — the safe way to be wrong, since the alternative is
        // an item that opens a pane with nothing to arrange.
        settings.show(
            from: sender, displayCount: (try? enumerator.onlineDisplayIDs().count) ?? 1)
    }

    /// - Note: the panel closes first for the same reason it does for coffee —
    ///   it floats at `.popUpMenu` level and would sit on top of the window it
    ///   just asked for.
    private func openArrangement() {
        dropdown.close()
        guard !NSWorkspace.shared.open(Self.arrangementURL) else { return }
        // The pane identifier is Apple's and could be renamed in some future
        // release. Landing the user in System Settings with a pane to pick is a
        // poor outcome; silently doing nothing is a worse one.
        if let settingsApp = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences")
        {
            NSWorkspace.shared.openApplication(
                at: settingsApp, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func openCoffee() {
        // The browser is about to come forward, and a panel left floating at
        // `.popUpMenu` level would sit on top of it.
        dropdown.close()
        NSWorkspace.shared.open(Self.coffeeURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - The countdown

    /// - Note: `.common`, not the `.default` mode `Timer.scheduledTimer`
    ///   installs into. A default-mode timer stops firing for as long as the
    ///   run loop is in `.eventTracking` — while a menu is held open, or while
    ///   the confirmation panel is being dragged, which it can be
    ///   (`isMovableByWindowBackground`). That would freeze the visible
    ///   countdown *and* the revert it is counting down to, which is the one
    ///   thing this class exists to guarantee.
    private func startTicking() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
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
        confirmation.update(secondsRemaining: coordinator.secondsRemaining(for: change))
        do {
            if try coordinator.expireIfNeeded(change) {
                finish()
            }
        } catch {
            // The revert failed and the deadline has passed. Nothing will retry
            // on its own, so stop pretending a countdown is still running and
            // tell the user how to recover.
            finish()
            confirmation.showFailure(ErrorText.revertFailure(error))
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
            // The user asked to keep it and the system refused — most often
            // because the click landed a hair past the deadline. `finish()`
            // stops the countdown, so after this nothing will ever revert on
            // its own: the safe resting state is the mode they came from, not
            // the one they just failed to keep. `displayctl set` does exactly
            // this in the same situation, and `revert` is still available
            // because `confirm` only marks a change resolved once it succeeds.
            let confirmFailure = error
            do {
                try coordinator.revert(change)
                finish()
                presentAlert(
                    "The resolution was not kept", ErrorText.describe(confirmFailure))
            } catch {
                finish()
                confirmation.showFailure(ErrorText.revertFailure(error))
            }
        }
    }

    private func revertNow() {
        guard let change = pending else { return }
        do {
            try coordinator.revert(change)
            finish()
        } catch {
            finish()
            confirmation.showFailure(ErrorText.revertFailure(error))
        }
    }

    private func finish() {
        stopTicking()
        pending = nil
        confirmation.close()
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
