# Crisp — DisplayCore & displayctl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `DisplayCore` (display enumeration and a safe apply path) and the `displayctl` CLI that drives it, so that resolutions — including the HiDPI modes System Settings hides — can be listed and changed from the terminal with confirm-or-revert protection.

**Architecture:** A pure Swift package with no UI dependencies. Every call into CoreGraphics goes through one of two narrow protocols (`DisplayEnumerating` for reads, `DisplayConfiguring` for writes) so that all logic is testable against fakes without changing the developer's actual screen. `displayctl` is a thin argument-parsing shell over that library.

**Tech Stack:** Swift 6.4, SwiftPM, swift-testing (as a package dependency), CoreGraphics, ColorSync. No Xcode, no third-party runtime dependencies.

**Spec:** `docs/specs/2026-09-05-crisp-design.md`

## Scope

This plan implements **milestones 1 and 2** of spec §16. It stops at a working CLI. Milestones 3–8 (the SwiftUI app, presets and identity, hot-plug, the CGS bridge, distribution) are deliberately out of scope and get their own plans — see "Why this plan stops here" at the end.

The deliverable of this plan is independently useful software: a signed-off `displayctl` that lists every mode and changes them safely.

## Global Constraints

Every task's requirements implicitly include this section.

- **Platform floor:** macOS 14.0. Set `platforms: [.macOS(.v14)]` in `Package.swift`.
- **Architecture:** arm64 only. Do not add x86_64 handling anywhere.
- **Bundle identifier (fixed, permanent):** `com.houlanyit.Crisp`. Not used in this plan, but do not invent a different one anywhere.
- **Toolchain:** Command Line Tools only — Xcode is **not** installed. `xcodebuild` and `actool` are unavailable. Do not write any step that calls them.
- **Every `swift build` / `swift test` / `swift run` invocation MUST pass `--build-system native`.** The default (XCBuild) build system fails under Command Line Tools with `SessionFailedError … "Unknown error parsing property list"`. It will print a deprecation warning about `native`; ignore it. This is not optional and applies to every command in every task.
- **Test framework:** swift-testing via the SPM dependency `https://github.com/swiftlang/swift-testing.git`. Neither `Testing` nor `XCTest` exists in the Command Line Tools SDK, so the dependency is mandatory. Use `import Testing`, `@Test`, `#expect`, `#require`.
- **Do not remove the swift-testing dependency, whatever the compiler says.** Every `@Test` emits `warning: 'Test' is deprecated: Swift Testing is now included in the Swift 6 toolchain. Remove your 'swift-testing' package dependency to silence this warning.` That advice is wrong *on this machine*: the toolchain ships the library but the Command Line Tools SDK does not expose the module, so removing the dependency turns every test file into `no such module 'Testing'`. The warnings are expected and are not a defect to fix. (Verified 2026-09-05 with Swift 6.4 + CLT, no Xcode.)
- **`DisplayCore` must not import SwiftUI, AppKit, or Foundation's `UserDefaults`,** and must never produce user-facing strings. It vends typed errors; presentation is the caller's job.
- **No test may change the developer's actual display mode.** Anything touching the write path is tested through `FakeConfigurator`. Only the manual verification steps in Task 7 touch real hardware, and they are explicitly marked.
- **Refresh rate is integer millihertz everywhere.** Never store or compare a `Double` Hz value. Built-in Apple displays report `0.0` Hz; `0` means "unspecified" and must never tolerance-match a non-zero value.
- **Commit after every task.** Conventional commit prefixes (`feat:`, `test:`, `chore:`).

---

## File Structure

```
Package.swift                                    SPM manifest, 3 targets
Sources/DisplayCore/
  ModeSignature.swift        the persistable identity of a mode
  DisplayMode.swift          a mode + its provenance
  DisplayDevice.swift        a physical monitor as seen this session
  DisplayError.swift         the typed error surface
  ModeMatcher.swift          signature matching and user-query resolution
  DisplayEnumerating.swift   READ protocol — the CoreGraphics seam
  CoreGraphicsEnumerator.swift  the real read implementation
  DisplayConfiguring.swift   WRITE protocol — the CoreGraphics seam
  CoreGraphicsConfigurator.swift  the real write implementation + watchdog
  MonotonicClock.swift       injectable time
  RevertCoordinator.swift    the confirm-or-revert state machine
Sources/displayctl/
  main.swift                 entry point + dispatch
  ArgumentParsing.swift      hand-rolled parsing (no dependency)
  Commands.swift             list / set / restore / doctor
  Rendering.swift            text + JSON output
Tests/DisplayCoreTests/
  Fakes.swift                FakeEnumerator, FakeConfigurator, FakeClock, builders
  ModeSignatureTests.swift
  ModeMatcherTests.swift
  CoreGraphicsEnumeratorTests.swift   incl. the constant-value guard
  CoreGraphicsConfiguratorTests.swift
  RevertCoordinatorTests.swift
```

Split by responsibility, not layer: the read seam and its implementation sit together, as do the write seam and its watchdog. `ModeMatcher` is separate from `ModeSignature` because matching policy changes far more often than the value type does.

### Deviation from the spec, recorded deliberately

Spec §6 sketches `DisplayMode` with flat stored properties and `var id: ModeSignature`. This plan **embeds** the signature as a stored property and derives the flat accessors from it. Same data, one source of truth, and it makes `mode.signature` — the thing persistence and matching both need — impossible to construct inconsistently. No behavioural difference.

---

### Task 1: Package scaffold and the value types

**Files:**
- Create: `Package.swift`
- Create: `Sources/DisplayCore/ModeSignature.swift`
- Create: `Sources/DisplayCore/DisplayMode.swift`
- Create: `Sources/DisplayCore/DisplayError.swift`
- Create: `Sources/displayctl/main.swift`
- Test: `Tests/DisplayCoreTests/ModeSignatureTests.swift`

