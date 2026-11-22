// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

@MainActor
final class PhoneRegionSessionTests: XCTestCase {
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

    /// Deliberately ignores cancellation, like a cloud reply already on its way.
    private actor Translator: TextTranslator {
        nonisolated let translatesTogether = true
        private var delayed: String?
        private var pending: CheckedContinuation<Void, Never>?
        private(set) var calls: [String] = []
        var waiting: Bool { pending != nil }

        func delay(_ text: String) { delayed = text }
        func resume() {
            pending?.resume()
            pending = nil
            delayed = nil
        }

        func translate(_ text: String) async throws -> String {
            calls.append(text)
            if text == delayed { await withCheckedContinuation { pending = $0 } }
            switch text {
            case "Reply today.": return "Bugün yanıtla."
            case "Open the camera.": return "Kamerayı aç."
            case "Meet me tomorrow.": return "Yarın buluşalım."
            default: return "Çevrildi: " + text
            }
        }
    }

    private final class Server: RegionSending {
        var sent: [(id: String, text: String, items: [ScreenTranslation.Item])] = []
        var clears = 0

        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }

        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?,
                        icons: [IconPlacement]?, blocks: [ScreenTranslation.Item]?) {
            sent.append((id, text, blocks ?? []))
        }

        func clearRegions() { clears += 1 }
    }

    private let first = TextBox(left: 0.15, top: 0.30, right: 0.85, bottom: 0.48)
    private let second = TextBox(left: 0.15, top: 0.72, right: 0.85, bottom: 0.85)
    private let edit = CGRect(x: 183, y: 94, width: 36, height: 12)
    private struct TimedOut: Error {}

    private func wait(_ done: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await done()) {
            if Date() >= deadline { throw TimedOut() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testChangedBubbleDropsOldTextWhileKeepingItsTranslatedNeighbor() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let a = GamePhoneTestFrame.phone(), b = GamePhoneTestFrame.phone(patch: edit)
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
        let unchanged = TextLine("Meet me tomorrow.", box: second)
        reader.set([TextLine("Reply today.", box: first), unchanged])
        watcher.offer(a, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        let shown = try XCTUnwrap(server.sent.last?.items)
        XCTAssertEqual(shown.map(\.translation), ["Bugün yanıtla.", "Yarın buluşalım."])
        XCTAssertTrue(shown.allSatisfy { $0.style != nil && $0.box.left >= pose.bounds.left && $0.box.right <= pose.bounds.right })

        reader.set([TextLine("Open the camera.", box: first), unchanged])
        await translator.delay("Open the camera.")
        clock = 450
        watcher.offer(b, areas: [], phone: pose)
        try await wait { await translator.waiting }
        XCTAssertEqual(server.sent.last?.items.map(\.translation), ["Yarın buluşalım."])
        await translator.resume()
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.last?.items.map(\.translation), ["Kamerayı aç.", "Yarın buluşalım."])
        let count = reader.count, visibleChanges = server.sent.count
        clock = 900
        watcher.offer(b, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(reader.count, count)
        XCTAssertEqual(server.sent.count, visibleChanges)
        let calls = await translator.calls
        XCTAssertEqual(calls.filter { $0 == "Meet me tomorrow." }.count, 1)
    }

    func testOldPageCannotPublishWhenAnotherFrameArrivesDuringTranslation() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let a = GamePhoneTestFrame.phone(), b = GamePhoneTestFrame.phone(patch: edit)
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
        await translator.delay("Reply today.")
        reader.set([TextLine("Reply today.", box: first)])
        watcher.offer(a, areas: [], phone: pose)
        try await wait { await translator.waiting }
        reader.set([TextLine("Open the camera.", box: first)])
        watcher.offer(b, areas: [], phone: pose)
        await translator.resume()
        try await wait { !watcher.isBusy }
        XCTAssertTrue(server.sent.isEmpty)
        clock = 450
        watcher.offer(b, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.map(\.text), ["Kamerayı aç."])
    }

    func testClosingPhoneWhileTranslationIsPendingLeavesManualRegionAlone() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let a = GamePhoneTestFrame.phone(), b = GamePhoneTestFrame.phone(patch: edit)
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
        let quest = ExtraArea(id: "q", name: "Quest", region: ExtraAreaPreset.quest.region)

        reader.set([TextLine("Meet me tomorrow.", box: second)])
        watcher.offer(a, areas: [quest])
        try await wait { !watcher.isBusy }
        clock = 1000
        watcher.offer(a, areas: [quest])
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.map(\.id), ["q"])

        reader.set([TextLine("Reply today.", box: first)])
        watcher.offer(a, areas: [quest], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.last?.text, "Bugün yanıtla.")
        let passes = watcher.passes
        await translator.delay("Open the camera.")
        reader.set([TextLine("Open the camera.", box: first)])
        clock += 450
        watcher.offer(b, areas: [quest], phone: pose)
        try await wait { await translator.waiting }
        watcher.offer(a, areas: [quest]) // The tracker has closed. No pending reply may draw over gameplay.
        await translator.resume()
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.filter { $0.id == "game-phone" }.map(\.text), ["Bugün yanıtla.", ""])
        XCTAssertEqual(server.sent.filter { $0.id == "q" }.count, 1)
        XCTAssertEqual(server.clears, 0)
        XCTAssertEqual(watcher.passes, passes)
    }

    /// Uzun mesajda yan yana iki sözcükte harf oynaması bekletilir; aynı okuma sürse de aynı mesajın OCR'la biraz farklı
    /// okunuşudur (`PhoneSteady`): yeniden çevrilmez, ekrandaki çeviri değişmez. Önceden ikinci okumada yeniden çevriliyor,
    /// çeviri gidip geliyordu (Windows ile aynı).
    func testLongPhoneMessageConfirmsAdjacentOcrTyposOnce() async throws {
        let original = "Cool. I'll check it out. Would be nice to clear my head for a second."
        let alternate = "Cool. I'll check ct ocut. Would be nice to clear my head for a second."
        for realChange in [false, true] {
            let reader = Reader(), translator = Translator(), server = Server()
            var clock = 0
            let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
            let a = GamePhoneTestFrame.phone()
            // Değişen piksel balonun dışında: OCR yeniden çalışır, balonun yüzeyi aynı kalır.
            let b = GamePhoneTestFrame.phone(patch: CGRect(x: 183, y: 160, width: 36, height: 12))
            let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
            reader.set([TextLine(original, box: first)])
            watcher.offer(a, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.count, 1)

            reader.set([TextLine(alternate, box: first)])
            clock = 450
            watcher.offer(b, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.count, 1, "bekletilen okuma ekranı değiştirmez")
            let held = await translator.calls
            XCTAssertEqual(held.count, 1)

            reader.set([TextLine(realChange ? alternate : original, box: first)])
            clock = 900
            watcher.offer(b, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            let calls = await translator.calls
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(server.sent.last?.text, "Çevrildi: " + original)
        }
    }

    /// Telefonun tek karede bulunamaması çevirileri silmez (önceden silinip bir sonraki turda geri geliyordu); art arda
    /// `PhoneSteady.missTurns` turda bulunamazsa silinir (Windows ve Android ile aynı).
    func testBriefPhoneMissKeepsTheTranslations() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let a = GamePhoneTestFrame.phone(), gone = GamePhoneTestFrame.phone(camera: false)
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
        reader.set([TextLine("Where are you man", box: first)])
        watcher.offer(a, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.map(\.text), ["Çevrildi: Where are you man"])
        for turn in 1...PhoneSteady.missTurns {
            clock = 450 * turn
            watcher.offer(gone, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.last?.text, turn < PhoneSteady.missTurns ? "Çevrildi: Where are you man" : "", "\(turn)")
        }
        XCTAssertEqual(server.sent.count, 2)
    }

    /// GitHub #822 / X (beta.76, GTA 6 telefonu): çeviri motordayken telefon bir karede doğrulanamadı (el titredi, kare
    /// geçişi). #801'den beri bu tur çevirileri silmiyor, ama okunan sayfa da bırakılmıyordu: telefon aynı görünüşe
    /// dönünce sayfa "değişmedi" sayılıyor, hazır çeviri hiç gösterilmiyordu (sonraki mesaja kadar "çeviri gelmiyor").
    func testTranslationArrivingDuringBriefPhoneMissIsShownOnTheNextTurn() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let a = GamePhoneTestFrame.phone(), gone = GamePhoneTestFrame.phone(camera: false)
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
        reader.set([TextLine("Reply today.", box: first)])
        await translator.delay("Reply today.")
        watcher.offer(a, areas: [], phone: pose)
        try await wait { await translator.waiting }
        watcher.offer(gone, areas: [], phone: pose)
        await translator.resume()
        try await wait { !watcher.isBusy }
        clock = 450
        watcher.offer(a, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.last?.text, "Bugün yanıtla.")
        let calls = await translator.calls
        XCTAssertEqual(calls, ["Reply today."])
    }

    /// İki komşu arasından düşen balon ekrandan hemen silinmez (`PhoneSteady.holdTurns` tur); sonra da yoksa silinir.
    func testOmittingOneBubbleBetweenUnchangedNeighborsRequiresASecondRead() async throws {
        let rows = [TextBox(left: 0.15, top: 0.20, right: 0.85, bottom: 0.26), TextBox(left: 0.15, top: 0.40, right: 0.85, bottom: 0.46),
                    TextBox(left: 0.15, top: 0.60, right: 0.85, bottom: 0.66), TextBox(left: 0.15, top: 0.80, right: 0.85, bottom: 0.86)]
        let full = zip(["How's work going?", "Not great today.", "Sorry to hear it.", "See you later."], rows).map { TextLine($0, box: $1) }
        for stillMissing in [false, true] {
            let reader = Reader(), translator = Translator(), server = Server()
            var clock = 0
            let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
            let a = GamePhoneTestFrame.phone(), b = GamePhoneTestFrame.phone(patch: edit)
            let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
            reader.set(full)
            watcher.offer(a, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.last?.items.count, 4)
            let sends = server.sent.count
            reader.set([full[0], full[1], full[3]])
            clock = 450
            watcher.offer(b, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.count, sends)
            if !stillMissing { reader.set(full) }
            clock = 900
            watcher.offer(b, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.last?.items.count, 4)
            clock = 1350
            watcher.offer(b, areas: [], phone: pose)
            try await wait { !watcher.isBusy }
            XCTAssertEqual(server.sent.last?.items.count, stillMissing ? 3 : 4)
        }
    }
}
