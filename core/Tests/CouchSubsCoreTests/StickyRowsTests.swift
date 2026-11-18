// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

/// GTA 6: görev yazısı konuşma altyazısının altında dakikalarca durur; altyazı onda takılı kalıyordu.
final class StickyRowsTests: XCTestCase {
    private let objective = "Stash the acid in Brian's lockup"

    func testObjectiveUnderChangingDialogueIsDropped() {
        var rows = StickyRows()
        XCTAssertEqual(rows.filter(Reading(text: objective), at: 0).text, objective)
        XCTAssertEqual(rows.filter(Reading(text: "Yeah!\n" + objective), at: 3000).text, "Yeah!\n" + objective)
        // Görev 6 sn'dir ekranda, konuşma ondan 3 sn sonra geldi: görev sabit sayılır.
        XCTAssertEqual(rows.filter(Reading(text: "Yeah!\n" + objective), at: 6000).text, "Yeah!")
        XCTAssertEqual(rows.newlySticky, [objective])
        XCTAssertEqual(rows.filter(Reading(text: "Okay.\n" + objective), at: 7000).text, "Okay.")
        // Konuşma kalktı, görev tek başına kaldı: TV'de eski konuşma kalmasın diye görev de okunmaz.
        XCTAssertEqual(rows.filter(Reading(text: objective), at: 9000).text, "")
        XCTAssertEqual(rows.filter(Reading(text: "Get in the sea plane"), at: 9500).text, "Get in the sea plane")
    }

    func testDialogueBoxWhoseRowsAppearTogetherIsKept() {
        var rows = StickyRows()
        let page = "You can stay here as long as you like.\nThe inn is always open for travelers."
        for time in stride(from: 0, through: 20_000, by: 500) {
            XCTAssertEqual(rows.filter(Reading(text: page), at: time).text, page)
        }
        // Yazı yazılır gibi beliren ikinci satır da birlikte gelmiş sayılır.
        var typed = StickyRows()
        XCTAssertEqual(typed.filter(Reading(text: "Where are you going?"), at: 0).text, "Where are you going?")
        XCTAssertEqual(typed.filter(Reading(text: "Where are you going?\nIt is late."), at: 1000).text, "Where are you going?\nIt is late.")
        XCTAssertEqual(typed.filter(Reading(text: "Where are you going?\nIt is late."), at: 12_000).text, "Where are you going?\nIt is late.")
    }

    func testRowThatLeftIsForgottenAndShownAgain() {
        var rows = StickyRows()
        _ = rows.filter(Reading(text: objective), at: 0)
        _ = rows.filter(Reading(text: "Yeah!\n" + objective), at: 3000)
        XCTAssertEqual(rows.filter(Reading(text: "Yeah!\n" + objective), at: 6000).text, "Yeah!")
        // Kısa okuma kaçağı sabitliği bozmaz.
        _ = rows.filter(Reading.empty, at: 6500)
        XCTAssertEqual(rows.filter(Reading(text: objective), at: 7000).text, "")
        // Görev ekrandan kalktı; yeniden belirince yeni yazıdır.
        _ = rows.filter(Reading.empty, at: 9000)
        XCTAssertEqual(rows.filter(Reading(text: objective), at: 9500).text, objective)
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

private final class StickyReader: TextReader, @unchecked Sendable {
    var texts: [String]
    init(_ texts: [String]) { self.texts = texts }
    func read(_ image: CGImage) throws -> String { texts.isEmpty ? "" : texts.removeFirst() }
}
private final class StickySender: SubtitleSending {
    var sent: [String] = []
    var clears = 0
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() { clears += 1 }
}
private final class StickyTranslator: TextTranslator {
    var requested: [String] = []
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        return "Çeviri " + String(requested.count)
    }
}

@MainActor
final class StickyObjectivePipelineTests: XCTestCase {
    func testDialogueIsNotStuckBehindObjective() async {
        let objective = "Stash the acid in Brian's lockup"
        let frames = Array(repeating: objective, count: 8)
            + Array(repeating: "Yeah!\n" + objective, count: 10)
            + Array(repeating: objective, count: 6)
            + Array(repeating: "Okay.\n" + objective, count: 4)
        var time = 0
        let translator = StickyTranslator(), sender = StickySender()
        let pipeline = SubtitlePipeline(reader: StickyReader(frames), translator: translator, server: sender, clock: { time })
        pipeline.packWait = 0; pipeline.cleanWait = 0
        let image = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        var clearsWhileObjectiveAlone = 0
        for index in frames.indices {
            await pipeline.process(image, region: CropRegion())
            await pipeline.waitForTranslations()
            if index == 23 { clearsWhileObjectiveAlone = sender.clears }
            time += 500
        }
        // Konuşma kalkıp görev tek başına kalınca eski konuşmanın çevirisi TV'den kalkar; yeni kısa konuşma çevrilir.
        XCTAssertGreaterThan(clearsWhileObjectiveAlone, 0)
        XCTAssertEqual(translator.requested, [objective, "Yeah!\n" + objective, "Okay."])
    }
}
#endif
