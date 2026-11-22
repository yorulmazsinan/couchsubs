// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// #827: aynı yazı aynı yerde tek kez çizilir. Kurallar ortak deneme dosyasından (Fixtures/screen-overlap.json; Windows
/// ScreenOverlapTests.cs ve Android ScreenOverlapTest.kt aynı dosyayı okur).
final class ScreenOverlapTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Overlap: Decodable { let name: String; let a: [Double]; let b: [Double]; let share: Double }
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Lines: Decodable { let name: String; let lines: [Line]; let kept: [String] }
        struct Entry: Decodable { let source: String; let translation: String?; let box: [Double] }
        struct Layers: Decodable { let name: String; let items: [Entry]; let kept: [String] }
        struct Expect: Decodable { let text: String; let box: [Double] }
        struct Edge: Decodable { let name: String; let text: String; let box: [Double]; let words: [Line]?; let expect: Expect }
        let overlap: [Overlap]
        let lines: [Lines]
        let layers: [Layers]
        let edges: [Edge]
    }

    /// Menüdeki simge (dükkân, kamera, ayar) çeviri kutusunun dışında kalır: kutu yalnız yazıyı kapsar.
    func testEdgeMarksStayOutsideTheBox() throws {
        for vector in try vectors().edges {
            let line = TextLine(vector.text, box: box(vector.box), words: vector.words?.map { TextWord($0.text, box: box($0.box)) })
            let trimmed = ScreenTranslation.withoutEdgeMarks(line)
            XCTAssertEqual(trimmed.text, vector.expect.text, vector.name)
            let got = trimmed.box!, want = box(vector.expect.box)
            for (a, b) in [(got.left, want.left), (got.top, want.top), (got.right, want.right), (got.bottom, want.bottom)] {
                XCTAssertEqual(a, b, accuracy: 1e-9, vector.name)
            }
        }
        // Kumanda simgeli satıra dokunulmaz (simge çeviride yerinde gösterilir).
        let icon = TextLine("\(ButtonIcons.marker) Back", box: TextBox(left: 0.1, top: 0.1, right: 0.2, bottom: 0.13),
                            icons: [IconSlot(box: TextBox(left: 0.1, top: 0.1, right: 0.12, bottom: 0.13), text: "O")])
        XCTAssertEqual(ScreenTranslation.withoutEdgeMarks(icon), icon)
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("screen-overlap.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    func testSharedVectors() throws {
        let all = try vectors()
        for vector in all.overlap {
            XCTAssertEqual(ScreenTranslation.overlap(box(vector.a), box(vector.b)), vector.share, accuracy: 1e-9, vector.name)
            XCTAssertEqual(ScreenTranslation.overlap(box(vector.b), box(vector.a)), vector.share, accuracy: 1e-9, vector.name)
        }
        for vector in all.lines {
            let lines = vector.lines.map { TextLine($0.text, box: box($0.box)) }
            XCTAssertEqual(ScreenTranslation.withoutDuplicateLines(lines).map(\.text), vector.kept, vector.name)
        }
        for vector in all.layers {
            let items = vector.items.map {
                ScreenTranslation.Item(source: $0.source, translation: $0.translation ?? "Türkçe \($0.source)", box: box($0.box), lineHeight: 0.03)
            }
            XCTAssertEqual(ScreenTranslation.layered(items).map(\.source), vector.kept, vector.name)
        }
    }

    /// "Ekranı çevir": görev listesinin seçili satırı bir de parça olarak okununca ayrı grup (ve altında ikinci kutu) olmaz.
    func testWholeScreenDoesNotTranslateTheSameLineTwice() throws {
        let vector = try vectors().lines[0]
        let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: box($0.box)) })
        let paragraphs = ScreenTranslation.groups(reading, wholeScreen: true).flatMap(\.paragraphs)
        XCTAssertFalse(paragraphs.contains("Find"), "\(paragraphs)")
        XCTAssertTrue(paragraphs.contains { $0.contains("Find Donnie's Package") }, "\(paragraphs)")
    }

    /// Aynı okumanın çevirilerinden aynı yeri çizenlerin yalnız biri gösterilir; telefon kartı dokunulmaz.
    func testPresentDropsDuplicateItems() {
        let whole = ScreenTranslation.Item(source: "Find Donnie's Package", translation: "Donnie'nin Paketini Bul",
                                           box: TextBox(left: 0.074, top: 0.245, right: 0.25, bottom: 0.272), lineHeight: 0.027)
        let piece = ScreenTranslation.Item(source: "Find", translation: "Bulur",
                                           box: TextBox(left: 0.15, top: 0.255, right: 0.19, bottom: 0.285), lineHeight: 0.03)
        XCTAssertEqual(ScreenTranslation.present([piece, whole], phone: nil).map(\.source), ["Find Donnie's Package"])
    }

    /// "Ekranı çevir" ekrandayken onun yerindeki ek alan blokları atılır, başka yerdekiler kalır.
    func testUncoveredKeepsOnlyBlocksElsewhere() {
        let screen = [ScreenTranslation.Item(source: "Make Money", translation: "Para Kazan",
                                             box: TextBox(left: 0.075, top: 0.185, right: 0.17, bottom: 0.21), lineHeight: 0.025)]
        let region = [ScreenTranslation.Item(source: "Make Money", translation: "Para Kazanın",
                                             box: TextBox(left: 0.07, top: 0.18, right: 0.17, bottom: 0.212), lineHeight: 0.025),
                      ScreenTranslation.Item(source: "Shoeless Keys", translation: "Shoeless Keys adası",
                                             box: TextBox(left: 0.44, top: 0.14, right: 0.53, bottom: 0.16), lineHeight: 0.02)]
        XCTAssertEqual(ScreenTranslation.uncovered(region, by: screen).map(\.source), ["Shoeless Keys"])
    }

    /// Menü ve görev etiketleri kısa, tekil emir kipinde çevrilir ("Para Kazan"; "Para Kazanın" değil).
    func testSystemPromptAsksForSingularImperativeLabels() {
        XCTAssertTrue(AIRequest.systemPrompt.contains("singular informal imperatives"))
        XCTAssertTrue(AIRequest.systemPrompt.contains("\"Para Kazan\""))
    }
}
