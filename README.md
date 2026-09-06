# Pitch

A macOS menu bar app for switching display resolutions — including the HiDPI
modes System Settings will not show you.

Every panel reports far more modes than macOS offers in the Displays pane. On a
4K monitor that typically means around 88 modes, of which roughly half are
HiDPI, against the handful System Settings lists. Pitch puts all of the usable
ones one click away, on every attached display, and gives you fifteen seconds
to change your mind.

Requires **macOS 14 or later** on **Apple silicon**.

---

## Install

**Download the release.** Grab `Pitch-1.0.0.zip` from
[Releases](https://github.com/mercuxio/Pitch/releases), unzip it, and drag
`Pitch.app` to `/Applications`.

The app is ad-hoc signed, not notarized — I don't pay for an Apple Developer
account. macOS quarantines anything downloaded from the internet that isn't
notarized, so the first launch will be refused with "Pitch is damaged and can't
be opened" or "cannot be verified". Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Pitch.app
```

Then open it normally. If you'd rather not run that on a stranger's binary —
reasonable — build it yourself; see [Building](#building).

---

## What it does

Click the monitor glyph in the menu bar and a panel drops down:

- **A display picker across the top.** One numbered monitor glyph per attached
  display, the selected one filled in, each with the display's real name on
  hover. It appears even with a single display, so the panel does not change
  shape when you plug something in.
- **Two columns of resolutions** — HiDPI on the left, Normal on the right —
  because `2560 × 1440` and `2560 × 1440 HiDPI` are different modes and telling
  them apart by a suffix is how people pick the wrong one. When a display
  offers only one kind, the headings disappear.
- **A checkmark on the current mode, and a dot on the last three you picked.**
  The current mode is excluded from the recency list, so it never spends one of
  the three dots on itself.
- **A footer**: settings, a link to buy the author a coffee, and quit.

Modes that are stretched (non-square pixels) or that the OS does not advertise
as safe are hidden. The one exception is the mode you are already on: it always
gets a row, so the panel can never open without a checkmark in it.

### Settings

The gear opens a second dropdown — a menu, not a dialog, and the resolution
panel stays put underneath it:

- **Display Arrangement…** opens the System Settings pane where displays are
  positioned. Shown only when more than one display is attached, since with one
  display that pane has nothing to arrange.
- **Start at Login**, via `SMAppService`. When macOS is waiting for you to
  approve the login item, the toggle disables itself rather than pretending a
  click would work.
- **Restore Defaults**, which returns every display to the system's saved
  configuration.

## Confirm or revert

Applying a resolution your monitor cannot actually display is how you end up
unable to read the menu that would undo it. So every change is provisional:

1. Pitch applies the mode for the current session only.
2. A floating panel appears with a fifteen-second countdown.
3. **Revert is the default button.** Keep is ⌘K. If you cannot see the panel and
   press Return blindly, you get the safe outcome.
4. If the countdown reaches zero, the previous mode comes back on its own.
5. Only when you click Keep is the change written permanently.

The countdown timer runs in the `.common` run loop mode, so it keeps ticking
while a menu is open or while you are dragging the panel around. If confirming
fails — most often because the click landed a hair past the deadline — Pitch
reverts rather than leaving you on a mode nothing will ever take back.

## `displayctl`

The same engine, as a command line tool. It exists mainly as the recovery path:
if a mode leaves a screen unreadable and you can still reach a terminal, or ssh
in from another machine, `displayctl restore` puts everything back.

```
displayctl list [--display N] [--all] [--json]
displayctl set WIDTHxHEIGHT [options]
displayctl restore
displayctl doctor
```

```bash
displayctl list --display 2
displayctl set 2560x1440 --hidpi --hz 59.94
displayctl set 3840x2160 --permanent
displayctl restore
```

`set` runs the same confirm-or-revert cycle, prompting on standard input;
`--yes` skips the countdown and `--timeout N` changes its length. `doctor`
prints what the enumerator sees, including the HiDPI mode count — useful for
telling "this display has no HiDPI modes" apart from "Pitch is not asking for
them".

Run `displayctl --help` for the full option list.

> `set` and `restore` change what is on screen. Do not run them on a machine
> nobody is sitting at.

## Building

```bash
swift build --build-system native -c release
./scripts/package-app.sh
```

`package-app.sh` assembles `build/Pitch.app` — SwiftPM produces a bare
executable and has no concept of an app bundle, so the layout, `Info.plist`,
icon and signature are put together by the script. The signature is ad-hoc,
which is enough to run the app yourself and not enough to distribute it;
shipping would need a Developer ID identity and notarization.

Drag `build/Pitch.app` to `/Applications` and launch it. There is no dock icon
— it is an `LSUIElement` agent, so the menu bar glyph is the whole interface.

## Layout

| Path | What lives there |
| --- | --- |
| `Sources/DisplayCore` | Enumerating modes, matching them, applying them, and the revert coordinator. Pure library: no AppKit, no `UserDefaults`, and no user-facing strings. |
| `Sources/displayctl` | The CLI: hand-rolled argument parsing, rendering, and the terminal confirmation prompt. |
| `Sources/Pitch` | The menu bar app. Everything is `@MainActor`. |
| `Tools/GenerateIcon.swift` | Draws the app icon from the same `display` SF Symbol the menu bar uses, so the two cannot drift apart. |
| `docs/specs/` | The design spec, which is the binding authority for behaviour. |

Nothing in `DisplayCore` reverts on its own — no timer, no queue, no `deinit`
hook. The safety property lives entirely in the caller's poll or wait, and time
enters through an injected clock, so the fifteen-second window is testable in
microseconds rather than in fifteen seconds.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) — in particular the `--build-system
native` flag, which every `swift` invocation on a Command Line Tools-only
machine needs, and one sharp edge in the test framework that silently disables
assertions.

```bash
swift test --build-system native
```

## Status

Version 1.0.0. The suite is green and the app has been used against real
hardware, but the full multi-display verification matrix in
`docs/milestone-3-carry-forward.md` has not been worked through end to end.

Releases carry an ad-hoc signed `Pitch.app` in a zip; see
[Install](#install) for the one command that gets it past Gatekeeper.

## License

[MIT](LICENSE).
