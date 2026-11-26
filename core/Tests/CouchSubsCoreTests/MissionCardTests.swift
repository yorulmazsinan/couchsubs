// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Harita görev/konum kartı: kartın tanınması, parçalarının ayrı çevrilmesi ve otomatik ekran yazısında türü. Kurallar
/// ortak deneme dosyasından (Fixtures/mission-card.json; Windows MissionCardTests.cs ve Android MissionCardTest.kt aynı
/// dosyayı okur).
final class MissionCardTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Expected: Decodable {
            let title: String; let subtitles: [String]; let body: [String]; let details: [String]; let helpCorner: Bool
            /// Konum kartı (#1391): başlık yer adı, çevrilmez (grubu yok).
            var place: Bool?
        }
        struct Case: Decodable { let name: String; let lines: [Line]; let cards: [Expected] }
        let cases: [Case]
    }

    private func vectors() throws -> [Vectors.Case] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("mission-card.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).cases
    }

    private func lines(_ vector: Vectors.Case) -> [TextLine] {
        vector.lines.map { TextLine($0.text, box: TextBox(left: $0.box[0], top: $0.box[1], right: $0.box[2], bottom: $0.box[3])) }
    }

    func testSharedVectors() throws {
        for vector in try vectors() {
            let lines = lines(vector)
            let cards = MissionCard.find(lines)
            XCTAssertEqual(cards.count, vector.cards.count, vector.name)
            for (card, expected) in zip(cards, vector.cards) {
                let groups = MissionCard.groups(card, lines)
                let place = expected.place ?? false
                XCTAssertEqual(card.place, place, vector.name)
                XCTAssertEqual(card.title.map { lines[$0].text }.joined(separator: " "), expected.title, vector.name)
                let head = place ? 0 : 1
                if !place { XCTAssertEqual(groups.first?.paragraphs, [expected.title], vector.name) }
                XCTAssertEqual(groups.dropFirst(head).prefix(expected.subtitles.count).flatMap(\.paragraphs), expected.subtitles, vector.name)
                XCTAssertEqual(groups[head + expected.subtitles.count].paragraphs, expected.body, vector.name)
                XCTAssertEqual(groups.suffix(expected.details.count).flatMap(\.paragraphs), expected.details, vector.name)
                XCTAssertEqual(groups.count, head + 1 + expected.subtitles.count + expected.details.count, vector.name)
                let box = card.all.map { lines[$0].box! }.reduce(lines[card.title[0]].box!) { $0.union($1) }
                XCTAssertEqual(MissionCard.inHelpCorner(box), expected.helpCorner, vector.name)
            }
        }
    }

    /// "Ekranı çevir": başlık açıklamanın ilk cümlesine katılmaz; haritanın başka yazıları ayrı kalır.
    func testWholeScreenSplitsTheCardIntoItsParts() throws {
        let groups = ScreenTranslation.groups(Reading(lines: lines(try vectors()[0])), wholeScreen: true)
        XCTAssertTrue(groups.contains { $0.paragraphs == ["THE MARINA JOB"] })
        XCTAssertTrue(groups.contains { $0.paragraphs == ["Brian wants the boat moved before the harbor patrol makes its rounds.",
                                                           "Bring Lucia along for backup."] })
        XCTAssertTrue(groups.contains { $0.paragraphs == ["VICE CITY"] })
        // Kartın dört sözcüklük başlığı eskiden ilk cümleye katılıyordu.
        let long = lines(try vectors()[1])
        XCTAssertEqual(ScreenTranslation.groups(Reading(lines: long), wholeScreen: true).first?.paragraphs,
                       ["ESCAPE FROM THE PORT OF LEONIDA"])
    }

    /// Otomatik ekran yazısında kartın bulunduğu alan "Görev ve hedef yazısı"dır; yardım köşesindeki başlıklı kutu değil.
    @MainActor
    func testAutoAreaWithACardIsAMission() throws {
        let all = try vectors()
        let region = CropRegion(top: 0.35, bottom: 0.65, left: 0.55, right: 0.95)
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        func local(_ vector: Vectors.Case) -> Reading {
            Reading(lines: lines(vector).map { line in
                let b = line.box!, w = place.right - place.left, h = place.bottom - place.top
                return TextLine(line.text, box: TextBox(left: (b.left - place.left) / w, top: (b.top - place.top) / h,
                                                        right: (b.right - place.left) / w, bottom: (b.bottom - place.top) / h))
            })
        }
        let area = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName, region: region, auto: true)
        let card = RegionWatcher.candidate(local(all[0]), in: region, auto: true)
        XCTAssertTrue(card.missionCard)
        XCTAssertEqual(RegionWatcher.kind(area, card), .mission)
        XCTAssertTrue(card.blocks?.contains { Array(card.paragraphs[$0.start..<$0.start + $0.count]) == ["THE MARINA JOB"] } == true)
        let corner = CropRegion(top: 0.0, bottom: 0.3, left: 0.0, right: 0.4)
        let help = RegionWatcher.candidate(Reading(lines: lines(all[3]).map { line in
            let b = line.box!
            return TextLine(line.text, box: TextBox(left: b.left / 0.4, top: b.top / 0.3, right: b.right / 0.4, bottom: b.bottom / 0.3))
        }), in: corner, auto: true)
        XCTAssertFalse(help.missionCard)
        XCTAssertEqual(RegionWatcher.kind(ExtraArea(id: "auto-2", name: ScreenTextDetector.areaName, region: corner, auto: true), help), .help)
    }

    /// Haritadaki uzaklık ("124 ft") göstergedir, çevrilmez (X: chiaki); içinde sözcük olan ayrıntı satırı yazıdır.
    func testDistanceIsNotWords() {
        for distance in ["124 ft", "4 ft", "2.4 mi", "1,2 km", "50 yd"] { XCTAssertFalse(ScreenTranslation.isWords(distance), distance) }
        XCTAssertTrue(ScreenTranslation.isWords("Distance 2.4 mi"))
        XCTAssertTrue(ScreenTranslation.isWords("Go home"))
    }

    /// Menüler kapalıyken kart boyundaki menü alanı "Görev ve hedef yazısı" açıksa okunur; ekranı kaplayan menü okunmaz.
    func testMenuAreaIsReadForMapCardsOnlyWhenMissionsAreOn() {
        var settings = UserSettings()
        settings.autoScreenText = true
        settings.screenTextMenus = false
        var small = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName, region: CropRegion(top: 0.3, bottom: 0.6, left: 0.55, right: 0.9), auto: true)
        small.menu = true
        var wide = small
        wide.region = CropRegion(top: 0.1, bottom: 0.9, left: 0.05, right: 0.95)
        XCTAssertTrue(ScreenTextKind.reads(small, allows: settings.screenTextAllows))
        XCTAssertFalse(ScreenTextKind.reads(wide, allows: settings.screenTextAllows))
        settings.screenTextMission = false
        XCTAssertFalse(ScreenTextKind.reads(small, allows: settings.screenTextAllows))
        // Ana anahtar kapalıyken türler uygulanmaz.
        settings.autoScreenText = false
        XCTAssertTrue(ScreenTextKind.reads(wide, allows: settings.screenTextAllows))
    }
}
