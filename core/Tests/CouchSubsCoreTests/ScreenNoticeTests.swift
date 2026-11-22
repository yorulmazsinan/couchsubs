// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Kullanıcı bildirimi (X, iki kişi, GTA 6): "Tam ekran" altyazı alanında sağ altta beliren mesaj önizlemesinin ve solda
/// kayarak giren bildirimin çevirisi ekranın ortasına geliyordu. Örnekler ortak deneme dosyasından
/// (Fixtures/screen-notice.json; Windows ScreenNoticeTests.cs ve Android ScreenNoticeTest.kt aynı dosyayı okur).
final class ScreenNoticeTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Area: Decodable { let id: String; let region: [Double] }
        struct Frame: Decodable { let at: Int; let lines: [Line]; let subtitle: String; let areas: [Area] }
        struct Case: Decodable { let name: String; let area: [Double]; let frames: [Frame] }
        let cases: [Case]
    }

    private static func box(_ values: [Double]) -> TextBox {
        TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3])
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("screen-notice.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private static func reading(_ lines: [Vectors.Line]) -> Reading {
        Reading(lines: lines.map { TextLine($0.text, box: box($0.box)) })
    }

    func testSharedVectors() throws {
        for vector in try vectors().cases {
            let area = Self.box(vector.area)
            var notices = ScreenNotices()
            for frame in vector.frames {
                var edge: [Reading] = []
                let block = Self.reading(frame.lines).subtitleBlock(in: area, notices: { edge.append($0.placed(in: area)) })
                XCTAssertEqual(block.text, frame.subtitle, "\(vector.name) @\(frame.at)")
                _ = notices.observe(edge, at: frame.at)
                XCTAssertEqual(notices.areas.map(\.id), frame.areas.map(\.id), "\(vector.name) @\(frame.at)")
                for (area, expected) in zip(notices.areas, frame.areas) {
                    let got = [area.region.left, area.region.top, area.region.right, area.region.bottom]
                    for (a, b) in zip(got, expected.region) { XCTAssertEqual(a, b, accuracy: 1e-6, "\(vector.name) @\(frame.at) \(area.id)") }
                    XCTAssertTrue(area.auto)
                    // Bölge asla ekranın ortasını kaplamaz.
                    XCTAssertFalse(area.region.left < 0.5 && area.region.right > 0.5, "\(area.region)")
                }
            }
        }
    }

    func testRules() {
        XCTAssertTrue(ScreenNotices.isWholeScreen(TextBox(left: 0, top: 0, right: 1, bottom: 1)))
        XCTAssertFalse(ScreenNotices.isWholeScreen(TextBox(left: 0.14, top: 0.62, right: 0.86, bottom: 0.97)))
        XCTAssertTrue(ScreenNotices.isNotice(TextBox(left: 0.74, top: 0.86, right: 0.97, bottom: 0.92)))
        XCTAssertTrue(ScreenNotices.isNotice(TextBox(left: 0.02, top: 0.4, right: 0.28, bottom: 0.43)))
        // Ortadan geçen ya da ortaya yakın blok bildirim değildir; sıfır alanlı kutu da.
        XCTAssertFalse(ScreenNotices.isNotice(TextBox(left: 0.3, top: 0.8, right: 0.7, bottom: 0.84)))
        XCTAssertFalse(ScreenNotices.isNotice(TextBox(left: 0.55, top: 0.8, right: 0.62, bottom: 0.84)))
        XCTAssertFalse(ScreenNotices.isNotice(TextBox(left: 0.8, top: 0.8, right: 0.8, bottom: 0.84)))
        XCTAssertTrue(ScreenNotices.isNotice(id: "auto-notice-3"))
        XCTAssertFalse(ScreenNotices.isNotice(id: "auto-3"))
    }

    /// Uçtan uca: "Tam ekran" alanda yalnız kenar bildirimleri okunur; hiçbiri altyazı olarak TV'ye (ortaya) gitmez,
    /// alanları kendi yerinde okunmak üzere bildirilir.
    @MainActor
    func testPipelineKeepsNoticesOutOfTheSubtitle() async throws {
        let vector = try XCTUnwrap(try vectors().cases.first)
        let reader = FixedReader()
        let server = Sent()
        var now = 1_000_000
        let pipeline = SubtitlePipeline(reader: reader, translator: Fixed(), server: server, clock: { now })
        pipeline.holdReadings = false
        var areas: [ExtraArea] = []
        pipeline.onNoticesChanged = { areas = $0 }
        let frame = try XCTUnwrap(Self.frame())
        let region = CropRegion(top: 0, bottom: 1, left: 0, right: 1)
        reader.reading = Self.reading(vector.frames[3].lines)
        for _ in 0..<12 {
            await pipeline.process(frame, region: region)
            now += 100
        }
        await pipeline.waitForTranslations()
        XCTAssertEqual(server.texts, [])
        XCTAssertEqual(areas.map(\.id), ["auto-notice-1", "auto-notice-2"])
        XCTAssertTrue(areas.allSatisfy { $0.region.right <= 0.5 || $0.region.left >= 0.5 })
    }

    private static func frame() -> CGImage? {
        let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context?.makeImage()
    }

    private final class FixedReader: TextReader, @unchecked Sendable {
        var reading = Reading.empty
        func read(_ image: CGImage) throws -> String { reading.text }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { reading }
    }

    private final class Fixed: TextTranslator, @unchecked Sendable {
        func translate(_ text: String) async throws -> String { "çeviri" }
    }

    private final class Sent: SubtitleSending {
        var texts: [String] = []
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { texts.append(text) }
        func clear() {}
    }
}
