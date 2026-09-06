import CoreGraphics

/// Pure conversion logic, extracted from the CoreGraphics calls so it can be
/// tested without a display attached. `CGDisplayMode` cannot be constructed in
/// a test, so anything worth testing takes primitives instead.
public enum ModeConversion {
    public static func signature(
        pointWidth: Int,
        pointHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRateHz: Double,
        isUsableForDesktopGUI: Bool
    ) -> ModeSignature {
        ModeSignature(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            // Round, never truncate: 59.9999 Hz is 60 Hz reported imprecisely,
            // and truncation would put it 1 mHz outside its own tolerance band.
            refreshMilliHz: Int((refreshRateHz * 1000).rounded()),
            isSafe: isUsableForDesktopGUI)
    }

    /// Non-square pixels: the point aspect and the pixel aspect disagree.
    public static func isStretched(
        pointWidth: Int,
        pointHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Bool {
        guard pointHeight > 0, pixelHeight > 0 else { return false }
        let pointAspect = Double(pointWidth) / Double(pointHeight)
        let pixelAspect = Double(pixelWidth) / Double(pixelHeight)
        // 1% tolerance: scaled modes round their point dimensions, so an exact
        // comparison reports false positives on every 1.5x-class mode.
        return abs(pointAspect - pixelAspect) / pointAspect > 0.01
    }

    /// Drops repeated signatures, keeping the first occurrence.
    ///
    /// The widened signature makes collisions rare, but the OS is free to
    /// report the same mode twice and a duplicated menu entry looks like a bug.
    public static func deduplicated(_ modes: [DisplayMode]) -> [DisplayMode] {
        var seen = Set<ModeSignature>()
        return modes.filter { seen.insert($0.signature).inserted }
    }
}

/// The real read path.
public struct CoreGraphicsEnumerator: DisplayEnumerating {
    public init() {}

    public func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else {
            throw DisplayError.modeEnumerationFailed(0)
        }
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            throw DisplayError.modeEnumerationFailed(0)
        }
        return Array(ids.prefix(Int(count)))
    }

    public func device(for id: CGDirectDisplayID) throws -> DisplayDevice {
        let ids = try onlineDisplayIDs()
        guard let position = ids.firstIndex(of: id) else {
            throw DisplayError.noSuchDisplay(id)
        }

        let builtIn = CGDisplayIsBuiltin(id) != 0
        // Real EDID product names need IOKit and arrive with persistent
        // identity in the next plan. A positional label is enough for a CLI
        // that addresses displays by index.
        let name = builtIn ? "Built-in Display" : "Display \(position + 1)"

        return DisplayDevice(
            displayID: id,
            localizedName: name,
            isBuiltIn: builtIn,
            // Sidecar, AirPlay and DisplayLink targets report as mirrored or
            // asleep sources; treating "not online-and-active" as virtual is
            // sufficient for the CLI.
            isVirtual: CGDisplayIsAsleep(id) == 0 && CGDisplayIsActive(id) == 0)
    }

    public func modes(for id: CGDirectDisplayID) throws -> [DisplayMode] {
        // SPEC §4.1 — DO NOT rewrite this key as a string literal.
        // `kCGDisplayShowDuplicateLowResolutionModes` has the underlying value
        // "kCGDisplayResolution". Passing the symbol's NAME instead of the
        // symbol silently returns 42 modes with zero HiDPI entries instead of
        // 88 with 46, with no error. The guard test in
        // CoreGraphicsEnumeratorTests pins this.
        let options = [
            kCGDisplayShowDuplicateLowResolutionModes as String: true
        ] as CFDictionary

        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else {
            throw DisplayError.modeEnumerationFailed(id)
        }

        return ModeConversion.deduplicated(raw.map(convert))
    }

    public func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode {
        guard let raw = CGDisplayCopyDisplayMode(id) else {
            throw DisplayError.currentModeUnavailable(id)
        }
        return convert(raw)
    }

    private func convert(_ raw: CGDisplayMode) -> DisplayMode {
        DisplayMode(
            signature: ModeConversion.signature(
                pointWidth: raw.width,
                pointHeight: raw.height,
                pixelWidth: raw.pixelWidth,
                pixelHeight: raw.pixelHeight,
                refreshRateHz: raw.refreshRate,
                isUsableForDesktopGUI: raw.isUsableForDesktopGUI()),
            ioDisplayModeID: raw.ioDisplayModeID,
            isStretched: ModeConversion.isStretched(
                pointWidth: raw.width,
                pointHeight: raw.height,
                pixelWidth: raw.pixelWidth,
                pixelHeight: raw.pixelHeight),
            source: .publicAPI)
    }
}
