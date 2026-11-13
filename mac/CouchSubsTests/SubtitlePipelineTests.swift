// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import ImageIO
import XCTest
@testable import CouchSubs

private final class FakeReader: TextReader, @unchecked Sendable {
    var texts: [String]
    var readOnMainThread: [Bool] = []
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String {
        readOnMainThread.append(Thread.isMainThread)
        return texts.isEmpty ? "" : texts.removeFirst()
    }
}

/// Satırları yerleriyle döndüren okuyucu.
private struct LinesReader: TextReader {
    let reading: Reading
    init(_ reading: Reading) { self.reading = reading }
    func read(_ image: CGImage) throws -> String { reading.text }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading { reading }
}

private final class FakeTranslator: TextTranslator {
    var error: Error?
    var failuresLeft = 0
    private(set) var requested: [String] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if let error { throw error }
        if failuresLeft > 0 { failuresLeft -= 1; throw URLError(.timedOut) }
        return "TR: " + text
    }
}

private final class SpeakingTranslator: TextTranslator {
    func translate(_ text: String) async throws -> String { "TR: " + text }
    func spokenLines(for text: String) -> [SpokenLine] { [SpokenLine(english: text, turkish: "TR: " + text)] }
}

/// Çevirileri test kapıyı açana kadar bekletir; kapı açıldıktan sonra gelenler beklemez.
private final class GatedTranslator: TextTranslator {
    private(set) var requested: [String] = []
    private var isOpen = false
    private var waiting: [(text: String, continuation: CheckedContinuation<Void, Never>)] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if !isOpen { await withCheckedContinuation { waiting.append((text, $0)) } }
        return "TR: " + text
    }
    func open() { isOpen = true; waiting.forEach { $0.continuation.resume() }; waiting.removeAll() }
    /// Yalnız bu satırın çevirisini bitirir (sırayı test belirler).
    func release(_ text: String) async {
        while !waiting.contains(where: { $0.text == text }) { await Task.yield() }
        let index = waiting.firstIndex { $0.text == text }!
        waiting.remove(at: index).continuation.resume()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class FakeSender: SubtitleSending {
    var sent: [String] = []
    var durations: [Int] = []
    var boxes: [TextBox?] = []
    var replaces: [Bool] = []
    var clears = 0
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {
        sent.append(text); durations.append(durationMs); boxes.append(box); self.replaces.append(replaces)
    }
    func clear() { clears += 1 }
}

/// Testlerde elle ilerletilen saat (milisaniye).
private final class PipelineClock: @unchecked Sendable {
    var now = 1_000_000
    func read() -> Int { now }
}

/// Her okumada saati `readMs` ilerleten okuyucu (ölçüm testleri).
private struct TimedReader: TextReader {
    let clock: PipelineClock
    let readMs: Int
    let reading: Reading
    func read(_ image: CGImage) throws -> String { reading.text }
    func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
        clock.now += readMs
        return reading
    }
}

/// Her çeviride saati `translateMs` ilerleten çevirmen (ölçüm testleri).
private final class TimedTranslator: TextTranslator {
    let clock: PipelineClock
    let translateMs: Int
    init(clock: PipelineClock, translateMs: Int) {
        self.clock = clock
        self.translateMs = translateMs
    }
    func translate(_ text: String) async throws -> String {
        clock.now += translateMs
        return "TR: " + text
    }
}

/// Okuması test bırakana kadar biten okuyucu (takılan ya da çok yavaş yazı tanıma).
private final class BlockingReader: TextReader, @unchecked Sendable {
    private let text: String
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var didStart = false
    init(_ text: String) { self.text = text }
    var started: Bool { lock.withLock { didStart } }
    func release() { gate.signal() }
    func read(_ image: CGImage) throws -> String {
        lock.withLock { didStart = true }
        gate.wait()
        return text
    }
}

private func lines(_ runs: (String, Int)...) -> [String] {
    runs.flatMap { Array(repeating: $0.0, count: $0.1) }
}