**Interfaces:**
- Consumes: nothing — this is the first task.
- Produces: `ModeSignature`, `ModeSource`, `DisplayMode`, `DisplayError`. Every later task depends on these exact names and types.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crisp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DisplayCore", targets: ["DisplayCore"]),
        .executable(name: "displayctl", targets: ["displayctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(name: "DisplayCore"),
        .executableTarget(name: "displayctl", dependencies: ["DisplayCore"]),
        .testTarget(
            name: "DisplayCoreTests",
            dependencies: [
                "DisplayCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/DisplayCoreTests/ModeSignatureTests.swift`. The two collision cases come from spec §4.3: on the reference LG 5K, `2560×1440 @60` non-HiDPI appears twice, distinguished only by the safety flag. A signature that cannot tell those apart is the bug this type exists to prevent.

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'ModeSignature' in scope`. The first run also fetches and compiles swift-testing from source, which takes about a minute.

- [ ] **Step 4: Write `ModeSignature`**

Create `Sources/DisplayCore/ModeSignature.swift`:

```swift
/// The persistable identity of a display mode.
///
/// Deliberately wider than it looks like it needs to be. Spec §4.3 measured ten
/// collision pairs on a single display using only point size, refresh, and a
/// HiDPI flag — pixel dimensions and the safety flag are what break those ties.
public struct ModeSignature: Codable, Hashable, Sendable {
    public let pointWidth: Int
    public let pointHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// Integer millihertz. Never a Double: VRR panels report 59.94 Hz, and the
    /// private and public providers round it differently, so float equality
    /// across providers silently never matches. `0` means "unspecified", which
    /// is what built-in Apple displays report.
    public let refreshMilliHz: Int

    /// Whether the OS advertises this mode as usable for the desktop GUI.
    public let isSafe: Bool

    public init(
        pointWidth: Int,
        pointHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshMilliHz: Int,
        isSafe: Bool
    ) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshMilliHz = refreshMilliHz
        self.isSafe = isSafe
    }
}
```

- [ ] **Step 5: Write `DisplayMode`**

Create `Sources/DisplayCore/DisplayMode.swift`:

```swift
/// Which provider surfaced a mode.
public enum ModeSource: String, Codable, Hashable, Sendable {
    case publicAPI
    case privateCGS
}

/// A display mode, as offered to the user.
public struct DisplayMode: Identifiable, Hashable, Sendable {
    public let signature: ModeSignature

    /// `CGDisplayMode.ioDisplayModeID`. An O(1) apply hint only — spec §4.2
    /// verified it equals the CGS table index, but it is not stable across
    /// EDID or OS changes, so it is always validated against the signature
    /// before use and never trusted on its own.
    public let ioDisplayModeID: Int32

    /// Non-square pixels. Only the private CGS provider surfaces these.
    public let isStretched: Bool

    public let source: ModeSource

    public var id: ModeSignature { signature }

    public init(
        signature: ModeSignature,
        ioDisplayModeID: Int32,
        isStretched: Bool,
        source: ModeSource
    ) {
        self.signature = signature
        self.ioDisplayModeID = ioDisplayModeID
        self.isStretched = isStretched
        self.source = source
    }

    public var pointWidth: Int { signature.pointWidth }
    public var pointHeight: Int { signature.pointHeight }
    public var pixelWidth: Int { signature.pixelWidth }
    public var pixelHeight: Int { signature.pixelHeight }
    public var refreshMilliHz: Int { signature.refreshMilliHz }
    public var isSafe: Bool { signature.isSafe }

    /// Horizontal backing-store scale. Derived, never stored: a stored copy is
    /// one more thing that can disagree with the dimensions it came from.
    public var scale: Double {
        guard signature.pointWidth > 0 else { return 1.0 }
        return Double(signature.pixelWidth) / Double(signature.pointWidth)
    }

    public var isHiDPI: Bool { scale > 1.0 }

    /// For display only. Compare `refreshMilliHz`, never this.
    public var refreshHz: Double { Double(signature.refreshMilliHz) / 1000.0 }
}
```

- [ ] **Step 6: Write `DisplayError`**

Create `Sources/DisplayCore/DisplayError.swift`. Note there is no `.closestMatchUsed` case — spec §10 forbids silent substitution, so "no exact or tolerant match" is a terminal error, not a fallback.

```swift
import CoreGraphics

/// The complete error surface of DisplayCore.
///
/// These carry no user-facing text by design (spec §13): the app and the CLI
/// render them differently, and DisplayCore should not have an opinion about
/// either.
public enum DisplayError: Error, Equatable, Sendable {
    case noSuchDisplay(CGDirectDisplayID)
    case modeEnumerationFailed(CGDirectDisplayID)
    case currentModeUnavailable(CGDirectDisplayID)

    /// A CoreGraphics configuration call returned a non-success code.
    case configurationFailed(code: Int32)

    /// `CGCompleteDisplayConfiguration` did not return within the watchdog
    /// window. Documented to happen in the field; spec §8.1.
    case completionTimedOut(seconds: Double)

    /// A stored preset no longer resolves to any available mode.
    case modeUnavailable(ModeSignature)

    /// No mode on this display satisfies the user's request.
    case noMatchingMode(requestedWidth: Int, requestedHeight: Int)

    /// The revert deadline passed before the change was confirmed.
    case confirmationExpired
}
```

- [ ] **Step 7: Write a placeholder `main.swift` so the executable target compiles**

Create `Sources/displayctl/main.swift`:

```swift
import DisplayCore

// Replaced with real dispatch in Task 4.
print("displayctl: not implemented yet")
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 5 tests.

- [ ] **Step 9: Commit**

```bash
cd ~/Projects/Crisp
git add Package.swift Package.resolved Sources Tests
git commit -m "feat: add DisplayCore value types and package scaffold"
```

`Package.resolved` is **committed, not ignored.** The usual advice to ignore it
applies to libraries, whose dependency versions are the consumer's business.
Crisp is an application: the resolved file is what makes a checkout build the
same swift-testing revision tomorrow as today, and `displayctl` is a recovery
tool whose build should never be at the mercy of an upstream tag moving.

---

### Task 2: Mode matching

**Files:**
- Create: `Sources/DisplayCore/ModeMatcher.swift`
- Test: `Tests/DisplayCoreTests/ModeMatcherTests.swift`

**Interfaces:**
- Consumes: `ModeSignature`, `DisplayMode`, `ModeSource` from Task 1.
- Produces: `ModeQuery`, `ModeMatch`, `ModeMatcher.match(_:in:)`, `ModeMatcher.resolve(_:in:)`, `ModeMatcher.refreshToleranceMilliHz`.

Two different jobs live here, and conflating them is a real hazard:

- **`match`** answers "the user saved *this exact mode*; is it still here?" It is strict, and refuses rather than approximating. This is what preset restore uses (spec §10).
- **`resolve`** answers "the user typed `2560x1440`; what did they mean?" It ranks candidates and picks the best. Choosing here is correct, because the user expressed a preference, not a recorded fact.

- [ ] **Step 1: Write the failing test**

Create `Tests/DisplayCoreTests/ModeMatcherTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'ModeMatcher' in scope`.

- [ ] **Step 3: Write `ModeMatcher`**

Create `Sources/DisplayCore/ModeMatcher.swift`:

```swift
/// What the user asked for, as opposed to what was previously recorded.
public struct ModeQuery: Equatable, Sendable {
    public var pointWidth: Int
    public var pointHeight: Int

    /// `nil` means "any refresh rate", which ranks highest-first.
    public var refreshMilliHz: Int?

    /// `nil` means "prefer HiDPI but accept native".
    public var hiDPI: Bool?

    public var includeUnsafe: Bool
    public var includeStretched: Bool

    public init(
        pointWidth: Int,
        pointHeight: Int,
        refreshMilliHz: Int? = nil,
        hiDPI: Bool? = nil,
        includeUnsafe: Bool = false,
        includeStretched: Bool = false
    ) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.refreshMilliHz = refreshMilliHz
        self.hiDPI = hiDPI
        self.includeUnsafe = includeUnsafe
        self.includeStretched = includeStretched
    }
}

/// The outcome of resolving a *recorded* signature. There is deliberately no
/// "approximate" case beyond `tolerant`, which only ever bridges sub-hertz
/// refresh drift.
public enum ModeMatch: Equatable, Sendable {
    case exact(DisplayMode)
    case tolerant(DisplayMode)
    case unavailable
}

public enum ModeMatcher {
    /// Spec §10. Wide enough to bridge 59.94 vs 60.00 Hz, narrow enough that
    /// 60 Hz and 75 Hz can never be confused.
    public static let refreshToleranceMilliHz = 1_000

    /// Strict resolution of a previously recorded signature.
    public static func match(
        _ wanted: ModeSignature,
        in modes: [DisplayMode]
    ) -> ModeMatch {
        if let hit = modes.first(where: { $0.signature == wanted }) {
            return .exact(hit)
        }

        // A refresh rate of 0 means "unspecified" and can only ever match
        // another unspecified rate — which the exact check above already
        // handled. Bailing here stops 0 from tolerance-matching 900 mHz.
        guard wanted.refreshMilliHz != 0 else { return .unavailable }

        let candidates = modes.filter {
            $0.pointWidth == wanted.pointWidth
                && $0.pointHeight == wanted.pointHeight
                && $0.pixelWidth == wanted.pixelWidth
                && $0.pixelHeight == wanted.pixelHeight
                && $0.isSafe == wanted.isSafe
                && $0.refreshMilliHz != 0
                && abs($0.refreshMilliHz - wanted.refreshMilliHz) <= refreshToleranceMilliHz
        }

        guard let nearest = candidates.min(by: {
            let a = abs($0.refreshMilliHz - wanted.refreshMilliHz)
            let b = abs($1.refreshMilliHz - wanted.refreshMilliHz)
            // Tie-break on the higher refresh rate so the result is stable
            // regardless of enumeration order.
            return a == b ? $0.refreshMilliHz > $1.refreshMilliHz : a < b
        }) else {
            return .unavailable
        }

        return .tolerant(nearest)
    }

    /// Ranked resolution of a user request. Best candidate first; empty means
    /// the display cannot do it.
    public static func resolve(
        _ query: ModeQuery,
        in modes: [DisplayMode]
    ) -> [DisplayMode] {
        let candidates = modes.filter { mode in
            guard mode.pointWidth == query.pointWidth,
                  mode.pointHeight == query.pointHeight else { return false }
            if !query.includeUnsafe && !mode.isSafe { return false }
            if !query.includeStretched && mode.isStretched { return false }
            if let wantHiDPI = query.hiDPI, mode.isHiDPI != wantHiDPI { return false }
            if let wantHz = query.refreshMilliHz, mode.refreshMilliHz != wantHz { return false }
            return true
        }

        return candidates.sorted { lhs, rhs in
            // HiDPI first: it is what the user almost always wants and is the
            // whole reason this app exists.
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            if lhs.refreshMilliHz != rhs.refreshMilliHz {
                return lhs.refreshMilliHz > rhs.refreshMilliHz
            }
            // Final tie-break for a deterministic order.
            return lhs.ioDisplayModeID < rhs.ioDisplayModeID
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 19 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/Crisp
git add Sources/DisplayCore/ModeMatcher.swift Tests/DisplayCoreTests/ModeMatcherTests.swift
git commit -m "feat: add strict signature matching and ranked query resolution"
```

---

### Task 3: The read seam and the real enumerator

**Files:**
- Create: `Sources/DisplayCore/DisplayDevice.swift`
- Create: `Sources/DisplayCore/DisplayEnumerating.swift`
- Create: `Sources/DisplayCore/CoreGraphicsEnumerator.swift`
- Create: `Tests/DisplayCoreTests/Fakes.swift`
- Test: `Tests/DisplayCoreTests/CoreGraphicsEnumeratorTests.swift`

**Interfaces:**
- Consumes: `DisplayMode`, `ModeSignature`, `ModeSource`, `DisplayError` from Task 1.
- Produces: `DisplayDevice`, `DisplayEnumerating`, `CoreGraphicsEnumerator`, `ModeConversion.signature(...)`, `ModeConversion.deduplicated(_:)`, and the test fake `FakeEnumerator`.

The single most important line in this task is the options dictionary. Spec §4.1 measured that building it from the constant's *name* rather than its *value* silently returns 42 modes with zero HiDPI entries instead of 88 with 46 — no error, no warning. The guard test exists so a future SDK change fails loudly instead of halving the mode list.

**Deferred deliberately:** `DisplayDevice.localizedName` is a positional label (`"Display 1"`, `"Built-in Display"`) in this plan, not the EDID product name. Real product names need IOKit `IODisplayCreateInfoDictionary`, which arrives with persistent identity in the next plan (spec §9). `displayctl` addresses displays by index, so nothing here needs the real name yet.

- [ ] **Step 1: Write the fakes**

Create `Tests/DisplayCoreTests/Fakes.swift`. Every later task uses these, so they live in one file rather than being redefined per test.

```swift
import CoreGraphics
@testable import DisplayCore

/// Builds a mode without the ceremony, for tests that do not care about most
/// of the fields.
func makeMode(
    point: (Int, Int),
    pixel: (Int, Int),
    mHz: Int = 60_000,
    safe: Bool = true,
    id: Int32 = 1,
    stretched: Bool = false,
    source: ModeSource = .publicAPI
) -> DisplayMode {
    DisplayMode(
        signature: ModeSignature(
            pointWidth: point.0, pointHeight: point.1,
            pixelWidth: pixel.0, pixelHeight: pixel.1,
            refreshMilliHz: mHz, isSafe: safe),
        ioDisplayModeID: id,
        isStretched: stretched,
        source: source)
}

/// A scripted `DisplayEnumerating` that never touches CoreGraphics.
final class FakeEnumerator: DisplayEnumerating, @unchecked Sendable {
    var devices: [DisplayDevice]
    var modesByDisplay: [CGDirectDisplayID: [DisplayMode]]
    var currentByDisplay: [CGDirectDisplayID: DisplayMode]
    var enumerationError: DisplayError?

    init(
        devices: [DisplayDevice] = [],
        modesByDisplay: [CGDirectDisplayID: [DisplayMode]] = [:],
        currentByDisplay: [CGDirectDisplayID: DisplayMode] = [:]
    ) {
        self.devices = devices
        self.modesByDisplay = modesByDisplay
        self.currentByDisplay = currentByDisplay
    }

    func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
        if let enumerationError { throw enumerationError }
        return devices.map(\.displayID)
    }

    func device(for id: CGDirectDisplayID) throws -> DisplayDevice {
        guard let hit = devices.first(where: { $0.displayID == id }) else {
            throw DisplayError.noSuchDisplay(id)
        }
        return hit
    }

    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode] {
        if let enumerationError { throw enumerationError }
        guard let hit = modesByDisplay[id] else {
            throw DisplayError.modeEnumerationFailed(id)
        }
        return hit
    }

    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode {
        guard let hit = currentByDisplay[id] else {
            throw DisplayError.currentModeUnavailable(id)
        }
        return hit
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/DisplayCoreTests/CoreGraphicsEnumeratorTests.swift`. The first test is the guard; the rest cover the pure conversion helpers, which is where the real logic lives.

```swift
import CoreGraphics
import Testing
@testable import DisplayCore

// MARK: - The guard

@Test func theHiDPIOptionsConstantStillHasTheValueWeDependOn() {
    // Spec §4.1. The symbol's NAME and its VALUE differ: the constant
    // `kCGDisplayShowDuplicateLowResolutionModes` carries the CFString value
    // "kCGDisplayResolution". If a future SDK changes this, the options
    // dictionary silently stops working and the mode list halves with no
    // error. This test is the alarm.
    #expect((kCGDisplayShowDuplicateLowResolutionModes as String) == "kCGDisplayResolution")
}

// MARK: - Conversion

@Test func conversionRoundsRefreshRateToMillihertz() {
    let sig = ModeConversion.signature(
        pointWidth: 2560, pointHeight: 1440,
        pixelWidth: 5120, pixelHeight: 2880,
        refreshRateHz: 59.94,
        isUsableForDesktopGUI: true)

    #expect(sig.refreshMilliHz == 59_940)
}

@Test func conversionKeepsAnUnspecifiedRefreshRateAsZero() {
    // Built-in Apple displays report 0.0 Hz.
    let sig = ModeConversion.signature(
        pointWidth: 1512, pointHeight: 982,
        pixelWidth: 3024, pixelHeight: 1964,
        refreshRateHz: 0.0,
        isUsableForDesktopGUI: true)

    #expect(sig.refreshMilliHz == 0)
}

@Test func conversionRoundsRatherThanTruncates() {
    // 60.0000001 Hz must not become 59_999 mHz through truncation.
    let sig = ModeConversion.signature(
        pointWidth: 1920, pointHeight: 1080,
        pixelWidth: 1920, pixelHeight: 1080,
        refreshRateHz: 59.9999,
        isUsableForDesktopGUI: true)

    #expect(sig.refreshMilliHz == 60_000)
}

@Test func conversionCarriesTheDesktopUsabilityFlagIntoIsSafe() {
    let sig = ModeConversion.signature(
        pointWidth: 1600, pointHeight: 900,
        pixelWidth: 1600, pixelHeight: 900,
        refreshRateHz: 60,
        isUsableForDesktopGUI: false)

    #expect(!sig.isSafe)
}

@Test func stretchedDetectionComparesAspectRatios() {
    // Square pixels: point and pixel aspect agree.
    #expect(!ModeConversion.isStretched(
        pointWidth: 2560, pointHeight: 1440, pixelWidth: 5120, pixelHeight: 2880))
    #expect(!ModeConversion.isStretched(
        pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080))

    // 16:9 points driven onto a 16:10 pixel grid: non-square pixels.
    #expect(ModeConversion.isStretched(
        pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1200))
}

@Test func stretchedDetectionToleratesRoundingInScaledModes() {
    // 1.5x-class scaled modes do not divide evenly and must not be
    // misreported as stretched.
    #expect(!ModeConversion.isStretched(
        pointWidth: 1707, pointHeight: 960, pixelWidth: 3414, pixelHeight: 1920))
}

@Test func deduplicationDropsRepeatedSignaturesKeepingTheFirst() {
    let first = makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 10)
    let duplicate = makeMode(point: (1920, 1080), pixel: (1920, 1080), id: 99)
    let other = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)

    let result = ModeConversion.deduplicated([first, duplicate, other])

    #expect(result == [first, other])
}

@Test func deduplicationKeepsModesThatDifferOnlyInSafety() {
    // The §4.3 collision pair must survive deduplication — they are genuinely
    // different modes, which is the whole reason isSafe is in the signature.
    let safe = makeMode(point: (2560, 1440), pixel: (2560, 1440), safe: true, id: 47)
    let unsafeTwin = makeMode(point: (2560, 1440), pixel: (2560, 1440), safe: false, id: 97)

    #expect(ModeConversion.deduplicated([safe, unsafeTwin]).count == 2)
}

// MARK: - The fake satisfies the protocol

@Test func fakeEnumeratorReportsWhatItWasGiven() throws {
    let device = DisplayDevice(
        displayID: 1, localizedName: "Display 1", isBuiltIn: false, isVirtual: false)
    let mode = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let fake = FakeEnumerator(
        devices: [device],
        modesByDisplay: [1: [mode]],
        currentByDisplay: [1: mode])

    #expect(try fake.onlineDisplayIDs() == [1])
    #expect(try fake.modes(for: 1) == [mode])
    #expect(try fake.currentMode(for: 1) == mode)
    #expect(throws: DisplayError.noSuchDisplay(7)) { try fake.device(for: 7) }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'ModeConversion' in scope`, `cannot find type 'DisplayEnumerating' in scope`.

- [ ] **Step 4: Write `DisplayDevice`**

Create `Sources/DisplayCore/DisplayDevice.swift`:

```swift
import CoreGraphics

/// A physical display as seen in the current session.
///
/// `displayID` is session-scoped: it is reassigned on replug and sometimes
/// across sleep/wake, so it is never persisted (spec §9). Persistent identity
/// arrives with presets in the next plan.
public struct DisplayDevice: Identifiable, Hashable, Sendable {
    public let displayID: CGDirectDisplayID
    public let localizedName: String
    public let isBuiltIn: Bool
    public let isVirtual: Bool

    public var id: CGDirectDisplayID { displayID }

    public init(
        displayID: CGDirectDisplayID,
        localizedName: String,
        isBuiltIn: Bool,
        isVirtual: Bool
    ) {
        self.displayID = displayID
        self.localizedName = localizedName
        self.isBuiltIn = isBuiltIn
        self.isVirtual = isVirtual
    }
}
```

- [ ] **Step 5: Write the read seam**

Create `Sources/DisplayCore/DisplayEnumerating.swift`:

```swift
import CoreGraphics

/// Everything DisplayCore reads from the windowing system.
///
/// Narrow on purpose: this is the seam that lets every consumer be tested
/// against a fake without touching the developer's actual screen.
public protocol DisplayEnumerating: Sendable {
    func onlineDisplayIDs() throws -> [CGDirectDisplayID]
    func device(for id: CGDirectDisplayID) throws -> DisplayDevice
    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode]
    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode
}
```

- [ ] **Step 6: Write the conversion helpers and the real enumerator**

Create `Sources/DisplayCore/CoreGraphicsEnumerator.swift`:

```swift
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
                isUsableForDesktopGUI: CGDisplayModeIsUsableForDesktopGUI(raw)),
            ioDisplayModeID: raw.ioDisplayModeID,
            isStretched: ModeConversion.isStretched(
                pointWidth: raw.width,
                pointHeight: raw.height,
                pixelWidth: raw.pixelWidth,
                pixelHeight: raw.pixelHeight),
            source: .publicAPI)
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 29 tests. If the guard test fails, **stop and report it** — it means the SDK changed the constant and spec §4.1 needs revisiting before any further work.

- [ ] **Step 8: Commit**

```bash
cd ~/Projects/Crisp
git add Sources/DisplayCore Tests/DisplayCoreTests
git commit -m "feat: add the display read seam and CoreGraphics enumerator"
```

---

### Task 4: `displayctl list`

**Files:**
- Create: `Sources/displayctl/ArgumentParsing.swift`
- Create: `Sources/displayctl/Rendering.swift`
- Create: `Sources/displayctl/Commands.swift`
- Modify: `Sources/displayctl/main.swift` (replace the Task 1 placeholder entirely)
- Modify: `Package.swift` (add a test target for the CLI)
- Test: `Tests/displayctlTests/ArgumentParsingTests.swift`
- Test: `Tests/displayctlTests/RenderingTests.swift`

**Interfaces:**
- Consumes: `DisplayEnumerating`, `CoreGraphicsEnumerator`, `DisplayDevice`, `DisplayMode`, `ModeQuery`, `DisplayError` from Tasks 1–3.
- Produces: `Command`, `ListOptions`, `SetOptions`, `ArgumentParser.parse(_:)`, `ParseError`, `Renderer.renderList(...)`, `Renderer.renderListJSON(...)`, `runList(...)`.

This is the first deliverable a person can actually use. Argument parsing is hand-rolled rather than taking `swift-argument-parser`: `displayctl` is the blind recovery path of spec §8.3, typed by someone who cannot see their screen, and every dependency is one more thing that can fail to load at exactly the wrong moment.

`SetOptions` is defined here even though `set` is not wired up until Task 7 — parsing and executing are separate concerns, and testing the parser fully now is cheaper than revisiting it.

- [ ] **Step 1: Add the CLI test target to `Package.swift`**

Replace the `targets:` array with:

```swift
    targets: [
        .target(name: "DisplayCore"),
        .executableTarget(name: "displayctl", dependencies: ["DisplayCore"]),
        .testTarget(
            name: "DisplayCoreTests",
            dependencies: [
                "DisplayCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
        .testTarget(
            name: "displayctlTests",
            dependencies: [
                "displayctl",
                "DisplayCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
```

- [ ] **Step 2: Write the failing parser test**

Create `Tests/displayctlTests/ArgumentParsingTests.swift`:

```swift
import Testing
@testable import DisplayCore
@testable import displayctl

@Test func bareInvocationIsHelp() throws {
    #expect(try ArgumentParser.parse([]) == .help)
    #expect(try ArgumentParser.parse(["--help"]) == .help)
    #expect(try ArgumentParser.parse(["-h"]) == .help)
}

@Test func listDefaultsToAllDisplaysAndFavouredModesOnly() throws {
    let parsed = try ArgumentParser.parse(["list"])
    #expect(parsed == .list(ListOptions(displayIndex: nil, includeAll: false, json: false)))
}

@Test func listAcceptsItsFlags() throws {
    let parsed = try ArgumentParser.parse(["list", "--display", "2", "--all", "--json"])
    #expect(parsed == .list(ListOptions(displayIndex: 2, includeAll: true, json: true)))
}

@Test func setParsesAResolution() throws {
    let parsed = try ArgumentParser.parse(["set", "2560x1440"])
    #expect(parsed == .set(SetOptions(
        width: 2560, height: 1440, displayIndex: nil, refreshMilliHz: nil,
        hiDPI: nil, includeUnsafe: false, includeStretched: false,
        permanent: false, assumeYes: false, timeoutSeconds: 15)))
}

@Test func setAcceptsAnUppercaseSeparator() throws {
    // Someone typing blind, in a panic, with caps lock on.
    let parsed = try ArgumentParser.parse(["set", "2560X1440"])
    #expect(parsed == .set(SetOptions(
        width: 2560, height: 1440, displayIndex: nil, refreshMilliHz: nil,
        hiDPI: nil, includeUnsafe: false, includeStretched: false,
        permanent: false, assumeYes: false, timeoutSeconds: 15)))
}

@Test func setParsesFractionalRefreshRatesIntoMillihertz() throws {
    let parsed = try ArgumentParser.parse(["set", "2560x1440", "--hz", "59.94"])
    guard case .set(let options) = parsed else {
        Issue.record("expected a set command"); return
    }
    #expect(options.refreshMilliHz == 59_940)
}

@Test func setAcceptsItsRemainingFlags() throws {
    let parsed = try ArgumentParser.parse([
        "set", "1920x1080", "--display", "1", "--no-hidpi", "--unsafe",
        "--stretched", "--permanent", "--yes", "--timeout", "30",
    ])
    #expect(parsed == .set(SetOptions(
        width: 1920, height: 1080, displayIndex: 1, refreshMilliHz: nil,
        hiDPI: false, includeUnsafe: true, includeStretched: true,
        permanent: true, assumeYes: true, timeoutSeconds: 30)))
}

