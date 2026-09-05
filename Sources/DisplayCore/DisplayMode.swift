/// Which provider surfaced a mode.
public enum ModeSource: String, Codable, Hashable, Sendable {
    case publicAPI
    case privateCGS
}

/// A display mode, as offered to the user.
public struct DisplayMode: Identifiable, Hashable, Sendable {
    public let signature: ModeSignature

    /// `CGDisplayMode.ioDisplayModeID`. An O(1) apply hint only — spec §4.2
    /// verified it equals the CGS table index, but it is not stable across
    /// EDID or OS changes, so it is always validated against the signature
    /// before use and never trusted on its own.
    public let ioDisplayModeID: Int32

    /// Non-square pixels. Only the private CGS provider surfaces these.
    public let isStretched: Bool

    public let source: ModeSource

    public var id: ModeSignature { signature }

    public init(
        signature: ModeSignature,
        ioDisplayModeID: Int32,
        isStretched: Bool,
        source: ModeSource
    ) {
        self.signature = signature
        self.ioDisplayModeID = ioDisplayModeID
        self.isStretched = isStretched
        self.source = source
    }

    public var pointWidth: Int { signature.pointWidth }
    public var pointHeight: Int { signature.pointHeight }
    public var pixelWidth: Int { signature.pixelWidth }
    public var pixelHeight: Int { signature.pixelHeight }
    public var refreshMilliHz: Int { signature.refreshMilliHz }
    public var isSafe: Bool { signature.isSafe }

    /// Horizontal backing-store scale. Derived, never stored: a stored copy is
    /// one more thing that can disagree with the dimensions it came from.
    public var scale: Double {
        guard signature.pointWidth > 0 else { return 1.0 }
        return Double(signature.pixelWidth) / Double(signature.pointWidth)
    }

    public var isHiDPI: Bool { scale > 1.0 }

    /// For display only. Compare `refreshMilliHz`, never this.
    public var refreshHz: Double { Double(signature.refreshMilliHz) / 1000.0 }
}
