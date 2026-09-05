import Foundation

public enum Confirmation: Equatable, Sendable {
    case confirmed
    case declined
    case timedOut
}

/// Where the answer to "can you see this?" comes from.
public protocol ConfirmationSource: Sendable {
    func awaitConfirmation(timeoutSeconds: Int) -> Confirmation
}

/// Reads one line from stdin, giving up after the timeout.
///
/// `readLine` cannot be cancelled, so on timeout the reader thread is left
/// blocked and the process exits with it. That is acceptable here and only
/// here: this is a short-lived CLI, and the alternative — raw-mode terminal
/// handling with a select loop — is a lot of machinery to save a thread that
/// dies milliseconds later.
public struct StandardInputConfirmation: ConfirmationSource {
    public init() {}

    public func awaitConfirmation(timeoutSeconds: Int) -> Confirmation {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()

        Thread.detachNewThread {
            let line = readLine(strippingNewline: true)
            box.answer = Self.confirmation(forLine: line)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            return .timedOut
        }
        return box.answer
    }

    /// Maps one line of raw stdin input to a `Confirmation`. `nil` means EOF
    /// (Ctrl-D with nothing typed).
    ///
    /// Allowlist, not a denylist: confirms only on `y` or `yes`, after
    /// trimming whitespace and lowercasing. Every other input — empty,
    /// whitespace-only, garbage, an arrow-key escape sequence, and EOF —
    /// declines. This is deliberate: the prompt reads `[y/N]`, and bare Enter
    /// is the most natural blind keystroke there is for someone staring at a
    /// screen they cannot read. Failing open here would keep the mode that
    /// broke their display.
    static func confirmation(forLine line: String?) -> Confirmation {
        guard let trimmed = line?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return .declined
        }
        return (trimmed == "y" || trimmed == "yes") ? .confirmed : .declined
    }

    private final class AnswerBox: @unchecked Sendable {
        var answer: Confirmation = .declined
    }
}
