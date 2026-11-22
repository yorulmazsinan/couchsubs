// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Görüntü kaynağı OBS'in Program projektörü: karede CouchSubs'ın OBS katmanındaki Türkçe altyazı da var (X bildirimi,
/// capture card + OBS). Okuyucu, gönderilen çeviri ekrandayken onu da (yazı tanımanın Türkçe harfleri bozduğu hâliyle)
/// okur.
private final class ProjectorScreen: SubtitleSending, @unchecked Sendable {
    var english: String
    /// "Örtsün": çeviri İngilizce satırın üstüne çizilir, İngilizce görünmez. Değilse ikisi alt alta görünür.
    var covers: Bool
    var shown: String?
    var sent: [String] = []
    var clears = 0
    init(english: String, covers: Bool) { self.english = english; self.covers = covers }
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text); shown = text }
    func clear() { clears += 1; shown = nil }

    /// Yazı tanımanın (İngilizce) Türkçe harfleri düz harfe çevirdiği okuma.
    static func ocr(_ text: String) -> String {
        String(text.map { ["ı": "i", "ş": "s", "ğ": "g", "ç": "c", "ö": "o", "ü": "u", "İ": "I", "Ş": "S", "Ç": "C",
                           "Ö": "O", "Ü": "U", "Ğ": "G"][$0] ?? $0 })
    }

    var frame: Reading {
        let english = TextLine(english, box: TextBox(left: 0.2, top: 0.40, right: 0.8, bottom: 0.60))
        guard let shown else { return Reading(lines: [english]) }
        let own = TextLine(Self.ocr(shown), box: TextBox(left: 0.18, top: covers ? 0.38 : 0.70, right: 0.82,
                                                         bottom: covers ? 0.62 : 0.92))
        return Reading(lines: covers ? [own] : [english, own])
    }
}

private struct ProjectorReader: TextReader {
    let screen: ProjectorScreen
    func read(_ image: CGImage) throws -> String { screen.frame.text }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading { screen.frame }
}

private final class DictionaryTranslator: TextTranslator {
    var requested: [String] = []
    let table: [String: String]
    init(_ table: [String: String]) { self.table = table }
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        return table[text] ?? "Çeviri: \(text)"
    }
}

