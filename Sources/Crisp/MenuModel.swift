import CoreGraphics
import DisplayCore

/// Everything the status menu needs to know, computed without touching AppKit.
///
/// The menu is the one place a user picks a mode, so the rules that decide
/// which modes appear — and which row shows the checkmark — are worth testing
/// without a screen attached. `StatusMenuController` turns these values into
/// `NSMenuItem`s and does nothing else.
enum MenuModel {
    /// One row in the menu: a resolution the user can pick.
    ///
    /// `signature` is the mode actually applied when the row is clicked. It is
    /// the highest refresh rate in its group (see `rows(for:current:)`), not
    /// necessarily the mode the enumerator happened to list first.
    struct Row: Equatable {
        let signature: ModeSignature
        let title: String
        let isCurrent: Bool

        /// Among the last few resolutions the user picked on this display.
        ///
        /// Marked with a dot in the gutter, which is the checkmark's column —
        /// so a row that is both current and recent shows the checkmark and no
        /// dot. The two markers answer different questions and the checkmark's
        /// is the more urgent one.
        let isRecent: Bool
    }

    /// One display's block of rows, with the heading shown above it.
    struct Section: Equatable {
        let displayID: CGDirectDisplayID
        let title: String
        let rows: [Row]
    }

    /// Modes that differ only in refresh rate collapse into one row.
    ///
    /// A panel reports the same resolution at 60, 120 and 144 Hz as three
    /// distinct modes. Listing all three triples the menu's length and asks
    /// the user a question they did not come here to answer, so the group is
    /// represented by its fastest member. Refresh-rate control is a separate
    /// feature (spec §11.3) and is not wired up yet — until it is, picking a
    /// resolution means picking the fastest refresh it supports.
    ///
    /// The grouping key includes pixel dimensions, not just point dimensions,
    /// so a HiDPI mode and its non-HiDPI twin at the same point size stay two
    /// separate rows — that difference is the entire point of the app.
    struct GroupKey: Hashable {
        let pointWidth: Int
        let pointHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func groupKey(_ mode: DisplayMode) -> GroupKey {
        GroupKey(
            pointWidth: mode.pointWidth,
            pointHeight: mode.pointHeight,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight)
    }

    /// `1920 × 1080`, and nothing else.
    ///
    /// No HiDPI marker: rows live under a `HiDPI` or `Normal` heading, so a
    /// per-row suffix would repeat what the section above it already said.
    ///
    /// Refresh rate is deliberately absent too — every row is the fastest in
    /// its group, so printing a rate would imply a choice the menu does not
    /// offer. A zero refresh rate means "unspecified", which built-in Apple
    /// panels genuinely report, and must never be rendered as "0 Hz".
    static func title(for mode: DisplayMode) -> String {
        "\(mode.pointWidth) × \(mode.pointHeight)"
    }

    /// The confirmation panel's headline.
    ///
    /// Unlike `title(for:)` this keeps the HiDPI marker. The panel floats on
    /// its own with no section heading above it, so "Keep 2560 × 1440?" would
    /// be ambiguous on a display that offers both twins — and which twin you
    /// just applied is exactly what the countdown is asking you to confirm.
    static func headline(for mode: DisplayMode) -> String {
        let kind = mode.pixelWidth > mode.pointWidth ? " HiDPI" : ""
        return "Keep \(mode.pointWidth) × \(mode.pointHeight)\(kind)?"
    }

    /// A heading and the rows beneath it.
    ///
    /// `heading` is nil when the display offers only one kind of mode: naming
    /// a section that has no sibling tells the user nothing.
    struct Group: Equatable {
        let heading: String?
        let rows: [Row]
    }

