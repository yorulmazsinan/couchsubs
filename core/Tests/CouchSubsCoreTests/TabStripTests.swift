// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// Menü sekme şeridi (#1372): aynı şerit her karede başka biçimde ve sırada okunsa da sekmeler ayrı etiket, soldan sağa
/// aynı sırada, aday anahtarı aynı; seçim kayınca bütün sekmelerin çevirisi yerinde kalır. Ortak deneme dosyası
/// Fixtures/tab-strip.json (Windows TabStripTests.cs ve Android TabStripTest.kt aynı dosyayı okur).
@MainActor
final class TabStripTests: XCTestCase {
    private struct Word: Decodable { let text: String; let box: [Double] }
    private struct Line: Decodable { let text: String; let box: [Double]; let words: [Word]?; let icons: [[Double]]? }
    private struct Frame: Decodable { let name: String; let lines: [Line] }
    private struct Carried: Decodable {
        let id: String
        let listMoved: Bool
        let rendered: [Line]
        let current: [Line]
        let kept: [[Int]]
        let fresh: [Int]
    }
    private struct Fixture: Decodable { let expected: [String]; let frames: [Frame]; let carried: Carried }

    private static func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("tab-strip.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private static func box(_ b: [Double]) -> TextBox { TextBox(left: b[0], top: b[1], right: b[2], bottom: b[3]) }

    private static func line(_ l: Line) -> TextLine {
        TextLine(l.text, box: box(l.box), words: l.words?.map { TextWord($0.text, box: box($0.box)) },
                 icons: l.icons?.map { IconSlot(box: box($0), text: "") })
    }

    func testTabsKeepTheirOrderEveryFrame() throws {
        let fixture = try Self.fixture()
        XCTAssertGreaterThanOrEqual(fixture.frames.count, 3)
        let full = CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        var keys = Set<String>()
        for frame in fixture.frames {
            let candidate = RegionWatcher.candidate(Reading(lines: frame.lines.map(Self.line)), in: full, auto: true, menu: true)
            XCTAssertEqual(candidate.paragraphs, fixture.expected, frame.name)
            let blocks = candidate.blocks ?? []
            XCTAssertEqual(blocks.count, fixture.expected.count, frame.name)
            // Her sekme kendi yerinde, soldan sağa.
            let tabs = blocks.prefix(4).map(\.box.left)
            XCTAssertEqual(tabs, tabs.sorted(), frame.name)
            keys.insert(candidate.key)
        }
        XCTAssertEqual(keys.count, 1, "aday anahtarı her karede aynı olmalı")
    }

    func testSelectionKeepsEveryTab() throws {
        let item = try Self.fixture().carried
        let rendered = item.rendered.map {
            ScreenTranslation.Item(source: $0.text, translation: "çeviri", box: Self.box($0.box), lineHeight: 0.042)
        }
        let current = item.current.map { (box: Self.box($0.box), text: $0.text) }
        let diff = RegionWatcher.carriedRows(rendered: rendered, current: current, listMoved: item.listMoved)
        XCTAssertEqual(diff.kept.map { [$0.rendered, $0.current ?? -1] }, item.kept, item.id)
        XCTAssertEqual(diff.fresh, item.fresh, item.id)
    }

    /// Sekme etiketleri arayüz sözlüğünden; karakter adları olduğu gibi.
    func testTabLabels() {
        XCTAssertEqual(UiCommands.translateLabelLoosely("MAP"), "HARİTA")
        XCTAssertEqual(UiCommands.translateLabelLoosely("GALLERY"), "GALERİ")
        XCTAssertEqual(UiCommands.translateLabelLoosely("JASON LUCIA MAP BRIEF"), "JASON LUCIA HARİTA ÖZET")
        XCTAssertTrue(ScreenTranslation.keepsNames("JASON LUCIA"))
        XCTAssertFalse(ScreenTranslation.keepsNames("MAP BRIEF"))
    }
}
