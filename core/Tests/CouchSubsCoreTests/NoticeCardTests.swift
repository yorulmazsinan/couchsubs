// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import ImageIO
import XCTest
@testable import CouchSubsCore

/// GitHub #1443 (X'te başkaları da: "sağ alt mesajlar çevrilmiyor"): GTA 6'nın sağ alttaki açık bildirim kartının yalnız
/// başlığı çevriliyor, gövdesi "koyu yazı açık zeminde (kâğıt/tabela)" sayılıp atılıyordu. Örnekler ortak deneme
/// dosyasından (Fixtures/notice-card.json; Windows NoticeCardTests.cs ve Android NoticeCardTest.kt aynı dosyayı okur):
/// gerçek kare gta6-n4-bildirim (kayıtlı okuması, alt şerit alanı kartı kesiyor), kayıtlı okuması olan öteki bütün gerçek
/// kareler (kart yok) ve kullanıcının fotoğrafındaki kartın ölçüleriyle sentetik kare.
final class NoticeCardTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Real: Decodable { let frame: String; let card: [Double]; let texts: [String] }
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Case: Decodable { let name: String; let shift: Double; let invert: Bool; let card: [Double]? }
        struct Synthetic: Decodable {
            let width: Int, height: Int
            let card: [Double], icon: [Double], rows: [[Double]], area: [Double]
            let lines: [Line]
            let subtitle: String
            let cardTexts: [String]
            let cases: [Case]
        }
        let tolerance: Double
        let real: [Real]
        let synthetic: Synthetic
    }

    private struct Recorded: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        let lines: [Line]
        let region: [Double]?
    }

    private static func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("notice-card.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private static func recorded(_ id: String) throws -> (reading: Reading, area: TextBox)? {
        let url = FrameReplayTests.directory.appendingPathComponent("ocr/\(id).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let fixture = try JSONDecoder().decode(Recorded.self, from: data)
        guard let region = fixture.region else { return nil }
        return (Reading(lines: fixture.lines.map { TextLine($0.text, box: box($0.box), confidence: 1) }), box(region))
    }

    private static func image(_ id: String) -> CGImage? {
        let url = FrameReplayTests.directory.appendingPathComponent("\(id).jpg")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func assertClose(_ got: TextBox?, _ want: [Double], _ tolerance: Double, _ name: String) {
        guard let got else { return XCTFail("\(name): kart bulunmadı") }
        let values = [got.left, got.top, got.right, got.bottom]
        for (g, w) in zip(values, want) {
            XCTAssertEqual(g, w, accuracy: tolerance, "\(name): \(values)")
        }
    }

    /// Gerçek kare: alt şerit alanı (kayıttaki region) kartı kesse de kartın tamamı bulunur, başlık ve gövde tek kart.
    func testRealNotificationCardIsFoundWhole() throws {
        let vectors = try vectors()
        for real in vectors.real {
            guard let frame = Self.image(real.frame), let (reading, area) = try Self.recorded(real.frame) else {
                throw XCTSkip("gerçek kare yok: \(real.frame)")
            }
            let (kept, cards) = NoticeCard.split(reading, in: area, card: NoticeCard.sampler(frame))
            // Bulunamazsa tanı: kartın içinden ve dışından parlaklıklar (makineye göre renk dönüşümü farkı).
            let probe = GamePhonePixels(frame).map { p in
                [(0.85, 0.82), (0.85, 0.87), (0.95, 0.83), (0.75, 0.85), (0.99, 0.85)].map { fx, fy -> Int in
                    let i = (Int(fy * Double(p.height)) * p.width + Int(fx * Double(p.width))) * 4
                    return (299 * Int(p.bytes[i]) + 587 * Int(p.bytes[i + 1]) + 114 * Int(p.bytes[i + 2])) / 1000
                }
            }
            XCTAssertEqual(cards.count, 1, "\(real.frame) parlaklık \(String(describing: probe))")
            assertClose(cards.first?.card, real.card, vectors.tolerance, real.frame)
            XCTAssertEqual(cards.first.map { $0.block.lines.map(\.text) }, real.texts, real.frame)
            XCTAssertTrue(kept.lines.allSatisfy { !real.texts.contains($0.text) }, real.frame)
        }
    }

    /// Kayıtlı okuması olan öteki gerçek karelerde (konuşma, kâğıt ilan, tabela, kitap kapağı, tişört, telefon, menü) kart
    /// yoktur: hiçbir satır altyazıdan bildirim kartına kaçmaz.
    func testNoOtherRealFrameHasACard() throws {
        let vectors = try vectors()
        let cards = Set(vectors.real.map(\.frame))
        let names = try FileManager.default.contentsOfDirectory(atPath: FrameReplayTests.directory.path)
            .filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) }.sorted()
        var checked = 0
        for name in names where !cards.contains(name) {
            guard let (reading, area) = try Self.recorded(name), let frame = Self.image(name) else { continue }
            let (kept, found) = NoticeCard.split(reading, in: area, card: NoticeCard.sampler(frame))
            XCTAssertTrue(found.isEmpty, "\(name): \(found.map { $0.block.text })")
            XCTAssertEqual(kept, reading, name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 30)
    }

    /// Kartın bölgesi kartın kendisidir; kart `settleMs` yerinde durunca gelir, küçük oynamada bölge değişmez, kart
    /// görünmeyince `forgetMs` sonra kalkar. Aynı karede kenar bildirimi bloğu ile kart ayrı izlenir.
    func testNoticesTrackCardsWithTheWholeCardAsRegion() {
        var notices = ScreenNotices()
        let card = TextBox(left: 0.68, top: 0.63, right: 0.96, bottom: 0.93)
        XCTAssertFalse(notices.observe([], cards: [card], at: 0))
        XCTAssertTrue(notices.observe([], cards: [card], at: ScreenNotices.settleMs))
        XCTAssertEqual(notices.areas.map(\.id), ["auto-notice-1"])
        XCTAssertEqual(notices.areas.first?.region, CropRegion(top: 0.63, bottom: 0.93, left: 0.68, right: 0.96))
        let jitter = TextBox(left: 0.682, top: 0.631, right: 0.958, bottom: 0.93)
        XCTAssertFalse(notices.observe([], cards: [jitter], at: ScreenNotices.settleMs + 100))
        XCTAssertFalse(notices.observe([], at: ScreenNotices.settleMs + 100 + ScreenNotices.forgetMs))
        XCTAssertTrue(notices.observe([], at: ScreenNotices.settleMs + 101 + ScreenNotices.forgetMs))
        XCTAssertEqual(notices.areas, [])
    }

    /// Sentetik parlaklık (ortak dosyadaki formül).
    private static func luma(_ synthetic: Vectors.Synthetic, x: Int, y: Int, shift: Double, invert: Bool) -> Int {
        let fx = (Double(x) + 0.5) / Double(synthetic.width) - shift, fy = (Double(y) + 0.5) / Double(synthetic.height)
        let inside = { (r: [Double]) in fx >= r[0] && fx < r[2] && fy >= r[1] && fy < r[3] }
        guard inside(synthetic.card) else { return 110 + (x * 37 + y * 91 + (x * y) % 53) % 90 }
        let (ground, ink) = invert ? (40, 236) : (236, 40)
        if inside(synthetic.icon) { return 130 }
        if synthetic.rows.contains(where: inside), (x / 3) % 2 == 0 { return ink }
        return ground
    }

    func testSyntheticCases() throws {
        let vectors = try vectors()
        let synthetic = vectors.synthetic
        let body = synthetic.lines.prefix(4).map { Self.box($0.box) }.reduce(Self.box(synthetic.lines[0].box)) { $0.union($1) }
        for item in synthetic.cases {
            let shifted = TextBox(left: body.left + item.shift, top: body.top, right: body.right + item.shift, bottom: body.bottom)
            let found = NoticeCard.bounds(around: shifted, width: synthetic.width, height: synthetic.height) { x, y in
                Self.luma(synthetic, x: x, y: y, shift: item.shift, invert: item.invert)
            }
            if let card = item.card { assertClose(found, card, vectors.tolerance, item.name) } else { XCTAssertNil(found, item.name) }
        }
    }

    /// Sentetik kare (`luma`) RGB görüntü olarak.
    private static func syntheticImage(_ synthetic: Vectors.Synthetic) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: synthetic.width * synthetic.height * 4)
        for y in 0..<synthetic.height {
            for x in 0..<synthetic.width {
                let value = UInt8(luma(synthetic, x: x, y: y, shift: 0, invert: false))
                let i = (y * synthetic.width + x) * 4
                (pixels[i], pixels[i + 1], pixels[i + 2]) = (value, value, value)
            }
        }
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: synthetic.width, height: synthetic.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: synthetic.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// Kullanıcının durumu (#1443): alt şerit altyazı alanı kartı kesiyor, gövde koyu yazı. Kart açıkken (GTA 6, ekran
    /// yazısı ya da telefon çevirisi) gövde altyazıya girmez, kâğıt/tabela diye de atılmaz; kartın tamamı "auto-notice-1"
    /// olur. Aynı karedeki konuşma altyazı olarak çevrilir. Kart kapalıyken eski davranış (kart bildirimi yok; konuşma da
    /// kartın satırlarıyla birlikte menü listesi sanılıp atılıyor).
    @MainActor
    func testPipelineRoutesTheCardToANoticeBeforeTheDarkInkRule() async throws {
        let vectors = try vectors()
        let synthetic = vectors.synthetic
        let area = Self.box(synthetic.area)
        let reading = Reading(lines: synthetic.lines.map { line in
            let b = Self.box(line.box)
            let w = area.right - area.left, h = area.bottom - area.top
            return TextLine(line.text, box: TextBox(left: (b.left - area.left) / w, top: (b.top - area.top) / h,
                                                    right: (b.right - area.left) / w, bottom: (b.bottom - area.top) / h),
                            confidence: 1)
        })
        let frame = Self.syntheticImage(synthetic)
        for cards in [true, false] {
            let run = await Self.run(reading, frame: frame, region: CropRegion(top: area.top, bottom: area.bottom,
                                                                                left: area.left, right: area.right),
                                     cards: cards)
            let joined = run.log.joined(separator: "\n")
            XCTAssertFalse(run.sent.contains { text in synthetic.cardTexts.contains { text.contains(String($0.reversed())) } }, joined)
            if cards {
                // Kart ayrılınca konuşma kendi başına altyazıdır (önceden kartın satırlarıyla birlikte menü listesi sanılıyordu).
                XCTAssertTrue(run.sent.contains { $0.contains(String(synthetic.subtitle.dropFirst(7).reversed())) }, joined)
                XCTAssertEqual(run.areas.map(\.id), ["auto-notice-1"], joined)
                if let region = run.areas.first?.region {
                    assertClose(TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom),
                                synthetic.card, vectors.tolerance, "hat")
                }
                XCTAssertFalse(run.log.contains { $0.contains(InkTone.reason) && $0.contains("from a chop") }, joined)
                XCTAssertTrue(run.log.contains { $0.contains("bildirim kartı:") && $0.contains("from a chop") }, joined)
            } else {
                XCTAssertEqual(run.areas.map(\.id), [], joined)
            }
        }
    }

    @MainActor
    private static func run(_ reading: Reading, frame: CGImage, region: CropRegion,
                            cards: Bool) async -> (sent: [String], log: [String], areas: [ExtraArea]) {
        let reader = FixedReader()
        reader.reading = reading
        let server = Sent()
        var now = 1_000_000
        let pipeline = SubtitlePipeline(reader: reader, translator: Reversed(), server: server, clock: { now })
        pipeline.holdReadings = false
        pipeline.lightInkGame = true
        pipeline.findsNoticeCards = cards
        var log: [String] = []
        var areas: [ExtraArea] = []
        pipeline.onLog = { log.append($0) }
        pipeline.onNoticesChanged = { areas = $0 }
        for _ in 0..<20 {
            await pipeline.process(frame, region: region)
            now += 100
        }
        await pipeline.waitForTranslations()
        return (server.texts, log, areas)
    }

    private final class Reversed: TextTranslator, @unchecked Sendable {
        func translate(_ text: String) async throws -> String { String(text.reversed()) }
    }

    private final class FixedReader: TextReader, @unchecked Sendable {
        var reading = Reading.empty
        func read(_ image: CGImage) throws -> String { reading.text }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { reading }
    }

    private final class Sent: SubtitleSending {
        var texts: [String] = []
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { texts.append(text) }
        func clear() {}
    }
}
