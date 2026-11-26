// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import ImageIO
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
        run(detector, 0, 500) { Self.scene($0, box: self.topLeft) }
        XCTAssertTrue(detector.areas.isEmpty)
        run(detector, 600, 700) { Self.scene($0, box: self.topLeft) }
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
        run(detector, 1100, 1900) { Self.scene($0, box: (200, 260, 240, 60)) }
        XCTAssertEqual(detector.areas.count, 1)
    }

    func testRejectedAreaIsNotProposedAgainUntilItChanges() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 700) { Self.scene($0, box: self.topLeft) }
        let id = try XCTUnwrap(detector.areas.first).id
        detector.reject(id)
        XCTAssertTrue(detector.areas.isEmpty)
        run(detector, 800, 2300) { Self.scene($0, box: self.topLeft) }
        XCTAssertTrue(detector.areas.isEmpty)
        // Kutunun içeriği değişti (yeni yazı): yeniden önerilir, yeni kimlikle.
        run(detector, 2400, 3200) { Self.scene($0, box: (20, 25, 160, 60)) }
        XCTAssertEqual(detector.areas.count, 1)
        XCTAssertNotEqual(detector.areas.first?.id, id)
    }

    func testAreaLeavesSevenHundredMillisecondsAfterTheBoxIsGone() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 700) { Self.scene($0, box: self.topLeft) }
        let id = try XCTUnwrap(detector.areas.first).id
        run(detector, 800, 1300) { Self.scene($0) }
        XCTAssertEqual(detector.areas.map(\.id), [id])
        run(detector, 1400, 1400) { Self.scene($0) }
        XCTAssertTrue(detector.areas.isEmpty)
    }

    func testAreaKeepsItsIdWhileTheBoxGrows() throws {
        let detector = ScreenTextDetector()
        run(detector, 0, 700) { Self.scene($0, box: self.topLeft) }
        let first = try XCTUnwrap(detector.areas.first)
        run(detector, 800, 1700) { Self.scene($0, box: (20, 20, 160, 100)) }
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

    /// Menü şeridinin sekmeleri arasındaki seçili (renkli, aday olmayan) sekme alanı ortadan bölmez: aynı karo satırında
    /// iki boş karoya kadar aralıklı bileşenler birleşir (#859); başka satırda iki boş karo sınırı kalır.
    func testTabsOnOneRowMergeAcrossTheSelectedTab() {
        typealias Cells = ScreenTextDetector.Cells
        let row = ScreenTextDetector.merged([(Cells(left: 14, top: 1, right: 20, bottom: 1), [1 * 32 + 14]),
                                             (Cells(left: 23, top: 1, right: 29, bottom: 1), [1 * 32 + 23])])
        XCTAssertEqual(row.count, 1)
        XCTAssertEqual(row.first?.cells, Cells(left: 14, top: 1, right: 29, bottom: 1))
        let apart = ScreenTextDetector.merged([(Cells(left: 14, top: 1, right: 20, bottom: 1), [1 * 32 + 14]),
                                               (Cells(left: 23, top: 2, right: 29, bottom: 2), [2 * 32 + 23])])
        XCTAssertEqual(apart.count, 2)
        // Seçili sekme üç karo genişse: iki yanındaki sekme öbekleri (en az iki karo) yine birleşir.
        let wide = ScreenTextDetector.merged([(Cells(left: 16, top: 1, right: 22, bottom: 1), [1 * 32 + 16]),
                                              (Cells(left: 26, top: 1, right: 29, bottom: 1), [1 * 32 + 26])])
        XCTAssertEqual(wide.count, 1)
        // Tek karoluk etiketler (tekerlek menü) dört sütun arayla ayrı kalır.
        let wheel = ScreenTextDetector.merged([(Cells(left: 4, top: 1, right: 4, bottom: 1), [1 * 32 + 4]),
                                               (Cells(left: 8, top: 1, right: 8, bottom: 1), [1 * 32 + 8])])
        XCTAssertEqual(wheel.count, 2)
    }

    /// Menüde aynı sütundaki alt alta bileşenler arada bir boş karo satırı olsa da tek alandır (#1339: GTA 6 duraklatma
    /// menüsünün "Settings" satırı ayrı alana düşüp kendi başına altına yazılıyordu); iki boş satır ya da başka sütun ayrı
    /// kalır (Windows ve Android aynı).
    func testMenuColumnMergesAcrossOneEmptyRow() {
        typealias Cells = ScreenTextDetector.Cells
        let column = ScreenTextDetector.menuColumns([(Cells(left: 3, top: 5, right: 7, bottom: 11), [5 * 32 + 3]),
                                                     (Cells(left: 3, top: 13, right: 6, bottom: 13), [13 * 32 + 3])])
        XCTAssertEqual(column.count, 1)
        XCTAssertEqual(column.first?.cells, Cells(left: 3, top: 5, right: 7, bottom: 13))
        let far = ScreenTextDetector.menuColumns([(Cells(left: 3, top: 5, right: 7, bottom: 11), [5 * 32 + 3]),
                                                  (Cells(left: 3, top: 14, right: 6, bottom: 14), [14 * 32 + 3])])
        XCTAssertEqual(far.count, 2)
        let other = ScreenTextDetector.menuColumns([(Cells(left: 3, top: 5, right: 7, bottom: 11), [5 * 32 + 3]),
                                                    (Cells(left: 12, top: 13, right: 16, bottom: 13), [13 * 32 + 12])])
        XCTAssertEqual(other.count, 2)
        // Ortalı başlık ve alt başlığı (tek satırlık iki bileşen, sol kenarları bir karo farklı) ayrı kalır.
        let titles = ScreenTextDetector.menuColumns([(Cells(left: 13, top: 8, right: 18, bottom: 8), [8 * 32 + 13]),
                                                     (Cells(left: 14, top: 10, right: 17, bottom: 10), [10 * 32 + 14])])
        XCTAssertEqual(titles.count, 2)
    }

    func testResetForgetsAreas() {
        let detector = ScreenTextDetector()
        run(detector, 0, 700) { Self.scene($0, box: self.topLeft) }
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
        // Sürüm derlemesinde ~0,5 ms; hata ayıklama derlemesi (CI) çok daha yavaş, eşik ona göre.
        #if DEBUG
        XCTAssertLessThan(average, 400)
        #else
        XCTAssertLessThan(average, 20)
        #endif
    }

    func testNoiseRules() {
        for text in ["$1,250", "12:45", "PAUSE", "HONOR", "LIQUOR STORE", "x3 Ammo"] {
            XCTAssertTrue(ScreenTextNoise.isNoise(text), text)
        }
        for text in ["Go to the Saloon.", "Follow Paulie to the car.", "Lamar has sent you a message.", "Press ✕ to open the map."] {
            XCTAssertFalse(ScreenTextNoise.isNoise(text), text)
        }
    }

    /// #1268, gerçek kare (testdata/frames/gta6-harita-kart.jpg): desenli açık haritanın üstündeki tuş listesi (RECENTER,
    /// 2D VIEW, ADD MARKER, SET DESTINATION, EXIT; beyaz harf, koyu kontur) menüde bir alan olur. Eskiden karolarında ne
    /// koyu zemin ne açık zemin yetiyordu; liste hiç okunmuyordu. Kart ve üst şerit eskisi gibi bulunur.
    func testOutlinedMapHintsOnARealMapFrameAreFound() throws {
        let url = ScreenFitTests.directory.appendingPathComponent("gta6-harita-kart.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let detector = ScreenTextDetector()
        for now in stride(from: 0, through: 2000, by: 100) { detector.sample(frame, now: now, excluded: []) }
        XCTAssertTrue(detector.inMenu)
        func holds(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> Bool {
            detector.areas.contains { a in
                a.region.left <= left && a.region.right >= right && a.region.top <= top && a.region.bottom >= bottom
            }
        }
        XCTAssertTrue(holds(0.84, 0.70, 0.98, 0.97), "tuş listesi: \(detector.areas.map(\.region))")
        XCTAssertTrue(holds(0.54, 0.38, 0.81, 0.62), "harita kartı")
        XCTAssertLessThanOrEqual(detector.areas.count, ScreenTextDetector.menuMaxAreas)
    }

    /// #1268, gerçek kare: tuş listesinin kutuları denizin renginde, yazı koyu lacivert (yanındaki Ⓛ3/Ⓡ3 simgesi ve taşan
    /// harf konturu zemine karışmaz). Eskiden "RECENTER" ve "2D VIEW" açık gri çiziliyordu; Android "ADD MARKER"ı grimsi
    /// (#608096) çiziyordu (Android RegionAliveTest ile aynı aralık).
    func testOutlinedMapHintsAreDrawnInTheSeaColour() throws {
        let url = ScreenFitTests.directory.appendingPathComponent("gta6-harita-kart.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let crop = RegionCropper.crop(frame, to: CropRegion(top: 0.639, bottom: 1.0, left: 0.812, right: 1.0))
        // Kayıtlı okumanın kutuları (alana oranla).
        let lines: [(String, [Double])] = [("RECENTER", [0.378, 0.183, 0.772, 0.258]), ("2D VIEW", [0.450, 0.343, 0.761, 0.431]),
                                           ("ADD MARKER", [0.278, 0.507, 0.750, 0.596]),
                                           ("SET DESTINATION", [0.128, 0.672, 0.750, 0.759])]
        for (text, b) in lines {
            let box = TextBox(left: b[0], top: b[1], right: b[2], bottom: b[3])
            let (style, look) = TextStyleSampler.sample(crop, box: box, lines: [TextLine(text, box: box)], source: text)
            XCTAssertLessThanOrEqual(TextPainter.distance(TextPainter.rgb(style.background), (0x3A, 0x94, 0xBB)), 24,
                                     "\(text): \(style.background)")
            XCTAssertLessThanOrEqual(TextPainter.distance(TextPainter.rgb(style.foreground), (0x1E, 0x2E, 0x3E)), 24,
                                     "\(text): \(style.foreground)")
            XCTAssertFalse(look.flat, "\(text): deniz düz zemin değil")
        }
    }

    func testOutlinedTileRule() {
        XCTAssertTrue(ScreenTextDetector.outlined(bright: 48, dark: 74))
        XCTAssertFalse(ScreenTextDetector.outlined(bright: 8, dark: 71), "harfsiz kontur")
        XCTAssertFalse(ScreenTextDetector.outlined(bright: 0, dark: 576), "düz koyu zemin")
        XCTAssertFalse(ScreenTextDetector.outlined(bright: 400, dark: 100), "açık sahne")
    }

    /// X, beta.104 (üç kullanıcı): telefon açıkken sağ alttaki tuş çubuğu ("SCROLL / SEND / EXIT") çevrilmiyordu.
    /// Telefona değen alan atılır, telefonun dışındaki tuş çubuğu kalır (Windows ScreenTextDetectorTests, Android aynı).
    func testPhoneOpenKeepsPromptsOutsideThePhone() {
        let phone = CropRegion(top: 0.25, bottom: 0.85, left: 0.55, right: 0.75)
        let onPhone = ExtraArea(id: "auto-1", name: "Auto", region: CropRegion(top: 0.4, bottom: 0.5, left: 0.58, right: 0.72), auto: true)
        let edge = ExtraArea(id: "auto-2", name: "Auto", region: CropRegion(top: 0.86, bottom: 0.9, left: 0.6, right: 0.7), auto: true)
        let prompts = ExtraArea(id: "auto-3", name: "Auto", region: CropRegion(top: 0.9, bottom: 0.96, left: 0.8, right: 0.97), auto: true)
        let drink = ExtraArea(id: "auto-4", name: "Auto", region: CropRegion(top: 0.6, bottom: 0.75, left: 0.86, right: 0.97), auto: true)
        let areas = [onPhone, edge, prompts, drink]
        XCTAssertEqual(ScreenTextDetector.outsidePhone(areas, phone: phone).map(\.id), ["auto-3", "auto-4"])
        XCTAssertEqual(ScreenTextDetector.outsidePhone(areas, phone: nil).map(\.id), areas.map(\.id))
        let padded = ScreenTextDetector.paddedPhone(CropRegion(top: 0.01, bottom: 0.99, left: 0.5, right: 0.7))
        XCTAssertEqual(padded.top, 0)
        XCTAssertEqual(padded.bottom, 1)
        XCTAssertEqual(padded.left, 0.48, accuracy: 1e-9)
    }
}
