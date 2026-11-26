// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// Harita düzeni (#1365): GTA 6 Harita › STORY ekranı (koyu panelde görev listesi, görev kartı, haritanın üstünde tuş
/// çubuğu) menü sayılır; liste tek alanda okunur, hazır alanlar yer verir; kamera oynayan ya da karanlık oyun sahnesi menü
/// sayılmaz. Ortak deneme dosyası Fixtures/map-layout.json (Windows MapLayoutTests.cs, Android MapLayoutTest.kt aynı).
final class MapLayoutTests: XCTestCase {
    struct Text: Decodable {
        var role: String
        var column: Int
        var row: Int
        var width: Int
        var kind: String
    }

    struct Box: Decodable {
        var cells: [Int]
        var fill: Int
    }

    struct Panel: Decodable {
        var side: String
        var columns: Int
        var fill: Int
    }

    struct Expect: Decodable {
        var menu: Bool
        var mapLayout: Bool
        var together: [String]?
        var apart: [[String]]?
        var presetsYield: Bool?
    }

    struct Scene: Decodable {
        var name: String
        var map: Int
        var texture: Bool
        var moving: Bool
        var mirror: Bool?
        var panel: Panel?
        var boxes: [Box]
        var texts: [Text]
        var untilMs: Int
        var expect: Expect
    }

    struct Fixture: Decodable { var scenes: [Scene] }

    static func load() throws -> [Scene] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("map-layout.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).scenes
    }

    static let width = 640, height = 360, tile = 20

    /// Aynalanmış sahne (sütunlar öbür yana).
    static func mirrored(_ scene: Scene) -> Scene {
        guard scene.mirror == true else { return scene }
        var scene = scene
        scene.texts = scene.texts.map { var t = $0; t.column = 32 - t.column - t.width; return t }
        scene.boxes = scene.boxes.map { var b = $0; b.cells = [31 - b.cells[2], b.cells[1], 31 - b.cells[0], b.cells[3]]; return b }
        if var panel = scene.panel {
            panel.side = panel.side == "left" ? "right" : "left"
            scene.panel = panel
        }
        return scene
    }

    /// Sahnenin `phase` anındaki karesi (gri tonlu RGBA).
    static func pixels(_ scene: Scene, phase: Int) -> [UInt8] {
        var gray = [UInt8](repeating: UInt8(scene.map), count: width * height)
        func set(_ x: Int, _ y: Int, _ v: Int) { gray[y * width + x] = UInt8(v) }
        let panelColumns: Set<Int> = scene.panel.map { panel in
            Set(panel.side == "left" ? Array(0..<panel.columns) : Array((32 - panel.columns)..<32))
        } ?? []
        for row in 0..<18 {
            for column in 0..<32 {
                let x0 = column * tile, y0 = row * tile
                if panelColumns.contains(column) {
                    for y in y0..<(y0 + tile) { for x in x0..<(x0 + tile) { set(x, y, scene.panel!.fill) } }
                } else if scene.texture && (column + row) % 3 != 0 {
                    let shift = scene.moving ? phase % 3 : 0
                    for y in y0..<(y0 + tile) { for x in x0..<(x0 + tile) { set(x, y, (y + shift) % 3 == 0 ? 200 : 120) } }
                }
            }
        }
        for box in scene.boxes {
            for y in (box.cells[1] * tile)..<((box.cells[3] + 1) * tile) {
                for x in (box.cells[0] * tile)..<((box.cells[2] + 1) * tile) { set(x, y, box.fill) }
            }
        }
        for text in scene.texts {
            let y0 = text.row * tile
            for y in (y0 + 3)..<(y0 + 17) {
                let r = (y - y0) % 6
                for x in (text.column * tile)..<((text.column + text.width) * tile) {
                    let stroke = x % 5 < 2
                    if text.kind == "dark" {
                        set(x, y, [2, 3].contains(r) && stroke ? 240 : 24)
                    } else if [2, 3].contains(r) && stroke {
                        set(x, y, 240)
                    } else if [1, 4].contains(r) && stroke {
                        set(x, y, 40)
                    }
                }
            }
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { (rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2]) = (gray[i], gray[i], gray[i]) }
        return rgba
    }

