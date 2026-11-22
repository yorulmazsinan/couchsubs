// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

/// GTA 6: görev yazısı konuşma altyazısının altında dakikalarca durur; altyazı onda takılı kalıyordu.
final class StickyRowsTests: XCTestCase {
    private let objective = "Stash the acid in Brian's lockup"

    func testObjectiveUnderChangingDialogueIsDropped() {
        var rows = StickyRows()
        XCTAssertEqual(rows.filter(Reading(text: objective), at: 0).text, objective)
        // Görev konuşmadan 3 sn önce geldi: henüz sabit değil ama konuşmaya karışmaz (lingerMs).
        XCTAssertEqual(rows.filter(Reading(text: "Yeah!\n" + objective), at: 3000).text, "Yeah!")
        // Görev 6 sn'dir ekranda, konuşma ondan 3 sn sonra geldi: görev sabit sayılır.
        XCTAssertEqual(rows.filter(Reading(text: "Yeah!\n" + objective), at: 6000).text, "Yeah!")
        XCTAssertEqual(rows.newlySticky, [objective])
        XCTAssertEqual(rows.filter(Reading(text: "Okay.\n" + objective), at: 7000).text, "Okay.")
        // Konuşma kalktı, görev tek başına kaldı: TV'de eski konuşma kalmasın diye görev de okunmaz.
        XCTAssertEqual(rows.filter(Reading(text: objective), at: 9000).text, "")
        XCTAssertEqual(rows.filter(Reading(text: "Get in the sea plane"), at: 9500).text, "Get in the sea plane")
    }

    /// Konuşan adıyla başlayan satır uzun süre ekranda kalsa da görev/HUD sayılmaz (Windows, Android ile aynı).
    func testSpeakerLineIsNeverSticky() {
        var rows = StickyRows()
        let named = "JASON: I don't like this place."
        XCTAssertEqual(rows.filter(Reading(text: named), at: 0).text, named)
        XCTAssertEqual(rows.filter(Reading(text: "Yeah!\n" + named), at: 6000).text, "Yeah!\n" + named)
        XCTAssertEqual(rows.newlySticky, [])
        XCTAssertEqual(rows.filter(Reading(text: named), at: 9000).text, named)
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

    func testOlderRowAtEdgeIsKeptOutOfNewDialogue() {
        var rows = StickyRows()
        XCTAssertEqual(rows.filter(Reading(text: objective + "\nI told you already."), at: 0).text,
                       objective + "\nI told you already.")
        // Görev üstte de olsa (altyazının üstünde duran görev) yeni konuşmaya karışmaz.
        XCTAssertEqual(rows.filter(Reading(text: objective + "\nWe have to go."), at: 1500).text, "We have to go.")
        // Konuşan adlı satır eski olsa da çıkarılmaz.
        var named = StickyRows()
        _ = named.filter(Reading(text: "Lucia: Wait for me."), at: 0)
        XCTAssertEqual(named.filter(Reading(text: "Lucia: Wait for me.\nOkay."), at: 2000).text, "Lucia: Wait for me.\nOkay.")
        // Görev tek başına kalınca (henüz sabit değilken) okunur.
        var alone = StickyRows()
        _ = alone.filter(Reading(text: objective), at: 0)
        XCTAssertEqual(alone.filter(Reading(text: objective), at: 3000).text, objective)
    }

    /// Kullanıcı bildirimi (X, beta.69, GTA 6): konuşma ekrandayken altına "Follow John" görevi geldi; eski kural konuşmayı
    /// (eski satır) görev sanıp atıyor, görevi altyazı olarak gönderiyordu.
    func testObjectiveAddedUnderTheDialogueIsDroppedNotTheDialogue() {
        let dialogue = "I can't believe he's still alive after all that."
        var rows = StickyRows()
        XCTAssertEqual(rows.filter(Reading(text: dialogue), at: 0).text, dialogue)
        XCTAssertEqual(rows.filter(Reading(text: dialogue + "\nFollow John"), at: 1500).text, dialogue)
        XCTAssertEqual(rows.removed.map(\.text), ["Follow John"])
        XCTAssertEqual(rows.filter(Reading(text: dialogue + "\nFollow John"), at: 3000).text, dialogue)
        // Konuşma değişti, görev kaldı: yeni konuşma çevrilir, görev yine dışarıda.
        XCTAssertEqual(rows.filter(Reading(text: "We need to keep moving.\nFollow John"), at: 4000).text, "We need to keep moving.")
        // Konuşma kalkınca görev tek başına okunur (eskisi gibi).
        XCTAssertEqual(rows.filter(Reading(text: "Follow John"), at: 4500).text, "Follow John")
    }

    /// Eklenen satır görev sayılmaz: yazı yazılır gibi beliren ikinci satır, cümlenin devamı, konuşan adlı, boyu yakın.
    func testDialogueAddedUnderTheDialogueStaysDialogue() {
        var typed = StickyRows()
        _ = typed.filter(Reading(text: "I told you this was a"), at: 0)
        _ = typed.filter(Reading(text: "I told you this was a bad idea."), at: 1000)
        XCTAssertEqual(typed.filter(Reading(text: "I told you this was a bad idea.\nGo."), at: 1500).text,
                       "I told you this was a bad idea.\nGo.")
        var wrapped = StickyRows()
        _ = wrapped.filter(Reading(text: "I told you this was a bad idea,"), at: 0)
        XCTAssertEqual(wrapped.filter(Reading(text: "I told you this was a bad idea,\nbut you never listen."), at: 2000).text,
                       "I told you this was a bad idea,\nbut you never listen.")
        var named = StickyRows()
        _ = named.filter(Reading(text: "We need to keep moving before they find us."), at: 0)
        XCTAssertEqual(named.filter(Reading(text: "We need to keep moving before they find us.\nLucia: Go."), at: 2000).text,
                       "Lucia: Go.")
        var close = StickyRows()
        _ = close.filter(Reading(text: "We need to keep moving."), at: 0)
        XCTAssertEqual(close.filter(Reading(text: "We need to keep moving.\nWe have to go there now."), at: 2000).text,
                       "We have to go there now.")
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
        XCTAssertEqual(translator.requested, [objective, "Yeah!", "Okay."])
    }
}
#endif
