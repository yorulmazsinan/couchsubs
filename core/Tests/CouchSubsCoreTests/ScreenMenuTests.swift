// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Ekrandaki menüler (Windows ScreenMenuTests ve Android ScreenMenuTest ile aynı sentetik tekerlek menü).
final class ScreenMenuTests: XCTestCase {
    // 640x360 karede karo 20x20 piksel. Tekerlek menünün sekiz etiketi, ortada başlık ve gri alt başlık.
    private static let labels: [(column: Int, row: Int, width: Int)] =
        [(8, 4, 1), (16, 2, 1), (24, 4, 1), (27, 9, 1), (24, 14, 1), (16, 16, 1), (8, 14, 1), (4, 9, 1)]

    private struct Canvas {
        var pixels: [UInt8]
        let width = 640, height = 360
        init(fill: UInt8) { pixels = [UInt8](repeating: fill, count: 640 * 360 * 4) }
        mutating func set(_ x: Int, _ y: Int, _ value: UInt8) {
            let p = (y * width + x) * 4
            (pixels[p], pixels[p + 1], pixels[p + 2]) = (value, value, value)
        }
        mutating func paint(_ column: Int, _ row: Int, _ width: Int, ink: UInt8) {
            for y in (row * 20 + 3)..<(row * 20 + 17) {
                for x in (column * 20)..<((column + width) * 20) {
                    set(x, y, [2, 3].contains((y - row * 20) % 6) && x % 5 < 2 ? ink : 24)
                }
            }
        }
        var image: CGImage { ScreenTextDetectorTests.image(pixels, width: width, height: height) }
    }

    /// Bulanık (düz gri) zeminde tekerlek menü.
    private static func wheel() -> Canvas {
        var canvas = Canvas(fill: 70)
        for label in labels { canvas.paint(label.column, label.row, label.width, ink: 240) }
        canvas.paint(13, 8, 6, ink: 240)
        canvas.paint(14, 10, 4, ink: 175)
        return canvas
    }

    private func run(_ detector: ScreenTextDetector, _ from: Int, _ to: Int, _ frame: (Int) -> CGImage) {
        for time in stride(from: from, through: to, by: ScreenTextDetector.sampleIntervalMs) {
            detector.sample(frame(time), now: time, excluded: [])
        }
    }

    func testWheelMenuIsDetectedWithItsShortLabels() {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { _ in Self.wheel().image }
        XCTAssertTrue(detector.inMenu)
        XCTAssertEqual(detector.areas.count, 10)
        XCTAssertTrue(detector.areas.allSatisfy { $0.menu && $0.auto })
    }

