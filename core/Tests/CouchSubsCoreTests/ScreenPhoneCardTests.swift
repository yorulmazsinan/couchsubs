// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// "Ekranı çevir": stil eşleşmeli yerinde çizim, GTA 6 telefon kartı ve yeniden basınca ekranın değişip değişmediği.
/// Telefonun satır kuralları ortak deneme dosyasından (Fixtures/phone-chat.json; Windows ScreenPhoneCardTests.cs ve
/// Android ScreenPhoneCardTest.kt aynı dosyayı okur).
final class ScreenPhoneCardTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Case: Decodable { let name: String; let pose: [Double]; let aspect: Double; let lines: [Line]; let groups: [[String]] }
        struct Outside: Decodable {
            struct Entry: Decodable { let box: [Double]; let inside: Bool }
            let pose: [Double]; let aspect: Double; let boxes: [Entry]
        }
        struct Flat: Decodable { let pose: [Double]; let aspect: Double; let box: [Double]; let flat: [Double] }
        struct Card: Decodable { let phone: [Double]; let card: [Double]; let avoid: [[Double]]? }
        let cases: [Case]
        let outside: Outside
        let flat: [Flat]
        let cards: [Card]
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-chat.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func handset(_ pose: [Double], _ aspect: Double = 16.0 / 9) -> ScreenPhoneCard.Handset {
        ScreenPhoneCard.Handset(pose: GamePhoneGeometry.Pose(topX: pose[0], topY: pose[1], bottomX: pose[2], bottomY: pose[3]),
                                aspect: aspect)
    }

    private func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    func testSharedChatVectors() throws {
        for vector in try vectors().cases {
            let phone = handset(vector.pose, vector.aspect)
            let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: box($0.box)) })
            let groups = ScreenTranslation.groups(reading, wholeScreen: true, handset: phone)
            XCTAssertEqual(groups.compactMap { $0.phone.map { [$0.role.rawValue] } }.count, groups.count, vector.name)
            XCTAssertEqual(groups.map { [$0.phone!.role.rawValue, $0.paragraphs.joined(separator: "\n")] }, vector.groups, vector.name)
        }
    }

    func testSharedEdgeAndFlatVectors() throws {
        let all = try vectors()
        let phone = handset(all.outside.pose, all.outside.aspect)
        for entry in all.outside.boxes {
            XCTAssertEqual(PhoneChat.onScreen(phone.flat(box(entry.box))), entry.inside, "\(entry.box)")
        }
        for entry in all.flat {
            let spot = handset(entry.pose, entry.aspect).flat(box(entry.box))
            XCTAssertEqual(spot.left, entry.flat[0], accuracy: 0.02, "\(entry)")
            XCTAssertEqual(spot.right, entry.flat[2], accuracy: 0.02, "\(entry)")
            XCTAssertEqual((spot.top + spot.bottom) / 2, (entry.flat[1] + entry.flat[3]) / 2, accuracy: 0.006, "\(entry)")
            XCTAssertEqual(spot.bottom - spot.top, entry.flat[3] - entry.flat[1], accuracy: 0.012, "\(entry)")
        }
        for entry in all.cards {
            let card = ScreenPhoneCard.cardBox(box(entry.phone), avoiding: (entry.avoid ?? []).map(box))
            for (a, b) in zip([card.left, card.top, card.right, card.bottom], entry.card) { XCTAssertEqual(a, b, accuracy: 1e-9) }
        }
    }

    private let upright = [0.78, 0.17, 0.78, 0.85]

    private func item(_ source: String, _ translation: String, role: ScreenPhoneCard.Role, top: Double,
                      left: Double = 0.1, right: Double = 0.7, unchanged: Bool = false) -> ScreenTranslation.Item {
        var item = ScreenTranslation.Item(source: source, translation: translation,
                                          box: TextBox(left: 0.8, top: 0.2 + top * 0.6, right: 0.9, bottom: 0.22 + top * 0.6),
                                          lineHeight: 0.018)
        item.unchanged = unchanged
        item.phone = ScreenPhoneCard.Placement(role: role, spot: TextBox(left: left, top: top, right: right, bottom: top + 0.03))
        return item
    }

    /// Kartsız (varsayılan ayar): her mesajın çevirisi kendi balonunun yerinde, kart zemini yok; kişi adı çevrilmediği
    /// için özgün hâli görünür kalır; telefon dışındaki yazı balon sayılmaz.
    /// Sinan Bey (beta.100, 3399): Mesajlar listesinde her ad ve önizleme ayrı hap olarak dağınıktı. Her satır tek kart
    /// (kalın ad + altında önizleme + avatar/rozet/seçim yerleri), kartın üstü adın İngilizcesiyle aynı hizada, boyu en az
    /// telefondaki satır kadar; kartlar üst üste binmez; bölüm başlığı küçük başlık (not) kalır. Kartlar telefonun boş
    /// tarafında (telefon sağdaysa solunda, soldaysa sağında). Aynı içerik birebir aynı çıktı (#1279).
    func testMessageListRowsBecomeOneAlignedCardEach() {
        func list(_ pose: [Double]) -> (items: [ScreenTranslation.Item], phone: ScreenPhoneCard.Handset) {
            let phone = handset(pose)
            var items = [item("Suggested", "Önerilen", role: .heading, top: 0.04),
                         item("Cal", "Cal", role: .contact, top: 0.10, unchanged: true),
                         item("$ in your mailbox. You bailed", "$ posta kutunda. Beni yine...", role: .preview, top: 0.14),
                         item("Brian", "Brian", role: .contact, top: 0.22, unchanged: true),
                         item("Ok. There's some cash in t...", "Tamam. Biraz para var...", role: .preview, top: 0.26),
                         item("Messages", "Mesajlar", role: .heading, top: 0.33),
                         item("Donnie", "Donnie", role: .contact, top: 0.40, unchanged: true)]
            items[2].style = PhoneTextStyle(background: "#F6F2EE", foreground: "#2A2A2A")
            return (items, phone)
        }
        let (items, phone) = list(upright)
        let laid = ScreenPhoneCard.layout(items, handset: phone)
        XCTAssertEqual(laid, ScreenPhoneCard.layout(items, handset: phone), "aynı içerik birebir aynı çıktı")
        let parts = laid.filter { $0.panel != .card }
        XCTAssertEqual(parts.map(\.panel), [.note, .row, .row, .note, .row])
        XCTAssertEqual(parts.compactMap(\.listRow).map(\.name), ["Cal", "Brian", "Donnie"])
        XCTAssertEqual(parts.compactMap(\.listRow).map(\.preview), ["$ posta kutunda. Beni yine...", "Tamam. Biraz para var...", ""])
        XCTAssertEqual(parts[1].translation, "Cal\n$ posta kutunda. Beni yine...", "eski TV için ad ve önizleme iki satır")
        XCTAssertEqual(parts[1].style, PhoneTextStyle(background: "#F6F2EE", foreground: "#2A2A2A"), "telefonun satır kartı rengi")
        XCTAssertEqual(parts[2].style, ScreenPhoneCard.rowColor, "örnek yoksa yedek satır rengi")
        XCTAssertEqual(parts[0].look?.bold, true)
        // Hizalı: kartın üstü adın İngilizcesinin hizasında; boyu en az telefondaki satır (ad + önizleme) kadar.
        let line = laid.first { $0.panel == .card }!.lineHeight
        // (Bu dar denemede üstteki başlık kartı en az kaydırmayla iter; kart hizasından yukarı çıkmaz.)
        XCTAssertGreaterThanOrEqual(parts[1].box.top, ScreenPhoneCard.alignedTop(items[1], line: line) - 1e-9)
        XCTAssertEqual(parts[1].box.top, parts[0].box.bottom + line * ScreenPhoneCard.bubbleSpacing, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(parts[1].box.bottom - parts[1].box.top, items[2].box.bottom - items[1].box.top)
        for (upper, lower) in zip(parts, parts.dropFirst()) { XCTAssertLessThanOrEqual(upper.box.bottom, lower.box.top + 1e-9) }
        // Boş taraf: telefon sağda, kartlar solunda; avatarın aranacağı yer telefonun içinde, satırın hizasında.
        XCTAssertTrue(parts.allSatisfy { $0.box.right <= phone.bounds.left + 1e-9 })
        let spot = try! XCTUnwrap(parts[1].listRow?.portraitSpot)
        XCTAssertTrue(spot.left >= phone.bounds.left - 0.05 && spot.right <= phone.bounds.right + 0.05)
        XCTAssertNotNil(parts[1].listRow?.badgeSpot)
        XCTAssertNotNil(parts[1].listRow?.frameSpot)
        // JSON: panel "row", row {name, preview}.
        let json = SubtitleServer.json(parts[1], phone: true)
        XCTAssertEqual(json["panel"] as? String, "row")
        XCTAssertEqual((json["row"] as? [String: Any])?["name"] as? String, "Cal")
        // Telefon solda: kartlar sağında.
        let left = list([0.22, 0.17, 0.22, 0.85])
        XCTAssertTrue(ScreenPhoneCard.layout(left.items, handset: left.phone).filter { $0.panel == .row }
            .allSatisfy { $0.box.left >= left.phone.bounds.right - 1e-9 })
    }

    /// Liste kartının avatarı, rozeti ve seçim çerçevesi kareden okunur (`PhoneListLook`): avatar satır başına bir kez
    /// kesilir (sonraki karelerin gürültüsü gönderiyi değiştirmez), seçim art arda iki okumada değişir; resimler küçük PNG.
    func testListCardImagesAreCutOnceAndSelectionNeedsTwoReads() {
        let phone = handset(upright)
        var items = [item("Cal", "Cal", role: .contact, top: 0.10, unchanged: true),
                     item("$ in your mailbox. You bailed", "$ posta kutunda...", role: .preview, top: 0.14)]
        items[0].box = TextBox(left: 0.80, top: 0.26, right: 0.84, bottom: 0.278)
        items[1].box = TextBox(left: 0.80, top: 0.284, right: 0.90, bottom: 0.302)
        let laid = ScreenPhoneCard.layout(items, handset: phone)
        let row = try! XCTUnwrap(laid.first { $0.panel == .row }?.listRow)
        let frame = try! XCTUnwrap(row.frameSpot), avatar = try! XCTUnwrap(row.portraitSpot)
        let width = 1920, height = 1080
        func inside(_ box: TextBox, _ x: Int, _ y: Int) -> Bool {
            let u = (Double(x) + 0.5) / Double(width), v = (Double(y) + 0.5) / Double(height)
            return u >= box.left && u <= box.right && v >= box.top && v <= box.bottom
        }
        func pixels(selected: Bool, tint: Int) -> (Int, Int) -> TextPainter.RGB {
            { x, y in
                if inside(avatar, x, y) { return (200 + tint, 60, 40) }
                if selected, inside(frame, x, y), abs(Double(y) / Double(height) - (frame.top + frame.bottom) / 2) < 0.004 {
                    return (58, 111, 216)
                }
                return (244, 241, 236)
            }
        }
        let look = PhoneListLook()
        let first = look.apply(laid, width: width, height: height, color: pixels(selected: true, tint: 0))
        let card = try! XCTUnwrap(first.first { $0.panel == .row }?.listRow)
        let picture = try! XCTUnwrap(card.avatar)
        XCTAssertTrue(picture.hasPrefix("data:image/png;base64,"))
        XCTAssertLessThan(picture.count, 12_000, "küçük resim")
        XCTAssertEqual(card.selected, "#3A6FD8")
        XCTAssertNil(card.badge, "düz kart zemininde rozet yok")
        // Sonraki kare: gürültü (renk biraz farklı) avatarı değiştirmez; seçim tek okumada kalkmaz, ikincide kalkar.
        let second = look.apply(laid, width: width, height: height, color: pixels(selected: false, tint: 9))
        XCTAssertEqual(second.first { $0.panel == .row }?.listRow?.avatar, picture)
        XCTAssertEqual(second.first { $0.panel == .row }?.listRow?.selected, "#3A6FD8")
        let third = look.apply(laid, width: width, height: height, color: pixels(selected: false, tint: 9))
        XCTAssertNil(third.first { $0.panel == .row }?.listRow?.selected)
        XCTAssertEqual(PhoneSteady.samePicture(second, second), true)
    }

    func testWithoutTheCardEachMessageStaysOnItsOwnBubble() {
        let phone = handset(upright)
        let outside = ScreenTranslation.Item(source: "Find the car", translation: "Arabayı bul",
                                             box: TextBox(left: 0.30, top: 0.10, right: 0.50, bottom: 0.13), lineHeight: 0.025)
        let incoming = item("Where are you man", "Neredesin adamım", role: .incoming, top: 0.2)
        let outgoing = item("On my way", "Yoldayım", role: .outgoing, top: 0.3, left: 0.6, right: 0.93)
        let items = [outside, item("Brian", "Brian", role: .header, top: 0.06, unchanged: true), incoming, outgoing]
        let shown = ScreenTranslation.present(items, phone: phone, card: false)
        XCTAssertEqual(shown.map(\.translation), ["Arabayı bul", "Neredesin adamım", "Yoldayım"])
        XCTAssertEqual(shown.map(\.bubble), [false, true, true])
        XCTAssertFalse(shown.contains(where: ScreenPhoneCard.isBackdrop))
        XCTAssertEqual(shown[1].box, incoming.box)
        XCTAssertEqual(shown[2].box, outgoing.box)
        XCTAssertEqual(SubtitleServer.json(shown[1])["bubble"] as? Bool, true)
        XCTAssertNil(SubtitleServer.json(shown[0])["bubble"])
    }

    /// Çeviriler balonların üstündeyken sohbet kayınca/değişince ilk yoklamada kalkmaz (elde sallanan telefon, #1253):
    /// durulunca yeniden çevrilir; durulmadan değişmeye devam ederse ikinci yoklamada kalkar. Kartlı izleme gizlemez.
    func testInPlaceTranslationsLeaveOnlyWhenTheChatKeepsChanging() {
        let a = [UInt8](repeating: 40, count: 768), b = [UInt8](repeating: 200, count: 768)
        let c = [UInt8](repeating: 120, count: 768)
        let place = TextBox(left: 0.6, top: 0.2, right: 0.8, bottom: 0.85)
        let inPlace = ScreenPhoneFollow(hidesOnChange: true), card = ScreenPhoneFollow()
        for follow in [inPlace, card] { follow.settled(place, signature: a) }
        XCTAssertEqual(inPlace.step(place, signature: a), .keep)
        XCTAssertEqual(inPlace.step(place, signature: b), .wait)
        XCTAssertEqual(inPlace.step(place, signature: b), .refresh)
        inPlace.settled(place, signature: b)
        XCTAssertEqual(inPlace.step(place, signature: a), .wait)
        XCTAssertEqual(inPlace.step(place, signature: c), .hide)
        XCTAssertEqual(inPlace.step(place, signature: c), .refresh)
        XCTAssertEqual(card.step(place, signature: b), .wait)
        XCTAssertEqual(card.step(place, signature: c), .wait)
        XCTAssertEqual(card.step(place, signature: c), .refresh)
    }

    /// Elde sallanan telefonun izi (#1253): ince ızgarada (hücrenin `subColumns` × `subRows` alt örneği) birkaç örnek
    /// kayan sohbet, hücre ortalaması ve yatay kaydırmalı karşılaştırmayla değişmiş sayılmaz; yeni mesajla kayan sohbet
    /// değişmiş sayılır. Windows ve Android aynı deneme.
    func testSwayingPhoneSignatureStaysTheSame() {
        let width = ReadScheduler.signatureWidth, height = ReadScheduler.signatureHeight
        let fineWidth = width * ScreenPhoneFollow.subColumns, fineHeight = height * ScreenPhoneFollow.subRows
        // Sohbet: 20 ince satırda bir balon (sırayla solda gri, sağda yeşil), balonun ortasında kelimeler.
        func chat(dx: Int, dy: Int) -> [UInt8] {
            (0..<(fineWidth * fineHeight)).map { index in
                let x = index % fineWidth - dx, y = index / fineWidth - dy
                let k = Int((Double(y) / 20).rounded(.down)), r = y - k * 20
                let (left, right, color) = k % 2 == 0 ? (8, 160, 80) : (96, 248, 140)
                guard r >= 4, r < 16, x >= left, x < right else { return 25 }
                return r >= 6 && r < 14 && (x - left) % 32 < 24 ? 200 : UInt8(color)
            }
        }
        let still = ScreenPhoneFollow.average(chat(dx: 0, dy: 0), width: width, height: height)
        for (dx, dy) in [(2, 1), (-4, 1), (6, -1), (3, 0), (-2, -1), (5, 1)] {
            let swayed = ScreenPhoneFollow.average(chat(dx: dx, dy: dy), width: width, height: height)
            XCTAssertLessThanOrEqual(ScreenPhoneFollow.changedShare(still, swayed), ScreenPhoneFollow.changeShare, "\(dx),\(dy)")
        }
        for scroll in [8, 10, 16] {
            let moved = ScreenPhoneFollow.average(chat(dx: 0, dy: -scroll), width: width, height: height)
            XCTAssertGreaterThan(ScreenPhoneFollow.changedShare(still, moved), ScreenPhoneFollow.changeShare, "\(scroll)")
        }
    }

    func testPhoneMessagesBecomeACardBesideThePhone() {
        let phone = handset(upright)
        var outside = ScreenTranslation.Item(source: "Find the car", translation: "Arabayı bul",
                                             box: TextBox(left: 0.30, top: 0.10, right: 0.50, bottom: 0.13), lineHeight: 0.025)
        outside.unchanged = false
        let items = [
            outside,
            item("Brian", "Brian", role: .header, top: 0.06, unchanged: true),
            item("Where are you man", "Neredesin adamım", role: .incoming, top: 0.2),
            item("On my way", "Yoldayım", role: .outgoing, top: 0.3, left: 0.6, right: 0.93),
        ]
        let laid = ScreenTranslation.present(items, phone: phone)
        XCTAssertEqual(laid.first?.translation, "Arabayı bul")
        // Sohbetin üstündeki kişi adı ("Brian") çizilmez (Sinan Bey, beta.100 3400/3402).
        XCTAssertEqual(laid.count, 4)
        XCTAssertFalse(laid.contains { $0.translation == "Brian" })
        let backdrop = laid[1]
        XCTAssertTrue(ScreenPhoneCard.isBackdrop(backdrop))
        XCTAssertEqual(backdrop.box.top, phone.bounds.top)
        XCTAssertEqual(backdrop.box.bottom, phone.bounds.bottom)
        XCTAssertLessThan(backdrop.box.right, phone.bounds.left)
        XCTAssertEqual(laid[2].lineHeight, ScreenPhoneCard.minLine)
        XCTAssertEqual(laid[2].style, ScreenPhoneCard.incomingColor)
        XCTAssertEqual(laid[2].box.left, backdrop.box.left + (backdrop.box.right - backdrop.box.left) * 0.05, accuracy: 1e-9)
        XCTAssertEqual(laid[3].style, ScreenPhoneCard.outgoingColor)
        XCTAssertEqual(laid[3].look?.align, .right)
        XCTAssertEqual(laid[3].box.right, backdrop.box.right - (backdrop.box.right - backdrop.box.left) * 0.05, accuracy: 1e-9)
        // Satırlar üst üste binmez ve kartın içinde kalır.
        for (upper, lower) in zip(laid[2...], laid[3...]) { XCTAssertLessThanOrEqual(upper.box.bottom, lower.box.top) }
        XCTAssertTrue(laid[2...].allSatisfy { $0.box.left >= backdrop.box.left && $0.box.right <= backdrop.box.right
            && $0.box.top >= backdrop.box.top && $0.box.bottom <= backdrop.box.bottom })
    }

    func testFullCardDropsTheOldestMessagesAndKeepsTheNewest() {
        let long = String(repeating: "Bu çok uzun bir mesajın Türkçesi ", count: 4)
        let items = (0..<9).map { index in
            item("message \(index)", "\(index) \(long)", role: index % 2 == 0 ? .incoming : .outgoing, top: 0.1 + Double(index) * 0.09)
        }
        let laid = ScreenPhoneCard.layout(items, handset: handset(upright))
        let card = laid[0].box
        let rows = Array(laid.dropFirst())
        XCTAssertLessThan(rows.count, 9)
        XCTAssertEqual(rows.last?.source, "message 8")
        for (upper, lower) in zip(rows, rows.dropFirst()) { XCTAssertLessThanOrEqual(upper.box.bottom, lower.box.top + 1e-9) }
        XCTAssertLessThanOrEqual(rows.last!.box.bottom, card.bottom)
        XCTAssertGreaterThanOrEqual(rows.first!.box.top, card.top)
    }

    func testAmbiguousBubbleSideComesFromItsColorAndListRowsAreLeftAligned() {
        var blue = item("Sure thing", "Tabii", role: .message, top: 0.2, left: 0.05, right: 0.96)
        blue.style = PhoneTextStyle(background: "#1E6FE0", foreground: "#FFFFFF")
        var gray = item("Ok then", "Peki", role: .message, top: 0.4, left: 0.05, right: 0.96)
        gray.style = PhoneTextStyle(background: "#E5E5EA", foreground: "#000000")
        let laid = ScreenPhoneCard.layout([blue, gray, item("Lucia", "Lucia", role: .contact, top: 0.6, unchanged: true),
                                           item("You coming?", "Geliyor musun?", role: .preview, top: 0.65)], handset: handset(upright))
        // Balon telefondaki balonun renginde (mavi giden, gri gelen); taraf da renkten.
        XCTAssertEqual(laid[1].panel, .mine)
        XCTAssertEqual(laid[1].style, blue.style)
        XCTAssertEqual(laid[2].panel, .theirs)
        XCTAssertEqual(laid[2].style, gray.style)
        // Liste satırı (ad + önizleme) tek kart: sola yaslı, telefonun satır kartı renginde (örnek yoksa yedek).
        XCTAssertEqual(laid.count, 4)
        XCTAssertEqual(laid[3].panel, .row)
        XCTAssertEqual(laid[3].look?.align, .left)
        XCTAssertEqual(laid[3].listRow?.name, "Lucia")
        XCTAssertEqual(laid[3].listRow?.preview, "Geliyor musun?")
        XCTAssertEqual(laid[3].translation, "Lucia\nGeliyor musun?")
        XCTAssertEqual(laid[3].style, ScreenPhoneCard.rowColor)
    }

    /// Hizalı panel (Sinan Bey'in beğendiği görünüm): her Türkçe balon telefondaki İngilizce balonuyla aynı yükseklikte
    /// (üst kenarı ±birkaç piksel), çakışan balon en az kaydırmayla aşağı itilir; balon telefonun balon renginde, giden sağa,
    /// gelen sola yaslı; kişi adı panelin üstünde küçük başlık. Aynı içerik birebir aynı çıktıyı verir.
    func testAlignedPanelPutsEachBubbleAtTheHeightOfItsEnglishBubble() {
        let phone = handset(upright)
        func message(_ source: String, _ translation: String, role: ScreenPhoneCard.Role, top: Double, height: Double,
                     style: PhoneTextStyle?) -> ScreenTranslation.Item {
            var item = item(source, translation, role: role, top: (top - phone.bounds.top) / (phone.bounds.bottom - phone.bounds.top))
            item.box = TextBox(left: 0.72, top: top, right: 0.84, bottom: top + height)
            item.style = style
            return item
        }
        let cream = PhoneTextStyle(background: "#F0E8E0", foreground: "#282828")
        let blue = PhoneTextStyle(background: "#D0D8F0", foreground: "#282828")
        var header = item("Brian", "Brian", role: .header, top: 0.02, unchanged: true)
        header.box = TextBox(left: 0.76, top: 0.24, right: 0.80, bottom: 0.26)
        let items = [header,
                     message("Where are you", "Neredesin", role: .incoming, top: 0.30, height: 0.02, style: cream),
                     message("On my way", "Yoldayım", role: .outgoing, top: 0.42, height: 0.02, style: blue),
                     // Uzun Türkçe: altındaki balonun İngilizcesiyle çakışır, o balon aşağı itilir.
                     message("Bring the stuff", String(repeating: "Malzemeleri getir hemen ", count: 6), role: .incoming,
                             top: 0.50, height: 0.02, style: cream),
                     message("Ok", "Tamam", role: .outgoing, top: 0.53, height: 0.02, style: nil)]
        let laid = ScreenPhoneCard.layout(items, handset: phone)
        XCTAssertEqual(laid, ScreenPhoneCard.layout(items, handset: phone), "aynı içerik birebir aynı çıktı")
        let panel = try! XCTUnwrap(ScreenPhoneCard.panel(laid))
        XCTAssertTrue(panel.aligned)
        XCTAssertEqual(SubtitleServer.json(panel.card, phone: true)["aligned"] as? Bool, true)
        let line = panel.card.lineHeight, pixel = 1.0 / 1080
        let rows = panel.messages
        XCTAssertEqual(rows.map(\.translation).prefix(2), ["Neredesin", "Yoldayım"])
        // Üst kenar hizası: Türkçe balonun yazısı İngilizce yazının üstünde başlar (balon dolgusu kadar yukarıdan).
        for (row, english) in zip(rows.prefix(3), [0.30, 0.42, 0.50]) {
            XCTAssertEqual(row.box.top + line * ScreenPhoneCard.bubblePadding / 2, english, accuracy: 3 * pixel, row.translation)
        }
        // Çakışma: "Tamam" İngilizcesinin yüksekliğinde duramaz, uzun balonun hemen altına (en az kaydırmayla) itilir.
        XCTAssertGreaterThan(rows[3].box.top, ScreenPhoneCard.alignedTop(items[4], line: line))
        XCTAssertEqual(rows[3].box.top, rows[2].box.bottom + line * ScreenPhoneCard.bubbleSpacing, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(panel.card.box.bottom, rows[3].box.bottom, "panel aşağı uzar")
        // Renk: telefonun balonundan; örneği olmayan balon yedek renkte. Gelen sola, giden sağa yaslı.
        XCTAssertEqual(rows[0].style, cream)
        XCTAssertEqual(rows[1].style, blue)
        XCTAssertEqual(rows[3].style, ScreenPhoneCard.outgoingColor)
        XCTAssertLessThan(rows[0].box.left, rows[1].box.left)
        XCTAssertEqual(rows[1].box.right, rows[3].box.right, accuracy: 1e-9)
        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402); balonlar hizalı kalır.
        XCTAssertNil(panel.title)
        XCTAssertFalse(laid.contains { $0.panel == .title || $0.translation == header.translation })
        // Okunmayan örnek (nötr yedek) ve okunmayan yazı rengi: yedek renk ya da zemine göre koyu/açık yazı.
        XCTAssertEqual(ScreenPhoneCard.bubbleColor(GamePhonePalette.neutral, fallback: ScreenPhoneCard.incomingColor),
                       ScreenPhoneCard.incomingColor)
        XCTAssertEqual(ScreenPhoneCard.bubbleColor(PhoneTextStyle(background: "#F0E8E0", foreground: "#E8E0D8"),
                                                   fallback: ScreenPhoneCard.incomingColor).foreground, "#17181B")
    }

    /// Saydam altyazı penceresi (Mac SubtitleOverlay, Windows SubtitleOverlayWindow): hizalı panelin görünümü aynen
    /// (kartsız balonlar, telefonun balon rengi), balonlar alanın telefon tarafındaki kenarında alt alta, sırası ve
    /// aralıklarıyla; yazı alt sınırın altına inmez, küçülmez; aynı içerik birebir aynı çıktı. Windows
    /// ScreenPhoneCardTests.StackedPanel…, Android ScreenPhoneCardTest.stackedPanel… aynı durumlar.
    func testStackedPanelInTheOverlayWindowKeepsTheAlignedLook() {
        func part(_ text: String, _ panel: ScreenPhoneCard.PanelPart, top: Double, bottom: Double,
                  style: PhoneTextStyle? = nil, align: TextLook.Align = .left) -> ScreenTranslation.Item {
            var item = ScreenTranslation.Item(source: text, translation: text, box: TextBox(left: 0.72, top: top, right: 0.9, bottom: bottom),
                                              lineHeight: 0.03)
            item.panel = panel
            item.style = style
            item.look = TextLook(bold: false, condensed: false, align: align, upper: false, flat: true)
            return item
        }
        let cream = PhoneTextStyle(background: "#F0E8E0", foreground: "#282828")
        var card = part(ScreenPhoneCard.backdropText, .card, top: 0.2, bottom: 0.8)
        card.aligned = true
        let items = [card,
                     part("Brian", .title, top: 0.2, bottom: 0.24),
                     part("Neredesin", .theirs, top: 0.30, bottom: 0.36, style: cream),
                     // Boşluk 0,6 satır (0,018): saydam pencerede de 0,6 satır kalır.
                     part("Yoldayım", .mine, top: 0.378, bottom: 0.438, style: nil, align: .right),
                     // Okunmayan yazı rengi: zemine göre koyu yazı.
                     part("Tamam", .theirs, top: 0.6, bottom: 0.66, style: PhoneTextStyle(background: "#F0E8E0", foreground: "#E8E0D8"))]
        let panel = ScreenPhoneCard.panel(items)!
        let stacked = ScreenPhoneCard.stacked(panel, width: 1600, height: 400, font: 20)
        XCTAssertEqual(stacked, ScreenPhoneCard.stacked(ScreenPhoneCard.panel(items)!, width: 1600, height: 400, font: 20),
                       "aynı içerik birebir aynı çıktı")
        // Kartsız: hizalı panel olarak çizilir (zemin ve simge yok, her parça kendi kutusunda).
        XCTAssertTrue(stacked.aligned)
        let line = stacked.card.lineHeight
        XCTAssertEqual(line * 400 * 0.85, 20, accuracy: 1e-9, "yazı boyu verilen boyda")
        // Telefon sağda: sütun alanın sağ kenarında; en çok alanın %45'i ve yazı boyunun 20 katı.
        XCTAssertEqual(stacked.card.box.right, 1, accuracy: 1e-9)
        XCTAssertEqual((stacked.card.box.right - stacked.card.box.left) * 1600, 400, accuracy: 1e-6)
        let rows = stacked.messages
        XCTAssertEqual(rows.map(\.translation), ["Neredesin", "Yoldayım", "Tamam"])
        // Gelen sola, giden sağa yaslı; sırası ve aralığı korunur.
        XCTAssertEqual(rows[0].box.left, stacked.card.box.left, accuracy: 1e-9)
        XCTAssertEqual(rows[1].box.right, 1, accuracy: 1e-9)
        XCTAssertEqual(rows[1].box.top - rows[0].box.bottom, 0.6 * line, accuracy: 1e-9)
        XCTAssertEqual(rows[2].box.top - rows[1].box.bottom, ScreenPhoneCard.stackedGapMax * line, accuracy: 1e-9,
                       "uzak balonlar arası boşluk sınırlı")
        let title = stacked.title!
        XCTAssertEqual(title.box.top, 0)
        XCTAssertLessThan(title.box.bottom, rows[0].box.top)
        // Renk: telefonun balonundan; örneği yoksa yedek; yazı okunmuyorsa koyu yazı.
        XCTAssertEqual(rows[0].style, cream)
        XCTAssertEqual(rows[1].style, ScreenPhoneCard.outgoingColor)
        XCTAssertEqual(rows[2].style?.foreground, "#17181B")
        // Telefon solda: sütun sol kenarda, giden balon sütunun sağında.
        var leftItems = items
        leftItems[0].box = TextBox(left: 0.1, top: 0.2, right: 0.3, bottom: 0.8)
        let left = ScreenPhoneCard.stacked(ScreenPhoneCard.panel(leftItems)!, width: 1600, height: 400, font: 20)
        XCTAssertEqual(left.card.box.left, 0)
        XCTAssertEqual(left.messages[1].box.right, left.card.box.right, accuracy: 1e-9)
        // Punto alt sınırı: küçük altyazıda yazı 13 pikselin altına inmez.
        let tiny = ScreenPhoneCard.stacked(panel, width: 1600, height: 400, font: 6)
        XCTAssertEqual(tiny.card.lineHeight * 400 * 0.85, ScreenPhoneCard.stackedMinFont, accuracy: 1e-9)
        // Alan dolarsa yazı küçülmez, en eski mesajlar düşer; son mesaj görünür.
        let short = ScreenPhoneCard.stacked(panel, width: 1600, height: 90, font: 20)
        XCTAssertEqual(short.card.lineHeight * 90 * 0.85, 20, accuracy: 1e-9)
        XCTAssertEqual(short.messages.last?.translation, "Tamam")
        XCTAssertLessThan(short.messages.count, 3)
        XCTAssertLessThanOrEqual(short.messages.last!.box.bottom, 1 + 1e-9)
    }

    /// Telefonun ana ekranı sohbet değildir; uygulama adı ("WhatUp") çevrilmez. Bileşen (başlık + sayaç: "Reminders /
    /// 10 Notifications") telefonun boş tarafında tek kart olur (Sinan Bey, beta.100 3397: bileşen çevrilmiyordu): kalın
    /// başlık, altında sayaç, kartın üstü bileşenin İngilizcesiyle aynı hizada; telefonun üstüne yazılmaz.
    func testHomeScreenWidgetBecomesOneCardBesideThePhone() async throws {
        let vector = try XCTUnwrap(try vectors().cases.first { $0.name.hasPrefix("ana ekran: bildirim") })
        let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: box($0.box)) })
        let phone = handset(vector.pose, vector.aspect)
        let groups = ScreenTranslation.groups(reading, wholeScreen: true, handset: phone)
        var items: [ScreenTranslation.Item] = []
        for group in groups {
            let translated = group.paragraphs.map { ["Reminders": "Hatırlatıcılar", "10 Notifications": "10 Bildirim"][$0]! }
            if let item = ScreenTranslation.item(group, group.paragraphs.map(IconText.protect), translated, keepUnchanged: true) {
                items.append(item)
            }
        }
        let shown = ScreenTranslation.present(items, phone: phone)
        XCTAssertEqual(shown, ScreenTranslation.present(items, phone: phone), "aynı içerik birebir aynı çıktı")
        let cards = shown.filter { $0.panel == .row }
        XCTAssertEqual(cards.count, 1)
        let widget = try XCTUnwrap(cards.first?.listRow)
        XCTAssertTrue(widget.widget)
        XCTAssertEqual(widget.name, "Hatırlatıcılar")
        XCTAssertEqual(widget.preview, "10 Bildirim")
        XCTAssertNotNil(widget.portraitSpot, "bileşenin simgesi kesilir")
        let card = try XCTUnwrap(cards.first)
        XCTAssertTrue(card.box.right <= phone.bounds.left + 1e-9 || card.box.left >= phone.bounds.right - 1e-9, "kart telefonun yanında")
        let english = try XCTUnwrap(groups.first).box.top
        XCTAssertEqual(card.box.top, ScreenPhoneCard.alignedTop(items[0], line: card.lineHeight), accuracy: 1e-9)
        XCTAssertLessThan(abs(card.box.top - english), 0.03, "kart bileşenin hizasında")
        XCTAssertEqual(SubtitleServer.json(card, phone: true)["panel"] as? String, "row")
        let row = try XCTUnwrap(SubtitleServer.json(card, phone: true)["row"] as? [String: Any])
        XCTAssertEqual(row["widget"] as? Bool, true)
        XCTAssertEqual(row["name"] as? String, "Hatırlatıcılar")
    }

    /// Otomatik telefon panelinde (`GamePhoneText.groups`, satırların yeri düz ekranda) da ana ekranın uygulama adları ve
    /// saat/hava çevrilmez; bileşen ve bildirim yazıları kendi yerinde kalır. Sohbet satırları olduğu gibi kalır (ortak
    /// deneme dosyasının `panels` bölümü; Windows ve Android aynı dosyayı okur).
    func testAutomaticPanelSkipsAppNamesOnTheHomeScreen() throws {
        struct Panel: Decodable {
            struct Line: Decodable { let text: String; let box: [Double] }
            let name: String; let lines: [Line]; let groups: [String]
        }
        struct File: Decodable { let panels: [Panel] }
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-chat.json")
        for panel in try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).panels {
            let reading = Reading(lines: panel.lines.map { line in
                var text = TextLine(line.text, box: box(line.box))
                text.phoneBox = box(line.box)
                return text
            })
            XCTAssertEqual(GamePhoneText.groups(reading).map { $0.paragraphs.joined(separator: "\n") }, panel.groups, panel.name)
        }
    }

    /// Sohbetin son kısa yanıtı ("Ok") ana ekran sayılmaz; sohbet yine kart olur.
    func testShortChatReplyIsNotAHomeScreen() throws {
        let vector = try vectors().cases[0]
        var lines = vector.lines.map { TextLine($0.text, box: box($0.box)) }
        lines.append(TextLine("Ok", box: TextBox(left: 0.84, top: 0.60, right: 0.86, bottom: 0.617)))
        let groups = ScreenTranslation.groups(Reading(lines: lines), wholeScreen: true, handset: handset(vector.pose))
        XCTAssertFalse(groups.contains { $0.phone?.role == .home })
        XCTAssertEqual(groups.first?.phone?.role, .header)
    }

    func testCardGoesRightWhenThePhoneIsOnTheLeft() {
        let left = handset([0.20, 0.17, 0.20, 0.85])
        let laid = ScreenPhoneCard.layout([item("Where are you man", "Neredesin adamım", role: .incoming, top: 0.3)], handset: left)
        XCTAssertGreaterThan(laid[0].box.left, left.bounds.right)
    }

    func testWithoutATranslatedPhoneTextNothingMovesAndUnchangedItemsAreDropped() {
        var outside = ScreenTranslation.Item(source: "Find the car", translation: "Arabayı bul",
                                             box: TextBox(left: 0.30, top: 0.10, right: 0.50, bottom: 0.13), lineHeight: 0.025)
        outside.unchanged = false
        let items = [item("Donnie", "Donnie", role: .header, top: 0.06, unchanged: true), outside]
        XCTAssertEqual(ScreenTranslation.present(items, phone: handset(upright)).map(\.translation), ["Arabayı bul"])
        XCTAssertEqual(ScreenTranslation.present(items, phone: nil).map(\.translation), ["Arabayı bul"])
    }

    /// Telefondaki kişi adı çevirmene gitmez ("Rose" → "Gül" olmasın); mesajlar gider.
    func testContactNamesAreNotSentToTheTranslator() async throws {
        let vector = try vectors().cases[0]
        let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: box($0.box)) })
        let groups = ScreenTranslation.groups(reading, wholeScreen: true, handset: handset(vector.pose))
        XCTAssertEqual(ScreenTranslation.known("Brian", in: groups[0]), "Brian")
        XCTAssertNil(ScreenTranslation.known("Will do", in: groups.last))
    }

    /// Çeviriler artık özgün yazının stilinde: koyu kutudaki beyaz yazı koyu zeminde beyaz, BÜYÜK HARF yazı büyük harf.
    func testTranslationsTakeTheLookOfTheOriginalText() async throws {
        let frame = TextStyleSamplerTests.text((20, 22, 30), (240, 240, 240), stroke: 2)
        let box = TextBox(left: 0, top: 10.0 / 60, right: 1, bottom: 50.0 / 60)
        let items = try await ScreenTranslation.translate(Reading(lines: [TextLine("SCROLL THE LIST", box: box)]),
                                                          using: { _ in "listeyi kaydır" }, frame: frame)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].style?.background, "#14161E")
        XCTAssertEqual(items[0].look?.upper, true)
        XCTAssertEqual(items[0].translation, "LİSTEYİ KAYDIR")
        // TV'ye stiliyle gider.
        let json = SubtitleServer.json(items[0])
        XCTAssertNotNil(json["surface"])
        XCTAssertNotNil(json["style"])
    }

    private struct Shared: Decodable {
        struct Layout: Decodable {
            struct Message: Decodable {
                let role: String; let source: String; let translation: String; let top: Double; let left: Double
                let right: Double; let line: Double; let unchanged: Bool
                /// İngilizce balonun karedeki kutusu (hizalı panel bu yüksekliğe dizer).
                let box: [Double]?
            }
            struct Outside: Decodable { let source: String; let translation: String; let box: [Double] }
            let name: String; let pose: [Double]; let items: [Message]; let outside: [Outside]?
            let card: [Double]?; let kept: [String]?; let moved: [[Double]]?
        }
        struct Follow: Decodable {
            struct Step: Decodable { let settle: [Double]?; let phone: [Double]?; let sig: [Int]?; let expect: String? }
            let name: String; let steps: [Step]; let hides: Bool?
        }
        struct Switch: Decodable { let chats: [String]; let calls: [Int] }
        let layouts: [Layout]; let follow: [Follow]; let `switch`: Switch
    }

    private func shared() throws -> Shared {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-chat.json")
        return try JSONDecoder().decode(Shared.self, from: Data(contentsOf: url))
    }

    /// Sıkışık balonlar: balonlar arasında en az yarım satır boşluk, hepsi kartın içinde; mesajlar telefon boyuna
    /// sığmazsa kart ekranın kenar payına kadar uzar, yine sığmazsa en eskiler düşer; kartın altında kalan çeviri kartın
    /// yanına alınır (ortak deneme dosyasının `layouts` bölümü; Windows ve Android aynı sonucu bulur).
    func testSharedLayoutVectors() throws {
        for vector in try shared().layouts {
            let phone = handset(vector.pose)
            var items = (vector.outside ?? []).map { entry -> ScreenTranslation.Item in
                var item = ScreenTranslation.Item(source: entry.source, translation: entry.translation, box: box(entry.box), lineHeight: 0.02)
                item.unchanged = false
                return item
            }
            items += vector.items.map { message in
                var item = ScreenTranslation.Item(source: message.source, translation: message.translation,
                                                  box: message.box.map(box) ?? TextBox(left: 0.8, top: 0.2, right: 0.9, bottom: 0.22),
                                                  lineHeight: message.line)
                item.unchanged = message.unchanged
                item.phone = ScreenPhoneCard.Placement(role: ScreenPhoneCard.Role(rawValue: message.role)!,
                                                       spot: TextBox(left: message.left, top: message.top, right: message.right,
                                                                     bottom: message.top + 0.03))
                return item
            }
            let laid = ScreenPhoneCard.layout(items, handset: phone)
            let outsideCount = vector.outside?.count ?? 0
            let card = laid[outsideCount].box
            XCTAssertTrue(ScreenPhoneCard.isBackdrop(laid[outsideCount]), vector.name)
            let rows = laid[(outsideCount + 1)...].filter { $0.phone?.role != .header }
            let line = rows.first!.lineHeight
            for (upper, lower) in zip(rows, rows.dropFirst()) {
                XCTAssertGreaterThanOrEqual(lower.box.top - upper.box.bottom, line * 0.5 - 1e-9, vector.name)
                // Hizalı: balon İngilizce balonunun yüksekliğinde; çakışırsa üsttekinin altına en az kaydırmayla itilir
                // (ekranın alt payına dayanmış panelde satırlar alttan yukarı itilir).
                let wanted = ScreenPhoneCard.alignedTop(items.first { $0.source == lower.source }!, line: line)
                if rows.last!.box.bottom < 1 - ScreenPhoneCard.screenMargin - 1e-9 {
                    XCTAssertEqual(lower.box.top, max(wanted, upper.box.bottom + line * ScreenPhoneCard.bubbleSpacing),
                                   accuracy: 1e-9, vector.name)
                }
            }
            XCTAssertTrue(laid[outsideCount].aligned, vector.name)
            XCTAssertTrue(laid[(outsideCount + 1)...].allSatisfy { $0.box.left >= card.left && $0.box.right <= card.right
                && $0.box.top >= card.top - 1e-9 && $0.box.bottom <= card.bottom + 1e-9 }, vector.name)
            XCTAssertGreaterThanOrEqual(card.top, ScreenPhoneCard.screenMargin - 1e-9, vector.name)
            XCTAssertLessThanOrEqual(card.bottom, 1 - ScreenPhoneCard.screenMargin + 1e-9, vector.name)
            XCTAssertEqual(rows.last?.source, vector.items.last?.source, vector.name)
            for index in 0..<outsideCount { XCTAssertEqual(ScreenPhoneCard.covered(laid[index].box, [card]), 0, vector.name) }
            if let expected = vector.card {
                for (a, b) in zip([card.left, card.top, card.right, card.bottom], expected) { XCTAssertEqual(a, b, accuracy: 1e-6, vector.name) }
            }
            if let kept = vector.kept { XCTAssertEqual(rows.map(\.source), kept, vector.name) }
            if let moved = vector.moved {
                for (index, expected) in moved.enumerated() {
                    let got = laid[index].box
                    for (a, b) in zip([got.left, got.top, got.right, got.bottom], expected) { XCTAssertEqual(a, b, accuracy: 1e-6, vector.name) }
                }
            }
        }
    }

    /// Kart ekrandayken telefon izlenir: sohbet değişip durulunca yeniden çevrilir, değişmeyen telefonda kart kalır,
    /// telefon kapanınca kart kalkar; tek karelik ıska kartı kaldırmaz (ortak deneme dosyasının `follow` bölümü).
    func testSharedFollowVectors() throws {
        // [taban, sayı, değer] ya da [taban, sayı, değer, şerit, kayma]: ilk `sayı` örnek `değer`, gerisi `taban`; şerit
        // verilirse 64 sütunluk izde `şerit` genişliğinde, `kayma` sütun sağa kaymış dikey şeritler de `değer`.
        func signature(_ spec: [Int]) -> [UInt8] {
            (0..<768).map { index in
                if index < spec[1] { return UInt8(spec[2]) }
                if spec.count >= 5, spec[3] > 0, ((index % 64 - spec[4] + 64) / spec[3]) % 2 == 1 { return UInt8(spec[2]) }
                return UInt8(spec[0])
            }
        }
        for vector in try shared().follow {
            let follow = ScreenPhoneFollow(hidesOnChange: vector.hides ?? false)
            for (index, step) in vector.steps.enumerated() {
                if let settle = step.settle {
                    follow.settled(box(settle), signature: signature(step.sig!))
                    continue
                }
                let got = follow.step(step.phone.map(box), signature: step.phone == nil ? nil : signature(step.sig!))
                XCTAssertEqual(got.rawValue, step.expect, "\(vector.name) #\(index)")
            }
        }
    }

    /// Başka bir sohbete geçip dönünce eski sohbetin mesajları çevirmene yeniden gitmez: çeviriler sohbetin başlığıyla
    /// saklanır (`PhoneChatMemory`; ortak deneme dosyasının `switch` bölümü).
    func testSwitchingChatsReusesTheirTranslations() async throws {
        let all = try vectors().cases
        let plan = try shared().switch
        let memory = PhoneChatMemory()
        var first: [String: [String]] = [:]
        for (name, expected) in zip(plan.chats, plan.calls) {
            let vector = try XCTUnwrap(all.first { $0.name == name })
            let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: box($0.box)) })
            var calls = 0
            let items = try await ScreenTranslation.translate(reading, using: { text in
                calls += 1
                return "TR " + text
            }, memory: memory, handset: handset(vector.pose, vector.aspect))
            XCTAssertEqual(calls, expected, name)
            let texts = items.map(\.translation)
            if let before = first[name] { XCTAssertEqual(texts, before, name) } else { first[name] = texts }
        }
    }

    /// Başka bir sohbete geçince ekranın izi değişir: tuşa yeniden basmak yeni sohbeti çevirir, çevirileri kaldırmaz.
    func testAnotherChatIsADifferentScreen() {
        func screen(_ lines: [String]) -> String {
            ScreenTranslation.fingerprint(Reading(lines: lines.enumerated().map { index, text in
                TextLine(text, box: TextBox(left: 0.74, top: 0.35 + Double(index) * 0.08, right: 0.94, bottom: 0.38 + Double(index) * 0.08))
            }))
        }
        let donnie = screen(["Donnie", "Where are you man", "Meet me at the docks"])
        let again = screen(["Donnie", "Where are you man", "Meet me at the docks"])
        let misread = screen(["Donnie", "Where are you rnan", "Meet me at the docks"])
        let lucia = screen(["Lucia", "Did you get the money", "Call me back"])
        let newMessage = screen(["Donnie", "Where are you man", "Meet me at the docks", "Hurry up"])
        XCTAssertTrue(ScreenTranslation.isSameScreen(donnie, again))
        XCTAssertTrue(ScreenTranslation.isSameScreen(donnie, misread))
        XCTAssertFalse(ScreenTranslation.isSameScreen(donnie, lucia))
        XCTAssertFalse(ScreenTranslation.isSameScreen(donnie, newMessage))
        XCTAssertTrue(ScreenTranslation.isSameScreen("", ""))
        XCTAssertFalse(ScreenTranslation.isSameScreen("", donnie))
    }

    /// Telefonun ekranındaki satırlar altyazı hattına girmez; telefonun önünden/altından geçen geniş altyazı girer
    /// (gerçek kare gta6-telefon-sohbet-2'nin telefonu; X, beta.79: bütün sohbet ortada tek satır).
    func testHoldsOnlyTheLinesOnThePhoneScreen() {
        let phone = handset([0.50375, 0.12444, 0.46125, 0.68444])
        XCTAssertTrue(ScreenPhoneCard.holds(box([0.39415, 0.47436, 0.54888, 0.52616]), handset: phone)) // Kingfishers a message. Hit
        XCTAssertTrue(ScreenPhoneCard.holds(box([0.47965, 0.17571, 0.5218, 0.19897]), handset: phone)) // Donnie
        // Telefonun alt gövdesi örtülü, telefon kısa bulundu: son mesaj yine telefonun.
        XCTAssertTrue(ScreenPhoneCard.holds(box([0.3974, 0.74924, 0.4632, 0.79995]), handset: phone)) // Locating...
        XCTAssertFalse(ScreenPhoneCard.holds(box([0.30, 0.86, 0.70, 0.91]), handset: phone)) // telefonun önündeki altyazı
        XCTAssertFalse(ScreenPhoneCard.holds(box([0.46, 0.90, 0.54, 0.94]), handset: phone)) // telefonun altındaki kısa altyazı
        XCTAssertFalse(ScreenPhoneCard.holds(box([0.949, 0.93197, 0.99577, 0.95692]), handset: phone)) // SCROLL
    }
}
