import CoreGraphics

/// A physical display as seen in the current session.
///
/// `displayID` is session-scoped: it is reassigned on replug and sometimes
/// across sleep/wake, so it is never persisted (spec §9). Persistent identity
/// arrives with presets in the next plan.
public struct DisplayDevice: Identifiable, Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let localizedName: String
    public let isBuiltIn: Bool
    public let isVirtual: Bool

    public var id: CGDirectDisplayID { displayID }

    public init(
        displayID: CGDirectDisplayID,
        localizedName: String,
        isBuiltIn: Bool,
        isVirtual: Bool
    ) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.isBuiltIn = isBuiltIn
        self.isVirtual = isVirtual
    }
}
