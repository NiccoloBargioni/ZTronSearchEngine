import Hub
import XCTest
@testable import ZTronSearchEngineMLX

/// `JSONConfig` replaces the tokenizer library's own JSON conversion on the load path, so it has
/// to produce the same tree.
final class JSONConfigTests: XCTestCase {
    private func make(_ json: String) throws -> Config {
        JSONConfig.make(try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
    }

    func testScalarsKeepTheirTypes() throws {
        let config = try make(#"{"s": "text", "i": 42, "neg": -7, "f": 1.5, "t": true, "no": false, "n": null, "empty": ""}"#)
        XCTAssertEqual(config["s"].string(), "text")
        XCTAssertEqual(config["i"].integer(), 42)
        XCTAssertEqual(config["neg"].integer(), -7)
        XCTAssertEqual(config["f"].floating(), 1.5)
        XCTAssertNil(config["f"].integer())
        XCTAssertEqual(config["t"].boolean(), true)
        XCTAssertEqual(config["no"].boolean(), false)
        XCTAssertNil(config["t"].integer(), "a JSON boolean is not an integer")
        XCTAssertTrue(config["n"].isNull())
        XCTAssertEqual(config["empty"].string(), "")
        XCTAssertTrue(config["absent"].isNull())
    }

    func testContainersNest() throws {
        let config = try make(#"{"list": [1, "two", false, null, [3, 4]], "object": {"inner": {"key": "value"}}, "none": [], "blank": {}}"#)
        let list = try XCTUnwrap(config["list"].array())
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list[0].integer(), 1)
        XCTAssertEqual(list[1].string(), "two")
        XCTAssertEqual(list[2].boolean(), false)
        XCTAssertTrue(list[3].isNull())
        XCTAssertEqual(list[4].array()?.compactMap { $0.integer() }, [3, 4])
        XCTAssertEqual(config["object"]["inner"]["key"].string(), "value")
        XCTAssertEqual(config["none"].array()?.count, 0)
        XCTAssertEqual(config["blank"].dictionary()?.count, 0)
    }

    func testTopLevelFragments() throws {
        XCTAssertEqual(try make("\"alone\"").string(), "alone")
        XCTAssertEqual(try make("7").integer(), 7)
        XCTAssertTrue(try make("null").isNull())
    }

    func testKeysThatDifferOnlyByNormalizationStayDistinct() throws {
        // U+00E9 and "e" followed by U+0301 are the same character to `String`, and two vocabulary
        // entries to a tokenizer.
        let config = try make(#"{"\u00e9": 1, "e\u0301": 2}"#)
        let entries = try XCTUnwrap(config.dictionary())
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[BinaryDistinctString([0x00E9])]?.integer(), 1)
        XCTAssertEqual(entries[BinaryDistinctString([0x0065, 0x0301])]?.integer(), 2)
    }

    func testStringsKeepTheirCodeUnits() throws {
        let config = try make(#"{"emoji": "😀", "cjk": "你好", "escaped": "a\u0000b\n"}"#)
        XCTAssertEqual(config["emoji"].string(), "😀")
        XCTAssertEqual(config["emoji"].binaryDistinctString()?.value, Array("😀".utf16))
        XCTAssertEqual(config["cjk"].string(), "你好")
        XCTAssertEqual(config["escaped"].binaryDistinctString()?.value, [0x61, 0x00, 0x62, 0x0A])
    }

    func testAgreesWithTheLibrarysOwnDecoder() throws {
        // No `[number, string]` pair and no `1.0` here: the library's `Codable` path reads the
        // first as a token tuple and the second as an integer, which is its business alone.
        let json = #"""
            {
              "version": "1.0",
              "added_tokens": [{"id": 0, "content": "<|endoftext|>", "special": true, "lstrip": false}],
              "normalizer": null,
              "model": {"type": "BPE", "dropout": 0.25, "vocab": {"a": 0, "b": 1, "ab": 2, "Ġ": 3}, "merges": [["a", "b"]]}
            }
            """#
        let mine = try make(json)
        let theirs = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(mine, theirs)
    }
}
