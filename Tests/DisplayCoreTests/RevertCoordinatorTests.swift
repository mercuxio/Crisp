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
    // `.session` is now `confirm`'s default (F6) — say `.permanent` out loud
    // since that is exactly what this test means to exercise.
    try coordinator.confirm(change, scope: .permanent)

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

    // Hoisted into a local and asserted as a plain condition. `#expect(x ==
    // false)` compiles and always passes when `x` is a `Bool` — see
    // `boolComparisonsAreInvisibleToTheExpectMacro`.
    let expired = try coordinator.expireIfNeeded(change)
    #expect(!expired)
    #expect(configurator.applications.count == 1)
}

@Test func expiryRevertsOnceTheDeadlinePasses() throws {
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 15.0)

    let expired = try coordinator.expireIfNeeded(change)
    #expect(expired)
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
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 20)

    #expect(throws: DisplayError.confirmationExpired) { try coordinator.confirm(change) }
    // Only `begin`'s apply happened — an implementation that applied and then
    // threw would slip past the expectation above without this.
    #expect(configurator.applications.count == 1)
}

@Test func multiDisplayPlansAreCarriedThroughIntact() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)
    let second = makeMode(point: (1512, 982), pixel: (3024, 1964), mHz: 0, id: 3)

    let change = try coordinator.begin(
        target: [1: target, 2: second],
        previous: [1: previous, 2: second])
    // Explicit `.permanent`, not the default. Since the default became
    // `.session` this is the only place a multi-display plan is confirmed at
    // permanent scope, and dropping the argument would quietly retire that
    // coverage while the transaction counts below kept passing.
    try coordinator.confirm(change, scope: .permanent)

    // One transaction per phase, both displays inside it. Spec §8.1.
    #expect(configurator.applications.count == 2)
    #expect(configurator.applications[0].plan.count == 2)
    #expect(configurator.applications[1].plan.count == 2)
    #expect(configurator.applications[1].scope == .permanent)
}

@Test func expireIfNeededRetriesAfterAFailedRevert() throws {
    // The monitor that won't take the old mode back on the first try. The
    // failure must not be swallowed, and it must not be mistaken for success —
    // the next poll has to try again rather than treating this as resolved.
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 15)

    configurator.nextApplyError = .configurationFailed(code: 2_000)
    #expect(throws: DisplayError.configurationFailed(code: 2_000)) {
        _ = try coordinator.expireIfNeeded(change)
    }
    // Only the original `begin` apply is recorded — the failed revert attempt
    // did not get marked as having happened.
    #expect(configurator.applications.count == 1)

    // A second attempt, with the fault cleared, must actually revert.
    let retried = try coordinator.expireIfNeeded(change)
    #expect(retried)
    #expect(configurator.applications.count == 2)
    #expect(configurator.applications.last?.plan == [1: previous])
}

@Test func confirmAfterAnExplicitRevertIsRefused() throws {
    // The screen was already put back. A confirm that arrives after that —
    // whether stale or racing — must not reapply the mode the user rejected.
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.revert(change)

    #expect(throws: DisplayError.confirmationExpired) { try coordinator.confirm(change) }
    // Still just the two applications from begin + revert — confirm did not
    // sneak a third one in.
    #expect(configurator.applications.count == 2)
    #expect(configurator.applications.last?.plan == [1: previous])
}

@Test func expireIfNeededIsIdempotentAfterTheFirstRevert() throws {
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 15)

    let firstPoll = try coordinator.expireIfNeeded(change)
    let secondPoll = try coordinator.expireIfNeeded(change)
    #expect(firstPoll)
    #expect(!secondPoll)

    // One revert transaction, not two — a second poll tick must not be a
    // second CoreGraphics transaction (and a second visible flicker).
    #expect(configurator.applications.count == 2)
}

@Test func confirmAtExactlyTheDeadlineIsRefused() throws {
    // The expiry side already pins 14.9s -> not yet and 15.0s -> revert now.
    // This pins the matching boundary on confirm: at exactly the deadline the
    // window is over, so confirm must refuse rather than sneak in.
    let clock = FakeClock()
    let coordinator = RevertCoordinator(
        configurator: FakeConfigurator(), clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 15.0)

    #expect(throws: DisplayError.confirmationExpired) { try coordinator.confirm(change) }
}
