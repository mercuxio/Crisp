/// What the user asked for, as opposed to what was previously recorded.
public struct ModeQuery: Equatable, Sendable {
    public var pointWidth: Int
    public var pointHeight: Int

    /// `nil` means "any refresh rate", which ranks highest-first.
    public var refreshMilliHz: Int?

    /// `nil` means "prefer HiDPI but accept native".
    public var hiDPI: Bool?

    public var includeUnsafe: Bool
    public var includeStretched: Bool

    public init(
        pointWidth: Int,
        pointHeight: Int,
        refreshMilliHz: Int? = nil,
        hiDPI: Bool? = nil,
        includeUnsafe: Bool = false,
        includeStretched: Bool = false
    ) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshMilliHz = refreshMilliHz
        self.hiDPI = hiDPI
        self.includeUnsafe = includeUnsafe
        self.includeStretched = includeStretched
    }
}

/// The outcome of resolving a *recorded* signature. There is deliberately no
/// "approximate" case beyond `tolerant`, which only ever bridges sub-hertz
/// refresh drift.
public enum ModeMatch: Equatable, Sendable {
    case exact(DisplayMode)
    case tolerant(DisplayMode)
    case unavailable
}

public enum ModeMatcher {
    /// Spec §10. Wide enough to bridge 59.94 vs 60.00 Hz, narrow enough that
    /// 60 Hz and 75 Hz can never be confused.
    public static let refreshToleranceMilliHz = 1_000

    /// Strict resolution of a previously recorded signature.
    public static func match(
        _ wanted: ModeSignature,
        in modes: [DisplayMode]
    ) -> ModeMatch {
        if let hit = modes.first(where: { $0.signature == wanted }) {
            return .exact(hit)
        }

        // A refresh rate of 0 means "unspecified" and can only ever match
        // another unspecified rate — which the exact check above already
        // handled. Bailing here stops 0 from tolerance-matching 900 mHz.
        guard wanted.refreshMilliHz != 0 else { return .unavailable }

        let candidates = modes.filter {
            $0.pointWidth == wanted.pointWidth
                && $0.pointHeight == wanted.pointHeight
                && $0.pixelWidth == wanted.pixelWidth
                && $0.pixelHeight == wanted.pixelHeight
                && $0.isSafe == wanted.isSafe
                && $0.refreshMilliHz != 0
                && abs($0.refreshMilliHz - wanted.refreshMilliHz) <= refreshToleranceMilliHz
        }

        guard let nearest = candidates.min(by: {
            let a = abs($0.refreshMilliHz - wanted.refreshMilliHz)
            let b = abs($1.refreshMilliHz - wanted.refreshMilliHz)
            // Tie-break on the higher refresh rate so the result is stable
            // regardless of enumeration order.
            return a == b ? $0.refreshMilliHz > $1.refreshMilliHz : a < b
        }) else {
            return .unavailable
        }

        return .tolerant(nearest)
    }

    /// Ranked resolution of a user request. Best candidate first; empty means
    /// the display cannot do it.
    public static func resolve(
        _ query: ModeQuery,
        in modes: [DisplayMode]
    ) -> [DisplayMode] {
        let candidates = modes.filter { mode in
            guard mode.pointWidth == query.pointWidth,
                  mode.pointHeight == query.pointHeight else { return false }
            if !query.includeUnsafe && !mode.isSafe { return false }
            if !query.includeStretched && mode.isStretched { return false }
            if let wantHiDPI = query.hiDPI, mode.isHiDPI != wantHiDPI { return false }
            if let wantHz = query.refreshMilliHz, mode.refreshMilliHz != wantHz { return false }
            return true
        }

        return candidates.sorted { lhs, rhs in
            // HiDPI first: it is what the user almost always wants and is the
            // whole reason this app exists.
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            if lhs.refreshMilliHz != rhs.refreshMilliHz {
                return lhs.refreshMilliHz > rhs.refreshMilliHz
            }
            // Final tie-break for a deterministic order.
            return lhs.ioDisplayModeID < rhs.ioDisplayModeID
        }
    }
}
