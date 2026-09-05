import CoreGraphics
import Testing
@testable import DisplayCore

private let target = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
private let previous = makeMode(point: (1920, 1080), pixel: (3840, 2160), id: 12)

@Test func beginAppliesForTheSessionOnlyNeverPermanently() throws {
    // The single most important assertion in this file. Spec §8.1: applying
    // permanently before confirmation is what makes a bad mode unescapable.
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    _ = try coordinator.begin(target: [1: target], previous: [1: previous])

    #expect(configurator.scopeSequence == [.session])
    #expect(configurator.applications[0].plan == [1: target])
}

@Test func confirmReappliesTheSameModePermanently() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.confirm(change)

    #expect(configurator.scopeSequence == [.session, .permanent])
    #expect(configurator.applications[1].plan == [1: target])
}

@Test func confirmingWithSessionScopeDoesNotEscalatePermanence() throws {
    // `displayctl set` without --permanent confirms in session scope. If this
    // silently applied permanently, a mode the user never asked to persist
    // would survive a reboot.
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.confirm(change, scope: .session)

    #expect(configurator.scopeSequence == [.session, .session])
}

@Test func revertRestoresThePreviousModeForTheSession() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.revert(change)

    #expect(configurator.scopeSequence == [.session, .session])
    #expect(configurator.applications[1].plan == [1: previous])
}

@Test func expiryDoesNothingBeforeTheDeadline() throws {
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 14.9)

    #expect(try coordinator.expireIfNeeded(change) == false)
    #expect(configurator.applications.count == 1)
}

@Test func expiryRevertsOnceTheDeadlinePasses() throws {
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 15.0)

    #expect(try coordinator.expireIfNeeded(change) == true)
    #expect(configurator.applications.last?.plan == [1: previous])
    #expect(configurator.applications.last?.scope == .session)
}

@Test func secondsRemainingCountsDownAndFloorsAtZero() throws {
    let clock = FakeClock()
    let coordinator = RevertCoordinator(
        configurator: FakeConfigurator(), clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    #expect(coordinator.secondsRemaining(for: change) == 15)

    clock.advance(by: 10)
    #expect(coordinator.secondsRemaining(for: change) == 5)

    clock.advance(by: 100)
    #expect(coordinator.secondsRemaining(for: change) == 0)
}

@Test func aFailedApplyLeavesNothingPending() {
    let configurator = FakeConfigurator()
    configurator.nextApplyError = .configurationFailed(code: 1_000)
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    #expect(throws: DisplayError.configurationFailed(code: 1_000)) {
        _ = try coordinator.begin(target: [1: target], previous: [1: previous])
    }
    #expect(configurator.applications.isEmpty)
}

@Test func confirmingAnExpiredChangeIsRefused() throws {
    // Otherwise a slow user confirms a mode that was already reverted, and the
    // screen changes back under them.
    let clock = FakeClock()
    let coordinator = RevertCoordinator(
        configurator: FakeConfigurator(), clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 20)

    #expect(throws: DisplayError.confirmationExpired) { try coordinator.confirm(change) }
}

@Test func multiDisplayPlansAreCarriedThroughIntact() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)
    let second = makeMode(point: (1512, 982), pixel: (3024, 1964), mHz: 0, id: 3)

    let change = try coordinator.begin(
        target: [1: target, 2: second],
        previous: [1: previous, 2: second])
    try coordinator.confirm(change)

    // One transaction per phase, both displays inside it. Spec §8.1.
    #expect(configurator.applications.count == 2)
    #expect(configurator.applications[0].plan.count == 2)
    #expect(configurator.applications[1].plan.count == 2)
}
