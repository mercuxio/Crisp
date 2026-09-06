import Foundation
import DisplayCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("displayctl: \(message)\n".utf8))
    exit(1)
}

let enumerator = CoreGraphicsEnumerator()

do {
    switch try ArgumentParser.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help:
        print(helpText)
    case .list(let options):
        print(try runList(options, enumerator: enumerator))
    case .set(let options):
        let configurator = CoreGraphicsConfigurator()
        let coordinator = RevertCoordinator(
            configurator: configurator,
            clock: SystemClock(),
            window: TimeInterval(options.timeoutSeconds))

        let outcome = try runSet(
            options,
            enumerator: enumerator,
            coordinator: coordinator,
            confirmation: StandardInputConfirmation())

        print(outcome.message)
        if case .reverted = outcome.result { exit(2) }

    case .restore:
        print(try runRestore(configurator: CoreGraphicsConfigurator()))

    case .doctor:
        print(try Doctor.report(enumerator: enumerator))
    }
} catch let error as ParseError {
    fail(error.message)
} catch let error as RevertAfterConfirmationFailed {
    fail(Renderer.describeRevertAfterConfirmationFailed(error.underlying))
} catch let error as DisplayError {
    fail(Renderer.describe(error))
} catch {
    fail("\(error)")
}
