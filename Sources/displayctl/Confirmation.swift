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
            let line = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            box.answer = (line == nil || line == "n" || line == "no")
                ? .declined
                : .confirmed
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            return .timedOut
        }
        return box.answer
    }

    private final class AnswerBox: @unchecked Sendable {
        var answer: Confirmation = .declined
    }
}
