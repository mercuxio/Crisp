import CoreGraphics
import Foundation
import Testing

@testable import DisplayCore

/// A plausible identity, overridable field by field.
private func identity(
    uuid: String? = "A1",
    vendor: UInt32 = 7789,
    model: UInt32 = 23305,
    serial: UInt32 = 79350
) -> DisplayIdentity {
    DisplayIdentity(
        uuid: uuid,
        hardwareKey: DisplayIdentity.hardwareKey(vendor: vendor, model: model, serial: serial))
}

@Test func identityResolvesByUUIDFirst() {
    let stored = identity(uuid: "A1")
    // The decoy shares nothing but is present to prove the search is a search.
    let live: [CGDirectDisplayID: DisplayIdentity] = [
        1: identity(uuid: "B2", vendor: 4, model: 5, serial: 6),
        2: stored,
    ]

    #expect(IdentityResolver.resolve(stored, among: live) == .matched(2, tier: .uuid))
}

@Test func identityFallsBackToHardwareWhenTheUUIDHasChanged() {
    // The OS recomputes the UUID after some firmware and OS updates. The panel
    // is the same panel, and EDID still says so.
    let stored = identity(uuid: "STALE")
    let live: [CGDirectDisplayID: DisplayIdentity] = [7: identity(uuid: "FRESH")]

    #expect(IdentityResolver.resolve(stored, among: live) == .matched(7, tier: .hardware))
}

@Test func identicalTwinsAreAmbiguousRatherThanAGuess() {
    // Spec §9: vendors ship batches with one serial, so two panels can agree on
    // every tier we implement. Tier 3 would separate them; until it exists this
    // must decline, not pick.
    let stored = identity(uuid: nil)
    let twin = identity(uuid: nil)
    let live: [CGDirectDisplayID: DisplayIdentity] = [1: twin, 2: twin]

    #expect(IdentityResolver.resolve(stored, among: live) == .ambiguous)
}

@Test func anUnreadableHardwareKeyMatchesNothing() {
    // Vendor and model of 0 mean the OS could not read EDID. That key would
    // otherwise match every unidentified panel on the desk.
    let stored = identity(uuid: nil, vendor: 0, model: 0, serial: 0)
    let live: [CGDirectDisplayID: DisplayIdentity] = [
        1: identity(uuid: nil, vendor: 0, model: 0, serial: 0)
    ]

    #expect(IdentityResolver.resolve(stored, among: live) == .notFound)
}

@Test func twoAbsentUUIDsAreNotAMatch() {
    // nil == nil is true in Swift and would be a silent cross-display match.
    let stored = DisplayIdentity(uuid: nil, hardwareKey: "1:2:3")
    let live: [CGDirectDisplayID: DisplayIdentity] = [
        1: DisplayIdentity(uuid: nil, hardwareKey: "9:9:9")
    ]

    #expect(IdentityResolver.resolve(stored, among: live) == .notFound)
}

@Test func anUnknownDisplayIsNotFound() {
    let stored = identity(uuid: "A1")
    let live: [CGDirectDisplayID: DisplayIdentity] = [
        1: identity(uuid: "B2", vendor: 1, model: 2, serial: 3)
    ]

    #expect(IdentityResolver.resolve(stored, among: live) == .notFound)
}

@Test func healingRewritesTheUUIDAfterAHardwareMatch() {
    let stored = identity(uuid: "STALE")
    let live = identity(uuid: "FRESH")

    let healed = stored.healed(against: live, matchedBy: .hardware)

    #expect(healed?.uuid == "FRESH")
    #expect(healed?.hardwareKey == stored.hardwareKey)
}

@Test func healingIsRefusedWhenTheSerialIsZero() {
    // Spec §9: a wrong rewrite permanently binds one display's data to another
    // with no undo. A zero serial is exactly the batch-collision case.
    let stored = identity(uuid: "STALE", serial: 0)
    let live = identity(uuid: "FRESH", serial: 0)

    #expect(stored.healed(against: live, matchedBy: .hardware) == nil)
}

@Test func healingIsRefusedAfterAUUIDMatch() {
    // Nothing to heal: the UUID is what matched.
    let stored = identity(uuid: "A1")
    let live = identity(uuid: "A1")

    #expect(stored.healed(against: live, matchedBy: .uuid) == nil)
}

@Test func identityRoundTripsThroughJSON() throws {
    let original = identity(uuid: "A1")

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(DisplayIdentity.self, from: data)

    #expect(decoded == original)
}

@Test func identityDecodesAFileWrittenBeforeRegistryLocationExisted() throws {
    // Tier 3 is deferred, but the field ships now so the stored format does not
    // change under users when it arrives.
    let json = Data(#"{"uuid":"A1","hardwareKey":"1:2:3"}"#.utf8)

    let decoded = try JSONDecoder().decode(DisplayIdentity.self, from: json)

    #expect(decoded.uuid == "A1")
    #expect(decoded.registryLocation == nil)
}
