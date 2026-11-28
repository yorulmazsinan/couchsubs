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
        /// Her okumada (OCR sürerken) çağrılır: elde sallanan telefonun yeni karesi gibi.
        private var hook: (@Sendable () -> Void)?
        var count: Int { lock.withLock { reads } }
        func set(_ lines: [TextLine]) { lock.withLock { self.lines = lines } }
        func onRead(_ hook: (@Sendable () -> Void)?) { lock.withLock { self.hook = hook } }
        func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
            let (reading, hook) = lock.withLock {
                reads += 1
                return (Reading(lines: lines), self.hook)
            }
            hook?()
            return reading
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
        // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
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
        // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
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

    /// GTA 6'nın telefonu elde durur, her karede birkaç piksel sallanır: okuma sürerken gelen her yeni karenin yazı
    /// pikselleri değişir. Okuma sonraki karede yeniden okunur ve kabul edilir; o okuma sürerken bir kare daha geldi diye
    /// atılmaz. Önceden yeniden okuma da her seferinde "doğrulanamadı" sayılıyordu: mesajlar ancak telefon tam durduğu
    /// nadir anlarda çevriliyor, ilk çeviriden sonra yeni mesaj gelmiyordu (#1202, #1197, #1193, #1170; Windows ve Android
    /// ile aynı).
    func testSwayingPhoneStillTranslatesAndShowsNewMessages() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
        let still = GamePhoneTestFrame.phone()
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(still))
        // Sallanan telefonun kareleri: yazının pikselleri her karede biraz başka yerde.
        let frames = (0..<4).map { GamePhoneTestFrame.phone(patch: CGRect(x: 170 + 12 * $0, y: 94, width: 10, height: 12)) }
        final class Sway: @unchecked Sendable { var next = 0 }
        let sway = Sway()
        reader.onRead {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    sway.next += 1
                    watcher.offer(frames[sway.next % frames.count], areas: [], phone: pose)
                }
            }
        }
        reader.set([TextLine("Reply today.", box: first)])
        watcher.offer(frames[0], areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.last?.items.map(\.translation), ["Bugün yanıtla."])

        reader.set([TextLine("Reply today.", box: first), TextLine("Meet me tomorrow.", box: second)])
        clock = 450
        watcher.offer(frames[sway.next % frames.count], areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        XCTAssertEqual(server.sent.last?.items.map(\.translation), ["Bugün yanıtla.", "Yarın buluşalım."])
    }

    func testClosingPhoneWhileTranslationIsPendingLeavesManualRegionAlone() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
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
            // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
            watcher.phonePanel = { PhonePanelOptions(enabled: false) }
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
        // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
        let a = GamePhoneTestFrame.phone(), gone = GamePhoneTestFrame.gone()
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
        // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
        let a = GamePhoneTestFrame.phone(), gone = GamePhoneTestFrame.gone()
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
            // Bu sınamalar balonların üstündeki düzeni (kararlılık) ölçer; panel ayrı sınanır.
            watcher.phonePanel = { PhonePanelOptions(enabled: false) }
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
            // Aynı eksik düzen `PhoneSteady.degradedTurns` okuma sürerse geçer (X, 28 Kas, beta.107; Windows ile aynı).
            for turn in 3...PhoneSteady.degradedTurns {
                clock = 450 * turn
                watcher.offer(b, areas: [], phone: pose)
                try await wait { !watcher.isBusy }
                if turn < PhoneSteady.degradedTurns { XCTAssertEqual(server.sent.last?.items.count, 4) }
            }
            XCTAssertEqual(server.sent.last?.items.count, stillMissing ? 3 : 4)
        }
    }

    /// Yanda Panel (varsayılan; X'teki bildirim: monitörde balonların üstündeki çeviriler kayıyor, kimin ne dediği belli
    /// olmuyor): mesajlar telefonun yanındaki panelde, telefonun üstüne binmeden; üstte kişinin adı aslıyla (çevirmene
    /// gitmez), karşı tarafın mesajı solda açık zeminde, oyuncunun mesajı sağda amber zeminde, sırası telefondaki gibi.
    func testSidePanelShowsTheChatNextToThePhone() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let a = GamePhoneTestFrame.phone()
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(a))
        reader.set([TextLine("Lucia", box: TextBox(left: 0.40, top: 0.05, right: 0.60, bottom: 0.09)),
                    TextLine("Reply today.", box: TextBox(left: 0.05, top: 0.30, right: 0.55, bottom: 0.36)),
                    TextLine("Open the camera.", box: TextBox(left: 0.45, top: 0.50, right: 0.95, bottom: 0.56))])
        watcher.offer(a, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        let items = try XCTUnwrap(server.sent.last?.items)
        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402).
        XCTAssertEqual(items.map(\.panel), [.card, .theirs, .mine])
        XCTAssertEqual(items.map { SubtitleServer.json($0, phone: true)["panel"] as? String }, ["card", "theirs", "mine"])
        XCTAssertEqual(items.map(\.translation), [ScreenPhoneCard.backdropText, "Bugün yanıtla.", "Kamerayı aç."])
        let calls = await translator.calls
        XCTAssertFalse(calls.contains("Lucia"), "kişinin adı çevrilmez")
        XCTAssertEqual(server.sent.last?.text, "Bugün yanıtla.\nKamerayı aç.")
        let card = items[0].box, phone = pose.bounds
        XCTAssertTrue(card.left >= phone.right || card.right <= phone.left || card.top >= phone.bottom, "panel telefonun yanında")
        for item in items.dropFirst() {
            XCTAssertTrue(item.box.left >= card.left - 1e-9 && item.box.right <= card.right + 1e-9
                          && item.box.top >= card.top - 1e-9 && item.box.bottom <= card.bottom + 1e-9)
        }
        // Balonlar telefondaki balonun renginde (deneme karesinin balonları gri), panel hizalı.
        XCTAssertEqual(items[1].style?.background, "#C0C0C0")
        XCTAssertEqual(items[2].style?.background, "#C0C0C0")
        XCTAssertTrue(items[0].aligned)
        XCTAssertLessThan(items[1].box.left, items[2].box.left, "karşı taraf solda, oyuncu sağda")
        XCTAssertLessThan(items[1].box.top, items[2].box.top)
        XCTAssertGreaterThanOrEqual(items[1].lineHeight, ScreenPhoneCard.minLine - 1e-9)

        // Balonların Üstünde: her çeviri kendi balonunun yerinde, adı aslıyla aynı olduğu için çizilmez.
        watcher.phonePanel = { PhonePanelOptions(enabled: false) }
        clock = 450
        watcher.offer(a, areas: [], phone: pose)
        try await wait { !watcher.isBusy }
        let bubbles = try XCTUnwrap(server.sent.last?.items)
        XCTAssertEqual(bubbles.map(\.translation), ["Bugün yanıtla.", "Kamerayı aç."])
        XCTAssertTrue(bubbles.allSatisfy { $0.panel == nil && $0.box.left >= phone.left && $0.box.right <= phone.right })
    }

    /// LG, beta.93: GTA 6 Mesajlar ekranı elde sallanırken TV'deki panel her saniye liste ile sohbet balonları arasında
    /// gidip geliyordu. Pikselleri biraz farklı, başlığı bir "g" ile bir simgesiz okunan art arda okumalarda sayfa liste
    /// kalır, aynı görüntü yeniden gönderilmez; tek bir sohbet gibi okunan kare türü değiştirmez, art arda iki okuma değiştirir.
    func testSwayingMessageListKeepsTheListLayout() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let still = GamePhoneTestFrame.phone()
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(still))
        func row(_ text: String, _ y: Double, _ left: Double, _ right: Double, _ dy: Double) -> TextLine {
            TextLine(text, box: TextBox(left: left, top: y + dy, right: right, bottom: y + dy + 0.031))
        }
        func list(_ heading: String, _ dy: Double) -> [TextLine] {
            [row(heading, 0.04, 0.05, 0.40, dy), row("Cal", 0.10, 0.30, 0.38, dy), row("$ in your mailbox. You bailed", 0.14, 0.30, 0.95, dy),
             row("Brian", 0.22, 0.30, 0.42, dy), row("Ok. There's some cash in t...", 0.26, 0.30, 0.95, dy),
             row("Messages", 0.33, 0.03, 0.30, dy), row("Donnie", 0.40, 0.30, 0.45, dy),
             row("Joey", 0.50, 0.30, 0.40, dy), row("Hey this is Joey from Coa...", 0.54, 0.30, 0.95, dy),
             row("Shirley", 0.74, 0.30, 0.45, dy), row("Oh that's nice hon. aren't ...", 0.78, 0.30, 0.95, dy),
             row("Rusty Anchor", 0.88, 0.30, 0.62, dy)]
        }
        // Liste gibi okunamayan kare: yalnız iki ad-önizleme çifti, başlık ve kesik önizleme yok.
        let chat = [row("Joey", 0.50, 0.30, 0.40, 0), row("Hey this is Joey from home.", 0.54, 0.30, 0.95, 0),
                    row("Shirley", 0.74, 0.30, 0.45, 0), row("Oh that's nice hon.", 0.78, 0.30, 0.95, 0)]
        var step = 0
        func read(_ lines: [TextLine]) async throws {
            reader.set(lines)
            clock = 450 * step
            let patch = CGRect(x: 170 + 6 * (step % 10), y: 60 + 4 * step, width: 10, height: 12)
            watcher.offer(GamePhoneTestFrame.phone(patch: patch), areas: [], phone: pose)
            step += 1
            try await wait { !watcher.isBusy }
        }
        try await read(list("Suggested", 0))
        let shown = try XCTUnwrap(server.sent.last?.items)
        // Bölüm başlıkları küçük başlık (sola yaslı, kalın not); her kişi satırı tek kart (ad + önizleme; Sinan Bey, beta.100
        // 3399). "…" ile ya da satır sonunda kesilmiş önizleme kesik çevrilir, "$" düşmez.
        let notes = shown.filter { $0.panel == .note }
        XCTAssertEqual(notes.map(\.translation), ["Çevrildi: Suggested", "Çevrildi: Messages"])
        XCTAssertTrue(notes.allSatisfy { $0.look?.align == .left && $0.look?.bold == true }, "başlık sola yaslı, kalın")
        let cards = shown.compactMap(\.listRow)
        XCTAssertEqual(cards.map(\.name), ["Cal", "Brian", "Donnie", "Joey", "Shirley", "Rusty Anchor"])
        XCTAssertEqual(cards.map(\.preview), ["Çevrildi: $ in your mailbox. You bailed...", "Çevrildi: Ok. There's some cash...", "",
                                             "Çevrildi: Hey this is Joey...", "Çevrildi: Oh that's nice hon...", ""])
        let rows = shown.filter { $0.panel == .note || $0.panel == .row }
        XCTAssertEqual(zip(rows, rows.dropFirst()).filter { $0.box.bottom > $1.box.top + 1e-9 }.count, 0, "telefondaki sıra, üst üste binmez")
        let calls = await translator.calls
        let names: Set<String> = ["Cal", "Brian", "Joey", "Donnie", "Shirley", "Rusty Anchor"]
        XCTAssertFalse(calls.contains { names.contains($0) }, "adlar çevrilmez")
        XCTAssertFalse(calls.contains { $0.contains("Coa") }, "yarım sözcük çeviriye gitmez")
        let sent = server.sent.count

        // Sallanan telefon: kutular birkaç piksel oynar, başlığın simgesi bir "g" okunur; görüntü aynı, yeniden gönderilmez.
        try await read(list("g Suggested", 0.003))
        try await read(list("✱ Suggested", -0.002))
        XCTAssertEqual(server.sent.count, sent)
        let later = await translator.calls
        XCTAssertFalse(later.contains { $0.contains("g Suggested") })

        // Tek bir okuma sohbet gibi geldi: liste kalır.
        try await read(chat)
        try await read(list("Suggested", 0.002))
        XCTAssertEqual(server.sent.count, sent)

        // Sayfa gerçekten değişti (art arda iki okuma): yeni tür çizilir.
        try await read(chat)
        XCTAssertEqual(server.sent.count, sent)
        try await read(chat)
        XCTAssertGreaterThan(server.sent.count, sent)
        let after = try XCTUnwrap(server.sent.last?.items)
        XCTAssertFalse(after.contains { $0.panel == .row || ($0.panel == .note && $0.look?.align == .left) })
    }

    /// Panelin yazısı altyazı boyutu ayarıyla büyür.
    func testSidePanelTextFollowsSubtitleSize() {
        XCTAssertEqual(ScreenPhoneCard.textScale(fontSize: 46), 1, accuracy: 1e-9)
        XCTAssertEqual(ScreenPhoneCard.textScale(fontSize: 69), 1.5, accuracy: 1e-9)
        XCTAssertEqual(ScreenPhoneCard.textScale(fontSize: 10), ScreenPhoneCard.minScale, accuracy: 1e-9)
    }
}