    /// Rows split into HiDPI and Normal, HiDPI first.
    ///
    /// Interleaved, this display produced 32 rows in one undifferentiated
    /// column, where `2560 × 1440` appeared twice with only a suffix telling
    /// them apart. Splitting makes the distinction structural instead of
    /// typographic — the same arrangement QuickRes uses.
    static func groups(
        for modes: [DisplayMode], current: DisplayMode, recents: [ModeSignature] = []
    ) -> [Group] {
        let all = rows(for: modes, current: current, recents: recents)
        let hiDPI = all.filter { $0.signature.pixelWidth > $0.signature.pointWidth }
        let normal = all.filter { $0.signature.pixelWidth <= $0.signature.pointWidth }

        if hiDPI.isEmpty { return normal.isEmpty ? [] : [Group(heading: nil, rows: normal)] }
        if normal.isEmpty { return [Group(heading: nil, rows: hiDPI)] }
        return [Group(heading: "HiDPI", rows: hiDPI), Group(heading: "Normal", rows: normal)]
    }

    /// The rows for one display, best resolution first.
    ///
    /// Stretched modes are dropped: they distort the picture, QuickRes does not
    /// offer them, and a user who wants one can reach it through `displayctl`.
    /// Unsafe modes are dropped for the same reason the CLI hides them by
    /// default — a mode the panel cannot display is how a user ends up unable
    /// to read the menu that would undo it.
    static func rows(
        for modes: [DisplayMode], current: DisplayMode, recents: [ModeSignature] = []
    ) -> [Row] {
        let usable = modes.filter { !$0.isStretched && $0.isSafe }
        let currentKey = groupKey(current)

        // Compared by group rather than by signature: a row stands for its whole
        // refresh-rate group and applies the fastest member, so a recent pick
        // recorded at 60 Hz must still light up the row that now offers 120.
        let recentKeys = Set(
            recents.map {
                GroupKey(
                    pointWidth: $0.pointWidth,
                    pointHeight: $0.pointHeight,
                    pixelWidth: $0.pixelWidth,
                    pixelHeight: $0.pixelHeight)
            })

        var fastest: [GroupKey: DisplayMode] = [:]
        for mode in usable {
            let key = groupKey(mode)
            if let existing = fastest[key], existing.refreshMilliHz >= mode.refreshMilliHz {
                continue
            }
            fastest[key] = mode
        }

        // The current mode always gets a row even if the filters above would
        // have dropped it. A user sitting on a stretched or unsafe mode still
        // needs to see where they are, and hiding it would leave the menu with
        // no checkmark at all.
        if fastest[currentKey] == nil {
            fastest[currentKey] = current
        }

        return fastest.values
            .sorted { lhs, rhs in
                if lhs.pointWidth != rhs.pointWidth { return lhs.pointWidth > rhs.pointWidth }
                if lhs.pointHeight != rhs.pointHeight { return lhs.pointHeight > rhs.pointHeight }
                return lhs.pixelWidth > rhs.pixelWidth
            }
            .map { mode in
                Row(
                    signature: mode.signature,
                    title: title(for: mode),
                    isCurrent: groupKey(mode) == currentKey,
                    isRecent: recentKeys.contains(groupKey(mode)))
            }
    }

    /// How many resolutions the dots remember.
    static let recentLimit = 3

    /// The recency list after the user picks `signature`, newest first.
    ///
    /// Moves a repeat pick back to the front rather than adding it twice, so
    /// three dots always mean three different resolutions. Trimmed to
    /// `recentLimit`, which is what stops the dots from spreading down the whole
    /// column until they say nothing at all.
    static func remembering(
        _ signature: ModeSignature, in recents: [ModeSignature]
    ) -> [ModeSignature] {
        ([signature] + recents.filter { $0 != signature }).prefix(recentLimit).map { $0 }
    }

    /// Which display the panel should be showing.
    ///
    /// `remembered` is the last one the user picked, which survives the panel
    /// closing but not the display being unplugged — hence the membership test
    /// rather than a straight unwrap. Falling back to the first online display
    /// matches what the panel showed before there was anything to pick.
    static func selection(
        from ids: [CGDirectDisplayID], remembered: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let remembered, ids.contains(remembered) { return remembered }
        return ids.first
    }
}
