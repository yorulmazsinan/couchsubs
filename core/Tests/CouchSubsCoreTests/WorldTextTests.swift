// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Oyun dünyasındaki yazı (poster, plaka, tabela) çevrilmez; yalnız arayüz kanıtı olan yazı (düz panel zemini, yerinde
/// sabitlik, perspektifsiz satırlar). Sentetik: dokulu sahne kamerayla kayar, üstünde dünya yazısı; sabit HUD kutusu
/// (Windows WorldTextTests ile aynı).
final class WorldTextTests: XCTestCase {
    private static let texture: [UInt8] = {
        var generator = ScreenTextDetectorTests.SplitMix(seed: 3)
        return (0..<(1280 * 360)).map { _ in UInt8(generator.next() % 110) }
    }()

    /// 640x360 kare: `pan` piksel kaymış dokulu sahne, sahnenin üstünde dünya yazısı (dokulu zeminde açık çizgiler,
    /// kamerayla kayar), isteğe bağlı sabit HUD kutusu (düz koyu zeminde beyaz yazı, sol üstte).
    static func scene(pan: Int, hud: Bool, worldText: Bool = true) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: 640 * 360 * 4)
        func set(_ x: Int, _ y: Int, _ value: UInt8) {
            let p = (y * 640 + x) * 4
            (pixels[p], pixels[p + 1], pixels[p + 2]) = (value, value, value)
        }
        for y in 0..<360 {
            for x in 0..<640 {
                let sx = x + pan
                var value = texture[y * 1280 + sx % 1280]
                if worldText, (300..<460).contains(sx), (200..<260).contains(y), [3, 4].contains((y - 200) % 9), (sx - 300) % 7 < 4 {
                    value = 235
                }
                set(x, y, value)
            }
        }
        if hud {
            for y in 20..<80 { for x in 20..<180 { set(x, y, [3, 4].contains((y - 20) % 9) && (x - 20) % 7 < 4 ? 240 : 28) } }
        }
        return ScreenTextDetectorTests.image(pixels, width: 640, height: 360)
    }

    func testPanningCameraFindsTheHudButNotTheWorldText() throws {
        let detector = ScreenTextDetector()
        var worldAreas = 0
        for step in 0..<30 {
            detector.sample(Self.scene(pan: step * 8, hud: true), now: step * 100, excluded: [])
            worldAreas += detector.areas.filter { $0.region.top > 0.4 }.count
        }
        XCTAssertEqual(worldAreas, 0)
        XCTAssertEqual(detector.areas.count, 1)
        let hud = try XCTUnwrap(detector.areas.first)
        XCTAssertTrue(hud.region.left < 0.1 && hud.region.top < 0.1)
    }

    func testStillCameraDoesNotTurnTexturedWorldTextIntoAnArea() {
        let detector = ScreenTextDetector()
        for step in 0..<20 { detector.sample(Self.scene(pan: 0, hud: false), now: step * 100, excluded: []) }
        XCTAssertTrue(detector.areas.isEmpty)
    }

    private final class Reader: TextReader, @unchecked Sendable {
        var box = TextBox(left: 0.1, top: 0.3, right: 0.9, bottom: 0.5)
        func read(_ image: CGImage) throws -> String { "" }
        func read(_ image: CGImage, deep: Bool) throws -> String { "" }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
            Reading(lines: [TextLine("Bean Machine Coffee and Donuts", box: box)])
        }
    }

    private final class Translator: TextTranslator {
        var calls = 0
        func translate(_ text: String) async throws -> String {
            calls += 1
            return "Kahve dükkânı"
        }
    }

    private final class Server: RegionSending {
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {}
        func clearRegions() {}
    }

    @MainActor
    func testSameTextSeenElsewhereIsWorldTextFromThenOn() async {
        let translator = Translator()
        var rejected: [String] = []
        let watcher = RegionWatcher(reader: Reader(), translator: translator, server: Server())
        watcher.onAutoRejected = { rejected.append($0) }
        let first = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName,
                              region: CropRegion(top: 0.1, bottom: 0.3, left: 0.1, right: 0.5), auto: true)
        let frame = { (shade: UInt8) in ScreenTextDetectorTests.image([UInt8](repeating: shade, count: 320 * 180 * 4), width: 320, height: 180) }
        await watcher.pass(frame(10), areas: [first])
        await watcher.pass(frame(10), areas: [first])
        XCTAssertEqual(translator.calls, 1)
        // Kamera kaydı: aynı tabela başka yerde okundu → dünya yazısı; artık hiçbir yerde çevrilmez.
        let moved = ExtraArea(id: "auto-2", name: ScreenTextDetector.areaName,
                              region: CropRegion(top: 0.4, bottom: 0.6, left: 0.3, right: 0.7), auto: true)
        await watcher.pass(frame(20), areas: [moved])
        await watcher.pass(frame(20), areas: [moved])
        XCTAssertTrue(rejected.contains("auto-2"))
        XCTAssertEqual(translator.calls, 1)
    }
}
