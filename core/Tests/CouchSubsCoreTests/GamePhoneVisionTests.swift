// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

enum GamePhoneTestFrame {
    static func image(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r,g,b) = color(x,y), i = (y * width + x) * 4
                pixels[i] = r
                pixels[i+1] = g
                pixels[i+2] = b
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func phone(casing: UInt8 = 110, slot: UInt8 = 25, camera: Bool = true, patch: CGRect? = nil) -> CGImage {
        image(width: 400, height: 225) { x,y in
            let gray = phoneGray(x, y, casing: casing, slot: slot, camera: camera, patch: patch)
            return (gray,gray,gray)
        }
    }

    static func phoneGray(_ x: Int, _ y: Int, casing: UInt8 = 110, slot: UInt8 = 25, camera: Bool = true, patch: CGRect? = nil) -> UInt8 {
        var gray: UInt8 = 85
        if (160..<244).contains(x), (22..<201).contains(y) { gray = casing }
        if (164..<240).contains(x), (40..<181).contains(y) { gray = 195 }
        if (196..<209).contains(x), (33..<35).contains(y) { gray = slot }
        if camera, (212..<215).contains(x), (33..<36).contains(y) { gray = slot }
        if (198..<207).contains(x), (189..<191).contains(y) { gray = slot }
        if (198..<207).contains(x), (170..<172).contains(y) { gray = 24 }
        if let patch, patch.contains(CGPoint(x: x, y: y)) { gray = 35 }
        return gray
    }

    /// Pencereden okunan kare: üstte `title` piksellik açık renk başlık çubuğu (üstünde koyu yazı), 400×225 oyun görüntüsü
    /// (`left`, `top`) noktasında, kalan yer simsiyah şerit.
    static func window(width: Int, height: Int, title: Int, left: Int, top: Int) -> CGImage {
        image(width: width, height: height) { x, y in
            if y < title {
                let ink: UInt8 = (8..<120).contains(x) && (title / 3..<title * 2 / 3).contains(y) && x % 4 < 2 ? 30 : 220
                return (ink, ink, ink)
            }
            guard (left..<left + 400).contains(x), (top..<top + 225).contains(y) else { return (0, 0, 0) }
            let gray = phoneGray(x - left, y - top)
            return (gray, gray, gray)
        }
    }
}

final class GamePhoneTrackerTests: XCTestCase {
    func testTwoAlignedObservationsAndFirstMissingPhone() {
        let tracker = GamePhoneTracker(), image = GamePhoneTestFrame.phone()
        XCTAssertNil(tracker.sample(image, now: 0).pose)
        XCTAssertFalse(tracker.sample(image, now: 250).sampled)
        XCTAssertNotNil(tracker.sample(image, now: 330).pose)
        // Açık telefon kısa süre bulunamayınca kapanmaz (panel kaybolup gelmesin); son görülmeden ~1 sn sonra, üçüncü
        // ıskada kapanır (#1334; önceden dördüncü ıskada, ~1,3 sn).
        let missing = GamePhoneTestFrame.phone(camera: false)
        XCTAssertNotNil(tracker.sample(missing, now: 660).pose)
        XCTAssertNotNil(tracker.sample(image, now: 990).pose)
        XCTAssertNotNil(tracker.sample(missing, now: 1320).pose)
        XCTAssertNotNil(tracker.sample(missing, now: 1650).pose)
        XCTAssertNil(tracker.sample(missing, now: 1980).pose)
        XCTAssertNil(tracker.sample(missing, now: 2310).pose)
        // Kapandıktan sonra yeniden açılış yine iki gözlem ister.
        XCTAssertNil(tracker.sample(image, now: 2640).pose)
        XCTAssertNotNil(tracker.sample(image, now: 2970).pose)
        tracker.reset()
        XCTAssertNil(tracker.sample(image, now: 2971).pose)
    }

    func testMovingHandsetRequiresNewConfirmationAndSubtitleBarAloneIsIgnored() {
        let game = GamePhoneTestFrame.image(width: 400, height: 225) { _, y in
            let g: UInt8 = (180..<192).contains(y) ? 210 : 32
            return (g,g,g)
        }
        XCTAssertNil(GamePhoneGeometry.locate(game))
        var x = 0.4
        let tracker = GamePhoneTracker { _ in .init(topX: x, topY: 0.16, bottomX: x, bottomY: 0.82) }
        XCTAssertNil(tracker.sample(game, now: 0).pose)
        x = 0.55
        XCTAssertNil(tracker.sample(game, now: 400).pose)
        XCTAssertEqual(tracker.sample(game, now: 800).pose?.topX, x)
    }

