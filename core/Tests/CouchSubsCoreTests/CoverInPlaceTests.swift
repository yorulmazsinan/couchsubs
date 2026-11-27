// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CouchSubsCore

/// Sinan Bey: #1300/#1320'den beri menü, görev kartı ve istem Türkçesi yanına ya da ikiz kutuya yazılıyordu; yer her okumada
/// boş alana göre yeniden seçildiği için ekranda kararlı durmuyordu. Varsayılan yine yerinde örtme: Türkçe özgün yazının
/// kendi dikdörtgenine, o kutunun ölçülen zemin renginde çizilir; simge ve kişi resmi örtülmez. Yanına yazma yalnız
/// "Menülerde Türkçeyi yanına yaz" açıkken (`RegionWatcher.writesBeside`). Gerçek GTA 6 menü/görev kartı kareleri
/// (testdata/frames, kayıtlı okumalar ocr/screen; yazı tanıma koşmaz). Windows (CoverInPlaceTests.cs) ve Android
/// (CoverInPlaceTest.kt) aynı kuralları sınar.
@MainActor
final class CoverInPlaceTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Screen: Decodable { let clear: [[Double]]? }
        struct Frame: Decodable { let id: String; let file: String; let screen: Screen? }
        let frames: [Frame]
    }
    private struct Fixture: Decodable {
        struct Word: Decodable { let text: String; let box: [Double] }
        struct Line: Decodable { let text: String; let box: [Double]?; let confidence: Double?; let words: [Word]? }
        struct Area: Decodable { let id: String; let menu: Bool?; let region: [Double]; let lines: [Line] }
        let areas: [Area]
    }

    private static func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    private struct Shot { let id: String; let image: CGImage; let clear: [TextBox]; let areas: [(region: CropRegion, reading: Reading, menu: Bool)] }

    private func shots() throws -> [Shot] {
        let directory = FrameReplayTests.directory
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("frames.json")))
        return try manifest.frames.compactMap { frame in
            guard let screen = frame.screen else { return nil }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("ocr/screen/\(frame.id).json")))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent(frame.file) as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let areas = fixture.areas.filter { !$0.lines.isEmpty }.map { area in
                (region: CropRegion(top: area.region[1], bottom: area.region[3], left: area.region[0], right: area.region[2]),
                 reading: Reading(lines: area.lines.map { line in
                     TextLine(line.text, box: line.box.map(Self.box), confidence: line.confidence,
                              words: line.words?.map { TextWord($0.text, box: Self.box($0.box)) })
                 }), menu: area.menu ?? false)
            }
            return Shot(id: frame.id, image: image, clear: (screen.clear ?? []).map(Self.box), areas: areas)
        }
    }

    private func blocks(_ shot: Shot, beside: Bool) -> [[RegionWatcher.Block]] {
        let screen = RegionWatcher.ScreenFrame(shot.image)
        return shot.areas.map { area in
            let crop = RegionCropper.crop(shot.image, to: area.region)
            let candidate = RegionWatcher.candidate(area.reading, in: area.region, frame: crop, auto: true, menu: area.menu,
                                                    styled: true, kind: area.menu ? .menu : nil, screen: screen, beside: beside)
            return candidate.blocks ?? []
        }
    }

    private static func intersects(_ a: TextBox, _ b: TextBox) -> Bool {
        min(a.right, b.right) > max(a.left, b.left) + 1.0 / 1920 && min(a.bottom, b.bottom) > max(a.top, b.top) + 1.0 / 1080
    }

    /// Varsayılan: her blok yerinde örtülür (yanına yazma ya da ikiz yok), örtü özgün yazının kendi yerinde (satır
    /// yüksekliğinin en çok yarısı sapma), zemin o kutudan ölçülmüş renk, simge ve kişi resmi açıkta; iki ardışık okuma aynı
    /// çizimi verir (her okumada yeniden karar yok).
    func testMenusCardsAndPromptsAreCoveredInPlaceByDefault() throws {
        let all = try shots()
        XCTAssertEqual(all.count, 3)
        for shot in all {
            let first = blocks(shot, beside: false)
            let second = blocks(shot, beside: false)
            XCTAssertEqual(first, second, "\(shot.id): ardışık okumalar farklı çizildi")
            var painted = 0
            for block in first.joined() {
                guard let paint = block.paint else { continue }
                painted += 1
                XCTAssertEqual(paint.mode, .cover, "\(shot.id)")
                XCTAssertNil(paint.twin, shot.id)
                XCTAssertNil(paint.spot, shot.id)
                XCTAssertTrue(paint.background.hasPrefix("#"), shot.id)
                let line = max(1e-6, block.lineHeight)
                XCTAssertLessThanOrEqual(abs(paint.cover.top - block.box.top) / line, 0.5, "\(shot.id): örtü yazının yerinde değil")
                XCTAssertLessThanOrEqual(abs(paint.cover.bottom - block.box.bottom) / line, 0.5, "\(shot.id): örtü yazının yerinde değil")
                for zone in shot.clear {
                    XCTAssertFalse(Self.intersects(paint.cover, zone), "\(shot.id): örtü simgeye/kişi resmine biniyor \(zone)")
                }
            }
            XCTAssertGreaterThan(painted, 3, shot.id)
        }
    }

    /// "Menülerde Türkçeyi yanına yaz" açıkken eski yerleşim (yanına yazma, ikiz kutu) sürer.
    func testBesideStaysAvailableAsAnOption() throws {
        let modes = try shots().flatMap { blocks($0, beside: true).joined().compactMap(\.paint?.mode) }
        print("yanına yazma açık: \(Dictionary(grouping: modes, by: \.rawValue).mapValues(\.count))")
        XCTAssertTrue(modes.contains { $0 != .cover }, "\(modes)")
    }

    func testOnlyUiKindsAreCoveredScenesKeepTheirKind() {
        XCTAssertNil(RegionWatcher.inPlaceKind(.menu, beside: false))
        XCTAssertNil(RegionWatcher.inPlaceKind(.mission, beside: false))
        XCTAssertNil(RegionWatcher.inPlaceKind(.help, beside: false))
        // Oyun dünyasındaki tabela ve sahne yazısı (#1300) türünü korur.
        XCTAssertEqual(RegionWatcher.inPlaceKind(.other, beside: false), .other)
        XCTAssertEqual(RegionWatcher.inPlaceKind(.menu, beside: true), .menu)
        var twin = TextPaint(background: "#203040", pitch: 0.03, cover: TextBox(left: 0.1, top: 0.1, right: 0.3, bottom: 0.13))
        twin.mode = .twin
        twin.twin = TextBox(left: 0.4, top: 0.1, right: 0.6, bottom: 0.2)
        twin.spot = TextBox(left: 0.41, top: 0.11, right: 0.59, bottom: 0.14)
        let covered = RegionWatcher.coveredInPlace(twin)
        XCTAssertEqual(covered.mode, .cover)
        XCTAssertEqual(covered.cover, twin.cover)
        XCTAssertEqual(covered.background, "#203040")
        XCTAssertNil(covered.twin)
        XCTAssertNil(covered.spot)
    }

    /// Ayar dört platformda aynı adla ve kapalı gelir; eski kayıtlarda yoktur.
    func testSettingDefaultsOffAndDecodesFromOldRecords() throws {
        XCTAssertFalse(UserSettings().screenTextBeside)
        let old = try JSONDecoder().decode(UserSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.screenTextBeside)
        var on = UserSettings()
        on.screenTextBeside = true
        let back = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(back.screenTextBeside)
    }
}
