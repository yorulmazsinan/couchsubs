// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// Açık zemindeki koyu yazı (kâğıt ilan) altyazı sayılmaz (GitHub #1124). Örnekler ortak deneme dosyasından
/// (Fixtures/dark-ink.json; Windows InkToneTests.cs ve Android InkToneTest.kt aynı dosyayı okur).
final class InkToneTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Image: Decodable {
            let name: String
            let width: Int
            let height: Int
            let fill: Int
            let rects: [[Int]]
            let box: [Double]
            let dark: Bool
        }
        struct Line: Decodable { let text: String; let box: [Double]; let dark: Bool? }
        struct Block: Decodable { let name: String; let lines: [Line]; let subtitle: String }
        struct Seen: Decodable { let text: String; let box: [Double] }
        struct Style: Decodable { let name: String; let blocks: [Seen]; let gameStyle: Bool; let lightInk: Bool? }
        let area: [Double]
        let images: [Image]
        let blocks: [Block]
        let style: [Style]
    }

    private static func box(_ values: [Double]) -> TextBox {
        TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3])
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("dark-ink.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private static func render(_ image: Vectors.Image) -> [Int] {
        var pixels = [Int](repeating: image.fill, count: image.width * image.height)
        for rect in image.rects {
            for y in max(0, rect[1])..<max(max(0, rect[1]), min(image.height, rect[3])) {
                for x in max(0, rect[0])..<max(max(0, rect[0]), min(image.width, rect[2])) {
                    pixels[y * image.width + x] = rect[4]
                }
            }
        }
        return pixels
    }

    func testPixels() throws {
        for image in try vectors().images {
            let pixels = Self.render(image)
            let dark = InkTone.isDarkOnLight(Self.box(image.box), width: image.width, height: image.height) { x, y in
                pixels[y * image.width + x]
            }
            XCTAssertEqual(dark, image.dark, image.name)
        }
    }

    /// Aynı denetim CGImage'den (altyazı hattının kullandığı yol): gri görüntü RGBA'ya çizilip okunur.
    func testSamplerReadsImage() throws {
        for image in try vectors().images {
            let pixels = Self.render(image)
            var bytes = [UInt8](repeating: 255, count: image.width * image.height * 4)
            for (i, value) in pixels.enumerated() {
                bytes[i * 4] = UInt8(value)
                bytes[i * 4 + 1] = UInt8(value)
                bytes[i * 4 + 2] = UInt8(value)
            }
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            XCTAssertEqual(InkTone.sampler(cg)(Self.box(image.box)), image.dark, image.name)
        }
    }

    func testBlocks() throws {
        let vectors = try vectors()
        let area = Self.box(vectors.area)
        for vector in vectors.blocks {
            let reading = Reading(lines: vector.lines.map { TextLine($0.text, box: Self.box($0.box)) })
            let dark = vector.lines.filter { $0.dark == true }.map { Self.box($0.box) }
            var reasons: [String] = []
            let block = reading.subtitleBlock(in: area, darkInk: { box in dark.contains(box) }, dropped: { reasons.append($1) })
            XCTAssertEqual(block.text, vector.subtitle, vector.name)
            if vector.subtitle.isEmpty { XCTAssertEqual(reasons, [InkTone.reason], vector.name) }
            // Renk verilmezse koyu yazı kuralı çalışmaz.
            XCTAssertFalse(reading.subtitleBlock(in: area).text.isEmpty, vector.name)
        }
    }

    func testGameStyle() throws {
        let vectors = try vectors()
        let area = Self.box(vectors.area)
        for vector in vectors.style {
            func run(lightInk: Bool) -> DarkInkStyle {
                var style = DarkInkStyle()
                style.lightInk = lightInk
                for seen in vector.blocks {
                    style.observe(Reading(lines: seen.text.split(separator: "\n").map { TextLine(String($0), box: Self.box(seen.box)) }),
                                  in: area)
                }
                return style
            }
            var style = run(lightInk: vector.lightInk ?? false)
            XCTAssertEqual(style.isGameStyle, vector.gameStyle, vector.name)
            style.reset()
            XCTAssertFalse(style.isGameStyle, vector.name)
            // Açık yazılı oyunda kuralı kapatmayan bloklar başka oyunda kapatır (vektör anlamlı).
            if vector.lightInk == true { XCTAssertTrue(run(lightInk: false).isGameStyle, vector.name) }
        }
    }
}
