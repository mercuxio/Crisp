import CoreGraphics
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
