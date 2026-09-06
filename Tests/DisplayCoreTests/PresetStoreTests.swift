import Foundation
import Testing

@testable import DisplayCore

/// A directory of its own per test, removed on the way out. Nothing here ever
/// touches the developer's real Application Support folder.
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PitchStoreTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

private let signature = ModeSignature(
    pointWidth: 2560, pointHeight: 1440,
    pixelWidth: 5120, pixelHeight: 2880,
    refreshMilliHz: 60_000, isSafe: true)

private func stored(name: String = "Studio Display") -> StoredDisplay {
    StoredDisplay(
        identity: DisplayIdentity(uuid: "A1", hardwareKey: "1:2:3"),
        lastSeenName: name,
        recents: [signature])
}

@Test func aMissingFileLoadsAsAnEmptyStore() throws {
    try withTemporaryDirectory { directory in
        let store = FilePresetStore(url: directory.appendingPathComponent("presets.json"))

        let loaded = try store.load()

        #expect(loaded.displays.isEmpty)
        #expect(loaded.schemaVersion == PresetStore.currentSchemaVersion)
    }
}

@Test func aSavedStoreLoadsBackIdentically() throws {
    try withTemporaryDirectory { directory in
        let url = directory.appendingPathComponent("presets.json")
        let store = FilePresetStore(url: url)
        let original = PresetStore(displays: [stored()])

        try store.save(original)
        // A second instance, because the point is that it survives the process.
        let loaded = try FilePresetStore(url: url).load()

        #expect(loaded == original)
    }
}

@Test func savingCreatesTheContainingDirectory() throws {
    try withTemporaryDirectory { directory in
        // Nothing has created Application Support/Pitch on a fresh install.
        let url = directory.appendingPathComponent("nested/deeper/presets.json")

        try FilePresetStore(url: url).save(PresetStore(displays: [stored()]))

        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

@Test func savingLeavesNoTemporaryFileBehind() throws {
    try withTemporaryDirectory { directory in
        let url = directory.appendingPathComponent("presets.json")
        let store = FilePresetStore(url: url)

        try store.save(PresetStore(displays: [stored()]))
        try store.save(PresetStore(displays: [stored(name: "Second")]))

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(left == ["presets.json"])
    }
}

@Test func aCorruptFileThrowsRatherThanReadingAsEmpty() throws {
    // Silently returning an empty store would let the next save overwrite data
    // that a human might still be able to rescue by hand.
    try withTemporaryDirectory { directory in
        let url = directory.appendingPathComponent("presets.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: url)

        #expect(throws: (any Error).self) { try FilePresetStore(url: url).load() }
    }
}

@Test func aStoreFromTheFutureIsRefusedRatherThanMisread() throws {
    try withTemporaryDirectory { directory in
        let url = directory.appendingPathComponent("presets.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":99,"displays":[]}"#.utf8).write(to: url)

        #expect(throws: DisplayError.storeSchemaUnsupported(version: 99)) {
            try FilePresetStore(url: url).load()
        }
    }
}

@Test func aDisplayEntryDecodesWithoutFieldsThatArriveLater() throws {
    // Favourites, hidden modes and auto-restore all land in this same file. An
    // entry written today must still decode once they exist, and vice versa.
    let json = Data(
        #"{"identity":{"hardwareKey":"1:2:3"},"lastSeenName":"Display 1"}"#.utf8)

    let decoded = try JSONDecoder().decode(StoredDisplay.self, from: json)

    #expect(decoded.recents.isEmpty)
    #expect(decoded.lastSeenName == "Display 1")
}

@Test func theStoreFindsADisplayByIdentityAndIgnoresStrangers() {
    let mine = DisplayIdentity(uuid: "A1", hardwareKey: "1:2:3")
    let other = DisplayIdentity(uuid: "B2", hardwareKey: "9:9:9")
    let store = PresetStore(displays: [stored()])

    #expect(store.entry(matching: mine)?.recents == [signature])
    #expect(store.entry(matching: other) == nil)
}
