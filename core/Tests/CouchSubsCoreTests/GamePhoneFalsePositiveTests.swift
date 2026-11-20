// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// Oyun telefonu yanlış pozitifi (LG'de "siyah ekran"): telefon olmayan ekranlarda telefon açılmaz, telefon kutusu akıl
/// sınırları içinde kalır, ekranın büyük kısmını kaplayan kutu TV'ye gönderilmez (Windows: GamePhoneFalsePositiveTests).
final class GamePhoneFalsePositiveTests: XCTestCase {
    private func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8, width: Int = 1920, height: Int = 1080) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    func testFlatDarkScreensDoNotOpenPhone() {
        for color in [(0x24, 0x27, 0x2a), (0, 0, 0), (0x1a, 0x1c, 0x22)] {
            let image = flat(UInt8(color.0), UInt8(color.1), UInt8(color.2))
            let tracker = GamePhoneTracker()
            _ = tracker.sample(image, now: 0)
            XCTAssertNil(tracker.sample(image, now: 400).pose)
        }
    }

    func testRealFramesWithoutPhoneDoNotOpenIt() throws {
        guard let root = ProcessInfo.processInfo.environment["COUCHSUBS_REAL_FRAMES"] else { return }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("kareler")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasPrefix("K") && name.hasSuffix(".png") {
            guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil),
                  let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            // Algılayıcı 16:9 kareye bakar: kareyi 1920x1080'e ger.
            let context = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(original, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let image = context.makeImage()!
            let tracker = GamePhoneTracker()
            _ = tracker.sample(image, now: 0)
            XCTAssertNil(tracker.sample(image, now: 400).pose, name)
        }
    }

    func testImplausiblePhoneBoxIsRejected() {
        XCTAssertTrue(GamePhoneTracker.plausible(CropRegion(top: 0.15, bottom: 0.85, left: 0.45, right: 0.64), width: 1920, height: 1080))
        XCTAssertFalse(GamePhoneTracker.plausible(CropRegion(top: 0, bottom: 1, left: 0, right: 1), width: 1920, height: 1080))
        XCTAssertFalse(GamePhoneTracker.plausible(CropRegion(top: 0.05, bottom: 0.95, left: 0.2, right: 0.8), width: 1920, height: 1080))
        XCTAssertFalse(GamePhoneTracker.plausible(CropRegion(top: 0.6, bottom: 0.75, left: 0.4, right: 0.95), width: 1920, height: 1080))
        XCTAssertFalse(GamePhoneTracker.plausible(CropRegion(top: 0.15, bottom: 0.85, left: 0.02, right: 0.2), width: 1920, height: 1080))
        XCTAssertFalse(GamePhoneTracker.plausible(CropRegion(top: 0, bottom: 0.5, left: 0.5, right: 0.64), width: 1920, height: 1080))
        XCTAssertFalse(GamePhoneTracker.plausible(CropRegion(top: 0.5, bottom: 0.6, left: 0.6, right: 0.63), width: 1920, height: 1080))
    }

    func testTrackerNeverOpensAFullScreenPhone() {
        let image = flat(0x24, 0x27, 0x2a)
        let tracker = GamePhoneTracker(locate: { _ in GamePhoneGeometry.Pose(topX: 0.5, topY: 0, bottomX: 0.5, bottomY: 1) })
        _ = tracker.sample(image, now: 0)
        // Bu poz ekranın tamamını kaplayan telefon kutusu verir.
        XCTAssertNil(tracker.sample(image, now: 400).pose)
    }

    func testServerDropsBoxesCoveringMostOfTheScreen() {
        func item(_ box: TextBox) -> ScreenTranslation.Item {
            ScreenTranslation.Item(source: "Hi", translation: "Selam", box: box, lineHeight: 0.03)
        }
        let small = item(TextBox(left: 0.5, top: 0.5, right: 0.6, bottom: 0.55))
        let huge = item(TextBox(left: 0, top: 0, right: 1, bottom: 0.9))
        let kept = SubtitleServer.guarded(text: "Selam", box: TextBox(left: 0, top: 0, right: 1, bottom: 0.9), blocks: [small, huge])
        XCTAssertEqual(kept.0, "Selam")
        XCTAssertEqual(kept.1, [small])
        XCTAssertEqual(SubtitleServer.guarded(text: "Selam", box: TextBox(left: 0, top: 0, right: 1, bottom: 1), blocks: nil).0, "")
        let many = (0..<10).map { i in item(TextBox(left: 0, top: Double(i) * 0.1, right: 0.5, bottom: Double(i) * 0.1 + 0.1)) }
        XCTAssertEqual(SubtitleServer.guarded(text: "y", box: TextBox(left: 0, top: 0, right: 0.5, bottom: 1), blocks: many).0, "")
        let normal = SubtitleServer.guarded(text: "Görev", box: TextBox(left: 0.7, top: 0.05, right: 0.95, bottom: 0.1), blocks: nil)
        XCTAssertEqual(normal.0, "Görev")
        XCTAssertNil(normal.1)
    }
}
