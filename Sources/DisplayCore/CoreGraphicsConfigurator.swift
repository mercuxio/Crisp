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

    /// Full six-field signature equality between `mode` and `signature` —
    /// nothing more. Spec §10: the `ioDisplayModeID` hint gives an O(1)
    /// apply, and this equality check is what makes a stale hint (or one
    /// that now points at a different variant sharing its ID) detectable,
    /// so the caller can fall back to a full scan instead of acting on it.
    public static func hintIsValid(_ mode: DisplayMode, against signature: ModeSignature) -> Bool {
        mode.signature == signature
    }

    /// Maps our scope to CoreGraphics' vocabulary. Spec §8.1: session is the
    /// only scope ever applied first — extracted to its own function so that
    /// fact is a tested, documented mapping rather than an inline ternary.
    static func cgOption(for scope: ConfigurationScope) -> CGConfigureOption {
        switch scope {
        case .session: return .forSession
        case .permanent: return .permanently
        }
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

        // Configure-loop failures must cancel: CoreGraphics has been told
        // about modes but nothing has been completed yet, so cancelling here
        // is well-defined and required — an abandoned handle at this point
        // leaves the window server sitting mid-transaction.
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

        let option = Self.cgOption(for: scope)
        // CGDisplayConfigRef (an OpaquePointer) is not Sendable, so it cannot
        // be captured directly in the @Sendable closure Watchdog.run requires.
        // Boxed the same way Watchdog boxes its result: the pointer only ever
        // crosses to the one worker thread the watchdog spawns, and that
        // thread either finishes before the deadline (in which case this
        // function has already returned control) or is abandoned in place —
        // never touched from two threads at once.
        let configurationBox = UncheckedBox(configuration)
        // If this throws (a watchdog timeout), do NOT cancel here: the
        // worker thread Watchdog.run spawned is still inside
        // CGCompleteDisplayConfiguration, holding this same handle. Calling
        // CGCancelDisplayConfiguration from this thread would race a handle
        // that is live on another thread. The abandoned call is left to
        // resolve — or never resolve — on its own; see Watchdog's doc comment.
        let completion = try Watchdog.run(timeout: completionTimeout) {
            CGCompleteDisplayConfiguration(configurationBox.value, option).rawValue
        }

        // If this fails — not a timeout, CGCompleteDisplayConfiguration
        // returned normally with a failure code — do NOT cancel either:
        // completing the configuration, successfully or not, consumes the
        // handle. There is no open transaction left to cancel.
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

        let candidates = raw.map { (ioDisplayModeID: $0.ioDisplayModeID, signature: signature(of: $0)) }

        guard let index = ModePick.index(in: candidates, matching: mode) else {
            throw DisplayError.modeUnavailable(mode.signature)
        }
        return raw[index]
    }

    private func signature(of candidate: CGDisplayMode) -> ModeSignature {
        ModeConversion.signature(
            pointWidth: candidate.width,
            pointHeight: candidate.height,
            pixelWidth: candidate.pixelWidth,
            pixelHeight: candidate.pixelHeight,
            refreshRateHz: candidate.refreshRate,
            isUsableForDesktopGUI: candidate.isUsableForDesktopGUI())
    }
}

/// The pure form of `resolveRawMode`'s search, extracted so it can be tested
/// without a real `CGDisplayMode` — which cannot be constructed in a test;
/// see the note at the top of `CoreGraphicsEnumerator.swift`: anything worth
/// testing takes primitives instead.
///
/// Mirrors `resolveRawMode` exactly and shares its safety gate: try the O(1)
/// hint first, validated through `CoreGraphicsConfigurator.hintIsValid` (the
/// same gate the apply path uses — not a second, untested copy of it), then
/// fall back to a full scan by signature if the hint is stale or collides
/// with the wrong variant sharing its ID.
enum ModePick {
    /// The index into `candidates` of the mode matching `mode`, or nil if
    /// none match.
    static func index(
        in candidates: [(ioDisplayModeID: Int32, signature: ModeSignature)],
        matching mode: DisplayMode
    ) -> Int? {
        // Fast path: the hint, validated.
        if let hintIndex = candidates.firstIndex(where: { $0.ioDisplayModeID == mode.ioDisplayModeID }) {
            let hinted = candidates[hintIndex]
            let hintedAsMode = DisplayMode(
                signature: hinted.signature,
                ioDisplayModeID: hinted.ioDisplayModeID,
                isStretched: false,
                source: .publicAPI)
            if CoreGraphicsConfigurator.hintIsValid(hintedAsMode, against: mode.signature) {
                return hintIndex
            }
        }

        // Slow path: the hint was stale (or pointed at the wrong variant of
        // a duplicated ID) — search everything by signature.
        return candidates.firstIndex(where: { $0.signature == mode.signature })
    }
}

/// Smuggles a non-Sendable value across the single hop `Watchdog.run` makes to
/// its worker thread. Not a general-purpose concurrency primitive — see the
/// call site for why this specific crossing is safe.
private final class UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
