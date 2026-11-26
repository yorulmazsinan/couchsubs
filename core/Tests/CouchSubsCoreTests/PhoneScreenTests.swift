// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CouchSubsCore

/// GTA 6 telefonunun sohbet dışı ekranları (Sinan Bey, beta.100 3416–3425): ekran türü, kartlar, kartların panelde
/// telefonun yanında orantılı boyda ve tek renkte çizilmesi, telefonun yazılarının altyazıya ve ekran yazısı kutularına
/// gitmemesi, ekran değişince eski kartların hemen kalkması ve aynı ekranda kartların kaybolmaması. Ortak deneme dosyası
/// Fixtures/phone-screens.json (Windows PhoneScreenTests.cs, Android PhoneScreenTest.kt).
@MainActor
final class PhoneScreenTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Card: Decodable { let paragraphs: [String]; let titled: Bool; let bold: Bool }
        struct Screen: Decodable { let name: String; let kind: String; let lines: [Line]; let cards: [Card] }
        struct Times: Decodable { let yes: [String]; let no: [String] }
        let screens: [Screen]
        let times: Times
    }

    private static func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-screens.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    func testSharedScreensGiveTheSameKindAndCards() throws {
        let all = try Self.fixture()
        for screen in all.screens {
            let lines = screen.lines.map { PhoneScreen.Line(text: $0.text, spot: Self.box($0.box)) }
            let kind = PhoneScreen.kind(lines)
            XCTAssertEqual(kind.rawValue, screen.kind, screen.name)
            let cards = PhoneScreen.cards(lines, kind: kind)
            XCTAssertEqual(cards.map { PhoneScreen.paragraphs($0, lines) }, screen.cards.map(\.paragraphs), screen.name)
            XCTAssertEqual(cards.map(\.titled), screen.cards.map(\.titled), screen.name)
            XCTAssertEqual(cards.map(\.bold), screen.cards.map(\.bold), screen.name)
        }
        for text in all.times.yes { XCTAssertTrue(PhoneScreen.isTime(text), text) }
        for text in all.times.no { XCTAssertFalse(PhoneScreen.isTime(text), text) }
    }

    private static let frames = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../testdata/frames").standardized

    /// Gerçek sohbet kareleri (kayıtlı okumalarıyla) sohbet kalır: alt satıra sarılmış kısa parçalar ("off for you") etiket
    /// sayılmaz, ana ekran kareleri de kart ekranı değil ana ekran kurallarıyla okunur.
    func testRealChatFramesStayChats() throws {
        for name in ["gta6-telefon-sohbet-1", "gta6-telefon-sohbet-2"] {
            let url = Self.frames.appendingPathComponent(name + ".jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw XCTSkip("gerçek kare yok") }
            let data = try Data(contentsOf: Self.frames.appendingPathComponent("ocr/\(name)-tam.json"))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let pose = try XCTUnwrap(GamePhoneGeometry.locate(frame), name)
            let handset = ScreenPhoneCard.Handset(pose: pose, aspect: Double(frame.width) / Double(frame.height))
            let lines = try XCTUnwrap(json["lines"] as? [[String: Any]]).compactMap { line -> PhoneScreen.Line? in
                guard let text = line["text"] as? String, let b = line["box"] as? [Double], b.count == 4 else { return nil }
                let box = TextBox(left: b[0], top: b[1], right: b[2], bottom: b[3])
                guard ScreenPhoneCard.holds(box, handset: handset) else { return nil }
                return PhoneScreen.Line(text: text, spot: handset.flat(box))
            }
            XCTAssertGreaterThanOrEqual(lines.count, 4, name)
            XCTAssertEqual(PhoneScreen.kind(lines), .chat, name)
        }
    }

    private func line(_ text: String, _ spot: [Double]) -> TextLine {
        var line = TextLine(text, box: TextBox(left: 0.4 + spot[0] * 0.2, top: 0.1 + spot[1] * 0.8,
                                               right: 0.4 + spot[2] * 0.2, bottom: 0.1 + spot[3] * 0.8))
        line.phoneBox = Self.box(spot)
        return line
    }

    /// Otomatik telefon okuması: uygulama ekranının satırları kartlarına ayrılır (rol `card`, başlıklı kart iki paragraf),
    /// gönderide kullanıcı adı, konum ve fotoğraf yazısı çevrilmez, açıklama tek grup.
    func testAutoPhoneReadingGroupsAppScreensIntoCards() throws {
        let fitness = Reading(lines: [
            line("Training", [0.06, 0.12, 0.3, 0.14]),
            line("Power Session", [0.1, 0.17, 0.5, 0.19]), line("Stage 2/4", [0.1, 0.195, 0.35, 0.215]),
            line("Session done. Take a break.", [0.12, 0.25, 0.8, 0.27]),
            line("Endurance Run", [0.1, 0.32, 0.5, 0.34]), line("Stage 1/4", [0.1, 0.345, 0.35, 0.365]),
            line("7PM", [0.7, 0.5, 0.8, 0.52]),
        ])
        let groups = GamePhoneText.groups(GamePhoneText.forTranslation(fitness))
        XCTAssertEqual(groups.map(\.paragraphs), [["Training"], ["Power Session", "Stage 2/4"], ["Session done. Take a break."],
                                                   ["Endurance Run", "Stage 1/4"]])
        XCTAssertTrue(groups.allSatisfy { $0.phone?.role == .card })
        XCTAssertEqual(groups.map { $0.phone?.titled }, [false, true, false, true])

        let post = Reading(lines: [
            line("BAIT SHOP", [0.2, 0.12, 0.6, 0.17]),
            line("@harbor_bait_club", [0.12, 0.56, 0.62, 0.585]),
            line("Sunrise run past the north jetty", [0.06, 0.6, 0.92, 0.625]),
            line("Grab the spring issue at the dock t...", [0.06, 0.63, 0.92, 0.655]),
            line("Grab the spring issue", [0.3, 0.63, 0.7, 0.655]),
            line("Marlin Point", [0.1, 0.7, 0.4, 0.72]),
        ])
        let caption = GamePhoneText.groups(GamePhoneText.forTranslation(post))
        XCTAssertEqual(caption.map(\.paragraphs), [["Sunrise run past the north jetty Grab the spring issue at the dock t..."]])
        XCTAssertEqual(caption.first?.phone?.role, .card)
    }

    private let pose = GamePhoneGeometry.Pose(topX: 0.62, topY: 0.15, bottomX: 0.62, bottomY: 0.85)

    private func card(_ source: String, _ translation: String, top: Double, height: Double = 0.012, titled: Bool = false,
                      style: PhoneTextStyle? = nil, unchanged: Bool = false) -> ScreenTranslation.Item {
        var item = ScreenTranslation.Item(source: source, translation: translation,
                                          box: TextBox(left: 0.56, top: 0.2 + top * 0.6, right: 0.7, bottom: 0.2 + top * 0.6 + height),
                                          lineHeight: height)
        item.unchanged = unchanged
        item.style = style
        item.phone = ScreenPhoneCard.Placement(role: .card, spot: TextBox(left: 0.06, top: top, right: 0.9, bottom: top + 0.03),
                                               titled: titled)
        return item
    }

    /// Kartlar telefonun boş yanında (telefonun üstünde değil), mesaj listesi kartı görünüşünde (avatarsız), hepsi aynı
    /// renkte ve aynı genişlikte; başlıklı kartın başlığı kalın ad, gövdesi altında; çevrilmeyen kart (ad) çizilmez.
    func testAppCardsAreDrawnBesideThePhoneAsUniformRowCards() throws {
        let handset = ScreenPhoneCard.Handset(pose: pose, aspect: 16.0 / 9)
        let white = PhoneTextStyle(background: "#F2F2F2", foreground: "#111111")
        let navy = PhoneTextStyle(background: "#1A2238", foreground: "#F0F0F0")
        let items = [
            card("Riley", "Riley", top: 0.03, style: white, unchanged: true),
            card("Power Session\nStage 2/4", "Güç Seansı\nAşama 2/4", top: 0.17, titled: true, style: white),
            card("Session done. Take a break.", "Seans bitti. Mola ver.", top: 0.25, style: navy),
            card("Endurance Run\nStage 1/4", "Dayanıklılık Koşusu\nAşama 1/4", top: 0.32, titled: true, style: white),
        ]
        let laid = ScreenPhoneCard.layout(items, handset: handset).filter { !$0.unchanged }
        let rows = laid.filter { $0.panel == .row }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.compactMap(\.listRow).map(\.name), ["Güç Seansı", "", "Dayanıklılık Koşusu"])
        XCTAssertEqual(rows.compactMap(\.listRow).map(\.preview), ["Aşama 2/4", "Seans bitti. Mola ver.", "Aşama 1/4"])
        XCTAssertTrue(rows.allSatisfy { $0.listRow?.avatar == nil && $0.listRow?.portraitSpot == nil })
        XCTAssertEqual(Set(rows.map { $0.style?.background ?? "" }).count, 1, "tek renk")
        XCTAssertEqual(rows[0].style?.background, white.background)
        XCTAssertEqual(Set(rows.map { ($0.box.right - $0.box.left).rounded(toPlaces: 9) }).count, 1, "aynı genişlik")
        let phone = handset.bounds
        for row in rows { XCTAssertTrue(row.box.right <= phone.left + 1e-9 || row.box.left >= phone.right - 1e-9, "telefonun üstünde değil") }
        // Kartların üstü İngilizcesiyle aynı hizada, üst üste binmez.
        for (a, b) in zip(rows, rows.dropFirst()) { XCTAssertLessThanOrEqual(a.box.bottom, b.box.top + 1e-9) }
        XCTAssertFalse(laid.contains { $0.source == "Riley" }, "çevrilmeyen ad çizilmez")
    }

    /// Yazı boyu telefon yazısıyla orantılı: fotoğrafın içindeki büyük yazı ya da yakın kamera paneli dev yazıyla
    /// çizmez (3416); çift sayıda ölçümde küçük ortanca alınır.
    func testCardTextIsProportionalNotHuge() {
        let handset = ScreenPhoneCard.Handset(pose: pose, aspect: 16.0 / 9)
        let small = card("Last call for the boat", "Tekne için son çağrı", top: 0.6, height: 0.012)
        let sign = card("BAIT SHOP", "YEM DÜKKANI", top: 0.1, height: 0.07)
        XCTAssertEqual(ScreenPhoneCard.measuredLine([small, sign]), 0.012)
        let laid = ScreenPhoneCard.layout([small, sign], handset: handset)
        for row in laid where row.panel == .row {
            XCTAssertLessThanOrEqual(row.lineHeight, ScreenPhoneCard.maxLine + 1e-9)
            XCTAssertGreaterThanOrEqual(row.lineHeight, ScreenPhoneCard.minLine - 1e-9)
        }
        let huge = ScreenPhoneCard.layout([card("Big", "Büyük yazı", top: 0.3, height: 0.08)], handset: handset, textScale: 1)
        XCTAssertEqual(huge.first { $0.panel == .row }?.lineHeight ?? 0, ScreenPhoneCard.maxLine, accuracy: 1e-9)
        // Altyazı boyutu ayarı yine çarpan olarak işler.
        let scaled = ScreenPhoneCard.layout([card("Big", "Büyük yazı", top: 0.3, height: 0.08)], handset: handset, textScale: 1.5)
        XCTAssertEqual(scaled.first { $0.panel == .row }?.lineHeight ?? 0, ScreenPhoneCard.maxLine * 1.5, accuracy: 1e-9)
    }

    /// Ana ekran ve hava yazıları da telefonun üstüne yazılmaz: panelde kart olur; saat ("7PM") çevrilmez.
    func testHomeAndWeatherTextGoesToThePanel() {
        let handset = ScreenPhoneCard.Handset(pose: pose, aspect: 16.0 / 9)
        var home = card("Partly cloudy", "Parçalı bulutlu", top: 0.2)
        home.phone?.role = .home
        let laid = ScreenPhoneCard.layout([home], handset: handset)
        let row = laid.first { $0.panel == .row }
        XCTAssertEqual(row?.listRow?.preview, "Parçalı bulutlu")
        XCTAssertTrue((row?.box.right ?? 1) <= handset.bounds.left + 1e-9 || (row?.box.left ?? 0) >= handset.bounds.right - 1e-9)
        var weather = [line("Now", [0.06, 0.1, 0.2, 0.12]), line("71°", [0.06, 0.13, 0.3, 0.2]),
                       line("Partly cloudy", [0.06, 0.21, 0.5, 0.23]), line("7PM", [0.06, 0.3, 0.14, 0.32]),
                       line("8PM", [0.2, 0.3, 0.28, 0.32]), line("Sunset", [0.06, 0.6, 0.3, 0.62])]
        weather = PhoneChat.withoutAppNames(weather)
        XCTAssertFalse(weather.contains { $0.text == "7PM" || $0.text == "8PM" })
        XCTAssertTrue(weather.contains { $0.text == "Sunset" })
    }

    /// Açık telefonun yanları beyaz ekranda zemine karışınca sıkı arama telefonu bulamaz; son yerindeki gevşek doğrulama
    /// (hoparlör yarığı, kamera, alt çentik) telefonu tutar. Yeni telefon gevşek doğrulamayla açılmaz; telefon gerçekten
    /// kalkınca (yarıklar yok) tolerans dolunca kapanır.
    func testOpenPhoneIsKeptWhenItsSidesBlendIntoTheBackground() throws {
        let normal = GamePhoneTestFrame.phone()
        // Beyaz ekran, açık kasa ve açık zemin aynı tonda: yan kenar yok (yalnız yarıklar ve kamera koyu).
        let blended = GamePhoneTestFrame.image(width: 400, height: 225) { x, y in
            var gray = GamePhoneTestFrame.phoneGray(x, y)
            if gray == 85 || gray == 110 { gray = 192 }
            return (gray, gray, gray)
        }
        let gone = GamePhoneTestFrame.image(width: 400, height: 225) { _, _ in (85, 85, 85) }
        XCTAssertNil(GamePhoneGeometry.locate(blended), "sıkı arama bulamıyor")
        let found = try XCTUnwrap(GamePhoneGeometry.locate(normal))
        let near = try XCTUnwrap(GamePhoneGeometry.locate(blended, near: found), "son yerinde doğrulanır")
        XCTAssertEqual(near.topY, found.topY, accuracy: 3.0 / 225)
        XCTAssertNil(GamePhoneGeometry.locate(gone, near: found))
        // Uzaktaki eski yer doğrulamaz.
        let far = GamePhoneGeometry.Pose(topX: found.topX - 0.2, topY: found.topY, bottomX: found.bottomX - 0.2, bottomY: found.bottomY)
        XCTAssertNil(GamePhoneGeometry.locate(blended, near: far))

        let tracker = GamePhoneTracker()
        XCTAssertNil(tracker.sample(normal, now: 0).pose)
        XCTAssertNotNil(tracker.sample(normal, now: 330).pose)
        for turn in 2...12 { XCTAssertNotNil(tracker.sample(blended, now: turn * 330).pose, "tur \(turn)") }
        var closed = false
        for turn in 13...18 where tracker.sample(gone, now: turn * 330).pose == nil { closed = true }
        XCTAssertTrue(closed)
        // Kapanmış telefon gevşek doğrulamayla açılmaz.
        let fresh = GamePhoneTracker()
        XCTAssertNil(fresh.sample(blended, now: 0).pose)
        XCTAssertNil(fresh.sample(blended, now: 330).pose)
    }

    /// Altyazı süzgeci açık telefonu tek ıskada bırakmaz (3418, 3420, 3421): `GamePhoneTracker.missGrace` arama tutulur.
    func testSubtitleFilterHoldsThePhoneThroughShortMisses() {
        let handset = ScreenPhoneCard.Handset(pose: pose, aspect: 16.0 / 9)
        var misses = 0
        XCTAssertEqual(SubtitlePipeline.heldPhone(handset, shown: nil, misses: &misses), handset)
        for _ in 0..<GamePhoneTracker.missGrace {
            XCTAssertEqual(SubtitlePipeline.heldPhone(nil, shown: handset, misses: &misses), handset)
        }
        XCTAssertNil(SubtitlePipeline.heldPhone(nil, shown: handset, misses: &misses))
        XCTAssertEqual(misses, 0)
        XCTAssertNil(SubtitlePipeline.heldPhone(nil, shown: nil, misses: &misses))
    }

    // MARK: - Oturum (otomatik telefon okuması)

    private final class Reader: TextReader, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [TextLine] = []
        func set(_ lines: [TextLine]) { lock.withLock { self.lines = lines } }
        func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { lock.withLock { Reading(lines: lines) } }
    }

    private actor Translator: TextTranslator {
        nonisolated let translatesTogether = true
        private(set) var calls: [String] = []
        func translate(_ text: String) async throws -> String {
            calls.append(text)
            let known = ["City council approves the waterfront plan": "Meclis sahil planını onayladı", "The council voted late on Tuesday to approve the long delayed plan.": "Meclis salı geç saatte uzun süredir bekleyen planı onayladı.", "Partly cloudy": "Parçalı bulutlu", "Sunset": "Gün batımı", "Now": "Şimdi"]
            return known[text] ?? "Çeviri " + String(text.reversed())
        }
    }

    private final class Server: RegionSending {
        var sent: [(id: String, items: [ScreenTranslation.Item])] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?,
                        icons: [IconPlacement]?, blocks: [ScreenTranslation.Item]?) {
            sent.append((id, text.isEmpty ? [] : (blocks ?? [ScreenTranslation.Item(source: "", translation: text, box: box ?? TextBox(left: 0, top: 0, right: 1, bottom: 1), lineHeight: lineHeight ?? 0)])))
        }
        func clearRegions() {}
    }

    private struct TimedOut: Error {}

    private func wait(_ done: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await done()) {
            if Date() >= deadline { throw TimedOut() }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func flat(_ text: String, _ spot: [Double]) -> TextLine { TextLine(text, box: Self.box(spot)) }

    /// Uygulama değişince (makaleden hava uygulamasına) eski kartlar aynı gönderide kalkar; aynı ekran art arda okununca
    /// kartlar kaybolmaz, yeniden gönderilmez ve yeniden çevrilmez (#1279).
    func testScreenChangeReplacesCardsAndSameScreenStaysStill() async throws {
        let frame = GamePhoneTestFrame.phone()
        let found = try XCTUnwrap(GamePhoneGeometry.locate(frame))
        let shifted = GamePhoneGeometry.Pose(topX: found.topX + 0.02, topY: found.topY, bottomX: found.bottomX + 0.02,
                                             bottomY: found.bottomY)
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        let article = [flat("< Back", [0.04, 0.02, 0.2, 0.045]),
                       flat("City council approves", [0.06, 0.06, 0.9, 0.1]), flat("the waterfront plan", [0.06, 0.105, 0.9, 0.145]),
                       flat("The council voted late on Tuesday to", [0.06, 0.6, 0.94, 0.62]),
                       flat("approve the long delayed plan.", [0.06, 0.625, 0.9, 0.645])]
        reader.set(article)
        watcher.offer(frame, areas: [], phone: found)
        try await wait { !watcher.isBusy }
        let first = try XCTUnwrap(server.sent.last { $0.id == "game-phone" }?.items)
        XCTAssertEqual(first.compactMap(\.listRow).map(\.name), ["Meclis sahil planını onayladı", ""])
        XCTAssertEqual(first.compactMap(\.listRow).map(\.preview), ["", "Meclis salı geç saatte uzun süredir bekleyen planı onayladı."])
        XCTAssertFalse(first.contains { $0.translation.contains("Back") })

        // Aynı ekran, telefon biraz kıpırdadı: yeniden okunur ama gönderi ve çeviri yinelenmez, kartlar yerinde kalır.
        let sends = server.sent.count, calls = await translator.calls.count
        for turn in 1...4 {
            clock += 450
            watcher.offer(frame, areas: [], phone: turn % 2 == 1 ? shifted : found)
            try await wait { !watcher.isBusy }
        }
        let still = await translator.calls.count
        XCTAssertEqual(still, calls, "aynı ekran yeniden çevrilmez")
        XCTAssertFalse(server.sent.dropFirst(sends).contains { $0.id == "game-phone" && $0.items.isEmpty }, "kartlar kaybolmaz")

        // Hava uygulaması: eski makale kartları bu gönderide kalkar.
        reader.set([flat("Now", [0.06, 0.1, 0.2, 0.12]), flat("71°", [0.06, 0.13, 0.3, 0.2]),
                    flat("Partly cloudy", [0.06, 0.21, 0.5, 0.23]), flat("7PM", [0.06, 0.3, 0.14, 0.32]),
                    flat("Sunset", [0.06, 0.6, 0.3, 0.62])])
        clock += 450
        watcher.offer(frame, areas: [], phone: shifted) // kare değişti (yeni uygulama); testte telefonun yeri oynatılarak yeniden okunur
        try await wait { !watcher.isBusy }
        let weather = try XCTUnwrap(server.sent.last { $0.id == "game-phone" }?.items)
        let texts = weather.compactMap(\.listRow).map { $0.name + $0.preview }
        XCTAssertFalse(texts.contains { $0.contains("Meclis") }, "eski kartlar kalktı: \(texts)")
        XCTAssertTrue(texts.contains("Parçalı bulutlu"))
        XCTAssertTrue(texts.contains("Gün batımı"))
        XCTAssertFalse(texts.contains { $0.contains("7PM") }, "saat çevrilmez")
    }

    /// Telefon açılınca otomatik ekran yazısı kutuları (telefonun ekranına çizilmiş olanlar dahil) aynı karede kalkar.
    func testPhoneOpeningClearsScreenTextBoxesAtOnce() async throws {
        let frame = GamePhoneTestFrame.phone()
        let found = try XCTUnwrap(GamePhoneGeometry.locate(frame))
        let reader = Reader(), translator = Translator(), server = Server()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        reader.set([TextLine("Governor speaks today", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.5))])
        let area = ExtraArea(id: "auto-7", name: "auto", region: CropRegion(top: 0.3, bottom: 0.4, left: 0.45, right: 0.6), auto: true)
        for _ in 0..<4 {
            await watcher.pass(frame, areas: [area])
            clock += 1000
        }
        XCTAssertTrue(server.sent.contains { $0.id == "auto-7" && !$0.items.isEmpty }, "kutu gösterildi")
        let before = server.sent.count
        watcher.offer(frame, areas: [], phone: found)
        XCTAssertTrue(server.sent.dropFirst(before).contains { $0.id == "auto-7" && $0.items.isEmpty }, "aynı karede kalktı")
        try await wait { !watcher.isBusy }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
