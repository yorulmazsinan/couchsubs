// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Windows TextStyleSamplerTests ve Android TextStyleSamplerTest ile aynı sentetik görüntüler.
final class TextStyleSamplerTests: XCTestCase {
    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    /// Düz zeminde dikey çizgilerden "yazı": her 10 pikselde `stroke` piksel yazı rengi.
    static func text(_ ground: RGB, _ ink: RGB, stroke: Int, width: Int = 400, height: Int = 60,
                     noise: ((Int) -> UInt8)? = nil) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var n = 0
        for y in 0..<height {
            for x in 0..<width {
                let isInk = (15..<45).contains(y) && x % 10 < stroke
                let p = (y * width + x) * 4
                if !isInk, let noise {
                    let value = noise(n)
                    n += 1
                    (pixels[p], pixels[p + 1], pixels[p + 2]) = (value, value, value)
                } else {
                    let c = isInk ? ink : ground
                    (pixels[p], pixels[p + 1], pixels[p + 2]) = (c.r, c.g, c.b)
                }
            }
        }
        return ScreenTextDetectorTests.image(pixels, width: width, height: height)
    }

    private let whole = TextBox(left: 0, top: 10.0 / 60, right: 1, bottom: 50.0 / 60)

    func testDarkBoxWithWhiteTextIsLightOnDarkAndFlat() {
        let (surface, look) = TextStyleSampler.sample(Self.text((20, 22, 30), (240, 240, 240), stroke: 2), box: whole,
                                                      lines: [TextLine("Meet Vicki at the bar tonight", box: whole)],
                                                      source: "Meet Vicki at the bar tonight")
        XCTAssertEqual(surface.background, "#14161E")
        XCTAssertEqual(surface.foreground, "#F0F0F0")
        XCTAssertTrue(look.flat)
        XCTAssertFalse(look.bold)
        XCTAssertFalse(look.upper)
    }

    func testLightGroundWithDarkTextIsDarkOnLight() {
        let (surface, _) = TextStyleSampler.sample(Self.text((235, 235, 225), (15, 15, 15), stroke: 2), box: whole,
                                                   lines: [TextLine("Lamar has sent you a message", box: whole)],
                                                   source: "Lamar has sent you a message")
        XCTAssertEqual(surface.background, "#EBEBE1")
        XCTAssertEqual(surface.foreground, "#0F0F0F")
    }

    func testUppercaseHeavyHeaderIsBoldUpperAndCondensed() {
        let header = TextBox(left: 0, top: 10.0 / 60, right: 0.6, bottom: 50.0 / 60)
        let (_, look) = TextStyleSampler.sample(Self.text((20, 22, 30), (240, 240, 240), stroke: 5), box: header,
                                                lines: [TextLine("ROB VICKI'S BOSS", box: header)], source: "ROB VICKI'S BOSS")
        XCTAssertTrue(look.bold)
        XCTAssertTrue(look.upper)
        XCTAssertTrue(look.condensed)
    }

    func testNoisyGroundIsNotFlat() {
        var generator = ScreenTextDetectorTests.SplitMix(seed: 1)
        let frame = Self.text((60, 60, 60), (250, 250, 250), stroke: 2) { _ in UInt8(10 + generator.next() % 110) }
        let (_, look) = TextStyleSampler.sample(frame, box: whole, lines: [TextLine("Go to the Saloon now", box: whole)],
                                                source: "Go to the Saloon now")
        XCTAssertFalse(look.flat)
    }

    /// #1268 (gerçek karede "ADD MARKER"): kontur yazının zemin kümesi denizle kontur grisinin karışımı; ikisinin parlaklığı
    /// aynı (125) ama rengi değil. Zemin renk sapmasıyla düz sayılmaz, yanındaki şerit de konturlu olduğundan bir şerit ötedeki
    /// düz deniz zemin olur. Android eskiden sapmayı yalnız parlaklıktan ölçüyor, kutuyu grimsi çiziyordu (Windows ve Android
    /// ile aynı görüntü).
    func testLumaFlatButColouredGroundTakesTheFarBand() {
        let (width, height) = (400, 100)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c: RGB = (30..<70).contains(y) && x % 16 < 5 ? (240, 240, 240)
                    : (20..<80).contains(y) && (5..<10).contains(x % 16) ? (125, 125, 125) : (58, 148, 187)
                let p = (y * width + x) * 4
                (pixels[p], pixels[p + 1], pixels[p + 2]) = (c.r, c.g, c.b)
            }
        }
        let frame = ScreenTextDetectorTests.image(pixels, width: width, height: height)
        let box = TextBox(left: 0.1, top: 0.3, right: 0.9, bottom: 0.7)
        let (surface, look) = TextStyleSampler.sample(frame, box: box, lines: [TextLine("ADD MARKER", box: box)],
                                                      source: "ADD MARKER")
        XCTAssertFalse(look.flat)
        XCTAssertLessThanOrEqual(TextPainter.distance(TextPainter.rgb(surface.background), (58, 148, 187)), 8,
                                 surface.background)
        XCTAssertLessThanOrEqual(TextPainter.distance(TextPainter.rgb(surface.foreground), (240, 240, 240)), 8,
                                 surface.foreground)
    }

    func testAlignmentFollowsTheLineEdges() {
        let frame = Self.text((20, 22, 30), (240, 240, 240), stroke: 2)
        func line(_ left: Double, _ right: Double, _ top: Double) -> TextLine {
            TextLine("Some words here", box: TextBox(left: left, top: top, right: right, bottom: top + 0.2))
        }
        XCTAssertEqual(TextStyleSampler.sample(frame, box: whole, lines: [line(0.1, 0.9, 0.1), line(0.1, 0.5, 0.4)], source: "a").look.align, .left)
        XCTAssertEqual(TextStyleSampler.sample(frame, box: whole, lines: [line(0.1, 0.9, 0.1), line(0.3, 0.7, 0.4)], source: "a").look.align, .center)
        XCTAssertEqual(TextStyleSampler.sample(frame, box: whole, lines: [line(0.1, 0.9, 0.1), line(0.5, 0.9, 0.4)], source: "a").look.align, .right)
    }

    func testTurkishUppercaseKeepsDottedI() {
        XCTAssertEqual(TextStyleSampler.turkishUpper("vicki'nin patronunu soy"), "VİCKİ'NİN PATRONUNU SOY")
        XCTAssertEqual(TextStyleSampler.turkishUpper("ılık su"), "ILIK SU")
        XCTAssertTrue(TextStyleSampler.isUpper("ROB VICKI'S BOSS"))
        XCTAssertFalse(TextStyleSampler.isUpper("Rob Vicki's boss"))
    }

    @MainActor
    func testAutoAreaBlocksCarryTheLook() throws {
        let frame = Self.text((20, 22, 30), (240, 240, 240), stroke: 5)
        let header = TextBox(left: 0, top: 10.0 / 60, right: 0.6, bottom: 50.0 / 60)
        let reading = Reading(lines: [TextLine("ROB VICKI'S BOSS", box: header)])
        let whole = CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        let candidate = RegionWatcher.candidate(reading, in: whole, frame: frame, auto: true)
        let block = try XCTUnwrap(candidate.blocks?.first)
        XCTAssertEqual(candidate.blocks?.count, 1)
        XCTAssertEqual(block.look?.upper, true)
        XCTAssertEqual(block.style?.background, "#14161E")
        // Kullanıcının alanında (otomatik değil) tek grup eskisi gibi bloksuzdur.
        XCTAssertNil(RegionWatcher.candidate(reading, in: whole, frame: frame).blocks)
        // Oyunun hazır alanı (GTA 6 yardım kutusu) otomatik alan gibi özgün stilde çizilir; siyah kutu değil (#856).
        let preset = RegionWatcher.candidate(reading, in: whole, frame: frame, styled: true)
        XCTAssertEqual(preset.blocks?.count, 1)
        XCTAssertEqual(preset.blocks?.first?.style?.background, "#14161E")
    }

    /// GTA 6 duraklatma menüsü (#1339): otomatik alan sütunun yazısından yalnız bir karo geniştir. Yanına yazmanın boş alanı
    /// alanın karesinde ölçülünce en uzun satır ("Photo Studio") sağa sığmıyor, liste dağılıp satır örtülüyordu. Boş alan
    /// bütün karede ölçülür: sütunun bütün satırları aynı yanda, Türkçeleri tek hizada (Windows ve Android aynı).
    @MainActor
    func testMenuColumnIsMeasuredOnTheWholeFrame() throws {
        // Mavi zeminde solda simgeli dikey menü (simge 40..52, yazı 60'tan başlar); sağı boş.
        let width = 640, height = 360
        let rows: [(String, Int, Int)] = [("Game", 100, 104), ("Store", 130, 106), ("Help", 160, 92),
                                          ("Photo Studio", 190, 150), ("Settings", 220, 122)]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let ink = rows.contains { _, top, right in
                    (top..<top + 14).contains(y) && ((x >= 40 && x < 52) || (x >= 60 && x < right && x % 6 < 2))
                }
                let p = (y * width + x) * 4
                (pixels[p], pixels[p + 1], pixels[p + 2]) = ink ? (240, 240, 240) : (30, 42, 156)
            }
        }
        let screen = ScreenTextDetectorTests.image(pixels, width: width, height: height)
        // Bulucunun alanı: sütunun karolarından solda ve sağda bir karo (640 piksellik karede karo 20 piksel).
        let region = CropRegion(top: 80.0 / 360, bottom: 260.0 / 360, left: 40.0 / 640, right: 180.0 / 640)
        let crop = try XCTUnwrap(screen.cropping(to: CGRect(x: 40, y: 80, width: 140, height: 180)))
        let lines = rows.map { text, top, right in
            TextLine(text, box: TextBox(left: (60.0 - 40) / 140, top: Double(top - 80) / 180,
                                        right: Double(right - 40) / 140, bottom: Double(top + 14 - 80) / 180))
        }
        let candidate = RegionWatcher.candidate(Reading(lines: lines), in: region, frame: crop, auto: true, menu: true,
                                                styled: true, kind: .menu, screen: RegionWatcher.ScreenFrame(screen))
        let paints = (candidate.blocks ?? []).compactMap(\.paint)
        XCTAssertEqual(paints.count, rows.count)
        for (paint, row) in zip(paints, rows) {
            XCTAssertEqual(paint.mode, .beside, row.0)
            let spot = try XCTUnwrap(paint.spot, row.0)
            // Sağda, kendi satırının hizasında.
            XCTAssertGreaterThanOrEqual(spot.left, Double(row.2) / 640, row.0)
            XCTAssertEqual(spot.top, paint.cover.top, accuracy: 1e-9, row.0)
            XCTAssertEqual(spot.left, try XCTUnwrap(paints[0].spot).left, accuracy: 1e-9, "\(row.0) ortak hiza")
        }
    }

    /// Kullanıcının ek alanı ve hazır alan, otomatik alanla aynı çizim kipini alır (#1324): tek kutu tuş simgelerini örtmez,
    /// yazı boyu özgünden ölçülür (Windows ve Android aynı).
    @MainActor
    func testExtraAreaGetsTheAutoAreaPaintMode() throws {
        // Koyu zeminde solda tek satır yazı; sağı ve altı boş.
        let width = 400, height = 120
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let ink = (15..<45).contains(y) && x >= 20 && x < 200 && x % 10 < 5
                let p = (y * width + x) * 4
                (pixels[p], pixels[p + 1], pixels[p + 2]) = ink ? (240, 240, 240) : (20, 22, 30)
            }
        }
        let frame = ScreenTextDetectorTests.image(pixels, width: width, height: height)
        let header = TextBox(left: 20.0 / 400, top: 15.0 / 120, right: 200.0 / 400, bottom: 45.0 / 120)
        let reading = Reading(lines: [TextLine("ROB VICKI'S BOSS", box: header)])
        let whole = CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        let auto = try XCTUnwrap(RegionWatcher.candidate(reading, in: whole, frame: frame, auto: true).blocks?.first?.paint)
        let extra = try XCTUnwrap(RegionWatcher.candidate(reading, in: whole, frame: frame, styled: true).blocks?.first?.paint)
        XCTAssertEqual(extra.mode, auto.mode)
        XCTAssertNotEqual(extra.mode, .cover)
        XCTAssertEqual(extra.pitch, auto.pitch, accuracy: 1e-9)
    }

    /// Görev/hedef satırının çevirisi altyazıdan ve öbür ekran yazılarından ayrı görünür (beta.100): özgün zemin yerine koyu
    /// kehribar kutu, birebir çizim yok, başında hedef imi; TV'ye zemin `surface` olarak gider (Windows ve Android aynı).
    @MainActor
    func testMissionLineHasItsOwnAmberLook() throws {
        let frame = Self.text((20, 22, 30), (240, 240, 240), stroke: 5)
        let reading = Reading(lines: [TextLine("Lose the cops", box: TextBox(left: 0, top: 10.0 / 60, right: 0.6, bottom: 50.0 / 60))])
        let whole = CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        let other = try XCTUnwrap(RegionWatcher.candidate(reading, in: whole, frame: frame, auto: true).blocks?.first)
        XCTAssertEqual(other.style?.background, "#14161E")
        XCTAssertFalse(other.mission)
        let candidate = RegionWatcher.candidate(reading, in: whole, frame: frame, auto: true, kind: .mission)
        let block = try XCTUnwrap(candidate.blocks?.first)
        XCTAssertTrue(block.mission)
        XCTAssertNil(block.paint)
        XCTAssertEqual(block.style, MissionLine.style)
        let item = try XCTUnwrap(RegionWatcher.renderBlocks(candidate, layout: [block], text: ["Polislerden kurtul"],
                                                           similar: [false], slots: []).first?.item)
        XCTAssertEqual(item.translation, "\u{25BA} Polislerden kurtul")
        let json = SubtitleServer.json(item)
        XCTAssertEqual((json["surface"] as? [String: Any])?["background"] as? String, "#7A4E00")
        XCTAssertNil(json["bg"])
    }
}
