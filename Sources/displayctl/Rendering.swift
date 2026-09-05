import Foundation
import DisplayCore

/// One display's worth of listing, ready to render.
public struct ListedDisplay: Sendable {
    public let device: DisplayDevice
    public let index: Int
    public let modes: [DisplayMode]
    public let current: DisplayMode?

    public init(device: DisplayDevice, index: Int, modes: [DisplayMode], current: DisplayMode?) {
        self.device = device
        self.index = index
        self.modes = modes
        self.current = current
    }
}

public enum Renderer {
    public static func renderList(
        device: DisplayDevice,
        index: Int,
        modes: [DisplayMode],
        current: DisplayMode?
    ) -> String {
        var lines: [String] = []
        lines.append("[\(index)] \(device.localizedName)\(device.isBuiltIn ? " (built-in)" : "")")

        for mode in modes {
            let marker = mode.signature == current?.signature ? "*" : " "
            var parts = ["  \(marker) \(mode.pointWidth) x \(mode.pointHeight)"]

            if mode.isHiDPI {
                parts.append("(\(mode.pixelWidth) x \(mode.pixelHeight) HiDPI)")
            }
            if mode.refreshMilliHz > 0 {
                parts.append(formatRefresh(mode.refreshMilliHz))
            }
            if mode.isStretched { parts.append("[stretched]") }
            if !mode.isSafe { parts.append("[unsafe]") }

            lines.append(parts.joined(separator: "  "))
        }

        return lines.joined(separator: "\n")
    }

    /// `60 Hz`, not `60.0 Hz`; `59.94 Hz`, not `59.94000000001 Hz`.
    static func formatRefresh(_ milliHz: Int) -> String {
        if milliHz % 1000 == 0 { return "\(milliHz / 1000) Hz" }
        let hz = Double(milliHz) / 1000.0
        return String(format: "%.2f Hz", hz)
    }

    public static func renderListJSON(_ displays: [ListedDisplay]) throws -> String {
        let payload = displays.map { listed -> [String: Any] in
            [
                "index": listed.index,
                "displayID": Int(listed.device.displayID),
                "name": listed.device.localizedName,
                "isBuiltIn": listed.device.isBuiltIn,
                "modes": listed.modes.map { mode -> [String: Any] in
                    [
                        "pointWidth": mode.pointWidth,
                        "pointHeight": mode.pointHeight,
                        "pixelWidth": mode.pixelWidth,
                        "pixelHeight": mode.pixelHeight,
                        "refreshMilliHz": mode.refreshMilliHz,
                        "isSafe": mode.isSafe,
                        "isHiDPI": mode.isHiDPI,
                        "isStretched": mode.isStretched,
                        "ioDisplayModeID": Int(mode.ioDisplayModeID),
                        "isCurrent": mode.signature == listed.current?.signature,
                    ]
                },
            ]
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func describeMode(_ mode: DisplayMode) -> String {
        var text = "\(mode.pointWidth) x \(mode.pointHeight)"
        if mode.isHiDPI { text += " (\(mode.pixelWidth) x \(mode.pixelHeight) HiDPI)" }
        if mode.refreshMilliHz > 0 { text += " @ \(formatRefresh(mode.refreshMilliHz))" }
        return text
    }

    public static func renderSetPrompt(_ mode: DisplayMode, seconds: Int) -> String {
        """
        Switched to \(describeMode(mode)).

        Keep this resolution? [y/N] — reverting automatically in \(seconds)s.
        """
    }

    public static func renderApplied(_ mode: DisplayMode, permanent: Bool) -> String {
        permanent
            ? "Keeping \(describeMode(mode)). It will survive a reboot."
            : "Keeping \(describeMode(mode)) until you log out."
    }

    public static func renderReverted(_ previous: DisplayMode) -> String {
        "Reverted to \(describeMode(previous))."
    }

    public static func renderAlreadyActive(_ mode: DisplayMode) -> String {
        "Already at \(describeMode(mode)). Nothing to do."
    }

    public static func describe(_ error: DisplayError) -> String {
        switch error {
        case .noSuchDisplay(let id):
            return "no display with ID \(id)"
        case .modeEnumerationFailed(let id):
            return "could not read the mode list for display \(id)"
        case .currentModeUnavailable(let id):
            return "could not read the current mode of display \(id)"
        case .configurationFailed(let code):
            return "the display configuration was rejected (CoreGraphics error \(code))"
        case .completionTimedOut(let seconds):
            return "the display configuration did not confirm completion within \(Int(seconds))s — "
                + "it may or may not have taken effect; run 'displayctl restore' to recover"
        case .modeUnavailable(let signature):
            return "the saved mode \(signature.pointWidth)x\(signature.pointHeight) is no longer available"
        case .noMatchingMode(let width, let height):
            return "this display has no \(width)x\(height) mode — run 'displayctl list --all' to see what it does have"
        case .confirmationExpired:
            // Must not claim a revert happened: the renderer has no way to
            // know whether the attempted revert that follows an expired (or
            // otherwise failed) confirmation actually succeeded. Same
            // discipline as `.completionTimedOut` above.
            return "the confirmation deadline passed before your answer was recorded — "
                + "the display may still be on the new mode; run 'displayctl restore' to recover"
        }
    }
}
