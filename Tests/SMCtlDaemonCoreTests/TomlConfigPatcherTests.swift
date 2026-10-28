import XCTest
@testable import SMCtlDaemonCore

final class TomlConfigPatcherTests: XCTestCase {
    func testReplacesValuePreservingIndentAndComment() {
        let input = """
        [battery]
          limit = "80"   # keep me
        sleep_policy = "strict"
        """

        let output = TomlConfigPatcher.patch(text: input, sections: [
            .init(name: "battery", values: [("limit", "\"70-80\"")])
        ])

        XCTAssertTrue(output.contains("  limit = \"70-80\"  # keep me"), output)
        XCTAssertTrue(output.contains("sleep_policy = \"strict\""), output)
        XCTAssertTrue(output.hasSuffix("\n"))
    }

    func testIgnoresHashInsideQuotedValue() {
        let input = """
        [sentry]
        dsn = "https://public@example.invalid/1#fragment"  # real comment
        """

        let output = TomlConfigPatcher.patch(text: input, sections: [
            .init(name: "sentry", values: [("dsn", "\"\"")])
        ])

        XCTAssertTrue(output.contains("dsn = \"\"  # real comment"), output)
        XCTAssertFalse(output.contains("#fragment"), "the old value must be gone: \(output)")
    }

    func testInsertsMissingKeyBeforeTrailingBlankLine() {
        let input = """
        [fan]
        profile = "auto"

        [safety]
        temp_ceiling = 95
        """

        let output = TomlConfigPatcher.patch(text: input, sections: [
            .init(name: "fan", values: [("profile", "\"quiet\""), ("extra", "true")])
        ])

        XCTAssertTrue(output.contains("""
        [fan]
        profile = "quiet"
        extra = true

        [safety]
        """), output)
    }

    func testAppendsMissingSectionAtEnd() {
        let input = """
        [battery]
        limit = "80"
        """

        let output = TomlConfigPatcher.patch(text: input, sections: [
            .init(name: "update", values: [("check", "false")])
        ])

        XCTAssertTrue(output.hasPrefix("[battery]\nlimit = \"80\"\n"), output)
        XCTAssertTrue(output.contains("\n[update]\ncheck = false\n"), output)
    }

    func testLeavesUnknownKeysAndArrayOfTablesUntouched() {
        let input = """
        [battery]
        limit = "80"
        vendor_flag = true   # unknown to smctl

        [[alert]]
        name = "a \\"quoted\\" name"
        command = ["/bin/echo", "hi # not a comment"]
        """

        let output = TomlConfigPatcher.patch(text: input, sections: [
            .init(name: "battery", values: [("limit", "\"60\"")])
        ])

        XCTAssertTrue(output.contains("limit = \"60\""), output)
        XCTAssertTrue(output.contains("vendor_flag = true   # unknown to smctl"), output)
        XCTAssertTrue(output.contains("[[alert]]"), output)
        XCTAssertTrue(output.contains("name = \"a \\\"quoted\\\" name\""), output)
        XCTAssertTrue(output.contains("command = [\"/bin/echo\", \"hi # not a comment\"]"), output)
    }

    func testDoesNotTouchCommentedOutKey() {
        let input = """
        [battery]
        # limit = "80"
        sleep_policy = "strict"
        """

        let output = TomlConfigPatcher.patch(text: input, sections: [
            .init(name: "battery", values: [("limit", "\"60\"")])
        ])

        XCTAssertTrue(output.contains("# limit = \"80\""), output)
        XCTAssertTrue(output.contains("limit = \"60\""), output)
    }

    func testStringLiteralEscapesControlCharacters() {
        let literal = TomlConfigPatcher.stringLiteral("a\"b\\c\nd\te")
        XCTAssertEqual(literal, "\"a\\\"b\\\\c\\nd\\te\"")
    }
}
