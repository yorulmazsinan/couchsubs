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
    }
}
