// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Hazır ek alanda arayüz kutusu kanıtı (Windows: UiPanelTests.cs ve RegionWatcherTests'teki hazır alan testleri; aynı kareler).
@MainActor
final class UiPanelTests: XCTestCase {
    /// Oyun dünyası: geniş ve sert parlaklık dalgalanması (Windows'taki Texture ile aynı).
    static func texture(_ x: Int, _ y: Int) -> UInt8 {
        UInt8(60 + ((x * 7 + y * 13) % 23) * 6 + ((x / 11 + y / 7) % 2) * 40)
    }

    /// Bölge: `ground` zemin (nil: dokulu dünya), sol üstte iki satır yazı çizgisi (`text` parlaklığında).
    static func region(_ ground: ((Int, Int) -> UInt8)?, text: UInt8, withText: Bool = true,
                       width: Int = 400, height: Int = 200) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var value = ground?(x, y) ?? texture(x, y)
                if withText, x >= 20, x < 260, (y >= 30 && y < 52) || (y >= 70 && y < 92), x % 9 < 3 { value = text }
                pixels[y * width + x] = value
            }
        }
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        return context!.makeImage()!
    }

    func testDarkPanelWithWhiteTextIsInterface() {
        XCTAssertTrue(UiPanel.hasText(Self.region({ _, _ in 28 }, text: 235)))
    }

    func testLightPanelWithDarkTextIsInterface() {
        XCTAssertTrue(UiPanel.hasText(Self.region({ _, _ in 225 }, text: 30)))
    }

    func testSemiTransparentPanelOverTheWorldIsInterface() {
        XCTAssertTrue(UiPanel.hasText(Self.region({ x, y in UInt8(30 + (Int(Self.texture(x, y)) - 60) / 30) }, text: 230)))
    }

    func testTextOnTheGameWorldIsNotInterface() {
        XCTAssertFalse(UiPanel.hasText(Self.region(nil, text: 245)))
    }

    func testFlatAreaWithoutTextIsNotInterface() {
        XCTAssertFalse(UiPanel.hasText(Self.region({ _, _ in 40 }, text: 40, withText: false)))
    }

    func testPanelOnlyInOneCornerOfTheAreaStillCounts() {
        XCTAssertTrue(UiPanel.hasText(Self.region({ x, y in x < 280 && y < 110 ? 26 : Self.texture(x, y) }, text: 235)))
    }

    func testGameAreaPresetsAreRecognized() {
        XCTAssertTrue(GameAreaPresets.areas("GTA 6").allSatisfy { GameAreaPresets.isPreset($0.id) })
        XCTAssertFalse(GameAreaPresets.isPreset("auto-1"))
    }

    private final class Reader: TextReader, @unchecked Sendable {
        var lines: [TextLine] = []
        var count = 0
        func read(_ image: CGImage) throws -> String { lines.map(\.text).joined(separator: "\n") }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { count += 1; return Reading(lines: lines) }
    }

    private final class Translator: TextTranslator {
        func translate(_ text: String) async throws -> String { "TR: " + text }
    }

    private final class Server: RegionSending {
        var sent: [(id: String, text: String)] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) { sent.append((id, text)) }
        func clearRegions() {}
    }

    private let help = ExtraArea(id: GameAreaPresets.helpId, name: "Help", region: CropRegion(top: 0, bottom: 1, left: 0, right: 1))
    private func frame(panel: Bool) -> CGImage { Self.region(panel ? { _, _ in 28 } : nil, text: 240, width: 320, height: 180) }

    /// Oyun yanlış seçiliyse (PS5 ana ekranı, başka oyun) ya da bölgede yalnız dünya yazısı varsa hazır alan çevrilmez.
    func testPresetAreaWithoutAnInterfacePanelIsNeverRead() async {
        let reader = Reader(), server = Server()
        reader.lines = [TextLine("LIQUOR STORE OPEN 24 HOURS", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))]
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server)
        for _ in 0..<3 { await watcher.pass(frame(panel: false), areas: [help]) }
        XCTAssertEqual(reader.count, 0)
        XCTAssertTrue(server.sent.isEmpty)
    }

    func testPresetAreaOnAPanelIsTranslatedAndRemovedWhenThePanelGoes() async {
        let reader = Reader(), server = Server()
        reader.lines = [TextLine("Follow Vicki to the car.", box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))]
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server)
        await watcher.pass(frame(panel: true), areas: [help])
        await watcher.pass(frame(panel: true), areas: [help])
        XCTAssertTrue(server.sent.contains { $0.id == GameAreaPresets.helpId && $0.text == "TR: Follow Vicki to the car." })
        await watcher.pass(frame(panel: false), areas: [help])
        XCTAssertEqual(server.sent.last?.id, GameAreaPresets.helpId)
        XCTAssertEqual(server.sent.last?.text, "")
    }
}
