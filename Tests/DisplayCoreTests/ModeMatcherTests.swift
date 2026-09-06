import Testing
@testable import DisplayCore

private func mode(
    point: (Int, Int),
    pixel: (Int, Int),
    mHz: Int,
    safe: Bool = true,
    id: Int32 = 1,
    stretched: Bool = false
) -> DisplayMode {
    DisplayMode(
        signature: ModeSignature(
            pointWidth: point.0, pointHeight: point.1,
            pixelWidth: pixel.0, pixelHeight: pixel.1,
            refreshMilliHz: mHz, isSafe: safe),
        ioDisplayModeID: id,
        isStretched: stretched,
        source: .publicAPI)
}

// MARK: - match: strict preset restore

@Test func matchFindsAnExactSignature() {
    let wanted = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000)
    let result = ModeMatcher.match(wanted.signature, in: [
        mode(point: (1920, 1080), pixel: (3840, 2160), mHz: 60_000, id: 10),
        wanted,
    ])
    #expect(result == .exact(wanted))
}

@Test func matchToleratesSubHertzRefreshDrift() {
    // 59.94 Hz vs 60.00 Hz is 60 mHz apart — the same physical mode reported
    // by two providers that round differently. Spec §6.
    let available = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 59_940)
    let wanted = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshMilliHz: 60_000, isSafe: true)

    #expect(ModeMatcher.match(wanted, in: [available]) == .tolerant(available))
}

@Test func matchRefusesWhenRefreshIsOutsideTolerance() {
    let available = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 120_000)
    let wanted = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshMilliHz: 60_000, isSafe: true)

    #expect(ModeMatcher.match(wanted, in: [available]) == .unavailable)
}

@Test func matchNeverCrossesTheSafetyFlag() {
    // The §4.3 collision pair. Tolerance must not bridge it, or a preset for the
    // safe mode silently applies the unsafe twin.
    let unsafeTwin = mode(point: (2560, 1440), pixel: (2560, 1440), mHz: 60_000, safe: false)
    let wanted = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 2560, pixelHeight: 1440,
        refreshMilliHz: 60_000, isSafe: true)

    #expect(ModeMatcher.match(wanted, in: [unsafeTwin]) == .unavailable)
}

@Test func matchNeverSubstitutesADifferentResolution() {
    // Spec §10: no "closest match" fallback. Modes genuinely disappear across
    // OS and firmware revisions, and silently applying a different resolution
    // is the exact failure the signature scheme exists to prevent.
    let other = mode(point: (1920, 1080), pixel: (3840, 2160), mHz: 60_000)
    let wanted = ModeSignature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshMilliHz: 60_000, isSafe: true)

    #expect(ModeMatcher.match(wanted, in: [other]) == .unavailable)
}

@Test func matchNeverTolerancesAcrossAnUnspecifiedRefreshRate() {
    // Built-in Apple displays report 0 Hz. 0 means "unspecified", not "0 Hz",
    // so it must not be within tolerance of a real 60 Hz mode — and 999 mHz
    // would otherwise sneak through.
    let builtIn = mode(point: (1512, 982), pixel: (3024, 1964), mHz: 0)
    let wanted = ModeSignature(
        pointWidth: 1512, pointHeight: 982,
        pixelWidth: 3024, pixelHeight: 1964,
        refreshMilliHz: 900, isSafe: true)

    #expect(ModeMatcher.match(wanted, in: [builtIn]) == .unavailable)
}

@Test func matchPrefersTheExactHitOverATolerantOne() {
    let exact = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000, id: 1)
    let near = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 59_940, id: 2)

    #expect(ModeMatcher.match(exact.signature, in: [near, exact]) == .exact(exact))
}

// MARK: - resolve: user query

@Test func resolvePrefersHiDPIByDefault() {
    let native = mode(point: (2560, 1440), pixel: (2560, 1440), mHz: 60_000, id: 1)
    let hidpi = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000, id: 2)

    let ranked = ModeMatcher.resolve(
        ModeQuery(pointWidth: 2560, pointHeight: 1440),
        in: [native, hidpi])

    #expect(ranked.first == hidpi)
}

@Test func resolveExcludesUnsafeModesUnlessAskedFor() {
    let unsafeMode = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000, safe: false)

    #expect(ModeMatcher.resolve(
        ModeQuery(pointWidth: 2560, pointHeight: 1440),
        in: [unsafeMode]).isEmpty)

    #expect(ModeMatcher.resolve(
        ModeQuery(pointWidth: 2560, pointHeight: 1440, includeUnsafe: true),
        in: [unsafeMode]) == [unsafeMode])
}

@Test func resolvePrefersHigherRefreshAmongEqualCandidates() {
    let slow = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000, id: 1)
    let fast = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 120_000, id: 2)

    let ranked = ModeMatcher.resolve(
        ModeQuery(pointWidth: 2560, pointHeight: 1440),
        in: [slow, fast])

    #expect(ranked == [fast, slow])
}

@Test func resolveHonoursAnExplicitRefreshRequest() {
    let slow = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000, id: 1)
    let fast = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 120_000, id: 2)

    let ranked = ModeMatcher.resolve(
        ModeQuery(pointWidth: 2560, pointHeight: 1440, refreshMilliHz: 60_000),
        in: [slow, fast])

    #expect(ranked == [slow])
}

@Test func resolveHonoursAnExplicitNoHiDPIRequest() {
    let native = mode(point: (2560, 1440), pixel: (2560, 1440), mHz: 60_000, id: 1)
    let hidpi = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000, id: 2)

    let ranked = ModeMatcher.resolve(
        ModeQuery(pointWidth: 2560, pointHeight: 1440, hiDPI: false),
        in: [native, hidpi])

    #expect(ranked == [native])
}

@Test func resolveExcludesStretchedModesUnlessAskedFor() {
    let stretched = mode(
        point: (1600, 900), pixel: (1600, 900), mHz: 60_000, id: 97, stretched: true)

    #expect(ModeMatcher.resolve(
        ModeQuery(pointWidth: 1600, pointHeight: 900),
        in: [stretched]).isEmpty)

    #expect(ModeMatcher.resolve(
        ModeQuery(pointWidth: 1600, pointHeight: 900, includeStretched: true),
        in: [stretched]) == [stretched])
}

@Test func resolveReturnsNothingForAResolutionTheDisplayLacks() {
    let available = mode(point: (2560, 1440), pixel: (5120, 2880), mHz: 60_000)

    #expect(ModeMatcher.resolve(
        ModeQuery(pointWidth: 3440, pointHeight: 1440),
        in: [available]).isEmpty)
}
