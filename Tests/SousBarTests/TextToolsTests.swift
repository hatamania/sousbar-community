import AppKit
import XCTest
@testable import SousBar

final class TextToolsTests: XCTestCase {
    // MARK: stripMarkdown

    func testStripsHeadingsEmphasisAndInlineCode() {
        let out = TextTools.stripMarkdown("## Done\n\nFixed **two** things in `vite.config.ts` and *one* more.")
        XCTAssertEqual(out, "Done\nFixed two things in vite.config.ts and one more.")
    }

    func testBulletsAndQuotes() {
        let out = TextTools.stripMarkdown("- first\n* second\n> quoted")
        XCTAssertEqual(out, "• first\n• second\nquoted")
    }

    func testLinksKeepTheirText() {
        XCTAssertEqual(TextTools.stripMarkdown("See [the docs](https://x.y/z)."), "See the docs.")
    }

    func testCodeBlockBecomesChip() {
        let md = "Before\n```ts\nconst a = 1\nconst b = 2\n```\nAfter"
        XCTAssertEqual(TextTools.stripMarkdown(md), "Before\n‹code · 2 lines›\nAfter")
    }

    func testSingleLineCodeChipIsSingular() {
        XCTAssertEqual(TextTools.stripMarkdown("```\nx\n```"), "‹code · 1 line›")
    }

    func testUnclosedCodeBlockStillProducesChip() {
        XCTAssertEqual(TextTools.stripMarkdown("Text\n```\na\nb\nc"), "Text\n‹code · 3 lines›")
    }

    func testTablesFlattenAndDropSeparatorRow() {
        let md = "| Name | Value |\n|---|:---:|\n| a | 1 |"
        XCTAssertEqual(TextTools.stripMarkdown(md), "Name · Value\na · 1")
    }

    func testAsteriskInMathIsLeftAlone() {
        XCTAssertEqual(TextTools.stripMarkdown("2 * 3 = 6"), "2 * 3 = 6")
    }

    // MARK: paginate

    private let font = NSFont.systemFont(ofSize: 15)

    private func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    func testEmptyTextGivesOneEmptyPage() {
        XCTAssertEqual(TextTools.paginate("", width: 300, font: font), [""])
    }

    func testShortTextIsOnePage() {
        XCTAssertEqual(TextTools.paginate("Hello there.", width: 500, font: font), ["Hello there."])
    }

    func testPagesFitAndKeepEveryWord() {
        let text = (1...40).map { "Sentence number \($0) is here." }.joined(separator: " ")
        let pages = TextTools.paginate(text, width: 260, font: font)
        XCTAssertGreaterThan(pages.count, 1)
        for page in pages { XCTAssertLessThanOrEqual(width(page), 260, page) }
        let words = { (s: String) in s.split(separator: " ").map(String.init) }
        XCTAssertEqual(pages.flatMap(words), words(text))
    }

    func testOverlongSentenceSplitsOnWords() {
        let text = Array(repeating: "word", count: 200).joined(separator: " ")
        let pages = TextTools.paginate(text, width: 200, font: font)
        XCTAssertGreaterThan(pages.count, 1)
        for page in pages { XCTAssertLessThanOrEqual(width(page), 200) }
        XCTAssertEqual(pages.joined(separator: " "), text)
    }

    func testSingleWordWiderThanPageStillAppears() {
        let long = String(repeating: "x", count: 300)
        XCTAssertEqual(TextTools.paginate(long, width: 100, font: font), [long])
    }

    // MARK: truncate

    func testTruncate() {
        XCTAssertEqual(TextTools.truncate("short", 10), "short")
        XCTAssertEqual(TextTools.truncate("exactly10!", 10), "exactly10!")
        XCTAssertEqual(TextTools.truncate("this is too long", 8), "this is…")
    }
}

final class ToolTextTests: XCTestCase {
    func testMcpDisplayName() {
        XCTAssertEqual(ToolText.displayName("mcp__github__create_issue"), "github·create_issue")
        XCTAssertEqual(ToolText.displayName("Bash"), "Bash")
    }

    func testBashSummaryFlattensNewlines() {
        XCTAssertEqual(ToolText.summary("Bash", ["command": "cd x\nmake"]), "cd x ⏎ make")
    }

    func testFileToolsShowLastTwoPathParts() {
        XCTAssertEqual(ToolText.summary("Edit", ["file_path": "/a/b/c/d.swift"]), "c/d.swift")
    }

    func testUnknownToolSummaryIsCompactJSON() {
        XCTAssertEqual(ToolText.summary("mcp__x__y", ["b": 1, "a": "z"]), #"{"a":"z","b":1}"#)
    }

    func testShortLabelTruncatesSummary() {
        let label = ToolText.shortLabel("Bash", ["command": String(repeating: "a", count: 100)])
        XCTAssertTrue(label.hasPrefix("Bash: "))
        XCTAssertEqual(label.count, "Bash: ".count + 60)
    }

    func testShortLabelWithoutSummaryIsJustName() {
        XCTAssertEqual(ToolText.shortLabel("Read", [:]), "Read")
    }

    func testRiskClassification() {
        for tool in ["Read", "Grep", "Glob", "WebFetch"] { XCTAssertTrue(ToolText.readOnly.contains(tool), tool) }
        for tool in ["Bash", "Edit", "Write", "MultiEdit", "mcp__a__b", "SomeFutureTool"] {
            XCTAssertFalse(ToolText.readOnly.contains(tool), tool)
        }
    }

    func testBashDetailIncludesDescriptionAndFence() {
        let detail = ToolText.detail("Bash", ["command": "ls", "description": "List"])
        XCTAssertEqual(detail, "List\n\n```\nls\n```")
    }
}
