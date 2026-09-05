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
