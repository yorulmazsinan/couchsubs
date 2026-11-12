// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Sunucunun yerine geçen sahte HTTP: gelen istekleri saklar, sıradaki yanıtı döner.
private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    /// Durum kodu ve başlıklar; nil: sunucuya ulaşılamadı.
    var replies: [(Int, [String: String])?] = []
    var fallback: (Int, [String: String])? = (200, [:])

    var received: [URLRequest] { lock.withLock { requests } }

    /// Gönderilen satır parçaları.
    var batches: [[[String: Any]]] {
        received.map { request in
            let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return body["lines"] as! [[String: Any]]
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: (Int, [String: String])? = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? fallback : replies.removeFirst()
        }
        guard let (status, headers) = reply else { throw URLError(.cannotConnectToHost) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

private final class PoolClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_793_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

final class LinePoolTests: XCTestCase {
    private var file: URL!
    private let server = FakeServer()
    private let clock = PoolClock()

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)").appendingPathComponent("pool.json")
    }

    private func makePool(enabled: Bool = true) -> LinePool {
        let server = self.server
        let clock = self.clock
        return LinePool(file: file, endpoint: URL(string: "https://example.test/v1/lines")!, app: "1.2.3", platform: "mac",
                        enabled: enabled, send: { try await server.send($0) }, clock: { clock.now })
    }

    func testDisabledPoolSendsNothing() async {
        XCTAssertTrue(LinePool.enabledByDefault)
        let pool = makePool(enabled: false)
        await pool.offer("Don Torrisi wants you.")
        await pool.flush()
        let queued = await pool.queued
        XCTAssertEqual(queued, [])
        XCTAssertEqual(server.received.count, 0)
    }

    func testLinesAreDeduplicatedByKey() async {
        let pool = makePool()
        await pool.offer("  Don Torrisi wants you.  ")
        await pool.offer("DON TORRISI WANTS YOU!")
        await pool.offer("Who is that over there?")
        let queued = await pool.queued
        XCTAssertEqual(queued.map(\.text), ["Don Torrisi wants you.", "Who is that over there?"])
        XCTAssertEqual(queued.first?.key, PackKey.key("Don Torrisi wants you."))
        XCTAssertEqual(queued.first?.firstSeen, "2026-10-26T07:33:20Z")
    }

    func testFiltersSkipShortLongAndNoisyLines() {
        XCTAssertTrue(LinePool.accepts("Get down!"))
        XCTAssertFalse(LinePool.accepts("Okay."))
        XCTAssertFalse(LinePool.accepts("..."))
        XCTAssertFalse(LinePool.accepts(String(repeating: "word ", count: 61)))
        XCTAssertFalse(LinePool.accepts("We need ou$3e now"))
        XCTAssertFalse(LinePool.accepts("HP 100/100 MP 25/50"))
        XCTAssertTrue(LinePool.accepts("Give me 50 dollars, Enzo."))
    }

    /// Havuzda en çok görülen "satırlar" PS5'in Türkçe arayüzü ve onun yazı tanıma bozmalarıydı; İngilizce oyun satırı değiller.
    func testRejectsTurkishAndSystemText() {
        for line in ["Oturum Açtı", "Oturum Aqtl", "Sifirlama Seqenekleri", "PS5 Sistemini Yeniden Baslat", "Oyunu Kapat",
                     "Ana Ekranda Tut", "Lütfen bekleyin..", "Ekran ve Video", "ilerlemenizi takip edin Kupalar",
                     "Keşfet PS5 ile ilgili Öne Çıkanlar", "Ekran görüntüsü kaydedildi.", "Kupa kazandınız!",
                     "Oturum Aqtl.", "Sifirlama Seqenekleri.", "PS5 Sistemini Yeniden Baslat.",
                     "John signed in.", "You've earned a trophy!",
                     "Please do not quit or turn off your console while the Rockstar cloud save icon is showing."] {
            XCTAssertFalse(LinePool.accepts(line), line)
        }
        // Yabancı addaki tek ü/ö/ç ve "designed in" gibi sözcük içi eşleşmeler İngilizce satırı düşürmez.
        for line in ["Herr Müller will see you now.", "This place was designed in a hurry.", "Tell Sam I signed the deal.",
                     "I lie to you, you lie to me.", "Don Torrisi wants you.", "DON TORRISI WANTS YOU!"] {
            XCTAssertTrue(LinePool.accepts(line), line)
        }
    }

    /// Yarım okumalar ve kısa arayüz yazıları havuza gitmez; noktalamayla biten kısa satır gider.
    func testRejectsFragmentsAndShortLines() {
        for line in ["GO to the", "Take out the trash and the", "it Auto V's Story Mode.", "FREE MONTH OF GTA+",
                     "PHOTO MODE SELECT", "Main menu", "Hold on"] {
            XCTAssertFalse(LinePool.accepts(line), line)
        }
        for line in ["Get down!", "Who's there?", "Line number 7 here", "We need to move before the cops show up"] {
            XCTAssertTrue(LinePool.accepts(line), line)
        }
    }

    func testBatchesAreAtMostTwoHundredLines() async throws {
        let pool = makePool()
        for index in 0..<450 { await pool.offer("This is line number \(index) of the test") }
        await pool.flush()
        XCTAssertEqual(server.batches.map(\.count), [200, 200, 50])
        let queued = await pool.queued
        XCTAssertEqual(queued, [])
        let body = try JSONSerialization.jsonObject(with: server.received[0].httpBody!) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["install", "app", "platform", "lines"])
        XCTAssertEqual(body["app"] as? String, "1.2.3")
        XCTAssertEqual(body["platform"] as? String, "mac")
        XCTAssertNotNil(UUID(uuidString: body["install"] as! String))
        XCTAssertEqual(Set(server.batches[0][0].keys), ["text", "key", "firstSeen"])
        XCTAssertEqual(server.received[0].httpMethod, "POST")
        // Gönderilen satır yeniden kuyruğa girmez.
        await pool.offer("This is line number 3 of the test")
        let again = await pool.queued
        XCTAssertEqual(again, [])
    }

    func testQueueSurvivesRestartAndUnreachableServer() async {
        server.fallback = nil
        let pool = makePool()
        await pool.offer("Don Torrisi wants you.")
        await pool.flush()
        let install = await pool.installID
        XCTAssertEqual(server.received.count, 1)

        let reopened = makePool()
        let queued = await reopened.queued
        XCTAssertEqual(queued.map(\.text), ["Don Torrisi wants you."])
        let sameInstall = await reopened.installID
        XCTAssertEqual(sameInstall, install)
        server.fallback = (200, [:])
        await reopened.flush()
        let left = await reopened.queued
        XCTAssertEqual(left, [])
    }

    func testTooManyRequestsWaitsForRetryAfter() async {
        server.replies = [(429, ["Retry-After": "120"])]
        let pool = makePool()
        await pool.offer("Don Torrisi wants you.")
        await pool.flush()
        await pool.flush()
        XCTAssertEqual(server.received.count, 1)
        clock.advance(121)
        await pool.flush()
        XCTAssertEqual(server.received.count, 2)
        let queued = await pool.queued
        XCTAssertEqual(queued, [])
    }

    func testQueueKeepsTheNewestFiveThousand() async {
        server.fallback = nil
        let pool = makePool()
        for index in 0..<(LinePool.maxQueue + 10) { await pool.offer("Line number \(index) here") }
        let queued = await pool.queued
        XCTAssertEqual(queued.count, LinePool.maxQueue)
        XCTAssertEqual(queued.first?.text, "Line number 10 here")
    }

    func testTurningOffDropsTheQueue() async {
        let pool = makePool()
        await pool.offer("Don Torrisi wants you.")
        await pool.setEnabled(false)
        await pool.flush()
        let queued = await pool.queued
        XCTAssertEqual(queued, [])
        XCTAssertEqual(server.received.count, 0)
    }

    func testRetryAfterAcceptsSecondsAndDates() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        XCTAssertEqual(LinePool.retryDelay("30", now: now), 30)
        XCTAssertEqual(LinePool.retryDelay(nil, now: now), 60)
        XCTAssertEqual(LinePool.retryDelay("Mon, 26 Oct 2026 07:35:20 GMT", now: now), 120)
    }
}
