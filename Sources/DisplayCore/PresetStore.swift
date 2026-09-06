import Foundation

/// What Pitch remembers about one display between launches (spec §10).
///
/// Favourites, hidden modes and auto-restore all land here later. `init(from:)`
/// is written by hand rather than synthesised so that a file saved today still
/// decodes once they exist — and, more to the point, so a file saved by a later
/// version still decodes here.
public struct StoredDisplay: Codable, Equatable, Sendable {
    public var identity: DisplayIdentity

    /// Only ever shown to a human: which entry is which, if they open the file.
    /// Never matched on — a name is not an identity.
    public var lastSeenName: String

    /// Newest first, capped by the caller.
    public var recents: [ModeSignature]

    public init(identity: DisplayIdentity, lastSeenName: String, recents: [ModeSignature] = []) {
        self.identity = identity
        self.lastSeenName = lastSeenName
        self.recents = recents
    }

    enum CodingKeys: String, CodingKey {
        case identity
        case lastSeenName
        case recents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(DisplayIdentity.self, forKey: .identity)
        lastSeenName = try container.decodeIfPresent(String.self, forKey: .lastSeenName) ?? ""
        recents = try container.decodeIfPresent([ModeSignature].self, forKey: .recents) ?? []
    }
}

/// Everything Pitch keeps on disk.
public struct PresetStore: Codable, Equatable, Sendable {
    /// Shipped from day one so that a later format has something to migrate
    /// *from*. A file with no version at all is unreadable without guessing.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var displays: [StoredDisplay]

    public init(
        schemaVersion: Int = PresetStore.currentSchemaVersion,
        displays: [StoredDisplay] = []
    ) {
        self.schemaVersion = schemaVersion
        self.displays = displays
    }

    /// Where a display now on the desk sits in `displays`.
    ///
    /// `.ambiguous` is kept distinct from `.none` because callers must treat
    /// them differently: nothing found means "add an entry", while a tie means
    /// "do nothing at all" — appending there would create a second entry that
    /// ties with the first forever.
    public enum Lookup: Equatable, Sendable {
        case found(index: Int, tier: IdentityTier)
        case ambiguous
        case none
    }

    /// The same tier walk as `IdentityResolver`, run in the other direction:
    /// live identity in, stored entry out.
    public func lookup(_ live: DisplayIdentity) -> Lookup {
        let indexed = Dictionary(
            uniqueKeysWithValues: displays.enumerated().map { ($0.offset, $0.element.identity) })

        switch IdentityResolver.match(live, among: indexed) {
        case .matched(let index, let tier): return .found(index: index, tier: tier)
        case .ambiguous: return .ambiguous
        case .notFound: return .none
        }
    }

    /// The entry for a display now on the desk, or `nil` if there is none — or
    /// if two entries tie and picking one would be a guess.
    public func entry(matching live: DisplayIdentity) -> StoredDisplay? {
        guard case .found(let index, _) = lookup(live) else { return nil }
        return displays[index]
    }
}

/// Where presets live. A seam so tests never touch a real Application Support
/// folder.
public protocol PresetStoring: Sendable {
    func load() throws -> PresetStore
    func save(_ store: PresetStore) throws
}

/// A JSON file. Chosen over `UserDefaults` deliberately (spec §10): "send me
/// your presets.json" is a support move that works, and a file can be deleted
/// by hand when something goes wrong.
public struct FilePresetStore: PresetStoring {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The file Pitch uses, given the application's name.
    ///
    /// The name is a parameter because `DisplayCore` is not allowed to know
    /// which app it is linked into.
    public static func defaultURL(applicationName: String) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent(applicationName, isDirectory: true)
            .appendingPathComponent("presets.json")
    }

    public func load() throws -> PresetStore {
        // No file is the ordinary first-launch case, not a failure.
        guard FileManager.default.fileExists(atPath: url.path) else { return PresetStore() }

        // Anything else that goes wrong is allowed to throw. Returning an empty
        // store on a damaged file would let the next save overwrite data a
        // human might still rescue by hand.
        let decoded = try JSONDecoder().decode(PresetStore.self, from: Data(contentsOf: url))

        guard decoded.schemaVersion <= PresetStore.currentSchemaVersion else {
            throw DisplayError.storeSchemaUnsupported(version: decoded.schemaVersion)
        }

        switch decoded.schemaVersion {
        case PresetStore.currentSchemaVersion:
            return decoded
        default:
            // No older version exists yet. The switch is here so that when one
            // does, there is an obvious place for its migration to go.
            return decoded
        }
    }

    public func save(_ store: PresetStore) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        // Sorted and readable: the file is meant to be openable by a human
        // during support, and a stable key order keeps diffs meaningful.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // `.atomic` writes a neighbouring temp file and renames it over the
        // target, so a crash mid-write leaves the previous file intact rather
        // than a half-written one.
        try encoder.encode(store).write(to: url, options: .atomic)
    }
}