@Test func restoreAndDoctorTakeNoArguments() throws {
    #expect(try ArgumentParser.parse(["restore"]) == .restore)
    #expect(try ArgumentParser.parse(["doctor"]) == .doctor)
}

@Test func unknownCommandsAreRejected() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["frobnicate"]) }
}

@Test func setWithoutAResolutionIsRejected() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set"]) }
}

@Test func malformedResolutionsAreRejected() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "2560"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "2560x"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "widexhigh"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "0x1440"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "-100x1440"]) }
}

@Test func flagsExpectingAValueAreRejectedWithoutOne() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["list", "--display"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "800x600", "--hz"]) }
}

@Test func unknownFlagsAreRejectedRatherThanIgnored() {
    // Silently ignoring a typo'd flag on a command that changes the screen is
    // how someone ends up at a resolution they did not ask for.
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["list", "--jsonn"]) }
}
```

- [ ] **Step 3: Write the failing rendering test**

Create `Tests/displayctlTests/RenderingTests.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'ArgumentParser' in scope`.

- [ ] **Step 5: Write the argument parser**

Create `Sources/displayctl/ArgumentParsing.swift`:

```swift
import Foundation

public struct ParseError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct ListOptions: Equatable, Sendable {
    public var displayIndex: Int?
    public var includeAll: Bool
    public var json: Bool

