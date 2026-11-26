// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Test sonunda serbest bırakılan, o zamana dek dönmeyen okuma (takılan Vision çağrısı gibi).
private final class Hang: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var waiting = 0
    func wait() {
        lock.withLock { waiting += 1 }
        semaphore.wait()
    }
    func release() {
        let count = lock.withLock { waiting }
        for _ in 0..<count + 64 { semaphore.signal() }
    }
}

/// İlk okuması takılır, sonrakiler yazı döndürür.
private final class FirstHangsReader: TextReader, @unchecked Sendable {
    let hang = Hang()
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    func read(_ image: CGImage) throws -> String {
        let call = lock.withLock { calls += 1; return calls }
        if call == 1 { hang.wait() }
        return "Hello there."
    }
}

/// Bağımsız bağlam yerine geçen sahte yedek: kaç kez bırakıldığını ve kapatıldığını sayar.
private final class FakeRescuer: ReadRescuer, @unchecked Sendable {
    let abandons = Counter(), standDowns = Counter(), reads = Counter(), promotions = Counter()
    private let lock = NSLock()
    private var fullQuality = true
    func recognize(_ image: CGImage, language: String) throws -> Reading {
        reads.add()
        return Reading(text: "yedekten")
    }
    func abandon() { abandons.add() }
    func standDown() { standDowns.add() }
    func preferFullQuality() { promotions.add() }
    var isFullQuality: Bool {
        get { lock.withLock { fullQuality } }
        set { lock.withLock { fullQuality = newValue } }
    }
}

/// İptal edilebilen takılı Vision isteğinin yerine (#1333): ilk istek süreç genelindeki kilidi tutup takılır, ancak
/// iptal edilince (`ReadCancellation`) kilidi bırakıp `CancellationError` ile döner; sonraki istekler kilidi bekler.
private final class WedgedVision: @unchecked Sendable {
    private let condition = NSCondition()
    private var wedged = true
    private var used = false
    private var cancels = 0
    func recognize() throws {
        condition.lock()
        let first = !used
        used = true
        condition.unlock()
        if first {
            guard let cancellation = ReadQueue.currentCancellation else { throw ReadQueueError.stuck }
            try cancellation.run(onCancel: { [self] in
                condition.lock()
                cancels += 1
                condition.unlock()
                free()
            }) { waitWhileWedged() }
            throw CancellationError()
        }
        waitWhileWedged()
    }
    private func waitWhileWedged() {
        condition.lock()
        while wedged { condition.wait() }
        condition.unlock()
    }
    var cancelCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return cancels
    }
    func free() {
        condition.lock()
        wedged = false
        condition.broadcast()
        condition.unlock()
    }
}

/// Süreç genelindeki Vision kilidinin yerine (#1307): kilit tutulurken asıl okuyucudaki her okuma (yeniden kurulan
/// kuyruktaki de) bekler; `free` ile hepsi biter.
private final class VisionLock: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = true
    func pass() {
        condition.lock()
        while held { condition.wait() }
        condition.unlock()
    }
    func free() {
        condition.lock()
        held = false
        condition.broadcast()
        condition.unlock()
    }
}

private final class NullSender: SubtitleSending {
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {}
    func clear() {}
}

private final class EchoTranslator: TextTranslator {
    func translate(_ text: String) async throws -> String { "Çeviri: " + text }
}

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ReadQueue.Event] = []
    func add(_ event: ReadQueue.Event) { lock.withLock { list.append(event) } }
    var all: [ReadQueue.Event] { lock.withLock { list } }
}

/// #507, #679: takılan Vision okuması altyazıyı kalıcı olarak durduruyordu.
final class ReadQueueTests: XCTestCase {
    private func image(_ width: Int = 64, _ height: Int = 64) -> CGImage {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    /// `VisionReader`'ın yerine (testler Vision çalıştırmaz): yedek bağlamdaysa yedekten okur, değilse "asıl" döner.
    private static func rescuedOrPrimary() throws -> Reading {
        guard let rescuer = ReadQueue.activeRescuer else { return Reading(text: "asıl") }
        let image = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        return try rescuer.recognize(image, language: "en")
    }

    /// Biten okumanın karesi hemen bırakılır; süre zamanlayıcıları onu `timeoutMs` boyunca tutmaz (GitHub #822). Mac'te
    /// pencere yakalamanın karesi okuma sırasındaki görüntüye bağlıdır; her okuma karesini 10 sn tutunca ScreenCaptureKit'in
    /// üç karelik havuzu doluyor, yeni kare gelmiyor, altyazı ~10,6 sn arayla okunuyordu.
    func testFinishedReadReleasesItsFrameBeforeTimeout() async throws {
        let queue = ReadQueue(label: "test.release", timeoutMs: 60_000, subtitleTimeoutMs: 30_000)
        queue.rescuer = FakeRescuer()
        final class Frame: @unchecked Sendable {}
        weak var subtitleFrame: Frame?
        weak var backgroundFrame: Frame?
        do {
            let frame = Frame()
            subtitleFrame = frame
            _ = try await queue.run(priority: .subtitle) { _ = frame; return 1 }
        }
        do {
            let frame = Frame()
            backgroundFrame = frame
            _ = try await queue.run(priority: .background) { _ = frame; return 2 }
        }
        for _ in 0..<100 where subtitleFrame != nil || backgroundFrame != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(subtitleFrame, "altyazı okumasının karesi okuma bitince bırakılmalı")
        XCTAssertNil(backgroundFrame, "arka plan okumasının karesi okuma bitince bırakılmalı")
    }

    /// Yedek yokken: takılan okumanın yanına yenisi verilmez (Vision'da o da aynı kilidi bekler); okuma hemen `stuck`
    /// döner, takılan bitince okuyucu kendiliğinden düzelir.
    func testStalledReaderWithoutRescueFailsFastAndRecovers() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.timeout", timeoutMs: 150)
        let events = Events()
        queue.onEvent = { events.add($0) }
        let ran = Counter()

        do {
            _ = try await queue.run(detail: "altyazı 64x64") { hang.wait(); return 1 }
            XCTFail("takılan okuma dönmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .timedOut(ms: 150))
        }
        XCTAssertNotNil(queue.stalledMs)
        XCTAssertFalse(queue.isRescuing)
        XCTAssertEqual(queue.backgroundSlowdown, 4)
        do {
            _ = try await queue.run { ran.add(); return 2 }
            XCTFail("takılıyken okuma verilmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .stuck)
        }
        XCTAssertEqual(ran.value, 0, "takılan okumanın yanına ikinci okuma verilmemeli")
        guard case .stalled(let stall, rescued: false)? = events.all.first else { return XCTFail("takılma bildirilmedi") }
        XCTAssertEqual(stall.detail, "altyazı 64x64")
        XCTAssertGreaterThanOrEqual(stall.ms, 140)
        XCTAssertEqual(stall.running, 1)
        XCTAssertTrue(stall.logText.contains("ısı: "))

        hang.release()
        var value: Int?
        for _ in 0..<100 where value == nil {
            value = try? await queue.run { 3 }
            if value == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(value, 3)
        XCTAssertNil(queue.stalledMs)
        XCTAssertTrue(events.all.contains { if case .recovered = $0 { return true } else { return false } })
    }

    /// Asla dönmeyen okuma + yedek: okumalar bağımsız bağlamda sürer; asıl okuyucu düzelince ona dönülür.
    func testNeverReturningReadIsRescuedInIndependentContext() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.rescue", timeoutMs: 500)
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }

        _ = try? await queue.run { hang.wait(); return Reading.empty }
        XCTAssertTrue(queue.isRescuing)
        // Sonraki okumalar yedek bağlamda çalışır: `VisionReader` oradayken okumayı yedeğe verir.
        for _ in 0..<5 {
            let reading = try await queue.run { () throws -> Reading in
                guard let active = ReadQueue.activeRescuer else { return Reading(text: "asıl") }
                return try active.recognize(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!, language: "en")
            }
            XCTAssertEqual(reading.text, "yedekten")
        }
        XCTAssertEqual(rescuer.reads.value, 5)
        guard case .stalled(_, rescued: true)? = events.all.first else { return XCTFail("yedeğe geçiş bildirilmedi") }

        hang.release()
        var text = ""
        for _ in 0..<100 where text != "asıl" {
            text = (try? await queue.run { ReadQueue.activeRescuer == nil ? "asıl" : "yedek" }) ?? ""
            if text != "asıl" { try await Task.sleep(for: .milliseconds(20)) }
        }
        XCTAssertEqual(text, "asıl")
        XCTAssertEqual(rescuer.standDowns.value, 1)
        XCTAssertFalse(queue.isRescuing)
    }

    /// Yedek de takılırsa bağlamı bırakılır, yenisinde okunur; art arda sınır kadar takılırsa okuma `stuck` döner.
    func testHungRescueIsAbandonedAndRebuiltThenGivesUp() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.rescue.hang", timeoutMs: 500, maxRescueFailures: 2)
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }

        _ = try? await queue.run { hang.wait() }
        // Yedekteki ilk okuma da takılır: bağlam bırakılır.
        do {
            _ = try await queue.run { hang.wait() }
            XCTFail("yedekte takılan okuma dönmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .timedOut(ms: 500))
        }
        XCTAssertEqual(rescuer.abandons.value, 1)
        // Yeni yedek bağlam çalışır.
        let value = try await queue.run { 7 }
        XCTAssertEqual(value, 7)
        // Art arda iki kez takılınca yedek bırakılır.
        _ = try? await queue.run { hang.wait() }
        _ = try? await queue.run { hang.wait() }
        XCTAssertEqual(rescuer.abandons.value, 3)
        do {
            _ = try await queue.run { 1 }
            XCTFail("yedek tükenince okuma verilmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .stuck)
        }
        XCTAssertTrue(events.all.contains { if case .rescueFailed(_, failures: 2) = $0 { return true } else { return false } })
    }

    /// Takılma yinelenirse okuma yolu değişir: hızlı düzey (Neural Engine'siz) bir süre (`fastLevelHoldMs`) kullanılır.
    func testRepeatedStallsSwitchToFastLevel() async throws {
        XCTAssertFalse(VisionReader.useFastLevel)
        defer { VisionReader.useFastLevel = false }
        let queue = ReadQueue(label: "test.degrade", timeoutMs: 100, degradeAfterStalls: 2)
        let events = Events()
        queue.onEvent = { events.add($0) }
        for round in 1...2 {
            let hang = DispatchSemaphore(value: 0)
            _ = try? await queue.run { hang.wait() }
            XCTAssertEqual(VisionReader.useFastLevel, false, "takılıyken yol değişmez (tur \(round))")
            hang.signal()
            for _ in 0..<100 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertTrue(VisionReader.useFastLevel)
        XCTAssertTrue(events.all.contains(.degraded(stalls: 2)))
    }

    func testStuckReadsDoNotStarveSwiftPool() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.pool", timeoutMs: 100)
        // Çekirdek sayısının üç katı takılan okuma: eskiden her biri havuzdan bir thread tutardı.
        let count = ProcessInfo.processInfo.activeProcessorCount * 3
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask { _ = try? await queue.run { hang.wait() } }
            }
        }
        // Havuz serbest: başka bir iş (AppModel.start'taki await'ler gibi) hemen devam eder.
        let pool = expectation(description: "Swift havuzu cevap veriyor")
        Task.detached { _ = await Task.detached { 42 }.value; pool.fulfill() }
        await fulfillment(of: [pool], timeout: 5)
    }

    /// Altyazı okuması, sırada bekleyen arka plan okumalarının (ek alan, ekran yazısı) önüne geçer.
    func testSubtitleReadsGoBeforeWaitingBackgroundReads() async throws {
        let queue = ReadQueue(label: "test.priority", timeoutMs: 5000)
        let order = Order()
        let gate = DispatchSemaphore(value: 0)
        async let first: Void = try queue.run(priority: .background) { gate.wait(); order.add("ilk") }
        try await Task.sleep(for: .milliseconds(50))
        async let b1: Void = try queue.run(priority: .background) { order.add("ek alan 1") }
        try await Task.sleep(for: .milliseconds(20))
        async let b2: Void = try queue.run(priority: .background) { order.add("ek alan 2") }
        try await Task.sleep(for: .milliseconds(20))
        async let subtitle: Void = try queue.run(priority: .subtitle) { Thread.sleep(forTimeInterval: 0.01); order.add("altyazı") }
        try await Task.sleep(for: .milliseconds(Self.waitMs))
        gate.signal()
        _ = try await (first, b1, b2, subtitle)
        XCTAssertEqual(order.all, ["ilk", "altyazı", "ek alan 1", "ek alan 2"])
        // Altyazı okuması sırada bekledi: arka plan okumaları kendini kısar.
        XCTAssertGreaterThan(queue.backgroundSlowdown, 1)
        // Beklemeyen bir altyazı okumasından sonra kısma kalkar.
        try await queue.run(priority: .subtitle) {}
        XCTAssertEqual(queue.backgroundSlowdown, 1)
    }

    private static let waitMs = ReadQueue.subtitleWaitLimitMs + 100

    /// Yavaş okumanın arkasında sırada beklemek takılma sayılmaz (süre, okuma başlayınca işler).
    func testWaitingBehindSlowReadIsNotAStall() async throws {
        let queue = ReadQueue(label: "test.wait", timeoutMs: 5000)
        let gate = DispatchSemaphore(value: 0)
        let ran = Counter()
        async let first: Int = try queue.run { gate.wait(); return 1 }
        try await Task.sleep(for: .milliseconds(120))
        async let second: Int = try queue.run { ran.add(); return 2 }
        try await Task.sleep(for: .milliseconds(50))
        gate.signal()
        let one = try await first
        let two = try await second
        XCTAssertEqual(one, 1)
        XCTAssertEqual(two, 2)
        XCTAssertNil(queue.stalledMs)
    }

    func testFallbackReadsRunOneAtATime() throws {
        let tracker = Concurrency()
        let reading = try VisionReader.firstLines(of: image(200, 50)) { _ in
            tracker.enter()
            Thread.sleep(forTimeInterval: 0.05)
            tracker.leave()
            return .empty
        }
        XCTAssertTrue(reading.lines.isEmpty)
        XCTAssertEqual(tracker.calls, 3)
        XCTAssertEqual(tracker.maxAtOnce, 1)
    }

    /// Takılan okumadan sonra hat okumayı sürdürür: yedek bağlamda (Mac) hemen, asıl okuyucu düzelince yeniden asılda.
    @MainActor
    func testPipelineKeepsReadingAfterHungRead() async {
        let reader = FirstHangsReader()
        defer { reader.hang.release() }
        let queue = ReadQueue(label: "test.pipeline", timeoutMs: 500)
        queue.rescuer = FakeRescuer()
        let pipeline = SubtitlePipeline(reader: reader, translator: EchoTranslator(), server: NullSender(), readQueue: queue)
        var results: [Error?] = []
        pipeline.onReadResult = { results.append($0) }

        await pipeline.process(image(), region: CropRegion())
        await pipeline.process(image(), region: CropRegion())
        await pipeline.process(image(), region: CropRegion())

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first.flatMap { $0 as? ReadQueueError }, .timedOut(ms: 500))
        XCTAssertNil(results.last ?? nil)
        XCTAssertEqual(reader.callCount, 3)
    }

    /// Yedek yokken (iPhone) takılan okuma hattı kilitlemez: kareler beklemeden `stuck` alır.
    @MainActor
    func testPipelineWithoutRescueReportsStuck() async {
        let reader = FirstHangsReader()
        defer { reader.hang.release() }
        let pipeline = SubtitlePipeline(reader: reader, translator: EchoTranslator(), server: NullSender(),
                                        readQueue: ReadQueue(label: "test.pipeline.norescue", timeoutMs: 150))
        var results: [Error?] = []
        pipeline.onReadResult = { results.append($0) }
        await pipeline.process(image(), region: CropRegion())
        await pipeline.process(image(), region: CropRegion())
        XCTAssertEqual(results.last.flatMap { $0 as? ReadQueueError }, .stuck)
        XCTAssertEqual(reader.callCount, 1)
    }

    /// GitHub #822: altyazı okuması yavaşlayınca (Mac, Remote Play penceresi) her takılmada 10 sn hiç satır okunmuyordu;
    /// kullanıcının geçmişinde çeviriler 8–11 sn arayla geliyordu. Yedek varken altyazı okuması `subtitleTimeoutMs`'te
    /// takılı sayılır, sonraki altyazı hemen yedekten okunur.
    func testSlowSubtitleReadMovesToRescueEarly() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.subtitle.early", timeoutMs: 5000, subtitleTimeoutMs: 150)
        queue.rescuer = FakeRescuer()
        let started = Date()
        do {
            _ = try await queue.run(priority: .subtitle) { hang.wait() }
            XCTFail("takılan okuma dönmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .timedOut(ms: 150))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "altyazı 5 sn'lik genel sınırı beklememeli")
        XCTAssertTrue(queue.isRescuing)
        let reading = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(reading.text, "yedekten")
    }

    /// Altyazı, asıl okuyucuda uzun süren bir arka plan okumasının (ek alan, "Ekranı çevir") arkasında genel sınır kadar
    /// beklemez: yedek varsa `subtitleTimeoutMs` sonra yedekten okunur.
    func testSubtitleDoesNotWaitBehindLongBackgroundRead() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.subtitle.behind", timeoutMs: 5000, subtitleTimeoutMs: 150)
        queue.rescuer = FakeRescuer()
        let background = Task { try? await queue.run(priority: .background) { hang.wait() } }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        let reading = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(reading.text, "yedekten")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        hang.release()
        _ = await background.value
    }

    // MARK: - #1210: Mac'te 15-20 dakikada bir "yazı okuma yanıt vermiyor" uyarısı, ardından bozuk çeviri

    /// 1. Altyazıyı bekleten arka plan okuması (telefon, ek alan, ekran yazısı) takılma sayılmaz: uyarı çıkmaz (asıl
    /// okuyucu takılı değil, `isRescuing` yanlış), sıradaki arka plan okumaları düşürülür, altyazı yalnız o tur yedekten
    /// okunur. Arka plan okuması sürerken gelen altyazı beklemeden yedeğe gider; arka plan okuması bitince sonucunu alır,
    /// yedek kapatılır ve altyazı yeniden asıl okuyucudan okunur.
    func testBackgroundReadBlockingSubtitleIsNotAStall() async throws {
        let gate = Hang()
        defer { gate.release() }
        let queue = ReadQueue(label: "test.yield", timeoutMs: 5000, subtitleTimeoutMs: 1000)
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }

        let background = Task { try await queue.run(priority: .background, detail: "telefon 64x64") { gate.wait(); return "telefon" } }
        try await Task.sleep(for: .milliseconds(30))
        let region = Task { try await queue.run(priority: .background, detail: "ek alan 64x64") { "ek alan" } }
        let request = Task { try await queue.run(priority: .background, detail: "ekranı çevir 64x64", droppable: false) { "ekranı çevir" } }
        try await Task.sleep(for: .milliseconds(30))

        let first = try await queue.run(priority: .subtitle, detail: "altyazı 64x64") { try Self.rescuedOrPrimary() }
        XCTAssertEqual(first.text, "yedekten", "altyazı bu tur yedekten okunur")
        XCTAssertFalse(queue.isRescuing, "asıl okuyucu takılı sayılmaz: uyarı çıkmaz")
        XCTAssertNil(queue.stalledMs)
        XCTAssertGreaterThan(queue.backgroundSlowdown, 1, "arka plan turları kısılır")
        do {
            _ = try await region.value
            XCTFail("sıradaki dönemsel arka plan okuması düşürülmeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .timedOut(ms: 5000))
        }

        // Arka plan okuması sürerken gelen altyazı sınırı beklemeden yedeğe gider.
        let started = Date()
        let second = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(second.text, "yedekten")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "sınırı (1 sn) beklemez")

        XCTAssertFalse(events.all.contains { if case .stalled = $0 { return true } else { return false } }, "takılma bildirilmez")
        let yields = events.all.filter { if case .backgroundYielded(_, dropped: 1, rescued: true) = $0 { return true } else { return false } }
        XCTAssertEqual(yields.count, 1, "yanından geçiş bir kez günlüğe yazılır")

        gate.release()
        let backgroundValue = try await background.value
        XCTAssertEqual(backgroundValue, "telefon", "süren arka plan okuması sonucunu teslim eder")
        let requestValue = try await request.value
        XCTAssertEqual(requestValue, "ekranı çevir", "kullanıcının istediği okuma düşürülmez")
        var text = ""
        for _ in 0..<100 where text != "asıl" {
            text = (try? await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() })?.text ?? ""
            if text != "asıl" { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(text, "asıl", "arka plan okuması bitince altyazı asıl okuyucudan okunur")
        XCTAssertEqual(rescuer.standDowns.value, 1, "o tur için açılan yedek kapatılır")
        XCTAssertFalse(VisionReader.useFastLevel)
    }

    /// 1 (iPhone, yedek yok): altyazıyı bekleten arka plan okuması yine takılma sayılmaz; sıradaki arka plan okumaları
    /// düşürülür, altyazı sırada öne geçer ve arka plan okuması biter bitmez asıl okuyucudan okunur.
    func testBackgroundReadBlockingSubtitleWithoutRescueDropsBackgroundReads() async throws {
        let gate = Hang()
        defer { gate.release() }
        let queue = ReadQueue(label: "test.yield.norescue", timeoutMs: 5000, subtitleTimeoutMs: 100)
        let events = Events()
        queue.onEvent = { events.add($0) }
        let order = Order()

        let background = Task { try await queue.run(priority: .background) { gate.wait(); order.add("telefon") } }
        try await Task.sleep(for: .milliseconds(30))
        let region = Task { try await queue.run(priority: .background) { order.add("ek alan") } }
        try await Task.sleep(for: .milliseconds(20))
        let subtitle = Task { try await queue.run(priority: .subtitle) { order.add("altyazı") } }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(queue.stalledMs, "takılma sayılmaz")
        XCTAssertTrue(events.all.contains { if case .backgroundYielded(_, dropped: 1, rescued: false) = $0 { return true } else { return false } })
        gate.release()
        try await background.value
        try await subtitle.value
        do {
            try await region.value
            XCTFail("ek alan okuması düşürülmeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .timedOut(ms: 5000))
        }
        XCTAssertEqual(order.all, ["telefon", "altyazı"])
        XCTAssertFalse(events.all.contains { if case .stalled = $0 { return true } else { return false } })
    }

    /// 1: arka plan okuması genel süre sınırında da bitmezse o zaman gerçek takılmadır (bildirilir, yedeğe geçilir).
    func testBackgroundReadThatNeverReturnsIsStillAStall() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.yield.hang", timeoutMs: 400, subtitleTimeoutMs: 80)
        queue.rescuer = FakeRescuer()
        let events = Events()
        queue.onEvent = { events.add($0) }
        let background = Task { try? await queue.run(priority: .background) { hang.wait() } }
        try await Task.sleep(for: .milliseconds(20))
        _ = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertFalse(queue.isRescuing)
        for _ in 0..<100 where queue.stalledMs == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(queue.stalledMs)
        XCTAssertTrue(queue.isRescuing)
        XCTAssertTrue(events.all.contains { if case .stalled(_, rescued: true) = $0 { return true } else { return false } })
        hang.release()
        _ = await background.value
    }

    /// 2. Hızlı düzey kalıcı değildir: süresi dolunca okumalar yeniden isabetli düzeyde verilir ve günlüğe yazılır.
    /// Eskiden oturum boyunca kalıyordu; çeviriler bozuk geliyor, ancak uygulamayı yeniden açmak düzeltiyordu.
    func testFastLevelIsRestoredAfterHold() async throws {
        XCTAssertFalse(VisionReader.useFastLevel)
        defer { VisionReader.useFastLevel = false }
        let queue = ReadQueue(label: "test.restore", timeoutMs: 100, degradeAfterStalls: 1, fastLevelHoldMs: 300)
        let events = Events()
        queue.onEvent = { events.add($0) }
        let hang = DispatchSemaphore(value: 0)
        _ = try? await queue.run { hang.wait() }
        hang.signal()
        for _ in 0..<100 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(VisionReader.useFastLevel)
        XCTAssertTrue(events.all.contains(.degraded(stalls: 1)))

        _ = try await queue.run { 1 }
        XCTAssertTrue(VisionReader.useFastLevel, "süre dolmadan isabetli düzeye dönülmez")
        try await Task.sleep(for: .milliseconds(350))
        _ = try await queue.run { 2 }
        XCTAssertFalse(VisionReader.useFastLevel, "süre dolunca isabetli düzeye dönülür")
        XCTAssertTrue(events.all.contains { if case .restored(let ms) = $0 { return ms >= 300 } else { return false } })

        // Yeniden takılırsa bir takılmada yine hızlı düzeye geçilir.
        let again = DispatchSemaphore(value: 0)
        _ = try? await queue.run { again.wait() }
        again.signal()
        for _ in 0..<100 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(VisionReader.useFastLevel)
    }

    /// 2 (iPhone): takılan okuma bırakılınca geçilen hızlı düzey de süreli; bırakılan okuma bitmeden (Vision'ı hâlâ
    /// tutuyor olabilir) isabetli düzeye dönülmez.
    func testAbandonFastLevelIsRestoredAfterAbandonedReadFinishes() async throws {
        defer { VisionReader.useFastLevel = false }
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.restore.abandon", timeoutMs: 50, fastLevelHoldMs: 100)
        let events = Events()
        queue.onEvent = { events.add($0) }
        _ = try? await queue.run { hang.wait() }
        XCTAssertNotNil(queue.abandonStall(olderThanMs: 0))
        XCTAssertTrue(VisionReader.useFastLevel)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await queue.run { 1 }
        XCTAssertTrue(VisionReader.useFastLevel, "bırakılan okuma bitmeden dönülmez")
        hang.release()
        for _ in 0..<100 where !events.all.contains(where: { if case .abandonedFinished = $0 { return true } else { return false } }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await queue.run { 2 }
        XCTAssertFalse(VisionReader.useFastLevel)
        XCTAssertTrue(events.all.contains { if case .restored = $0 { return true } else { return false } })
    }

    /// 3. Yedekten asıl okuyucuya dönüş kendiliğindendir: takılan altyazı okuması bitince yedek kapatılır, uyarının
    /// dayandığı durum (`isRescuing`, `stalledMs`) kalkar, `recovered` bildirilir ve sonraki okuma asıl okuyucudadır.
    func testRescueEndsAndWarningClearsWhenPrimaryRecovers() async throws {
        let queue = ReadQueue(label: "test.recover", timeoutMs: 5000, subtitleTimeoutMs: 80)
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }
        let gate = DispatchSemaphore(value: 0)
        _ = try? await queue.run(priority: .subtitle) { gate.wait() }
        XCTAssertTrue(queue.isRescuing)
        let rescued = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(rescued.text, "yedekten")
        gate.signal()
        for _ in 0..<100 where queue.isRescuing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.isRescuing)
        XCTAssertNil(queue.stalledMs)
        XCTAssertEqual(rescuer.standDowns.value, 1)
        XCTAssertTrue(events.all.contains { if case .recovered = $0 { return true } else { return false } })
        let primary = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(primary.text, "asıl")
    }

    /// 4. Altyazının kendi okuma sınırı cihazın son okumalarına uyar: ortanca × 3, en az `subtitleTimeoutMs`, en çok
    /// `subtitleTimeoutCapMs`. Isınıp yavaşlayan Mac'te her okuma eski sabit sınırı aşınca yanlış alarm çıkıyordu.
    func testSubtitleLimitAdaptsToRecentReadTimes() async throws {
        let queue = ReadQueue(label: "test.adaptive", timeoutMs: 5000, subtitleTimeoutMs: 100, subtitleTimeoutCapMs: 2000)
        let events = Events()
        queue.onEvent = { events.add($0) }
        XCTAssertEqual(queue.currentSubtitleTimeoutMs, 100, "yeterli okuma yokken taban sınır")
        // Hızlı okumalar sınırı tabanın altına indirmez.
        for _ in 0..<ReadQueue.subtitleMinSamples { _ = try await queue.run(priority: .subtitle) { 1 } }
        XCTAssertEqual(queue.currentSubtitleTimeoutMs, 100)
        // Cihaz yavaşladı: okumalar ~200 ms. Sınır ortanca × 3'e uzar. (Okumalar yedeksiz verilir: yavaş CI makinesinde
        // erken sınıra takılmasınlar; süreleri yine de sayılır.)
        for _ in 0..<ReadQueue.subtitleSampleCount { _ = try await queue.run(priority: .subtitle) { Thread.sleep(forTimeInterval: 0.2) } }
        let limit = queue.currentSubtitleTimeoutMs
        XCTAssertGreaterThanOrEqual(limit, 600)
        XCTAssertLessThanOrEqual(limit, 2000)
        // Yedek varken: eski sınırı (100 ms) çok aşan ama cihazın tipik süresine uyan okuma takılma sayılmaz.
        queue.rescuer = FakeRescuer()
        let value = try await queue.run(priority: .subtitle) { Thread.sleep(forTimeInterval: 0.3); return 7 }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(queue.isRescuing)
        XCTAssertFalse(events.all.contains { if case .stalled = $0 { return true } else { return false } })
    }

    /// 4: uyarlanan sınırın üst ucu (`subtitleTimeoutCapMs`, uygulamada 10 sn).
    func testAdaptiveSubtitleLimitIsCapped() async throws {
        let queue = ReadQueue(label: "test.adaptive.cap", timeoutMs: 5000, subtitleTimeoutMs: 50, subtitleTimeoutCapMs: 200)
        for _ in 0..<ReadQueue.subtitleMinSamples { _ = try await queue.run(priority: .subtitle) { Thread.sleep(forTimeInterval: 0.1) } }
        XCTAssertEqual(queue.currentSubtitleTimeoutMs, 200)
    }

    /// Yedek yokken (iPhone) altyazı için erken sınır uygulanmaz: beklemenin yerine geçecek okuyucu yok.
    func testSubtitleLimitNeedsRescue() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.subtitle.norescue", timeoutMs: 400, subtitleTimeoutMs: 100)
        do {
            _ = try await queue.run(priority: .subtitle) { hang.wait() }
            XCTFail("takılan okuma dönmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .timedOut(ms: 400))
        }
    }

    /// Altyazıyı bekletmemek için erken takılı sayılıp genel sınırdan önce biten okuma hızlı düzeye geçirmez (o yol
    /// yalnız gerçekten dönmeyen okumalar için).
    func testEarlyStallDoesNotDegrade() async throws {
        XCTAssertFalse(VisionReader.useFastLevel)
        defer { VisionReader.useFastLevel = false }
        let queue = ReadQueue(label: "test.subtitle.degrade", timeoutMs: 2000, degradeAfterStalls: 1, subtitleTimeoutMs: 100)
        queue.rescuer = FakeRescuer()
        let events = Events()
        queue.onEvent = { events.add($0) }
        _ = try? await queue.run(priority: .subtitle) { Thread.sleep(forTimeInterval: 0.3); return 1 }
        for _ in 0..<100 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(queue.stalledMs)
        XCTAssertTrue(events.all.contains { if case .recovered = $0 { return true } else { return false } })
        XCTAssertFalse(events.all.contains(.degraded(stalls: 1)))
        XCTAssertFalse(VisionReader.useFastLevel)
    }

    /// Erken sınır (`subtitleTimeoutMs`) Vision isteklerini biriktirmez: takılı sayılan okuma iptal edilemez ama o bitene
    /// kadar asıl okuyucuya ikinci istek verilmez; art arda gelen altyazı okumalarının hepsi yedeğe gider, takılma bir kez
    /// günlüğe yazılır. (Mac, beta.80: altyazı gelmezken süreçte birden çok Vision iş parçacığı görülünce şüphelenildi.)
    func testEarlySubtitleLimitNeverStacksPrimaryReads() async throws {
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.subtitle.nostack", timeoutMs: 5000, subtitleTimeoutMs: 80)
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }
        let primary = Concurrency()
        for _ in 0..<12 {
            _ = try? await queue.run(priority: .subtitle, detail: "altyazı 64x64") { () -> Reading in
                // Yedek bağlamda değilse asıl okuyucudadır (Vision'ın yerinde): girer ve takılır.
                guard ReadQueue.activeRescuer == nil else { return try Self.rescuedOrPrimary() }
                primary.enter()
                defer { primary.leave() }
                hang.wait()
                return .empty
            }
            _ = try? await queue.run(priority: .background, detail: "ek alan 64x64") { () -> Reading in
                guard ReadQueue.activeRescuer == nil else { return try Self.rescuedOrPrimary() }
                primary.enter()
                defer { primary.leave() }
                hang.wait()
                return .empty
            }
        }
        XCTAssertEqual(primary.maxAtOnce, 1, "asıl okuyucuda aynı anda tek okuma")
        XCTAssertEqual(primary.calls, 1, "takılan okuma bitmeden asıl okuyucuya yeni okuma verilmez")
        XCTAssertEqual(rescuer.reads.value, 23, "öbür okumaların hepsi yedekten")
        let stalls = events.all.filter { if case .stalled(_, rescued: true) = $0 { return true } else { return false } }
        XCTAssertEqual(stalls.count, 1, "takılma günlüğe bir kez yazılır")
        hang.release()
        for _ in 0..<200 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(queue.stalledMs, "takılan okuma bitince asıl okuyucuya dönülür")
        XCTAssertEqual(rescuer.standDowns.value, 1)
    }

    private static func count(_ events: Events, _ match: (ReadQueue.Event) -> Bool) -> Int { events.all.filter(match).count }
    private static func isAbandoned(_ event: ReadQueue.Event) -> Bool { if case .abandoned = event { true } else { false } }
    private static func isRebuilt(_ event: ReadQueue.Event) -> Bool { if case .recoveredAfterRebuild = event { true } else { false } }

    /// #1247 (Mac, beta.95): takılan Vision isteği hiç dönmüyordu; okumalar oturum boyunca yedekte kaldı, "macOS'in yazı
    /// okuması yanıt vermiyor" uyarısı 839 sn kalkmadı. Artık takılan okuma süre dolunca kendiliğinden bırakılır, okuyucu
    /// yeniden kurulur; yeni okuyucu sınanırken altyazı yedekten sürer, art arda okumaları süresinde bitirince yedek
    /// kapatılır, uyarının dayandığı durum (`isRescuing`) kalkar.
    func testNeverReturningReadIsAbandonedAndRebuiltReaderRecovers() async throws {
        defer { VisionReader.useFastLevel = false }
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.rebuild", timeoutMs: 5000, subtitleTimeoutMs: 80,
                              abandonStallAfterMs: 300, recoverAfterReads: 3)
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }

        // Hiç dönmeyen istek (test sonuna dek).
        _ = try? await queue.run(priority: .subtitle) { hang.wait() }
        XCTAssertTrue(queue.isRescuing)
        let rescued = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(rescued.text, "yedekten")

        for _ in 0..<200 where Self.count(events, Self.isAbandoned) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        guard case .abandoned(let ms, rescued: true, cancelled: false)? = events.all.first(where: Self.isAbandoned) else {
            return XCTFail("takılan okuma bırakılmadı")
        }
        XCTAssertGreaterThanOrEqual(ms, 300)
        XCTAssertNil(queue.stalledMs)
        XCTAssertTrue(queue.isRescuing, "yeni okuyucu sınanırken uyarı sürer, altyazı yedekten gelir")

        // Yeni okuyucu okumaları süresinde bitirir: yedekten çıkılır.
        for _ in 0..<100 where Self.count(events, Self.isRebuilt) == 0 {
            _ = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(events.all.last(where: Self.isRebuilt), .recoveredAfterRebuild(reads: 3))
        XCTAssertFalse(queue.isRescuing, "uyarı kalkar")
        XCTAssertEqual(rescuer.standDowns.value, 1)
        let primary = try await queue.run(priority: .subtitle) { try Self.rescuedOrPrimary() }
        XCTAssertEqual(primary.text, "asıl")
    }

    private static func isParked(_ event: ReadQueue.Event) -> Bool { if case .parked = event { true } else { false } }
    private static func isRecovered(_ event: ReadQueue.Event) -> Bool { if case .recovered = event { true } else { false } }

    /// #1307 (Mac, beta.99): ekran yazıyla dolunca Vision takıldı; okuyucu 3 kez yeniden kuruldu, her yeni okuyucu 3 sn
    /// içinde yine takıldı (kilit bırakılan okumada, süreç geneli); sınır dolunca 5 sn'de bir boşuna denendi, bir saatten
    /// uzun ana okuyucuya dönülmedi, uyarı ekranda kaldı. Artık yeniden kurulan okuyucu tek okuma bitiremeden takılınca
    /// asıl okuyucu kilitli sayılır: yeniden kurma durur, okumalar yedekte sürer; yedek isabetliyse uyarı gösterilmez;
    /// kilit serbest kalınca asıl okuyucuya dönülür.
    func testLockWideHangParksOnRescueAndReturnsWhenLockFrees() async throws {
        defer { VisionReader.useFastLevel = false }
        let vision = VisionLock()
        defer { vision.free() }
        let queue = ReadQueue(label: "test.parked", timeoutMs: 5000, subtitleTimeoutMs: 80,
                              abandonStallAfterMs: 200, recoverAfterReads: 3)
        let rescuer = FakeRescuer()
        rescuer.isFullQuality = false
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }
        let read: @Sendable () throws -> Reading = {
            if ReadQueue.activeRescuer == nil { vision.pass() }
            return try Self.rescuedOrPrimary()
        }

        _ = try? await queue.run(priority: .subtitle, read)
        XCTAssertTrue(queue.showsRescueNotice)
        for _ in 0..<200 where Self.count(events, Self.isAbandoned) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Self.count(events, Self.isAbandoned), 1)

        // Yeni okuyucu da kilidi bekler: okuma yedekten teslim edilir, sınamadaki kopya takılır, asıl okuyucu kilitli.
        for _ in 0..<200 where !queue.isPrimaryParked {
            let reading = try await queue.run(priority: .subtitle, read)
            XCTAssertEqual(reading.text, "yedekten")
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(queue.isPrimaryParked)
        for _ in 0..<100 where Self.count(events, Self.isParked) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(events.all.first(where: Self.isParked), .parked(stillStuck: 1, rescued: true))
        XCTAssertEqual(rescuer.promotions.value, 1, "kilitliyken yedekten hemen isabetli düzey istenir (#1333)")

        // Boşuna yeniden kurma yok: bırakma süresinin kat kat fazlası boyunca okumalar yedekte sürer, bırakma denenmez.
        let checks = queue.abandonCheckCount
        for _ in 0..<20 {
            let reading = try await queue.run(priority: .subtitle, read)
            XCTAssertEqual(reading.text, "yedekten")
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Self.count(events, Self.isAbandoned), 1, "kilitliyken okuyucu yeniden kurulmaz")
        XCTAssertEqual(queue.abandonCheckCount, checks, "kilitliyken aralıklı bırakma denemesi yok")
        XCTAssertEqual(Self.count(events, Self.isParked), 1)

        // Uyarı gerçek duruma uyar: yedek hızlı düzeyde okurken uyarı var; isabetli okuyorsa kalıcı okuyucudur, uyarı yok.
        XCTAssertTrue(queue.showsRescueNotice)
        rescuer.isFullQuality = true
        XCTAssertFalse(queue.showsRescueNotice)
        XCTAssertTrue(queue.isRescuing)

        // Kilit serbest: bırakılan okuma ve takılı kopya biter; asıl okuyucuya dönülür, yedek kapatılır.
        vision.free()
        for _ in 0..<200 where queue.isRescuing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.isRescuing)
        XCTAssertFalse(queue.isPrimaryParked)
        XCTAssertNil(queue.stalledMs)
        // Olaylar durum değiştikten sonra yazılır; iki okuma (bırakılan ve takılı kopya) aynı anda biter.
        for _ in 0..<100 where !events.all.contains(.abandonedFinished(stillStuck: 0)) || Self.count(events, Self.isRecovered) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(events.all.contains(.abandonedFinished(stillStuck: 0)))
        XCTAssertTrue(events.all.contains(where: Self.isRecovered))
        XCTAssertGreaterThanOrEqual(rescuer.standDowns.value, 1)
        let primary = try await queue.run(priority: .subtitle, read)
        XCTAssertEqual(primary.text, "asıl")
    }

    /// #1307, iPhone (yedek yok): yeniden kurulan okuyucu da kilidi bekliyorsa yeniden kurma durur (her biri bir takılı iş
    /// parçacığı bırakıyordu); elle "Durdur / Başlat" da boşuna bırakmaz. Kilit serbest kalınca okuma kendiliğinden sürer.
    func testLockWideHangWithoutRescueStopsRebuildingAndRecovers() async throws {
        defer { VisionReader.useFastLevel = false }
        let vision = VisionLock()
        defer { vision.free() }
        let queue = ReadQueue(label: "test.parked.norescue", timeoutMs: 50, abandonStallAfterMs: 100, abandonRetryMs: 30)
        let events = Events()
        queue.onEvent = { events.add($0) }

        _ = try? await queue.run { vision.pass() }
        for _ in 0..<200 where Self.count(events, Self.isAbandoned) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Self.count(events, Self.isAbandoned), 1)
        _ = try? await queue.run { vision.pass() }
        XCTAssertTrue(queue.isPrimaryParked)
        XCTAssertEqual(events.all.first(where: Self.isParked), .parked(stillStuck: 1, rescued: false))
        XCTAssertNil(queue.abandonStall(olderThanMs: 0), "kilitliyken elle de bırakılmaz")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(Self.count(events, Self.isAbandoned), 1)
        do {
            _ = try await queue.run { 1 }
            XCTFail("kilitliyken okuma verilmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .stuck)
        }

        vision.free()
        for _ in 0..<200 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(queue.stalledMs)
        XCTAssertFalse(queue.isPrimaryParked)
        let value = try await queue.run { 5 }
        XCTAssertEqual(value, 5)
    }

    private static func wasCancelled(_ event: ReadQueue.Event?) -> Bool? {
        guard case .abandoned(_, _, let cancelled)? = event else { return nil }
        return cancelled
    }

    /// #1333 (Mac, beta.101): ekran yazıyla dolunca takılan Vision isteği hiç dönmüyordu; bırakılan istek kilidi oturum
    /// boyunca tuttu, yeniden kurulan okuyucu hemen takıldı, okumalar yedekte (önce hızlı düzeyde) kaldı. Artık bırakılan
    /// istek iptal edilir: kilit serbest kalır, bırakılan okuma biter, asıl okuyucu kilitli sayılmaz ve geri döner.
    func testAbandonedReadIsCancelledReleasingTheLockAndPrimaryRecovers() async throws {
        defer { VisionReader.useFastLevel = false }
        let vision = WedgedVision()
        defer { vision.free() }
        let queue = ReadQueue(label: "test.cancel", timeoutMs: 5000, subtitleTimeoutMs: 80,
                              abandonStallAfterMs: 200, recoverAfterReads: 3, cancelsAbandonedRead: { true })
        let rescuer = FakeRescuer()
        queue.rescuer = rescuer
        let events = Events()
        queue.onEvent = { events.add($0) }
        let read: @Sendable () throws -> Reading = {
            if ReadQueue.activeRescuer == nil { try vision.recognize() }
            return try Self.rescuedOrPrimary()
        }

        _ = try? await queue.run(priority: .subtitle, read)
        XCTAssertTrue(queue.isRescuing)
        for _ in 0..<200 where Self.count(events, Self.isAbandoned) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Self.wasCancelled(events.all.first(where: Self.isAbandoned)), true)
        XCTAssertEqual(vision.cancelCount, 1, "takılan istek iptal edildi")

        // Kilit serbest: bırakılan okuma biter, yeni okuyucu okumaları süresinde bitirir, asıl okuyucuya dönülür.
        for _ in 0..<200 where Self.count(events, Self.isRebuilt) == 0 {
            _ = try await queue.run(priority: .subtitle, read)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(events.all.contains(.abandonedFinished(stillStuck: 0)))
        XCTAssertEqual(events.all.last(where: Self.isRebuilt), .recoveredAfterRebuild(reads: 3))
        XCTAssertFalse(queue.isPrimaryParked)
        XCTAssertEqual(Self.count(events, Self.isParked), 0, "iptal edilen istek kilidi tutmaz, asıl okuyucu kilitli sayılmaz")
        XCTAssertFalse(queue.isRescuing)
        let primary = try await queue.run(priority: .subtitle, read)
        XCTAssertEqual(primary.text, "asıl")
    }

    /// İsabetli model henüz hazır değilken (ilk açılışta derleniyor) bırakılan istek iptal edilmez: iptal derlemeyi
    /// baştan başlatırdı. Takılma eskisi gibi yedekte sürer.
    func testAbandonedReadIsNotCancelledBeforeTheModelIsReady() async throws {
        defer { VisionReader.useFastLevel = false }
        let vision = WedgedVision()
        defer { vision.free() }
        let queue = ReadQueue(label: "test.cancel.cold", timeoutMs: 5000, subtitleTimeoutMs: 80,
                              abandonStallAfterMs: 200, cancelsAbandonedRead: { false })
        queue.rescuer = FakeRescuer()
        let events = Events()
        queue.onEvent = { events.add($0) }

        _ = try? await queue.run(priority: .subtitle) { if ReadQueue.activeRescuer == nil { try vision.recognize() } }
        for _ in 0..<200 where Self.count(events, Self.isAbandoned) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Self.wasCancelled(events.all.first(where: Self.isAbandoned)), false)
        XCTAssertEqual(vision.cancelCount, 0)
    }

    /// İptal, kayıtlı isteği bir kez iptal eder; iptalden sonra yeni istek başlatılmaz (derin okumanın ikinci isteği).
    func testReadCancellationCancelsRunningRequestOnceAndBlocksLaterOnes() throws {
        let cancellation = ReadCancellation()
        let cancels = Counter()
        let value = try cancellation.run(onCancel: { cancels.add() }) { () -> Int in
            cancellation.cancel()
            cancellation.cancel()
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertEqual(cancels.value, 1)
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertThrowsError(try cancellation.run(onCancel: { cancels.add() }) { 1 }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(cancels.value, 1)
        XCTAssertNil(ReadQueue.currentCancellation, "kuyruk dışında iptal yok")
    }

    /// #1307: art arda bırakma sınırı dolunca takılma 5 sn'de bir boşuna yeniden deneniyordu. Artık denenmez; bırakılan
    /// okumalar bitince sınır sıfırlanır ve süren takılma kendiliğinden bırakılır (3 bırakmadan sonra dönüş).
    func testAbandonLimitStopsRetryingAndRearmsWhenAbandonedReadsFinish() async throws {
        defer { VisionReader.useFastLevel = false }
        let queue = ReadQueue(label: "test.abandon.cap", timeoutMs: 50, abandonStallAfterMs: 100, abandonRetryMs: 30)
        let events = Events()
        queue.onEvent = { events.add($0) }
        let hangs = (0..<4).map { _ in Hang() }
        defer { hangs.forEach { $0.release() } }

        // Her biri ayrı takılma: yeni okuyucu okuyabiliyor (kilit süreç geneli değil), sonra yeniden takılıyor.
        for round in 0..<ReadQueue.defaultMaxAbandons {
            let hang = hangs[round]
            _ = try? await queue.run { hang.wait() }
            for _ in 0..<200 where Self.count(events, Self.isAbandoned) <= round { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(Self.count(events, Self.isAbandoned), round + 1, "tur \(round)")
            let value = try await queue.run { round }
            XCTAssertEqual(value, round)
        }
        let last = hangs[3]
        _ = try? await queue.run { last.wait() }
        // Sınır dolu: bırakılmaz ve aralıklı denenmez.
        try await Task.sleep(for: .milliseconds(400))
        let checks = queue.abandonCheckCount
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(queue.abandonCheckCount, checks, "sınır doluyken boşuna deneme yok")
        XCTAssertEqual(Self.count(events, Self.isAbandoned), ReadQueue.defaultMaxAbandons)
        XCTAssertNotNil(queue.stalledMs)
        XCTAssertFalse(queue.isPrimaryParked)

        // Bırakılan okumalar biter: sınır sıfırlanır, süren takılma kendiliğinden bırakılır, okuma sürer.
        hangs[0..<3].forEach { $0.release() }
        for _ in 0..<200 where Self.count(events, Self.isAbandoned) <= ReadQueue.defaultMaxAbandons {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Self.count(events, Self.isAbandoned), ReadQueue.defaultMaxAbandons + 1)
        XCTAssertNil(queue.stalledMs)
        let value = try await queue.run { 42 }
        XCTAssertEqual(value, 42)
    }

    /// #1307: art arda bırakma sınırı sağlıklı okumalarla sıfırlanır. Yeniden kurulan okuyucu okumaları süresinde
    /// bitirdiyse sonraki ayrı takılma da bırakılır (bırakılan okumalar hiç bitmese de).
    func testHealthyReadsResetAbandonStreak() async throws {
        defer { VisionReader.useFastLevel = false }
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.abandon.streak", timeoutMs: 50, recoverAfterReads: 2)
        let events = Events()
        queue.onEvent = { events.add($0) }
        for round in 1...4 {
            _ = try? await queue.run { hang.wait() }
            XCTAssertNotNil(queue.abandonStall(olderThanMs: 0, maxAbandons: 2), "tur \(round): sağlıklı okumadan sonra bırakılır")
            for n in 0..<2 {
                let value = try await queue.run { n }
                XCTAssertEqual(value, n)
            }
        }
        // Olay, okuma çağırana teslim edildikten sonra yazılır.
        for _ in 0..<100 where Self.count(events, Self.isRebuilt) < 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Self.count(events, Self.isRebuilt), 4)
        // Aralarda sınamayı geçecek kadar okuma yoksa art arda bırakma sınırda durur.
        for _ in 0..<2 {
            _ = try? await queue.run { hang.wait() }
            XCTAssertNotNil(queue.abandonStall(olderThanMs: 0, maxAbandons: 2))
            _ = try await queue.run { 0 }
        }
        _ = try? await queue.run { hang.wait() }
        XCTAssertFalse(queue.isPrimaryParked)
        XCTAssertNil(queue.abandonStall(olderThanMs: 0, maxAbandons: 2))
    }

    /// #1307: bırakılan okuma hiç bitmese de yeniden kurulan okuyucu okumaları süresinde bitirdiyse hızlı düzeyin süresi
    /// dolunca isabetli düzeye dönülür (eskiden oturum boyunca hızlı düzeyde kalınıyordu).
    func testFastLevelRestoredWhenRebuiltReaderIsHealthy() async throws {
        defer { VisionReader.useFastLevel = false }
        let hang = Hang()
        defer { hang.release() }
        let queue = ReadQueue(label: "test.restore.healthy", timeoutMs: 50, fastLevelHoldMs: 100, recoverAfterReads: 3)
        let events = Events()
        queue.onEvent = { events.add($0) }
        _ = try? await queue.run { hang.wait() }
        XCTAssertNotNil(queue.abandonStall(olderThanMs: 0))
        XCTAssertTrue(VisionReader.useFastLevel)
        for n in 0..<3 { _ = try await queue.run { n } }
        try await Task.sleep(for: .milliseconds(150))
        _ = try await queue.run { 3 }
        XCTAssertFalse(VisionReader.useFastLevel)
        XCTAssertTrue(events.all.contains { if case .restored = $0 { return true } else { return false } })
    }

    /// iPhone: asla dönmeyen okuma altyazıyı uygulama kapatılana dek durduruyordu (TestFlight, X). Takılma yeterince
    /// uzunsa bırakılır; sonraki okuma yeni kuyrukta ve hızlı düzeyde verilir. Sınır kadar bırakıldıktan sonra yine `stuck`.
    func testNeverReturningReadIsAbandonedWithoutRescue() async throws {
        let hang = Hang()
        defer { hang.release() }
        defer { VisionReader.useFastLevel = false }
        let queue = ReadQueue(label: "test.abandon", timeoutMs: 100)

        _ = try? await queue.run { hang.wait() }
        XCTAssertNotNil(queue.stalledMs)
        XCTAssertNil(queue.abandonStall(olderThanMs: 60_000), "kısa takılma bırakılmaz")
        do {
            _ = try await queue.run { 1 }
            XCTFail("takılıyken okuma verilmemeliydi")
        } catch {
            XCTAssertEqual(error as? ReadQueueError, .stuck)
        }

        let ms = queue.abandonStall(olderThanMs: 0, maxAbandons: 2)
        XCTAssertGreaterThanOrEqual(ms ?? 0, 100)
        XCTAssertNil(queue.stalledMs)
        XCTAssertTrue(VisionReader.useFastLevel)
        let value = try await queue.run { 2 }
        XCTAssertEqual(value, 2)

        // Yeni kuyrukta yine takılırsa bir kez daha bırakılır; sınırdan sonra bırakılmaz.
        _ = try? await queue.run { hang.wait() }
        XCTAssertNotNil(queue.abandonStall(olderThanMs: 0, maxAbandons: 2))
        let three = try await queue.run { 3 }
        XCTAssertEqual(three, 3)
        _ = try? await queue.run { hang.wait() }
        XCTAssertNil(queue.abandonStall(olderThanMs: 0, maxAbandons: 2))
        XCTAssertNotNil(queue.stalledMs)

        // Bırakılan okuma sonradan biterse yeni kuyruğa dokunmaz.
        hang.release()
        for _ in 0..<100 where queue.stalledMs != nil { try await Task.sleep(for: .milliseconds(10)) }
        let four = try await queue.run { 4 }
        XCTAssertEqual(four, 4)
    }

    /// X (iPhone): "2 saat oynadım, bir anda altyazılar gitti; uygulamayı kapatıp açınca düzeldi". Bırakma sınırı süreç
    /// boyunca sayılıyordu: uzun oyunda dördüncü takılma bırakılamıyor, altyazı uygulama kapatılana dek gelmiyordu. Uzun
    /// oturum sıkıştırılmış sürede: her biri sonradan biten on takılma; her biri bırakılır, okuma her seferinde sürer.
    func testLongSessionKeepsAbandoningStallsThatLaterFinish() async throws {
        defer { VisionReader.useFastLevel = false }
        let queue = ReadQueue(label: "test.abandon.long", timeoutMs: 50)
        let events = EventLog()
        queue.onEvent = { events.add($0) }
        for round in 1...10 {
            let hang = Hang()
            _ = try? await queue.run { hang.wait() }
            XCTAssertNotNil(queue.stalledMs, "tur \(round)")
            XCTAssertNotNil(queue.abandonStall(olderThanMs: 0, maxAbandons: 3), "tur \(round): takılan okuma bırakılmalı")
            let value = try await queue.run { round }
            XCTAssertEqual(value, round)
            // Takılan okuma (Vision) bir süre sonra kendiliğinden biter.
            hang.release()
            for _ in 0..<200 where events.finishedCount < round { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(events.finishedCount, round, "tur \(round): bitti olayı")
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ReadQueue.Event] = []
    func add(_ event: ReadQueue.Event) { lock.withLock { events.append(event) } }
    var finishedCount: Int {
        lock.withLock { events.filter { if case .abandonedFinished = $0 { return true } else { return false } }.count }
    }
}

/// iPhone'da kareler ana iş parçacığına tek gözlü kutudan gider (bkz. `FrameMailbox`).
final class FrameMailboxTests: XCTestCase {
    func testOnlyLatestFrameWaitsAndOneDeliveryIsScheduled() {
        let box = FrameMailbox<Int>()
        XCTAssertTrue(box.put(1), "ilk kare teslim işi kurdurur")
        XCTAssertFalse(box.put(2))
        XCTAssertFalse(box.put(3))
        XCTAssertEqual(box.take(), 3, "yalnız son kare bekler")
        XCTAssertEqual(box.takeDropped(), 2)
        XCTAssertFalse(box.put(4), "teslim işi sürüyor: yenisi kurulmaz")
        XCTAssertEqual(box.take(), 4)
        XCTAssertNil(box.take(), "kutu boş: teslim işi biter")
        XCTAssertTrue(box.put(5), "sonraki kare yeni teslim işi kurdurur")
        box.clear()
        XCTAssertNil(box.take())
        XCTAssertTrue(box.put(6))
    }

    /// Ana iş parçacığı takılı kalsa da çözücü beklemez ve bellekte tek kare kalır.
    func testSlowConsumerKeepsOneFrame() {
        let box = FrameMailbox<[UInt8]>()
        var scheduled = 0
        for _ in 0..<200 where box.put([UInt8](repeating: 0, count: 16)) { scheduled += 1 }
        XCTAssertEqual(scheduled, 1)
        XCTAssertEqual(box.takeDropped(), 199)
        XCTAssertNotNil(box.take())
        XCTAssertNil(box.take())
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ name: String) { lock.withLock { list.append(name) } }
    var all: [String] { lock.withLock { list } }
}

private final class Concurrency: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private(set) var calls = 0
    private(set) var maxAtOnce = 0
    func enter() { lock.withLock { now += 1; calls += 1; maxAtOnce = max(maxAtOnce, now) } }
    func leave() { lock.withLock { now -= 1 } }
}
#endif
