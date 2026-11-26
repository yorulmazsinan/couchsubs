// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Menüde seçim/liste kaydında satır farkı (#1359, #1362) ve tuş çubuğunun dar yazısı (#1360). Ortak vakalar
/// Fixtures/menu-rows.json (Windows MenuRowsTests.cs ve Android MenuRowsTest.kt aynı dosyayı okur).
@MainActor
final class MenuRowsTests: XCTestCase {
    private struct Row: Decodable { let text: String; let box: [Double] }
    private struct Carried: Decodable {
        let id: String
        let listMoved: Bool
        let rendered: [Row]
        let current: [Row]
        let kept: [[Int?]]
        let fresh: [Int]
    }
    private struct Characters: Decodable { let text: String; let characters: Int }
    private struct Condensed: Decodable { let width: Double; let height: Double; let characters: Int; let condensed: Bool }
    private struct Fixture: Decodable {
        let carriedRows: [Carried]
        let characters: [Characters]
        let condensed: [Condensed]
    }

    private static func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("menu-rows.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func box(_ b: [Double]) -> TextBox { TextBox(left: b[0], top: b[1], right: b[2], bottom: b[3]) }

    func testSharedCarriedRows() throws {
        let cases = try Self.fixture().carriedRows
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for item in cases {
            let rendered = item.rendered.map {
                ScreenTranslation.Item(source: $0.text, translation: "çeviri", box: Self.box($0.box), lineHeight: 0.03)
            }
            let current = item.current.map { (box: Self.box($0.box), text: $0.text) }
            let diff = RegionWatcher.carriedRows(rendered: rendered, current: current, listMoved: item.listMoved)
            XCTAssertEqual(diff.kept.map { [$0.rendered, $0.current] }, item.kept, item.id)
            XCTAssertEqual(diff.fresh, item.fresh, item.id)
        }
    }

    func testSharedCondensedMeasure() throws {
        let fixture = try Self.fixture()
        for item in fixture.characters {
            XCTAssertEqual(TextStyleSampler.characters(item.text), item.characters, item.text)
        }
        for item in fixture.condensed {
            XCTAssertEqual(TextStyleSampler.isCondensed(width: item.width, height: item.height, characters: item.characters),
                           item.condensed, "\(item)")
        }
    }

    /// Aynı gruptaki etiketlerden biri dar yazıysa hepsi dar (#1360); grupsuz etiket değişmez.
    func testGroupSharesCondensedLook() {
        func block(_ group: Int?, condensed: Bool) -> RegionWatcher.Block {
            var paint = TextPaint(background: "#000000", pitch: 0.03, cover: TextBox(left: 0, top: 0, right: 0.1, bottom: 0.03))
            paint.group = group
            return RegionWatcher.Block(start: 0, count: 1, box: paint.cover, lineHeight: 0.03,
                                       look: TextLook(bold: true, condensed: condensed, align: .left, upper: true, flat: true),
                                       paint: paint)
        }
        let blocks = RegionWatcher.condensedTogether([block(0, condensed: true), block(0, condensed: false),
                                                      block(0, condensed: false), block(nil, condensed: false)])
        XCTAssertEqual(blocks.map { $0.look?.condensed }, [true, true, true, false])
    }
}
