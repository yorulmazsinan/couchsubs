// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class LineMetricsTests: XCTestCase {
    func testMeasuresEachStageFromTheSameClock() {
        let metrics = LineMetrics.measure(capturedAt: 1000, ocrMs: 42, translation: (1100, 1410), sentAt: 1520,
                                          confidence: 0.934, origin: .engine)
        XCTAssertEqual(metrics, LineMetrics(ocrMs: 42, translationMs: 310, totalMs: 520, confidence: 93, origin: .engine))
    }

    func testPackLineHasNoTranslationTime() {
        let metrics = LineMetrics.measure(capturedAt: 1000, ocrMs: 30, translation: nil, sentAt: 1045, confidence: nil, origin: .pack)
        XCTAssertNil(metrics.translationMs)
        XCTAssertNil(metrics.confidence)
        XCTAssertEqual(metrics.totalMs, 45)
    }

    func testNegativeDurationsAndOutOfRangeConfidenceAreClamped() {
        let metrics = LineMetrics.measure(capturedAt: 2000, ocrMs: -5, translation: (10, 5), sentAt: 1500, confidence: 1.7, origin: .engine)
        XCTAssertEqual(metrics.ocrMs, 0)
        XCTAssertEqual(metrics.translationMs, 0)
        XCTAssertEqual(metrics.totalMs, 0)
        XCTAssertEqual(metrics.confidence, 100)
    }

    func testSummaryListsOnlyKnownValuesInOrder() {
        let engine = LineMetrics(ocrMs: 40, translationMs: 300, totalMs: 520, confidence: 91, origin: .engine)
        XCTAssertEqual(engine.summary, "OCR 40 ms · Translation 300 ms · Delay 520 ms · Confidence 91%")
        let pack = LineMetrics(ocrMs: nil, translationMs: nil, totalMs: 60, confidence: nil, origin: .pack)
        XCTAssertEqual(pack.summary, "Ready pack · Delay 60 ms")
    }

    func testReadingConfidenceIsTheAverageOfKnownLines() {
        let reading = Reading(lines: [TextLine("Stay close", confidence: 0.8), TextLine("boy.", confidence: 1.0), TextLine("hm")])
        XCTAssertEqual(reading.confidence ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertNil(Reading(text: "No confidence").confidence)
        // Ayıklamalar güveni korur.
        XCTAssertEqual(reading.withoutOcrNoise().confidence ?? 0, 0.9, accuracy: 0.0001)
    }
}
