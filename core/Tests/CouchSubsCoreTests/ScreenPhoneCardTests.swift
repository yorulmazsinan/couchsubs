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

    /// Çeviriler balonların üstündeyken sohbet kayınca/değişince ilk yoklamada kalkar (`hide`), durulunca yeniden
    /// çevrilir; kartlı izleme eskisi gibi bekler.
    func testInPlaceTranslationsLeaveAsSoonAsTheChatMoves() {
        let a = [UInt8](repeating: 40, count: 768), b = [UInt8](repeating: 200, count: 768)
        let place = TextBox(left: 0.6, top: 0.2, right: 0.8, bottom: 0.85)
        let inPlace = ScreenPhoneFollow(hidesOnChange: true), card = ScreenPhoneFollow()
        for follow in [inPlace, card] { follow.settled(place, signature: a) }
        XCTAssertEqual(inPlace.step(place, signature: a), .keep)
        XCTAssertEqual(inPlace.step(place, signature: b), .hide)
        XCTAssertEqual(inPlace.step(place, signature: b), .refresh)
        XCTAssertEqual(card.step(place, signature: b), .wait)
        XCTAssertEqual(card.step(place, signature: b), .refresh)
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
        XCTAssertEqual(laid.count, 5)
        let backdrop = laid[1]
        XCTAssertTrue(ScreenPhoneCard.isBackdrop(backdrop))
        XCTAssertEqual(backdrop.box.top, phone.bounds.top)
        XCTAssertEqual(backdrop.box.bottom, phone.bounds.bottom)
        XCTAssertLessThan(backdrop.box.right, phone.bounds.left)
        // Kişi adı çevrilmese de kartın başlığıdır: ortalı, kalın; yazı TV'de okunacak boyda.
        XCTAssertEqual(laid[2].translation, "Brian")
        XCTAssertEqual(laid[2].look?.align, .center)
        XCTAssertEqual(laid[2].look?.bold, true)
        XCTAssertEqual(laid[2].lineHeight, ScreenPhoneCard.minLine)
        XCTAssertEqual(laid[3].style, ScreenPhoneCard.incomingColor)
        XCTAssertEqual(laid[3].box.left, backdrop.box.left + (backdrop.box.right - backdrop.box.left) * 0.05, accuracy: 1e-9)
        XCTAssertEqual(laid[4].style, ScreenPhoneCard.outgoingColor)
        XCTAssertEqual(laid[4].look?.align, .right)
        XCTAssertEqual(laid[4].box.right, backdrop.box.right - (backdrop.box.right - backdrop.box.left) * 0.05, accuracy: 1e-9)
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
        XCTAssertEqual(laid[1].style, ScreenPhoneCard.outgoingColor)
        XCTAssertEqual(laid[2].style, ScreenPhoneCard.incomingColor)
        XCTAssertEqual(laid[3].look?.bold, true)
        XCTAssertEqual(laid[3].look?.align, .left)
        XCTAssertEqual(laid[4].style, ScreenPhoneCard.cardColor)
    }

    /// Telefonun ana ekranı sohbet değildir: kart kurulmaz, bileşenin yazıları kendi yerinde kalır, uygulama adı ("WhatUp")
    /// çevrilmez. Önceden ana ekran sohbet kartı sayılıyor, "Hatırlatıcılar / 10 Bildirim / Ne haber!" telefonun yanında
    /// tek blok oluyordu (X'teki bildirim).
    func testHomeScreenIsTranslatedInPlaceWithoutACard() async throws {
        let vector = try XCTUnwrap(try vectors().cases.first { $0.name.hasPrefix("ana ekran: bildirim") })
        let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: box($0.box)) })
        let phone = handset(vector.pose, vector.aspect)
        let groups = ScreenTranslation.groups(reading, wholeScreen: true, handset: phone)
        var items: [ScreenTranslation.Item] = []
        for group in groups {
            let translated = ["Reminders": "Hatırlatıcılar", "10 Notifications": "10 Bildirim"][group.paragraphs[0]]!
            if let item = ScreenTranslation.item(group, group.paragraphs.map(IconText.protect), [translated], keepUnchanged: true) {
                items.append(item)
            }
        }
        let shown = ScreenTranslation.present(items, phone: phone)
        XCTAssertEqual(shown.map(\.translation), ["Hatırlatıcılar", "10 Bildirim"])
        XCTAssertFalse(shown.contains(where: ScreenPhoneCard.isBackdrop))
        for (item, group) in zip(shown, groups) { XCTAssertEqual(item.box, group.box) }
        XCTAssertTrue(shown.allSatisfy { $0.box.left >= phone.bounds.left && $0.box.right <= phone.bounds.right })
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
            }
            struct Outside: Decodable { let source: String; let translation: String; let box: [Double] }
            let name: String; let pose: [Double]; let items: [Message]; let outside: [Outside]?
            let card: [Double]?; let kept: [String]?; let moved: [[Double]]?
        }
        struct Follow: Decodable {
            struct Step: Decodable { let settle: [Double]?; let phone: [Double]?; let sig: [Int]?; let expect: String? }
            let name: String; let steps: [Step]
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
                                                  box: TextBox(left: 0.8, top: 0.2, right: 0.9, bottom: 0.22), lineHeight: message.line)
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
            }
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
        func signature(_ spec: [Int]) -> [UInt8] {
            (0..<768).map { UInt8($0 < spec[1] ? spec[2] : spec[0]) }
        }
        for vector in try shared().follow {
            let follow = ScreenPhoneFollow()
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
