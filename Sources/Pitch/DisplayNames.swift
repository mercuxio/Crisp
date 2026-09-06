import AppKit
import CoreGraphics

/// The names macOS itself shows for the attached displays.
///
/// `DisplayCore` deliberately does not answer this. It labels displays by their
/// position in `CGGetOnlineDisplayList` — "Display 2" — which suits `displayctl`,
/// where that index is also how you address a display. In a tooltip the same
/// string is worse than useless: it names a slot rather than a monitor, and the
/// slot changes when you replug.
///
/// `NSScreen.localizedName` is where the real name lives, and it is the very
/// string System Settings prints, so the panel and Settings cannot disagree.
/// Reading the EDID through IOKit would get there too, and will have to when
/// presets need an identity that survives a reboot (spec §9) — but that is a
/// different problem, and AppKit already knows the answer to this one.
@MainActor
enum DisplayNames {
    /// Every display AppKit can see right now, keyed by the same ID
    /// CoreGraphics uses.
    ///
    /// Empty when there is no window server to ask — a CLI over SSH, say —
    /// which is exactly when callers should fall back to DisplayCore's label.
    static func system() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { continue }
            names[number.uint32Value] = screen.localizedName
        }
        return names
    }
}
