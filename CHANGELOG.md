# Changelog

All notable changes to Crisp are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- The confirm-or-revert countdown now runs in the `.common` run loop mode.
  Installed in the default mode, it stopped firing while a menu was open or
  while the confirmation panel was being dragged — freezing both the visible
  countdown and the automatic revert behind it.
- Clicking **Keep** on a change the system then refuses now reverts, instead of
  leaving the display on an unconfirmed mode with nothing left to take it back.
  This matches what `displayctl set` has always done in the same situation.
- The settings menu turns `autoenablesItems` off, so items it disables stay
  disabled. Under AppKit's default, **Start at Login** rendered as a live,
  clickable toggle in the one state — waiting for the user's approval of the
  login item — where clicking it cannot work.
- The countdown timer no longer captures `self` strongly.
- Seventeen test assertions written as `#expect(x == true / == false)` never
  checked anything, because of a macro defect in `swift-testing` 0.99.0 under
  the current compiler. All of them have been rewritten, and the defect is
  pinned by a test. See [CONTRIBUTING.md](CONTRIBUTING.md).

### Added

- `README.md`, `CONTRIBUTING.md`, this changelog, and an MIT `LICENSE`.

## [0.1.0]

First working version.

- Menu bar panel listing every usable mode per display, HiDPI and Normal in
  separate columns, with a checkmark on the current mode and a dot on the last
  three picked.
- A display picker across the top of the panel, named and numbered, shown even
  with a single display attached.
- Fifteen-second confirm-or-revert on every change, with Revert as the default
  button and Keep on ⌘K.
- Settings dropdown: Display Arrangement (two or more displays), Start at Login
  via `SMAppService`, and Restore Defaults.
- `displayctl` — `list`, `set`, `restore`, `doctor` — sharing the same engine
  and serving as the blind-recovery path.
