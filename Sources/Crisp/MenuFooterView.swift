import AppKit

/// The icon row at the bottom of the menu.
///
/// Laid out to match InOut's footer: settings and coffee on the left, quit
/// pushed to the right. Two apps in the same menu bar that look like siblings
/// is worth more than either arrangement on its own merits.
///
/// A custom view, not menu items, because these are chrome rather than choices
/// in the same list as the resolutions. The cost is that AppKit stops doing
/// anything for you inside it — no highlight, no keyboard traversal — which is
/// why the buttons below track the mouse themselves.
@MainActor
final class MenuFooterView: NSView {
    private enum Metrics {
        /// Glyph, plus its slop on both sides, plus InOut's 5pt vertical
        /// padding on both sides.
        static let height: CGFloat = 31
        /// InOut pads its footer by 10 and every control carries 4pt of
        /// invisible hit slop inside that, so the *visible* glyph sits 14 from
        /// the edge. Reproduced here as a visible inset, with the slop
        /// subtracted back off when the frames are placed.
        static let visibleInset: CGFloat = 14
        static let spacing: CGFloat = 2
        static let glyph: CGFloat = 13
        static let hitSlop: CGFloat = 4
        /// `NSMenu.size` reports content width, stopping short of the menu's own
        /// trailing margin — measured against the separator above the footer,
        /// that margin is about this wide.
        static let trailingMargin: CGFloat = 12
    }

    init(target: AnyObject, settings: Selector, coffee: Selector, quit: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: Metrics.height))

        // Settings is an SF Symbol in InOut too — only the coffee and quit
        // glyphs are Lucide. Copying that mix rather than "correcting" it is
        // what keeps the two footers identical.
        let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")?
            .withSymbolConfiguration(.init(pointSize: Metrics.glyph, weight: .regular))

        let leading = NSStackView(views: [
            Self.button(
                image: gear, tooltip: "Settings", target: target, action: settings),
            Self.button(
                image: LucideIcon.coffee.image(size: Metrics.glyph),
                tooltip: "Buy me a coffee", target: target, action: coffee),
        ])
        leading.orientation = .horizontal
        leading.spacing = Metrics.spacing

        let quitButton = Self.button(
            image: LucideIcon.logOut.image(size: Metrics.glyph),
            tooltip: "Quit Crisp", target: target, action: quit)

        for view in [leading, quitButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.visibleInset - Metrics.hitSlop),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Pinned to this view's trailing edge, so widening the view in
            // `fit(toMenuWidth:)` is all it takes to push quit out to the
            // menu's right margin — landing the glyph the same 14 from that
            // edge as the gear is from the left.
            quitButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -(Metrics.visibleInset - Metrics.hitSlop)),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Called after every item has been added, when `NSMenu.size` is finally
    /// meaningful. Doing this inside `layout()` instead would feed the new width
    /// back into the menu's own sizing pass and grow the menu on every open.
    func fit(toMenuWidth width: CGFloat) {
        guard width > 0 else { return }
        setFrameSize(NSSize(width: width + Metrics.trailingMargin, height: Metrics.height))
    }

    private static func button(
        image: NSImage?, tooltip: String, target: AnyObject, action: Selector
    ) -> NSButton {
        let button = FooterButton()
        button.image = image
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.target = target
        button.action = action
        button.toolTip = tooltip
        // The icon has no label, so this is the only thing VoiceOver can read.
        button.setAccessibilityLabel(tooltip)
        button.contentTintColor = .secondaryLabelColor

        // Glyph plus InOut's 4pt of hit slop on every side: a stroked 13pt icon
        // is a hairline target otherwise.
        let side = Metrics.glyph + Metrics.hitSlop * 2
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
        return button
    }
}

/// A borderless icon button that lights up under the pointer.
///
/// Inside a menu's custom view there is no highlight for free, and an icon that
/// never reacts reads as decoration rather than a control.
private final class FooterButton: NSButton {
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .secondaryLabelColor
    }

    /// Deliberately empty, and the reason this button works at all.
    ///
    /// `NSButton.mouseDown` hands off to the cell, which runs its *own* nested
    /// event loop until the mouse comes back up. Inside a menu that loop never
    /// ends: the menu is already draining the event queue, so the mouse-up is
    /// consumed elsewhere and `mouseUp` below is never reached — the button
    /// highlights on hover and then does nothing when clicked. Swallowing the
    /// mouse-down keeps the click in this view's own hands.
    override func mouseDown(with event: NSEvent) {}

    /// Clicking an item inside a menu does not close the menu on its own the way
    /// a real menu item does, and leaving it open behind a browser tab looks
    /// broken.
    ///
    /// The action is sent first, so a button that opens something of its own
    /// still has a live menu window to measure against before anything here
    /// tears the menu down around it.
    override func mouseUp(with event: NSEvent) {
        // A press that wandered off the glyph before releasing is a cancelled
        // click, the same as anywhere else in the system.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        sendAction(action, to: target)
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
