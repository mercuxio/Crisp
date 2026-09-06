import AppKit

/// Crisp runs as a menu bar agent: no dock icon, no main window, no menu bar
/// title of its own. `LSUIElement` in Info.plist is what makes that true at
/// launch; `.accessory` here keeps it true if the app is ever run from a bundle
/// that lacks the key.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = StatusMenuController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
