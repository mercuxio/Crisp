import CoreGraphics
import Foundation

/// A mode change that has been applied for the session but not yet confirmed.
///
/// `id` is a token minted by `begin` so the coordinator can recognize the same
/// change across repeated calls and tell whether it has already been resolved
/// (confirmed or reverted). It carries no meaning outside this file.
public struct PendingChange: Equatable, Sendable {
    let id: Int
    public let target: [CGDirectDisplayID: DisplayMode]
    public let previous: [CGDirectDisplayID: DisplayMode]
    public let deadline: Double
}

/// The confirm-or-revert state machine of spec §8.2.
///
/// Holds no timer and no UI. Callers drive `expireIfNeeded` from whatever run
/// loop they have — a countdown panel in the app, a polling prompt in the CLI —
/// which is also why every branch of this is testable in microseconds.
///
/// Not thread-safe. `nextChangeID` and `resolvedChangeIDs` are plain mutable
/// state with no synchronization, so every call — `begin`, `confirm`,
/// `revert`, `expireIfNeeded` — must be made from a single execution context
/// (e.g. the main actor, or a single-threaded polling loop). A driver that
/// calls into this from more than one task or thread concurrently can race on
/// that state; that is the caller's obligation to prevent, not this type's.
///
/// `expireIfNeeded` and `secondsRemaining` have no caller on this branch:
/// `displayctl set` drives the revert entirely off `awaitConfirmation`
/// returning, which is legitimate because that wait is itself bounded by the
/// same timeout. Both are well covered by unit tests, but neither has run
/// against a real countdown driven by a run loop — they exist for the
/// milestone-3 menu bar app's countdown panel, so do not treat them as
/// field-proven until something actually calls them end to end.
public final class RevertCoordinator {
    private let configurator: DisplayConfiguring
    private let clock: MonotonicClock
    private let window: TimeInterval
    private var nextChangeID = 0
    private var resolvedChangeIDs: Set<Int> = []

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

        let id = nextChangeID
        nextChangeID += 1
        return PendingChange(
            id: id,
            target: target,
            previous: previous,
            deadline: clock.nowSeconds + window)
    }

    /// The user can see the screen. Stop the countdown.
    ///
    /// The scope is the caller's: confirming means "keep this now", which is
    /// not the same as "keep this across reboots". Only an explicit request for
    /// permanence should escalate past `.session` — see spec §8.1. The default
    /// is therefore `.session`: a call that can outlive a reboot needs the
    /// caller to say so explicitly, not fall into permanence by omission.
    ///
    /// Refused once the change has already been resolved — confirmed, reverted
    /// by hand, or expired — so a confirm that arrives late (or races a revert)
    /// can never reapply a mode the user already escaped.
    public func confirm(
        _ change: PendingChange,
        scope: ConfigurationScope = .session
    ) throws {
        guard !resolvedChangeIDs.contains(change.id) else {
            throw DisplayError.confirmationExpired
        }
        guard clock.nowSeconds < change.deadline else {
            throw DisplayError.confirmationExpired
        }
        try configurator.apply(change.target, scope: scope)
        resolvedChangeIDs.insert(change.id)
    }

    /// Put it back. Session scope, because the previous mode's own permanence
    /// was already settled when it was applied.
    ///
    /// A no-op if the change was already resolved. Only marked resolved once
    /// `apply` returns without throwing — if it throws, nothing is recorded,
    /// so a subsequent retry (from `expireIfNeeded` or a direct call) tries
    /// the apply again instead of being silently treated as done.
    public func revert(_ change: PendingChange) throws {
        guard !resolvedChangeIDs.contains(change.id) else { return }
        try configurator.apply(change.previous, scope: .session)
        resolvedChangeIDs.insert(change.id)
    }

    /// Reverts if the deadline has passed. Returns whether it did.
    ///
    /// Returns `false` — without touching the configurator — for a change
    /// that was already resolved, so polling this after the first successful
    /// revert is a no-op rather than a repeat transaction.
    @discardableResult
    public func expireIfNeeded(_ change: PendingChange) throws -> Bool {
        guard !resolvedChangeIDs.contains(change.id) else { return false }
        guard clock.nowSeconds >= change.deadline else { return false }
        try revert(change)
        return true
    }

    public func secondsRemaining(for change: PendingChange) -> Int {
        max(0, Int((change.deadline - clock.nowSeconds).rounded(.up)))
    }
}
