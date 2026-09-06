# Contributing to Crisp

## Building and testing

**Every `swift` invocation needs `--build-system native`:**

```bash
swift build --build-system native
swift test  --build-system native
```

This machine class has Command Line Tools without Xcode, and the default build
system fails there. SwiftPM prints a deprecation warning advising you to drop
the flag; on a CLT-only machine that advice is wrong.

The same constraint explains the one dependency. `swift-testing` is taken as an
SPM package rather than from the toolchain because, without Xcode selected,
SwiftPM cannot resolve the bundled `Testing` module at all — `import Testing`
simply fails. That dependency is the only one the project should ever grow:
`displayctl` is the blind-recovery path, so its argument parser stays
hand-rolled rather than pulling in `swift-argument-parser`.

`@testable import` of an `executableTarget` links and runs, which is how both
`displayctl` and the app target are tested.

## Never apply a display mode unattended

`displayctl set` and `displayctl restore` change what is on the screen. If
nobody is at the keyboard, a mode the monitor cannot show leaves them unable to
see the prompt that would undo it.

Safe at any time: `swift build`, `swift test`, `displayctl list`, `displayctl
doctor`, `displayctl --help`, and any invocation that fails during argument
parsing.

## Never write `== true` or `== false` inside `#expect`

The standalone `swift-testing` 0.99.0 release is built against swift-syntax
600, and under the current compiler its `#expect` macro mis-resolves any
comparison whose left operand is already a `Bool` or `Bool?`: it checks that
operand on its own and throws the comparison away.

The failure is silent. `#expect(x == false)` compiles, reads correctly, and
passes for every value of `x`. Seventeen assertions across this suite were
written that way and not one of them had ever tested anything.

```swift
#expect(flag == false)                  // never fails, whatever flag holds
#expect(row?.isRecent == true)          // likewise
#expect(!flag)                          // checks
```

For an optional, or for anything with a `try` in it, hoist the value into a
local first and assert the plain identifier:

```swift
let isRecent = rows.first { $0.isCurrent }?.isRecent ?? true
#expect(!isRecent)
```

`??` inside `#expect` is mis-instrumented by the same macro, so do the
coalescing in the `let`, not in the expectation.

Only `Bool` and `Bool?` operands are affected — `Int?`, `String?`, enums and
`nil` comparisons all evaluate correctly.
`boolComparisonsAreInvisibleToTheExpectMacro` in `Tests/DisplayCoreTests`
pins the behaviour; if it ever starts failing, the macro has been fixed and the
workarounds above can be unwound.

## Two facts the code depends on

**`kCGDisplayShowDuplicateLowResolutionModes` has the underlying CFString value
`"kCGDisplayResolution"`.** Build the CoreGraphics options dictionary from the
linked symbol, never from the constant's *name* as a string literal — the
literal silently returns about 42 modes with zero HiDPI instead of about 88
with 46. No error, no warning. There is a guard comment at each call site, a
test pinning the value, and a line in `displayctl doctor`; all three are
load-bearing.

**`ioDisplayModeID` is an O(1) apply hint, never an identity.** It is not
stable across reboots or hardware changes. Validate it against the stored
six-field `ModeSignature` before acting on it.

Refresh rate is integer millihertz throughout. `0` means "unspecified" —
built-in Apple panels genuinely report it — and must never tolerance-match a
non-zero value, nor be rendered as "0 Hz".

## Layering

`DisplayCore` is a pure library: no SwiftUI, no AppKit, no `UserDefaults`, and
no user-facing strings. Text the user reads lives in
`Sources/displayctl/Rendering.swift` and `Sources/Crisp/ErrorText.swift`.

Nothing in `DisplayCore` fires a revert on its own — no timer, no queue, no
`deinit` hook. The entire confirm-or-revert safety property lives in the
caller's poll or wait. Time enters through an injected `MonotonicClock`, never
`Date()`, so the fifteen-second window is testable in microseconds.

In the app, that poll is `StatusMenuController.tick()`, driven by a timer
installed in the `.common` run loop mode. A `.default`-mode timer — which is
what `Timer.scheduledTimer` gives you — stops firing while a menu is tracking
or a window is being dragged, which would freeze the countdown *and* the revert
it is counting down to. If you touch that timer, keep the mode.

## Style

The codebase carries a lot of comments, and they are load-bearing: they say why
a line is the way it is, usually because the obvious alternative is wrong in a
way that costs an afternoon to rediscover. Match that. A comment restating what
the code says is noise; a comment naming the trap is the point.

`docs/specs/2026-09-05-crisp-design.md` is the binding authority for behaviour.
When code and spec disagree, the spec wins unless you change it deliberately.

## Pull requests

- One branch, `main`. Keep it green: `swift test --build-system native`.
- Say what you verified on real hardware, if anything. Multi-display behaviour
  cannot be proved by the suite alone.
- New behaviour needs a test, and after writing it, break the code on purpose
  and watch the test fail. Given the `#expect` trap above, a test that has
  never failed has not been shown to test anything.
