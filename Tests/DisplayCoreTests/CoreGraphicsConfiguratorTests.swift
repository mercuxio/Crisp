import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

// MARK: - Watchdog

@Test func watchdogReturnsTheResultWhenWorkFinishesInTime() throws {
    let result = try Watchdog.run(timeout: 2.0) { 0 }
    #expect(result == 0)
}

@Test func watchdogThrowsWhenWorkOverrunsTheWindow() {
    #expect(throws: DisplayError.completionTimedOut(seconds: 0.2)) {
        try Watchdog.run(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 1.0)
            return 0
        }
    }
}

@Test func watchdogPropagatesANonZeroResultRatherThanSwallowingIt() throws {
    let result = try Watchdog.run(timeout: 2.0) { 1_004 }
    #expect(result == 1_004)
}

// MARK: - Mode hint validation

@Test func hintValidationAcceptsAMatchingSignature() {
    let mode = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    #expect(CoreGraphicsConfigurator.hintIsValid(mode, against: mode.signature))
}

@Test func hintValidationRejectsAStaleSignature() {
    // Spec §4.2 and §10: ioDisplayModeID is an O(1) hint, not an identity.
    // After an OS update the same numeric ID can point at a different mode,
    // and applying it unvalidated silently changes the resolution.
    let stored = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let whatIDNowPointsAt = makeMode(point: (1920, 1080), pixel: (3840, 2160), id: 48)

    #expect(!CoreGraphicsConfigurator.hintIsValid(whatIDNowPointsAt, against: stored.signature))
}

// MARK: - Scope-to-CGConfigureOption mapping

@Test func cgOptionMapsSessionScopeToForSession() {
    #expect(CoreGraphicsConfigurator.cgOption(for: .session) == .forSession)
}

@Test func cgOptionMapsPermanentScopeToPermanently() {
    #expect(CoreGraphicsConfigurator.cgOption(for: .permanent) == .permanently)
}

// MARK: - Mode pick logic (the real gate behind resolveRawMode)

@Test func modePickTakesTheFastPathWhenTheHintIsValid() {
    let target = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let candidates: [(ioDisplayModeID: Int32, signature: ModeSignature)] = [
        (ioDisplayModeID: 1, signature: makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 1).signature),
        (ioDisplayModeID: 48, signature: target.signature),
    ]

    #expect(ModePick.index(in: candidates, matching: target) == 1)
}

@Test func modePickFallsThroughToTheSignatureScanWhenTheHintIsStale() {
    // Spec §4.2/§10: an ID collision after a hardware or OS change should
    // fall back to a full scan rather than apply the wrong mode.
    let target = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let candidates: [(ioDisplayModeID: Int32, signature: ModeSignature)] = [
        // id 48 now points at something else entirely.
        (ioDisplayModeID: 48, signature: makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 48).signature),
        // the real target is elsewhere, under a different id.
        (ioDisplayModeID: 99, signature: target.signature),
    ]

    #expect(ModePick.index(in: candidates, matching: target) == 1)
}

@Test func modePickFindsTheRightVariantWhenADuplicateIDsFirstMatchIsWrong() {
    // Two candidates share ioDisplayModeID 48; the first one CoreGraphics
    // happens to list is the wrong variant. The fast path must reject it
    // (hintIsValid fails) and the slow path must still find the correct one.
    let target = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let candidates: [(ioDisplayModeID: Int32, signature: ModeSignature)] = [
        (ioDisplayModeID: 48, signature: makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 48).signature),
        (ioDisplayModeID: 48, signature: target.signature),
    ]

    #expect(ModePick.index(in: candidates, matching: target) == 1)
}

@Test func modePickReturnsNilWhenNothingMatches() {
    // resolveRawMode turns this into DisplayError.modeUnavailable.
    let target = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let candidates: [(ioDisplayModeID: Int32, signature: ModeSignature)] = [
        (ioDisplayModeID: 1, signature: makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 1).signature),
    ]

    #expect(ModePick.index(in: candidates, matching: target) == nil)
}

// MARK: - The fake honours the contract

@Test func fakeConfiguratorRecordsScopeAndPlan() throws {
    let configurator = FakeConfigurator()
    let mode = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)

    try configurator.apply([1: mode], scope: .session)

    #expect(configurator.applications.count == 1)
    #expect(configurator.applications[0].plan == [1: mode])
    #expect(configurator.applications[0].scope == .session)
}

@Test func fakeConfiguratorThrowsOnceWhenPrimed() {
    let configurator = FakeConfigurator()
    configurator.nextApplyError = .configurationFailed(code: 1_000)

    #expect(throws: DisplayError.configurationFailed(code: 1_000)) {
        try configurator.apply([:], scope: .session)
    }
    #expect(throws: Never.self) { try configurator.apply([:], scope: .session) }
}
