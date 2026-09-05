import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore
@testable import displayctl

private let hidpi = cliMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
private let native = cliMode(point: (1920, 1080), pixel: (1920, 1080), id: 12)
private let stretched = cliMode(
    point: (1600, 1200), pixel: (2560, 1440), stretched: true, id: 70)

private func fixture(
    current: DisplayMode = native,
    modes: [DisplayMode] = [hidpi, native, stretched]
) -> CLIFakeEnumerator {
    let enumerator = CLIFakeEnumerator()
    enumerator.modesByID = [1: modes]
    enumerator.currentByID = [1: current]
    return enumerator
}

private func options(
    width: Int = 2560,
    height: Int = 1440,
    permanent: Bool = false,
    assumeYes: Bool = false,
    timeout: Int = 15
) -> SetOptions {
    SetOptions(
        width: width, height: height,
        displayIndex: nil, refreshMilliHz: nil, hiDPI: nil,
        includeUnsafe: false, includeStretched: false,
        permanent: permanent, assumeYes: assumeYes,
        timeoutSeconds: timeout)
}

private func coordinator(
    _ configurator: DisplayConfiguring,
    clock: MonotonicClock = SteppingClock(),
    window: TimeInterval = 15
) -> RevertCoordinator {
    RevertCoordinator(configurator: configurator, clock: clock, window: window)
}

// MARK: - Display selection

@Test func displayIndexIsOneBasedAndMatchesTheListOutput() throws {
    let enumerator = fixture()
    enumerator.ids = [7, 9]

    #expect(try resolveDisplay(index: 1, enumerator: enumerator) == 7)
    #expect(try resolveDisplay(index: 2, enumerator: enumerator) == 9)
}

@Test func omittingTheDisplayIndexSelectsTheFirstDisplay() throws {
    let enumerator = fixture()
    enumerator.ids = [7, 9]

    #expect(try resolveDisplay(index: nil, enumerator: enumerator) == 7)
}

@Test func anOutOfRangeDisplayIndexIsRejectedBeforeAnythingIsApplied() {
    let enumerator = fixture()

    #expect(throws: ParseError.self) {
        _ = try resolveDisplay(index: 4, enumerator: enumerator)
    }
}

// MARK: - The happy path

@Test func confirmingWithinTheWindowAppliesForTheSessionThenPermanently() throws {
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(permanent: true),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(outcome.result == .applied)
    #expect(configurator.scopeSequence == [.session, .permanent])
    #expect(configurator.applications[0].plan == [1: hidpi])
}

@Test func withoutPermanentTheChangeIsNeverEscalatedPastTheSession() throws {
    // Spec §8.1: `--permanent` is opt-in. A change the user did not ask to
    // persist must not survive a reboot, which is the escape hatch of last
    // resort for a mode that turns out to be wrong later.
    let configurator = CLIFakeConfigurator()
    _ = try runSet(
        options(permanent: false),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(!configurator.scopeSequence.contains(.permanent))
}

@Test func assumeYesSkipsTheConfirmationSourceEntirely() throws {
    let confirmation = ScriptedConfirmation(.timedOut)
    let configurator = CLIFakeConfigurator()

    let outcome = try runSet(
        options(permanent: true, assumeYes: true),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: confirmation)

    #expect(outcome.result == .applied)
    #expect(confirmation.timeoutsSeen.isEmpty)
    #expect(configurator.scopeSequence == [.session, .permanent])
}

// MARK: - The paths that save a user

@Test func decliningRevertsToThePreviousMode() throws {
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.declined))

    #expect(outcome.result == .reverted(reason: .declined))
    #expect(configurator.applications.last?.plan == [1: native])
    #expect(configurator.applications.last?.scope == .session)
}

@Test func silenceRevertsToThePreviousMode() throws {
    // The case this whole design exists for: the user cannot see the prompt
    // because the mode they just chose made the screen unreadable.
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.timedOut))

    #expect(outcome.result == .reverted(reason: .timedOut))
    #expect(configurator.applications.last?.plan == [1: native])
}

@Test func theConfirmationDeadlineAndThePromptTimeoutAreTheSameNumber() throws {
    // If the prompt waited longer than the coordinator's window, confirming at
    // second 19 of a 15-second window would throw instead of working.
    let confirmation = ScriptedConfirmation(.timedOut)
    _ = try runSet(
        options(timeout: 30),
        enumerator: fixture(),
        coordinator: coordinator(CLIFakeConfigurator(), window: 30),
        confirmation: confirmation)

    #expect(confirmation.timeoutsSeen == [30])
}

// MARK: - Refusals

@Test func askingForTheModeThatIsAlreadyActiveChangesNothing() throws {
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(width: 1920, height: 1080),
        enumerator: fixture(current: native),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(outcome.result == .alreadyActive)
    #expect(configurator.applications.isEmpty)
}

@Test func anUnavailableSizeIsRefusedWithAnActionableError() {
    #expect(throws: DisplayError.noMatchingMode(requestedWidth: 3200, requestedHeight: 1800)) {
        _ = try runSet(
            options(width: 3200, height: 1800),
            enumerator: fixture(),
            coordinator: coordinator(CLIFakeConfigurator()),
            confirmation: ScriptedConfirmation(.confirmed))
    }
}

@Test func stretchedModesAreExcludedUnlessAskedFor() {
    // 1600x1200 exists only as a stretched mode in the fixture.
    #expect(throws: DisplayError.noMatchingMode(requestedWidth: 1600, requestedHeight: 1200)) {
        _ = try runSet(
            options(width: 1600, height: 1200),
            enumerator: fixture(),
            coordinator: coordinator(CLIFakeConfigurator()),
            confirmation: ScriptedConfirmation(.confirmed))
    }
}

@Test func stretchedModesAreReachableWhenExplicitlyAllowed() throws {
    var opts = options(width: 1600, height: 1200, permanent: true)
    opts.includeStretched = true
    let configurator = CLIFakeConfigurator()

    let outcome = try runSet(
        opts,
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(outcome.result == .applied)
    #expect(configurator.applications[0].plan == [1: stretched])
}

// MARK: - restore

@Test func restoreGoesStraightToTheConfigurator() throws {
    let configurator = CLIFakeConfigurator()
    let message = try runRestore(configurator: configurator)

    #expect(configurator.restoreCount == 1)
    #expect(configurator.applications.isEmpty)
    #expect(message.contains("restore"))
}

// MARK: - doctor

@Test func doctorReportsTheHiDPIConstantAndTheModeCounts() throws {
    let report = try Doctor.report(enumerator: fixture())

    #expect(report.contains("kCGDisplayResolution"))
    #expect(report.contains("3 modes"))
    // 2, not 1: `stretched` (1600x1200 pt -> 2560x1440 px) has a width scale
    // of 1.6, so `DisplayMode.isHiDPI` (scale > 1.0, established in Task 1)
    // counts it as HiDPI too, alongside `hidpi` itself. Doctor's job is to
    // report exactly what isHiDPI says; this asserts that, not a narrower
    // "HiDPI and not stretched" reading nothing in Doctor.swift computes.
    #expect(report.contains("2 HiDPI"))
}

@Test func doctorWarnsWhenNoHiDPIModesAreVisibleAtAll() throws {
    // The exact symptom of the spec §4.1 constant regression.
    let report = try Doctor.report(enumerator: fixture(current: native, modes: [native]))

    #expect(report.contains("no HiDPI modes"))
}
