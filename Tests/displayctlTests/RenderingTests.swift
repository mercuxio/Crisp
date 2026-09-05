import Foundation
import Testing
@testable import DisplayCore
@testable import displayctl

private let device = DisplayDevice(
    displayID: 1, localizedName: "Display 1", isBuiltIn: false, isVirtual: false)

private let hidpi = DisplayMode(
    signature: ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshMilliHz: 60_000, isSafe: true),
    ioDisplayModeID: 48, isStretched: false, source: .publicAPI)

private let native = DisplayMode(
    signature: ModeSignature(
        pointWidth: 1920, pointHeight: 1080,
        pixelWidth: 1920, pixelHeight: 1080,
        refreshMilliHz: 59_940, isSafe: true),
    ioDisplayModeID: 12, isStretched: false, source: .publicAPI)

@Test func listMarksTheCurrentMode() {
    let text = Renderer.renderList(
        device: device, index: 1, modes: [hidpi, native], current: hidpi)

    let currentLine = try? #require(
        text.split(separator: "\n").first { $0.contains("2560 x 1440") })
    #expect(currentLine?.contains("*") == true)

    let otherLine = text.split(separator: "\n").first { $0.contains("1920 x 1080") }
    #expect(otherLine?.contains("*") == false)
}

@Test func listShowsPixelDimensionsForHiDPIModesOnly() {
    let text = Renderer.renderList(
        device: device, index: 1, modes: [hidpi, native], current: native)

    #expect(text.contains("5120 x 2880"))
    // A native mode's pixel size equals its point size; repeating it is noise.
    #expect(!text.contains("1920 x 1080 px"))
}

@Test func listShowsRefreshRateWithoutTrailingZeroNoise() {
    let text = Renderer.renderList(
        device: device, index: 1, modes: [hidpi, native], current: hidpi)

    #expect(text.contains("60 Hz"))
    #expect(text.contains("59.94 Hz"))
}

@Test func listOmitsRefreshWhenTheDisplayDoesNotReportIt() {
    let unspecified = DisplayMode(
        signature: ModeSignature(
            pointWidth: 1512, pointHeight: 982,
            pixelWidth: 3024, pixelHeight: 1964,
            refreshMilliHz: 0, isSafe: true),
        ioDisplayModeID: 3, isStretched: false, source: .publicAPI)

    let text = Renderer.renderList(
        device: device, index: 1, modes: [unspecified], current: unspecified)

    #expect(!text.contains("Hz"))
}

@Test func jsonOutputIsStableAndParsable() throws {
    let json = try Renderer.renderListJSON(
        [ListedDisplay(device: device, index: 1, modes: [hidpi], current: hidpi)])

    let parsed = try #require(
        try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    #expect(parsed.count == 1)

    let modes = try #require(parsed[0]["modes"] as? [[String: Any]])
    #expect(modes[0]["pointWidth"] as? Int == 2560)
    #expect(modes[0]["pixelWidth"] as? Int == 5120)
    #expect(modes[0]["refreshMilliHz"] as? Int == 60_000)
    #expect(modes[0]["isCurrent"] as? Bool == true)
}
