import AppKit

/// The window the status item drops down, in place of a menu.
///
/// Not an `NSMenu`, and that is the entire point. AppKit refuses to open a
/// second menu while one is tracking — `popUp` returns false and nothing
/// appears — so the gear's settings dropdown could never show without first
/// tearing the resolution list down around it. A panel runs no tracking
/// session, so a menu opened from inside it behaves like a menu opened from
/// any other window, and the list stays put underneath. It is also what InOut
/// does: its panel is a window (`MenuBarExtra` with `menuBarExtraStyle(.window)`),
/// which is why its own gear dropdown never had this problem.
///
/// Everything `NSMenu` used to provide is now this class's job: appearing in
/// the right place under the status item, and going away again when the user
/// looks elsewhere.
///
/// Unlike `ConfirmationPanel`, which wraps an `NSPanel`, this subclasses one —
/// a borderless window cannot take the keyboard without overriding
/// `canBecomeKey`, and without the keyboard there is no Escape and no ⌘Q.
@MainActor
final class StatusPanel: NSPanel {
    private enum Metrics {
        /// Matches the corner radius macOS gives its own menus.
        static let corner: CGFloat = 10
        /// Clearance below the menu bar, the same a menu leaves.
        static let gap: CGFloat = 6
        /// How close to the edge of the screen the panel may sit.
        static let screenMargin: CGFloat = 8
    }

    private var outsideClicks: Any?
    private var keys: Any?

    /// The status item this is hanging off, kept so the dismiss monitor can
    /// recognise a click on it. See `startWatching(quit:)`.
    private weak var anchor: NSStatusBarButton?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            // Borderless because the rounded, vibrant background below is the
            // entire chrome; a title bar would draw a second one around it.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        isReleasedWhenClosed = false
        // Dismissal is decided deliberately below, not by whether the app
        // happens to still be frontmost — a settings menu opening on top of
        // this panel must not take it away.
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Otherwise it turns up in Mission Control and in the window list of an
        // app that is not supposed to have windows at all.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        // `.followsWindowActiveState` would grey the whole panel out the moment
        // a menu opened on top of it — which is now a supported thing to do.
        background.state = .active
        // Both, and they do different jobs: the mask rounds the blurred
        // backdrop, the layer rounds everything drawn on top of it.
        background.maskImage = Self.roundedMask(radius: Metrics.corner)
        background.wantsLayer = true
        background.layer?.cornerRadius = Metrics.corner
        background.layer?.masksToBounds = true
        contentView = background
    }

    /// A resizable rounded rectangle, stretched over the vibrant background.
    ///
    /// A layer `cornerRadius` rounds what the effect view *draws*, and nothing
    /// else. The blur behind it is the window server's, cut to the window's
    /// shape — still square — so the bright desktop showing through it appeared
    /// as a hard white corner sitting just outside the curve. `maskImage` is the
    /// one knob AppKit forwards to that backdrop.
    ///
    /// The cap insets leave the four corners intact and stretch only the single
    /// middle pixel, so one small image fits a panel of any size.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(
            size: NSSize(width: edge, height: edge),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Borderless windows refuse key status unless asked for it.
    override var canBecomeKey: Bool { true }

    /// Replace the contents and resize around them.
    ///
    /// The panel is exactly as big as what it holds — no scroll view, no fixed
    /// height — so a display offering forty modes simply makes a taller panel,
    /// the same way the menu used to grow.
    ///
    /// Called while the panel is open too, when the monitor picker switches to
    /// another display. A window grows from its bottom-left origin, so a taller
    /// panel would otherwise push its own header up under the menu bar and out
    /// from under the pointer. Pinning the top-left instead keeps the picker
    /// exactly where the click left it and lets the list below it lengthen.
    func setContent(_ view: NSView) {
        guard let background = contentView else { return }
        let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
        background.subviews.forEach { $0.removeFromSuperview() }

        view.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            view.topAnchor.constraint(equalTo: background.topAnchor),
            view.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        background.layoutSubtreeIfNeeded()
        setContentSize(view.fittingSize)
        if isVisible { setFrameTopLeftPoint(topLeft) }
    }

    var isShowing: Bool { isVisible }

    /// Show the panel hanging off `button`, and start watching for whatever
    /// should take it away again.
    ///
    /// - Parameter quit: what ⌘Q does here. An `LSUIElement` app has no menu
    ///   bar to hang the shortcut on, so the panel carries it — the same reason
    ///   the menu used to carry a hidden Quit item.
    func show(under button: NSStatusBarButton, quit: @escaping () -> Void) {
        guard let buttonWindow = button.window else { return }
        self.anchor = button
        let frame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        setFrameTopLeftPoint(origin(under: frame, on: buttonWindow.screen))

        // Activating is what lets the panel take a keypress at all, and it is
        // what InOut's window-style menu bar extra does too.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        startWatching(quit: quit)
    }

    override func close() {
        stopWatching()
        super.close()
    }

    /// Centred under the status item, then pulled back inside the screen.
    ///
    /// Status items live at the right-hand end of the menu bar, so a wide panel
    /// centred on one would otherwise hang off the side of the display.
    private func origin(under anchor: NSRect, on screen: NSScreen?) -> NSPoint {
        let width = frame.width
        var x = anchor.midX - width / 2
        let y = anchor.minY - Metrics.gap

        if let visible = screen?.visibleFrame {
            let leftmost = visible.minX + Metrics.screenMargin
            let rightmost = visible.maxX - Metrics.screenMargin - width
            x = min(max(x, leftmost), max(leftmost, rightmost))
        }
        return NSPoint(x: x, y: y)
    }

    /// - Note: the mouse monitor is deliberately *global*, which is to say it
    ///   sees only clicks delivered to other applications. A local monitor would
    ///   also catch clicks inside Crisp's own settings dropdown and close the
    ///   panel out from under it — the exact behaviour this class exists to fix.
    ///
    ///   The status item is the one thing the monitor must not act on, because
    ///   the menu bar delivers those clicks somewhere this monitor can still
    ///   see. Closing here would race the button's own action: the panel would
    ///   shut, `toggle` would then find nothing showing and open it again, and a
    ///   second click on the icon would appear to do nothing at all.
    private func startWatching(quit: @escaping () -> Void) {
        stopWatching()

        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            let location = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, !self.anchorFrame().contains(location) else { return }
                self.close()
            }
        }

        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Classified out here rather than inside `assumeIsolated`, which can
            // only hand back a `Sendable` value — and an `NSEvent` is not one.
            let isEscape = event.keyCode == 53
            let isQuit =
                event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "q"
            guard isEscape || isQuit else { return event }

            MainActor.assumeIsolated {
                if isEscape {
                    self?.close()
                } else {
                    quit()
                }
            }
            return nil
        }
    }

    /// The status item's rectangle in screen coordinates, or an empty one when
    /// there is no status item to speak of — which contains no point, so the
    /// monitor falls through to closing as usual.
    private func anchorFrame() -> NSRect {
        guard let anchor, let window = anchor.window else { return .zero }
        return window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
    }

    private func stopWatching() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        if let keys { NSEvent.removeMonitor(keys) }
        outsideClicks = nil
        keys = nil
    }
}
