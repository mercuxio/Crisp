# Crisp — Design Specification

**Date:** 2026-09-05
**Status:** Draft for review
**Target:** macOS 14+, arm64-only, non-sandboxed, Developer ID + notarized

---

## 1. Summary

Crisp is a macOS menu bar utility for switching display resolutions, including the
HiDPI and scaled modes that System Settings hides. It replaces the several-click
trip through System Settings › Displays with a one-click menu and a global hotkey
that toggles between two saved modes.

The design is grounded in measurements taken on the target machine (M2, macOS 27.0
build 26A5425a, LG 5K at 5120×2880). Those measurements changed the architecture
materially — see §4.

---

## 2. Goals and non-goals

### Goals

- List every usable display mode, including HiDPI variants System Settings omits
- Switch modes in one click from the menu bar
- Global hotkey toggling between two saved modes
- Curate the mode list — favourite, hide, reorder
- Drive multiple simultaneous displays independently, and survive hot-plug
- Remember a preferred mode per physical display and reapply it on reconnect
- Expose refresh rate as part of mode selection
- Never leave the user on an unreadable screen

### Non-goals

- Creating modes that the display does not report (no EDID/display-override
  plist authoring — SIP-protected, requires reboot, wrong tool for this job)
- Brightness, colour, or DDC control (MonitorControl and Lunar own that space)
- Window management or display arrangement (displayplacer owns that)
- Mac App Store distribution — incompatible with the private-API enhancement
  path in §7.2 and with the non-sandboxed requirement
- Intel support

---

## 3. Constraints

| Constraint | Value | Rationale |
|---|---|---|
| Minimum macOS | 14.0 (Sonoma) | `SMAppService`, `MenuBarExtra`, `@Observable` all available |
| Architecture | arm64 only | Matches the incumbent; no Intel testing burden |
| Sandbox | None | IOKit service matching and CGS symbols do not survive App Sandbox |
| Signing | Developer ID + notarized | Gatekeeper blocks unsigned apps for recipients |
| Distribution | `.dmg` + Sparkle appcast | No App Store review, no fast hotfix channel |
| Language | Swift 6, strict concurrency | New project; no legacy to carry |

**Bundle identifier: `dev.houlanyit.Crisp`.** Permanent once shipped —
`SMAppService` login-item registration, the preferences path, and the Sparkle update
feed all key off it, so changing it after the first release orphans every existing
user's presets, login item, and update channel.

---

## 4. Findings that shaped this design

All measured on the target machine, 2026-09-05. Reproduction code in
`docs/specs/probes/`.

### 4.1 The public API is sufficient for the headline feature

`CGDisplayCopyAllDisplayModes` returns the full HiDPI ladder **when the options
dictionary is built from the linked symbol**:

```
actual CFString value of kCGDisplayShowDuplicateLowResolutionModes: "kCGDisplayResolution"

nil options            : 42 modes,  0 HiDPI, max pixel width 3840
using the SYMBOL       : 88 modes, 46 HiDPI, max pixel width 6016
using the LITERAL name : 42 modes,  0 HiDPI, max pixel width 3840
current mode: 2560x1440 pt / 5120x2880 px, ioID 48 — present in symbol list: true
```

The constant's *name* and its *value* differ. Reconstructing the key as the literal
string `"kCGDisplayShowDuplicateLowResolutionModes"` silently yields the unfiltered
42-mode list with zero HiDPI entries — no error, no warning. This trap plausibly
explains why much community tooling concluded the public API cannot see HiDPI modes.

**Consequence:** the public API is the primary provider. The core product therefore
has no private-API dependency.

The private CGS table reports 98 entries against the public 88. The two tables are
not a subset relation in either direction: 78 signatures appear in both, and the
CGS-only remainder is dominated by *stretched* modes (flags `0x00200001`, non-square
pixels). Those are the only entries a user could act on that the public list lacks,
which is why §7.1 merges by `ioDisplayModeID` rather than assuming containment.

### 4.2 The CGS index is `ioDisplayModeID`

Cross-referencing the CGS table against public `CGDisplayMode.ioDisplayModeID`
produced exact agreement on every signature present in both tables (78 pairs).
The value passed to `CGSConfigureDisplayMode` is an IOKit mode ID, not an array
position. It is still not stable across EDID or OS changes, but it is more durable
than an ordinal.

