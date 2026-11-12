// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Bilgisayar ekranındaki pencere TV uygulamasıyla (tv-webos/app.js) aynı satırları aynı sürelerle göstermeli.
final class SubtitleStackTests: XCTestCase {
    private func texts(_ stack: SubtitleStack, at now: TimeInterval) -> [String] { stack.lines(at: now).map(\.text) }

    func testLineStaysForGivenDuration() {
        var stack = SubtitleStack()
        stack.show("Kapıyı aç.", durationMs: 4000, now: 0)
        XCTAssertEqual(texts(stack, at: 3.9), ["Kapıyı aç."])
        XCTAssertTrue(stack.isEmpty(at: 4))
    }

    func testVeryShortDurationStillShowsMinimumTime() {
        var stack = SubtitleStack()
        stack.show("Evet.", durationMs: 100, now: 0)
        XCTAssertFalse(stack.isEmpty(at: 1.1))
        XCTAssertTrue(stack.isEmpty(at: 1.2))
    }

    func testMissingDurationComesFromLength() {
        var stack = SubtitleStack()
        stack.show("Evet.", durationMs: 0, now: 0)
        // 2 sn + 5 harf × 60 ms
        XCTAssertFalse(stack.isEmpty(at: 2.29))
        XCTAssertTrue(stack.isEmpty(at: 2.31))
    }

    func testFastSpeechStacksUpToThreeLines() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 8000, now: 0)
        stack.show("İkinci", durationMs: 8000, now: 0.5)
        stack.show("Üçüncü", durationMs: 8000, now: 1)
        let lines = stack.lines(at: 1)
        XCTAssertEqual(lines.map(\.text), ["Birinci", "İkinci", "Üçüncü"])
        XCTAssertEqual(lines.map(\.role), [.older, .previous, .current])
        // Dördüncü satır en eskiyi düşürür.
        stack.show("Dördüncü", durationMs: 8000, now: 1.5)
        XCTAssertEqual(texts(stack, at: 1.5), ["İkinci", "Üçüncü", "Dördüncü"])
    }

    func testSlowSpeechReplacesTheLine() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 8000, now: 0)
        stack.show("İkinci", durationMs: 8000, now: 2)
        XCTAssertEqual(texts(stack, at: 2), ["İkinci"])
    }

    func testPreviousLineFadesThenGoes() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 8000, now: 0)
        stack.show("İkinci", durationMs: 8000, now: 1)
        XCTAssertEqual(stack.lines(at: 2.4).first?.fading, false)
        XCTAssertEqual(stack.lines(at: 2.6).first?.fading, true)
        XCTAssertEqual(texts(stack, at: 2.9), ["İkinci"])
        XCTAssertEqual(stack.nextChange(after: 1), 2.5)
        XCTAssertEqual(stack.nextChange(after: 2.5), 2.9)
        XCTAssertEqual(stack.nextChange(after: 2.9), 9)
    }

    func testSameSentenceReadAgainDoesNotStack() {
        var stack = SubtitleStack()
        stack.show("Kapı", durationMs: 8000, now: 0)
        stack.show("Kapı daha fazla açılmıyor.", durationMs: 8000, now: 0.5)
        XCTAssertEqual(texts(stack, at: 0.5), ["Kapı daha fazla açılmıyor."])
    }

    /// Bilgisayar "yerine koy" dediyse (aynı cümlenin uzamış okuması) önceki çeviri üste çıkmaz; Türkçeleri birbirini
    /// içermese de. Üstteki daha eski satır yerinde kalır.
    func testRevisedLineReplacesInsteadOfStacking() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 8000, now: 0)
        stack.show("Vaktimiz yok", durationMs: 8000, now: 0.5)
        stack.show("Bunun için vaktimiz yok, evlat.", durationMs: 8000, replaces: true, now: 0.8)
        XCTAssertEqual(texts(stack, at: 0.8), ["Birinci", "Bunun için vaktimiz yok, evlat."])
        XCTAssertEqual(stack.lines(at: 0.8).map(\.role), [.previous, .current])
    }

    func testParagraphsNeverStack() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 8000, now: 0)
        stack.show("GÖREV\n• Kapıyı bul", durationMs: 8000, paragraphs: true, now: 0.5)
        XCTAssertEqual(texts(stack, at: 0.5), ["GÖREV\n• Kapıyı bul"])
        XCTAssertEqual(stack.lines(at: 0.5).first?.paragraphs, true)
    }

    /// "Temizle" satırı okunacak kadar görünmeden kaldırmaz.
    func testClearWaitsForReadingTime() {
        var stack = SubtitleStack()
        stack.show("Kapıyı aç.", durationMs: 15000, now: 0)
        stack.clear(now: 1)
        // 2 sn + 10 harf × 60 ms = 2,6 sn
        XCTAssertFalse(stack.isEmpty(at: 2.5))
        XCTAssertTrue(stack.isEmpty(at: 2.61))
    }

    func testClearAfterReadingTimeHidesAtOnce() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 15000, now: 0)
        stack.show("İkinci", durationMs: 15000, now: 1)
        stack.clear(now: 4)
        XCTAssertTrue(stack.isEmpty(at: 4))
        XCTAssertNil(stack.nextChange(after: 4))
    }

    func testHideRemovesEverything() {
        var stack = SubtitleStack()
        stack.show("Birinci", durationMs: 8000, now: 0)
        stack.show("İkinci", durationMs: 8000, now: 0.5)
        stack.hide()
        XCTAssertTrue(stack.isEmpty(at: 0.5))
    }

    func testSameLineIgnoresCaseAndPunctuation() {
        XCTAssertTrue(SubtitleStack.sameLine("Kapıyı aç!", "kapıyı aç."))
        XCTAssertTrue(SubtitleStack.sameLine("Kapı", "Kapı daha fazla…"))
        XCTAssertFalse(SubtitleStack.sameLine("Evet", "Hayır"))
    }
}
