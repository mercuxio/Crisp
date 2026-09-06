import CoreGraphics

/// The complete error surface of DisplayCore.
///
/// These carry no user-facing text by design (spec §13): the app and the CLI
/// render them differently, and DisplayCore should not have an opinion about
/// either.
public enum DisplayError: Error, Equatable, Sendable {
    case noSuchDisplay(CGDirectDisplayID)
    case modeEnumerationFailed(CGDirectDisplayID)
    case currentModeUnavailable(CGDirectDisplayID)

    /// A CoreGraphics configuration call returned a non-success code.
    case configurationFailed(code: Int32)

    /// `CGCompleteDisplayConfiguration` did not return within the watchdog
    /// window. Documented to happen in the field; spec §8.1.
    case completionTimedOut(seconds: Double)

    /// A stored preset no longer resolves to any available mode.
    case modeUnavailable(ModeSignature)

    /// No mode on this display satisfies the user's request.
    case noMatchingMode(requestedWidth: Int, requestedHeight: Int)

    /// The revert deadline passed before the change was confirmed.
    case confirmationExpired
}
