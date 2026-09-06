import AppKit
import CoreGraphics

/// The row of monitor icons at the top of the panel: which display the
/// resolutions below belong to.
///
/// Showing every display's modes at once made a panel taller than the screen it
/// was offering to resize, and gave no clue which list was which beyond a name
/// printed above it. One icon per display, one list below, is both shorter and
/// less ambiguous. The view is built even for a single display, where it selects
/// nothing but still says whose resolutions these are.
///
/// The icon is the same `display` symbol the menu bar item uses, numbered the
/// way System Settings numbers displays in its arrangement view.
///
/// Only the selected display is named in full, on its own line under the row.
/// Naming all of them would mean every name fitting under its own icon for any
/// of them to line up, and "Built-in Retina Display" is several times the width
/// of a 16pt glyph. One name on one line has the whole panel to spread across,
/// and it answers the question the icons raise — which of these am I on? — for
/// the one icon where the answer matters. The rest keep their tooltips.
@MainActor
final class DisplayPickerView: NSView {
    /// One display, as much of it as this view needs to know.
    struct Item {
        let id: CGDirectDisplayID
        /// The display's name as macOS knows it — see `DisplayNames`. Shown in
        /// full when this display is the selected one, and as a tooltip
        /// otherwise.
        let name: String
    }

    private enum Metrics {
        /// Matches `MenuFooterView`, so the icons at the top of the panel sit on
        /// the same left margin as the icons at the bottom.
        static let visibleInset: CGFloat = 14
        static let hitSlop: CGFloat = 4
        static let spacing: CGFloat = 2
        static let glyph: CGFloat = 16
        static let topPadding: CGFloat = 5
        static let bottomPadding: CGFloat = 5

        /// Zero because the buttons already carry `hitSlop` below their glyphs,
        /// which is the visual gap. Adding to it here would double-count.
        static let nameGap: CGFloat = 0
        static let nameSize: CGFloat = 11
    }

    init(
        items: [Item],
        selected: CGDirectDisplayID,
        pick: @escaping (CGDirectDisplayID) -> Void
    ) {
        super.init(frame: .zero)

        let buttons = items.enumerated().map { index, item in
            Self.button(
                // 1-based: the displays are numbered for a person reading them,
                // not indexed for a program.
                number: index + 1,
                name: item.name,
                isSelected: item.id == selected,
                action: { pick(item.id) })
        }

        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = Metrics.spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let name = Self.nameLabel(items.first { $0.id == selected }?.name ?? "")
        addSubview(name)

        NSLayoutConstraint.activate([
            // Pulled left by the slop so the glyphs, not the buttons' invisible
            // edges, line up with everything else on the panel's margin.
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.visibleInset - Metrics.hitSlop),
            row.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -(Metrics.visibleInset - Metrics.hitSlop)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),

            // The label has no slop to compensate for, so it sits on the margin
            // itself and still lines up with the glyphs above it.
            name.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Metrics.visibleInset),
            name.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Metrics.visibleInset),
            name.topAnchor.constraint(equalTo: row.bottomAnchor, constant: Metrics.nameGap),
            name.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.bottomPadding),
        ])
    }

    /// The selected display's name, under the row of icons.
    ///
    /// Truncated rather than wrapped: the panel's width is set by the resolution
    /// columns below, and letting a long monitor name run onto a second line
    /// would make the header taller for reasons that have nothing to do with the
    /// header. Sentence case, not the uppercase the resolution headings use —
    /// "LG Ultra HD" is a product's name and shouting it back is a small
    /// discourtesy.
    private static func nameLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Metrics.nameSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func button(
        number: Int, name: String, isSelected: Bool, action: @escaping () -> Void
    ) -> NSButton {
        let button = PickerButton()
        button.image = glyph(number: number, size: Metrics.glyph)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.toolTip = name
        // The glyph carries a number, not a name, so this is the only thing
        // VoiceOver has to go on.
        button.setAccessibilityLabel(name)
        button.isSelected = isSelected
        button.onClick = action

        let side = Metrics.glyph + Metrics.hitSlop * 2
        button.widthAnchor.constraint(equalToConstant: side).isActive = true
        button.heightAnchor.constraint(equalToConstant: side).isActive = true
        return button
    }

    /// The menu bar's `display` symbol with a number drawn inside its screen.
    ///
    /// Composited rather than overlaid as a second view: the result is one
    /// template image, so a single `contentTintColor` colours the outline and
    /// the number together and the two can never disagree about which state the
    /// button is in.
    ///
    /// The number is drawn in black, which the template treatment then throws
    /// away — only the alpha survives. That is the point: black is simply the
    /// most opaque thing to draw with.
    private static func glyph(number: Int, size: CGFloat) -> NSImage? {
        guard
            let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        else { return nil }

        let composed = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)

            let text = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: round(size * 0.44), weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let bounds = text.size(withAttributes: attributes)
            // The symbol is a screen sitting on a stand, so its centre is not
            // the screen's centre — the number has to ride above the midpoint to
            // land inside the panel rather than across its foot.
            let centre = NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.60)
            text.draw(
                at: NSPoint(x: centre.x - bounds.width / 2, y: centre.y - bounds.height / 2),
                withAttributes: attributes)
            return true
        }
        composed.isTemplate = true
        return composed
    }
}

/// A borderless icon button that is either the chosen display or one of the
/// others.
///
/// Selected is `labelColor` and unselected `tertiaryLabelColor`: the same pair
/// AppKit uses for a chosen row against the rest of a list, which also means
/// both follow the system appearance instead of being literally black.
///
/// Hover lifts an unselected icon to `secondaryLabelColor` — enough to read as
/// clickable, not enough to be mistaken for the selection.
private final class PickerButton: NSButton {
    var onClick: (() -> Void)?

    var isSelected: Bool = false {
        didSet { applyTint(hovering: false) }
    }

    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() {
        onClick?()
    }

    private func applyTint(hovering: Bool) {
        if isSelected {
            contentTintColor = .labelColor
        } else {
            contentTintColor = hovering ? .secondaryLabelColor : .tertiaryLabelColor
        }
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

    override func mouseEntered(with event: NSEvent) {
        applyTint(hovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        applyTint(hovering: false)
    }
}
