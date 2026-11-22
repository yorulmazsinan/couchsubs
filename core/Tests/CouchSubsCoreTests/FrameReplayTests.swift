// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import Foundation
import XCTest

/// Gerçek kare gerileme setinin (testdata/frames, scripts/regression-frames.sh) altyazı seçimi, kayıtlı Vision
/// okumalarıyla: her oturumun kareleri sırayla aynı seçimden geçer (düğme ipuçları ve yazı tanıma çöpü atılır, satırlar
/// birleşir, altyazı bloğu seçilir, altyazının yeri öğrenilir). Seçilen blok testdata/frames/ocr/selection.json'daki
/// beklenenle aynı olmalı. Android (FrameReplayTest.kt) ve Windows (FrameReplayTests.cs) aynı okumalarla aynı sonucu
/// vermeli. Seçim bilerek değişince yeniden yazmak için: RECORD_FRAME_SELECTION=1 swift test --filter FrameReplayTests
final class FrameReplayTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Frame: Decodable { let id: String; let session: String? }
        let frames: [Frame]
    }

    private struct Fixture: Decodable {
        struct Word: Decodable { let text: String; let box: [Double] }
        struct Line: Decodable { let text: String; let box: [Double]?; let confidence: Double?; let words: [Word]? }
        let id: String
        let region: [Double]
        let lines: [Line]
        /// Karedeki GTA 6 telefonu [üstX, üstY, altX, altY, kare eni/boyu]; ekranındaki satırlar altyazı hattına girmez.
        let phone: [Double]?
    }

    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../testdata/frames").standardized
    }

    private static func box(_ values: [Double]) -> TextBox {
        TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3])
    }

    /// Kareler oturum oturum, manifestteki sırayla; her karenin seçilen altyazı bloğu.
    static func selections() throws -> [(id: String, text: String)] {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("frames.json")))
        var bands: [String: SubtitleBand] = [:]
        var result: [(id: String, text: String)] = []
        for frame in manifest.frames {
            let url = directory.appendingPathComponent("ocr/\(frame.id).json")
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let area = box(fixture.region)
            var reading = Reading(lines: fixture.lines.map { line in
                TextLine(line.text, box: line.box.map(box), confidence: line.confidence,
                         words: line.words?.map { TextWord($0.text, box: box($0.box)) })
            })
            if let p = fixture.phone, p.count == 5 {
                // Altyazı hattı gibi: telefonun ekranındaki satırlar okunmaz (`SubtitlePipeline.findsPhone`).
                let handset = ScreenPhoneCard.Handset(pose: GamePhoneGeometry.Pose(topX: p[0], topY: p[1], bottomX: p[2], bottomY: p[3]), aspect: p[4])
                reading = Reading(lines: reading.lines.filter { line in
                    line.box.map { !ScreenPhoneCard.holds($0.placed(in: area), handset: handset) } ?? true
                })
            }
            let key = frame.session ?? frame.id
            var band = bands[key] ?? SubtitleBand()
            let block = reading.withoutButtonPrompts().withoutOcrNoise().joiningRows().subtitleBlock(in: area, band: band)
            band.record(block, in: area)
            bands[key] = band
            result.append((frame.id, block.text))
        }
        return result
    }

    func testSelectionMatchesRecordedRealFrames() throws {
        let selections = try Self.selections()
        XCTAssertGreaterThanOrEqual(selections.count, 40)
        let golden = Self.directory.appendingPathComponent("ocr/selection.json")
        if ProcessInfo.processInfo.environment["RECORD_FRAME_SELECTION"] == "1" {
            let pairs = selections.map { "  \(Self.quoted($0.id)): \(Self.quoted($0.text))" }
            try ("{\n" + pairs.joined(separator: ",\n") + "\n}\n").write(to: golden, atomically: true, encoding: .utf8)
            return
        }
        let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: golden))
        XCTAssertEqual(Set(expected.keys), Set(selections.map(\.id)))
        for (id, text) in selections {
            XCTAssertEqual(text, expected[id], id)
        }
    }

    private static func quoted(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
    }
}
