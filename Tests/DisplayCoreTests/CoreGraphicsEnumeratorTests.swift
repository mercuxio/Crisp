import CoreGraphics
import Testing
@testable import DisplayCore

// MARK: - The guard

@Test func theHiDPIOptionsConstantStillHasTheValueWeDependOn() {
    // Spec §4.1. The symbol's NAME and its VALUE differ: the constant
    // `kCGDisplayShowDuplicateLowResolutionModes` carries the CFString value
    // "kCGDisplayResolution". If a future SDK changes this, the options
    // dictionary silently stops working and the mode list halves with no
    // error. This test is the alarm.
    #expect((kCGDisplayShowDuplicateLowResolutionModes as String) == "kCGDisplayResolution")
}

// MARK: - Conversion

@Test func conversionRoundsRefreshRateToMillihertz() {
    let sig = ModeConversion.signature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshRateHz: 59.94,
        isUsableForDesktopGUI: true)

    #expect(sig.refreshMilliHz == 59_940)
}

@Test func conversionKeepsAnUnspecifiedRefreshRateAsZero() {
    // Built-in Apple displays report 0.0 Hz.
    let sig = ModeConversion.signature(
        pointWidth: 1512, pointHeight: 982,
        pixelWidth: 3024, pixelHeight: 1964,
        refreshRateHz: 0.0,
        isUsableForDesktopGUI: true)

    #expect(sig.refreshMilliHz == 0)
}

@Test func conversionRoundsRatherThanTruncates() {
    // 60.0000001 Hz must not become 59_999 mHz through truncation.
    let sig = ModeConversion.signature(
        pointWidth: 1920, pointHeight: 1080,
        pixelWidth: 1920, pixelHeight: 1080,
        refreshRateHz: 59.9999,
        isUsableForDesktopGUI: true)

    #expect(sig.refreshMilliHz == 60_000)
}

@Test func conversionCarriesTheDesktopUsabilityFlagIntoIsSafe() {
    let sig = ModeConversion.signature(
        pointWidth: 1600, pointHeight: 900,
        pixelWidth: 1600, pixelHeight: 900,
        refreshRateHz: 60,
        isUsableForDesktopGUI: false)

    #expect(!sig.isSafe)
}

@Test func stretchedDetectionComparesAspectRatios() {
    // Square pixels: point and pixel aspect agree.
    #expect(!ModeConversion.isStretched(
        pointWidth: 2560, pointHeight: 1440, pixelWidth: 5120, pixelHeight: 2880))
    #expect(!ModeConversion.isStretched(
        pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080))

    // 16:9 points driven onto a 16:10 pixel grid: non-square pixels.
    #expect(ModeConversion.isStretched(
        pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1200))
}

@Test func stretchedDetectionToleratesRoundingInScaledModes() {
    // 1.5x-class scaled modes do not divide evenly and must not be
    // misreported as stretched.
    #expect(!ModeConversion.isStretched(
        pointWidth: 1707, pointHeight: 960, pixelWidth: 3414, pixelHeight: 1920))
}

@Test func deduplicationDropsRepeatedSignaturesKeepingTheFirst() {
    let first = makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 10)
    let duplicate = makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 99)
    let other = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)

    let result = ModeConversion.deduplicated([first, duplicate, other])

    #expect(result == [first, other])
}

@Test func deduplicationKeepsModesThatDifferOnlyInSafety() {
    // The §4.3 collision pair must survive deduplication — they are genuinely
    // different modes, which is the whole reason isSafe is in the signature.
    let safe = makeMode(point: (2560, 1440), pixel: (2560, 1440), safe: true, id: 47)
    let unsafeTwin = makeMode(point: (2560, 1440), pixel: (2560, 1440), safe: false, id: 97)

    #expect(ModeConversion.deduplicated([safe, unsafeTwin]).count == 2)
}

// MARK: - The fake satisfies the protocol

@Test func fakeEnumeratorReportsWhatItWasGiven() throws {
    let device = DisplayDevice(
        displayID: 1, localizedName: "Display 1", isBuiltIn: false, isVirtual: false)
    let mode = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let fake = FakeEnumerator(
        devices: [device],
        modesByDisplay: [1: [mode]],
        currentByDisplay: [1: mode])

    #expect(try fake.onlineDisplayIDs() == [1])
    #expect(try fake.modes(for: 1) == [mode])
    #expect(try fake.currentMode(for: 1) == mode)
    #expect(throws: DisplayError.noSuchDisplay(7)) { try fake.device(for: 7) }
}
