// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

@MainActor
final class FreeButtonIconsTests: XCTestCase {
    private let marker = String(ButtonIcons.marker)
    private let full = CropRegion(top: 0, bottom: 1, left: 0, right: 1)

    // 400×40 OCR alanı. Her verilen x, siyah zemindeki 18 piksellik beyaz bir düğmenin sol kenarı.
    private func frame(_ rings: Int...) -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 40, bitsPerComponent: 8, bytesPerRow: 1600,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(400 * 40) { pixels[i * 4 + 3] = 255 }
        for x0 in rings {
            for y in 11..<29 {
                for x in x0..<(x0 + 18) where x - x0 < 3 || x0 + 18 - x <= 3 || y < 14 || y >= 26 {
                    let p = (y * 400 + x) * 4
                    pixels[p] = 255
                    pixels[p + 1] = 255
                    pixels[p + 2] = 255
                }
            }
        }
        return context.makeImage()!
    }

    private func word(_ text: String, _ left: Double, _ right: Double) -> TextWord {
        TextWord(text, box: TextBox(left: left, top: 0.25, right: right, bottom: 0.75))
    }

    private func line(_ words: TextWord...) -> TextLine {
        TextLine(words.map(\.text).joined(separator: " "), box: words.dropFirst().reduce(words[0].box) { $0.union($1.box) }, words: words)
    }

    private struct Vectors: Decodable {
        struct Layout: Decodable { let width: Int; let height: Int; let top: Int; let size: Int }
        struct Marked: Decodable { let text: String; let icons: [String]? }
        struct Screen: Decodable { let paragraphs: [String]; let maxRight: Double }
        struct Case: Decodable {
            let name: String; let rings: [Int]; let background: [Int]?; let ink: [Int]?
            let words: [[Value]]; let markFree: Marked?; let screen: Screen?
        }
        enum Value: Decodable {
            case text(String), number(Double)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) { self = .text(text) } else { self = .number(try container.decode(Double.self)) }
            }
            var text: String { if case let .text(value) = self { return value }; return "" }
            var number: Double { if case let .number(value) = self { return value }; return 0 }
        }
        let frame: Layout
        let cases: [Case]
    }

    /// Ortak vakalar Fixtures/free-button-icons.json (Windows FreeButtonIconsTests.cs, Android FreeButtonIconsTest.kt aynı
    /// dosyayı okur).
    func testSharedCasesMatchWindowsAndAndroid() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("free-button-icons.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(vectors.cases.count, 10)
        let layout = vectors.frame
        for item in vectors.cases {
            let background = item.background ?? [0, 0, 0], ink = item.ink ?? [255, 255, 255]
            let context = CGContext(data: nil, width: layout.width, height: layout.height, bitsPerComponent: 8,
                                    bytesPerRow: layout.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            func paint(_ p: Int, _ color: [Int]) {
                pixels[p] = UInt8(color[0]); pixels[p + 1] = UInt8(color[1]); pixels[p + 2] = UInt8(color[2]); pixels[p + 3] = 255
            }
            for i in 0..<(layout.width * layout.height) { paint(i * 4, background) }
            let s = layout.size, t = layout.top
            for x0 in item.rings {
                for y in t..<(t + s) {
                    for x in x0..<(x0 + s) where x - x0 < 3 || x0 + s - x <= 3 || y - t < 3 || t + s - y <= 3 {
                        paint((y * layout.width + x) * 4, ink)
                    }
                }
            }
            let image = context.makeImage()!
            let source = line(item.words.map { word($0[0].text, $0[1].number, $0[2].number) })
            if let expected = item.markFree {
                let marked = ButtonIcons.markFree(source, frame: image)
                XCTAssertEqual(marked.text, expected.text, item.name)
                XCTAssertEqual(marked.icons?.map(\.text), expected.icons, item.name)
                if expected.icons == nil { XCTAssertEqual(marked, source, item.name) }
                for icon in ButtonIcons.withImages(marked.icons ?? [], frame: image) {
                    XCTAssertTrue(icon.box.left >= 0 && icon.box.right <= 1, item.name)
                    XCTAssertNotNil(icon.image, item.name)
                }
            }
            if let expected = item.screen {
                let groups = ScreenTranslation.groups(Reading(lines: [source]), frame: image, wholeScreen: true)
                XCTAssertEqual(groups.flatMap(\.paragraphs), expected.paragraphs, item.name)
                XCTAssertTrue(groups.allSatisfy { $0.icons == nil && $0.box.right <= expected.maxRight + 1e-9 }, item.name)
            }
        }
    }

    private func line(_ words: [TextWord]) -> TextLine {
        TextLine(words.map(\.text).joined(separator: " "), box: words.dropFirst().reduce(words[0].box) { $0.union($1.box) }, words: words)
    }

    func testOnlyButtonBarsProbeGapsAndOnlyVisibleIconsChangeTheCandidateKey() {
        let bar = line(word("SET", 0.05, 0.15), word("DESTINATION", 0.17, 0.45), word("EXIT", 0.55, 0.65))
        let visible = frame(191), empty = frame()
        let marked = ButtonIcons.markFree(bar, frame: visible)
        XCTAssertEqual(marked.text, "SET DESTINATION \(marker) EXIT")
        XCTAssertEqual(marked.icons?.count, 1)
        XCTAssertEqual(ButtonIcons.markFree(bar, frame: empty), bar)
        let normal = line(word("your", 0.05, 0.15), word("vehicle", 0.17, 0.45), word("for", 0.55, 0.65))
        XCTAssertEqual(ButtonIcons.markFree(normal, frame: visible), normal)
        let reading = Reading(lines: [bar])
        XCTAssertNotEqual(RegionWatcher.candidate(reading, in: full, frame: visible).key,
                          RegionWatcher.candidate(reading, in: full, frame: empty).key)
    }

    func testLeftEdgeIconAndMisreadLetterInButtonBar() {
        let mixed = line(word("Pick", 0.30, 0.40), word("up", 0.42, 0.47))
        XCTAssertEqual(ButtonIcons.markFree(mixed, frame: frame(92)).text, "\(marker) Pick up")
        let bar = line(word("OFFER", 0.05, 0.20), word("RIDE", 0.22, 0.40), word("e", 0.45, 0.50), word("LUCIA", 0.56, 0.75))
        XCTAssertEqual(ButtonIcons.markFree(bar, frame: frame(178)).text, "OFFER RIDE \(marker) LUCIA")
    }

    func testBothEdgesCanBeCutWithoutClipping() throws {
        let image = frame(4, 377)
        let bar = line(word("SELECT", 30.0 / 400, 0.7), word("ITEM", 0.73, 371.0 / 400))
        let marked = ButtonIcons.markFree(bar, frame: image)
        XCTAssertEqual(marked.text, "\(marker) SELECT ITEM \(marker)")
        let icons = ButtonIcons.withImages(try XCTUnwrap(marked.icons), frame: image)
        XCTAssertEqual(icons.count, 2)
        for icon in icons {
            XCTAssertGreaterThanOrEqual(icon.box.left, 0)
            XCTAssertLessThanOrEqual(icon.box.right, 1)
            XCTAssertNotNil(icon.image)
        }
    }

    func testAdjacentShoulderButtonsAndUnconfirmedSymbol() throws {
        let image = frame(122, 150)
        let bar = line(word("SELECT", 0.05, 0.26), word("L1", 0.30, 0.355), word("R1", 0.37, 0.43))
        let marked = ButtonIcons.markFree(bar, frame: image)
        XCTAssertEqual(marked.text, "SELECT \(marker) \(marker)")
        let icons = ButtonIcons.withImages(try XCTUnwrap(marked.icons), frame: image)
        XCTAssertEqual(icons.map(\.text), ["L1", "R1"])
        if icons.count == 2 { XCTAssertLessThanOrEqual(icons[0].box.right, icons[1].box.left) }
        XCTAssertTrue(icons.allSatisfy { $0.image != nil })

        let secondOnly = line(word("SELECT", 0.05, 0.26), word("○", 0.30, 0.355), word("R1", 0.37, 0.43))
        let mixed = ButtonIcons.markFree(secondOnly, frame: frame(150))
        XCTAssertEqual(mixed.text, "SELECT ○ \(marker)")
        XCTAssertEqual(mixed.icons?.map(\.text), ["R1"])
    }

    func testMeasuredButtonIncludesItsOutline() throws {
        let image = frame(120)
        let bar = line(word("SELECT", 0.05, 0.26), word("R1", 124.0 / 400, 134.0 / 400))
        let marked = ButtonIcons.markFree(bar, frame: image)
        let icons = ButtonIcons.withImages(try XCTUnwrap(marked.icons), frame: image)
        XCTAssertEqual(icons.count, 1)
        let expected = try XCTUnwrap(ButtonIcons.crop(image, TextBox(left: 0.28, top: 0.1, right: 0.36, bottom: 0.9)))
        XCTAssertEqual(icons.first?.image, expected)
    }

    func testGroupingKeepsTheRecoveredImageWithItsParagraph() throws {
        let reading = Reading(lines: [line(word("R2", 0.05, 0.11), word("Swing", 0.13, 0.28)),
                                      line(word("Incoming", 0.65, 0.79), word("call", 0.8, 0.89))])
        let candidate = RegionWatcher.candidate(reading, in: full, frame: frame(22))
        XCTAssertEqual(candidate.blocks?.count, 2)
        // Satır başındaki tuş simgesi çeviriye girmez, kutunun dışında kalır; ekranda görünür (#860).
        XCTAssertEqual(candidate.paragraphs, ["Swing", "Incoming call"])
        XCTAssertNil(candidate.icons)
        let swing = try XCTUnwrap(candidate.blocks?.first)
        XCTAssertGreaterThanOrEqual(swing.box.left, 0.11)
    }

    /// "Ekranı çevir"de tuş ipucu atılmaz: etiketi kendi kutusunda çevrilir, tuş ("R2") çeviriye girmez ve ekranda
    /// özgün haliyle görünür kalır (simgesi görünse de görünmese de; GTA 6 tuş çubuğu ve etkileşim seçenekleri).
    func testFullScreenTranslatesThePromptLabelAndLeavesTheButton() async throws {
        let reading = Reading(lines: [line(word("R2", 0.05, 0.11), word("Swing", 0.13, 0.28))])
        for image in [frame(), frame(22)] {
            var calls: [String] = []
            let items = try await ScreenTranslation.translate(reading, using: { source in
                calls.append(source)
                return "TR: " + source
            }, frame: image)
            XCTAssertEqual(calls, ["Swing"])
            XCTAssertEqual(items.map(\.translation), ["TR: Swing"])
            XCTAssertEqual(items.first?.box.left, 0.13)
            XCTAssertNil(items.first?.icons)
        }
    }

    func testCommandGlossaryPreservesMarkersAndFallsBackForUnknownCommands() {
        XCTAssertEqual(UiCommands.translate("SET DESTINATION \(marker) EXIT \(marker)"), "Hedef belirle \(marker) Çıkış \(marker)")
        XCTAssertEqual(UiCommands.translate("OPEN \(marker)"), "Aç \(marker)")
        XCTAssertEqual(UiCommands.translate("REFUEL"), "Yakıt al")
        XCTAssertNil(UiCommands.translate("Open the door"))
        XCTAssertNil(UiCommands.translate("LAUNCH ROCKETS \(marker) EXIT"))
    }
}
