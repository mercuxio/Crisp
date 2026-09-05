import CoreGraphics

/// Everything DisplayCore reads from the windowing system.
///
/// Narrow on purpose: this is the seam that lets every consumer be tested
/// against a fake without touching the developer's actual screen.
public protocol DisplayEnumerating: Sendable {
    func onlineDisplayIDs() throws -> [CGDirectDisplayID]
    func device(for id: CGDirectDisplayID) throws -> DisplayDevice
    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode]
    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode
}
