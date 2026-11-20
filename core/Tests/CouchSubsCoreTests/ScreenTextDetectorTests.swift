// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Windows ScreenTextDetectorTests ve Android ScreenTextDetectorTest ile aynı sentetik kareler.
final class ScreenTextDetectorTests: XCTestCase {
    private static let width = 640
    private static let height = 360

    /// Her karede değişen gürültülü sahne; istenirse üstünde koyu kutu ve beyaz "yazı" çizgileri.
    static func scene(_ seed: Int, box: (x: Int, y: Int, w: Int, h: Int)? = nil,
                      width: Int = width, height: Int = height) -> CGImage {
        var generator = SplitMix(seed: UInt64(seed) &+ 1)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let value = generator.next()
            pixels[i] = UInt8(truncatingIfNeeded: value)
            pixels[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
            pixels[i + 2] = UInt8(truncatingIfNeeded: value >> 16)
        }
        if let b = box {
            for y in b.y..<(b.y + b.h) {
                for x in b.x..<(b.x + b.w) {
                    let p = (y * width + x) * 4
                    let ink = [3, 4].contains((y - b.y) % 9) && (x - b.x) % 7 < 4
                    let value: UInt8 = ink ? 240 : 24
                    pixels[p] = value
                    pixels[p + 1] = value
                    pixels[p + 2] = value
                }
            }
        }
        return image(pixels, width: width, height: height)
    }

    static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
        var copy = pixels
        let context = copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        return context!.makeImage()!
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // Sol üstte, 32x18 ızgarada yaklaşık 8x3 karo (karo 20x20 piksel).
    private let topLeft = (x: 20, y: 20, w: 160, h: 60)

    private func run(_ detector: ScreenTextDetector, _ from: Int, _ to: Int, excluded: [CropRegion] = [],
                     _ frame: (Int) -> CGImage) {
        for time in stride(from: from, through: to, by: ScreenTextDetector.sampleIntervalMs) {
            detector.sample(frame(time), now: time, excluded: excluded)
        }
    }

    func testBoxThatStaysStillIsProposedAfterItSettles() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 200) { Self.scene($0, box: self.topLeft) }
        XCTAssertTrue(detector.areas.isEmpty)
        run(detector, 300, 400) { Self.scene($0, box: self.topLeft) }
        XCTAssertEqual(detector.areas.count, 1)
        let area = try XCTUnwrap(detector.areas.first)
        XCTAssertTrue(area.auto)
        XCTAssertTrue(area.id.hasPrefix("auto-"))
        XCTAssertEqual(area.name, ScreenTextDetector.areaName)
        // Kutu (0.031..0.281 x 0.056..0.222) bölgenin içinde; bölge kutudan çok büyük değil.
        let r = area.region
        XCTAssertTrue(r.left <= 0.04 && r.right >= 0.27 && r.top <= 0.06 && r.bottom >= 0.22, "\(r)")
        XCTAssertTrue(r.right <= 0.36 && r.bottom <= 0.32, "\(r)")
    }

    func testNoisySceneAloneProposesNothing() {
        let detector = ScreenTextDetector()
        run(detector, 0, 2000) { Self.scene($0) }
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testBoxThatMovesEverySampleIsNotProposed() {
        let detector = ScreenTextDetector()
        run(detector, 0, 1500) { Self.scene($0, box: (20 + $0 / 100 * 20, 20, 160, 60)) }
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testBoxInsideTheSubtitleAreaIsNotProposed() {
        let detector = ScreenTextDetector()
        run(detector, 0, 1000, excluded: [CropRegion()]) { Self.scene($0, box: (200, 260, 240, 60)) }
        XCTAssertTrue(detector.areas.isEmpty)
        // Aynı kutu altyazı alanı dışında sayılırsa önerilir.
        run(detector, 1100, 1600) { Self.scene($0, box: (200, 260, 240, 60)) }
        XCTAssertEqual(detector.areas.count, 1)
    }

    func testRejectedAreaIsNotProposedAgainUntilItChanges() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { Self.scene($0, box: self.topLeft) }
        let id = try XCTUnwrap(detector.areas.first).id
        detector.reject(id)
        XCTAssertTrue(detector.areas.isEmpty)
        run(detector, 500, 2000) { Self.scene($0, box: self.topLeft) }
        XCTAssertTrue(detector.areas.isEmpty)
        // Kutunun içeriği değişti (yeni yazı): yeniden önerilir, yeni kimlikle.
        run(detector, 2100, 2600) { Self.scene($0, box: (20, 25, 160, 60)) }
        XCTAssertEqual(detector.areas.count, 1)
        XCTAssertNotEqual(detector.areas.first?.id, id)
    }

    func testAreaLeavesSevenHundredMillisecondsAfterTheBoxIsGone() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { Self.scene($0, box: self.topLeft) }
        let id = try XCTUnwrap(detector.areas.first).id
        run(detector, 500, 1000) { Self.scene($0) }
        XCTAssertEqual(detector.areas.map(\.id), [id])
        run(detector, 1100, 1100) { Self.scene($0) }
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testAreaKeepsItsIdWhileTheBoxGrows() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { Self.scene($0, box: self.topLeft) }
        let first = try XCTUnwrap(detector.areas.first)
        run(detector, 500, 1000) { Self.scene($0, box: (20, 20, 160, 100)) }
        XCTAssertEqual(detector.areas.count, 1)
        let grown = try XCTUnwrap(detector.areas.first)
        XCTAssertEqual(grown.id, first.id)
        XCTAssertGreaterThan(grown.region.bottom, first.region.bottom)
    }

    func testLargeComponentIsSceneTextureNotATextBox() {
        let detector = ScreenTextDetector()
        run(detector, 0, 1000) { Self.scene($0, box: (0, 0, 560, 300)) }
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testResetForgetsAreas() {
        let detector = ScreenTextDetector()
        run(detector, 0, 400) { Self.scene($0, box: self.topLeft) }
        XCTAssertEqual(detector.areas.count, 1)
        detector.reset()
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testSamplesAtMostTenTimesASecond() {
        let detector = ScreenTextDetector()
        XCTAssertTrue(detector.due(0))
        detector.sample(Self.scene(0), now: 0, excluded: [])
        XCTAssertFalse(detector.due(50))
        XCTAssertTrue(detector.due(100))
    }

    /// Ölçüm: 1920x1080 karede bir örneğin süresi (100 tekrar).
    func testSampleOfA1080pFrameIsCheap() {
        let detector = ScreenTextDetector()
        let frames = (0..<4).map { Self.scene($0, box: (40, 40, 600, 160), width: 1920, height: 1080) }
        for i in 0..<10 { detector.sample(frames[i % 4], now: i * 100, excluded: []) }
        var times: [Double] = []
        for i in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            detector.sample(frames[i % 4], now: 1000 + i * 100, excluded: [])
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        let average = times.reduce(0, +) / Double(times.count)
        print(String(format: "1920x1080 örnek: ortalama %.3f ms, en kötü %.3f ms (100 tekrar)", average, times.max()!))
        XCTAssertLessThan(average, 20)
    }

    func testNoiseRules() {
        for text in ["$1,250", "12:45", "PAUSE", "HONOR", "LIQUOR STORE", "x3 Ammo"] {
            XCTAssertTrue(ScreenTextNoise.isNoise(text), text)
        }
        for text in ["Go to the Saloon.", "Follow Paulie to the car.", "Lamar has sent you a message.", "Press ✕ to open the map."] {
            XCTAssertFalse(ScreenTextNoise.isNoise(text), text)
        }
    }
}