    public init(displayIndex: Int? = nil, includeAll: Bool = false, json: Bool = false) {
        self.displayIndex = displayIndex
        self.includeAll = includeAll
        self.json = json
    }
}

public struct SetOptions: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var displayIndex: Int?
    public var refreshMilliHz: Int?
    public var hiDPI: Bool?
    public var includeUnsafe: Bool
    public var includeStretched: Bool
    public var permanent: Bool
    public var assumeYes: Bool
    public var timeoutSeconds: Int

    public init(
        width: Int,
        height: Int,
        displayIndex: Int? = nil,
        refreshMilliHz: Int? = nil,
        hiDPI: Bool? = nil,
        includeUnsafe: Bool = false,
        includeStretched: Bool = false,
        permanent: Bool = false,
        assumeYes: Bool = false,
        timeoutSeconds: Int = 15
    ) {
        self.width = width
        self.height = height
        self.displayIndex = displayIndex
        self.refreshMilliHz = refreshMilliHz
        self.hiDPI = hiDPI
        self.includeUnsafe = includeUnsafe
        self.includeStretched = includeStretched
        self.permanent = permanent
        self.assumeYes = assumeYes
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum Command: Equatable, Sendable {
    case list(ListOptions)
    case set(SetOptions)
    case restore
    case doctor
    case help
}

public enum ArgumentParser {
    public static func parse(_ arguments: [String]) throws -> Command {
        guard let verb = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())

        switch verb {
        case "--help", "-h", "help": return .help
        case "list": return .list(try parseList(rest))
        case "set": return .set(try parseSet(rest))
        case "restore":
            try requireNoArguments(rest, for: "restore")
            return .restore
        case "doctor":
            try requireNoArguments(rest, for: "doctor")
            return .doctor
        default:
            throw ParseError("unknown command '\(verb)' — try 'displayctl --help'")
        }
    }

    private static func requireNoArguments(_ rest: [String], for verb: String) throws {
        guard rest.isEmpty else {
            throw ParseError("'\(verb)' takes no arguments, got '\(rest[0])'")
        }
    }

    private static func parseList(_ rest: [String]) throws -> ListOptions {
        var options = ListOptions()
        var index = 0
        while index < rest.count {
            switch rest[index] {
            case "--display":
                options.displayIndex = try value(rest, after: &index, flag: "--display")
            case "--all":
                options.includeAll = true
            case "--json":
                options.json = true
            default:
                throw ParseError("unexpected argument '\(rest[index])' for 'list'")
            }
            index += 1
        }
        return options
    }

    private static func parseSet(_ rest: [String]) throws -> SetOptions {
        guard let resolution = rest.first else {
            throw ParseError("'set' needs a resolution, e.g. 'displayctl set 2560x1440'")
        }
        let (width, height) = try parseResolution(resolution)

        var options = SetOptions(width: width, height: height)
        var index = 1
        while index < rest.count {
            switch rest[index] {
            case "--display":
                options.displayIndex = try value(rest, after: &index, flag: "--display")
            case "--hz":
                options.refreshMilliHz = try refreshValue(rest, after: &index)
            case "--hidpi":
                options.hiDPI = true
            case "--no-hidpi":
                options.hiDPI = false
            case "--unsafe":
                options.includeUnsafe = true
            case "--stretched":
                options.includeStretched = true
            case "--permanent":
                options.permanent = true
            case "--yes", "-y":
                options.assumeYes = true
            case "--timeout":
                options.timeoutSeconds = try value(rest, after: &index, flag: "--timeout")
            default:
                throw ParseError("unexpected argument '\(rest[index])' for 'set'")
            }
            index += 1
        }
        return options
    }

    /// Accepts `2560x1440` and `2560X1440` — someone typing this blind should
    /// not be defeated by caps lock.
    private static func parseResolution(_ text: String) throws -> (Int, Int) {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0
        else {
            throw ParseError("'\(text)' is not a resolution — expected WIDTHxHEIGHT, e.g. 2560x1440")
        }
        return (width, height)
    }

    private static func value(
        _ rest: [String], after index: inout Int, flag: String
    ) throws -> Int {
        guard index + 1 < rest.count, let parsed = Int(rest[index + 1]), parsed > 0 else {
            throw ParseError("'\(flag)' needs a positive whole number")
        }
        index += 1
        return parsed
    }

    private static func refreshValue(_ rest: [String], after index: inout Int) throws -> Int {
        guard index + 1 < rest.count, let hz = Double(rest[index + 1]), hz > 0 else {
            throw ParseError("'--hz' needs a refresh rate, e.g. 60 or 59.94")
        }
        index += 1
        return Int((hz * 1000).rounded())
    }
}
```

- [ ] **Step 6: Write the renderer**

Create `Sources/displayctl/Rendering.swift`:

```swift
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
            return "the display configuration did not complete within \(Int(seconds))s"
        case .modeUnavailable(let signature):
            return "the saved mode \(signature.pointWidth)x\(signature.pointHeight) is no longer available"
        case .noMatchingMode(let width, let height):
            return "this display has no \(width)x\(height) mode — run 'displayctl list --all' to see what it does have"
        case .confirmationExpired:
            return "the change was not confirmed in time and was reverted"
        }
    }
}
```

- [ ] **Step 7: Write the `list` command and the entry point**

Create `Sources/displayctl/Commands.swift`:

```swift
import Foundation
import DisplayCore

let helpText = """
displayctl — change display resolutions, including the HiDPI modes
System Settings hides.

USAGE
  displayctl list [--display N] [--all] [--json]
  displayctl set WIDTHxHEIGHT [options]
  displayctl restore
  displayctl doctor

LIST
  --display N    only this display (1-based, as shown by 'list')
  --all          include modes that are unsafe or stretched
  --json         machine-readable output

SET
  --display N    which display to change (default: the main display)
  --hz N         require this refresh rate, e.g. --hz 59.94
  --hidpi        require a HiDPI mode
  --no-hidpi     require a native (non-HiDPI) mode
  --unsafe       allow modes the OS does not advertise as usable
  --stretched    allow modes with non-square pixels
  --permanent    keep the mode across logout and reboot
  --yes, -y      skip the confirmation countdown
  --timeout N    seconds to wait for confirmation (default 15)

RESTORE
  Returns every display to its default mode. This is the recovery path:
  if a mode leaves a screen unreadable, run 'displayctl restore'.
"""

func collectDisplays(
    _ enumerator: DisplayEnumerating,
    options: ListOptions
) throws -> [ListedDisplay] {
    let ids = try enumerator.onlineDisplayIDs()

    var results: [ListedDisplay] = []
    for (offset, id) in ids.enumerated() {
        let index = offset + 1
        if let wanted = options.displayIndex, wanted != index { continue }

        let device = try enumerator.device(for: id)
        var modes = try enumerator.modes(for: id)
        if !options.includeAll {
            modes = modes.filter { $0.isSafe && !$0.isStretched }
        }
        modes.sort {
            $0.pointWidth == $1.pointWidth
                ? $0.refreshMilliHz > $1.refreshMilliHz
                : $0.pointWidth > $1.pointWidth
        }

        results.append(ListedDisplay(
            device: device,
            index: index,
            modes: modes,
            current: try? enumerator.currentMode(for: id)))
    }

    if let wanted = options.displayIndex, results.isEmpty {
        throw ParseError("no display \(wanted) — run 'displayctl list' to see what is connected")
    }
    return results
}

func runList(_ options: ListOptions, enumerator: DisplayEnumerating) throws -> String {
    let displays = try collectDisplays(enumerator, options: options)

    if options.json {
        return try Renderer.renderListJSON(displays)
    }
    return displays
        .map { Renderer.renderList(device: $0.device, index: $0.index, modes: $0.modes, current: $0.current) }
        .joined(separator: "\n\n")
}
```

Replace `Sources/displayctl/main.swift` entirely:

```swift
import Foundation
import DisplayCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("displayctl: \(message)\n".utf8))
    exit(1)
}

let enumerator = CoreGraphicsEnumerator()

do {
    switch try ArgumentParser.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(helpText)
    case .list(let options):
        print(try runList(options, enumerator: enumerator))
    case .set:
        fail("'set' is not wired up yet")
    case .restore:
        fail("'restore' is not wired up yet")
    case .doctor:
        fail("'doctor' is not wired up yet")
    }
} catch let error as ParseError {
    fail(error.message)
} catch let error as DisplayError {
    fail(Renderer.describe(error))
} catch {
    fail("\(error)")
}
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 47 tests.

- [ ] **Step 9: Verify against the real display**

```bash
cd ~/Projects/Crisp && swift run --build-system native displayctl list
```

Expected: at least one display, with HiDPI modes present. On the reference LG 5K this shows `2560 x 1440  (5120 x 2880 HiDPI)` marked with `*`.

**This is the check that retires the project's core risk.** If no HiDPI modes appear, the options dictionary is wrong — re-read spec §4.1 and the comment in `CoreGraphicsEnumerator.modes(for:)` before going further.

- [ ] **Step 10: Record the regression fixture**

```bash
cd ~/Projects/Crisp && mkdir -p Tests/Fixtures \
  && swift run --build-system native displayctl list --all --json > Tests/Fixtures/reference-display-modes.json \
  && head -30 Tests/Fixtures/reference-display-modes.json
```

