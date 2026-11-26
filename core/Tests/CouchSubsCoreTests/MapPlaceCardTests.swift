// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// #1391: haritanın konum kartı (dükkân, garaj açıklaması) tek paragraf olarak çevrilir, başlığı (yer adı) çevrilmez,
/// mesaj alanına taşan kart iki alana bölünmez, mesaj alanının kenarındaki kesik parça tek başına çevrilmez. Ortak deneme
/// dosyası Fixtures/map-place-card.json (Windows MapPlaceCardTests.cs, Android MapPlaceCardTest.kt aynı dosyayı okur).
final class MapPlaceCardTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Card: Decodable {
            let name: String; let lines: [Line]; let place: Bool; let subtitles: [String]; let body: [String]; let details: [String]
        }
        struct Title: Decodable { let text: String; let place: Bool }
        struct Area: Decodable { let name: String; let region: [Double]; let menu: Bool; let kept: [String] }
        struct Fragment: Decodable { let text: String; let box: [Double]; let cut: Bool }
        let cards: [Card]
        let titles: [Title]
        let areas: [Area]
        let fragments: [Fragment]
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("map-place-card.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func lines(_ card: Vectors.Card) -> [TextLine] {
        card.lines.map { TextLine($0.text, box: TextBox(left: $0.box[0], top: $0.box[1], right: $0.box[2], bottom: $0.box[3])) }
    }

    func testCardGroups() throws {
        for vector in try vectors().cards {
            let lines = lines(vector)
            let cards = MissionCard.find(lines)
            XCTAssertEqual(cards.count, 1, vector.name)
            guard let card = cards.first else { continue }
            XCTAssertEqual(card.place, vector.place, vector.name)
            let groups = MissionCard.groups(card, lines)
            let head = vector.place ? 0 : 1
            if !vector.place { XCTAssertEqual(groups.first?.paragraphs, [lines[card.title[0]].text], vector.name) }
            XCTAssertEqual(groups.dropFirst(head).prefix(vector.subtitles.count).flatMap(\.paragraphs), vector.subtitles, vector.name)
            XCTAssertEqual(groups[head + vector.subtitles.count].paragraphs, vector.body, vector.name)
            XCTAssertEqual(groups.count, head + 1 + vector.subtitles.count + vector.details.count, vector.name)
            // Açıklamanın bloğu sarılmış satırların hepsini kapsar (örtü İngilizcenin tamamına).
            let body = card.body.map { lines[$0].box! }
            XCTAssertEqual(groups[head + vector.subtitles.count].box, body.dropFirst().reduce(body[0]) { $0.union($1) }, vector.name)
        }
    }

    func testPlaceTitles() throws {
        for title in try vectors().titles {
            XCTAssertEqual(MissionCard.isPlaceTitle(title.text), title.place, title.text)
        }
    }

    @MainActor
    func testPresetsYieldToACrossingCard() throws {
        for vector in try vectors().areas {
            let r = vector.region
            var auto = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName,
                                 region: CropRegion(top: r[1], bottom: r[3], left: r[0], right: r[2]), auto: true)
            auto.menu = vector.menu
            XCTAssertEqual(RegionWatcher.yieldingPresets(GameAreaPresets.areas("GTA 6") + [auto]).map(\.id), vector.kept, vector.name)
        }
    }

    @MainActor
    func testFragmentsAtTheMessagesEdge() throws {
        let region = GameAreaPresets.areas("GTA 6").first { $0.id == GameAreaPresets.phoneId }!.region
        let fragments = try vectors().fragments
        for fragment in fragments {
            let b = fragment.box
            let line = TextLine(fragment.text, box: TextBox(left: b[0], top: b[1], right: b[2], bottom: b[3]))
            XCTAssertEqual(RegionWatcher.cutAtAreaLeftEdge(line, region: region), fragment.cut, fragment.text)
        }
        // Hazır mesaj alanının okumasında kesik parçalar çeviriye girmez.
        let reading = Reading(lines: fragments.map { f in
            TextLine(f.text, box: TextBox(left: f.box[0], top: f.box[1], right: f.box[2], bottom: f.box[3]))
        })
        let candidate = RegionWatcher.candidate(reading, in: region, styled: true, kind: .phone)
        let joined = candidate.paragraphs.joined(separator: " ")
        XCTAssertTrue(joined.contains("Just saw Moses"), joined)
        for fragment in fragments where fragment.cut { XCTAssertFalse(joined.contains(fragment.text), joined) }
    }

    /// Otomatik alanda konum kartı: başlık çevrilmez, açıklama tek parça ve tek blok.
    @MainActor
    func testAutoAreaTranslatesTheCardAsOneParagraph() throws {
        let vector = try vectors().cards[0]
        let region = CropRegion(top: 0.36, bottom: 0.66, left: 0.37, right: 0.78)
        let w = region.right - region.left, h = region.bottom - region.top
        let reading = Reading(lines: vector.lines.filter { $0.box[0] >= region.left }.map { l in
            TextLine(l.text, box: TextBox(left: (l.box[0] - region.left) / w, top: (l.box[1] - region.top) / h,
                                          right: (l.box[2] - region.left) / w, bottom: (l.box[3] - region.top) / h))
        })
        let candidate = RegionWatcher.candidate(reading, in: region, auto: true)
        XCTAssertTrue(candidate.missionCard)
        XCTAssertEqual(candidate.paragraphs, vector.subtitles + vector.body)
        XCTAssertEqual(candidate.blocks?.count, 2)
    }
}
