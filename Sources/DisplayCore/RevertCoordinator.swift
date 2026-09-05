import CoreGraphics
import Foundation

/// A mode change that has been applied for the session but not yet confirmed.
public struct PendingChange: Equatable, Sendable {
    public let target: [CGDirectDisplayID: DisplayMode]
    public let previous: [CGDirectDisplayID: DisplayMode]
    public let deadline: Double
}

/// The confirm-or-revert state machine of spec §8.2.
///
/// Holds no timer and no UI. Callers drive `expireIfNeeded` from whatever run
/// loop they have — a countdown panel in the app, a polling prompt in the CLI —
/// which is also why every branch of this is testable in microseconds.
public final class RevertCoordinator {
    private let configurator: DisplayConfiguring
    private let clock: MonotonicClock
    private let window: TimeInterval

    public init(
        configurator: DisplayConfiguring,
        clock: MonotonicClock,
        window: TimeInterval = 15
    ) {
        self.configurator = configurator
        self.clock = clock
        self.window = window
    }

    /// Applies the change for the session only and starts the clock.
    public func begin(
        target: [CGDirectDisplayID: DisplayMode],
        previous: [CGDirectDisplayID: DisplayMode]
    ) throws -> PendingChange {
        // Apply first, then hand back the pending change. If this throws, the
        // caller has nothing to confirm or revert, which is correct — nothing
        // happened.
        try configurator.apply(target, scope: .session)

        return PendingChange(
            target: target,
            previous: previous,
            deadline: clock.nowSeconds + window)
    }

    /// The user can see the screen. Stop the countdown.
    ///
    /// The scope is the caller's: confirming means "keep this now", which is
    /// not the same as "keep this across reboots". Only an explicit request for
    /// permanence should escalate past `.session` — see spec §8.1.
    public func confirm(
        _ change: PendingChange,
        scope: ConfigurationScope = .permanent
    ) throws {
        guard clock.nowSeconds < change.deadline else {
            throw DisplayError.confirmationExpired
        }
        try configurator.apply(change.target, scope: scope)
    }

    /// Put it back. Session scope, because the previous mode's own permanence
    /// was already settled when it was applied.
    public func revert(_ change: PendingChange) throws {
        try configurator.apply(change.previous, scope: .session)
    }

    /// Reverts if the deadline has passed. Returns whether it did.
    @discardableResult
    public func expireIfNeeded(_ change: PendingChange) throws -> Bool {
        guard clock.nowSeconds >= change.deadline else { return false }
        try revert(change)
        return true
    }

    public func secondsRemaining(for change: PendingChange) -> Int {
        max(0, Int((change.deadline - clock.nowSeconds).rounded(.up)))
    }
}
