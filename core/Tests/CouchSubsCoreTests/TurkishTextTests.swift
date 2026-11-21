// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class TurkishReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class TurkishSender: SubtitleSending {
    var sent: [String] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() {}
}
private final class TurkishTranslator: TextTranslator {
    var requested: [String] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        return "TR: " + text
    }
}

/// Ekranda zaten Türkçe olan satır çevrilmez (#289; Windows: TurkishTextTests.cs, Android: TurkishTextTest.kt).
@MainActor
final class TurkishTextTests: XCTestCase {
    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    func testTurkishLinesAreSure() {
        for text in ["Daha Sonra Güncelle", "Sistem Yazillml Güncellem€", "Lütfen bekleyin.", "Ekran görüntüsü kaydedildi",
                     "Yardımcı\nolabilir miyim, efendim?", "Merchant: Yardımcı olabilir miyim, efendim?"] {
            XCTAssertTrue(TurkishText.isSure(text), text)
        }
    }

    func testOtherLinesAreNotSure() {
        for text in ["Atatürk said we must defend the city.", "Herr Müller wants the system back online.",
                     "Play Grand Theft Auto V's Story Mode.", "Kurulum sirasmda PS5 sisteminizi kapatmayn."] {
            XCTAssertFalse(TurkishText.isSure(text), text)
        }
    }

    private func run(_ line: String, skipsTurkish: Bool = true) async -> (TurkishTranslator, TurkishSender) {
        var time = 0
        let translator = TurkishTranslator(), sender = TurkishSender()
        let pipeline = SubtitlePipeline(reader: TurkishReader(Array(repeating: line, count: 4)), translator: translator,
                                        server: sender, clock: { time })
        pipeline.skipsTurkish = skipsTurkish
        pipeline.packWait = 0; pipeline.cleanWait = 0; pipeline.holdReadings = true
        for _ in 0..<4 {
            await pipeline.process(image, region: CropRegion())
            await pipeline.waitForTranslations()
            time += 100
        }
        return (translator, sender)
    }

    func testTurkishLineIsNotSentToTheEngine() async {
        let (translator, sender) = await run("Daha Sonra Güncelle")
        XCTAssertEqual(translator.requested, [])
        XCTAssertEqual(sender.sent, [])
    }

    func testEnglishLineWithTurkishNameIsTranslated() async {
        let (translator, sender) = await run("Atatürk said no.")
        XCTAssertEqual(translator.requested, ["Atatürk said no."])
        XCTAssertEqual(sender.sent, ["TR: Atatürk said no."])
    }

    func testOtherTargetLanguageTranslatesTurkish() async {
        let (translator, _) = await run("Daha Sonra Güncelle", skipsTurkish: false)
        XCTAssertEqual(translator.requested, ["Daha Sonra Güncelle"])
    }
}
#endif
