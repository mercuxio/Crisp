// This file imports both `Testing` and `displayctl`, and BOTH define a type
// named `Confirmation`. Bare `Confirmation` is a hard ambiguity error here —
// qualify it as `displayctl.Confirmation`, or keep the reference leading-dot
// inferred. See the same note atop SetCommandTests.swift.
import Foundation
import Testing
@testable import displayctl

// D7: `StandardInputConfirmation` had zero tests before this file, and the
// `String? -> Confirmation` mapping it hides inside a detached-thread closure
// is exactly why B1 (bare Enter reading as confirmed, despite the `[y/N]`
// prompt) survived seven reviews. Pin the whole table here, against the
// extracted pure function, so nothing hides the mapping again.

@Test(arguments: [
    // Confirms only on "y" or "yes", case-insensitively, after trimming.
    ("y", displayctl.Confirmation.confirmed),
    ("Y", .confirmed),
    ("yes", .confirmed),
    ("YES", .confirmed),
    (" y ", .confirmed),
    // Every other non-nil input declines.
    ("n", .declined),
    ("no", .declined),
    ("N", .declined),
    ("", .declined),
    (" ", .declined),
    ("asdf", .declined),
    ("\u{1B}[A", .declined),  // a stray arrow-key escape sequence
])
func stdinLineMapsToTheExpectedConfirmation(line: String, expected: displayctl.Confirmation) {
    #expect(StandardInputConfirmation.confirmation(forLine: line) == expected)
}

@Test func eofDeclinesRatherThanConfirming() {
    // Bare Enter and EOF are the two blind keystrokes a person on an
    // unreadable screen is most likely to produce. Both must decline.
    #expect(StandardInputConfirmation.confirmation(forLine: nil) == .declined)
}