### 4.3 The obvious mode signature collides

`{pointWidth, pointHeight, refreshHz, isHiDPI}` is **not unique**: 10 collision
pairs on this single display. `2560×1440 @60` non-HiDPI maps to both index 47
(`flags 0x1`) and index 97 (`flags 0x40000000`), byte-identical in every other
field. Point dimensions alone are insufficient.

### 4.4 The `CGSDisplayModeDescription` layout is 212 bytes on macOS 27

Measured offsets: `0x00` mode number, `0x04` flags, `0x08/0x0c` point width/height,
`0x10` depth, `0x14` bytes-per-row, `0x18` bpp, `0x24` refresh (uint32),
`0x28/0x2c` DPI, `0x30` pixel-encoding string, `0xbc` **struct size = 212**,
`0xc0` flags copy, `0xc4` mode number copy, `0xc8/0xcc` pixel width/height,
`0xd0` scale (float32).

This matches RDM and knoll (0xD4 = 212, 32-bit float scale) and contradicts the
widely-copied NUIKit/CGSInternal header (0xD8 = 216, `CGFloat` scale). The header
most likely to be copied is the wrong one.

`CGSGetDisplayModeDescriptionOfLength` returns 0 (success) for **any** length from
4 to 1024, writing `min(length, 212)` bytes. A wrong length yields a partially
filled struct and a success code — silent corruption, not an error.

### 4.5 Prior art persists modes the wrong way

`displayplacer` persists by mode index and carries a trail of issues about it.
BetterDisplay's CLI persists by attributes (`resolution`, `hiDPI`, `refreshRate`).
Modes genuinely disappear between releases: Sequoia tightened pixel-clock limits,
and M4/M5 DCP firmware caps the sub-pipe at 6720px, deleting 3840×2160 HiDPI on
some 4K displays. Any persisted index silently aliases to a different mode when
the list shrinks.

### 4.6 The wake placeholder display cannot be filtered by configuration flags

Apple DTS confirms that wake produces a transient placeholder display reporting
`kDisplayVendorIDUnknown` with `kCGDisplayAddFlag`, and that it "cannot be
prevented or avoided." Filtering on `kCGDisplayBeginConfigurationFlag` does not
catch it; it must be excluded by vendor ID.

---

## 5. Architecture

Three targets in one Swift package plus an app target. One dependency rule:
**the app depends on the core; the core never knows the app exists.** No
`UserDefaults`, SwiftUI, or AppKit inside `DisplayCore`.

```
DisplayCore (library)                pure logic, headlessly testable
├── ModeProvider.swift               protocol + provider selection
├── PublicModeProvider.swift         CGDisplayCopyAllDisplayModes — PRIMARY
├── CGSModeProvider.swift            dlsym'd private path — ENHANCEMENT ONLY
├── CGSBridge.swift                  the only file touching private symbols
├── DisplayMode.swift                value type: a mode
├── ModeSignature.swift              persistable identity of a mode
├── DisplayDevice.swift              value type: a physical monitor
├── DisplayIdentity.swift            stable keying across replug
├── DisplayApplier.swift             transactions, confirm-or-revert, watchdog
├── DisplayEventSource.swift         protocol — injectable, fakeable
├── SystemEventSource.swift          real CGDisplayRegisterReconfigurationCallback
└── DisplayEnumerator.swift          composes providers into a mode list

displayctl (executable)              CLI harness AND blind-recovery path
                                     list | set | watch | doctor

Crisp (app target, SwiftUI)          MenuBarExtra, Settings, presets,
                                     hotkeys, Sparkle, login item
```

### Why the CLI is not optional

Two reasons, both load-bearing:

1. Mode switching is miserable to test through a GUI — every test physically
   changes the screen.
2. **It is the recovery path.** If a mode leaves the screen unreadable, a
   15-second confirm dialog does not help, because it cannot be read.
   `displayctl set 2560x1440` typed blind from muscle memory does.

`displayctl` ships inside the app bundle, signed with the same Team ID and
hardened runtime, with a Settings action to symlink it into `/usr/local/bin`.

---

## 6. Domain model

