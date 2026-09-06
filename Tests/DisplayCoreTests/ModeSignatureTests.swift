import Foundation
import Testing
@testable import DisplayCore

@Test func signatureDistinguishesTheSafetyFlagCollision() {
    // Spec §4.3: CGS indices 47 (flags 0x1) and 97 (flags 0x40000000) are
    // byte-identical apart from the safety flag. The narrow signature that
    // {point size, refresh, isHiDPI} would produce collides here; ours must not.
    let safe = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshMilliHz: 60_000, isSafe: true)
    let unsafe = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshMilliHz: 60_000, isSafe: false)

    #expect(safe != unsafe)
    #expect(safe.hashValue != unsafe.hashValue)
}

@Test func signatureDistinguishesHiDPIFromNative() {
    let hidpi = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshMilliHz: 60_000, isSafe: true)
    let native = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshMilliHz: 60_000, isSafe: true)

    #expect(hidpi != native)
}

@Test func signatureRoundTripsThroughJSON() throws {
    let original = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshMilliHz: 59_940, isSafe: true)

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ModeSignature.self, from: data)

    #expect(decoded == original)
}

@Test func modeDerivesItsAccessorsFromTheSignature() {
    let mode = DisplayMode(
        signature: ModeSignature(
            pointWidth: 2560, pointHeight: 1440,
            pixelWidth: 5120, pixelHeight: 2880,
            refreshMilliHz: 59_940, isSafe: true),
        ioDisplayModeID: 48,
        isStretched: false,
        source: .publicAPI)

    #expect(mode.pointWidth == 2560)
    #expect(mode.pixelHeight == 2880)
    #expect(mode.scale == 2.0)
    #expect(mode.isHiDPI)
    #expect(mode.id == mode.signature)
}

@Test func aStretchedModeIsNotConsideredHiDPI() {
    // Non-square pixels: 1.5x horizontally, 1.0x vertically. `scale` is defined
    // on the horizontal axis, so guard that this does not masquerade as HiDPI.
    let mode = DisplayMode(
        signature: ModeSignature(
            pointWidth: 1600, pointHeight: 900,
            pixelWidth: 1600, pixelHeight: 900,
            refreshMilliHz: 60_000, isSafe: false),
        ioDisplayModeID: 97,
        isStretched: true,
        source: .privateCGS)

    #expect(mode.scale == 1.0)
    #expect(!mode.isHiDPI)
    #expect(mode.isStretched)
}
