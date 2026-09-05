import CoreGraphics
import Foundation

/// Runs a blocking call with a deadline.
///
/// `CGCompleteDisplayConfiguration` is documented to hang in some
/// configurations. It cannot be cancelled, so on timeout the work item is
/// abandoned rather than killed — the caller gets control back and the user
/// gets an error instead of a frozen app.
public enum Watchdog {
    public static func run(
        timeout: TimeInterval,
        work: @escaping @Sendable () -> Int32
    ) throws -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()

        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw DisplayError.completionTimedOut(seconds: timeout)
        }
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Int32 = 0
    }
}

/// The real write path.
public final class CoreGraphicsConfigurator: DisplayConfiguring {
    private let completionTimeout: TimeInterval

    public init(completionTimeout: TimeInterval = 5.0) {
        self.completionTimeout = completionTimeout
    }

    /// Whether a mode reached via its `ioDisplayModeID` hint is still the mode
    /// that was recorded. Spec §10: the hint gives an O(1) apply, but it is
    /// validated every time so staleness is detected rather than acted on.
    public static func hintIsValid(_ mode: DisplayMode, against signature: ModeSignature) -> Bool {
        mode.signature == signature
    }

    public func apply(
        _ plan: [CGDirectDisplayID: DisplayMode],
        scope: ConfigurationScope
    ) throws {
        guard !plan.isEmpty else { return }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw DisplayError.configurationFailed(code: beginResult.rawValue)
        }

        // From here on, every failure path must cancel — an abandoned
        // configuration handle leaves the window server in a transaction.
        do {
            for (displayID, mode) in plan {
                let raw = try resolveRawMode(mode, on: displayID)
                let result = CGConfigureDisplayWithDisplayMode(
                    configuration, displayID, raw, nil)
                guard result == .success else {
                    throw DisplayError.configurationFailed(code: result.rawValue)
                }
            }
        } catch {
            CGCancelDisplayConfiguration(configuration)
            throw error
        }

        let option: CGConfigureOption = scope == .permanent ? .permanently : .forSession
        // CGDisplayConfigRef (an OpaquePointer) is not Sendable, so it cannot
        // be captured directly in the @Sendable closure Watchdog.run requires.
        // Boxed the same way Watchdog boxes its result: the pointer only ever
        // crosses to the one worker thread the watchdog spawns, and that
        // thread either finishes before the deadline (in which case this
        // function has already returned control) or is abandoned in place —
        // never touched from two threads at once.
        let configurationBox = UncheckedBox(configuration)
        let completion = try Watchdog.run(timeout: completionTimeout) {
            CGCompleteDisplayConfiguration(configurationBox.value, option).rawValue
        }

        guard completion == CGError.success.rawValue else {
            throw DisplayError.configurationFailed(code: completion)
        }
    }

    public func restoreDefaults() throws {
        // Spec §8.3: this is the panic path and deliberately restores every
        // display. A user who cannot see a screen cannot tell you which one.
        CGRestorePermanentDisplayConfiguration()
    }

    /// Finds the `CGDisplayMode` corresponding to one of our modes, preferring
    /// the O(1) hint but never trusting it unvalidated.
    private func resolveRawMode(
        _ mode: DisplayMode,
        on displayID: CGDirectDisplayID
    ) throws -> CGDisplayMode {
        // Same constant discipline as CoreGraphicsEnumerator — see spec §4.1.
        let options = [
            kCGDisplayShowDuplicateLowResolutionModes as String: true
        ] as CFDictionary

        guard let raw = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            throw DisplayError.modeEnumerationFailed(displayID)
        }

        func signature(of candidate: CGDisplayMode) -> ModeSignature {
            ModeConversion.signature(
                pointWidth: candidate.width,
                pointHeight: candidate.height,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight,
                refreshRateHz: candidate.refreshRate,
                isUsableForDesktopGUI: candidate.isUsableForDesktopGUI())
        }

        // Fast path: the hint, validated.
        if let hinted = raw.first(where: { $0.ioDisplayModeID == mode.ioDisplayModeID }),
           signature(of: hinted) == mode.signature {
            return hinted
        }

        // Slow path: the hint was stale, so search by signature.
        if let found = raw.first(where: { signature(of: $0) == mode.signature }) {
            return found
        }

        throw DisplayError.modeUnavailable(mode.signature)
    }
}

/// Smuggles a non-Sendable value across the single hop `Watchdog.run` makes to
/// its worker thread. Not a general-purpose concurrency primitive — see the
/// call site for why this specific crossing is safe.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