```swift
struct DisplayMode: Identifiable, Hashable, Sendable {
    let id: ModeSignature
    let ioDisplayModeID: Int32     // fast-path hint; validated, never trusted alone
    let pointSize: CGSize          // 2560×1440 — what the user reasons about
    let pixelSize: CGSize          // 5120×2880 — what the panel drives
    let refreshMilliHz: Int        // integer millihertz: 59_940, not 59.94
    let scale: Double              // pixelWidth / pointWidth
    let isSafe: Bool               // OS-advertised as supported
    let isStretched: Bool          // non-square pixels; CGS-only modes
    let source: ModeSource         // .public or .privateCGS
}

struct ModeSignature: Codable, Hashable, Sendable {
    let pointW, pointH: Int
    let pixelW, pixelH: Int
    let refreshMilliHz: Int
    let isSafe: Bool
}

struct DisplayDevice: Identifiable, Hashable, Sendable {
    let displayID: CGDirectDisplayID   // VOLATILE — never persist
    let identity: DisplayIdentity      // stable — persist this
    let localizedName: String
    let isBuiltIn: Bool
    let isVirtual: Bool                // Sidecar, AirPlay, DisplayLink
}
```

**Refresh rate is integer millihertz.** ProMotion and VRR panels report 59.94 Hz;
the CGS integer field truncates to 59 while the public API returns 59.94 as a
Double. Float equality across two providers would silently never match. Matching
uses a ±1000 mHz tolerance band, not equality.

**`isHiDPI` is not a stored field.** It is derived (`scale > 1.0`) for display
purposes only. It was insufficient as a signature component (§4.3) because a bool
cannot distinguish 2× from a 1.5×-class scaled mode.

---

## 7. Mode providers

### 7.1 Provider protocol and selection

```swift
protocol ModeProvider: Sendable {
    var source: ModeSource { get }
    var isAvailable: Bool { get }
    func modes(for id: CGDirectDisplayID) throws -> [DisplayMode]
    func currentMode(for id: CGDirectDisplayID) throws -> DisplayMode
}
```

`DisplayEnumerator` always uses `PublicModeProvider`. It additionally merges
`CGSModeProvider` output **only** when the user has enabled "Show stretched modes"
in Settings and the bridge self-check passes. Modes are merged by
`ioDisplayModeID`; CGS-only entries are tagged `isStretched` and shown in a
separate menu section.

Enumeration measured at 0.24 ms per call. **No mode cache** — it is coupling with
no payoff. Rebuild on menu open.

### 7.2 `PublicModeProvider` (primary)

```swift
let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]
```

The options dictionary **must** be constructed from the linked symbol. A unit test
asserts `(kCGDisplayShowDuplicateLowResolutionModes as String) == "kCGDisplayResolution"`
so that a future SDK change to the constant's value fails loudly rather than
silently halving the mode list.

### 7.3 `CGSModeProvider` (enhancement, optional)

Resolves four private symbols via `dlsym`, never link-time:
`CGSGetNumberOfDisplayModes`, `CGSGetDisplayModeDescriptionOfLength`,
`CGSGetCurrentDisplayMode`, `CGSConfigureDisplayMode`.

Resolution order per symbol:
1. `CGS*` in the default namespace
2. `SLS*` in the default namespace — the CG names are re-exports of SkyLight, and
   the alias is the more fragile half
3. explicit `dlopen` of SkyLight, then `SLS*`

**Startup self-check.** The provider marks itself unavailable unless all of:

- all four symbols resolve
- `CGSGetNumberOfDisplayModes` returns a plausible count (1…512)
- the descriptor's self-reported size at offset `0xbc` equals 212
- `pixelWidth % pointWidth == 0` or `scale` is within [0.5, 4.0]
- the current mode round-trips: `CGSGetCurrentDisplayMode` yields an ID present
  in the enumerated table

Buffers are allocated at 512 bytes while declaring 212 — over-allocation is free
insurance against layout drift, and the API writes `min(length, 212)` without
complaint (§4.4).

Failure at any step disables stretched modes and surfaces one line in Settings:
"Stretched modes unavailable on this version of macOS." The app is fully
functional without it.

---

## 8. The apply path and safety