    static func center(_ text: Text) -> (x: Double, y: Double) {
        ((Double(text.column) + Double(text.width) / 2) / 32, (Double(text.row) + 0.5) / 18)
    }

    static func holder(_ areas: [ExtraArea], _ text: Text) -> ExtraArea? {
        let c = center(text)
        return areas.first { c.x >= $0.region.left && c.x <= $0.region.right && c.y >= $0.region.top && c.y <= $0.region.bottom }
    }

    @MainActor
    func testMapLayoutScenes() throws {
        for original in try Self.load() {
            let scene = Self.mirrored(original)
            let detector = ScreenTextDetector()
            var notes: [String] = []
            detector.onLog = { notes.append($0) }
            for time in stride(from: 0, through: scene.untilMs, by: ScreenTextDetector.sampleIntervalMs) {
                let image = ScreenTextDetectorTests.image(Self.pixels(scene, phase: time / 100), width: Self.width, height: Self.height)
                detector.sample(image, now: time, excluded: [CropRegion()])
            }
            XCTAssertEqual(detector.inMenu, scene.expect.menu, scene.name)
            XCTAssertEqual(detector.inMapLayout, scene.expect.mapLayout, scene.name)
            if scene.expect.mapLayout {
                XCTAssertTrue(notes.contains { $0.hasPrefix("ekran menüsü: harita düzeni bulundu") }, "\(scene.name): \(notes)")
            }
            let areas = detector.areas
            for role in scene.expect.together ?? [] {
                let held = scene.texts.filter { $0.role == role }.map { Self.holder(areas, $0)?.id }
                XCTAssertFalse(held.contains(nil), "\(scene.name): \(role) alansız")
                XCTAssertEqual(Set(held).count, 1, "\(scene.name): \(role) bölündü")
            }
            for pair in scene.expect.apart ?? [] {
                let a = Set(scene.texts.filter { $0.role == pair[0] }.compactMap { Self.holder(areas, $0)?.id })
                let b = Set(scene.texts.filter { $0.role == pair[1] }.compactMap { Self.holder(areas, $0)?.id })
                XCTAssertTrue(a.isDisjoint(with: b), "\(scene.name): \(pair) aynı alanda")
            }
            if scene.expect.presetsYield == true {
                let kept = RegionWatcher.yieldingPresets(GameAreaPresets.areas("GTA 6") + areas)
                XCTAssertFalse(kept.contains { GameAreaPresets.isPreset($0.id) }, "\(scene.name): hazır alan okunuyor")
            }
        }
    }

    /// Düzen karolara bakar: sentetik karo tonlarıyla (çizimsiz) sol panel bulunur, panelsiz ya da koyu haritada bulunmaz.
    func testMapPanelFromTileTones() {
        func panel(_ tone: (Int, Int) -> Double, text: Set<Int> = [], steady: Bool = true) -> (left: Bool, width: Int)? {
            ScreenTextDetector.mapPanel(text: { text.contains($0) }) { index in (tone(index % 32, index / 32), steady) }
        }
        let list = Set((1...6).flatMap { row in (1...6).map { row * 32 + $0 } })
        let found = panel({ column, _ in column < 9 ? 45 : 160 }, text: list)
        XCTAssertEqual(found?.left, true)
        XCTAssertEqual(found?.width, 9)
        XCTAssertNil(panel({ column, _ in column < 9 ? 45 : 160 }), "panelde liste yok")
        XCTAssertNil(panel({ column, _ in column < 9 ? 45 : 160 }, text: list, steady: false), "harita oynuyor")
        XCTAssertNil(panel({ column, _ in column < 9 ? 45 : 60 }, text: list), "yanı da karanlık")
        XCTAssertNil(panel({ column, row in column < 9 && row < 12 ? 45 : 160 }, text: list), "panel tam boy değil")
        let right = Set((1...6).flatMap { row in (25...30).map { row * 32 + $0 } })
        XCTAssertEqual(panel({ column, _ in column >= 23 ? 45 : 160 }, text: right)?.left, false)
    }
}
