// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// Yoğun menü ekranları: duraklatma menüsü ve kontrol şeması (Windows DenseMenuTests ve Android ile aynı örnekler).
@MainActor
final class DenseMenuTests: XCTestCase {
    private final class Reader: TextReader, @unchecked Sendable {
        var lines: [TextLine] = []
        func read(_ image: CGImage) throws -> String { lines.map(\.text).joined(separator: "\n") }
        func read(_ image: CGImage, deep: Bool) throws -> String { try read(image) }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { Reading(lines: lines) }
    }

    /// Toplu istekleri sayan çevirmen.
    private final class Batch: TextTranslator {
        var requests = 0
        var texts: [String] = []
        var translatesTogether: Bool { true }
        func translate(_ text: String) async throws -> String { Self.map(text) }
        func translateAll(_ texts: [String]) async throws -> [String] {
            requests += 1
            self.texts += texts
            return texts.map(Self.map)
        }
        static func map(_ text: String) -> String { "çeviri" + String(text.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 9973 }) }
    }

    private final class Server: RegionSending {
        var blocks: [[ScreenTranslation.Item]?] = []
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                        blocks: [ScreenTranslation.Item]?) {
            self.blocks.append(text.isEmpty ? nil : blocks)
        }
        func clearRegions() {}
    }

    private let area = ExtraArea(id: "auto-1", name: ScreenTextDetector.areaName,
                                 region: CropRegion(top: 0, bottom: 1, left: 0, right: 1), auto: true)

    // --- (a) Duraklatma menüsü: koyu panelde altı satır, seçili satır ters renk ---

    private static let pauseRows = ["Map", "Game", "Store", "Help", "Photo Studio", "Settings"]

    private static func row(_ index: Int) -> TextBox {
        TextBox(left: 20 / 400.0, top: Double(20 + 40 * index) / 300.0, right: 200 / 400.0, bottom: Double(50 + 40 * index) / 300.0)
    }

    private static func pause(_ selected: Int) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: 400 * 300 * 4)
        for y in 0..<300 {
            for x in 0..<400 {
                let row = (y - 20) / 40
                let inRow = y >= 20 && (y - 20) % 40 < 30 && row < pauseRows.count && (20..<200).contains(x)
                let chosen = inRow && row == selected
                let ink = inRow && (10..<20).contains((y - 20) % 40) && x % 6 < 2
                let value: UInt8 = chosen ? (ink ? 20 : 225) : ink ? 235 : 30
                let p = (y * 400 + x) * 4
                (pixels[p], pixels[p + 1], pixels[p + 2]) = (value, value, value)
            }
        }
        return ScreenTextDetectorTests.image(pixels, width: 400, height: 300)
    }

    private static func light(_ hex: String) -> Bool { Int(hex.dropFirst().prefix(2), radix: 16)! > 128 }

    func testEachRowHasItsOwnSurfaceAndMovingTheSelectionOnlyRecolours() async throws {
        let reader = Reader(), translator = Batch(), server = Server()
        reader.lines = Self.pauseRows.enumerated().map { TextLine($1, box: Self.row($0)) }
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        watcher.translatesUiCommands = true
        await watcher.pass(Self.pause(2), areas: [area])
        await watcher.pass(Self.pause(2), areas: [area])
        let first = try XCTUnwrap(server.blocks.last { $0 != nil } ?? nil)
        XCTAssertEqual(first.count, 6)
        XCTAssertTrue(Self.light(try XCTUnwrap(first[2].style).background))
        for (index, block) in first.enumerated() where index != 2 { XCTAssertFalse(Self.light(block.style!.background)) }
        // Satırların hepsi arayüz sözlüğünde: motora istek gitmez; karışık harfli özgün normal Türkçe kalır.
        XCTAssertEqual(translator.requests, 0)
        XCTAssertEqual(first[0].translation, "Harita")
        XCTAssertEqual(first[1].translation, "Oyun")

        await watcher.pass(Self.pause(3), areas: [area])
        await watcher.pass(Self.pause(3), areas: [area])
        XCTAssertEqual(translator.requests, 0)
        let moved = try XCTUnwrap(server.blocks.last { $0 != nil } ?? nil)
        XCTAssertFalse(Self.light(moved[2].style!.background))
        XCTAssertTrue(Self.light(moved[3].style!.background))
        XCTAssertEqual(first.map(\.translation), moved.map(\.translation))
    }

    // --- (b) Kontrol şeması: sağa yaslı tuş etiketleri, sola yaslı simgeli etiketler, sayaçlar ---

    private static func label(_ text: String, _ left: Double, _ right: Double, _ row: Int) -> TextLine {
        TextLine(text, box: TextBox(left: left, top: 0.04 + Double(row) * 0.04, right: right, bottom: 0.07 + Double(row) * 0.04))
    }

    private static func scheme() -> [TextLine] {
        var lines = [
            label("CONTROL SCHEME", 0.05, 0.25, 0), label("PREVIEW", 0.6, 0.7, 0),
            label("Default 1 / 3", 0.05, 0.2, 1), label("On Foot", 0.05, 0.15, 2), label("Land / Water Vehicles", 0.05, 0.28, 3),
            label("5 / 9", 0.05, 0.1, 4),
            label("HOLSTER (L1)", 0.32, 0.45, 5), label("AIM / INTERACT (L2)", 0.28, 0.45, 6), label("RUN (L3)", 0.38, 0.45, 7),
            label("(△) INTERACT", 0.55, 0.66, 5), label("(✕) JUMP / CLIMB", 0.55, 0.7, 6),
            label("RESTORE DEFAULT (□)", 0.05, 0.22, 20), label("SELECT (✕)", 0.3, 0.4, 20), label("BACK (○)", 0.45, 0.53, 20),
        ]
        let more = ["MELEE", "RELOAD", "SPRINT", "CROUCH", "COVER", "WHISTLE", "SWAP WEAPON", "THROW", "PHONE", "RADIO",
                    "HORN", "HANDBRAKE", "LOOK BEHIND", "HEADLIGHTS"]
        for (i, text) in more.enumerated() {
            lines.append(label(text + " (R\(1 + i % 3))", 0.3 - Double(i % 2) * 0.02, 0.45, 8 + i % 11))
        }
        return lines
    }

    func testLabelsAlignByTheirNeighboursAndKeepButtonNames() throws {
        let candidate = RegionWatcher.candidate(Reading(lines: Self.scheme()), in: CropRegion(top: 0, bottom: 1, left: 0, right: 1),
                                                frame: Self.pause(-1), auto: true)
        let blocks = try XCTUnwrap(candidate.blocks)
        func align(_ text: String) -> TextLook.Align? {
            blocks.first { candidate.paragraphs[$0.start] == text }?.look?.align
        }
        XCTAssertEqual(align("HOLSTER (L1)"), .right)
        XCTAssertEqual(align("(△) INTERACT"), .left)
        XCTAssertFalse(candidate.paragraphs.contains("5 / 9"))

        typealias Part = RegionWatcher.LabelPart
        XCTAssertEqual(RegionWatcher.splitLabel("HOLSTER (L1)"), [Part(prefix: "", core: "HOLSTER", suffix: " (L1)")])
        XCTAssertEqual(RegionWatcher.splitLabel("AIM / INTERACT (L2)"),
                       [Part(prefix: "", core: "AIM", suffix: ""), Part(prefix: "", core: "INTERACT", suffix: " (L2)")])
        XCTAssertEqual(RegionWatcher.splitLabel("(△) INTERACT"), [Part(prefix: "(△) ", core: "INTERACT", suffix: "")])
        XCTAssertEqual(RegionWatcher.splitLabel("Default 1 / 3"), [Part(prefix: "", core: "Default", suffix: " 1 / 3")])
    }

    func testWholeSchemeIsOneBatchAndReturningCostsNothing() async throws {
        let reader = Reader(), translator = Batch(), server = Server()
        reader.lines = Self.scheme()
        let watcher = RegionWatcher(reader: reader, translator: translator, server: server)
        watcher.translatesUiCommands = true
        await watcher.pass(Self.pause(-1), areas: [area])
        await watcher.pass(Self.pause(-1), areas: [area])
        XCTAssertEqual(translator.requests, 1)
        XCTAssertGreaterThanOrEqual(translator.texts.count, 20)
        // Tuş adları ve sayaçlar çeviriye gitmez, sözlükteki etiketler de ("SELECT", "BACK").
        XCTAssertFalse(translator.texts.contains { $0.contains("(L1)") || $0.contains("1 / 3") || $0 == "SELECT" || $0 == "BACK" })
        let sent = try XCTUnwrap(server.blocks.last { $0 != nil } ?? nil)
        func translation(_ source: String) -> String? { sent.first { $0.source == source }?.translation }
        XCTAssertTrue(translation("HOLSTER (L1)")?.hasSuffix(" (L1)") == true)
        XCTAssertTrue(translation("AIM / INTERACT (L2)")?.contains(" / ") == true)
        XCTAssertEqual(translation("SELECT (✕)"), "SEÇ (✕)")

        // Menü kapandı, yeniden açıldı: hepsi oturum önbelleğinden.
        var again = area
        again.id = "auto-7"
        await watcher.pass(Self.pause(-1), areas: [])
        await watcher.pass(Self.pause(-1), areas: [again])
        await watcher.pass(Self.pause(-1), areas: [again])
        XCTAssertEqual(translator.requests, 1)
    }
}
