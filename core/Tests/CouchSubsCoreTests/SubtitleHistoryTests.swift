// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SubtitleHistoryTests: XCTestCase {
    func testNewestComesFirst() {
        var history = SubtitleHistory()
        history.add(source: "Stay close, boy.", translation: "Yakın dur, evlat.")
        history.add(source: "The gate will not hold.", translation: "Kapı dayanmayacak.")
        XCTAssertEqual(history.entries.map(\.translation), ["Kapı dayanmayacak.", "Yakın dur, evlat."])
    }

    func testRereadOfSameLineUpdatesInsteadOfAdding() {
        var history = SubtitleHistory()
        history.add(source: "The gate will not hold.", translation: "Kapı dayanmayacak.")
        history.add(source: "The gale will not hold.", translation: "Kapı tutmayacak.")
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].translation, "Kapı tutmayacak.")
    }

    func testEmptyTranslationIsIgnored() {
        var history = SubtitleHistory()
        history.add(source: "...", translation: "  ")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testOldestDropsPastLimit() {
        var history = SubtitleHistory(limit: 2)
        history.add(source: "One line here", translation: "Bir")
        history.add(source: "Second different sentence", translation: "İki")
        history.add(source: "Third unrelated words", translation: "Üç")
        XCTAssertEqual(history.entries.map(\.translation), ["Üç", "İki"])
        XCTAssertEqual(Set(history.entries.map(\.id)).count, 2)
    }

    func testDefaultKeepsTwoHundredLines() {
        var history = SubtitleHistory()
        for index in 0..<250 { history.add(source: UUID().uuidString, translation: "Satır \(index)") }
        XCTAssertEqual(history.entries.count, 200)
        XCTAssertEqual(history.entries.first?.translation, "Satır 249")
    }

    func testRecordsTimeAndOrigin() {
        var history = SubtitleHistory()
        let date = Date(timeIntervalSince1970: 1_000)
        history.add(source: "Get down!", translation: "Yere yat!", origin: .pack, date: date)
        XCTAssertEqual(history.entries[0].origin, .pack)
        XCTAssertEqual(history.entries[0].date, date)
    }

    func testLongTextIsClipped() {
        var history = SubtitleHistory()
        history.add(source: String(repeating: "a", count: 2000), translation: String(repeating: "b", count: 2000))
        XCTAssertEqual(history.entries[0].source.count, SubtitleHistory.maxTextLength)
        XCTAssertEqual(history.entries[0].translation.count, SubtitleHistory.maxTextLength)
    }

    func testEntriesSinceSessionStart() {
        var history = SubtitleHistory()
        history.add(source: "Earlier session line", translation: "Eski", date: Date(timeIntervalSince1970: 100))
        history.add(source: "This session line now", translation: "Yeni", date: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(history.entries(since: Date(timeIntervalSince1970: 200)).map(\.translation), ["Yeni"])
    }

    func testSavesAndLoadsAcrossSessions() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var history = SubtitleHistory()
        history.add(source: "Stay close, boy.", translation: "Yakın dur, evlat.", origin: .engine, date: Date(timeIntervalSince1970: 1_700_000_000))
        history.add(source: "Get down!", translation: "Yere yat!", origin: .pack, date: Date(timeIntervalSince1970: 1_700_000_005))
        try history.save(to: file)

        var loaded = SubtitleHistory.load(from: file)
        XCTAssertEqual(loaded.entries, history.entries)
        // Yeni satırın kimliği eskilerle çakışmaz.
        loaded.add(source: "The gate will not hold.", translation: "Kapı dayanmayacak.")
        XCTAssertEqual(Set(loaded.entries.map(\.id)).count, 3)

        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"origin\":\"pack\""), json)
        XCTAssertTrue(json.contains("2023-11-14T22:13:25Z"), json)
    }

    func testMissingOrDamagedFileGivesEmptyHistory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertTrue(SubtitleHistory.load(from: file).entries.isEmpty)
        try Data("not json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(SubtitleHistory.load(from: file).entries.isEmpty)
    }

    func testClearEmptiesTheList() {
        var history = SubtitleHistory()
        history.add(source: "Stay close, boy.", translation: "Yakın dur, evlat.")
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPlainTextForCopying() {
        var history = SubtitleHistory()
        history.add(source: "Stay close, boy.", translation: "Yakın dur, evlat.", date: Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(SubtitleHistory.plainText(history.entries, timeZone: TimeZone(identifier: "UTC")!),
                       "[01:00:00] Yakın dur, evlat.\nStay close, boy.")
    }
}
