// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// X (26 Kas, beta.104, Windows + PS Remote Play): GTA 6 telefon sohbetinde en üstteki uzun mesaj çizilmiyordu, alttaki iki
/// cevap seçeneğinden biri sarı giden balon, öbürü soluk ortalı not olarak karışık görünüyordu. Ortak deneme dosyasının
/// `roles` bölümü ve `cases` içindeki "cevap seçeneği" sohbeti (Windows PhoneOptionTests.cs, Android PhoneOptionTest.kt).
final class PhoneOptionTests: XCTestCase {
    private struct Shared: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Panel: Decodable { let name: String; let lines: [Line]; let groups: [[String]] }
        let roles: [Panel]
    }

    private func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    private func shared() throws -> Shared {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-chat.json")
        return try JSONDecoder().decode(Shared.self, from: Data(contentsOf: url))
    }

    /// Otomatik telefon okuması: en üstteki mesaj (başlık okunmasa da) balon, her cevap seçeneği kendi satırı ve `option`.
    func testSharedRoleVectors() throws {
        for panel in try shared().roles {
            let reading = Reading(lines: panel.lines.map { line in
                var text = TextLine(line.text, box: box(line.box))
                text.phoneBox = box(line.box)
                return text
            })
            let groups = GamePhoneText.groups(GamePhoneText.forTranslation(reading))
            XCTAssertEqual(groups.map { [$0.phone?.role.rawValue ?? "-", $0.paragraphs.joined(separator: "\n")] }, panel.groups, panel.name)
        }
    }

    /// Not yalnız kısa etiket; ortalı cümle cevap seçeneğidir.
    func testCenteredSentenceIsAnOptionNotANote() {
        func row(_ text: String, _ left: Double, _ right: Double) -> PhoneChat.Row {
            PhoneChat.Row(lines: [], spot: TextBox(left: left, top: 0.8, right: right, bottom: 0.82), text: text)
        }
        XCTAssertEqual(PhoneChat.role(of: [row("Today 9:41 PM", 0.38, 0.62)]), .note)
        XCTAssertEqual(PhoneChat.role(of: [row("New messages", 0.32, 0.66)]), .note)
        XCTAssertEqual(PhoneChat.role(of: [row("Thanks for the heads up.", 0.21, 0.77)]), .option)
        XCTAssertEqual(PhoneChat.role(of: [row("Yeah I don't need your", 0.3, 0.7), row("opinion thanks.", 0.3, 0.6)]), .option)
        XCTAssertEqual(PhoneChat.withOptions([.incoming, .outgoing, .option]), [.incoming, .option, .option])
        XCTAssertEqual(PhoneChat.withOptions([.outgoing, .incoming, .option]), [.outgoing, .incoming, .option])
        XCTAssertEqual(PhoneChat.withOptions([.incoming, .outgoing, .note]), [.incoming, .outgoing, .note])
    }

    /// Yanda Panel: seçenekler oyuncunun tarafında ayrı balonlar, ikisi de aynı renkte (okunan örnek ya da yedek).
    func testOptionsShareOneLookInThePanel() {
        let handset = ScreenPhoneCard.Handset(pose: GamePhoneGeometry.Pose(topX: 0.6087, topY: 0.1026, bottomX: 0.5528, bottomY: 0.8395),
                                              aspect: 16.0 / 9)
        func item(_ text: String, _ role: ScreenPhoneCard.Role, top: Double, style: PhoneTextStyle?) -> ScreenTranslation.Item {
            var item = ScreenTranslation.Item(source: text, translation: text + " (tr)",
                                              box: TextBox(left: 0.5, top: top, right: 0.62, bottom: top + 0.03), lineHeight: 0.016)
            item.phone = ScreenPhoneCard.Placement(role: role, spot: TextBox(left: 0.2, top: top, right: 0.8, bottom: top + 0.03))
            item.style = style
            return item
        }
        let blue = PhoneTextStyle(background: "#3058D0", foreground: "#FFFFFF")
        let laid = ScreenPhoneCard.layout([item("Hello there friend", .incoming, top: 0.4, style: nil),
                                           item("Thanks for the heads up.", .option, top: 0.65, style: GamePhonePalette.neutral),
                                           item("Yeah I don't need your opinion thanks.", .option, top: 0.72, style: blue)],
                                          handset: handset)
        let options = laid.filter { $0.source != "Hello there friend" && !ScreenPhoneCard.isBackdrop($0) }
        XCTAssertEqual(options.count, 2)
        XCTAssertTrue(options.allSatisfy { $0.panel == .mine && $0.look?.align == .right })
        XCTAssertEqual(options[0].style, blue)
        XCTAssertEqual(options[1].style, blue)
        XCTAssertLessThan(options[0].box.bottom, options[1].box.top)
        // Okunan seçeneğin kendi seçim rengi korunur (X, 28 Kas, beta.107; Windows ile aynı).
        let selected = PhoneTextStyle(background: "#F5B83D", foreground: "#17181B")
        for styles in [[selected, blue], [blue, selected]] {
            let panel = ScreenPhoneCard.layout([item("First reply.", .option, top: 0.65, style: styles[0]),
                                                item("Second reply.", .option, top: 0.72, style: styles[1])], handset: handset)
            XCTAssertEqual(panel.filter { $0.panel == .mine }.map(\.style), styles)
        }
    }

    /// Saydam pencere: uzun ilk mesaj dar sütuna sığmayınca düşmez; sütun genişler (gerekirse yazı küçülür). Hiçbir düzen
    /// yetmezse eski kural (verilen boy, en eski mesaj düşer) sürer.
    func testStackedPanelKeepsTheLongFirstMessage() {
        func part(_ text: String, _ panel: ScreenPhoneCard.PanelPart, top: Double) -> ScreenTranslation.Item {
            var item = ScreenTranslation.Item(source: text, translation: text, box: TextBox(left: 0.72, top: top, right: 0.9, bottom: top + 0.05),
                                              lineHeight: 0.03)
            item.panel = panel
            return item
        }
        var card = part(ScreenPhoneCard.backdropText, .card, top: 0.2)
        card.box = TextBox(left: 0.6, top: 0.1, right: 0.9, bottom: 0.9)
        card.aligned = true
        let long = "Seni 10 numaralı odadaki misafirimizle gördüm. Bil diye söylüyorum, misafir kurallarını çiğnediği için "
            + "birçok kez uyarıldı. Onun yüzünden daha fazla belaya girmeni istemem. L."
        let items = [card, part("Yeni mesajlar", .note, top: 0.25), part(long, .theirs, top: 0.3),
                     part("DAHA FAZLA yazım hatasıydı. Tabii ki HERHANGİ BİR sorun demek istedim.", .theirs, top: 0.55),
                     part("Haber verdiğin için sağ ol.", .mine, top: 0.65), part("Evet, senin fikrine ihtiyacım yok, sağ ol.", .mine, top: 0.72)]
        let panel = ScreenPhoneCard.panel(items)!
        let stacked = ScreenPhoneCard.stacked(panel, width: 1600, height: 420, font: 20)
        XCTAssertEqual(stacked.messages.map(\.translation), panel.messages.map(\.translation), "en üstteki mesaj düşmez")
        XCTAssertLessThanOrEqual(stacked.messages.last!.box.bottom, 1 + 1e-9)
        XCTAssertGreaterThan(stacked.card.box.right - stacked.card.box.left, ScreenPhoneCard.stackedShare)
        XCTAssertEqual(stacked, ScreenPhoneCard.stacked(panel, width: 1600, height: 420, font: 20), "aynı girdi aynı çıktı")
        // Geniş alanda sütun dar kalır, yazı verilen boyda.
        let roomy = ScreenPhoneCard.stacked(panel, width: 1600, height: 1600, font: 20)
        XCTAssertEqual(roomy.card.lineHeight * 1600 * 0.85, 20, accuracy: 1e-9)
        XCTAssertEqual((roomy.card.box.right - roomy.card.box.left) * 1600, 400, accuracy: 1e-6)
        XCTAssertEqual(roomy.messages.count, panel.messages.count)
    }

    /// Günlük: okunan satırların türü ve ilk sözcükleri; özet değişince, en çok 5 sn'de bir.
    func testRowSummaryAndRateLimit() {
        func group(_ text: String, _ role: ScreenPhoneCard.Role) -> ScreenTranslation.Group {
            var group = ScreenTranslation.Group(paragraphs: [text], box: TextBox(left: 0, top: 0, right: 1, bottom: 0.1), lineHeight: 0.02)
            group.phone = ScreenPhoneCard.Placement(role: role, spot: TextBox(left: 0, top: 0, right: 1, bottom: 0.1))
            return group
        }
        let groups = [group("Linda", .header), group("I saw you with our guest from room 10.", .incoming),
                      group("Thanks for the heads up.", .option), group("New messages", .note)]
        XCTAssertEqual(PhoneChat.rowSummary(groups),
                       "header: Linda | bubble: I saw you with… | option: Thanks for the heads… | note: New messages")
        let log = PhoneRowsLog()
        XCTAssertEqual(log.line(groups, now: 1_000), "telefon satırları: " + PhoneChat.rowSummary(groups))
        XCTAssertNil(log.line(groups, now: 20_000), "aynı özet yinelenmez")
        XCTAssertNil(log.line(Array(groups.prefix(2)), now: 2_000), "5 sn dolmadan yazılmaz")
        XCTAssertNotNil(log.line(Array(groups.prefix(2)), now: 7_000))
        XCTAssertNil(log.line([], now: 30_000))
    }
}
