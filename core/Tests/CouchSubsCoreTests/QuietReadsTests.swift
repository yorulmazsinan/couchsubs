// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Sahte okuyucu (Vision kullanmaz): verilen okumayı döndürür ya da hata verir.
private final class ScriptedReader: TextReader, @unchecked Sendable {
    var reading = Reading.empty
    var error: Error?
    func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        if let error { throw error }
        return reading
    }
}

private final class SilentScreen: SubtitleSending {
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {}
    func clear() {}
}

private final class PlainTranslator: TextTranslator {
    func translate(_ text: String) async throws -> String { "Çeviri: " + text }
}

private struct BrokenRead: Error, CustomStringConvertible {
    var description: String { "bozuk kare" }
}

/// Mac (beta.80, PS5, GTA 6): ekranda diyalog varken altyazı günlüğüne dakikalarca hiçbir satır düşmüyordu; ne okuma
/// takılması ne sahne yazısı. Altyazının okunmadığı mı (menü), boş mu okunduğu mu, süzgeçte mi kaldığı mı, okumanın hata
/// mı verdiği mi anlaşılmıyordu. Sessizlik sürerse nedeni dakikada bir günlüğe yazılır.
@MainActor
final class QuietReadsTests: XCTestCase {
    private func frame(_ shade: Int) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: CGFloat(shade % 7) / 7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    private func run(_ reader: ScriptedReader, frames: Int, stepMs: Int = 1000,
                     each: (SubtitlePipeline, Int) -> Bool = { _, _ in false }) async -> [String] {
        var time = 0
        let pipeline = SubtitlePipeline(reader: reader, translator: PlainTranslator(), server: SilentScreen(), clock: { time })
        var logs: [String] = []
        pipeline.onLog = { logs.append($0) }
        for index in 0..<frames {
            if !each(pipeline, index) { await pipeline.process(frame(index), region: CropRegion()) }
            time += stepMs
        }
        return logs
    }

    func testEmptyReadsAreReportedOncePerMinute() async {
        let logs = await run(ScriptedReader(), frames: 130)
        let quiet = logs.filter { $0.hasPrefix("altyazı alanında") }
        XCTAssertEqual(quiet.count, 2, logs.joined(separator: "\n"))
        XCTAssertTrue(quiet[0].contains("60 sn'dir yazı yok"), quiet[0])
        XCTAssertTrue(quiet[0].contains("boş"), quiet[0])
        XCTAssertFalse(quiet[0].contains(" 0 boş"), quiet[0])
    }

    func testReadErrorsAreReportedWithTheError() async {
        let reader = ScriptedReader()
        reader.error = BrokenRead()
        let logs = await run(reader, frames: 61)
        let quiet = logs.first { $0.hasPrefix("altyazı alanında") }
        XCTAssertNotNil(quiet, logs.joined(separator: "\n"))
        XCTAssertTrue(quiet?.contains("son hata: bozuk kare") == true, quiet ?? "")
    }

    func testTextKeepsTheReportQuiet() async {
        let reader = ScriptedReader()
        reader.reading = Reading(lines: [TextLine("Get in the car, now.", box: TextBox(left: 0.2, top: 0.4, right: 0.8, bottom: 0.6))])
        let logs = await run(reader, frames: 130)
        XCTAssertFalse(logs.contains { $0.hasPrefix("altyazı alanında") }, logs.joined(separator: "\n"))
    }

    /// Menü yüzünden okunmayan kareler: geçiş bir kez yazılır, sessizlik özetinde menü sayılır, menü kapanınca yazılır.
    func testMenuSkipIsLogged() async {
        let logs = await run(ScriptedReader(), frames: 70) { pipeline, index in
            guard index >= 5, index < 66 else { return false }
            pipeline.skipForMenu()
            return true
        }
        XCTAssertEqual(logs.filter { $0.hasPrefix("ekran menü sayıldı") }.count, 1, logs.joined(separator: "\n"))
        XCTAssertEqual(logs.filter { $0.hasPrefix("menü kapandı sayıldı") }.count, 1, logs.joined(separator: "\n"))
        let quiet = logs.first { $0.hasPrefix("altyazı alanında") }
        XCTAssertTrue(quiet?.contains("kare menü yüzünden okunmadı") == true, quiet ?? "")
        XCTAssertFalse(quiet?.contains(" 0 kare menü") ?? true, quiet ?? "")
    }
}
#endif
