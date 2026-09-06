import CoreGraphics

/// How long a configuration change survives.
public enum ConfigurationScope: Equatable, Sendable {
    /// Lasts until logout. The only scope a change is ever applied in first —
    /// spec §8.1 — so that an unreadable result is always escapable.
    case session

    /// Survives logout and reboot. Only ever used after confirmation.
    case permanent
}

/// Everything DisplayCore writes to the windowing system.
///
/// `apply` takes the whole plan because a multi-display change must land in a
/// single transaction (spec §8.1); splitting it across calls would re-lay-out
/// the desktop once per display.
public protocol DisplayConfiguring: AnyObject, Sendable {
    func apply(_ plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope) throws
    func restoreDefaults() throws
}