This is the highest-severity area. Applying an unsupported mode can leave a
display with no signal the panel can sync to, and the user cannot read a dialog
on a screen they cannot see.

### 8.1 Transaction structure

```swift
func apply(_ mode: DisplayMode, to displays: [CGDirectDisplayID]) throws {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { throw DisplayError.configurationFailed }
    // all displays configured inside ONE transaction — otherwise the desktop
    // re-lays-out once per display and window positions scramble
    for id in displays { try setMode(config, id, mode) }
    CGCompleteDisplayConfiguration(config, .forSession)   // NOT permanently
}
```

**`kCGConfigureForSession` first, always.** Only after user confirmation is the
mode re-applied with `kCGConfigurePermanently`. This single choice determines
whether a mode survives logout and reboot, and applying `Permanently` up front is
the primary cause of "it reverted" and "I can't undo it" reports in this category.

`CGCompleteDisplayConfiguration` is documented to hang in some configurations.
It runs off the main thread with a **5-second watchdog**; on timeout the app
reports failure and offers the revert path rather than blocking the UI.

### 8.2 Confirm-or-revert

Every mode change follows:

1. Apply with `.forSession`
2. Show a countdown panel on the affected display: "Keep this resolution?
   Reverting in 15s." — large type, high contrast, centred
3. On confirm → re-apply with `.permanently`, persist the signature
4. On timeout or cancel → restore the previous mode with `.forSession`

The countdown panel is skipped only when the target mode is one Crisp itself
applied and confirmed within the current session — hotkey toggling between two
already-confirmed modes should not nag.

### 8.3 Panic recovery

Three independent escapes, in ascending order of desperation:

1. The 15-second auto-revert above
2. A fixed, non-rebindable global hotkey — **⌃⌥⌘R** — that restores **every**
   connected display to its default mode (`CGRestorePermanentDisplayConfiguration`).
   It deliberately does not target one display: a user who cannot see a screen
   cannot tell you which screen it is, and reverting all of them is a recoverable
   over-correction where guessing wrong is not.
3. `displayctl set <W>x<H>` from Terminal or SSH, typed blind

---

## 9. Display identity

`CGDirectDisplayID` is session-scoped and is reassigned on replug and sometimes
across sleep/wake. It is never persisted.

```swift
struct DisplayIdentity: Codable, Hashable, Sendable {
    var uuid: String?          // CGDisplayCreateUUIDFromDisplayID — import ColorSync
    var hardwareKey: String    // "vendor:model:serial", serial may be 0
    var registryLocation: String?  // IOKit location path — the real tiebreaker
}
```

Resolution order: `uuid` → `hardwareKey` → `registryLocation`.

**Product name is deliberately not a tier.** It exists to disambiguate identical
twin monitors, and identical twins have identical product names — it cannot solve
the only case it was introduced for, and a fuzzy hit that changes the wrong screen
is worse than a miss that does nothing.

**Tiers 1 and 2 are not independent.** Both derive from EDID. Vendors ship entire
batches with the same serial, so two identical panels can produce the same
OS-computed UUID *and* the same `vendor:model:serial`. `registryLocation` is the
only genuinely independent discriminator, which is why it is a tier rather than
a nicety.

**Ambiguity rule:** when two live displays tie on identity at every tier, Crisp
**declines to auto-restore** and logs it. It never guesses.

**Self-healing** rewrites the stored `uuid` only when all hold:

- the match came from `hardwareKey`
- the serial component is non-zero
- exactly one live display matches

Never rewrite from `registryLocation` alone. A wrong rewrite permanently binds one
display's presets to another with no undo.

---

## 10. Presets and persistence

```swift
struct PresetStore: Codable {
    var schemaVersion: Int = 1
    var displays: [StoredDisplay]
}

struct StoredDisplay: Codable {
    var identity: DisplayIdentity
    var lastSeenName: String          // for the UI only, never for matching
    var favorites: [ModeSignature]
    var hidden: [ModeSignature]
    var autoRestore: ModeSignature?
    var toggleA, toggleB: ModeSignature?
}
```

Stored at `~/Library/Application Support/Crisp/presets.json`, written atomically
via temp file + `rename`. A file rather than `UserDefaults` because "send me your
presets.json" is a viable support move once the app is shared.

