import AppKit

/// The icon row at the bottom of the panel.
///
/// Laid out to match InOut's footer: settings and coffee on the left, quit
/// pushed to the right. Two apps in the same menu bar that look like siblings
/// is worth more than either arrangement on its own merits.
///
/// These are chrome rather than choices in the same list as the resolutions,
/// which is why they are icons in a row instead of rows in the list.
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
    }

    init(target: AnyObject, settings: Selector, coffee: Selector, quit: Selector) {
        // The width is a starting point only — the panel stretches this view to
        // its full width. The height is the one this view insists on, stated as
        // a constraint below.
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
            tooltip: "Quit Pitch", target: target, action: quit)

        for view in [leading, quitButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            leading.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.visibleInset - Metrics.hitSlop),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Pinned to this view's trailing edge, so the panel stretching it to
            // full width is all it takes to push quit out to the right margin —
            // landing that glyph the same 14 from its edge as the gear is from
            // the left.
            quitButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -(Metrics.visibleInset - Metrics.hitSlop)),
            quitButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

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
/// An icon that never reacts reads as decoration rather than as a control, and
/// a bordered button here would look nothing like InOut's footer.
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
}
