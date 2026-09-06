import ColorSync
import CoreGraphics

/// The persistable identity of a physical display (spec §9).
///
/// `CGDirectDisplayID` is a table number, not a passport: it is reassigned on
/// replug and sometimes across sleep/wake. Anything written to disk and matched
/// up again later has to key on this instead, or one monitor eventually
/// inherits another's data.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    /// Tier 1. `CGDisplayCreateUUIDFromDisplayID`, stringified. Stable across
    /// reboots, but the OS recomputes it after some firmware and system
    /// updates, which is what tier 2 is for.
    public var uuid: String?

    /// Tier 2. `"vendor:model:serial"`, decimal. The serial may legitimately be
    /// `0`; a vendor or model of `0` means EDID could not be read at all, which
    /// makes the whole key useless — see `isUsable(_:)`.
    public var hardwareKey: String

    /// Tier 3, deferred. The IOKit registry path — where the panel is plugged
    /// in rather than what it claims to be, and so the only discriminator that
    /// does not come from EDID.
    ///
    /// Nothing populates this yet. The field ships now so the file format does
    /// not change under people who already have data when it arrives, and
    /// `IdentityResolver` already walks it, so tier 3 becomes a matter of
    /// filling it in.
    public var registryLocation: String?

    public init(uuid: String?, hardwareKey: String, registryLocation: String? = nil) {
        self.uuid = uuid
        self.hardwareKey = hardwareKey
        self.registryLocation = registryLocation
    }

    /// Assembles tier 2's key. Kept here so the format has exactly one author.
    public static func hardwareKey(vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        "\(vendor):\(model):\(serial)"
    }

    /// This identity's value at one tier, or `nil` if it carries none.
    func value(for tier: IdentityTier) -> String? {
        switch tier {
        case .uuid: return uuid
        case .hardware: return hardwareKey
        case .registry: return registryLocation
        }
    }

    /// Whether this identity's value at one tier is worth matching on.
    ///
    /// An absent or empty value is not, and neither is a hardware key whose
    /// vendor or model is `0` — that is the OS saying it could not read EDID,
    /// and it would otherwise match every unidentified panel on the desk.
    func isUsable(_ tier: IdentityTier) -> Bool {
        guard let value = value(for: tier), !value.isEmpty else { return false }
        guard tier == .hardware else { return true }

        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let vendor = UInt32(parts[0]),
              let model = UInt32(parts[1])
        else { return false }
        return vendor != 0 && model != 0
    }

    /// Tier 2's serial component, if the key is well formed.
    var serial: UInt32? {
        let parts = hardwareKey.split(separator: ":")
        guard parts.count == 3 else { return nil }
        return UInt32(parts[2])
    }

    /// The identity to store after matching a live display, or `nil` to leave
    /// the stored one alone (spec §9, self-healing).
    ///
    /// Only ever rewrites `uuid`, and only when the match came from tier 2 with
    /// a non-zero serial. A batch of panels sharing serial `0` is exactly the
    /// case where "same monitor, new UUID" and "a different monitor from the
    /// same batch" are indistinguishable, and a wrong rewrite binds one
    /// display's data to another permanently, with no undo.
    ///
    /// Ambiguity is already excluded by the caller: `IdentityResolver` returns
    /// `.ambiguous` rather than a match when more than one display ties.
    public func healed(
        against live: DisplayIdentity, matchedBy tier: IdentityTier
    ) -> DisplayIdentity? {
        guard tier == .hardware else { return nil }
        guard let serial, serial != 0 else { return nil }
        guard let fresh = live.uuid, !fresh.isEmpty, fresh != uuid else { return nil }

        var healed = self
        healed.uuid = fresh
        return healed
    }
}

/// The tiers of `DisplayIdentity`, in the order they are consulted.
public enum IdentityTier: String, Codable, CaseIterable, Sendable {
    case uuid
    case hardware
    case registry
}

/// The outcome of looking a stored identity up among the displays on the desk.
public enum IdentityResolution: Equatable, Sendable {
    case matched(CGDirectDisplayID, tier: IdentityTier)

    /// Two or more displays tie at every tier that could tell them apart.
    /// Spec §9: decline, never guess.
    case ambiguous

    case notFound
}

public enum IdentityResolver {
    /// Finds the live display a stored identity refers to.
    ///
    /// Tiers are consulted in order, and a tie does not end the search — it
    /// narrows it. Identical twins agree at tier 1 and tier 2 alike, so the
    /// tied pair is carried forward for a later tier to separate; with tier 3
    /// deferred that pair survives to the end and the answer is `.ambiguous`.
    ///
    /// A tier that matches *nothing* is a different thing from a tie: it means
    /// the stored value has gone stale, so the search continues against every
    /// live display rather than a narrowed set. That is the "UUID changed after
    /// a firmware update" case, and tier 2 is what rescues it.
    public static func resolve(
        _ stored: DisplayIdentity,
        among live: [CGDirectDisplayID: DisplayIdentity]
    ) -> IdentityResolution {
        switch match(stored, among: live) {
        case .matched(let id, let tier): return .matched(id, tier: tier)
        case .ambiguous: return .ambiguous
        case .notFound: return .notFound
        }
    }

    enum Outcome<Key> {
        case matched(Key, IdentityTier)
        case ambiguous
        case notFound
    }

    /// The tier walk itself, over anything keyed by anything.
    ///
    /// Generic because it runs in both directions: from a stored identity to a
    /// display on the desk, and from a display on the desk to its entry in the
    /// store.
    static func match<Key: Hashable>(
        _ wanted: DisplayIdentity,
        among candidates: [Key: DisplayIdentity]
    ) -> Outcome<Key> {
        var remaining = candidates
        var tied = false

        for tier in IdentityTier.allCases {
            guard wanted.isUsable(tier), let value = wanted.value(for: tier) else { continue }

            let hits = remaining.filter {
                $0.value.isUsable(tier) && $0.value.value(for: tier) == value
            }
            if hits.count == 1, let hit = hits.first {
                return .matched(hit.key, tier)
            }
            if hits.count > 1 {
                tied = true
                remaining = hits
            }
        }

        return tied ? .ambiguous : .notFound
    }
}

/// Reads a display's identity from the windowing system.
///
/// A seam of its own, like `DisplayEnumerating`: the tests need identities that
/// no monitor on the developer's desk has to supply.
public protocol DisplayIdentifying: Sendable {
    func identity(for id: CGDirectDisplayID) -> DisplayIdentity
}

public struct CoreGraphicsIdentifier: DisplayIdentifying {
    public init() {}

    public func identity(for id: CGDirectDisplayID) -> DisplayIdentity {
        var uuid: String?
        // A Create function: the reference is owned here and released on the
        // way out.
        if let reference = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            uuid = CFUUIDCreateString(nil, reference) as String?
        }

        return DisplayIdentity(
            uuid: uuid,
            hardwareKey: DisplayIdentity.hardwareKey(
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)))
    }
}
