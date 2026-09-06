import ServiceManagement

/// Pitch's login-item registration, read from the system on every access.
///
/// Nothing is cached. The user can add or remove Pitch under System Settings ›
/// General › Login Items without the app ever hearing about it, so a stored
/// value would eventually put a checkmark next to a setting that is off.
@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// What to say beneath the toggle when a plain on/off reading would mislead,
    /// and nil when it would not.
    ///
    /// `.notRegistered` and `.notFound` both leave the toggle unchecked but mean
    /// very different things: one is "off", the other is "macOS cannot match
    /// this bundle to a login item at all". Collapsing them tells a fresh
    /// install it is broken.
    static var note: String? {
        switch status {
        case .requiresApproval:
            return "Approve Pitch under System Settings › General › Login Items."
        case .notFound:
            // Registration is keyed to the code signature, so an ad-hoc signed
            // build usually cannot be matched to a login item. A Developer ID
            // signed copy resolves this.
            return "Not recognised as a login item — expected for an unsigned build."
        default:
            return nil
        }
    }

    static func set(_ wanted: Bool) throws {
        if wanted {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
