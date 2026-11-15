import XCTest
@testable import ZTronSearchEngineMLX

final class ThinkBlockFilterTests: XCTestCase {
    /// Feeds `pieces` one by one and returns everything the filter let through, plus the
    /// individual results so tests can check when text was released.
    private func run(_ pieces: [String], filter: ThinkBlockFilter = ThinkBlockFilter()) -> (text: String, steps: [String]) {
        var filter = filter
        var steps = pieces.map { filter.consume($0) }
        steps.append(filter.finish())
        return (steps.joined(), steps)
    }

    /// Every way of cutting `text` into two pieces, and into single characters.
    private func splits(of text: String) -> [[String]] {
        var result: [[String]] = [text.map(String.init)]
        for cut in text.indices.dropFirst() {
            result.append([String(text[..<cut]), String(text[cut...])])
        }
        return result
    }

    func testTextWithoutTagsPassesThroughUnchanged() {
        XCTAssertEqual(run(["Hello", ", ", "world."]).text, "Hello, world.")
        XCTAssertEqual(run([""]).text, "")
        XCTAssertEqual(run([]).text, "")
    }

    func testBlockInOnePieceIsRemoved() {
        XCTAssertEqual(run(["<think>plan the answer</think>Paris."]).text, "Paris.")
    }

    func testTextBeforeAndAfterABlockIsKept() {
        XCTAssertEqual(run(["The answer <think>hmm</think>is 42."]).text, "The answer is 42.")
    }

    func testBlockSplitAcrossPiecesIsRemovedWhereverTheCutFalls() {
        let text = "Before <think>secret reasoning</think> after."
        for pieces in splits(of: text) {
            XCTAssertEqual(run(pieces).text, "Before  after.", "pieces: \(pieces)")
        }
    }

    func testOpeningTagSplitAcrossThreeTokens() {
        let result = run(["<", "thi", "nk>", "hidden", "</", "think", ">", "shown"])
        XCTAssertEqual(result.text, "shown")
        // Nothing may leak while the tag is still incomplete.
        XCTAssertEqual(Array(result.steps.prefix(7)), ["", "", "", "", "", "", ""])
    }

    func testSeveralBlocksAreAllRemoved() {
        XCTAssertEqual(run(["a<think>1</think>b<think>2</think>c"]).text, "abc")
    }

    func testNestedBlocksNeedMatchingClosingTags() {
        XCTAssertEqual(run(["<think>outer <think>inner</think> still hidden</think>visible"]).text, "visible")
        for pieces in splits(of: "x<think>a<think>b</think>c</think>y") {
            XCTAssertEqual(run(pieces).text, "xy", "pieces: \(pieces)")
        }
    }

    func testUnterminatedBlockSwallowsTheRest() {
        XCTAssertEqual(run(["Shown. <think>never closed", " and more"]).text, "Shown. ")
        XCTAssertEqual(run(["<think>only thinking"]).text, "")
    }

    func testUnterminatedBlockWithPartialClosingTagStaysHidden() {
        XCTAssertEqual(run(["<think>abc</thi"]).text, "")
    }

    func testStrayClosingTagIsDropped() {
        XCTAssertEqual(run(["no block here</think> at all"]).text, "no block here at all")
    }

    func testWhitespaceAfterALeadingBlockIsDropped() {
        XCTAssertEqual(run(["<think>\nreasoning\n</think>\n\nThe answer."]).text, "The answer.")
        XCTAssertEqual(run(["<think>x</think>", "\n", "\n", "  ", "Answer"]).text, "Answer")
        // Whitespace alone before the block does not count as text.
        XCTAssertEqual(run(["\n<think>x</think>\n\nAnswer"]).text, "\nAnswer")
    }

    func testWhitespaceAfterABlockInsideTextIsKept() {
        XCTAssertEqual(run(["First.<think>x</think>\n\nSecond."]).text, "First.\n\nSecond.")
    }

    func testEmptyBlockOfDisabledThinkingIsRemoved() {
        XCTAssertEqual(run(["<think>\n\n</think>\n\nHello"]).text, "Hello")
    }

    func testAngleBracketThatIsNotATagIsReleasedLate() {
        let result = run(["a <", " b"])
        XCTAssertEqual(result.steps, ["a ", "< b", ""])
        XCTAssertEqual(run(["x <thin air"]).text, "x <thin air")
        XCTAssertEqual(run(["1 </ 2"]).text, "1 </ 2")
    }

    func testHeldTailIsReleasedByFinish() {
        var filter = ThinkBlockFilter()
        XCTAssertEqual(filter.consume("ends with <thi"), "ends with ")
        XCTAssertEqual(filter.finish(), "<thi")
    }

    func testTagMatchingIsCaseSensitiveAndExact() {
        XCTAssertEqual(run(["<Think>kept</Think>"]).text, "<Think>kept</Think>")
        XCTAssertEqual(run(["<thinking>kept</thinking>"]).text, "<thinking>kept</thinking>")
    }

    func testIsInsideBlockTracksTheState() {
        var filter = ThinkBlockFilter()
        XCTAssertFalse(filter.isInsideBlock)
        _ = filter.consume("a<think>b")
        XCTAssertTrue(filter.isInsideBlock)
        _ = filter.consume("</think>")
        XCTAssertFalse(filter.isInsideBlock)
    }

    func testFinishResetsTheFilter() {
        var filter = ThinkBlockFilter()
        _ = filter.consume("<think>open")
        XCTAssertEqual(filter.finish(), "")
        XCTAssertFalse(filter.isInsideBlock)
        XCTAssertEqual(filter.consume("fresh"), "fresh")
        XCTAssertEqual(filter, { var expected = ThinkBlockFilter(); _ = expected.consume("fresh"); return expected }())
    }

    func testCustomTags() {
        let filter = ThinkBlockFilter(openTag: "[[", closeTag: "]]")
        XCTAssertEqual(run(["a[", "[hidden]", "]b"], filter: filter).text, "ab")
    }

    func testNonASCIITextAroundBlocks() {
        XCTAssertEqual(run(["Città <think>🤔 perché</think>è 🇮🇹 bella"]).text, "Città è 🇮🇹 bella")
        for pieces in splits(of: "é<think>ü</think>ñ") {
            XCTAssertEqual(run(pieces).text, "éñ", "pieces: \(pieces)")
        }
    }

    func testRandomSplitsNeverChangeTheResult() {
        let text = "Intro <think>step one\nstep <two> </thin k>\nstep three</think>\n\nBody with <b>markup</b> and a < sign.<think>tail"
        let expected = "Intro \n\nBody with <b>markup</b> and a < sign."
        var generator = SystemRandomNumberGenerator()
        let characters = Array(text)
        for _ in 0 ..< 500 {
            var pieces: [String] = []
            var index = 0
            while index < characters.count {
                let length = Int.random(in: 1 ... 7, using: &generator)
                let end = min(characters.count, index + length)
                pieces.append(String(characters[index ..< end]))
                index = end
            }
            XCTAssertEqual(run(pieces).text, expected, "pieces: \(pieces)")
        }
    }
}