Spec §14 asks for this: a recorded mode table from a known-good OS, so a future macOS release can be diffed against it rather than argued about.

- [ ] **Step 11: Commit**

```bash
cd ~/Projects/Crisp
git add Package.swift Sources/displayctl Tests/displayctlTests Tests/Fixtures
git commit -m "feat: add displayctl list with text and JSON output"
```

---

### Task 5: The write seam, the transaction, and the watchdog

**Files:**
- Create: `Sources/DisplayCore/DisplayConfiguring.swift`
- Create: `Sources/DisplayCore/CoreGraphicsConfigurator.swift`
- Modify: `Tests/DisplayCoreTests/Fakes.swift` (append `FakeConfigurator`)
- Test: `Tests/DisplayCoreTests/CoreGraphicsConfiguratorTests.swift`

**Interfaces:**
- Consumes: `DisplayMode`, `DisplayError`, `ModeSignature` from Tasks 1–3.
- Produces: `ConfigurationScope`, `DisplayConfiguring`, `CoreGraphicsConfigurator`, `Watchdog.run(timeout:work:)`, and the test fake `FakeConfigurator`.

Three spec requirements land here, and each is a decision that is hard to retrofit:

- **One transaction for all displays** (§8.1). Configuring displays one at a time makes the desktop re-lay-out once per display and scrambles window positions.
- **`.session` by default, never `.permanent`** (§8.1). Applying permanently up front is the direct cause of "it reverted and I can't undo it" reports in this category of app.
- **A 5-second watchdog** (§8.1). `CGCompleteDisplayConfiguration` is documented to hang; blocking the caller forever is not an option.

The `apply` protocol takes the whole plan in one call rather than exposing begin/set/complete. Atomicity then becomes an invariant of the implementation instead of something every caller has to remember.

- [ ] **Step 1: Append `FakeConfigurator` to `Tests/DisplayCoreTests/Fakes.swift`**

```swift
/// Records what it was asked to do and never touches a real display.
final class FakeConfigurator: DisplayConfiguring, @unchecked Sendable {
    struct Application: Equatable {
        let plan: [CGDirectDisplayID: DisplayMode]
        let scope: ConfigurationScope
    }

    private(set) var applications: [Application] = []
    private(set) var restoreCount = 0

    /// Thrown by the next `apply` call, then cleared.
    var nextApplyError: DisplayError?

    func apply(
        _ plan: [CGDirectDisplayID: DisplayMode],
        scope: ConfigurationScope
    ) throws {
        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }
        applications.append(Application(plan: plan, scope: scope))
    }

    func restoreDefaults() throws {
        restoreCount += 1
    }

    var scopeSequence: [ConfigurationScope] { applications.map(\.scope) }
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/DisplayCoreTests/CoreGraphicsConfiguratorTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

// MARK: - Watchdog

@Test func watchdogReturnsTheResultWhenWorkFinishesInTime() throws {
    let result = try Watchdog.run(timeout: 2.0) { 0 }
    #expect(result == 0)
}

@Test func watchdogThrowsWhenWorkOverrunsTheWindow() {
    #expect(throws: DisplayError.completionTimedOut(seconds: 0.2)) {
        try Watchdog.run(timeout: 0.2) {
            Thread.sleep(forTimeInterval: 1.0)
            return 0
        }
    }
}

@Test func watchdogPropagatesANonZeroResultRatherThanSwallowingIt() throws {
    let result = try Watchdog.run(timeout: 2.0) { 1_004 }
    #expect(result == 1_004)
}

// MARK: - Mode hint validation

@Test func hintValidationAcceptsAMatchingSignature() {
    let mode = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    #expect(CoreGraphicsConfigurator.hintIsValid(mode, against: mode.signature))
}

@Test func hintValidationRejectsAStaleSignature() {
    // Spec §4.2 and §10: ioDisplayModeID is an O(1) hint, not an identity.
    // After an OS update the same numeric ID can point at a different mode,
    // and applying it unvalidated silently changes the resolution.
    let stored = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
    let whatIDNowPointsAt = makeMode(point: (1920, 1080), pixel: (3840, 2160), id: 48)

    #expect(!CoreGraphicsConfigurator.hintIsValid(whatIDNowPointsAt, against: stored.signature))
}

// MARK: - The fake honours the contract

@Test func fakeConfiguratorRecordsScopeAndPlan() throws {
    let configurator = FakeConfigurator()
    let mode = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)

    try configurator.apply([1: mode], scope: .session)

    #expect(configurator.applications.count == 1)
    #expect(configurator.applications[0].plan == [1: mode])
    #expect(configurator.applications[0].scope == .session)
}

@Test func fakeConfiguratorThrowsOnceWhenPrimed() {
    let configurator = FakeConfigurator()
    configurator.nextApplyError = .configurationFailed(code: 1_000)

    #expect(throws: DisplayError.configurationFailed(code: 1_000)) {
        try configurator.apply([:], scope: .session)
    }
    #expect(throws: Never.self) { try configurator.apply([:], scope: .session) }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'Watchdog' in scope`.

- [ ] **Step 4: Write the write seam**

Create `Sources/DisplayCore/DisplayConfiguring.swift`:

```swift
import CoreGraphics

/// How long a configuration change survives.
public enum ConfigurationScope: Equatable, Sendable {
    /// Lasts until logout. The only scope a change is ever applied in first —
    /// spec §8.1 — so that an unreadable result is always escapable.
    case session

    /// Survives logout and reboot. Only ever used after confirmation.
    case permanent
}

/// Everything DisplayCore writes to the windowing system.
///
/// `apply` takes the whole plan because a multi-display change must land in a
/// single transaction (spec §8.1); splitting it across calls would re-lay-out
/// the desktop once per display.
public protocol DisplayConfiguring: AnyObject, Sendable {
    func apply(_ plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope) throws
    func restoreDefaults() throws
}
```

- [ ] **Step 5: Write the configurator and the watchdog**

Create `Sources/DisplayCore/CoreGraphicsConfigurator.swift`:

```swift
import CoreGraphics
import Foundation

/// Runs a blocking call with a deadline.
///
/// `CGCompleteDisplayConfiguration` is documented to hang in some
/// configurations. It cannot be cancelled, so on timeout the work item is
/// abandoned rather than killed — the caller gets control back and the user
/// gets an error instead of a frozen app.
public enum Watchdog {
    public static func run(
        timeout: TimeInterval,
        work: @escaping @Sendable () -> Int32
    ) throws -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw DisplayError.completionTimedOut(seconds: timeout)
        }
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Int32 = 0
    }
}

/// The real write path.
public final class CoreGraphicsConfigurator: DisplayConfiguring {
    private let completionTimeout: TimeInterval

    public init(completionTimeout: TimeInterval = 5.0) {
        self.completionTimeout = completionTimeout
    }

    /// Whether a mode reached via its `ioDisplayModeID` hint is still the mode
    /// that was recorded. Spec §10: the hint gives an O(1) apply, but it is
    /// validated every time so staleness is detected rather than acted on.
    public static func hintIsValid(_ mode: DisplayMode, against signature: ModeSignature) -> Bool {
        mode.signature == signature
    }

    public func apply(
        _ plan: [CGDirectDisplayID: DisplayMode],
        scope: ConfigurationScope
    ) throws {
        guard !plan.isEmpty else { return }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw DisplayError.configurationFailed(code: beginResult.rawValue)
        }

        // From here on, every failure path must cancel — an abandoned
        // configuration handle leaves the window server in a transaction.
        do {
            for (displayID, mode) in plan {
                let raw = try resolveRawMode(mode, on: displayID)
                let result = CGConfigureDisplayWithDisplayMode(
                    configuration, displayID, raw, nil)
                guard result == .success else {
                    throw DisplayError.configurationFailed(code: result.rawValue)
                }
            }
        } catch {
            CGCancelDisplayConfiguration(configuration)
            throw error
        }

        let option: CGConfigureOption = scope == .permanent ? .permanently : .forSession
        let completion = try Watchdog.run(timeout: completionTimeout) {
            CGCompleteDisplayConfiguration(configuration, option).rawValue
        }

        guard completion == CGError.success.rawValue else {
            throw DisplayError.configurationFailed(code: completion)
        }
    }

    public func restoreDefaults() throws {
        // Spec §8.3: this is the panic path and deliberately restores every
        // display. A user who cannot see a screen cannot tell you which one.
        CGRestorePermanentDisplayConfiguration()
    }

    /// Finds the `CGDisplayMode` corresponding to one of our modes, preferring
    /// the O(1) hint but never trusting it unvalidated.
    private func resolveRawMode(
        _ mode: DisplayMode,
        on displayID: CGDirectDisplayID
    ) throws -> CGDisplayMode {
        // Same constant discipline as CoreGraphicsEnumerator — see spec §4.1.
        let options = [
            kCGDisplayShowDuplicateLowResolutionModes as String: true
        ] as CFDictionary

        guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            throw DisplayError.modeEnumerationFailed(displayID)
        }

        func signature(of candidate: CGDisplayMode) -> ModeSignature {
            ModeConversion.signature(
                pointWidth: candidate.width,
                pointHeight: candidate.height,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight,
                refreshRateHz: candidate.refreshRate,
                isUsableForDesktopGUI: CGDisplayModeIsUsableForDesktopGUI(candidate))
        }

        // Fast path: the hint, validated.
        if let hinted = raw.first(where: { $0.ioDisplayModeID == mode.ioDisplayModeID }),
           signature(of: hinted) == mode.signature {
            return hinted
        }

        // Slow path: the hint was stale, so search by signature.
        if let found = raw.first(where: { signature(of: $0) == mode.signature }) {
            return found
        }

        throw DisplayError.modeUnavailable(mode.signature)
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 54 tests. No test in this task changes the display — `CoreGraphicsConfigurator.apply` is never called from a test, only its pure helpers.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/Crisp
git add Sources/DisplayCore Tests/DisplayCoreTests
git commit -m "feat: add the display write seam with transaction and watchdog"
```

---

### Task 6: Confirm-or-revert

**Files:**
- Create: `Sources/DisplayCore/MonotonicClock.swift`
- Create: `Sources/DisplayCore/RevertCoordinator.swift`
- Modify: `Tests/DisplayCoreTests/Fakes.swift` (append `FakeClock`)
- Test: `Tests/DisplayCoreTests/RevertCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DisplayConfiguring`, `ConfigurationScope`, `DisplayMode`, `DisplayError` from Task 5.
- Produces: `MonotonicClock`, `SystemClock`, `PendingChange`, `RevertCoordinator` with `begin(target:previous:)`, `confirm(_:)`, `revert(_:)`, `expireIfNeeded(_:)`, `secondsRemaining(for:)`.

