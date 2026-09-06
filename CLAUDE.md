# Pitch

A macOS menu bar display-resolution switcher (a QuickRes replacement). Bundle id
`com.houlanyit.Pitch`. Target macOS 14+, arm64 only. Multi-display is a hard requirement,
not a later addition.

Spec: `docs/specs/2026-09-05-pitch-design.md` — it is the binding authority.

## Building and testing

This machine has **Command Line Tools only, no Xcode**. Every swift invocation needs the flag:

```bash
swift test --build-system native
```

`swift build --build-system native` likewise. Without it the build fails on this machine.

swift-testing comes in as an SPM dependency deliberately. SwiftPM emits a deprecation warning
advising its removal; **that warning is wrong here** — removing the dependency breaks the suite.
It is the only dependency, and the only one that should ever be added: `displayctl` is the
blind-recovery path, so its argument parser stays hand-rolled rather than taking
`swift-argument-parser`.

`@testable import` of an `executableTarget` links and runs, which is how `displayctl` is tested.

**Never write `== true` or `== false` inside `#expect`.** swift-testing 0.99.0 is built against
swift-syntax 600, and under the current compiler its macro mis-resolves any comparison whose left
operand is already a `Bool` or `Bool?` — it checks that operand alone and discards the comparison.
`#expect(x == false)` therefore compiles, reads correctly, and passes for every value of `x`.
Seventeen assertions in this suite were written that way and none had ever tested anything. Write
the plain condition, or hoist the value into a `let` first (`??` inside `#expect` is mis-instrumented
too). Only `Bool`/`Bool?` operands are affected. `boolComparisonsAreInvisibleToTheExpectMacro` pins
it; CONTRIBUTING.md has the detail.

## Never apply a display mode unattended

`displayctl set` and `displayctl restore` change what is on the screen. If the person who owns
this machine is not at the keyboard, a mode their monitor cannot show leaves them unable to see
the prompt that would undo it. `swift build`, `swift test`, `displayctl list`, `displayctl
doctor`, `displayctl --help`, and invocations that fail during argument parsing are safe.

Manual hardware verification is owed by a human at the keyboard; it has never been run. See
`docs/milestone-3-carry-forward.md`.

## Two facts the code depends on

**`kCGDisplayShowDuplicateLowResolutionModes` has the underlying CFString value
`"kCGDisplayResolution"`.** Build the CG options dictionary from the linked symbol, never from
the constant's *name* as a string literal — the literal silently returns ~42 modes with 0 HiDPI
instead of ~88 with ~46. No error, no warning. There is a guard comment at the call site and a
test pinning the value; both are load-bearing.

**`ioDisplayModeID` is an O(1) hint, never an identity.** It is not stable across reboots or
hardware changes. Validate it against the stored six-field `ModeSignature` before acting on it.

Refresh rate is integer millihertz throughout. `0` means "unspecified" — built-in Apple panels
genuinely report 0.0 Hz — and must never tolerance-match a non-zero value, nor render as "0 Hz".

## Layering

`DisplayCore` is a pure library: no SwiftUI, no AppKit, no `UserDefaults`, and **no user-facing
strings**. All text the user reads lives in `Sources/displayctl/Rendering.swift`.

Nothing in `DisplayCore` fires a revert on its own — no timer, no queue, no `deinit` hook. The
entire confirm-or-revert safety property lives in the caller's poll or wait. Time enters through
an injected `MonotonicClock`, never `Date()`, so the 15-second window is testable in microseconds.
