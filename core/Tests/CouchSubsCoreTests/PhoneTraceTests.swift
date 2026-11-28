// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// #1251: telefon ekranda görünürken otomatik okumadan hiç satır gelmiyordu ve günlük de sessizdi. Telefonun açılıp kapanması,
/// oynadığı için açılmaması, turun atlanması ve eğik ekranın boş okunması artık sınırlı satırlarla günlüğe yazılır (Windows ve
/// Android ile aynı metinler).
@MainActor
final class PhoneTraceTests: XCTestCase {
    private final class Reader: TextReader, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [TextLine] = []
        private var reads = 0
        var count: Int { lock.withLock { reads } }
        func set(_ lines: [TextLine]) { lock.withLock { self.lines = lines } }
        func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
            lock.withLock {
                reads += 1
                return Reading(lines: lines)
            }
        }
    }

    private struct Translator: TextTranslator {
        func translate(_ text: String) async throws -> String { "Çevrildi: " + text }
    }

    private final class Server: RegionSending {
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {}
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?,
                        icons: [IconPlacement]?, blocks: [ScreenTranslation.Item]?) {}
        func clearRegions() {}
    }

    private struct TimedOut: Error {}

    private func wait(_ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !done() {
            if Date() >= deadline { throw TimedOut() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// #1334: telefon indirilince çevirisi süreyle (~1 sn) kalkar; örnekler seyrek gelse de ıska sayısı beklenmez. Tek
    /// karelik ıska kapatmaz.
    func testClosedPhoneLeavesWithinASecondEvenWhenSamplesAreSparse() {
        let image = GamePhoneTestFrame.phone()
        var found = true
        let pose = GamePhoneGeometry.Pose(topX: 0.45, topY: 0.15, bottomX: 0.45, bottomY: 0.83)
        func tracker() -> GamePhoneTracker { GamePhoneTracker(locate: { _ in found ? pose : nil }) }

        // Olağan aralık (330 ms): üçüncü ıskada, son görülmeden ~1 sn sonra kapanır (önceden dördüncüde, ~1,3 sn).
        var regular = tracker()
        found = true
        XCTAssertNil(regular.sample(image, now: 0).pose)
        XCTAssertNotNil(regular.sample(image, now: 330).pose)
        found = false
        XCTAssertNotNil(regular.sample(image, now: 660).pose)
        XCTAssertNotNil(regular.sample(image, now: 990).pose)
        XCTAssertNil(regular.sample(image, now: 1320).pose)

        // Seyrek örnekler (1 sn arayla): tek ıska kapatmaz, ikinci ıskada kapanır (önceden dördüncüde, ~4 sn).
        regular = tracker()
        found = true
        _ = regular.sample(image, now: 0)
        XCTAssertNotNil(regular.sample(image, now: 1000).pose)
        found = false
        XCTAssertNotNil(regular.sample(image, now: 2000).pose)
        found = true
        XCTAssertNotNil(regular.sample(image, now: 3000).pose)
        found = false
        XCTAssertNotNil(regular.sample(image, now: 4000).pose)
        XCTAssertNil(regular.sample(image, now: 5000).pose)

        // Akış takıldı, telefon iki kat süre hiç görülmedi: tek ıska yeter.
        regular = tracker()
        found = true
        _ = regular.sample(image, now: 0)
        XCTAssertNotNil(regular.sample(image, now: 330).pose)
        found = false
        XCTAssertNil(regular.sample(image, now: 330 + 2 * GamePhoneTracker.missGraceMs).pose)

        XCTAssertFalse(GamePhoneTracker.closes(misses: 1, unseenMs: 1200))
        XCTAssertTrue(GamePhoneTracker.closes(misses: 4, unseenMs: 0))
    }

    func testTrackerLogsOpeningClosingAndAMovingPhoneOncePerMinute() {
        var log: [String] = []
        var top = 0.15
        var found = true
        let image = GamePhoneTestFrame.phone()
        let tracker = GamePhoneTracker(locate: { _ in
            found ? GamePhoneGeometry.Pose(topX: 0.45, topY: top, bottomX: 0.45, bottomY: top + 0.68) : nil
        })
        tracker.onLog = { if !$0.contains("telefon arama durumu") { log.append($0) } } // 30 sn durum satırı ayrı (PhoneSearchStatusTests)
        var time = 0
        func sample() { time += 400; _ = tracker.sample(image, now: time) }

        sample()
        sample()
        XCTAssertEqual(log, ["düşen satır [PhoneTrace] telefon açıldı: \"\""])
        found = false
        for _ in 0..<3 { sample() }
        XCTAssertEqual(log.last, "düşen satır [PhoneTrace] telefon kapandı (1200 ms görülmedi, 3 ıska): \"\"")

        // Elde sallanan telefon: her örnekte %10 kayıyor, iki uyumlu gözlem olmadığı için hiç açılmıyor.
        log = []
        found = true
        for _ in 0..<6 {
            top = top == 0.15 ? 0.25 : 0.15
            sample()
        }
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(log[0].hasPrefix("düşen satır [PhoneTrace] telefon oynuyor, açılmadı (%10 oynama)"), log[0])
        time += DropLog.repeatMs
        top = top == 0.15 ? 0.25 : 0.15
        sample()
        XCTAssertEqual(log.count, 2)
    }

    func testShiftIsTheLargestEdgeMove() {
        XCTAssertEqual(PhoneTrace.shift(CropRegion(top: 0.1, bottom: 0.8, left: 0.3, right: 0.6),
                                        CropRegion(top: 0.12, bottom: 0.8, left: 0.37, right: 0.6)), 0.07, accuracy: 1e-9)
        XCTAssertEqual(PhoneTrace.percent(0.07), 7)
    }

    private func turns(_ frame: CGImage, pose: GamePhoneGeometry.Pose, reader: Reader, count: Int,
                       step: Int = 1000) async throws -> [String] {
        var log: [String] = []
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: Server(), clock: { clock })
        watcher.onLog = { log.append($0) }
        for _ in 0..<count {
            clock += step
            watcher.offer(frame, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
        }
        return log
    }

    func testTurnSkippedBecauseThePhoneMovedIsLogged() async throws {
        let frame = GamePhoneTestFrame.phone()
        let found = try XCTUnwrap(GamePhoneGeometry.locate(frame))
        let moved = GamePhoneGeometry.Pose(topX: found.topX, topY: found.topY + 0.1, bottomX: found.bottomX,
                                           bottomY: found.bottomY + 0.1)
        let reader = Reader()
        reader.set([TextLine("Where are you man", box: TextBox(left: 0.15, top: 0.30, right: 0.85, bottom: 0.48))])
        let log = try await turns(frame, pose: moved, reader: reader, count: 3)
        XCTAssertEqual(log.count, 1)
        XCTAssertTrue(log[0].hasPrefix("düşen satır [PhoneTrace] telefon karede yerinde değil, tur atlandı (%"), log[0])
        XCTAssertEqual(reader.count, 0)
    }

    func testTurnSkippedBecauseThePhoneIsGoneIsLoggedOncePerMinute() async throws {
        let frame = GamePhoneTestFrame.phone()
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(frame))
        let log = try await turns(GamePhoneTestFrame.gone(), pose: pose, reader: Reader(), count: 4, step: 20_000)
        XCTAssertEqual(log, Array(repeating: "düşen satır [PhoneTrace] PhoneMissing: telefon bu karede bulunamadı, tur atlandı: \"Phone\"",
                                  count: 2))
    }

    func testEmptyStraightenedPhoneReadingIsLogged() async throws {
        let frame = GamePhoneTestFrame.phone()
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(frame))
        let reader = Reader()
        let log = try await turns(frame, pose: pose, reader: reader, count: 2)
        XCTAssertGreaterThan(reader.count, 0)
        XCTAssertTrue(log.contains("düşen satır [PhoneTrace] eğik ekran düzeltilmiş okuması boş: \"Phone\""), "\(log)")
    }
}