The state machine from spec §8.2, kept entirely free of UI and of real time so the 15-second window can be tested in microseconds. The app in a later plan drives this with a countdown panel; `displayctl` drives it with a terminal prompt. Neither variation belongs in here.

- [ ] **Step 1: Append `FakeClock` to `Tests/DisplayCoreTests/Fakes.swift`**

```swift
/// A clock that only moves when a test moves it.
final class FakeClock: MonotonicClock, @unchecked Sendable {
    private var seconds: Double

    init(startingAt seconds: Double = 0) {
        self.seconds = seconds
    }

    var nowSeconds: Double { seconds }

    func advance(by interval: Double) {
        seconds += interval
    }
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/DisplayCoreTests/RevertCoordinatorTests.swift`:

```swift
import CoreGraphics
import Testing
@testable import DisplayCore

private let target = makeMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
private let previous = makeMode(point: (1920, 1080), pixel: (3840, 2160), id: 12)

@Test func beginAppliesForTheSessionOnlyNeverPermanently() throws {
    // The single most important assertion in this file. Spec §8.1: applying
    // permanently before confirmation is what makes a bad mode unescapable.
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    _ = try coordinator.begin(target: [1: target], previous: [1: previous])

    #expect(configurator.scopeSequence == [.session])
    #expect(configurator.applications[0].plan == [1: target])
}

@Test func confirmReappliesTheSameModePermanently() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.confirm(change)

    #expect(configurator.scopeSequence == [.session, .permanent])
    #expect(configurator.applications[1].plan == [1: target])
}

@Test func confirmingWithSessionScopeDoesNotEscalatePermanence() throws {
    // `displayctl set` without --permanent confirms in session scope. If this
    // silently applied permanently, a mode the user never asked to persist
    // would survive a reboot.
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.confirm(change, scope: .session)

    #expect(configurator.scopeSequence == [.session, .session])
}

@Test func revertRestoresThePreviousModeForTheSession() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    try coordinator.revert(change)

    #expect(configurator.scopeSequence == [.session, .session])
    #expect(configurator.applications[1].plan == [1: previous])
}

@Test func expiryDoesNothingBeforeTheDeadline() throws {
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 14.9)

    #expect(try coordinator.expireIfNeeded(change) == false)
    #expect(configurator.applications.count == 1)
}

@Test func expiryRevertsOnceTheDeadlinePasses() throws {
    let clock = FakeClock()
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(configurator: configurator, clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 15.0)

    #expect(try coordinator.expireIfNeeded(change) == true)
    #expect(configurator.applications.last?.plan == [1: previous])
    #expect(configurator.applications.last?.scope == .session)
}

@Test func secondsRemainingCountsDownAndFloorsAtZero() throws {
    let clock = FakeClock()
    let coordinator = RevertCoordinator(
        configurator: FakeConfigurator(), clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    #expect(coordinator.secondsRemaining(for: change) == 15)

    clock.advance(by: 10)
    #expect(coordinator.secondsRemaining(for: change) == 5)

    clock.advance(by: 100)
    #expect(coordinator.secondsRemaining(for: change) == 0)
}

@Test func aFailedApplyLeavesNothingPending() {
    let configurator = FakeConfigurator()
    configurator.nextApplyError = .configurationFailed(code: 1_000)
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)

    #expect(throws: DisplayError.configurationFailed(code: 1_000)) {
        _ = try coordinator.begin(target: [1: target], previous: [1: previous])
    }
    #expect(configurator.applications.isEmpty)
}

@Test func confirmingAnExpiredChangeIsRefused() throws {
    // Otherwise a slow user confirms a mode that was already reverted, and the
    // screen changes back under them.
    let clock = FakeClock()
    let coordinator = RevertCoordinator(
        configurator: FakeConfigurator(), clock: clock, window: 15)

    let change = try coordinator.begin(target: [1: target], previous: [1: previous])
    clock.advance(by: 20)

    #expect(throws: DisplayError.confirmationExpired) { try coordinator.confirm(change) }
}

@Test func multiDisplayPlansAreCarriedThroughIntact() throws {
    let configurator = FakeConfigurator()
    let coordinator = RevertCoordinator(
        configurator: configurator, clock: FakeClock(), window: 15)
    let second = makeMode(point: (1512, 982), pixel: (3024, 1964), mHz: 0, id: 3)

    let change = try coordinator.begin(
        target: [1: target, 2: second],
        previous: [1: previous, 2: second])
    try coordinator.confirm(change)

    // One transaction per phase, both displays inside it. Spec §8.1.
    #expect(configurator.applications.count == 2)
    #expect(configurator.applications[0].plan.count == 2)
    #expect(configurator.applications[1].plan.count == 2)
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'RevertCoordinator' in scope`.

- [ ] **Step 4: Write the clock**

Create `Sources/DisplayCore/MonotonicClock.swift`:

```swift
import Foundation

/// Time, injected.
///
/// A monotonic source specifically: the revert deadline must not move when the
/// wall clock is adjusted, or an NTP correction mid-countdown either reverts a
/// good mode early or strands a bad one.
public protocol MonotonicClock: Sendable {
    var nowSeconds: Double { get }
}

public struct SystemClock: MonotonicClock {
    public init() {}

    /// Time since boot; unaffected by wall-clock adjustments.
    public var nowSeconds: Double { ProcessInfo.processInfo.systemUptime }
}
```

- [ ] **Step 5: Write the coordinator**

Create `Sources/DisplayCore/RevertCoordinator.swift`:

```swift
import CoreGraphics
import Foundation

/// A mode change that has been applied for the session but not yet confirmed.
public struct PendingChange: Equatable, Sendable {
    public let target: [CGDirectDisplayID: DisplayMode]
    public let previous: [CGDirectDisplayID: DisplayMode]
    public let deadline: Double
}

/// The confirm-or-revert state machine of spec §8.2.
///
/// Holds no timer and no UI. Callers drive `expireIfNeeded` from whatever run
/// loop they have — a countdown panel in the app, a polling prompt in the CLI —
/// which is also why every branch of this is testable in microseconds.
public final class RevertCoordinator {
    private let configurator: DisplayConfiguring
    private let clock: MonotonicClock
    private let window: TimeInterval

    public init(
        configurator: DisplayConfiguring,
        clock: MonotonicClock,
        window: TimeInterval = 15
    ) {
        self.configurator = configurator
        self.clock = clock
        self.window = window
    }

    /// Applies the change for the session only and starts the clock.
    public func begin(
        target: [CGDirectDisplayID: DisplayMode],
        previous: [CGDirectDisplayID: DisplayMode]
    ) throws -> PendingChange {
        // Apply first, then hand back the pending change. If this throws, the
        // caller has nothing to confirm or revert, which is correct — nothing
        // happened.
        try configurator.apply(target, scope: .session)

        return PendingChange(
            target: target,
            previous: previous,
            deadline: clock.nowSeconds + window)
    }

    /// The user can see the screen. Stop the countdown.
    ///
    /// The scope is the caller's: confirming means "keep this now", which is
    /// not the same as "keep this across reboots". Only an explicit request for
    /// permanence should escalate past `.session` — see spec §8.1.
    public func confirm(
        _ change: PendingChange,
        scope: ConfigurationScope = .permanent
    ) throws {
        guard clock.nowSeconds < change.deadline else {
            throw DisplayError.confirmationExpired
        }
        try configurator.apply(change.target, scope: scope)
    }

    /// Put it back. Session scope, because the previous mode's own permanence
    /// was already settled when it was applied.
    public func revert(_ change: PendingChange) throws {
        try configurator.apply(change.previous, scope: .session)
    }

    /// Reverts if the deadline has passed. Returns whether it did.
    @discardableResult
    public func expireIfNeeded(_ change: PendingChange) throws -> Bool {
        guard clock.nowSeconds >= change.deadline else { return false }
        try revert(change)
        return true
    }

    public func secondsRemaining(for change: PendingChange) -> Int {
        max(0, Int((change.deadline - clock.nowSeconds).rounded(.up)))
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 64 tests.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/Crisp
git add Sources/DisplayCore Tests/DisplayCoreTests
git commit -m "feat: add the confirm-or-revert coordinator"
```

---

### Task 7: `displayctl set`, `restore`, and `doctor`

**Files:**
- Create: `Sources/displayctl/Confirmation.swift`
- Create: `Sources/displayctl/Doctor.swift`
- Modify: `Sources/displayctl/Commands.swift` (append `resolveDisplay`, `runSet`, `runRestore`)
- Modify: `Sources/displayctl/Rendering.swift` (append the `set` renderers)
- Modify: `Sources/displayctl/main.swift` (replace the three `fail(...)` stubs)
- Create: `Tests/displayctlTests/CLIFakes.swift`
- Test: `Tests/displayctlTests/SetCommandTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: `Confirmation`, `ConfirmationSource`, `StandardInputConfirmation`, `SetOutcome`, `resolveDisplay(index:enumerator:)`, `runSet(...)`, `runRestore(...)`, `Doctor.report(enumerator:)`, `Renderer.renderSetPrompt(_:seconds:)`, `Renderer.renderApplied(_:permanent:)`, `Renderer.renderReverted(_:)`, `Renderer.renderAlreadyActive(_:)`.

The last task, and the one that closes the loop: after this, milestone 2 of spec §16 is done and there is a tool that changes resolutions safely from a terminal.

Three notes on the shape of this:

- **`runSet` returns a `SetOutcome` rather than printing.** Printing from inside the decision logic would make every branch untestable, and these are exactly the branches that must not be wrong.
- **Waiting for confirmation is behind `ConfirmationSource`.** Real stdin in production; a scripted answer in tests. Otherwise testing the timeout path costs 15 real seconds.
- **`doctor` exists because of spec §4.1.** The HiDPI-modes failure is silent — the wrong dictionary key yields a plausible-looking short list, not an error. `doctor` makes that failure visible in the field, on a machine you do not have.

- [ ] **Step 1: Write the failing test**

Create `Tests/displayctlTests/CLIFakes.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore
@testable import displayctl

// Deliberately duplicated from Tests/DisplayCoreTests/Fakes.swift: SwiftPM test
// targets cannot see each other's sources, and adding a shared support target
// to ship two structs is a worse trade than twenty lines of duplication.

