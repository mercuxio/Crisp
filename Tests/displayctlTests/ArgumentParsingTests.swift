import Testing
@testable import DisplayCore
@testable import displayctl

@Test func bareInvocationIsHelp() throws {
    #expect(try ArgumentParser.parse([]) == .help)
    #expect(try ArgumentParser.parse(["--help"]) == .help)
    #expect(try ArgumentParser.parse(["-h"]) == .help)
}

@Test func listDefaultsToAllDisplaysAndFavouredModesOnly() throws {
    let parsed = try ArgumentParser.parse(["list"])
    #expect(parsed == .list(ListOptions(displayIndex: nil, includeAll: false, json: false)))
}

@Test func listAcceptsItsFlags() throws {
    let parsed = try ArgumentParser.parse(["list", "--display", "2", "--all", "--json"])
    #expect(parsed == .list(ListOptions(displayIndex: 2, includeAll: true, json: true)))
}

@Test func setParsesAResolution() throws {
    let parsed = try ArgumentParser.parse(["set", "2560x1440"])
    #expect(parsed == .set(SetOptions(
        width: 2560, height: 1440, displayIndex: nil, refreshMilliHz: nil,
        hiDPI: nil, includeUnsafe: false, includeStretched: false,
        permanent: false, assumeYes: false, timeoutSeconds: 15)))
}

@Test func setAcceptsAnUppercaseSeparator() throws {
    // Someone typing blind, in a panic, with caps lock on.
    let parsed = try ArgumentParser.parse(["set", "2560X1440"])
    #expect(parsed == .set(SetOptions(
        width: 2560, height: 1440, displayIndex: nil, refreshMilliHz: nil,
        hiDPI: nil, includeUnsafe: false, includeStretched: false,
        permanent: false, assumeYes: false, timeoutSeconds: 15)))
}

@Test func setParsesFractionalRefreshRatesIntoMillihertz() throws {
    let parsed = try ArgumentParser.parse(["set", "2560x1440", "--hz", "59.94"])
    guard case .set(let options) = parsed else {
        Issue.record("expected a set command"); return
    }
    #expect(options.refreshMilliHz == 59_940)
}

@Test func setAcceptsItsRemainingFlags() throws {
    let parsed = try ArgumentParser.parse([
        "set", "1920x1080", "--display", "1", "--no-hidpi", "--unsafe",
        "--stretched", "--permanent", "--yes", "--timeout", "30",
    ])
    #expect(parsed == .set(SetOptions(
        width: 1920, height: 1080, displayIndex: 1, refreshMilliHz: nil,
        hiDPI: false, includeUnsafe: true, includeStretched: true,
        permanent: true, assumeYes: true, timeoutSeconds: 30)))
}

@Test func restoreAndDoctorTakeNoArguments() throws {
    #expect(try ArgumentParser.parse(["restore"]) == .restore)
    #expect(try ArgumentParser.parse(["doctor"]) == .doctor)
}

@Test func unknownCommandsAreRejected() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["frobnicate"]) }
}

@Test func setWithoutAResolutionIsRejected() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set"]) }
}

@Test func malformedResolutionsAreRejected() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "2560"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "2560x"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "widexhigh"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "0x1440"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "-100x1440"]) }
}

@Test func flagsExpectingAValueAreRejectedWithoutOne() {
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["list", "--display"]) }
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["set", "800x600", "--hz"]) }
}

@Test func unknownFlagsAreRejectedRatherThanIgnored() {
    // Silently ignoring a typo'd flag on a command that changes the screen is
    // how someone ends up at a resolution they did not ask for.
    #expect(throws: ParseError.self) { try ArgumentParser.parse(["list", "--jsonn"]) }
}

@Test func aRepeatedDisplayFlagIsRejectedRatherThanLastWins() {
    // `set --display 1 --display 2` reconfiguring display 2 while the user
    // believes they named display 1 is exactly the mistake this guards
    // against — silently accepting it means changing a screen nobody named.
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["list", "--display", "1", "--display", "2"])
    }
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["set", "1920x1080", "--display", "1", "--display", "2"])
    }
}

@Test func aRepeatedValuedFlagOnSetIsRejected() {
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["set", "1920x1080", "--timeout", "10", "--timeout", "20"])
    }
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["set", "1920x1080", "--hz", "60", "--hz", "59.94"])
    }
}

@Test func aRepeatedBooleanFlagOnSetIsRejected() {
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["set", "1920x1080", "--permanent", "--permanent"])
    }
}

@Test func theTwoSpellingsOfAssumeYesShareOneSlot() {
    // `-y` and `--yes` set the same field, so mixing them is a repeat too.
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["set", "1920x1080", "-y", "--yes"])
    }
    #expect(throws: ParseError.self) {
        try ArgumentParser.parse(["set", "1920x1080", "--yes", "-y"])
    }
}