    func testRealBezelAndCameraRequiredEvenWithHigherContrastTextStroke() throws {
        let shades: [(UInt8, UInt8)] = [(110, 25), (55, 23)]
        for (casing, slot) in shades {
            let pose = try XCTUnwrap(GamePhoneGeometry.locate(GamePhoneTestFrame.phone(casing: casing, slot: slot)))
            XCTAssertTrue((32...35).contains(pose.topY * 225))
            XCTAssertTrue((188...191).contains(pose.bottomY * 225))
            XCTAssertNil(GamePhoneGeometry.locate(GamePhoneTestFrame.phone(casing: casing, slot: slot, camera: false)))
        }
    }

    /// PS Remote Play / chiaki-ng / OBS penceresinden okunan kare 16:9 değildir (başlık çubuğu, siyah şeritler). Telefon
    /// önceden yalnız tam 16:9 karede aranıyordu; pencerede hiç bulunmuyordu. Şimdi oyun görüntüsü karenin içinde bulunur,
    /// telefonun yeri karenin tamamına göre verilir (Windows ve Android'de aynı deneme).
    func testPhoneIsFoundInsideARemotePlayWindow() throws {
        let direct = try XCTUnwrap(GamePhoneGeometry.locate(GamePhoneTestFrame.phone()))
        // Başlık çubuğu + tam oturan görüntü; başlık çubuğu + üstte/altta siyah şerit; başlık çubuğu + yanlarda şerit.
        let layouts: [(width: Int, height: Int, title: Int, left: Int, top: Int)] = [
            (400, 256, 31, 0, 31), (400, 300, 31, 0, 56), (470, 256, 31, 35, 31),
        ]
        for layout in layouts {
            let frame = GamePhoneTestFrame.window(width: layout.width, height: layout.height, title: layout.title,
                                                  left: layout.left, top: layout.top)
            let area = try XCTUnwrap(GamePhoneGeometry.picture(width: layout.width, height: layout.height) { x, y in
                guard y >= layout.title else { return 220 }
                return (layout.left..<layout.left + 400).contains(x) && (layout.top..<layout.top + 225).contains(y)
                    ? Int(GamePhoneTestFrame.phoneGray(x - layout.left, y - layout.top)) : 0
            })
            XCTAssertEqual([area.x, area.y, area.width, area.height], [layout.left, layout.top, 400, 225], "\(layout)")
            let pose = try XCTUnwrap(GamePhoneGeometry.locate(frame), "\(layout)")
            let w = Double(layout.width), h = Double(layout.height)
            XCTAssertEqual(pose.topX * w, Double(layout.left) + direct.topX * 400, accuracy: 0.5)
            XCTAssertEqual(pose.topY * h, Double(layout.top) + direct.topY * 225, accuracy: 0.5)
            XCTAssertEqual(pose.bottomY * h, Double(layout.top) + direct.bottomY * 225, accuracy: 0.5)
            XCTAssertNotNil(ScreenPhoneCard.phone(in: frame), "\(layout)")
        }
        // Kamerası olmayan (telefon olmayan) görüntü pencerede de telefon sayılmaz.
        XCTAssertNil(GamePhoneGeometry.locate(GamePhoneTestFrame.image(width: 400, height: 256) { _, y in
            y < 31 ? (220, 220, 220) : (85, 85, 85)
        }))
    }
}

final class GamePhonePaletteTests: XCTestCase {
    func testSurfaceAndInkComeFromInsideTheBox() {
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [(224, 232, 224, 24), (32, 64, 120, 248)]
        for (r, g, b, ink) in colors {
            let image = GamePhoneTestFrame.image(width: 120, height: 50) { x,y in
                guard (15..<105).contains(x), (10..<40).contains(y) else { return (255,0,196) }
                return x % 13 < 3 ? (ink,ink,ink) : (r,g,b)
            }
            let style = GamePhonePalette.sample(image, box: .init(left: 0.125, top: 0.2, right: 0.875, bottom: 0.8))
            XCTAssertEqual(style.background, String(format: "#%02X%02X%02X", r,g,b))
            XCTAssertEqual(style.foreground, String(format: "#%02X%02X%02X", ink,ink,ink))
        }
    }

