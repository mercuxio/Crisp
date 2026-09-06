import CoreGraphics
@testable import DisplayCore

/// Builds a mode without the ceremony, for tests that do not care about most
/// of the fields.
func makeMode(
    point: (Int, Int),
    pixel: (Int, Int),
    mHz: Int = 60_000,
    safe: Bool = true,
    id: Int32 = 1,
    stretched: Bool = false,
    source: ModeSource = .publicAPI
) -> DisplayMode {
    DisplayMode(
        signature: ModeSignature(
            pointWidth: point.0, pointHeight: point.1,
            pixelWidth: pixel.0, pixelHeight: pixel.1,
            refreshMilliHz: mHz, isSafe: safe),
        ioDisplayModeID: id,
        isStretched: stretched,
        source: source)
}

/// A scripted `DisplayEnumerating` that never touches CoreGraphics.
final class FakeEnumerator: DisplayEnumerating, @unchecked Sendable {
    var devices: [DisplayDevice]
    var modesByDisplay: [CGDirectDisplayID: [DisplayMode]]
    var currentByDisplay: [CGDirectDisplayID: DisplayMode]
    var enumerationError: DisplayError?

    init(
        devices: [DisplayDevice] = [],
        modesByDisplay: [CGDirectDisplayID: [DisplayMode]] = [:],
        currentByDisplay: [CGDirectDisplayID: DisplayMode] = [:]
    ) {
        self.devices = devices
        self.modesByDisplay = modesByDisplay
        self.currentByDisplay = currentByDisplay
    }

    func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        if let enumerationError { throw enumerationError }
        return devices.map(\.displayID)
    }

    func device(for id: CGDirectDisplayID) throws -> DisplayDevice {
        guard let hit = devices.first(where: { $0.displayID == id }) else {
            throw DisplayError.noSuchDisplay(id)
        }
        return hit
    }

    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode] {
        if let enumerationError { throw enumerationError }
        guard let hit = modesByDisplay[id] else {
            throw DisplayError.modeEnumerationFailed(id)
        }
        return hit
    }

    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode {
        guard let hit = currentByDisplay[id] else {
            throw DisplayError.currentModeUnavailable(id)
        }
        return hit
    }
}

/// Records what it was asked to do and never touches a real display.
final class FakeConfigurator: DisplayConfiguring, @unchecked Sendable {
    struct Application: Equatable {
        let plan: [CGDirectDisplayID: DisplayMode]
        let scope: ConfigurationScope
    }

    private(set) var applications: [Application] = []
    private(set) var restoreCount = 0

    /// Thrown by the next `apply` call, then cleared.
    var nextApplyError: DisplayError?

    func apply(
        _ plan: [CGDirectDisplayID: DisplayMode],
        scope: ConfigurationScope
    ) throws {
        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }
        applications.append(Application(plan: plan, scope: scope))
    }

    func restoreDefaults() throws {
        restoreCount += 1
    }

    var scopeSequence: [ConfigurationScope] { applications.map(\.scope) }
}

/// A clock that only moves when a test moves it.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private var seconds: Double

    init(startingAt seconds: Double = 0) {
        self.seconds = seconds
    }

    var nowSeconds: Double { seconds }

    func advance(by interval: Double) {
        seconds += interval
    }
}
