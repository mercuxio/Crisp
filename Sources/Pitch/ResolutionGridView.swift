import AppKit
import DisplayCore

/// One display's resolutions, HiDPI and Normal side by side.
///
/// Side by side rather than stacked: with both kinds in one column, a laptop
/// panel produced 32 rows — a list taller than most of the resolutions it was
/// offering. Side by side it fits on screen, and the HiDPI/Normal split becomes
/// structural rather than typographic.
///
/// These are plain views, not menu items, so nothing draws a highlight or a
/// checkmark for free. `RowButton` below does both by hand.
@MainActor
final class ResolutionGridView: NSView {
    private enum Metrics {
        static let inset: CGFloat = 10
        static let topInset: CGFloat = 2
        static let bottomInset: CGFloat = 6
        /// Half the trough between the columns; the rule sits in the middle.
        static let gutter: CGFloat = 8
        static let rowSpacing: CGFloat = 0
        static let headingGap: CGFloat = 3
    }

    /// Where this view's text starts, measured from its own leading edge.
    ///
    /// Published so the display-name headings above the grid can line up with
    /// the resolutions inside it instead of guessing at the same number.
    static let contentInset: CGFloat = Metrics.inset + RowButton.checkColumn

    init(groups: [MenuModel.Group], pick: @escaping (ModeSignature) -> Void) {
        super.init(frame: .zero)

        let columns = groups.map { Self.column(for: $0, pick: pick) }

        // One group means one column and no rule — a divider needs two sides.
        let content: NSView
        switch columns.count {
        case 0:
            content = NSView()
        case 1:
            content = columns[0]
        default:
            var views: [NSView] = []
            var rules: [NSView] = []
            for (index, column) in columns.enumerated() {
                if index > 0 {
                    let rule = Self.rule()
                    rules.append(rule)
                    views.append(rule)
                }
                views.append(column)
            }

            let row = NSStackView(views: views)
            row.orientation = .horizontal
            // Columns are different lengths, and stretching the short one would
            // leave its rows spread down a half-empty column.
            row.alignment = .top
            row.spacing = Metrics.gutter
            // Which is also why the rule needs its height stated: a top-aligned
            // stack stretches nothing, so an NSBox with no intrinsic height
            // collapses to an invisible zero-height line.
            for rule in rules {
                rule.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
            }
            content = row
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.inset),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topInset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func column(
        for group: MenuModel.Group, pick: @escaping (ModeSignature) -> Void
    ) -> NSStackView {
        var views: [NSView] = []
        if let heading = group.heading {
            views.append(headingLabel(heading))
        }
        views.append(contentsOf: group.rows.map { RowButton(row: $0, pick: pick) })

        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Metrics.rowSpacing
        if group.heading != nil, views.count > 1 {
            column.setCustomSpacing(Metrics.headingGap, after: views[0])
        }
        // Rows are buttons, which would otherwise stretch to the tallest sibling
        // column's height and spread their highlight across empty space.
        column.setHuggingPriority(.required, for: .vertical)
        return column
    }

    /// The same small-caps treatment the display-name headings use, so the two
    /// levels of heading in this panel read as one system.
    ///
    /// Wrapped in a container that reproduces the rows' checkmark gutter, so the
    /// heading starts where the resolutions start instead of hanging out to
    /// their left. That is how macOS indents its own menu section headers.
    private static func headingLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ]))
        label.translatesAutoresizingMaskIntoConstraints = false
        // The rule between the columns is required to match the stack's height,
        // which leaves that height a free variable for the solver. Minimising it
        // then costs whatever resists least — and a text field's default 750
        // vertical compression resistance is the weakest thing here, so without
        // this the taller column's heading silently flattens to nothing.
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: RowButton.checkColumn),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.setContentHuggingPriority(.required, for: .vertical)
        return container
    }

    private static func rule() -> NSView {
        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return rule
    }
}

/// One resolution.
///
/// The checkmark column and the hover highlight are both drawn here. A real
/// menu item would have supplied them; a view laid out in columns supplies
/// nothing, which is the price of the two-column arrangement above.
final class RowButton: NSView {
    /// Shared with the column headings, which indent by exactly this much to
    /// line their first glyph up with the resolutions below them.
    static let checkColumn: CGFloat = 16

    private enum Metrics {
        static let height: CGFloat = 20
        static let trailing: CGFloat = 12
        static let corner: CGFloat = 4
    }

    private let pick: (ModeSignature) -> Void
    private let signature: ModeSignature
    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var tracking: NSTrackingArea?

    /// What the gutter glyph goes back to when the pointer leaves.
    ///
    /// Not always `labelColor`: a recency dot rests two steps down the label
    /// hierarchy from the checkmark, so restoring one colour for both would
    /// promote every dot the pointer had passed over.
    private let restingTint: NSColor
    /// `NSControl` already spells this `isHighlighted`, and this is a plain
    /// view, so the name says what it actually tracks: the pointer.
    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            label.textColor = isHovering ? .alternateSelectedControlTextColor : .labelColor
            check.contentTintColor = isHovering ? label.textColor : restingTint
            needsDisplay = true
        }
    }

    init(row: MenuModel.Row, pick: @escaping (ModeSignature) -> Void) {
        self.pick = pick
        self.signature = row.signature
        // A checkmark reads at full strength, a dot a step below it: where you
        // are should carry more weight than where you have been. The model
        // guarantees a row is never both, so this picks a colour rather than
        // settling an argument.
        self.restingTint = row.isCurrent ? .labelColor : .secondaryLabelColor
        super.init(frame: .zero)

        label.stringValue = row.title
        label.font = .menuFont(ofSize: 12)
        label.textColor = .labelColor

        check.image = Self.marker(isCurrent: row.isCurrent, isRecent: row.isRecent)
        check.contentTintColor = restingTint

        for view in [check, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.centerXAnchor.constraint(
                equalTo: leadingAnchor, constant: RowButton.checkColumn / 2),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: RowButton.checkColumn),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: Metrics.trailing),
        ])

        // VoiceOver needs the label because the row is a view, not a menu item.
        // No tooltip: it would pop up repeating the text already on the row.
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(Self.spoken(row))
    }

    /// What sits in the gutter: a checkmark, a dot, or nothing.
    ///
    /// The dot is drawn at a fraction of the checkmark's size and two steps down
    /// the label hierarchy. It is a hint about where you have been, and a hint
    /// that competes with the checkmark for attention is worse than no hint.
    private static func marker(isCurrent: Bool, isRecent: Bool) -> NSImage? {
        if isCurrent {
            return NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Current")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
        }
        guard isRecent else { return nil }
        return NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Recent")?
            .withSymbolConfiguration(.init(pointSize: 5, weight: .regular))
    }

    /// The row read aloud, including whatever the gutter is showing.
    ///
    /// A glyph inside an image view VoiceOver never reaches is a marker only
    /// sighted users get, so the distinction is spelled into the row's label.
    private static func spoken(_ row: MenuModel.Row) -> String {
        if row.isCurrent { return "\(row.title), current" }
        if row.isRecent { return "\(row.title), recently used" }
        return row.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovering else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.corner, yRadius: Metrics.corner)
            .fill()
    }

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

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// - Note: closing the panel is `pick`'s job, and it does it before applying
    ///   anything. The confirmation countdown opens from there, and this panel
    ///   floats at `.popUpMenu` level — left open, it would sit on top of the
    ///   countdown it just started.
    override func mouseUp(with event: NSEvent) {
        isHovering = false
        // A press that wandered off the row before releasing is a cancelled
        // click, the same as anywhere else in the system.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        pick(signature)
    }
}
