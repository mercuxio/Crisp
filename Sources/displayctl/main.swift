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
    case .set:
        fail("'set' is not wired up yet")
    case .restore:
        fail("'restore' is not wired up yet")
    case .doctor:
        fail("'doctor' is not wired up yet")
    }
} catch let error as ParseError {
    fail(error.message)
} catch let error as DisplayError {
    fail(Renderer.describe(error))
} catch {
    fail("\(error)")
}
