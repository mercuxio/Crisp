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

    func apply(_ plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope) throws {
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
