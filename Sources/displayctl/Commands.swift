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