    func testClosingTheMenuRemovesEveryBoxAtOnce() {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { _ in Self.wheel().image }
        XCTAssertFalse(detector.areas.isEmpty)
        detector.sample(Canvas(fill: 70).image, now: 500, excluded: [])
        XCTAssertFalse(detector.inMenu)
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testNavigatingKeepsTheOtherBoxes() {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { _ in Self.wheel().image }
        let before = Set(detector.areas.map(\.id))
        // Seçim çerçevesi bir etiketin üstüne geçti: o etiketin karosu değişti, diğerleri yerinde.
        run(detector, 500, 800) { time in
            var canvas = Self.wheel()
            canvas.paint(8, 4, 1, ink: time % 200 == 0 ? 200 : 250)
            for x in 160..<180 {
                let p = ((4 * 20 + 1) * canvas.width + x) * 4
                canvas.pixels[p] = UInt8(truncatingIfNeeded: time / 10)
            }
            return canvas.image
        }
        XCTAssertTrue(detector.inMenu)
        XCTAssertGreaterThanOrEqual(detector.areas.filter { before.contains($0.id) }.count, 9)
    }

    /// Menü kapandıktan sonra sakin (karanlık) sahnede ayrı ayrı belirmiş üç yazı (görev satırı, PS5 bildirimi, HUD)
    /// menüyü sürdürmez. GTA 6 "Gone Fishing" (Mac ve iPhone günlükleri, 2026-11-22): menü durumu bitmedi, altyazı
    /// bütün oturum okunmadı; diyalog ve görev satırı yalnız ekran yazısı olarak çevrildi.
    func testMenuEndsWhenItsOwnLabelsLeaveEvenIfOtherTextStays() {
        let scene: [(column: Int, row: Int, width: Int, from: Int)] = [(1, 0, 2, 500), (29, 0, 2, 900), (1, 17, 3, 1300)]
        func frame(_ time: Int, wheel: Bool) -> CGImage {
            var canvas = wheel ? Self.wheel() : Canvas(fill: 70)
            for label in scene where time >= label.from { canvas.paint(label.column, label.row, label.width, ink: 240) }
            return canvas.image
        }
        let detector = ScreenTextDetector()
        run(detector, 0, 1900) { frame($0, wheel: true) }
        XCTAssertTrue(detector.inMenu)
        // Eski kuralda (menü yalnız "≥3 bileşen + sakin zemin" ile sürüyordu) burada menü durumu hiç bitmiyordu.
        run(detector, 2000, 4000) { frame($0, wheel: false) }
        XCTAssertFalse(detector.inMenu)
    }

    /// Menüde hiçbir şey değişmeden 5 sn geçince menü durumu biter ve aynı yazılarla yeniden açılmaz: menü sanılan sabit
    /// HUD altyazıyı en çok 5 sn susturur. Yeni beliren bir menü yeniden menü sayılır.
    func testStillMenuExpiresAndOnlyANewMenuReopens() {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { _ in Self.wheel().image }
        XCTAssertTrue(detector.inMenu)
        run(detector, 500, 5000) { _ in Self.wheel().image }
        XCTAssertTrue(detector.inMenu)
        run(detector, 5100, 8000) { _ in Self.wheel().image }
        XCTAssertFalse(detector.inMenu)
        run(detector, 8100, 8200) { _ in Canvas(fill: 70).image }
        run(detector, 8300, 8800) { _ in Self.wheel().image }
        XCTAssertTrue(detector.inMenu)
    }

    func testLabelsOnABusyMovingSceneAreNotAMenu() {
        let detector = ScreenTextDetector()
        run(detector, 0, 1000) { time in
            var generator = ScreenTextDetectorTests.SplitMix(seed: UInt64(time) &+ 7)
            var canvas = Canvas(fill: 0)
            for i in 0..<canvas.pixels.count { canvas.pixels[i] = UInt8(truncatingIfNeeded: generator.next()) }
            for label in Self.labels { canvas.paint(label.column, label.row, label.width, ink: 240) }
            return canvas.image
        }
        XCTAssertFalse(detector.inMenu)
    }

    func testShortLabelsAreTranslatedOnlyInAMenu() {
        for (text, noiseInMenu) in [("OFF", false), ("ON", false), ("OUTFITS", false), ("CURRENT OUTFIT", false),
                                    ("40", true), ("0", true), ("x3", true), ("100%", true)] {
            XCTAssertEqual(ScreenTextNoise.isNoise(text, menu: true), noiseInMenu, text)
            XCTAssertTrue(ScreenTextNoise.isNoise(text, menu: false), text)
        }
    }

    func testShortLabelsComeFromTheDictionaryKeepingTheirCase() {
        for (label, turkish) in [("OFF", "KAPALI"), ("Off", "Kapalı"), ("off", "kapalı"), ("ON", "AÇIK"),
                                 ("SETTINGS", "AYARLAR"), ("Inventory", "Envanter"), ("STATS", "İSTATİSTİKLER"),
                                 ("EXIT", "ÇIKIŞ")] {
            XCTAssertEqual(UiCommands.translateLabel(label), turkish, label)
        }
        XCTAssertNil(UiCommands.translateLabel("CURRENT OUTFIT"))
        XCTAssertNil(UiCommands.translateLabel("40"))
    }
}
