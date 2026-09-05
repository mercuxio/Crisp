# Carried forward into milestone 3

Milestones 1-2 (`DisplayCore` + `displayctl`) are complete: 112 tests, seven scoped reviews and
one whole-branch review. These are the things those reviews found and deliberately did not fix
here. Read this before starting the menu bar app.

## 1. `RevertCoordinator` is correct but defenceless — fix this first

It is deliberately not `Sendable` and documents a single-execution-context obligation, while
`PendingChange` — the token every entry point takes — is `public` and `Sendable` and travels
freely across threads. `displayctl` honours the contract only because `runSet` is single-threaded
start to finish.

Milestone 3 breaks that by construction. A countdown panel ticking `expireIfNeeded` on a timer, a
Keep/Revert button on the main actor, and a display-reconfiguration notification arriving on a
CoreGraphics callback thread are three drivers of one unsynchronised `Set<Int>`. The failure mode
is a revert that silently does not fire because a concurrent write lost the insert — which is the
exact failure the product exists to prevent.

**Make it an actor or a `@MainActor` type before the first timer is attached, not after.**

## 2. A killed process leaves the screen changed

If `displayctl` is killed mid-window — Ctrl-C, terminal closed, crash — nothing reverts, and the
session-scoped mode persists until logout. Neither the plan nor any review caught this until late.
The menu bar app needs the panic hotkey (spec §8.3) and should consider a crash-safe path, since
an app that dies mid-countdown has the same hole.

## 3. `expireIfNeeded` and `secondsRemaining` have never run

Both are well tested and have **no caller** on this branch — `runSet` drives the revert entirely
off `awaitConfirmation` returning, which is legitimate because the semaphore wait is bounded. So
the poll API ships unexercised end to end. Do not assume it is field-proven.

## 4. `restore` cannot undo `--permanent`

`CGRestorePermanentDisplayConfiguration` restores the *permanent* configuration, and a confirmed
`--permanent` change is that configuration. The help text is honest about this now, but the
milestone-3 panic hotkey inherits the same limitation from spec §8.3. Decide what the hotkey does
about a permanent change before shipping it.

## 5. There is no main-display concept

`displayctl set` with no `--display` targets `ids.first` from `CGGetOnlineDisplayList`, and
`CGMainDisplayID` appears nowhere in the tree. The online list also includes inactive and mirrored
targets. The help now says "display 1, as shown by `list`" rather than "the main display", which is
true but is not what a menu bar app wants. Widening `DisplayEnumerating` with a main-display query
is milestone-3-shaped work.

## 6. Small open residuals

- `revertOrThrowRevertFailure` catches only `DisplayError`. Every current throw site is one, so a
  non-`DisplayError` falling through to the generic handler is unreachable today — but `apply` is
  untyped `throws`, so it will not stay unreachable forever.
- User-facing strings have drifted outside `Rendering.swift` on the CLI side: `helpText` and two
  display errors live in `Commands.swift`, the whole report in `Doctor.swift`, every `ParseError`
  in `ArgumentParsing.swift`. `DisplayCore` is clean, so the binding constraint holds, but the
  CLI-side convention no longer does.
- `resolveDisplay` throws `ParseError` for runtime conditions ("no displays are connected"), which
  is not a parse failure. Cosmetic — both types exit 1 through the same path.
- `Confirmation` collides by name with swift-testing's own `Confirmation` in test files. Ruled not
  worth renaming public API; there is a warning comment at the top of `SetCommandTests.swift`.

## 7. Manual hardware verification is owed

Nothing on this branch has been run against a real display. Every review and every implementer was
explicitly forbidden from applying a mode, because the machine's owner was not at the keyboard. The
commands to run, by hand, with someone watching the screen, are in the repository README section of
this file's sibling — see `CLAUDE.md`, and run them one at a time.