`schemaVersion` ships on day one with a migration switch, even though there is
nothing to migrate yet. The store is what rots across three years and three OS
releases; retrofitting versioning after users have data is materially harder.

### Mode resolution at apply time

1. Exact `ModeSignature` match → apply
2. Same point size, same pixel size, same `isSafe`, refresh within ±1000 mHz → apply
3. Otherwise → **do not apply**. Mark the preset "unavailable on this display"
   in the menu and notify once.

There is no "closest match" fallback. Modes disappear permanently across OS and
firmware revisions (§4.5); silently substituting a different resolution is the
failure this whole scheme exists to prevent.

`ioDisplayModeID` is stored alongside the signature as a **hint**: try it first,
validate that the resolved descriptor matches the signature, and fall back to
search on mismatch. This gives O(1) apply with self-detecting staleness.

---

## 11. Hot-plug and auto-restore

### 11.1 Event pipeline

`SystemEventSource` wraps `CGDisplayRegisterReconfigurationCallback` and exposes
`AsyncStream<DisplayEvent>`. It is injected as a `DisplayEventSource` so tests can
drive a fake — **required**, because `CGDisplayRegisterReconfigurationCallback`
needs a live CFRunLoop that `displayctl` does not have. Without injection the
harness would silently fail to exercise the subsystem that most needs one.

Filtering, in order:

1. Drop events carrying `kCGDisplayBeginConfigurationFlag` — act only on completion
2. Drop displays reporting `kDisplayVendorIDUnknown` with `kCGDisplayAddFlag` —
   the unavoidable wake placeholder (§4.6)
3. Drop events whose generation token matches an in-flight self-initiated change
4. Debounce **1.0 s**; **3.0 s** additionally after `NSWorkspace.didWakeNotification`

### 11.2 Generation counter, not a time window

Loop prevention uses a monotonically incrementing `reconfigureGeneration`, not a
wall-clock suppression window. `DisplayApplier` increments it before each apply and
tags the expected events; the watcher drops only matched events. A time window is a
race in both directions: a slow `CGCompleteDisplayConfiguration` outlasts it, and a
genuine hotplug coinciding with a user-initiated change gets swallowed.

This is MonitorControl's approach, and it uses the same 1.0 s / 3.0 s constants.

### 11.3 Settle-and-retry

Displays report `online` before they will accept a mode set. Auto-restore applies,
reads back the current mode, and retries up to **3 times at 500 ms intervals**
before giving up. Without this, auto-restore silently no-ops on dock connect.

### 11.4 Reapply cap

Hard limit of **3 reapplies per display per 60 seconds**. On exceeding it, Crisp
stops, disables auto-restore for that display, and posts a notification. This
bounds the worst case — a flapping display or an unforeseen loop — to a brief
flicker rather than an unusable machine.

### 11.5 Verification requirement

Multi-display is a first-class requirement, so this section is not optional and
not deferrable. Auto-restore is **on by default**.

The constraint is that the development machine has one display, so the constants in
§11.1–11.4 come from MonitorControl's production values rather than local
measurement. That makes second-display testing a **release blocker**, not a
nice-to-have: milestone 6 cannot be signed off from this machine alone.

`displayctl watch` exists for exactly this — it prints the raw reconfiguration
event stream, with generation tokens and filter decisions, so the pipeline can be
validated against real dock/undock and sleep/wake events on whatever hardware is
available. If borrowed hardware is the only option, `watch` plus `doctor` produce
a transcript that can be captured in one sitting and analysed afterwards.

---

## 12. User interface

### 12.1 Menu bar

`MenuBarExtra` with a template icon. Content rebuilt on open (0.24 ms — cheap):

```
◇ Crisp
  ── LG Ultra HD ───────────────    ← header suppressed when only one display
  ✓ 2560 × 1440   (HiDPI)
    2880 × 1620   (HiDPI)
    3200 × 1800   (HiDPI)
    1920 × 1080   (HiDPI)
    All resolutions            ▸
    Stretched                  ▸    (only if CGS bridge available)
  ── Built-in Display ──────────
  ✓ 1512 × 982    (HiDPI)
    1800 × 1169   (HiDPI)
    All resolutions            ▸
  ──────────────────────────────
    Toggle: 1440p ⇄ 1800p    ⌘⌥T
    Settings…                  ⌘,
    Quit Crisp                 ⌘Q
```

