//
//  MDParserTests.swift
//  PennyTests
//
//  Guards the chat transcript's tiny markdown engine (`enum MD` in ChatView.swift):
//  splitting assistant replies into paragraph vs pipe-table blocks (header +
//  separator + rows), separator detection (dashes/colons with optional spaces),
//  cell parsing with ragged rows padded to the header count, the data-driven
//  column-alignment heuristic (a column at least half numeric/money-like
//  right-aligns; separator colons are ignored), and `MD.inline`, which must keep
//  **bold**/*italic* while preserving literal newlines. Every assistant bubble —
//  including the deterministic LEDGER tables — renders through this parser, so a
//  regression here garbles every table Penny shows.
//

import XCTest
import SwiftUI
@testable import Penny

final class MDParserTests: XCTestCase {

    // MARK: - helpers

    private func tableBlock(_ block: MD.Block?,
                            file: StaticString = #filePath, line: UInt = #line)
        -> (headers: [String], rows: [[String]], aligns: [TextAlignment])? {
        if case .table(let h, let r, let a)? = block { return (h, r, a) }
        XCTFail("expected a table block, got \(String(describing: block))", file: file, line: line)
        return nil
    }

    private func paragraphBlock(_ block: MD.Block?,
                                file: StaticString = #filePath, line: UInt = #line) -> String? {
        if case .paragraph(let s)? = block { return s }
        XCTFail("expected a paragraph block, got \(String(describing: block))", file: file, line: line)
        return nil
    }

    /// Alignment the heuristic assigns to a single-column table whose one data
    /// cell is `value` — the only way to probe the private isNumeric().
    private func alignment(ofCell value: String) -> TextAlignment? {
        tableBlock(MD.parse("| H |\n|---|\n| \(value) |").first)?.aligns.first
    }

    // MARK: - paragraphs vs tables

    func testPlainTextIsOneParagraphKeepingInteriorBlankLines() {
        let blocks = MD.parse("one\n\ntwo")
        XCTAssertEqual(blocks.count, 1, "no table lines → everything is a single paragraph")
        XCTAssertEqual(paragraphBlock(blocks.first), "one\n\ntwo",
                       "interior blank lines are preserved inside the paragraph; edges are trimmed")
    }

    func testDocumentSplitsIntoParagraphTableParagraph() {
        let md = """
        Intro line.

        | H1 | H2 |
        | --- | ---: |
        | a | 1 |
        | b | 2 |

        Outro **bold**.
        """
        let blocks = MD.parse(md)
        XCTAssertEqual(blocks.count, 3, "expected paragraph, table, paragraph — got \(blocks.count) blocks")
        XCTAssertEqual(paragraphBlock(blocks.first), "Intro line.")
        guard let t = tableBlock(blocks[1]) else { return }
        XCTAssertEqual(t.headers, ["H1", "H2"])
        XCTAssertEqual(t.rows, [["a", "1"], ["b", "2"]])
        XCTAssertEqual(t.aligns, [.leading, .trailing],
                       "text column leads, all-numeric column trails")
        XCTAssertEqual(paragraphBlock(blocks[2]), "Outro **bold**.")
    }

    func testHasTable() {
        XCTAssertTrue(MD.hasTable("| a | b |\n|---|---|\n| 1 | 2 |"))
        XCTAssertTrue(MD.hasTable("| a | b |\n|---|---|"),
                      "header + separator with zero body rows is still a table")
        XCTAssertFalse(MD.hasTable("no pipes at all"))
        XCTAssertFalse(MD.hasTable("a | b\nno separator follows"),
                       "a pipe line without a separator underneath is prose, not a table")
    }

    func testZeroRowTableParsesWithLeadingAligns() {
        guard let t = tableBlock(MD.parse("| A | B |\n|---|---|").first) else { return }
        XCTAssertEqual(t.headers, ["A", "B"])
        XCTAssertTrue(t.rows.isEmpty)
        XCTAssertEqual(t.aligns, [.leading, .leading], "no data → default leading alignment")
    }

    // MARK: - separator detection

    func testSeparatorVariantsAllFormTables() {
        let variants = [
            "| A | B |\n|---|:--:|\n| x | y |",          // mixed dashes + colon-centering
            "| A | B |\n|  ---  |  :--:  |\n| x | y |",  // spaces inside the separator
            "| A | B |\n|:---|---:|\n| x | y |",         // left / right colons
            "A | B\n--- | ---\nx | y",                   // GitHub style without outer pipes
            "| A | B |\n| - | - |\n| x | y |",           // minimal single-dash cells
        ]
        for md in variants {
            guard let t = tableBlock(MD.parse(md).first) else {
                XCTFail("separator variant not recognised in:\n\(md)"); continue
            }
            XCTAssertEqual(t.headers, ["A", "B"], "headers wrong for:\n\(md)")
            XCTAssertEqual(t.rows, [["x", "y"]], "rows wrong for:\n\(md)")
        }
    }

    func testNonSeparatorLinesDoNotStartTables() {
        // A letter inside the dashes, a pipe-less dash line, and a dash-less
        // colon line must all fail the separator test → whole text stays prose.
        for md in ["| A |\n|--x|\n| v |",
                   "| A |\n----\n| v |",
                   "| A |\n| : |\n| v |"] {
            let blocks = MD.parse(md)
            XCTAssertFalse(MD.hasTable(md), "should not detect a table in:\n\(md)")
            XCTAssertEqual(blocks.count, 1, "expected one prose paragraph for:\n\(md)")
        }
    }

    func testSeparatorLineInsideBodyEndsTheTable() {
        let blocks = MD.parse("| A |\n|---|\n| 1 |\n|---|\n| 2 |")
        XCTAssertEqual(blocks.count, 2)
        guard let t = tableBlock(blocks.first) else { return }
        XCTAssertEqual(t.rows, [["1"]], "a second separator terminates the row scan")
        XCTAssertEqual(paragraphBlock(blocks[1]), "|---|\n| 2 |",
                       "the leftover lines fall through as a paragraph")
    }

    func testBlankLineEndsTheTable() {
        let blocks = MD.parse("| A |\n|---|\n| 1 |\n\n| 2 |")
        XCTAssertEqual(blocks.count, 2)
        guard let t = tableBlock(blocks.first) else { return }
        XCTAssertEqual(t.rows, [["1"]])
        XCTAssertEqual(paragraphBlock(blocks[1]), "| 2 |",
                       "an orphan pipe line after the blank is prose (no separator follows)")
    }

    // MARK: - cells

    func testCellsTrimOuterPipesAndKeepInteriorEmpties() {
        guard let t = tableBlock(MD.parse("| a |  | c |\n|---|---|---|\nx | y | z").first) else { return }
        XCTAssertEqual(t.headers, ["a", "", "c"], "interior empty cells must survive")
        XCTAssertEqual(t.rows, [["x", "y", "z"]], "rows without outer pipes parse the same")
    }

    func testRaggedRowsPaddedToHeaderCount() {
        guard let t = tableBlock(MD.parse("| A | B | C |\n|---|---|---|\n| only |\n| x | y |").first) else { return }
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[0], ["only", "", ""], "1-cell row padded to 3 headers")
        XCTAssertEqual(t.rows[1], ["x", "y", ""], "2-cell row padded to 3 headers")
    }