    func testLowContrastBlueKeepsLightInkAndPhotosGetNeutralColors() {
        let box = TextBox(left: 0, top: 0, right: 1, bottom: 1)
        let blue = GamePhoneTestFrame.image(width: 90, height: 30) { x,_ in
            x % 13 < 3 ? (230,239,246) : (88,120,192)
        }
        XCTAssertEqual(GamePhonePalette.sample(blue, box: box), .init(background: "#5070B8", foreground: "#FFFFFF"))
        for step in 0...1 {
            let photo = GamePhoneTestFrame.image(width: 96, height: 54) { x,y in
                (UInt8(truncatingIfNeeded: 3*x + step*80), UInt8(y*4), UInt8(truncatingIfNeeded: (x+y)*3))
            }
            XCTAssertEqual(GamePhonePalette.sample(photo, box: box), GamePhonePalette.neutral)
        }
    }
}

final class GamePhoneReaderTests: XCTestCase {
    private final class Probe: TextReader, @unchecked Sendable {
        let box = TextBox(left: 0.2, top: 0.25, right: 0.6, bottom: 0.35)
        var samples: [CGPoint] = []
        func read(_ image: CGImage) throws -> String { XCTFail("Expected line geometry"); return "" }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
            XCTAssertFalse(deep)
            let pixels = try XCTUnwrap(GamePhonePixels(image))
            for v in [box.top, box.bottom] {
                for u in [box.left, box.right] {
                    let p = pixels.offset(Int(u * Double(image.width)), Int(v * Double(image.height)))
                    samples.append(CGPoint(x: Int(pixels.bytes[p]) * 4, y: Int(pixels.bytes[p+1]) * 2))
                }
            }
            return Reading(lines: [TextLine("Notice", box: box, words: [TextWord("Notice", box: box)],
                                            icons: [IconSlot(box: box, text: "X")])])
        }
    }

    func testDeskewInBothDirectionsMapsWordsAndIconsToOriginalPixels() throws {
        // Mavi kanal dolu: aydınlık ekran, koyu ekran hazırlığı (`PhoneDarkScreen`) kodlanmış koordinatları değiştirmesin.
        let image = GamePhoneTestFrame.image(width: 800, height: 450) { x,y in (UInt8(x/4), UInt8(y/2), 255) }
        for tilt in [-0.06, 0.06] {
            let reader = Probe()
            let pose = GamePhoneGeometry.Pose(topX: 0.50, topY: 0.16, bottomX: 0.50+tilt, bottomY: 0.82)
            let r = pose.bounds
            let result = try GamePhoneReader.read(image, region: r, pose: pose, reader: reader)
            let line = try XCTUnwrap(result.lines.first)
            let mapped = try XCTUnwrap(line.box).placed(in: TextBox(left: r.left, top: r.top, right: r.right, bottom: r.bottom))
            XCTAssertEqual(reader.samples.count, 4)
            XCTAssertEqual(mapped.left * 800, Double(try XCTUnwrap(reader.samples.map(\.x).min())), accuracy: 5)
            XCTAssertEqual(mapped.right * 800, Double(try XCTUnwrap(reader.samples.map(\.x).max())), accuracy: 5)
            XCTAssertEqual(mapped.top * 450, Double(try XCTUnwrap(reader.samples.map(\.y).min())), accuracy: 3)
            XCTAssertEqual(mapped.bottom * 450, Double(try XCTUnwrap(reader.samples.map(\.y).max())), accuracy: 3)
            XCTAssertEqual(line.phoneBox, reader.box)
            XCTAssertEqual(line.words?.first?.box, line.box)
            XCTAssertEqual(line.icons?.first?.box, line.box)
        }
    }

    func testChangingGlyphsInsideEachBubbleButNotNoiseOrOutsideVideoInvalidatesPage() {
        let pageRegion = CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        let box = TextBox(left: 0.2, top: 0.3, right: 0.8, bottom: 0.6)
        func image(_ mode: Int) -> CGImage {
            GamePhoneTestFrame.image(width: 100, height: 50) { x,y in
                var g: UInt8 = mode == 0 ? 85 : 89
                if mode > 0, x < 12 { g = 200 }
                if mode > 0, x == 30, y == 20 { g = 220 }
                if mode == 2, (45..<48).contains(x), (20..<25).contains(y) { g = 210 }
                return (g,g,g)
            }
        }
        let page = GamePhonePage(frame: image(0), region: pageRegion, reading: Reading(lines: [TextLine("Hey", box: box)]))
        XCTAssertFalse(page.changed(image(1), region: pageRegion))
        XCTAssertTrue(page.changed(image(2), region: pageRegion))
    }
}