@MainActor
final class OwnSubtitleTests: XCTestCase {
    private let english = "You shouldn't have done that, Lucia."
    private let turkish = "Bunu yapmamalıydın, Lucia. Çok üzgünüm."
    /// Karenin izi satırla değişir (kararlayıcı aynı izli boş okumayı "satır duruyor" sayar).
    private func image(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: CGFloat(text.count % 7) / 7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    private let next = "Get in the car, now."
    private let nextTurkish = "Hemen arabaya bin."

    /// `script`: kare numarasına göre ekrandaki İngilizce satır (nil: değişmez).
    private func run(covers: Bool, frames: Int = 60, script: (Int) -> String? = { _ in nil })
        async -> (ProjectorScreen, DictionaryTranslator, [String]) {
        var time = 0
        let screen = ProjectorScreen(english: english, covers: covers)
        let translator = DictionaryTranslator([english: turkish, next: nextTurkish])
        let pipeline = SubtitlePipeline(reader: ProjectorReader(screen: screen), translator: translator, server: screen,
                                        clock: { time })
        var logs: [String] = []
        pipeline.onLog = { logs.append($0) }
        pipeline.packWait = 0; pipeline.cleanWait = 0
        for index in 0..<frames {
            if let line = script(index) { screen.english = line }
            await pipeline.process(image(screen.english), region: CropRegion())
            await pipeline.waitForTranslations()
            time += 100
        }
        return (screen, translator, logs)
    }

    /// Örtme yerleşimi: çeviri İngilizce satırı örtünce okunan tek satır kendi çevirimizdir. Önceden bu "yeni satır"
    /// sayılıp yeniden çevriliyor, sonra İngilizce yeniden görünüyor, altyazı yanıp sönüyordu.
    func testOwnSubtitleCoveringTheLineIsNotReadAsANewLine() async {
        let (screen, translator, logs) = await run(covers: true)
        XCTAssertEqual(translator.requested, [english])
        XCTAssertEqual(screen.sent, [turkish])
        XCTAssertEqual(screen.clears, 0)
        XCTAssertTrue(logs.contains { $0.contains("kendi altyazısı") }, logs.joined(separator: "\n"))
    }

    /// Sabit yerleşim: İngilizce satır ve bizim Türkçe altyazımız alt alta görünür; Türkçe satır İngilizceye katılıp
    /// satırı değiştirmez.
    func testOwnSubtitleBelowTheLineIsIgnored() async {
        let (screen, translator, _) = await run(covers: false)
        XCTAssertEqual(translator.requested, [english])
        XCTAssertEqual(screen.sent, [turkish])
        XCTAssertEqual(screen.clears, 0)
    }

    /// Sabit yerleşimde İngilizce satır kalkınca altyazı kalkar (ayrı yerdeki kendi altyazımız satırı tutmaz); sonraki
    /// satır her zamanki gibi çevrilir.
    func testLineLeavingAndNextLineStillWorkBesideOwnSubtitle() async {
        let (screen, translator, _) = await run(covers: false, frames: 90) { index in
            index == 30 ? "" : index == 45 ? self.next : nil
        }
        XCTAssertEqual(translator.requested, [english, next])
        XCTAssertEqual(screen.sent, [turkish, nextTurkish])
        XCTAssertEqual(screen.clears, 1)
    }

    /// OBS'i okumayan kurulum: karede çevirimiz yok, süzgeç hiçbir satırı atmaz; çevirisi kaynağıyla aynı adları taşıyan
    /// İngilizce satır da atılmaz.
    func testEnglishLineIsNeverTakenForOwnSubtitle() {
        var time = 0
        let own = OwnSubtitles(clock: { time })
        let lucia = Reading(lines: [TextLine("Lucia, Jason!", box: TextBox(left: 0.3, top: 0.8, right: 0.7, bottom: 0.9))])
        XCTAssertEqual(own.split(lucia).kept, lucia)
        own.record("Lucia, Jason! Buraya gelin.", source: "Lucia, Jason! Come here.", durationMs: 15000)
        time += 500
        XCTAssertTrue(own.split(lucia).own.isEmpty)
        XCTAssertFalse(own.isOwn("Lucia, Jason! Come here."))
        XCTAssertFalse(own.isOwn("Come here, Lucia."))
        XCTAssertTrue(own.isOwn("Lucia, Jason! Buraya gelin."))
        // Süre dolunca (ve pay geçince) hiçbir şey kendi altyazısı sayılmaz.
        time += 15000 + OwnSubtitles.textGraceMs + 1
        XCTAssertFalse(own.isOwn("Lucia, Jason! Buraya gelin."))
    }

    /// Katman uzun çeviriyi satırlara böler; yazı tanıma Türkçe harfleri bozar. Her parça tanınır, tanınmayacak kadar
    /// bozulan parça da öğrenilen yerinden atılır; o yerin dışındaki satıra dokunulmaz.
    func testWrappedAndGarbledOwnRowsAreDropped() {
        var time = 0
        let own = OwnSubtitles(clock: { time })
        own.record("Bunu yapmamalıydın Lucia, şimdi hepimiz büyük bir belanın içindeyiz.",
                   source: "You shouldn't have done that, Lucia. Now we're all in big trouble.", durationMs: 15000)
        time += 300
        let first = TextLine("Bunu yapmamaliydin Lucia, simdi", box: TextBox(left: 0.3, top: 0.80, right: 0.7, bottom: 0.85))
        let hint = TextLine("Press X to skip", box: TextBox(left: 0.02, top: 0.94, right: 0.15, bottom: 0.97))
        let clean = own.split(Reading(lines: [
            first, TextLine("hepimiz buyuk bir belanin icindeyiz.", box: TextBox(left: 0.31, top: 0.86, right: 0.69, bottom: 0.91)),
            hint,
        ]))
        XCTAssertEqual(clean.kept.lines.map(\.text), ["Press X to skip"])
        let reading = Reading(lines: [
            first, TextLine("h3p!miz bvyvk b1r be!anin", box: TextBox(left: 0.32, top: 0.86, right: 0.68, bottom: 0.91)), hint,
        ])
        let (kept, dropped) = own.split(reading)
        XCTAssertEqual(kept.lines.map(\.text), ["Press X to skip"])
        XCTAssertEqual(dropped.count, 2)
        XCTAssertTrue(own.isOwn("hepimiz büyük bir belanın içindeyiz."))
        XCTAssertTrue(OwnSubtitles.coversLine(dropped, line: TextBox(left: 0.3, top: 0.81, right: 0.7, bottom: 0.9)))
        XCTAssertFalse(OwnSubtitles.coversLine(dropped, line: TextBox(left: 0.3, top: 0.4, right: 0.7, bottom: 0.5)))
        // Çeviri kalkınca öğrenilen yer kısa süre sonra bırakılır: aynı yere gelen yeni İngilizce satır okunur.
        own.cleared()
        time += OwnSubtitles.placeGraceMs + 1
        XCTAssertEqual(own.split(reading).kept.lines.count, 2)
    }

    /// Ekran yazısı okuyucuları da kendi altyazımızı ekran yazısı olarak çevirmez.
    func testScreenTextReadersSkipOwnSubtitle() {
        let echo = SubtitleEcho(clock: { 0 })
        let own = OwnSubtitles(clock: { 0 })
        echo.own = own
        own.record(turkish, source: english, durationMs: 15000)
        let reading = Reading(lines: [TextLine(ProjectorScreen.ocr(turkish)), TextLine("Vice City Beach")])
        XCTAssertEqual(echo.filter(reading, geometry: false).lines.map(\.text), ["Vice City Beach"])
    }
}
#endif
