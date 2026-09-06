import Testing
@testable import Pitch
@testable import DisplayCore

/// `MenuModel` decides which modes reach the menu, which row is checked, and how
/// each is worded. The AppKit layers around it draw what these values say — with
/// one exception, the gear dropdown's display-count rule, in `SettingsMenuTests`.
private func mode(
    _ pointWidth: Int,
    _ pointHeight: Int,
    pixels: (Int, Int)? = nil,
    hz: Int = 60_000,
    safe: Bool = true,
    stretched: Bool = false
) -> DisplayMode {
    let pixel = pixels ?? (pointWidth, pointHeight)
    return DisplayMode(
        signature: ModeSignature(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            pixelWidth: pixel.0,
            pixelHeight: pixel.1,
            refreshMilliHz: hz,
            isSafe: safe),
        ioDisplayModeID: 0,
        isStretched: stretched,
        source: .publicAPI)
}

@Test func refreshRateVariantsCollapseToTheFastest() {
    let sixty = mode(1920, 1080, hz: 60_000)
    let oneTwenty = mode(1920, 1080, hz: 120_000)
    let rows = MenuModel.rows(for: [sixty, oneTwenty], current: sixty)

    #expect(rows.count == 1)
    #expect(rows[0].signature.refreshMilliHz == 120_000)
}

@Test func aHiDPIModeAndItsNonHiDPITwinStayTwoRows() {
    let scaled = mode(1920, 1080, pixels: (3840, 2160))
    let plain = mode(1920, 1080)
    let rows = MenuModel.rows(for: [scaled, plain], current: plain)

    #expect(rows.count == 2)
    #expect(rows.filter(\.isCurrent).count == 1)
    #expect(rows.first(where: \.isCurrent)?.signature.pixelWidth == 1920)
}

@Test func stretchedAndUnsafeModesAreNotOffered() {
    let good = mode(1920, 1080)
    let rows = MenuModel.rows(
        for: [good, mode(1600, 900, stretched: true), mode(1024, 768, safe: false)],
        current: good)

    #expect(rows.count == 1)
    #expect(rows[0].signature.pointWidth == 1920)
}

@Test func theCurrentModeIsAlwaysShownEvenWhenTheFiltersWouldDropIt() {
    // A user sitting on a stretched mode still needs to see where they are,
    // otherwise the menu opens with no checkmark anywhere.
    let stretched = mode(1600, 900, stretched: true)
    let rows = MenuModel.rows(for: [mode(1920, 1080), stretched], current: stretched)

    #expect(rows.count == 2)
    #expect(rows.first(where: \.isCurrent)?.signature == stretched.signature)
}

@Test func rowsRunLargestFirst() {
    let current = mode(1280, 720)
    let rows = MenuModel.rows(
        for: [mode(1280, 720), mode(2560, 1440), mode(1920, 1080)], current: current)

    #expect(rows.map(\.signature.pointWidth) == [2560, 1920, 1280])
}

@Test func aRowTitleIsTheResolutionAndNothingElse() {
    // The HiDPI marker moved to the section heading. A per-row suffix would
    // repeat what the heading above it already said.
    #expect(MenuModel.title(for: mode(1920, 1080, pixels: (3840, 2160))) == "1920 × 1080")
    #expect(MenuModel.title(for: mode(1920, 1080)) == "1920 × 1080")
}

@Test func aZeroRefreshRateNeverReachesTheTitle() {
    // Built-in Apple panels genuinely report 0 Hz, meaning "unspecified".
    // Rendering that as "0 Hz" would be a lie; the title carries no rate at all.
    let title = MenuModel.title(for: mode(1512, 982, pixels: (3024, 1964), hz: 0))
    #expect(!title.contains("0 Hz"))
    #expect(title == "1512 × 982")
}

@Test func theConfirmationHeadlineKeepsTheHiDPIMarker() {
    // The panel floats alone with no heading above it, so this is the one
    // place the marker still has to appear — otherwise the two twins ask the
    // user to confirm the same sentence.
    #expect(
        MenuModel.headline(for: mode(2560, 1440, pixels: (5120, 2880)))
            == "Keep 2560 × 1440 HiDPI?")
    #expect(MenuModel.headline(for: mode(2560, 1440)) == "Keep 2560 × 1440?")
}

@Test func bothKindsOfModeSplitIntoTwoHeadedGroups() {
    let scaled = mode(1920, 1080, pixels: (3840, 2160))
    let plain = mode(1920, 1080)
    let groups = MenuModel.groups(for: [scaled, plain], current: scaled)

    #expect(groups.count == 2)
    #expect(groups[0].heading == "HiDPI")
    #expect(groups[0].rows.map(\.signature) == [scaled.signature])
    #expect(groups[1].heading == "Normal")
    #expect(groups[1].rows.map(\.signature) == [plain.signature])
}

@Test func oneKindOfModeGetsNoHeadingAtAll() {
    // Naming a section that has no sibling tells the user nothing.
    let plain = mode(1920, 1080)
    let groups = MenuModel.groups(for: [plain, mode(1280, 720)], current: plain)

    #expect(groups.count == 1)
    #expect(groups[0].heading == nil)
    #expect(groups[0].rows.count == 2)
}

