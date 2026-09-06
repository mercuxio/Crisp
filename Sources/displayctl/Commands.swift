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
  --display N    which display to change (default: display 1, as shown by 'list')
  --hz N         require this refresh rate, e.g. --hz 59.94
  --hidpi        require a HiDPI mode
  --no-hidpi     require a native (non-HiDPI) mode
  --unsafe       allow modes the OS does not advertise as usable
  --stretched    allow modes with non-square pixels
  --permanent    keep the mode across logout and reboot ('restore' cannot undo this)
  --yes, -y      skip the confirmation countdown
  --timeout N    seconds to wait for confirmation (default 15)

RESTORE
  Returns every display to the system's saved configuration. This is the
  recovery path for a session-scoped change: if a mode leaves a screen
  unreadable, run 'displayctl restore'. A confirmed --permanent change
  writes that saved configuration, so 'restore' will not undo it.
"""

/// D5: the one wording for "there is no display at this index" — shared by
/// `list --display N` (`collectDisplays`) and `set --display N`
/// (`resolveDisplay`) so the two paths can never say it two different ways
/// again.
func noSuchDisplayIndexMessage(_ index: Int, connectedCount: Int) -> String {
    "no display \(index) — this Mac has \(connectedCount); run 'displayctl list'"
}

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
        throw ParseError(noSuchDisplayIndexMessage(wanted, connectedCount: ids.count))
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
        throw ParseError(noSuchDisplayIndexMessage(index, connectedCount: ids.count))
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
        do {
            try coordinator.confirm(change, scope: options.permanent ? .permanent : .session)
        } catch {
            // The user asked to keep this mode and the system refused (most
            // often: the confirmation arrived after the deadline, so nothing
            // was ever applied on their behalf). The safe resting state is
            // the mode they came from, not the one they just failed to keep.
            // If putting it back also fails, the screen is stuck on a mode
            // the user could not keep, and that — not the confirm error — is
            // what they need told, with the recovery command. If it succeeds,
            // the original error is what explains why they are back where
            // they started.
            do {
                try revertOrThrowRevertFailure(change, coordinator: coordinator)
            } catch let revertFailure as RevertAfterConfirmationFailed {
                throw revertFailure
            }
            throw error
        }
        return SetOutcome(result: .applied, message: Renderer.renderApplied(chosen, permanent: options.permanent))

    case .declined:
        try revertOrThrowRevertFailure(change, coordinator: coordinator)
        return SetOutcome(result: .reverted(reason: .declined), message: Renderer.renderReverted(current))

    case .timedOut:
        try revertOrThrowRevertFailure(change, coordinator: coordinator)
        return SetOutcome(result: .reverted(reason: .timedOut), message: Renderer.renderReverted(current))
    }
}

/// Reverts, and if CoreGraphics refuses, tries exactly once more before
/// giving up (F1b). A screen the user cannot read is not a place to loop —
/// one retry absorbs a transient rejection; a second failure means
/// CoreGraphics is refusing outright, and the caller needs the error, not a
/// spin. `RevertCoordinator.revert` only marks a change resolved after a
/// successful apply (commit 9680b83), so this retry lands on the same
/// pending change rather than double-applying.
private func revertRetryingOnce(
    _ change: PendingChange, coordinator: RevertCoordinator
) throws {
    do {
        try coordinator.revert(change)
    } catch {
        try coordinator.revert(change)
    }
}

/// The revert that follows a failed, declined, or timed-out confirmation
/// definitely failed (F1b's retry exhausted). Distinct from a
/// plain `DisplayError` so `main.swift` can render a message that says
/// plainly the revert failed and the display is still on the new mode —
/// `Renderer.describe(.configurationFailed)` names a numeric CoreGraphics
/// code and nothing else, which is not enough here, where the caller (unlike
/// the renderer) knows for certain which direction failed.
struct RevertAfterConfirmationFailed: Error {
    let underlying: DisplayError
}

private func revertOrThrowRevertFailure(
    _ change: PendingChange, coordinator: RevertCoordinator
) throws {
    do {
        try revertRetryingOnce(change, coordinator: coordinator)
    } catch let error as DisplayError {
        throw RevertAfterConfirmationFailed(underlying: error)
    }
}

func runRestore(configurator: DisplayConfiguring) throws -> String {
    try configurator.restoreDefaults()
    return "Asked the system to restore every display to its saved configuration."
}