func cliMode(
    point: (Int, Int),
    pixel: (Int, Int),
    mHz: Int = 60_000,
    safe: Bool = true,
    stretched: Bool = false,
    id: Int32
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

final class CLIFakeEnumerator: DisplayEnumerating, @unchecked Sendable {
    var ids: [CGDirectDisplayID] = [1]
    var modesByID: [CGDirectDisplayID: [DisplayMode]] = [:]
    var currentByID: [CGDirectDisplayID: DisplayMode] = [:]

    func onlineDisplayIDs() throws -> [CGDirectDisplayID] { ids }

    func device(for id: CGDirectDisplayID) throws -> DisplayDevice {
        guard ids.contains(id) else { throw DisplayError.noSuchDisplay(id) }
        return DisplayDevice(
            displayID: id, localizedName: "Display \(id)",
            isBuiltIn: false, isVirtual: false)
    }

    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode] {
        guard let modes = modesByID[id] else {
            throw DisplayError.modeEnumerationFailed(id)
        }
        return modes
    }

    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode {
        guard let mode = currentByID[id] else {
            throw DisplayError.currentModeUnavailable(id)
        }
        return mode
    }
}

final class CLIFakeConfigurator: DisplayConfiguring, @unchecked Sendable {
    private(set) var applications: [(plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope)] = []
    private(set) var restoreCount = 0

    func apply(_ plan: [CGDirectDisplayID: DisplayMode], scope: ConfigurationScope) throws {
        applications.append((plan, scope))
    }

    func restoreDefaults() throws { restoreCount += 1 }

    var scopeSequence: [ConfigurationScope] { applications.map(\.scope) }
}

final class ScriptedConfirmation: ConfirmationSource, @unchecked Sendable {
    private let answer: Confirmation
    private(set) var timeoutsSeen: [Int] = []

    init(_ answer: Confirmation) { self.answer = answer }

    func awaitConfirmation(timeoutSeconds: Int) -> Confirmation {
        timeoutsSeen.append(timeoutSeconds)
        return answer
    }
}

final class SteppingClock: MonotonicClock, @unchecked Sendable {
    private var seconds: Double = 0
    var nowSeconds: Double { seconds }
    func advance(by interval: Double) { seconds += interval }
}
```

Create `Tests/displayctlTests/SetCommandTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore
@testable import displayctl

private let hidpi = cliMode(point: (2560, 1440), pixel: (5120, 2880), id: 48)
private let native = cliMode(point: (1920, 1080), pixel: (1920, 1080), id: 12)
private let stretched = cliMode(
    point: (1600, 1200), pixel: (2560, 1440), stretched: true, id: 70)

private func fixture(
    current: DisplayMode = native,
    modes: [DisplayMode] = [hidpi, native, stretched]
) -> CLIFakeEnumerator {
    let enumerator = CLIFakeEnumerator()
    enumerator.modesByID = [1: modes]
    enumerator.currentByID = [1: current]
    return enumerator
}

private func options(
    width: Int = 2560,
    height: Int = 1440,
    permanent: Bool = false,
    assumeYes: Bool = false,
    timeout: Int = 15
) -> SetOptions {
    SetOptions(
        width: width, height: height,
        displayIndex: nil, refreshMilliHz: nil, hiDPI: nil,
        includeUnsafe: false, includeStretched: false,
        permanent: permanent, assumeYes: assumeYes,
        timeoutSeconds: timeout)
}

private func coordinator(
    _ configurator: DisplayConfiguring,
    clock: MonotonicClock = SteppingClock(),
    window: TimeInterval = 15
) -> RevertCoordinator {
    RevertCoordinator(configurator: configurator, clock: clock, window: window)
}

// MARK: - Display selection

@Test func displayIndexIsOneBasedAndMatchesTheListOutput() throws {
    let enumerator = fixture()
    enumerator.ids = [7, 9]

    #expect(try resolveDisplay(index: 1, enumerator: enumerator) == 7)
    #expect(try resolveDisplay(index: 2, enumerator: enumerator) == 9)
}

@Test func omittingTheDisplayIndexSelectsTheFirstDisplay() throws {
    let enumerator = fixture()
    enumerator.ids = [7, 9]

    #expect(try resolveDisplay(index: nil, enumerator: enumerator) == 7)
}

@Test func anOutOfRangeDisplayIndexIsRejectedBeforeAnythingIsApplied() {
    let enumerator = fixture()

    #expect(throws: ParseError.self) {
        _ = try resolveDisplay(index: 4, enumerator: enumerator)
    }
}

// MARK: - The happy path

@Test func confirmingWithinTheWindowAppliesForTheSessionThenPermanently() throws {
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(permanent: true),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(outcome.result == .applied)
    #expect(configurator.scopeSequence == [.session, .permanent])
    #expect(configurator.applications[0].plan == [1: hidpi])
}

@Test func withoutPermanentTheChangeIsNeverEscalatedPastTheSession() throws {
    // Spec §8.1: `--permanent` is opt-in. A change the user did not ask to
    // persist must not survive a reboot, which is the escape hatch of last
    // resort for a mode that turns out to be wrong later.
    let configurator = CLIFakeConfigurator()
    _ = try runSet(
        options(permanent: false),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(!configurator.scopeSequence.contains(.permanent))
}

@Test func assumeYesSkipsTheConfirmationSourceEntirely() throws {
    let confirmation = ScriptedConfirmation(.timedOut)
    let configurator = CLIFakeConfigurator()

    let outcome = try runSet(
        options(permanent: true, assumeYes: true),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: confirmation)

    #expect(outcome.result == .applied)
    #expect(confirmation.timeoutsSeen.isEmpty)
    #expect(configurator.scopeSequence == [.session, .permanent])
}

// MARK: - The paths that save a user

@Test func decliningRevertsToThePreviousMode() throws {
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.declined))

    #expect(outcome.result == .reverted(reason: .declined))
    #expect(configurator.applications.last?.plan == [1: native])
    #expect(configurator.applications.last?.scope == .session)
}

@Test func silenceRevertsToThePreviousMode() throws {
    // The case this whole design exists for: the user cannot see the prompt
    // because the mode they just chose made the screen unreadable.
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(),
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.timedOut))

    #expect(outcome.result == .reverted(reason: .timedOut))
    #expect(configurator.applications.last?.plan == [1: native])
}

@Test func theConfirmationDeadlineAndThePromptTimeoutAreTheSameNumber() throws {
    // If the prompt waited longer than the coordinator's window, confirming at
    // second 19 of a 15-second window would throw instead of working.
    let confirmation = ScriptedConfirmation(.timedOut)
    _ = try runSet(
        options(timeout: 30),
        enumerator: fixture(),
        coordinator: coordinator(CLIFakeConfigurator(), window: 30),
        confirmation: confirmation)

    #expect(confirmation.timeoutsSeen == [30])
}

// MARK: - Refusals

@Test func askingForTheModeThatIsAlreadyActiveChangesNothing() throws {
    let configurator = CLIFakeConfigurator()
    let outcome = try runSet(
        options(width: 1920, height: 1080),
        enumerator: fixture(current: native),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(outcome.result == .alreadyActive)
    #expect(configurator.applications.isEmpty)
}

@Test func anUnavailableSizeIsRefusedWithAnActionableError() {
    #expect(throws: DisplayError.noMatchingMode(requestedWidth: 3200, requestedHeight: 1800)) {
        _ = try runSet(
            options(width: 3200, height: 1800),
            enumerator: fixture(),
            coordinator: coordinator(CLIFakeConfigurator()),
            confirmation: ScriptedConfirmation(.confirmed))
    }
}

@Test func stretchedModesAreExcludedUnlessAskedFor() {
    // 1600x1200 exists only as a stretched mode in the fixture.
    #expect(throws: DisplayError.noMatchingMode(requestedWidth: 1600, requestedHeight: 1200)) {
        _ = try runSet(
            options(width: 1600, height: 1200),
            enumerator: fixture(),
            coordinator: coordinator(CLIFakeConfigurator()),
            confirmation: ScriptedConfirmation(.confirmed))
    }
}

@Test func stretchedModesAreReachableWhenExplicitlyAllowed() throws {
    var opts = options(width: 1600, height: 1200, permanent: true)
    opts.includeStretched = true
    let configurator = CLIFakeConfigurator()

    let outcome = try runSet(
        opts,
        enumerator: fixture(),
        coordinator: coordinator(configurator),
        confirmation: ScriptedConfirmation(.confirmed))

    #expect(outcome.result == .applied)
    #expect(configurator.applications[0].plan == [1: stretched])
}

// MARK: - restore

@Test func restoreGoesStraightToTheConfigurator() throws {
    let configurator = CLIFakeConfigurator()
    let message = try runRestore(configurator: configurator)

    #expect(configurator.restoreCount == 1)
    #expect(configurator.applications.isEmpty)
    #expect(message.contains("restore"))
}

// MARK: - doctor

@Test func doctorReportsTheHiDPIConstantAndTheModeCounts() throws {
    let report = try Doctor.report(enumerator: fixture())

    #expect(report.contains("kCGDisplayResolution"))
    #expect(report.contains("3 modes"))
    #expect(report.contains("1 HiDPI"))
}

