import DisplayCore

/// User-facing wording for `DisplayError`, in the app's voice.
///
/// DisplayCore deliberately carries no strings (spec §13). `displayctl` has its
/// own renderer for a terminal; this one is for alert panels, so it names what
/// the user can do rather than what CoreGraphics returned.
enum ErrorText {
    static func describe(_ error: Error) -> String {
        guard let error = error as? DisplayError else {
            return String(describing: error)
        }
        switch error {
        case .noSuchDisplay:
            return "That display is no longer connected."
        case .modeEnumerationFailed:
            return "The display's resolution list could not be read."
        case .currentModeUnavailable:
            return "The display's current resolution could not be read."
        case .configurationFailed(let code):
            return "The system refused the change (CoreGraphics error \(code))."
        case .completionTimedOut(let seconds):
            return "The change did not complete within \(Int(seconds)) seconds."
        case .modeUnavailable:
            return "That resolution is no longer available on this display."
        case .noMatchingMode(let width, let height):
            return "No mode on this display matches \(width) × \(height)."
        case .confirmationExpired:
            return "The confirmation window closed before the change was kept."
        }
    }

    /// The message shown when a revert fails — the one case where the user is
    /// left on a mode they may not be able to read, so it must end in an
    /// instruction, not a diagnosis.
    static func revertFailure(_ error: Error) -> String {
        describe(error)
            + "\n\nThe display is still on the new mode. Use Crisp's Restore Defaults "
            + "item, or run 'displayctl restore' in Terminal — it can be typed without "
            + "seeing the screen."
    }
}
