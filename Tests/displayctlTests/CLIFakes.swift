import CoreGraphics
import Foundation
// Deliberately not `import Testing`: this file uses no Testing API, and
// swift-testing's own `Confirmation` type (used for expected-call-count
// assertions) collides by name with displayctl's `Confirmation` — importing
// it here would make every bare `Confirmation` reference in this file
// ambiguous.
@testable import DisplayCore
@testable import displayctl

// Deliberately duplicated from Tests/DisplayCoreTests/Fakes.swift: SwiftPM test
// targets cannot see each other's sources, and adding a shared support target
// to ship two structs is a worse trade than twenty lines of duplication.

func cliMode(
    point: (Int, Int),
    pixel: (Int, Int),
    mHz: Int = 60_000,
    safe: Bool = true,
    stretched: Bool = false,
    id: Int32
) -> DisplayMode {
    DisplayMode(
        signature: ModeSignature(
            pointWidth: point.0, pointHeight: point.1,
            pixelWidth: pixel.0, pixelHeight: pixel.1,
            refreshMilliHz: mHz, isSafe: safe),
        ioDisplayModeID: id,
        isStretched: stretched,
        source: .publicAPI)
}

final class CLIFakeEnumerator: DisplayEnumerating, @unchecked Sendable {
    var ids: [CGDirectDisplayID] = [1]
    var modesByID: [CGDirectDisplayID: [DisplayMode]] = [:]
    var currentByID: [CGDirectDisplayID: DisplayMode] = [:]

    func onlineDisplayIDs() throws -> [CGDirectDisplayID] { ids }

    func device(for id: CGDirectDisplayID) throws -> DisplayDevice {
        guard ids.contains(id) else { throw DisplayError.noSuchDisplay(id) }
        return DisplayDevice(
            displayID: id, localizedName: "Display \(id)",
            isBuiltIn: false, isVirtual: false)
    }

    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode] {
        guard let modes = modesByID[id] else {
            throw DisplayError.modeEnumerationFailed(id)
        }
        return modes
    }

    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode {
        guard let mode = currentByID[id] else {
            throw DisplayError.currentModeUnavailable(id)
        }
        return mode
    }
}

final class CLIFakeConfigurator: DisplayConfiguring, @unchecked Sendable {
    private(set) var applications: [(plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope)] = []
    private(set) var restoreCount = 0

    /// Attempts at `apply`, counting failures as well as successes. Every
    /// existing call site leaves this at `applyAttempts == applications.count`
    /// (no script set), so nothing already written against this fake needs
    /// to change.
    private(set) var applyAttempts = 0

    /// A per-call script for `apply`, consumed one element per call in order:
    /// `nil` succeeds and is recorded exactly as `apply` always has been;
    /// a non-nil error is thrown instead, and that call is not recorded.
    /// Once the script runs out, every further call succeeds — the same
    /// behavior every existing call site (which never touches this property,
    /// leaving it empty) already sees. `runSet`'s first apply is always
    /// `begin`'s, so a script that should let that one through and fail only
    /// the ones after it starts with `nil`.
    var applyScript: [DisplayError?] = []
    private var applyScriptIndex = 0

    func apply(_ plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope) throws {
        applyAttempts += 1
        if applyScriptIndex < applyScript.count {
            let scripted = applyScript[applyScriptIndex]
            applyScriptIndex += 1
            if let scripted { throw scripted }
        }
        applications.append((plan, scope))
    }

    func restoreDefaults() throws { restoreCount += 1 }

    var scopeSequence: [ConfigurationScope] { applications.map(\.scope) }
}

final class ScriptedConfirmation: ConfirmationSource, @unchecked Sendable {
    private let answer: Confirmation
    private(set) var timeoutsSeen: [Int] = []

    init(_ answer: Confirmation) { self.answer = answer }

    func awaitConfirmation(timeoutSeconds: Int) -> Confirmation {
        timeoutsSeen.append(timeoutSeconds)
        return answer
    }
}

final class SteppingClock: MonotonicClock, @unchecked Sendable {
    private var seconds: Double = 0
    var nowSeconds: Double { seconds }
    func advance(by interval: Double) { seconds += interval }
}

/// A `ConfirmationSource` that advances a shared clock as a side effect of
/// answering, so a test can put the coordinator's deadline and the "user's"
/// answer on opposite sides of it (F1a). This is exactly how that bug
/// actually happens: the coordinator's clock starts inside `begin`, but the
/// prompt's own timer starts strictly later, so a `.confirmed` answer can
/// arrive after `nowSeconds >= change.deadline`.
final class ClockAdvancingConfirmation: ConfirmationSource, @unchecked Sendable {
    private let clock: SteppingClock
    private let advanceBy: Double
    private let answer: Confirmation

    init(clock: SteppingClock, advanceBy: Double, answer: Confirmation) {
        self.clock = clock
        self.advanceBy = advanceBy
        self.answer = answer
    }

    func awaitConfirmation(timeoutSeconds: Int) -> Confirmation {
        clock.advance(by: advanceBy)
        return answer
    }
}
