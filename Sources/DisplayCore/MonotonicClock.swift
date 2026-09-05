import Foundation

/// Time, injected.
///
/// A monotonic source specifically: the revert deadline must not move when the
/// wall clock is adjusted, or an NTP correction mid-countdown either reverts a
/// good mode early or strands a bad one.
public protocol MonotonicClock: Sendable {
    var nowSeconds: Double { get }
}

public struct SystemClock: MonotonicClock {
    public init() {}

    /// Time since boot; unaffected by wall-clock adjustments.
    public var nowSeconds: Double { ProcessInfo.processInfo.systemUptime }
}