Top level shows favourites only. Point size is the primary label because that is
what users reason about; pixel size appears in the submenu and in tooltips. With
46 HiDPI modes on this display, curation is not a nicety — the uncurated list does
not fit on screen.

**Multi-display layout.** One section per connected display, ordered by the system
arrangement left-to-right with the built-in display last. The section header is
suppressed entirely for a single display, so the common case stays flat. Past three
displays each section collapses into a submenu, since four inline mode lists exceed
the screen the menu has to fit on.

Section headers use the display's localized name, disambiguated with the
arrangement position when two displays share a name (`Studio Display (left)`) —
which is a UI nicety and explicitly **not** how §9 matches displays for presets.

**Which display does the hotkey act on?** The one containing the mouse cursor when
the shortcut fires, falling back to the main display. Not the focused window's
display: Crisp is a menu bar app that usually has no window, and "the screen my
pointer is on" is the only target a user can predict without looking anywhere. Each
display carries its own toggle pair (§10), so the same shortcut does the right
thing on each screen.

Refresh rate is folded into the label (`2560 × 1440 · 120 Hz`) only when a display
offers more than one rate for that size. No separate refresh-rate control.

### 12.2 Settings

Four panes: **General** (launch at login via `SMAppService`, menu bar icon style,
`displayctl` symlink), **Displays** (per-display favourites, hidden modes,
auto-restore toggle, identity diagnostics), **Shortcuts** (toggle pair binding via
the `KeyboardShortcuts` package — the maintained successor to MASShortcut), and
**Advanced** (stretched modes toggle, CGS bridge status, reset presets).

---

## 13. Error handling

| Failure | Behaviour |
|---|---|
| CGS bridge self-check fails | Stretched modes hidden; one line in Settings; app fully functional |
| `CGBeginDisplayConfiguration` fails | Abort, no partial state, alert with the CG error code |
| `CGCompleteDisplayConfiguration` hangs > 5 s | Watchdog fires, report failure, offer panic hotkey |
| Applied mode not confirmed in 15 s | Auto-revert to previous mode |
| Preset signature no longer resolvable | Menu shows it greyed "unavailable"; notify once; never substitute |
| Identity ambiguous across live displays | Decline auto-restore, log, notify once |
| Reapply cap exceeded | Disable auto-restore for that display, notify |
| `presets.json` corrupt | Back up to `presets.json.bad-<timestamp>`, start fresh, notify |

Errors surface as a typed `DisplayError` from `DisplayCore`; the app maps them to
user-facing text. `DisplayCore` never produces user-facing strings.

---

## 14. Testing

**Unit (no hardware).** `ModeSignature` matching including the ±1000 mHz tolerance;
signature collision resolution against a recorded 98-mode fixture from this LG 5K;
identity tier resolution and the self-heal gate; preset migration; the
generation-counter suppression logic driven by a fake `DisplayEventSource`;
descriptor decoding against recorded 212-byte fixtures.

**Integration (`displayctl`, real hardware).** `doctor` runs the CGS self-check and
prints provider availability, mode counts per provider, and identity for every
connected display — the single command to run after any macOS update. `list`
verifies HiDPI modes appear. `set` verifies apply and revert.

**Manual, multi-display (release blocker).** Dock/undock, sleep/wake, display
ordering changes, and the auto-restore matrix — each with two displays connected,
and at least once with two *identical* displays if obtainable, since that is the
only way to exercise the §9 ambiguity rule. Capture `displayctl watch` output for
each scenario and diff it against the expected event sequence.

**Regression fixture.** The recorded mode table and struct dumps from 2026-09-05
live in `Tests/Fixtures/` so a future macOS can be diffed against a known-good
baseline.

---

## 15. Distribution

- Developer ID Application signing, hardened runtime
- `com.apple.security.cs.disable-library-validation` — required for Sparkle
- Notarize with `notarytool`, staple the ticket, ship a `.dmg`
- Sparkle 2.x with **EdDSA** signing; the private key never enters the repository
- `displayctl` inside the bundle, same Team ID and hardened runtime

