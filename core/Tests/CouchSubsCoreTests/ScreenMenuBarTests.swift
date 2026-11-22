// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// GTA 6 menü/görev ekranı (#856, #859, #860): menü şeridinin sekmeleri ayrı, yalnız özel addan oluşan sekme çevrilmez,
/// satır ucundaki tuş simgesi kutunun dışında, saat çevrilmez. Ortak deneme dosyası Fixtures/screen-menu.json (Windows
/// ScreenMenuBarTests.cs, Android ScreenMenuBarTest.kt aynı dosyayı okur).
final class ScreenMenuBarTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Name: Decodable { let text: String; let keep: Bool }
        struct Clock: Decodable { let text: String; let clock: Bool }
        struct Word: Decodable { let text: String; let box: [Double] }
        struct Menu: Decodable { let name: String; let text: String; let box: [Double]; let words: [Word]; let pieces: [String] }
        struct Edge: Decodable {
            let name: String; let text: String; let box: [Double]; let words: [Word]?; let icons: [[Double]]?
            let expected: String; let left: Double; let right: Double
        }
        let names: [Name]
        let clocks: [Clock]
        let menuLines: [Menu]
        let edgeIcons: [Edge]
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("screen-menu.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    func testNamesOnlyAreKept() throws {
        for name in try vectors().names {
            XCTAssertEqual(ScreenTranslation.keepsNames(name.text), name.keep, name.text)
            if name.keep { XCTAssertEqual(ScreenTranslation.known(name.text), name.text, name.text) }
        }
    }

    func testClocksAreNotTranslated() throws {
        for clock in try vectors().clocks {
            XCTAssertEqual(ScreenTranslation.isClock(clock.text), clock.clock, clock.text)
        }
    }

    func testMenuBarSplitsIntoTabs() throws {
        for menu in try vectors().menuLines {
            let line = TextLine(menu.text, box: box(menu.box), words: menu.words.map { TextWord($0.text, box: box($0.box)) })
            let pieces = ScreenTranslation.menuPieces(line)
            XCTAssertEqual(pieces.map(\.text), menu.pieces, menu.name)
            for piece in pieces { XCTAssertEqual(piece.box?.top, menu.box[1], menu.name) }
        }
    }

    func testEdgeButtonsStayOutsideTheBox() throws {
        for edge in try vectors().edgeIcons {
            var line = TextLine(edge.text, box: box(edge.box), words: edge.words?.map { TextWord($0.text, box: box($0.box)) })
            line.icons = edge.icons?.map { IconSlot(box: box($0), text: "") }
            let trimmed = ScreenTranslation.withoutEdgeIcons(line)
            XCTAssertEqual(trimmed.text, edge.expected, edge.name)
            XCTAssertEqual(trimmed.box!.left, edge.left, accuracy: 1e-9, edge.name)
            XCTAssertEqual(trimmed.box!.right, edge.right, accuracy: 1e-9, edge.name)
            XCTAssertNil(trimmed.text == edge.text ? nil : trimmed.icons, edge.name)
        }
    }

    /// Menü şeridi sözcük yerleri olmadan da görüntüdeki boşluklardan bölünür (yazı tanımanın sözcük kutuları boşluğu kapsıyor).
    func testMenuBarSplitsFromThePixels() throws {
        let width = 960, height = 60
        var pixels = [UInt8](repeating: 30, count: width * height * 4)
        // Üç sekme: harf benzeri dikey çizgiler, sekme içinde dar, sekmeler arasında geniş boşluk.
        let tabs = [(40, 222), (300, 342), (420, 532)]  // harf başına ~14 nokta
        for (start, end) in tabs {
            for x in start..<end where (x - start) % 12 < 6 {
                for y in 15..<45 {
                    let p = (y * width + x) * 4
                    (pixels[p], pixels[p + 1], pixels[p + 2]) = (230, 230, 230)
                }
            }
        }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let frame = ScreenTextDetectorTests.image(pixels, width: width, height: height)
        let line = TextLine("JASON & LUCIA MAP PROGRESS", box: TextBox(left: 40.0 / 960, top: 0.25, right: 532.0 / 960, bottom: 0.75))
        let pieces = ScreenTranslation.menuPieces(line, aspect: 16, frame: frame)
        XCTAssertEqual(pieces.map(\.text), ["JASON & LUCIA", "MAP", "PROGRESS"])
        XCTAssertEqual(pieces[1].box!.left, 300.0 / 960, accuracy: 0.003)
        XCTAssertEqual(pieces[1].box!.right, 342.0 / 960, accuracy: 0.01)
    }

    /// Görev kartı: başlığın solunda portre var, açıklama portrenin altından başlar; görev listesinde sıradaki görevin
    /// başlığı açıklamaya katılmaz.
    func testCardWithPortraitAndMissionList() {
        let portrait = [
            TextLine("ISLAND DREAMS", box: TextBox(left: 0.187, top: 0.193, right: 0.350, bottom: 0.244)),
            TextLine("Keep an eye on the bachelor party", box: TextBox(left: 0.147, top: 0.276, right: 0.429, bottom: 0.310)),
            TextLine("while searching Kenton's dive spot for", box: TextBox(left: 0.146, top: 0.326, right: 0.462, bottom: 0.363)),
            TextLine("treasure.", box: TextBox(left: 0.145, top: 0.382, right: 0.222, bottom: 0.409)),
        ]
        let cards = MissionCard.find(portrait)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first.map { MissionCard.groups($0, portrait).map(\.paragraphs) },
                       [["ISLAND DREAMS"], ["Keep an eye on the bachelor party while searching Kenton's dive spot for treasure."]])
    }
}
