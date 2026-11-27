// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Altyazı alanına düşen tabela ve tişört yazısı çevrilmez (X bildirimleri, beta.73, GTA 6, iPhone/iPad). Örnekler ortak
/// deneme dosyasından (Fixtures/scene-text.json; Windows SceneTextTests.cs ve Android SceneTextTest.kt aynı dosyayı okur).
final class SceneTextTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Word: Decodable { let text: String; let box: [Double] }
        struct Line: Decodable { let text: String; let box: [Double]; let confidence: Double?; let words: [Word]? }
        struct Case: Decodable { let name: String; let before: [Line]?; let lines: [Line]; let subtitle: String }
        let area: [Double]
        let cases: [Case]
    }

    private static func box(_ values: [Double]) -> TextBox {
        TextBox(left: values[0], top: values[1], right: values[2], bottom: values[3])
    }

    private func vectors() throws -> Vectors {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("scene-text.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func reading(_ vector: Vectors.Case) -> Reading { reading(vector.lines) }

    private func reading(_ lines: [Vectors.Line]) -> Reading {
        Reading(lines: lines.map { line in
            TextLine(line.text, box: Self.box(line.box), confidence: line.confidence,
                     words: line.words?.map { TextWord($0.text, box: Self.box($0.box)) })
        })
    }

    func testSharedVectors() throws {
        let vectors = try vectors()
        let area = Self.box(vectors.area)
        for vector in vectors.cases {
            // "before": aynı oturumda önceden okunan altyazı; okunduğu yükseklik öğrenilir (SubtitleBand).
            var band = SubtitleBand()
            if let before = vector.before { band.record(reading(before).subtitleBlock(in: area), in: area) }
            XCTAssertEqual(reading(vector).subtitleBlock(in: area, band: band).text, vector.subtitle, vector.name)
        }
    }

    /// Uçtan uca: ekranda altyazı yokken alandaki tabela ve tişört okunur, hiçbir şey TV'ye gitmez; altyazı gelince
    /// yalnız altyazı çevrilir.
    @MainActor
    func testPipelineTranslatesOnlyTheSubtitle() async throws {
        let vectors = try vectors()
        let region = CropRegion(top: vectors.area[1], bottom: vectors.area[3], left: vectors.area[0], right: vectors.area[2])
        let reader = FixedReader()
        let server = Sent()
        var now = 1_000_000
        let pipeline = SubtitlePipeline(reader: reader, translator: Fixed(), server: server, clock: { now })
        pipeline.holdReadings = false
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        let frame = try XCTUnwrap(Self.frame())
        reader.reading = reading(vectors.cases[1])
        for _ in 0..<12 {
            await pipeline.process(frame, region: region)
            now += 100
        }
        await pipeline.waitForTranslations()
        XCTAssertEqual(server.texts, [])
        // Atılan blok günlükte nedeniyle bir kez görünür (GitHub #822).
        let scene = log.filter { $0.hasPrefix("sahne yazısı:") }
        XCTAssertEqual(scene.count, 2, "\(log)")
        XCTAssertTrue(scene.allSatisfy { $0.contains("karenin ortasında kısa satır") }, "\(scene)")
        reader.reading = reading(vectors.cases[0])
        for _ in 0..<12 {
            await pipeline.process(frame, region: region)
            now += 100
        }
        await pipeline.waitForTranslations()
        XCTAssertEqual(server.texts, ["Buradan hemen çıkmalıyız."])
    }

    /// GitHub #822: altyazısı alttaki %22'lik şeridin biraz üstünde duran oyunda kısa altyazılar ("Let's go") da
    /// çevrilir; bu oturumda aynı yükseklikte kesin altyazı okunmuştu.
    @MainActor
    func testShortSubtitleWhereSubtitlesSitIsTranslated() async throws {
        let vectors = try vectors()
        let region = CropRegion(top: vectors.area[1], bottom: vectors.area[3], left: vectors.area[0], right: vectors.area[2])
        let learned = try XCTUnwrap(vectors.cases.first { $0.before != nil && $0.subtitle == "Let's go" })
        let reader = FixedReader()
        let server = Sent()
        var now = 1_000_000
        let pipeline = SubtitlePipeline(reader: reader, translator: Reversed(), server: server, clock: { now })
        pipeline.holdReadings = false
        let frame = try XCTUnwrap(Self.frame())
        for lines in [try XCTUnwrap(learned.before), learned.lines] {
            reader.reading = reading(lines)
            for _ in 0..<12 {
                await pipeline.process(frame, region: region)
                now += 100
            }
            reader.reading = .empty
            for _ in 0..<6 {
                await pipeline.process(frame, region: region)
                now += 100
            }
            await pipeline.waitForTranslations()
        }
        XCTAssertEqual(server.texts, [".kcab emoc yeht erofeb ereh fo tuo teg ot deen eW", "og s'teL"])
    }

    /// Alanda okunup altyazı bloğu seçilmeyen satırlar (burada alt alta menü) günlüğe bir kez yazılır; eskiden sessizce
    /// atılıyordu (iPhone 1.0.6, 2026-11-22: altyazı çevrilmeyince günlükte neden yoktu).
    @MainActor
    func testLinesLeftOutOfTheSubtitleBlockAreLoggedOnce() async throws {
        let reader = FixedReader()
        reader.reading = Reading(lines: [
            TextLine("We need to get out of here.", box: TextBox(left: 0.30, top: 0.40, right: 0.70, bottom: 0.50)),
            TextLine("MAP", box: TextBox(left: 0.02, top: 0.05, right: 0.08, bottom: 0.12)),
            TextLine("HELP", box: TextBox(left: 0.02, top: 0.14, right: 0.08, bottom: 0.21)),
            TextLine("SETTINGS", box: TextBox(left: 0.02, top: 0.23, right: 0.10, bottom: 0.30)),
        ])
        var now = 1_000_000
        let pipeline = SubtitlePipeline(reader: reader, translator: Reversed(), server: Sent(), clock: { now })
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        let frame = try XCTUnwrap(Self.frame())
        for _ in 0..<5 {
            await pipeline.process(frame, region: CropRegion())
            now += 100
        }
        await pipeline.waitForTranslations()
        let left = log.filter { $0.hasPrefix("altyazı sayılmadı:") }
        XCTAssertEqual(left, ["altyazı sayılmadı: \"MAP / HELP / SETTINGS\" (seçilen: \"We need to get out of here.\")"],
                       log.joined(separator: "\n"))
    }

    /// #1411 (GTA 6, beta-105): plakanın "GOOD TIME STATE" yazısı bir karede plaka sayılıp atılıyor, bir sonraki karede
    /// tek satır ve noktalı ("& COCOTIME STATE O.") okununca altyazı sanılıp çevriliyordu. Az önce atılan yazının başka
    /// okunuşu artık altyazı olmaz (`SceneTextMemory`); aynı okuma önceden plaka görülmeden gelirse altyazı kuralı onu
    /// geçirir (denemenin kendisi bunu da doğrular).
    @MainActor
    func testPlateRereadAfterBeingDroppedIsNotTranslated() async throws {
        let plate = Reading(lines: [
            TextLine("NIC", box: TextBox(left: 0.47, top: 0.82, right: 0.53, bottom: 0.85), confidence: 1),
            TextLine("COCOTIME STATE A", box: TextBox(left: 0.42, top: 0.86, right: 0.58, bottom: 0.89), confidence: 1),
        ])
        let reread = Reading(lines: [
            TextLine("& COCOTIME STATE O.", box: TextBox(left: 0.42, top: 0.86, right: 0.58, bottom: 0.89), confidence: 1),
        ])
        let alone = try await Self.run([reread])
        XCTAssertEqual(alone.sent.count, 1, "denemede okuma kendi başına altyazı geçmeli: \(alone.log)")
        let after = try await Self.run([plate, reread])
        XCTAssertEqual(after.sent, [], after.log.joined(separator: "\n"))
        XCTAssertTrue(after.log.contains { $0.contains(SceneTextMemory.reason) && $0.contains("plaka/tabela") },
                      after.log.joined(separator: "\n"))
    }

    /// Gerçek karenin kayıtlı okuması (testdata/frames/ocr; Mac'te Apple Vision ile kaydedildi).
    private static func recorded(_ id: String) throws -> Reading {
        struct Line: Decodable { let text: String; let box: [Double] }
        struct Fixture: Decodable { let lines: [Line] }
        let url = FrameReplayTests.directory.appendingPathComponent("ocr/\(id).json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        return Reading(lines: fixture.lines.map {
            TextLine($0.text, box: TextBox(left: $0.box[0], top: $0.box[1], right: $0.box[2], bottom: $0.box[3]), confidence: 1)
        })
    }

    /// #1414'ün yan etkisi (gerçek kare gta6-n1-kitap): kitap kapağının "[TOM E / DESIGN" satırları tabela sayılıp
    /// atılıyor, alt satır ("A LIBERTY CITY MEMOIR") belirince DESIGN hatırlanıp çıkarılıyor, kapağın tek kalan satırı
    /// altyazı sanılıp çevriliyordu. Bloğun çoğu sahne yazısıysa kalanı da çevrilmez; günlükte nedeniyle yazılır
    /// (Windows/Android aynı).
    @MainActor
    func testLeftoverLineOfASceneBlockIsNotTranslated() async throws {
        let cover = try Self.recorded("gta6-n1-kitap")
        let top = Reading(lines: cover.lines.filter { $0.text != "A LIBERTY CITY MEMOIR" })
        let run = try await Self.run([top, cover])
        XCTAssertEqual(run.sent, [], run.log.joined(separator: "\n"))
        XCTAssertTrue(run.log.contains { $0.contains(SceneTextMemory.blockReason) && $0.contains("A LIBERTY CITY MEMOIR") },
                      run.log.joined(separator: "\n"))
    }

    /// Telefon sohbeti (gerçek kare gta6-telefon-sohbet-1): altyazının yüksekliği konuşmadan (gta6-01-lucia) öğrenildikten
    /// sonra üç satırı menü açıklaması sayılıp atılan mesajın son satırı ("bring it 2 me •") tek başına çevrilmez.
    @MainActor
    func testLeftoverLineOfAPhoneChatIsNotTranslated() async throws {
        let chat = try Self.recorded("gta6-telefon-sohbet-1")
        let top = Reading(lines: chat.lines.filter { !$0.text.hasPrefix("bring") })
        let run = try await Self.run([try Self.recorded("gta6-01-lucia"), top, chat])
        XCTAssertEqual(run.sent.count, 1, run.log.joined(separator: "\n"))
        XCTAssertTrue(run.sent.allSatisfy { $0.hasSuffix(String("Could I have another ice water, please?".reversed())) },
                      run.sent.joined(separator: "\n"))
    }

    /// Okumaları sırayla (her biri 12 kare) tam ekran alanda hattan geçirir; TV'ye gidenler ve günlük.
    @MainActor
    private static func run(_ readings: [Reading]) async throws -> (sent: [String], log: [String]) {
        let reader = FixedReader()
        let server = Sent()
        var now = 1_000_000
        let pipeline = SubtitlePipeline(reader: reader, translator: Reversed(), server: server, clock: { now })
        pipeline.holdReadings = false
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        let frame = try XCTUnwrap(frame())
        for reading in readings {
            reader.reading = reading
            for _ in 0..<12 {
                await pipeline.process(frame, region: CropRegion())
                now += 100
            }
        }
        await pipeline.waitForTranslations()
        return (server.texts, log)
    }

    private final class Reversed: TextTranslator, @unchecked Sendable {
        func translate(_ text: String) async throws -> String { String(text.reversed()) }
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
        func translate(_ text: String) async throws -> String { "Buradan hemen çıkmalıyız." }
    }

    private final class Sent: SubtitleSending {
        var texts: [String] = []
        func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { texts.append(text) }
        func clear() {}
    }
}
