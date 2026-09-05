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