**Gatekeeper caveat:** `spctl` on the development machine reports
`override=security disabled`. That machine cannot validate that recipients will be
able to open the build. Test the notarized `.dmg` on a machine with Gatekeeper
enabled before sharing.

---

## 16. Build order

Sequenced so the riskiest assumption is retired first and each milestone is
independently useful.

| # | Milestone | Proves |
|---|---|---|
| 1 | `displayctl list` / `set` on the **public** provider only | Enumeration and apply work; HiDPI modes visible. Retires the core risk in ~1 day. |
| 2 | Apply path: transaction, `.forSession` → confirm → `.permanently`, watchdog, panic hotkey | Safety before features. Nothing else is safe to build until this exists. |
| 3 | `MenuBarExtra` app: flat mode list, click to apply, checkmark on current | The product, minimally |
| 4 | Global hotkey toggle between two modes | The daily-use feature |
| 5 | Signature persistence + two-tier identity + favourites/hiding | Curation and memory |
| 6 | Hot-plug pipeline + auto-restore, on by default | Multi-display, a stated requirement. Needs a second display to sign off. |
| 7 | CGS bridge behind the self-check; stretched modes section | The optional enhancement — the one milestone that could be cut |
| 8 | Sign, notarize, `.dmg`, Sparkle appcast | Shipping |

Milestone 1 deliberately excludes the private API. Under the original design it was
the day-one risk; §4.1 demoted it to an optional extra, and building the public path
first means the app shell is proven before any undocumented struct is parsed.

Milestone 6 sits ahead of 7 because multi-display support is required and stretched
modes are not. If the schedule compresses, 7 is the milestone that gets cut.

Multi-display work is not confined to milestone 6. Milestone 1 enumerates every
display, milestone 2's transaction spans all of them atomically (§8.1), milestone 3
sections the menu per display, and milestone 5 keys presets by physical identity
(§9). Milestone 6 adds only the reaction to displays appearing and disappearing.

---

## 17. Risks and open questions

| Risk | Severity | Mitigation |
|---|---|---|
| Hot-plug constants unverifiable on one-display hardware | High | Release blocker, not a shipped unknown (§11.5); `displayctl watch` transcripts; §11.4 cap bounds the worst case |
| Identity ambiguity untested without two identical panels | Medium | Decline-to-guess rule fails safe; unit tests drive it via a fake event source |
| CGS struct layout drifts in macOS 28 | Low (now) | Self-check disables the path; core product unaffected |
| Public constant's value changes in a future SDK | Low | Unit test asserts `"kCGDisplayResolution"` |
| Identical twin monitors alias | Medium | `registryLocation` tier; decline-to-guess rule |
| Sparkle key handling | Medium | EdDSA; key outside the repo; document the release process |
| `CGCompleteDisplayConfiguration` hang | Low | 5 s watchdog, off-main-thread |

**Open questions for the author:**

1. Is Sparkle worth it at this audience size, or is texting a `.dmg` link enough
   for the first few releases? Milestone 8 assumes yes; it is easy to drop.
2. What second-display hardware will be available for milestone 6 sign-off, and
   when? This does not block starting — milestones 1–5 need no second display —
   but it does block release.

---

## Appendix A — Provenance

The findings in §4 were produced by a four-member Claude council (Architect,
Skeptic, Pragmatist, Researcher — independent contexts, distinct personas) on
2026-09-05, with the pivotal public-API measurement independently re-verified by
the chairman session after two members returned contradictory results. The
Skeptic's contradictory figures (42 modes / 0 HiDPI) were traced to constructing
the options dictionary from the constant's *name* rather than its *value*, which
is what §4.1 documents.

Design decisions the council changed from the pre-review draft:

- Public provider promoted from fallback to primary; CGS demoted to optional
- `ModeSignature` widened with pixel dimensions and a safety flag
- Refresh rate changed from `Double` Hz to `Int` millihertz
- Time-based suppression window replaced with a generation counter
- Debounce raised from 500 ms to 1.0 s, plus 3.0 s post-wake
- Product-name identity tier removed; `registryLocation` added
- Self-heal gated behind unique, non-zero-serial matches
- §8 (apply path, confirm-or-revert, panic recovery) added — absent entirely from
  the pre-review draft, and flagged by all four members
- Schema versioning added to the preset store