@MainActor
final class SubtitlePipelineTests: XCTestCase {
    private let frame: CGImage = {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    /// Saniyede 20 okuma: saat verilirse her kareden sonra 50 ms ilerler.
    private func run(_ pipeline: SubtitlePipeline, _ frames: Int, wait: Bool = true, clock: PipelineClock? = nil) async {
        for _ in 0..<frames {
            await pipeline.process(frame, region: CropRegion())
            if wait { await pipeline.waitForTranslations() }
            clock?.now += 50
        }
    }

    func testStableTextIsTranslatedAndSentOnce() async {
        let sender = FakeSender()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate", "Hold the gate", "Hold the gate"]),
                                        translator: FakeTranslator(), server: sender)
        for _ in 0..<3 { await pipeline.process(frame, region: CropRegion()); await pipeline.waitForTranslations() }
        XCTAssertEqual(sender.sent, ["TR: Hold the gate"])
        XCTAssertEqual(pipeline.lastPair?.source, "Hold the gate")
    }

    /// Okuma sürerken hat sıfırlanırsa (Durdur, takılan okuma yüzünden yeniden kurulan hat) geç biten okuma yeni
    /// oturuma karışmaz: TV'ye eski satır gitmez, çevirmen çağrılmaz.
    func testReadFinishingAfterResetIsDropped() async {
        let reader = BlockingReader("Hold the gate.")
        let sender = FakeSender()
        let translator = FakeTranslator()
        let pipeline = SubtitlePipeline(reader: reader, translator: translator, server: sender)
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        let running = Task { await pipeline.process(frame, region: CropRegion()) }
        while !reader.started { await Task.yield() }
        pipeline.reset()
        reader.release()
        await running.value
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, [])
        XCTAssertEqual(translator.requested, [])
        XCTAssertTrue(log.contains { $0.hasPrefix("eski okuma ") && $0.hasSuffix("hat sıfırlanmıştı; atıldı") }, log.joined(separator: "\n"))
    }

    /// Aynı okuma hat sıfırlanmadan biterse satır gider (yukarıdaki testin karşılığı).
    func testBlockedReadIsSentWhenNotReset() async {
        let reader = BlockingReader("Hold the gate.")
        let sender = FakeSender()
        let pipeline = SubtitlePipeline(reader: reader, translator: FakeTranslator(), server: sender)
        let running = Task { await pipeline.process(frame, region: CropRegion()) }
        while !reader.started { await Task.yield() }
        reader.release()
        await running.value
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, ["TR: Hold the gate."])
    }

    /// Altyazı günlüğü: ilk kare, ilk yazı, her kararlı satır ve akıbeti (motor ya da paket) yazılır.
    func testLogsEachLineAndItsOutcome() async {
        let sender = FakeSender()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate.", "Hold the gate.", "Run!", "Run!"]),
                                        translator: FakeTranslator(), server: sender)
        var log: [String] = []
        pipeline.onLog = { log.append($0) }
        pipeline.packLookup = { $0 == "Run!" ? PackMatch(text: "Koş!", spoken: []) : nil }
        pipeline.packName = { "mafia" }
        for _ in 0..<4 { await pipeline.process(frame, region: CropRegion()); await pipeline.waitForTranslations() }
        pipeline.reset()
        XCTAssertEqual(sender.sent, ["TR: Hold the gate.", "Koş!"])
        XCTAssertEqual(log.count, 6, log.joined(separator: "\n"))
        XCTAssertTrue(log[0].hasPrefix("ilk kare: oturum başından "), log[0])
        XCTAssertTrue(log[1].hasPrefix("ilk yazı: ") && log[1].hasSuffix("\"Hold the gate.\""), log[1])
        XCTAssertEqual(log[2], "#1 \"Hold the gate.\" → çeviriye")
        XCTAssertTrue(log[3].hasPrefix("#1 çeviri:motor ") && log[3].hasSuffix(" ms, gösterildi"), log[3])
        XCTAssertEqual(log[4], "#2 \"Run!\" → paket:mafia")
        XCTAssertEqual(log[5], "hat sıfırlandı (paketten 1 satır)")
    }

    /// Canlı altyazı alanındaki ölçümler gerçek sürelerdir: okuma, çeviri ve karenin gelişinden TV'ye kadar geçen süre.
    func testSentLineReportsMeasuredTimes() async {
        let clock = PipelineClock()
        let reader = TimedReader(clock: clock, readMs: 40, reading: Reading(lines: [TextLine("Hold the gate.", confidence: 0.9)]))
        let pipeline = SubtitlePipeline(reader: reader, translator: TimedTranslator(clock: clock, translateMs: 300),
                                        server: FakeSender(), clock: clock.read)
        var reported: [LineMetrics] = []
        pipeline.onMetrics = { reported.append($0) }
        for _ in 0..<3 {
            await pipeline.process(frame, region: CropRegion(), capturedAt: clock.now)
            await pipeline.waitForTranslations()
            clock.now += 50
        }
        XCTAssertEqual(reported, [LineMetrics(ocrMs: 40, translationMs: 300, totalMs: 340, confidence: 90, origin: .engine)])
        XCTAssertEqual(pipeline.lastMetrics, reported.first)
    }

    func testPackLineReportsNoTranslationTime() async {
        let clock = PipelineClock()
        let reader = TimedReader(clock: clock, readMs: 25, reading: Reading(text: "Run!"))
        let pipeline = SubtitlePipeline(reader: reader, translator: TimedTranslator(clock: clock, translateMs: 300),
                                        server: FakeSender(), clock: clock.read)
        pipeline.packLookup = { $0 == "Run!" ? PackMatch(text: "Koş!", spoken: []) : nil }
        var reported: [LineMetrics] = []
        pipeline.onMetrics = { reported.append($0) }
        for _ in 0..<3 {
            await pipeline.process(frame, region: CropRegion(), capturedAt: clock.now)
            await pipeline.waitForTranslations()
            clock.now += 50
        }
        XCTAssertEqual(reported, [LineMetrics(ocrMs: 25, translationMs: nil, totalMs: 25, confidence: nil, origin: .pack)])
    }

    func testEachSentLineIsHandedToDubbingOnce() async {
        let sender = FakeSender()
        let translator = SpeakingTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate", "Hold the gate", "Hold the gate"]),
                                        translator: translator, server: sender)
        var spoken: [[SpokenLine]] = []
        pipeline.onSpeech = { spoken.append($0) }
        for _ in 0..<3 { await pipeline.process(frame, region: CropRegion()); await pipeline.waitForTranslations() }
        XCTAssertEqual(spoken, [[SpokenLine(english: "Hold the gate", turkish: "TR: Hold the gate")]])
    }

    func testTtsFormEncodesSpecialCharacters() {
        XCTAssertEqual(PocketTTSServer.form(["text": "[kızgın] dur & bekle = 1+1", "voice_url": "http://127.0.0.1:8787/voices/male_1.wav"]),
                       "text=%5Bk%C4%B1zg%C4%B1n%5D%20dur%20%26%20bekle%20%3D%201%2B1&voice_url=http%3A%2F%2F127.0.0.1%3A8787%2Fvoices%2Fmale_1.wav")
    }

    func testButtonPromptsAreNotTranslated() async {
        let sender = FakeSender()
        let pipeline = SubtitlePipeline(reader: FakeReader(["R2 Swing", "R2 Swing", "Hold the gate\nR2 Swing", "Hold the gate\nR2 Swing"]),
                                        translator: FakeTranslator(), server: sender)
        for _ in 0..<4 { await pipeline.process(frame, region: CropRegion()); await pipeline.waitForTranslations() }
        XCTAssertEqual(sender.sent, ["TR: Hold the gate"])
    }

    func testSubtitleBoxIsSentInFrameCoordinates() async {
        let sender = FakeSender()
        let reading = Reading(lines: [TextLine("Hold the gate.", box: TextBox(left: 0.25, top: 0.5, right: 0.75, bottom: 1))])
        let pipeline = SubtitlePipeline(reader: LinesReader(reading), translator: FakeTranslator(), server: sender)
        await pipeline.process(frame, region: CropRegion(top: 0.6, bottom: 1.0, left: 0.1, right: 0.9))
        await pipeline.waitForTranslations()
        let box = try? XCTUnwrap(sender.boxes.first ?? nil)
        XCTAssertEqual(box?.left ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(box?.top ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(box?.right ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertEqual(box?.bottom ?? 0, 1.0, accuracy: 1e-9)
    }

    func testTextRecognitionRunsOffTheMainThread() async {
        let reader = FakeReader(["Hold the gate"])
        let pipeline = SubtitlePipeline(reader: reader, translator: FakeTranslator(), server: FakeSender())
        await pipeline.process(frame, region: CropRegion())
        XCTAssertEqual(reader.readOnMainThread, [false])
    }

    func testMissingLanguagePackSendsNothing() async {
        let sender = FakeSender()
        let translator = FakeTranslator()
        translator.error = TranslatorError.needsDownload
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate", "Hold the gate"]), translator: translator, server: sender)
        for _ in 0..<2 { await pipeline.process(frame, region: CropRegion()); await pipeline.waitForTranslations() }
        XCTAssertTrue(sender.sent.isEmpty)
        XCTAssertEqual(pipeline.lastError, .needsDownload)
    }

    func testFailedTranslationIsRetriedWhileLineStaysOnScreen() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = FakeTranslator()
        translator.failuresLeft = 1
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate", 25))), translator: translator, server: sender,
                                        clock: clock.read)
        await run(pipeline, 25, clock: clock)
        XCTAssertEqual(sender.sent, ["TR: Hold the gate"])
    }

    /// Kalıcı hatada (dil paketi eksik) satır ekranda durdukça çevirmene saniyede en çok bir kez gidilir.
    func testFailedTranslationRetriesAreRateLimited() async {
        let clock = PipelineClock()
        let translator = FakeTranslator()
        translator.error = TranslatorError.needsDownload
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate", 40))), translator: translator, server: FakeSender(),
                                        clock: clock.read)
        await run(pipeline, 40, clock: clock)
        XCTAssertTrue((2...3).contains(translator.requested.count), "\(translator.requested.count)")
    }

    /// Okuma saniyede ~20 kez yapılır; kısa okunamayan an altyazıyı TV'den silmemeli.
    func testShortReadingGapDoesNotClearTheTV() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate", 2), ("", 2), ("Hold the gate", 1))),
                                        translator: FakeTranslator(), server: sender, clock: clock.read)
        await run(pipeline, 5, clock: clock)
        XCTAssertEqual(sender.clears, 0)
        XCTAssertEqual(sender.sent, ["TR: Hold the gate"])
    }

    /// Parlak arka planda okuma yarım saniye kaçsa da TV'deki altyazı silinmez, aynı satır yeniden gönderilmez.
    func testFlickerShorterThanClearTimeNeitherClearsNorResends() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = FakeTranslator()
        let pipeline = SubtitlePipeline(
            reader: FakeReader(lines(("Hold the gate", 3), ("", 15), ("Hold the gate", 3), ("", 10), ("Hold the gate", 3))),
            translator: translator, server: sender, clock: clock.read)
        await run(pipeline, 34, clock: clock)
        XCTAssertEqual(sender.clears, 0)
        XCTAssertEqual(sender.sent, ["TR: Hold the gate"])
        XCTAssertEqual(translator.requested.count, 1)
    }

    func testSubtitleGoneForClearTimeClearsTheTV() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate", 2), ("", 17))),
                                        translator: FakeTranslator(), server: sender, clock: clock.read)
        await run(pipeline, 18, clock: clock)
        XCTAssertEqual(sender.clears, 0)
        await run(pipeline, 1, clock: clock)
        XCTAssertEqual(sender.clears, 1)
    }

    /// Kalkıp 1,5 sn içinde geri gelen satır çevirmene gitmeden eski çevirisiyle yeniden gösterilir.
    func testLineReturningSoonAfterClearIsRestoredWithoutTranslating() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = FakeTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate.", 2), ("", 20), ("Hold the gate.", 2))),
                                        translator: translator, server: sender, clock: clock.read)
        var shown = 0
        pipeline.onPair = { _, _ in shown += 1 }
        await run(pipeline, 24, clock: clock)
        XCTAssertEqual(sender.clears, 1)
        XCTAssertEqual(sender.sent, ["TR: Hold the gate.", "TR: Hold the gate."])
        XCTAssertEqual(sender.durations, [15000, 15000])
        XCTAssertEqual(translator.requested.count, 1)
        XCTAssertEqual(shown, 1)
    }

    /// Daha geç gelen aynı satır gerçek bir tekrardır; yeniden çevrilir.
    func testLineReturningLaterIsTranslatedAgain() async {
        let clock = PipelineClock()
        let translator = FakeTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate.", 2), ("", 50), ("Hold the gate.", 2))),
                                        translator: translator, server: FakeSender(), clock: clock.read)
        await run(pipeline, 54, clock: clock)
        XCTAssertEqual(translator.requested.count, 2)
    }

    /// İki konuşmacı aynı sözlerle konuşuyor; ikisi de çevrilir.
    func testTwoSpeakersWithOverlappingWordsAreBothTranslated() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Where are you going, boy?", 3), ("Where are you going?", 3))),
                                        translator: FakeTranslator(), server: sender, clock: clock.read)
        await run(pipeline, 6, clock: clock)
        XCTAssertEqual(sender.sent, ["TR: Where are you going, boy?", "TR: Where are you going?"])
    }

    /// Bölge değişmiyorsa yazı tanıma çalışmaz; işlemci boşa harcanmaz.
    func testUnchangedRegionIsNotReadAgain() async {
        let reader = FakeReader(Array(repeating: "Hold the gate", count: 8))
        let pipeline = SubtitlePipeline(reader: reader, translator: FakeTranslator(), server: FakeSender(), scheduler: ReadScheduler())
        for _ in 0..<5 { await pipeline.process(frame, region: CropRegion()); await pipeline.waitForTranslations() }
        XCTAssertEqual(reader.readOnMainThread.count, 1)
    }

    func testSignatureNoticesAChangedRegion() throws {
        func image(_ gray: CGFloat) -> CGImage {
            let context = CGContext(data: nil, width: 640, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 120))
            return context.makeImage()!
        }
        XCTAssertEqual(RegionCropper.signature(of: image(0.2)), RegionCropper.signature(of: image(0.2)))
        XCTAssertNotEqual(RegionCropper.signature(of: image(0.2)), RegionCropper.signature(of: image(0.8)))
        XCTAssertEqual(RegionCropper.signature(of: image(0.2)).count, 64 * 12)
    }

    /// Çeviri sürerken okuma durmamalı; yoksa kısa satırlar kaçar.
    func testReadingContinuesWhileTranslating() async {
        let reader = FakeReader(["Hold the gate", "Hold the gate", "Run", "Run"])
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: reader, translator: translator, server: FakeSender())
        // İlk satırın çevirisi kapıda beklerken ikinci satır okunup çeviriye gönderilmiş olmalı.
        for _ in 0..<4 { await pipeline.process(frame, region: CropRegion()) }
        translator.open()
        await pipeline.waitForTranslations()
        XCTAssertEqual(translator.requested, ["Hold the gate", "Run"])
    }

    /// Hızlı konuşmada yeni satır gelse de önceki satırın çevirisi gösterilir; satır kaybolmaz.
    func testEarlierLineIsShownWhenItsTranslationArrivesFirst() async {
        let sender = FakeSender()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate.", "Run!"]), translator: translator, server: sender)
        for _ in 0..<2 { await pipeline.process(frame, region: CropRegion()) }
        await translator.release("Hold the gate.")
        await translator.release("Run!")
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, ["TR: Hold the gate.", "TR: Run!"])
    }

    /// Hızlı konuşmada çeviri sürerken gelen satırlar sırayla çevrilir ve gösterilir; araya giren satır kaybolmaz
    /// (eskiden yalnız en yenisi bekliyordu: üç satırlık konuşmanın ortası hiç çevrilmiyordu).
    func testFastLinesAreAllTranslatedInOrder() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate.", "Run!", "Get down!"]), translator: translator, server: sender,
                                        clock: clock.read)
        await run(pipeline, 3, wait: false, clock: clock)
        await translator.release("Hold the gate.")
        await translator.release("Run!")
        await translator.release("Get down!")
        await pipeline.waitForTranslations()
        XCTAssertEqual(translator.requested, ["Hold the gate.", "Run!", "Get down!"])
        XCTAssertEqual(sender.sent, ["TR: Hold the gate.", "TR: Run!", "TR: Get down!"])
    }

    /// Sıra dolunca en eski bekleyen satır atlanır; kuyruk konuşma hızıyla büyümez.
    func testOldestWaitingLineIsSkippedWhenTheQueueIsFull() async {
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate.", "Run!", "Get down!", "Now!"]), translator: translator,
                                        server: FakeSender(), clock: clock.read)
        await run(pipeline, 4, wait: false, clock: clock)
        await translator.release("Hold the gate.")
        translator.open()
        await pipeline.waitForTranslations()
        XCTAssertEqual(translator.requested, ["Hold the gate.", "Get down!", "Now!"])
    }

    /// Yavaş çeviride (ücretsiz motor) art arda üç satırın çevirisi satırlar kalktıktan iki saniye sonra gelse de
    /// üçü de gösterilir; eskiden yalnız ilki görünüyordu.
    func testSlowTranslationsOfQuickLinesAreStillShown() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate.", "Run!", "Get down!"]), translator: translator, server: sender,
                                        clock: clock.read)
        await run(pipeline, 3, wait: false, clock: clock)
        clock.now += 2000
        await translator.release("Hold the gate.")
        await translator.release("Run!")
        await translator.release("Get down!")
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, ["TR: Hold the gate.", "TR: Run!", "TR: Get down!"])
        XCTAssertEqual(sender.durations, [SubtitlePipeline.readingTime(for: "TR: Hold the gate."),
                                          SubtitlePipeline.readingTime(for: "TR: Run!"), 15000])
    }

    /// Daktilo efekti: yarım okunan cümlenin çevirisi sürerken tamamı gelirse yarımın çevirisi gösterilmez.
    func testGrowingLineSupersedesItsPartialTranslation() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Run to", 2), ("Run to the boat!", 2))),
                                        translator: translator, server: sender, clock: clock.read)
        await run(pipeline, 4, wait: false, clock: clock)
        await translator.release("Run to")
        await translator.release("Run to the boat!")
        await pipeline.waitForTranslations()
        XCTAssertEqual(translator.requested, ["Run to", "Run to the boat!"])
        XCTAssertEqual(sender.sent, ["TR: Run to the boat!"])
    }

    /// Yarım satırın çevirisi gösterildikten sonra tamamı gelirse TV'ye "yerine koy" denir: aynı cümlenin iki çevirisi
    /// üst üste yığılmaz. Başka bir cümle yığılabilir.
    func testRevisedLineReplacesTheShownTranslation() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let pipeline = SubtitlePipeline(
            reader: FakeReader(lines(("Run to", 2), ("Run to the boat!", 2), ("Get down now!", 2))),
            translator: FakeTranslator(), server: sender, clock: clock.read)
        await run(pipeline, 6, clock: clock)
        XCTAssertEqual(sender.sent, ["TR: Run to", "TR: Run to the boat!", "TR: Get down now!"])
        XCTAssertEqual(sender.replaces, [false, true, false])
    }

    /// Yeni satır gelmiş, eskisinin çevirisi bir saniyeden geç gelmişse gösterilmez; yeni satırınki gösterilir.
    func testLateTranslationOfReplacedLineIsDropped() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate.", "Run!"]), translator: translator, server: sender,
                                        clock: clock.read)
        await run(pipeline, 2, wait: false, clock: clock)
        clock.now += SubtitlePipeline.lateResultMs + 100
        await translator.release("Hold the gate.")
        await translator.release("Run!")
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, ["TR: Run!"])
    }

    /// Satır ekrandan kalktıktan sonra çevirisi gelirse yine de okunacak kadar kısa süre gösterilir.
    func testTranslationArrivingAfterLineLeftIsShownBriefly() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate.", 1), ("", 17))), translator: translator, server: sender,
                                        clock: clock.read)
        await run(pipeline, 18, wait: false, clock: clock)
        XCTAssertEqual(sender.clears, 1)
        translator.open()
        await pipeline.waitForTranslations()
        XCTAssertEqual(sender.sent, ["TR: Hold the gate."])
        XCTAssertEqual(sender.durations.first ?? 0, 2000 + "TR: Hold the gate.".count * 60)
    }

    /// Satır bir saniyeden uzun süre önce kalktıysa geç gelen çevirisi sonraki sahnenin üstüne düşmez.
    func testTranslationArrivingLongAfterLineLeftIsDropped() async {
        let sender = FakeSender()
        let clock = PipelineClock()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(lines(("Hold the gate.", 1), ("", 17))), translator: translator, server: sender,
                                        clock: clock.read)
        await run(pipeline, 18, wait: false, clock: clock)
        XCTAssertEqual(sender.clears, 1)
        clock.now += SubtitlePipeline.lateResultMs + 100
        translator.open()
        await pipeline.waitForTranslations()
        XCTAssertTrue(sender.sent.isEmpty)
    }

    /// Çeviri durdurulduysa geç gelen çeviri TV'ye gönderilmez.
    func testTranslationArrivingAfterStopIsDropped() async {
        let sender = FakeSender()
        let translator = GatedTranslator()
        let pipeline = SubtitlePipeline(reader: FakeReader(["Hold the gate", "Hold the gate"]), translator: translator, server: sender)
        for _ in 0..<2 { await pipeline.process(frame, region: CropRegion()) }
        pipeline.reset()
        translator.open()
        await pipeline.waitForTranslations()
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testShortLinesGetAZoomedSecondReading() throws {
        let image = frame
        let stripWidth = Int((Double(image.width) * 0.4).rounded()) * 2
        let text = try VisionReader.firstReading(of: image) { candidate in
            // Yalnız ortası büyütülmüş görüntüde okunabilen kısa satır.
            candidate.width == stripWidth ? "Go!" : ""
        }
        XCTAssertEqual(text, "Go!")
    }

    /// İki yedek okuma da yazı bulursa ortadaki şeridinki (daha güvenilir olanı) seçilir.
    func testCenterStripReadingWinsOverZoomedRegion() throws {
        let image = frame
        let text = try VisionReader.firstReading(of: image) { candidate in
            switch candidate.width {
            case image.width: ""
            case image.width * 2: "G0!"
            default: "Go!"
            }
        }
        XCTAssertEqual(text, "Go!")
    }

    func testFullReadingIsUsedWhenItFindsText() throws {
        let calls = Counter()
        let text = try VisionReader.firstReading(of: frame) { _ in calls.increment(); return "Hold the gate" }
        XCTAssertEqual(text, "Hold the gate")
        XCTAssertEqual(calls.value, 1)
    }

    /// Bölge boşken iki yedek okuma art arda değil aynı anda yapılır; yeni satır daha erken fark edilir.
    func testFallbackReadingsRunAtTheSameTime() throws {
        let image = frame
        let start = Date()
        _ = try VisionReader.firstReading(of: image) { candidate in
            if candidate.width != image.width { Thread.sleep(forTimeInterval: 0.2) }
            return ""
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
    }

    func testVisionReadsSubtitleButNotHud() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "oyun-karesi", withExtension: "png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let text = try VisionReader().read(RegionCropper.crop(image, to: CropRegion(top: 0.6, bottom: 0.99)))
        XCTAssertTrue(text.contains("We do not have time for this, boy"), text)
        XCTAssertFalse(text.contains("24 / 120"), text)
    }
}