@Test func doctorWarnsWhenNoHiDPIModesAreVisibleAtAll() throws {
    // The exact symptom of the spec §4.1 constant regression.
    let report = try Doctor.report(enumerator: fixture(current: native, modes: [native]))

    #expect(report.contains("no HiDPI modes"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: FAIL — `cannot find 'runSet' in scope`.

- [ ] **Step 3: Write the confirmation source**

Create `Sources/displayctl/Confirmation.swift`:

```swift
import Foundation

public enum Confirmation: Equatable, Sendable {
    case confirmed
    case declined
    case timedOut
}

/// Where the answer to "can you see this?" comes from.
public protocol ConfirmationSource: Sendable {
    func awaitConfirmation(timeoutSeconds: Int) -> Confirmation
}

/// Reads one line from stdin, giving up after the timeout.
///
/// `readLine` cannot be cancelled, so on timeout the reader thread is left
/// blocked and the process exits with it. That is acceptable here and only
/// here: this is a short-lived CLI, and the alternative — raw-mode terminal
/// handling with a select loop — is a lot of machinery to save a thread that
/// dies milliseconds later.
public struct StandardInputConfirmation: ConfirmationSource {
    public init() {}

    public func awaitConfirmation(timeoutSeconds: Int) -> Confirmation {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()

        Thread.detachNewThread {
            let line = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            box.answer = (line == nil || line == "n" || line == "no")
                ? .declined
                : .confirmed
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            return .timedOut
        }
        return box.answer
    }

    private final class AnswerBox: @unchecked Sendable {
        var answer: Confirmation = .declined
    }
}
```

- [ ] **Step 4: Write `doctor`**

Create `Sources/displayctl/Doctor.swift`:

```swift
import CoreGraphics
import Foundation
import DisplayCore

/// Field diagnostics for the failure mode of spec §4.1.
///
/// Building the enumeration options from a string literal instead of the
/// linked constant returns a shorter list with no HiDPI modes — no error, no
/// warning, just a wrong answer. On a machine you cannot inspect, this report
/// is how you find out.
public enum Doctor {
    public static func report(enumerator: DisplayEnumerating) throws -> String {
        var lines: [String] = []

        lines.append("displayctl doctor")
        lines.append("")
        lines.append("HiDPI enumeration key")
        lines.append("  kCGDisplayShowDuplicateLowResolutionModes = "
            + "\"\(kCGDisplayShowDuplicateLowResolutionModes as String)\"")
        lines.append("  expected: \"kCGDisplayResolution\"")

        if (kCGDisplayShowDuplicateLowResolutionModes as String) != "kCGDisplayResolution" {
            lines.append("  WARNING: the constant changed value. HiDPI enumeration is")
            lines.append("           unverified on this OS version.")
        }

        lines.append("")
        lines.append("Displays")

        var sawAnyHiDPI = false
        for (offset, id) in try enumerator.onlineDisplayIDs().enumerated() {
            let device = try enumerator.device(for: id)
            let modes = try enumerator.modes(for: id)
            let hidpi = modes.filter(\.isHiDPI)
            sawAnyHiDPI = sawAnyHiDPI || !hidpi.isEmpty

            lines.append("  [\(offset + 1)] \(device.localizedName) (ID \(id))")
            lines.append("      \(modes.count) modes, \(hidpi.count) HiDPI, "
                + "\(modes.filter { !$0.isSafe }.count) unsafe, "
                + "\(modes.filter(\.isStretched).count) stretched")

            if let current = try? enumerator.currentMode(for: id) {
                lines.append("      current: \(current.pointWidth)x\(current.pointHeight)"
                    + " (\(current.pixelWidth)x\(current.pixelHeight) px)")
            }
        }

        if !sawAnyHiDPI {
            lines.append("")
            lines.append("WARNING: no HiDPI modes on any display. On a Retina or scaled")
            lines.append("         external display this means enumeration is broken —")
            lines.append("         see the HiDPI enumeration key above.")
        }

        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 5: Write `set` and `restore`**

Append to `Sources/displayctl/Commands.swift`:

```swift
public struct SetOutcome: Equatable, Sendable {
    public enum RevertReason: Equatable, Sendable {
        case declined
        case timedOut
    }

    public enum Result: Equatable, Sendable {
        case applied
        case alreadyActive
        case reverted(reason: RevertReason)
    }

    public let result: Result
    public let message: String
}

/// Turns the 1-based index the user sees in `list` into a display ID.
func resolveDisplay(
    index: Int?,
    enumerator: DisplayEnumerating
) throws -> CGDirectDisplayID {
    let ids = try enumerator.onlineDisplayIDs()
    guard let first = ids.first else {
        throw ParseError("no displays are connected")
    }
    guard let index else { return first }
    guard index >= 1, index <= ids.count else {
        throw ParseError(
            "no display \(index) — this Mac has \(ids.count); run 'displayctl list'")
    }
    return ids[index - 1]
}

func runSet(
    _ options: SetOptions,
    enumerator: DisplayEnumerating,
    coordinator: RevertCoordinator,
    confirmation: ConfirmationSource,
    log: (String) -> Void = { print($0) }
) throws -> SetOutcome {
    let displayID = try resolveDisplay(index: options.displayIndex, enumerator: enumerator)
    let modes = try enumerator.modes(for: displayID)
    let current = try enumerator.currentMode(for: displayID)

    let query = ModeQuery(
        pointWidth: options.width,
        pointHeight: options.height,
        refreshMilliHz: options.refreshMilliHz,
        hiDPI: options.hiDPI,
        includeUnsafe: options.includeUnsafe,
        includeStretched: options.includeStretched)

    guard let chosen = ModeMatcher.resolve(query, in: modes).first else {
        throw DisplayError.noMatchingMode(
            requestedWidth: options.width, requestedHeight: options.height)
    }

    guard chosen.signature != current.signature else {
        return SetOutcome(
            result: .alreadyActive,
            message: Renderer.renderAlreadyActive(chosen))
    }

    // From here the screen is about to change. Everything below is the
    // confirm-or-revert contract of spec §8.2.
    let change = try coordinator.begin(
        target: [displayID: chosen], previous: [displayID: current])

    let answer: Confirmation
    if options.assumeYes {
        answer = .confirmed
    } else {
        log(Renderer.renderSetPrompt(chosen, seconds: options.timeoutSeconds))
        answer = confirmation.awaitConfirmation(timeoutSeconds: options.timeoutSeconds)
    }

    switch answer {
    case .confirmed:
        // Session scope unless the user asked for permanence. Confirming is
        // about keeping the mode now, not about surviving a reboot.
        try coordinator.confirm(change, scope: options.permanent ? .permanent : .session)
        return SetOutcome(result: .applied, message: Renderer.renderApplied(chosen, permanent: options.permanent))

    case .declined:
        try coordinator.revert(change)
        return SetOutcome(result: .reverted(reason: .declined), message: Renderer.renderReverted(current))

    case .timedOut:
        try coordinator.revert(change)
        return SetOutcome(result: .reverted(reason: .timedOut), message: Renderer.renderReverted(current))
    }
}

func runRestore(configurator: DisplayConfiguring) throws -> String {
    try configurator.restoreDefaults()
    return "Asked the system to restore every display to its default mode."
}
```

- [ ] **Step 6: Write the `set` renderers**

Append to the `Renderer` enum in `Sources/displayctl/Rendering.swift`:

```swift
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
```

- [ ] **Step 7: Wire up the entry point**

In `Sources/displayctl/main.swift`, replace the three stub cases:

```swift
    case .set(let options):
        let configurator = CoreGraphicsConfigurator()
        let coordinator = RevertCoordinator(
            configurator: configurator,
            clock: SystemClock(),
            window: TimeInterval(options.timeoutSeconds))

        let outcome = try runSet(
            options,
            enumerator: enumerator,
            coordinator: coordinator,
            confirmation: StandardInputConfirmation())

        print(outcome.message)
        if case .reverted = outcome.result { exit(2) }

    case .restore:
        print(try runRestore(configurator: CoreGraphicsConfigurator()))

    case .doctor:
        print(try Doctor.report(enumerator: enumerator))
```

Exit code 2 for a revert is deliberate: a script that sets a mode needs to be able to tell "applied" from "tried and put back", and both print to stdout.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd ~/Projects/Crisp && swift test --build-system native
```

Expected: PASS, 80 tests.

- [ ] **Step 9: MANUAL HARDWARE VERIFICATION — this changes your screen**

Everything above is fake-driven. This step is the only one that touches real hardware, and it is the one that proves the milestone. **Read all of it before running any of it.**

If a step leaves a screen unreadable, the recovery is: wait 15 seconds and it reverts by itself. If it does not, type blind:

```bash
~/Projects/Crisp/.build/arm64-apple-macosx/debug/displayctl restore
```

Build the binary once so recovery does not depend on a compile:

```bash
cd ~/Projects/Crisp && swift build --build-system native
```

Then work through these and record what happened:

1. **Diagnostics.** `swift run --build-system native displayctl doctor` — the key prints `"kCGDisplayResolution"`, every display shows a non-zero HiDPI count, and the display count matches what is physically plugged in.
2. **Revert on silence.** `swift run --build-system native displayctl set 1280x800` and then *do not type anything*. The screen changes, waits ~15s, and returns on its own. This is the single most important behaviour in the milestone.
3. **Revert on decline.** Same command; answer `n`. It returns immediately.
4. **Apply on confirm.** Same command; answer `y`. It stays. Then `displayctl set` back to your normal resolution.
5. **Second display.** Repeat 2 and 4 with `--display 2`. Confirm the *other* display did not change — spec §11.5 makes this a release blocker, and a plan that only ever tested display 1 would not have caught an off-by-one in `resolveDisplay`.
6. **Permanence is opt-in.** `displayctl set <something> --yes`, log out and back in, confirm it is *not* still applied. Then the same with `--permanent`, confirm it *is*. (This is the slowest check here and the one most worth doing once.)
7. **Recovery.** With a non-default mode applied, run `displayctl restore` and confirm every display returns to its default.

Record the results in the commit message. If any of 2, 3, 5, or 7 fails, stop — the safety contract is broken and no later milestone should be built on it.

- [ ] **Step 10: Commit**

```bash
cd ~/Projects/Crisp
git add Sources/displayctl Tests/displayctlTests
git commit -m "feat: add displayctl set, restore and doctor

Manual hardware verification:
- doctor: <result>
- revert on silence: <result>
- revert on decline: <result>
- apply on confirm: <result>
- second display: <result>
- permanence opt-in: <result>
- restore: <result>"
```

---

## Why this plan stops here

At the end of Task 7 there is a working, tested command-line resolution switcher with a safety contract that has been verified on real hardware. Spec §16 milestones 1 and 2 are complete.

The remaining milestones get their own plans, in this order:

| Milestone | Why it is not here |
|---|---|
| 3 — `MenuBarExtra` app shell | Needs an app bundle, an `Info.plist`, and `LSUIElement`. The `DisplayCore` seams it consumes have to exist and be proven first, which is what this plan delivers. |
| 4 — Global hotkey toggle | Depends on the app shell for an event tap owner. |
| 5 — Presets and display identity | Needs `ColorSync`/IOKit identity work and a preferences store. `DisplayCore` deliberately has no `UserDefaults` dependency; introducing persistence is a design step, not an increment. |
| 6 — Hot-plug and auto-restore | Depends on 5 for identity and on a reconfiguration-callback owner that only the app has. On by default, second-display verification is a release blocker (spec §11.5). |
| 7 — CGS bridge | Optional by construction (spec §4). It is the only cuttable milestone, and it should be evaluated against real gaps found in milestone 1's output rather than built speculatively. |
| 8 — Signing, notarization, Sparkle | **Blocked:** `security find-identity -v -p codesigning` currently reports `0 valid identities found`. Distribution needs Apple Developer Program enrolment, which is a purchase decision, not an engineering task. |

**One piece of milestone 2 is deliberately deferred.** Spec §16 lists the panic
hotkey (⌃⌥⌘R) as part of milestone 2, and it is not here. A global hotkey needs
an event-tap owner and an Accessibility permission prompt, both of which arrive
with the app shell in milestone 3; building a headless CLI that installs a
system-wide hotkey would be the wrong shape. What this plan delivers instead is
the same recovery, reachable the other way: `displayctl restore`, typed blind,
documented in the help text and in the manual verification step. The safety
contract of §8.2 — the part that makes a bad mode survivable without any
recovery action at all — is fully implemented and tested here. Milestone 3's
plan must carry the hotkey forward as its first item.

Two other things surfaced while writing this plan that belong in the next planning session rather than in this one:

- `DisplayDevice.localizedName` is positional here (`"Display 1"`). Real EDID names need IOKit, which arrives with identity work in milestone 5.
- The CGS bridge's `ModeSource.privateCGS` case exists in the domain model but nothing produces it yet. That is intentional — the enum shape is settled now so milestone 7 does not have to change types that everything else depends on.