    // MARK: - alignment heuristic (numeric-majority, data-driven)

    func testAlignmentNumericMajorityRules() {
        // 2 of 3 numeric → trailing
        var t = tableBlock(MD.parse("| M |\n|---|\n| £1,234.56 |\n| -2.5 |\n| junk |").first)
        XCTAssertEqual(t?.aligns, [.trailing], "2/3 numeric should right-align")
        // exactly half (1 of 2) → trailing (the >= half rule)
        t = tableBlock(MD.parse("| M |\n|---|\n| 10 |\n| abc |").first)
        XCTAssertEqual(t?.aligns, [.trailing], "exactly half numeric still right-aligns")
        // 1 of 3 → leading
        t = tableBlock(MD.parse("| M |\n|---|\n| 10 |\n| a |\n| b |").first)
        XCTAssertEqual(t?.aligns, [.leading], "below half numeric stays left-aligned")
        // all text → leading
        t = tableBlock(MD.parse("| M |\n|---|\n| a |\n| b |").first)
        XCTAssertEqual(t?.aligns, [.leading])
    }

    func testAllEmptyColumnDefaultsToLeading() {
        guard let t = tableBlock(MD.parse("| A | B |\n|---|---|\n| 1 | |\n| 2 | |").first) else { return }
        XCTAssertEqual(t.aligns, [.trailing, .leading],
                       "empty cells are filtered out; a valueless column leads")
    }

    func testAlignmentIgnoresSeparatorColonsAndUsesData() {
        // ":---:" / "---:" hints in the separator have NO effect — only the data does.
        var t = tableBlock(MD.parse("| A |\n|---:|\n| xyz |").first)
        XCTAssertEqual(t?.aligns, [.leading], "text column leads despite a right-colon separator")
        t = tableBlock(MD.parse("| A |\n|:---|\n| 42 |").first)
        XCTAssertEqual(t?.aligns, [.trailing], "numeric column trails despite a left-colon separator")
    }

    func testNumericDetectionAcceptsMoneyForms() {
        let numeric = ["1,234", "£1,234.56", "$-5.00", "-2.5", "-£3.50", "12%",
                       "₹1,23,456.78", "1 234", "€99", "100."]
        for v in numeric {
            XCTAssertEqual(alignment(ofCell: v), .trailing,
                           "'\(v)' should count as numeric/money → right-aligned")
        }
    }

    func testNumericDetectionRejectsJunk() {
        let junk = ["1.2.3", "-", "abc123", "12a", "(1.50)", "--5", "5-",
                    "N/A", "£", "100.00 CR", "junk"]
        for v in junk {
            XCTAssertEqual(alignment(ofCell: v), .leading,
                           "'\(v)' should NOT count as numeric → left-aligned")
        }
    }

    // MARK: - inline markdown

    func testInlineBoldItalicPreservingNewlines() {
        let attr = MD.inline("**bold** and *ital*\nsecond line")
        XCTAssertEqual(String(attr.characters), "bold and ital\nsecond line",
                       "markup stripped, literal newline preserved")
        var bold = "", italic = ""
        for run in attr.runs {
            let piece = String(attr.characters[run.range])
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { bold += piece }
            if run.inlinePresentationIntent?.contains(.emphasized) == true { italic += piece }
        }
        XCTAssertEqual(bold, "bold", "exactly the **…** span carries strong emphasis")
        XCTAssertEqual(italic, "ital", "exactly the *…* span carries emphasis")
    }

    func testInlineLeavesPlainWhitespaceUntouched() {
        let attr = MD.inline("a  b\nc")
        XCTAssertEqual(String(attr.characters), "a  b\nc",
                       "double spaces and newlines survive inline parsing")
    }
}
