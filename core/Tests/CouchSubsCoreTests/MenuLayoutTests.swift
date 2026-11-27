// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import Foundation
import XCTest

/// Menüde çevirinin biçimi ayardan gelir (#1365, `MenuLayout`): B üstünü örter, A Türkçeyi yanına koyu etikete yazar
/// (yanına sığmazsa altına/üstüne, şerit bir bütün), görev kartının ikizi kartın altında. Ortak deneme dosyası
/// Fixtures/menu-layout.json (Windows MenuLayoutTests.cs, Android MenuLayoutTest.kt aynı vakalar).
final class MenuLayoutTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Item: Decodable {
            let name: String
            let cover: [Double]
            let box: [Double]
            let line: Double
            let align: String
            let bg: String
            let icon: String?
        }
        struct Expect: Decodable {
            let mode: String
            let spot: [Double]?
            let room: [Double]?
            let twin: [Double]?
            let label: String?
            let bg: String?
        }
        struct Case: Decodable {
            let id: String
            let aspect: Double
            let cover: Bool
            let items: [Item]
            let cards: [[Int]]
            let expect: [Expect]
        }
        let labelColor: String
        let cases: [Case]
    }

    private func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    private func near(_ expected: [Double]?, _ actual: TextBox?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let expected, let actual else { return XCTFail("\(what): kutu yok", file: file, line: line) }
        let e = box(expected)
        let ok = abs(actual.left - e.left) < 1e-6 && abs(actual.top - e.top) < 1e-6
            && abs(actual.right - e.right) < 1e-6 && abs(actual.bottom - e.bottom) < 1e-6
        XCTAssertTrue(ok, "\(what): beklenen \(e), çıkan \(actual)", file: file, line: line)
    }

    func testSharedCases() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("menu-layout.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.labelColor, MenuLayout.labelColor)
        for c in fixture.cases {
            let paints = c.items.map { item -> TextPaint in
                var paint = TextPaint(background: item.bg, pitch: item.line, cover: box(item.cover))
                paint.iconSide = item.icon.flatMap(TextLook.Align.init(rawValue:))
                // Ölçümün seçtiği kip ne olursa olsun kilitlenir.
                paint.mode = .twin
                paint.spot = box(item.cover)
                paint.spotRoom = box(item.cover)
                paint.twin = TextBox(left: 0, top: 0, right: 1, bottom: 1)
                return paint
            }
            let targets = c.items.map { item in
                TextPainter.Target(box: box(item.box), lineHeight: item.line, rows: 1, background: item.bg,
                                   foreground: "#F0F0F0", upper: false, align: TextLook.Align(rawValue: item.align)!)
            }
            let result = MenuLayout.locked(paints, targets: targets, cards: c.cards, cover: c.cover, aspect: c.aspect)
            XCTAssertEqual(result.count, c.expect.count, c.id)
            for (k, e) in c.expect.enumerated() where k < result.count {
                let p = result[k]
                let what = "\(c.id) / \(c.items[k].name)"
                XCTAssertEqual(p.mode.rawValue, e.mode, what)
                XCTAssertEqual(p.cover, paints[k].cover, what)
                if p.mode == .cover {
                    XCTAssertNil(p.spot, what)
                    XCTAssertNil(p.twin, what)
                    XCTAssertNil(p.label, what)
                    continue
                }
                near(e.spot, p.spot, what + " spot")
                near(e.room, p.spotRoom, what + " spotRoom")
                if p.mode == .beside {
                    XCTAssertEqual(p.label, e.label, what)
                    XCTAssertNil(p.twin, what)
                } else {
                    near(e.twin, p.twin, what + " twin")
                    XCTAssertEqual(p.background, e.bg, what)
                    XCTAssertNil(p.label, what)
                }
            }
        }
    }

    private struct PortraitFixture: Decodable {
        struct Rect: Decodable { let box: [Int]; let color: String }
        struct Case: Decodable {
            let id: String
            let base: String
            let rects: [Rect]
            let covers: [[Double]]
            let card: [Int]
            let background: String
            let line: Double
            let expect: [Double]?
        }
        let width: Int
        let height: Int
        let cases: [Case]
    }

    /// İkiz kartın kişi resmi kareden bulunur (`TextPainter.cardPortrait`): başlığa yakın resim bulunur; harita, harf
    /// taşması ve resimsiz kart resim sayılmaz. Ortak deneme dosyası Fixtures/card-portrait.json.
    func testCardPortraitSharedCases() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("card-portrait.json")
        let fixture = try JSONDecoder().decode(PortraitFixture.self, from: Data(contentsOf: url))
        let w = Double(fixture.width), h = Double(fixture.height)
        for c in fixture.cases {
            let rects = c.rects.map { (box: $0.box, color: TextPainter.rgb($0.color)) }
            let ground = TextPainter.rgb(c.base)
            let covers = c.covers.map { TextBox(left: $0[0] / w, top: $0[1] / h, right: $0[2] / w, bottom: $0[3] / h) }
            let found = TextPainter.cardPortrait(covers: covers, card: c.card, background: c.background, line: c.line / h,
                                                 width: fixture.width, height: fixture.height) { x, y in
                rects.last { x >= $0.box[0] && x < $0.box[2] && y >= $0.box[1] && y < $0.box[3] }?.color ?? ground
            }
            guard let e = c.expect else {
                XCTAssertNil(found, "\(c.id): resim bulunmamalı")
                continue
            }
            near([e[0] / w, e[1] / h, e[2] / w, e[3] / h], found, c.id)
        }
    }

    /// İkiz kartta kişi resmi yoksa kareden aranan resim bütün parçalara konur ve ikiz kutu resmi de içine alır.
    func testCardTwinTakesTheFoundPortrait() {
        let title = TextPaint(background: "#1E2A5A", pitch: 0.04, cover: TextBox(left: 0.30, top: 0.30, right: 0.50, bottom: 0.34))
        let body = TextPaint(background: "#1E2A5A", pitch: 0.04, cover: TextBox(left: 0.24, top: 0.36, right: 0.60, bottom: 0.44))
        let targets = [title, body].map {
            TextPainter.Target(box: $0.cover, lineHeight: 0.04, rows: 1, background: "#1E2A5A", foreground: "#F0F0F0",
                               upper: false, align: .left)
        }
        let face = TextBox(left: 0.24, top: 0.29, right: 0.28, bottom: 0.35)
        var asked = 0
        let result = MenuLayout.locked([title, body], targets: targets, cards: [[0, 1]], cover: false, aspect: 1) { _, fill in
            asked += 1
            XCTAssertEqual(fill, "#1E2A5A")
            return (box: face, image: "data:image/png;base64,AA==")
        }
        XCTAssertEqual(asked, 1)
        for p in result {
            XCTAssertEqual(p.mode, .twin)
            XCTAssertEqual(p.portrait, face)
            XCTAssertEqual(p.portraitImage, "data:image/png;base64,AA==")
            XCTAssertTrue(p.twin!.left <= face.left && p.portraitTwin!.top > p.twin!.top - 1e-9, "ikiz resmi içine alır")
        }
        // Görev listesindeki kart ikiz kurulmaz: resim de aranmaz.
        let row = TextPaint(background: "#1E2A5A", pitch: 0.04, cover: TextBox(left: 0.24, top: 0.10, right: 0.40, bottom: 0.14))
        let listTargets = [TextPainter.Target(box: row.cover, lineHeight: 0.04, rows: 1, background: "#1E2A5A",
                                              foreground: "#F0F0F0", upper: false, align: .left)] + targets
        _ = MenuLayout.locked([row, title, body], targets: listTargets, cards: [[1, 2]], cover: false, aspect: 1) { _, _ in
            asked += 1
            return nil
        }
        XCTAssertEqual(asked, 1)
    }

    private struct SteadyFixture: Decodable {
        struct Row: Decodable { let text: String; let box: [Double]; let mode: String }
        struct Read: Decodable { let menuCover: Bool?; let map: Bool; let rows: [Row]; let expected: [String] }
        struct Run: Decodable { let name: String; let reads: [Read] }
        let sequences: [Run]
    }

    /// Menüde biçim ayardan gelince satırın saklı kipi (`RegionWatcher.steadyPaints`, menuCover): ayar değişince eski biçim
    /// kalmaz, A'da bir kez örtülen satır örtülü kalmaz, kart ikizi harita düzeninde kalır, menü dışı okumanın kipi menüye
    /// geçmez. Ortak deneme dosyası Fixtures/menu-steady.json (Windows, Android aynı).
    func testMenuRowPaintFollowsTheSetting() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("menu-steady.json")
        let fixture = try JSONDecoder().decode(SteadyFixture.self, from: Data(contentsOf: url))
        for sequence in fixture.sequences {
            var memory: [String: RegionWatcher.RowPaint] = [:]
            for (index, read) in sequence.reads.enumerated() {
                let blocks = read.rows.enumerated().map { i, row -> RegionWatcher.Block in
                    let box = TextBox(left: row.box[0], top: row.box[1], right: row.box[2], bottom: row.box[3])
                    return RegionWatcher.Block(start: i, count: 1, box: box, lineHeight: 0.04, paint: Self.steadyPaint(row.mode, box))
                }
                let out = RegionWatcher.steadyPaints(blocks, texts: read.rows.map(\.text), memory: &memory, map: read.map,
                                                     menuCover: read.menuCover)
                for (k, row) in read.rows.enumerated() {
                    XCTAssertEqual(out[k].paint?.mode.rawValue, read.expected[k], "\(sequence.name) okuma \(index): \(row.text)")
                    // Taşınan ölçü satırın yeni yerindedir.
                    XCTAssertEqual(out[k].paint?.cover.top ?? -1, row.box[1], accuracy: 1e-9, "\(sequence.name) okuma \(index)")
                }
            }
        }
    }

    private static func steadyPaint(_ mode: String, _ box: TextBox) -> TextPaint {
        var paint = TextPaint(background: "#202020", pitch: box.bottom - box.top, cover: box)
        let width = box.right - box.left, height = box.bottom - box.top
        switch mode {
        case "beside":
            paint.mode = .beside
            paint.spot = TextBox(left: box.right + 0.01, top: box.top, right: box.right + 0.01 + width, bottom: box.bottom)
            paint.spotRoom = paint.spot
            paint.label = MenuLayout.labelColor
        case "twin":
            paint.mode = .twin
            paint.twin = TextBox(left: box.left, top: box.bottom + 0.01, right: box.right, bottom: box.bottom + 0.01 + height)
            paint.spot = paint.twin
        default:
            paint.mode = .cover
        }
        return paint
    }
}
