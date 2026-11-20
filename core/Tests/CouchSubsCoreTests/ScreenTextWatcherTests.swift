// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Otomatik bulunan ekran yazısı alanları RegionWatcher'da (Windows: RegionWatcherTests.cs'teki Auto testleri).
@MainActor
final class ScreenTextWatcherTests: XCTestCase {
    private final class Reader: TextReader, @unchecked Sendable {
        var lines: [TextLine] = []
        func read(_ image: CGImage) throws -> String { lines.map(\.text).joined(separator: "\n") }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { Reading(lines: lines) }
    }

    private final class Translator: TextTranslator {
        var calls: [String] = []
        var map: (String) -> String = { "TR: " + $0 }
        func translate(_ text: String) async throws -> String {
            calls.append(text)
            return map(text)
        }
    }

    private final class Server: RegionSending {
        var sent: [(id: String, text: String)] = []
        var blocks: [[ScreenTranslation.Item]?] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                        blocks: [ScreenTranslation.Item]?) {
            sent.append((id, text))
            self.blocks.append(blocks)
        }
        func clearRegions() {}
    }

    private func frame(_ shade: UInt8) -> CGImage {
        ScreenTextDetectorTests.image([UInt8](repeating: shade, count: 320 * 180 * 4), width: 320, height: 180)
    }

    private let auto = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName,
                                 region: CropRegion(top: 0.02, bottom: 0.2, left: 0.02, right: 0.4), auto: true)
    private let quest = ExtraArea(id: "q", name: "Quest", region: ExtraAreaPreset.quest.region)

    private func line(_ text: String) -> TextLine {
        TextLine(text, box: TextBox(left: 0.1, top: 0.2, right: 0.9, bottom: 0.3))
    }

    func testAutoAreaTranslatesRealTextInPlace() async throws {
        let reader = Reader(), server = Server(), translator = Translator()
        translator.map = { _ in "Lamar sana mesaj gönderdi." }
        reader.lines = [line("Lamar has sent you a message.")]
        var rejected: [String] = []
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        watcher.onAutoRejected = { rejected.append($0) }
        await watcher.pass(frame(10), areas: [auto])
        await watcher.pass(frame(10), areas: [auto])
        XCTAssertEqual(server.sent.map { $0.id + "|" + $0.text }, ["auto-1|Lamar sana mesaj gönderdi."])
        // Tek grup da blok olur ve stilini taşır.
        let block = try XCTUnwrap(server.blocks.first ?? nil)
        XCTAssertEqual(block.count, 1)
        XCTAssertNotNil(block[0].look)
        XCTAssertNotNil(block[0].style)
        XCTAssertTrue(rejected.isEmpty)
    }

    func testAutoAreaWithNoiseIsRejectedNotTranslated() async {
        for text in ["$1,250", "HONOR", "LIQUOR STORE"] {
            let reader = Reader(), server = Server(), translator = Translator()
            reader.lines = [line(text)]
            var rejected: [String] = []
            let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
            watcher.onAutoRejected = { rejected.append($0) }
            await watcher.pass(frame(10), areas: [auto])
            await watcher.pass(frame(10), areas: [auto])
            XCTAssertTrue(translator.calls.isEmpty, text)
            XCTAssertTrue(server.sent.isEmpty, text)
            XCTAssertEqual(rejected, ["auto-1"], text)
        }
    }

    func testAutoAreaWithoutTextIsRejected() async {
        let server = Server()
        var rejected: [String] = []
        let watcher = RegionWatcher(reader: Reader(), translator: Translator(), server: server)
        watcher.onAutoRejected = { rejected.append($0) }
        await watcher.pass(frame(10), areas: [auto])
        await watcher.pass(frame(10), areas: [auto])
        XCTAssertEqual(rejected, ["auto-1"])
        XCTAssertTrue(server.sent.isEmpty)
    }

    /// Gürültü elemesi yalnız otomatik alanlarda: kullanıcının alanı eskisi gibi çevrilir.
    func testNoiseInAUserAreaIsStillHandledAsBefore() async {
        let reader = Reader(), server = Server()
        reader.lines = [line("LIQUOR STORE")]
        var rejected: [String] = []
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: server)
        watcher.onAutoRejected = { rejected.append($0) }
        await watcher.pass(frame(10), areas: [quest])
        await watcher.pass(frame(10), areas: [quest])
        XCTAssertTrue(rejected.isEmpty)
        XCTAssertEqual(server.sent.map(\.text), ["TR: LIQUOR STORE"])
    }

    func testAutoAreasAreReadEveryHalfSecond() async throws {
        var clock = 0
        let reader = Reader()
        reader.lines = [line("Follow Paulie to the car.")]
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: Server(), clock: { clock })
        watcher.offer(frame(10), areas: [auto])
        try await waitIdle(watcher)
        clock = RegionWatcher.autoIntervalMs
        watcher.offer(frame(20), areas: [auto])
        try await waitIdle(watcher)
        XCTAssertEqual(watcher.passes, 2)

        clock = 0
        let user = RegionWatcher(reader: reader, translator: Translator(), server: Server(), clock: { clock })
        user.offer(frame(10), areas: [quest])
        try await waitIdle(user)
        clock = RegionWatcher.autoIntervalMs
        user.offer(frame(20), areas: [quest])
        try await waitIdle(user)
        XCTAssertEqual(user.passes, 1)
    }

    /// Stilli bloklar sunucuda `surface` (flat ile) ve `style` alanlarıyla gider; masaüstü penceresine `screenText` olur.
    func testServerSendsStyledBlocks() throws {
        var item = ScreenTranslation.Item(source: "ROB VICKI'S BOSS", translation: "VİCKİ'NİN PATRONUNU SOY",
                                          box: TextBox(left: 0.1, top: 0.1, right: 0.4, bottom: 0.15), lineHeight: 0.04)
        item.style = PhoneTextStyle(background: "#14161E", foreground: "#F0F0F0")
        item.look = TextLook(bold: true, condensed: true, align: .center, upper: true, flat: true)
        let json = SubtitleServer.json(item)
        XCTAssertEqual(json["surface"] as? [String: AnyHashable],
                       ["background": "#14161E", "foreground": "#F0F0F0", "flat": true])
        XCTAssertEqual(json["style"] as? [String: AnyHashable],
                       ["align": "center", "bold": true, "condensed": true, "upper": true])
        // Stilsiz blokta (kullanıcı alanı) eskisi gibi ikisi de yok.
        let plain = SubtitleServer.json(ScreenTranslation.Item(source: "a", translation: "b", box: item.box, lineHeight: 0.04))
        XCTAssertNil(plain["surface"])
        XCTAssertNil(plain["style"])

        let server = SubtitleServer(port: 0)
        final class Events: @unchecked Sendable { var all: [SubtitleEvent] = [] }
        let events = Events()
        server.onEvent = { events.all.append($0) }
        server.sendRegion(id: "auto-1", text: item.translation, box: item.box, lineHeight: 0.04, icons: nil, blocks: [item])
        server.sendRegion(id: "auto-1", text: "", box: nil, lineHeight: nil)
        XCTAssertEqual(events.all, [.screenText(id: "auto-1", items: [item]), .region(id: "auto-1", text: "", box: nil)])
    }

    private func waitIdle(_ watcher: RegionWatcher) async throws {
        for _ in 0..<200 where watcher.isBusy { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}
