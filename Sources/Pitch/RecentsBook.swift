import CoreGraphics
import DisplayCore

/// The last few resolutions picked on each display, kept across launches.
///
/// Sits between the menu and `PresetStore` so that the identity matching — the
/// part with the interesting failure modes — can be tested without AppKit.
///
/// The in-memory copy is the working one; the store is written through. That
/// ordering matters: a save that fails costs the dots after quit and nothing
/// else, so it must not be allowed to break the session that is still running.
final class RecentsBook {
    private let store: PresetStoring?
    private let identifier: DisplayIdentifying
    private var contents: PresetStore

    /// Set when the file could not be read.
    ///
    /// A damaged or too-new file may still be rescuable by hand, or by an
    /// update. Saving over it would end that, and the only thing preserved by
    /// refusing is three dots — so the session runs from an empty book and the
    /// file is left exactly as it was found.
    private let isReadOnly: Bool

    init(store: PresetStoring?, identifier: DisplayIdentifying = CoreGraphicsIdentifier()) {
        self.store = store
        self.identifier = identifier

        if let store {
            do {
                contents = try store.load()
                isReadOnly = false
            } catch {
                contents = PresetStore()
                isReadOnly = true
            }
        } else {
            contents = PresetStore()
            isReadOnly = true
        }
    }

    /// The book Pitch actually uses.
    ///
    /// A `nil` store means the Application Support URL could not be resolved at
    /// all — the dots then last for the session, which is what they did before
    /// any of this existed.
    convenience init(applicationName: String = "Pitch") {
        let url = try? FilePresetStore.defaultURL(applicationName: applicationName)
        self.init(store: url.map { FilePresetStore(url: $0) })
    }

    /// Newest first. Empty when this display is unknown, or when two stored
    /// entries tie and picking one would be a guess.
    func recents(for id: CGDirectDisplayID) -> [ModeSignature] {
        contents.entry(matching: identifier.identity(for: id))?.recents ?? []
    }

    func record(_ signature: ModeSignature, for id: CGDirectDisplayID, name: String) {
        let live = identifier.identity(for: id)

        switch contents.lookup(live) {
        case .found(let index, let tier):
            var entry = contents.displays[index]
            entry.recents = MenuModel.remembering(signature, in: entry.recents)
            entry.lastSeenName = name
            if let healed = entry.identity.healed(against: live, matchedBy: tier) {
                entry.identity = healed
            }
            contents.displays[index] = entry

        case .none:
            contents.displays.append(
                StoredDisplay(identity: live, lastSeenName: name, recents: [signature]))

        case .ambiguous:
            // Two stored entries tie on this display. Appending a third would
            // tie with both of them forever, so the tie is left alone and
            // nothing is written.
            return
        }

        persist()
    }

    private func persist() {
        guard !isReadOnly, let store else { return }
        // Deliberately swallowed. This runs immediately after a resolution
        // change the user is already being asked to keep or revert; an alert
        // about a preferences file on top of that countdown would be worse
        // than losing the dots at quit.
        try? store.save(contents)
    }
}
