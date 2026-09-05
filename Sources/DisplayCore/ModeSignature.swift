/// The persistable identity of a display mode.
///
/// Deliberately wider than it looks like it needs to be. Spec §4.3 measured ten
/// collision pairs on a single display using only point size, refresh, and a
/// HiDPI flag — pixel dimensions and the safety flag are what break those ties.
public struct ModeSignature: Codable, Hashable, Sendable {
    public let pointWidth: Int
    public let pointHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Integer millihertz. Never a Double: VRR panels report 59.94 Hz, and the
    /// private and public providers round it differently, so float equality
    /// across providers silently never matches. `0` means "unspecified", which
    /// is what built-in Apple displays report.
    public let refreshMilliHz: Int

    /// Whether the OS advertises this mode as usable for the desktop GUI.
    public let isSafe: Bool

    public init(
        pointWidth: Int,
        pointHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshMilliHz: Int,
        isSafe: Bool
    ) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshMilliHz = refreshMilliHz
        self.isSafe = isSafe
    }
}
