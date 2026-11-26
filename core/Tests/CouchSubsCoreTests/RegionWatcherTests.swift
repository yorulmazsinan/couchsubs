// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Ek alanlar: ana altyazıdan ayrı, seyrek okunur; yazı kararlıysa ve değiştiyse çevrilir (Windows: RegionWatcherTests.cs).
@MainActor
final class RegionWatcherTests: XCTestCase {
    /// Okunacak yazı test içinde değiştirilir.
    private final class Reader: TextReader, @unchecked Sendable {
        var lines: [TextLine] = []
        var count = 0
        var failuresRemaining = 0
        private enum Failure: Error { case expected }
        func read(_ image: CGImage) throws -> String { lines.map(\.text).joined(separator: "\n") }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading {
            count += 1
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw Failure.expected
            }
            return Reading(lines: lines)
        }
    }

    private final class Translator: TextTranslator {
        var calls: [String] = []
        var failuresRemaining = 0
        func translate(_ text: String) async throws -> String {
            calls.append(text)
            if hangNs > 0 { try? await Task.sleep(nanoseconds: hangNs) }
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw Failure.expected
            }
            return map(text)
        }
        var map: (String) -> String = { "TR: " + $0 }
        /// Doluysa çeviri bu kadar ns bekler (asılı motor).
        var hangNs: UInt64 = 0

        private enum Failure: Error { case expected }
    }

    private final class Server: RegionSending {
        var sent: [(id: String, text: String, box: TextBox?)] = []
        var lineHeights: [Double?] = []
        var clears = 0
        /// Her gönderimin blokları (`sent` ile aynı sırada; bloksuz gönderimde nil).
        var blocks: [[ScreenTranslation.Item]?] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                        blocks: [ScreenTranslation.Item]?) {
            sent.append((id, text, box))
            lineHeights.append(lineHeight)
            self.blocks.append(blocks)
        }
        func clearRegions() { clears += 1 }
    }

    /// Düz gri kare; `shade` değişince bölge izi değişir.
    private func frame(_ shade: UInt8) -> CGImage {
        let width = 320, height = 180
        var pixels = [UInt8](repeating: shade, count: width * height)
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        return context!.makeImage()!
    }

    private let quest = ExtraArea(id: "q", name: "Quest", region: ExtraAreaPreset.quest.region)
    private func line(_ text: String, top: Double = 0.2, height: Double = 0.1) -> TextLine {
        TextLine(text, box: TextBox(left: 0.1, top: top, right: 0.9, bottom: top + height))
    }

    private func at(_ text: String, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> TextLine {
        TextLine(text, box: TextBox(left: left, top: top, right: right, bottom: bottom))
    }

    private func inQuest(_ box: TextBox) -> TextBox {
        let region = quest.region
        return box.placed(in: TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom))
    }

    /// Alanda birbirinden ayrı duran yazılar alt alta tek kutuda değil, her biri kendi yeriyle gider; eski TV'ler için
    /// birleşik metin de kalır (Windows ile aynı).
    func testSeparateGroupsInAnAreaAreSentAsBlocksAtTheirOwnPlaces() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [at("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), at("Go to the barn", 0.1, 0.6, 0.4, 0.7)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Find the blacksmith\nTR: Go to the barn"])
        XCTAssertEqual(server.blocks.count, 1)
        let blocks = try XCTUnwrap(server.blocks[0])
        XCTAssertEqual(blocks.map(\.translation), ["TR: Find the blacksmith", "TR: Go to the barn"])
        XCTAssertEqual(blocks.map(\.source), ["Find the blacksmith", "Go to the barn"])
        XCTAssertEqual(blocks[0].box, inQuest(TextBox(left: 0.5, top: 0.1, right: 0.95, bottom: 0.2)))
        XCTAssertEqual(blocks[1].box, inQuest(TextBox(left: 0.1, top: 0.6, right: 0.4, bottom: 0.7)))
        XCTAssertEqual(blocks[0].lineHeight, 0.1 * (quest.region.bottom - quest.region.top), accuracy: 1e-9)
        XCTAssertEqual(server.sent[0].box, inQuest(TextBox(left: 0.1, top: 0.1, right: 0.95, bottom: 0.7)))
    }

    /// Tek grup (alt alta sarılmış tek yazı) tek çeviridir; kullanıcının alanında da özgün stilinde tek blok olarak çizilir
    /// (#1324: tek siyah kutu tuş simgelerini örtüyor, yazı boyu okumadan okumaya değişiyordu).
    func testOneGroupIsSentAsOneStyledBlock() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        translator.map = { _ in "Demirciyi bul ve kılıcını onarmasını iste." }
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Find the blacksmith and ask him", top: 0.2), line("to repair your sword.", top: 0.3)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(translator.calls, ["Find the blacksmith and ask him to repair your sword."])
        XCTAssertEqual(server.sent.map(\.text), ["Demirciyi bul ve kılıcını onarmasını iste."])
        XCTAssertEqual(server.blocks.count, 1)
        let blocks = try XCTUnwrap(server.blocks[0])
        XCTAssertEqual(blocks.map(\.translation), ["Demirciyi bul ve kılıcını onarmasını iste."])
        XCTAssertNotNil(blocks[0].paint)
    }

    /// Çevirisi aslıyla aynı grup (ad) blok olarak gönderilmez; İngilizcesi görünür kalır.
    func testUntranslatedGroupIsLeftOutOfTheBlocks() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        translator.map = { $0 == "Arthur" ? "Arthur" : "TR: " + $0 }
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [at("Arthur", 0.1, 0.1, 0.3, 0.2), at("Meet me at the barn", 0.1, 0.6, 0.6, 0.7)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        let blocks = try XCTUnwrap(server.blocks.first ?? nil)
        XCTAssertEqual(blocks.map(\.translation), ["TR: Meet me at the barn"])
        XCTAssertEqual(blocks[0].box, inQuest(TextBox(left: 0.1, top: 0.6, right: 0.6, bottom: 0.7)))
    }

    /// Aynı yazı kayınca yeniden çevrilmez; bloklar aynı çeviriyle yeni yerlerine gönderilir.
    func testMovedBlocksKeepTheirTranslations() async throws {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [at("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), at("Go to the barn", 0.1, 0.6, 0.4, 0.7)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        reader.lines = [at("Find the blacksmith", 0.5, 0.1, 0.95, 0.2), at("Go to the barn", 0.1, 0.7, 0.4, 0.8)]
        await watcher.pass(frame(60), areas: [quest])
        XCTAssertEqual(translator.calls, ["Find the blacksmith", "Go to the barn"])
        XCTAssertEqual(server.sent.count, 2)
        let moved = try XCTUnwrap(server.blocks[1])
        XCTAssertEqual(moved.map(\.translation), ["TR: Find the blacksmith", "TR: Go to the barn"])
        XCTAssertEqual(moved[1].box, inQuest(TextBox(left: 0.1, top: 0.7, right: 0.4, bottom: 0.8)))
        // Yer değişmeden yeniden okunan aynı yazı bir şey göndermez.
        await watcher.pass(frame(100), areas: [quest])
        XCTAssertEqual(server.sent.count, 2)
    }

    func testFailedReadRetriesOnAnUnchangedFrameThenStopsReading() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Find the blacksmith")]
        reader.failuresRemaining = 1
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertTrue(server.sent.isEmpty)
        for _ in 0..<4 { await watcher.pass(frame(10), areas: [quest]) }
        XCTAssertEqual(reader.count, 2)
        XCTAssertEqual(translator.calls, ["Find the blacksmith"])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Find the blacksmith"])
    }

    /// Ekranda zaten Türkçe olan yazı (bozuk okunmuş olsa da) çevrilmez, kutu gösterilmez (#289).
    func testTurkishTextIsNotTranslated() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Sistem Yazillml Güncellem€")]
        for _ in 0..<3 { await watcher.pass(frame(10), areas: [quest]) }
        XCTAssertEqual(translator.calls, [])
        XCTAssertTrue(server.sent.allSatisfy { $0.text.isEmpty })
    }

    func testEnglishTextWithTurkishNameIsTranslated() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Atatürk said no.")]
        for _ in 0..<3 { await watcher.pass(frame(10), areas: [quest]) }
        XCTAssertEqual(translator.calls, ["Atatürk said no."])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Atatürk said no."])
    }

    func testFailedReadKeepsShownTextAndDiscardsUnconfirmedReading() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Talk to Arthur")]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        reader.lines = [line("Meet Arthur at the barn")]
        await watcher.pass(frame(60), areas: [quest])
        reader.failuresRemaining = 1
        await watcher.pass(frame(100), areas: [quest])
        reader.lines = [line("Find the blacksmith")]
        await watcher.pass(frame(100), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur"])
        await watcher.pass(frame(100), areas: [quest])
        XCTAssertEqual(translator.calls, ["Talk to Arthur", "Find the blacksmith"])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur", "TR: Find the blacksmith"])
    }

    func testFailedReadDoesNotBlockAnotherArea() async {
        let reader = Reader(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server)
        let phone = ExtraArea(id: "p", name: "Phone", region: ExtraAreaPreset.phone.region)
        reader.lines = [line("Find the blacksmith")]
        reader.failuresRemaining = 1
        await watcher.pass(frame(10), areas: [quest, phone])
        await watcher.pass(frame(10), areas: [quest, phone])
        XCTAssertEqual(server.sent.map(\.id), ["p"])
        await watcher.pass(frame(10), areas: [quest, phone])
        XCTAssertEqual(server.sent.map(\.id), ["p", "q"])
        XCTAssertEqual(reader.count, 3)
    }

    func testRepeatedReadFailuresStillRespectThePassInterval() async {
        var clock = 0
        let reader = Reader(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server, clock: { clock })
        reader.failuresRemaining = 10
        for step in 0...20 {
            clock = step * RegionWatcher.defaultIntervalMs / 10
            watcher.offer(frame(10), areas: [quest])
            while watcher.isBusy { await Task.yield() }
        }
        XCTAssertEqual(watcher.passes, 3)
        XCTAssertEqual(reader.count, 3)
        XCTAssertTrue(server.sent.isEmpty)
    }

    func testStableTextIsTranslatedOnceAndPlacedInItsArea() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Find the blacksmith")]
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertTrue(translator.calls.isEmpty, "geçici metin çeviri bağlamına girmemeli")
        XCTAssertTrue(server.sent.isEmpty, "ilk okuma kararlı sayılmaz")
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Find the blacksmith"])
        let box = server.sent[0].box!
        XCTAssertGreaterThan(box.left, quest.region.left)
        XCTAssertLessThan(box.right, quest.region.right)
        // Kare değişmedikçe ne okunur ne çevrilir.
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(reader.count, 1)
        XCTAssertEqual(translator.calls.count, 1)
        XCTAssertEqual(server.sent.count, 1)
    }

    func testSameTextAtNewGeometryUpdatesRegionWithoutRetranslating() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Find the blacksmith", top: 0.2, height: 0.1)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        let firstBox = server.sent[0].box!
        let firstHeight = server.lineHeights[0]!

        reader.lines = [line("Find the blacksmith", top: 0.45, height: 0.2)]
        await watcher.pass(frame(60), areas: [quest])

        XCTAssertEqual(server.sent.map(\.text), ["TR: Find the blacksmith", "TR: Find the blacksmith"])
        XCTAssertNotEqual(server.sent[1].box?.top, firstBox.top)
        XCTAssertNotEqual(server.lineHeights[1], firstHeight)
        XCTAssertEqual(translator.calls, ["Find the blacksmith"])
    }

    func testFailedTranslationRetriesWithoutLosingPreviouslyShownText() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Talk to Arthur")]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur"])

        reader.lines = [line("Meet Arthur at the barn")]
        translator.failuresRemaining = 1
        await watcher.pass(frame(90), areas: [quest])
        await watcher.pass(frame(90), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur"])

        await watcher.pass(frame(90), areas: [quest])
        XCTAssertEqual(translator.calls, ["Talk to Arthur", "Meet Arthur at the barn", "Meet Arthur at the barn"])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur", "TR: Meet Arthur at the barn"])
    }

    /// Görev alanının yalnız sol dörtte biri `shade` olan kare: iz değişir ama alanın çoğu aynı kalır (`bigChangeShare` altı).
    private func partly(_ shade: UInt8) -> CGImage {
        let width = 320, height = 180
        var pixels = [UInt8](repeating: 10, count: width * height)
        let region = quest.region
        let left = Int(region.left * Double(width)), right = left + Int((region.right - region.left) * Double(width) / 4)
        for y in 0..<height { for x in left..<right { pixels[y * width + x] = shade } }
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        return context!.makeImage()!
    }

    /// Görev alanında sabit, parlak "yazı" çizgileri; arkası (`background`) değişir. Yazının izi her karede aynıdır
    /// (`RegionWatcher.traceGone` yanlış), ama alanın çoğu değişir (`bigChangeShare` üstü).
    private func lettered(_ background: UInt8) -> CGImage {
        let width = 320, height = 180
        var pixels = [UInt8](repeating: background, count: width * height)
        let region = quest.region
        let left = Int(region.left * Double(width)), right = Int(region.right * Double(width))
        let top = Int(region.top * Double(height)), bottom = Int(region.bottom * Double(height))
        let band = (top + (bottom - top) / 3)..<(top + 2 * (bottom - top) / 3)
        for y in band { for x in left..<right where (x - left) % 8 < 4 { pixels[y * width + x] = 255 } }
        let context = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }
        return context!.makeImage()!
    }

    /// Otomatik ekran yazısı gibi 500 ms'de bir tur atan saat ve izleyici; `Talk to Arthur at the camp` gösterilmiş olarak.
    private func shownCamp(_ reader: Reader, _ translator: Translator, _ server: Server,
                           log: @escaping (String) -> Void = { _ in }) async -> (RegionWatcher, () -> Int, (Int) -> Void) {
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server, clock: { clock })
        watcher.onLog = log
        reader.lines = [line("Talk to Arthur at the camp")]
        await watcher.pass(lettered(10), areas: [quest])
        clock += 500
        await watcher.pass(lettered(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp"])
        return (watcher, { clock }, { clock += $0 })
    }

    /// Yazı sabit, arkasında sahne oynuyor: okumalar yarım, bozuk, arada boş ya da ilgisiz. Çeviri kalır; kutu 10 sn boyunca
    /// hiç kalkıp geri gelmez (önceden 3 tur = 1,5 sn'de kalkıp önbellekten geri geliyordu; Samsung'da parlaklık sıçraması).
    func testSteadyTextOverAMovingSceneKeepsItsTranslationWithoutBlinking() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let (watcher, _, advance) = await shownCamp(reader, translator, server)
        let reads = ["Talk to Arthur at the cam", "", "Wind noise", "Arthur at tho camp", "Tlk t0 Arthr", "Grss camp",
                     "", "Talk to Arthur", "Birds flying", "Talk Arthur at camp."]
        for step in 0..<20 {
            advance(500)
            let text = reads[step % reads.count]
            reader.lines = text.isEmpty ? [] : [line(text)]
            await watcher.pass(lettered(UInt8(40 + (step % 4) * 40)), areas: [quest])
        }
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp"])
        XCTAssertEqual(translator.calls, ["Talk to Arthur at the camp"])
    }

    /// #1198: yazı gidip yerinde sahne oynayınca okuma hiç kararlı olmuyordu; eski çeviri TV'de kalıyordu. Gösterilene
    /// benzemeyen okumalar `unsteadyTurns` tur ve `unsteadyMs` sürünce çeviri kalkar: ~3 sn içinde, 1,5 sn'den önce değil.
    func testTextThatReallyLeavesLosesItsTranslationWithinThreeSeconds() async {
        let reader = Reader(), translator = Translator(), server = Server()
        var lines: [String] = []
        let (watcher, time, advance) = await shownCamp(reader, translator, server) { lines.append($0) }
        let start = time() + 500
        var clearedAt: Int?
        for (step, text) in ["Grass and trees", "Sky above hills", "Dust road ahead", "Rocky cliffs", "Blue river",
                             "Green pines", "Old fence", "Wet stones", "Dark clouds"].enumerated() {
            advance(500)
            reader.lines = [line(text)]
            await watcher.pass(frame(UInt8(40 + step * 20)), areas: [quest])
            if clearedAt == nil, server.sent.count > 1 { clearedAt = time() }
        }
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp", ""])
        let after = (clearedAt ?? .max) - start
        XCTAssertGreaterThanOrEqual(after, RegionWatcher.unsteadyMs)
        XCTAssertLessThanOrEqual(after, 3000)
        XCTAssertTrue(lines.contains { $0.contains("kararlı okunmadı, çevirisi kaldırıldı") }, "\(lines)")
    }

    /// Yazı ve izi birlikte gitti (boş okuma, yazısız kare): çeviri beklemeden kalkar. Boş okumada izi yerinde duran yazının
    /// çevirisi ise hemen kalkmaz.
    func testEmptyReadRemovesTheTranslationAtOnceOnlyWhenTheTraceIsGone() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let (watcher, _, advance) = await shownCamp(reader, translator, server)
        advance(500)
        reader.lines = []
        await watcher.pass(lettered(200), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp"])
        advance(500)
        await watcher.pass(frame(100), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp", ""])
    }

    /// Kaldırılan yazı kısa sürede yeniden okunursa yerindeydi: çeviri önbellekten geri gelir, günlüğe yazılır ve o alanın
    /// kaldırma eşiği uzar (aynı kararsızlık bu kez 3 sn'de çeviriyi kaldırmaz, uzamış eşikte kaldırır).
    func testSameTextReturningAfterRemovalExtendsTheThreshold() async {
        let reader = Reader(), translator = Translator(), server = Server()
        var lines: [String] = []
        let (watcher, _, advance) = await shownCamp(reader, translator, server) { lines.append($0) }
        func unrelated(_ count: Int) async {
            for step in 0..<count {
                advance(500)
                reader.lines = [line("Noise \(["alpha", "bravo", "delta", "omega", "kappa", "sigma"][step % 6]) \(step)")]
                await watcher.pass(frame(UInt8(40 + (step % 8) * 20)), areas: [quest])
            }
        }
        await unrelated(7)
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp", ""])
        reader.lines = [line("Talk to Arthur at the camp")]
        advance(500)
        await watcher.pass(lettered(10), areas: [quest])
        advance(500)
        await watcher.pass(lettered(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp", "", "TR: Talk to Arthur at the camp"])
        XCTAssertEqual(translator.calls, ["Talk to Arthur at the camp"])
        XCTAssertTrue(lines.contains { $0.contains("kaldırılan yazı geri geldi") }, "\(lines)")
        await unrelated(8)
        XCTAssertEqual(server.sent.count, 3)
        await unrelated(13)
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp", "", "TR: Talk to Arthur at the camp", ""])
    }

    func testPartlyVisibleReadingsAreNotUnsteady() {
        XCTAssertTrue(RegionWatcher.partlyVisible("tlk t0 arthr", "talk to arthur at the camp"))
        XCTAssertTrue(RegionWatcher.partlyVisible("grss camp", "talk to arthur at the camp"))
        XCTAssertFalse(RegionWatcher.partlyVisible("sky above the hills", "talk to arthur at the camp"))
        XCTAssertFalse(RegionWatcher.partlyVisible("", "talk to arthur at the camp"))
        XCTAssertFalse(RegionWatcher.unsteadyLong(turns: 3, elapsedMs: 5000, patience: 0))
        XCTAssertFalse(RegionWatcher.unsteadyLong(turns: 7, elapsedMs: 2500, patience: 0))
        XCTAssertTrue(RegionWatcher.unsteadyLong(turns: 7, elapsedMs: 3000, patience: 0))
        XCTAssertFalse(RegionWatcher.unsteadyLong(turns: 7, elapsedMs: 3000, patience: 1))
    }

    /// Görüntü bütünüyle değişip yazı da gittiyse çeviri beklemeden kalkar.
    func testBigChangeWithNoTextRemovesTheTranslationAtOnce() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Talk to Arthur at the camp")]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        reader.lines = [line("Wild grass")]
        await watcher.pass(frame(200), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp"])
        reader.lines = []
        await watcher.pass(frame(100), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur at the camp", ""])
    }

    /// Asılı çeviri isteği turu kilitlemez: süre dolunca tur biter, hiçbir şey gösterilmez; sonraki tur yeniden dener.
    func testHangingTranslationTimesOutAndALaterPassShowsTheTranslation() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        watcher.translationTimeoutMs = 100
        translator.hangNs = 30_000_000_000
        reader.lines = [line("Talk to Arthur")]
        let started = Date()
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(server.sent.map(\.text), [])
        translator.hangNs = 0
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur"])
    }

    func testMovingBackgroundWithTheSameTextIsNotTranslatedAgain() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Talk to Arthur")]
        for shade: UInt8 in [10, 60, 110, 160, 210] { await watcher.pass(frame(shade), areas: [quest]) }
        XCTAssertEqual(reader.count, 5)
        XCTAssertEqual(translator.calls, ["Talk to Arthur"])
        // Zemin rengi değişince kutunun rengi güncellenir (özgün stil); çeviri aynı kalır.
        XCTAssertEqual(Set(server.sent.map(\.text)), ["TR: Talk to Arthur"])
    }

    func testChangedTextIsTranslatedAndEmptyAreaRemovesTheBox() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        reader.lines = [line("Talk to Arthur")]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        reader.lines = [line("Meet Arthur at the barn")]
        await watcher.pass(frame(90), areas: [quest])
        await watcher.pass(frame(90), areas: [quest])
        reader.lines = []
        await watcher.pass(frame(200), areas: [quest])
        await watcher.pass(frame(200), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Talk to Arthur", "TR: Meet Arthur at the barn", ""])
    }

    func testPromptsNumbersAndUntranslatedTextShowNothing() async {
        let reader = Reader(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server)
        reader.lines = [line("R2 Swing"), line("23m", top: 0.5)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertTrue(server.sent.isEmpty)
    }

    func testPackTranslationIsUsedBeforeTheEngine() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        watcher.packLookup = { $0 == "New message" ? PackMatch(text: "Yeni mesaj", spoken: []) : nil }
        reader.lines = [line("New message", top: 0.1), line("Call me when you get this.", top: 0.25)]
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(server.sent.map(\.text), ["Yeni mesaj\nTR: Call me when you get this."])
        XCTAssertEqual(translator.calls, ["Call me when you get this."])
    }

    func testRemovedAreaLosesItsBoxAndResetClearsAll() async {
        let reader = Reader(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server)
        let phone = ExtraArea(id: "p", name: "Phone", region: ExtraAreaPreset.phone.region)
        reader.lines = [line("Where are you?")]
        await watcher.pass(frame(10), areas: [quest, phone])
        await watcher.pass(frame(10), areas: [quest, phone])
        XCTAssertEqual(Set(server.sent.map(\.id)), ["q", "p"])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertEqual(server.sent.last?.id, "p")
        XCTAssertEqual(server.sent.last?.text, "")
        watcher.reset()
        XCTAssertEqual(server.clears, 1)
        watcher.reset()
        XCTAssertEqual(server.clears, 1, "gösterilen kutu yoksa temizleme gönderilmez")
    }

    func testOfferRunsAtMostOncePerInterval() async {
        var clock = 0
        let reader = Reader(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server, clock: { clock })
        reader.lines = [line("Find the blacksmith")]
        let image = frame(10)
        watcher.offer(image, areas: [quest])
        while watcher.isBusy { await Task.yield() }
        let interval = 1000 // Mac ve iPhone aynı seri OCR kuyruğunda saniyede en çok bir tur başlatır.
        for step in 1...9 {
            clock = step * interval / 10
            watcher.offer(image, areas: [quest])
            while watcher.isBusy { await Task.yield() }
        }
        XCTAssertEqual(watcher.passes, 1)
        clock = interval
        watcher.offer(image, areas: [quest])
        while watcher.isBusy { await Task.yield() }
        XCTAssertEqual(watcher.passes, 2)
        XCTAssertEqual(server.sent.map(\.text), ["TR: Find the blacksmith"])
    }

    /// Kararlı okunup gösterilen yazı (iki tur, aynı kare).
    private func show(_ watcher: RegionWatcher, _ reader: Reader, _ text: String, _ shade: UInt8) async {
        reader.lines = text.isEmpty ? [] : [line(text)]
        await watcher.pass(frame(shade), areas: [quest])
        await watcher.pass(frame(shade), areas: [quest])
    }

    func testCommandGlossaryRespectsLanguagePackPriorityAndCache() async {
        let scenarios: [(Bool, String?, String, [String])] = [
            (true, nil, "Aç", []), (true, "Menüyü aç", "Menüyü aç", []), (false, nil, "TR: OPEN", ["OPEN"])
        ]
        for (enabled, packText, expected, calls) in scenarios {
            let reader = Reader(), translator = Translator(), server = Server()
            let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
            watcher.translatesUiCommands = enabled
            var lookups = 0
            watcher.packLookup = { text in
                lookups += 1
                return text == "OPEN" ? packText.map { PackMatch(text: $0, spoken: []) } : nil
            }
            await show(watcher, reader, "OPEN", 10)
            await show(watcher, reader, "", 90)
            await show(watcher, reader, "OPEN", 10)
            XCTAssertEqual(server.sent.map(\.text), [expected, "", expected])
            XCTAssertEqual(translator.calls, calls)
            XCTAssertEqual(lookups, 1)
        }
    }

    /// Görev yazısı arada kaybolup yeniden çıkınca çevirmene yeniden gidilmez.
    func testReappearingTextUsesTheEarlierTranslation() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        await show(watcher, reader, "Find the blacksmith", 10)
        await show(watcher, reader, "", 90)
        await show(watcher, reader, "Find the blacksmith", 170)
        XCTAssertEqual(translator.calls, ["Find the blacksmith"])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Find the blacksmith", "", "TR: Find the blacksmith"])
    }

    /// Yazı belirirken renkli sözcük geç geliyor: az önce gösterilen yazının başı okunursa tamamı beklenir; görev iki kez
    /// çevrilip değişmez.
    func testPartialReadingOfTheLastTextWaitsForTheWholeText() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        await show(watcher, reader, "Fly to a drop point", 10)
        await show(watcher, reader, "", 90)
        await show(watcher, reader, "Fly to a", 170)
        reader.lines = [line("Fly to a drop point")]
        await watcher.pass(frame(250), areas: [quest])
        await watcher.pass(frame(250), areas: [quest])
        XCTAssertEqual(translator.calls, ["Fly to a drop point"])
        XCTAssertEqual(server.sent.map(\.text), ["TR: Fly to a drop point", "", "TR: Fly to a drop point"])
    }

    /// Arka plan oynarken ekrandakinin harfi bozuk okuması kutuyu değiştirmez.
    func testNearlySameReadingKeepsTheShownText() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        await show(watcher, reader, "SET DESTINATION EXIT", 10)
        await show(watcher, reader, "SET DESTINATIPN EXIT", 90)
        await show(watcher, reader, "SET DESTINATION EXIT", 170)
        XCTAssertEqual(translator.calls, ["SET DESTINATION EXIT"])
        XCTAssertEqual(Set(server.sent.map(\.text)), ["TR: SET DESTINATION EXIT"])
    }

    /// Yalnız bir sözcüğü değişen görev, o hâlde kalırsa birkaç tur sonra gösterilir.
    func testNearlySameTextThatStaysIsShownAfterTheHoldLimit() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        await show(watcher, reader, "Go to the barn", 10)
        await show(watcher, reader, "Go to the bank", 90)
        XCTAssertEqual(server.sent.count, 1)
        for _ in 0..<RegionWatcher.holdLimit { await watcher.pass(frame(90), areas: [quest]) }
        XCTAssertEqual(server.sent.map(\.text), ["TR: Go to the barn", "TR: Go to the bank"])
    }

    func testPartialAndWordLosingReadingsAreRecognised() {
        XCTAssertFalse(RegionWatcher.isPartOf("run", "find the blacksmith"))
        XCTAssertTrue(RegionWatcher.isPartOf("add marker set destination", "add marker set destination exit"))
        XCTAssertFalse(RegionWatcher.isPartOf("talk to arthur", "meet arthur at the barn"))
        XCTAssertTrue(RegionWatcher.losesWords("find \u{FFFC}", "find donnie"))
        XCTAssertFalse(RegionWatcher.losesWords("hold \u{FFFC} to climb", "hold to climb"))
    }

    func testNewNumberNegationAndUnrelatedWordAreShownAfterConfirmation() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        let sources = ["Take gate 5", "Take gate 6", "You can leave the base", "You can't leave the base", "Run"]
        for (index, source) in sources.enumerated() {
            await show(watcher, reader, source, UInt8(index * 40))
        }
        XCTAssertEqual(translator.calls, sources)
    }

    func testAlternatingRereadsDoNotAccumulateHolds() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        await show(watcher, reader, "Go to the barn", 10)
        for _ in 0...RegionWatcher.holdLimit {
            await show(watcher, reader, "Go to the bank", 90)
            await show(watcher, reader, "Go to the barn", 10)
        }
        XCTAssertEqual(translator.calls, ["Go to the barn"])
    }

    func testFirstConfirmedTextAfterResetUsesTheNewGameTranslation() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        translator.map = { _ in "İlk oyun" }
        await show(watcher, reader, "Board the train", 10)
        watcher.reset()
        translator.map = { _ in "İkinci oyun" }
        await show(watcher, reader, "Board the train", 10)
        XCTAssertEqual(server.sent.map(\.text), ["İlk oyun", "İkinci oyun"])
        XCTAssertEqual(server.clears, 1)
    }

    func testResetDropsOfferedPassBeforeItStarts() async {
        let reader = Reader(), translator = Translator(), server = Server()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        watcher.offer(frame(90), areas: [quest])
        watcher.reset()
        await show(watcher, reader, "Board the train", 170)
        XCTAssertEqual(watcher.passes, 2)
        XCTAssertEqual(watcher.reads, 1)
        XCTAssertEqual(translator.calls, ["Board the train"])
    }

    func testTextKeyKeepsButtonIcons() {
        XCTAssertEqual(RegionWatcher.textKey(["SET DESTINATION \u{FFFC} EXIT"]), "set destination \u{FFFC} exit")
        XCTAssertNotEqual(RegionWatcher.textKey(["SET DESTINATION"]), RegionWatcher.textKey(["SET DESTINATION \u{FFFC}"]))
    }

    func testNoAreasMeansNoWork() async {
        let reader = Reader()
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: Server())
        watcher.offer(frame(10), areas: [])
        XCTAssertFalse(watcher.isBusy)
        XCTAssertEqual(reader.count, 0)
    }

    /// Yeni arayüzde ek alan sınırı 3'ten kaldırıldı: dördüncü ve sonrakiler eklenir (kısayolu yok), kayıt yine de üst
    /// sınırda durur.
    func testSettingsHaveNoExtraAreasByDefaultAndAcceptMoreThanThree() throws {
        XCTAssertTrue(UserSettings().extraAreas.isEmpty)
        var settings = UserSettings()
        for preset in ExtraAreaPreset.allCases { XCTAssertNotNil(settings.addExtraArea(preset, name: preset.rawValue)) }
        XCTAssertNotNil(settings.addExtraArea(.quest, name: "fourth"))
        XCTAssertEqual(settings.extraAreas.count, 4)
        while settings.canAddExtraArea { settings.addExtraArea(.quest, name: "more") }
        XCTAssertEqual(settings.extraAreas.count, ExtraArea.maxCount)
        XCTAssertNil(settings.addExtraArea(.quest, name: "over"))
        settings.extraAreas = Array(settings.extraAreas.prefix(4))
        settings.updateExtraArea(id: settings.extraAreas[1].id) { $0.enabled = false }
        XCTAssertEqual(settings.activeExtraAreas.map(\.name), ["quest", "phone", "fourth"])
        let decoded = try JSONDecoder().decode(UserSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.extraAreas, settings.extraAreas)
        // Eski kayıt: alan yok.
        let old = try JSONDecoder().decode(UserSettings.self, from: Data(#"{"sourceLanguage":"en"}"#.utf8))
        XCTAssertTrue(old.extraAreas.isEmpty)
    }

    /// Altyazı alanı Tam ekranken ek alan okunmaz (ekranın tamamı zaten okunuyor); ayarlar değişmez, başka alana dönünce
    /// eskisi gibi okunur (Windows: FullScreenAreaPausesWatchedRegionsWithoutChangingThem).
    func testFullScreenAreaPausesExtraAreasWithoutChangingThem() {
        var settings = UserSettings()
        settings.addExtraArea(.quest, name: "quest")
        settings.addExtraArea(.phone, name: "phone")
        settings.updateExtraArea(id: settings.extraAreas[1].id) { $0.enabled = false }
        let saved = settings.extraAreas
        settings.selectAreaPreset(.full)
        XCTAssertTrue(settings.extraAreasPausedByFullScreen)
        XCTAssertTrue(settings.activeExtraAreas.isEmpty)
        XCTAssertEqual(settings.extraAreas, saved)
        settings.selectAreaPreset(.top)
        XCTAssertFalse(settings.extraAreasPausedByFullScreen)
        XCTAssertEqual(settings.activeExtraAreas.map(\.name), ["quest"])
        // Özel bölge tam kareyi kaplasa da Tam ekran seçili değildir; ek alanlar okunur.
        settings.setCustomRegion(CropRegion(top: 0, bottom: 1, left: 0, right: 1))
        XCTAssertEqual(settings.activeExtraAreas.map(\.name), ["quest"])
    }
}
