import XCTest
import ZTronSearchEngine
@testable import ZTronSearchFixtures

final class RelevanceMetricsTests: XCTestCase {
    private let judgments: [SearchableID: Int] = ["a": 3, "c": 1, "d": 2]

    func testDiscountedCumulativeGain() {
        // Gains 2^g - 1 are 7, 0, 1 at ranks 1, 2, 3; discounts log2(2), log2(3), log2(4).
        XCTAssertEqual(RelevanceMetrics.dcg(["a", "b", "c"], judgments: judgments, at: 10), 7 + 0 + 1 / 2.0, accuracy: 1e-12)
        // Ideal order is a (7), d (3), c (1): 7 + 3 / log2(3) + 1 / 2.
        let ideal = 7 + 3 / log2(3.0) + 0.5
        XCTAssertEqual(ideal, 9.392789260714372, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.idealDCG(judgments: judgments, at: 10), ideal, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.ndcg(["a", "b", "c"], judgments: judgments, at: 10), 7.5 / ideal, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.ndcg(["a", "b", "c"], judgments: judgments, at: 10), 0.7984848580, accuracy: 1e-9)
    }

    func testNormalizedGainAtACutoff() {
        // Cut at 2: only a counts; the ideal at 2 is a then d.
        let idealAtTwo = 7 + 3 / log2(3.0)
        XCTAssertEqual(RelevanceMetrics.ndcg(["a", "b", "c"], judgments: judgments, at: 2), 7 / idealAtTwo, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.ndcg(["a", "d", "c"], judgments: judgments, at: 10), 1, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.ndcg(["d", "a", "c"], judgments: judgments, at: 10), (3 + 7 / log2(3.0) + 0.5) / (7 + 3 / log2(3.0) + 0.5), accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.ndcg(["x", "y"], judgments: judgments, at: 10), 0)
        XCTAssertEqual(RelevanceMetrics.ndcg([], judgments: judgments, at: 10), 0)
        XCTAssertEqual(RelevanceMetrics.ndcg(["a"], judgments: [:], at: 10), 0, "nothing relevant: zero, not a division by zero")
        XCTAssertEqual(RelevanceMetrics.ndcg(["a"], judgments: judgments, at: 0), 0)
        // A repeated id earns its gain once.
        XCTAssertEqual(RelevanceMetrics.dcg(["a", "a", "a"], judgments: judgments, at: 10), 7, accuracy: 1e-12)
        // Grades 1, 2, 3 gain 1, 3, 7.
        XCTAssertEqual(RelevanceMetrics.dcg(["c"], judgments: judgments, at: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.dcg(["d"], judgments: judgments, at: 1), 3, accuracy: 1e-12)
    }

    func testReciprocalRank() {
        XCTAssertEqual(RelevanceMetrics.reciprocalRank(["a", "b"], judgments: judgments, at: 10), 1)
        XCTAssertEqual(RelevanceMetrics.reciprocalRank(["x", "y", "c", "a"], judgments: judgments, at: 10), 1 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.reciprocalRank(["x", "y", "c"], judgments: judgments, at: 2), 0, "the first relevant result is past the cutoff")
        XCTAssertEqual(RelevanceMetrics.reciprocalRank([], judgments: judgments, at: 10), 0)
        // MRR over two queries: (1 + 1/4) / 2.
        let mean = RelevanceMetrics.mean([
            RelevanceMetrics.reciprocalRank(["a"], judgments: judgments, at: 10),
            RelevanceMetrics.reciprocalRank(["x", "y", "z", "d"], judgments: judgments, at: 10),
        ])
        XCTAssertEqual(mean, 0.625, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.mean([]), 0)
    }

    func testRecall() {
        XCTAssertEqual(RelevanceMetrics.recall(["a", "x", "d"], judgments: judgments, at: 10), 2 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.recall(["a", "x", "d"], judgments: judgments, at: 2), 1 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.recall(["c", "d", "a"], judgments: judgments, at: 10), 1)
        XCTAssertEqual(RelevanceMetrics.recall(["a", "a", "a"], judgments: judgments, at: 10), 1 / 3.0, accuracy: 1e-12, "a repeated id is found once")
        XCTAssertEqual(RelevanceMetrics.recall(["x"], judgments: judgments, at: 10), 0)
        XCTAssertEqual(RelevanceMetrics.recall(["a"], judgments: [:], at: 10), 0)
        // Twelve relevant items, ten slots: at best 10 / 12.
        var many: [SearchableID: Int] = [:]
        for index in 0..<12 { many[SearchableID("r\(index)")] = 2 }
        let ranked = (0..<12).map { SearchableID("r\($0)") }
        XCTAssertEqual(RelevanceMetrics.recall(ranked, judgments: many, at: 10), 10 / 12.0, accuracy: 1e-12)
    }

    func testRankOne() {
        XCTAssertTrue(RelevanceMetrics.isRankOne(["a", "d"], judgments: judgments, minimumGrade: 3))
        XCTAssertTrue(RelevanceMetrics.isRankOne(["a", "d"], judgments: judgments), "the default asks for grade 3")
        XCTAssertFalse(RelevanceMetrics.isRankOne(["d", "a"], judgments: judgments, minimumGrade: 3))
        XCTAssertTrue(RelevanceMetrics.isRankOne(["d", "a"], judgments: judgments, minimumGrade: 2))
        XCTAssertFalse(RelevanceMetrics.isRankOne(["x", "a"], judgments: judgments, minimumGrade: 1))
        XCTAssertFalse(RelevanceMetrics.isRankOne([], judgments: judgments, minimumGrade: 1))
    }

    func testPrecision() {
        XCTAssertEqual(RelevanceMetrics.precision(["a", "b", "c", "d"], allowed: ["a", "c", "d"]), 0.75, accuracy: 1e-12)
        XCTAssertEqual(RelevanceMetrics.precision(["a", "c"], allowed: ["a", "c", "d"]), 1)
        XCTAssertEqual(RelevanceMetrics.precision(["x"], allowed: ["a"]), 0)
        XCTAssertEqual(RelevanceMetrics.precision([], allowed: ["a"]), 1, "no hit violates anything")
        XCTAssertEqual(RelevanceMetrics.precision(["a"], allowed: []), 0)
    }
}