@Test func groupingLosesNoRows() {
    let modes = [
        mode(2560, 1440, pixels: (5120, 2880)),
        mode(1920, 1080, pixels: (3840, 2160)),
        mode(2560, 1440),
        mode(1920, 1080),
        mode(1280, 720),
    ]
    let current = modes[0]
    let flattened = MenuModel.groups(for: modes, current: current).flatMap(\.rows)
    let ungrouped = MenuModel.rows(for: modes, current: current)

    // Grouping reorders — HiDPI first — but it may never drop or invent a row.
    #expect(flattened.count == ungrouped.count)
    #expect(Set(flattened.map(\.signature)) == Set(ungrouped.map(\.signature)))
    #expect(flattened.filter(\.isCurrent).count == 1)
}

@Test func rememberingPutsTheNewestPickFirstAndTrimsToCapacity() {
    var recents: [ModeSignature] = []
    for width in [1920, 1680, 1600, 1440, 1400] {
        recents = MenuModel.remembering(mode(width, 1080).signature, in: recents)
    }
    #expect(recents.count == MenuModel.recentCapacity)
    #expect(recents.map(\.pointWidth) == [1400, 1440, 1600, 1680])
}

@Test func threeDotsSurviveTheCurrentModeTakingOneOfTheRecentSlots() {
    // The mode you are sitting on is a recent pick like any other, but it
    // wears the checkmark instead of a dot. Were it to count against the
    // limit, the panel would show two dots rather than three — and it would
    // do so almost always, because the last thing you picked is normally
    // the thing you are on.
    let modes = [mode(2560, 1440), mode(1920, 1080), mode(1600, 900), mode(1280, 720)]
    var recents: [ModeSignature] = []
    for mode in modes { recents = MenuModel.remembering(mode.signature, in: recents) }

    let rows = MenuModel.rows(for: modes, current: modes[3], recents: recents)

    #expect(rows.filter(\.isRecent).count == MenuModel.recentLimit)
    // Hoisted into a local rather than compared or coalesced inside
    // `#expect`: see `boolComparisonsAreInvisibleToTheExpectMacro` in
    // DisplayCoreTests for why neither form checks anything here.
    let currentIsRecent = rows.first { $0.isCurrent }?.isRecent ?? true
    #expect(!currentIsRecent)
}

@Test func rememberingARepeatPickMovesItForwardRatherThanDuplicatingIt() {
    let a = mode(1920, 1080).signature
    let b = mode(1600, 900).signature
    let recents = MenuModel.remembering(a, in: MenuModel.remembering(b, in: [a]))
    #expect(recents == [a, b])
}

@Test func recentRowsAreMarkedAndTheCurrentRowIsNotDoubleMarked() {
    let current = mode(1920, 1080)
    let recent = mode(1600, 900)
    let other = mode(1280, 720)

    let rows = MenuModel.rows(
        for: [current, recent, other],
        current: current,
        recents: [current.signature, recent.signature])

    // The current row carries the checkmark, so the model does not also call
    // it recent: one gutter, one marker, and the decision is made here rather
    // than left to the view.
    let currentIsRecent = rows.first { $0.signature == current.signature }?.isRecent ?? true
    let recentIsRecent = rows.first { $0.signature == recent.signature }?.isRecent ?? false
    let otherIsRecent = rows.first { $0.signature == other.signature }?.isRecent ?? true
    let currentIsChecked = rows.first { $0.signature == current.signature }?.isCurrent ?? false
    #expect(!currentIsRecent)
    #expect(recentIsRecent)
    #expect(!otherIsRecent)
    #expect(currentIsChecked)
}

@Test func aRecentPickMarksItsRowEvenAfterTheGroupSwitchesRefreshRate() {
    // Picked at 60 Hz; the row now stands for the 120 Hz member of the same
    // group. Comparing signatures rather than groups would lose the dot.
    let sixty = mode(1920, 1080, hz: 60_000)
    let oneTwenty = mode(1920, 1080, hz: 120_000)

    let rows = MenuModel.rows(
        for: [sixty, oneTwenty], current: mode(1280, 720), recents: [sixty.signature])

    let fastRowIsRecent = rows.first { $0.signature == oneTwenty.signature }?.isRecent ?? false
    #expect(fastRowIsRecent)
}

@Test func selectionKeepsTheRememberedDisplayWhileItIsStillAttached() {
    #expect(MenuModel.selection(from: [1, 2, 3], remembered: 2) == 2)
}

@Test func selectionFallsBackToTheFirstDisplayWhenTheRememberedOneIsGone() {
    // The user picked the external monitor and then unplugged it. Anything but
    // a fallback here leaves the panel showing no resolutions at all.
    #expect(MenuModel.selection(from: [1, 3], remembered: 2) == 1)
    #expect(MenuModel.selection(from: [1, 3], remembered: nil) == 1)
    #expect(MenuModel.selection(from: [], remembered: 2) == nil)
}
