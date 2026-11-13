// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SubtitleStabilizerTests: XCTestCase {
    /// Noktalamayla bitmeyen satır yazılmakta olabilir; iki kare aynı okununca gönderilir.
    func testUnfinishedLineIsSentAfterTwoStableFrames() {
        var s = SubtitleStabilizer()
        XCTAssertEqual(s.feed("We do not have time"), .none)
        XCTAssertEqual(s.feed("We do not have time"), .translate("We do not have time"))
        XCTAssertEqual(s.feed("We do not have time"), .none)
    }

    /// Cümle bitmişse beklemeye gerek yok; hızlı konuşmada her kare önemli.
    func testFinishedSentenceIsSentOnFirstFrame() {
        for line in ["We do not have time.", "Wait!", "Who are you?", "I know…", "\"Run.\""] {
            var s = SubtitleStabilizer()
            XCTAssertEqual(s.feed(line), .translate(line), line)
            XCTAssertEqual(s.feed(line), .none, line)
        }
    }

    /// Noktayla biten çöp okuma (altyazılar geçişte üst üste solarken) ilk karede çevrilmez; ardından gelen düzgün
    /// okuma çevrilir.
    func testGarbledSentenceIsNotSentOnFirstFrame() {
        var s = SubtitleStabilizer()
        XCTAssertEqual(s.feed("Gtt solkolfege."), .none)
        XCTAssertEqual(s.feed("Go to college."), .translate("Go to college."))
    }

    /// Altyazılar geçişte üst üste solarken birkaç kare aynı çöp okunabiliyor (GTA V, #26): geçiş süresince çevrilmez,
    /// gerçekten öyle duran yazı ise sonunda çevrilir.
    func testGarbledLineIsSentOnlyAfterStayingLongerThanACrossfade() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        let garbled = "- Nat) but, you knpw. shit, I m"
        for _ in 0..<5 {
            XCTAssertEqual(s.feed(garbled), .none)
            clock.now += 100
        }
        clock.now += SubtitleStabilizer.garbledStableMs
        XCTAssertEqual(s.feed(garbled), .translate(garbled))
    }

    func testOcrNoiseDoesNotReemit() {
        var s = SubtitleStabilizer()
        _ = s.feed("The gate will not hold"); _ = s.feed("The gate will not hold")
        XCTAssertEqual(s.feed("The gale will not hold"), .none)
        XCTAssertEqual(s.feed("The gale will not hold"), .none)
    }

    /// Süslü yazıda aynı cümle her karede başka çöple okunur; TV'de iki çeviri olarak görünmemeli.
    func testGarbledRereadOfSentLineDoesNotReemit() {
        var s = SubtitleStabilizer()
        let first = "Across the deep waters, Pbo ou$3e went, hoping a boat would carry him home."
        XCTAssertEqual(s.feed(first), .translate(first))
        XCTAssertEqual(s.feed("Across the deep waters2aljd O went, Hoping a boat would carry him home."), .none)
        XCTAssertEqual(s.feed("Across the deep waters2aljd O went, Hoping a boat would carry him home."), .none)
        XCTAssertEqual(s.feed("Across the deep waters, he went."), .translate("Across the deep waters, he went."))
    }

    /// Açık zeminde (GTA V, #26) aynı cümle her karede bir iki sözcüğü eksik ya da başka okunuyordu; her okuma ayrı
    /// çevrilip TV'de üç çeviri üst üste duruyordu. Daha kötü okuma yeni satır sayılmaz, eskisiyle gidip gelmesi de.
    func testWorseRereadOfSentLineIsNotTranslatedAgain() {
        var s = SubtitleStabilizer()
        let full = "Shit, I just came by to see if there's somethin' I can help you with."
        let worse = "Shit, I came by to see if there somethinl I can help ya."
        XCTAssertEqual(s.feed(full), .translate(full))
        XCTAssertEqual(s.feed(worse), .none)
        XCTAssertEqual(s.feed(full), .none)
        XCTAssertEqual(s.feed(worse), .none)
    }

    /// Önce eksik okunan cümlenin daha çok sözcüklü okuması gelirse yeniden çevrilir (TV eskisinin yerine koyar).
    func testBetterRereadOfSentLineIsTranslated() {
        var s = SubtitleStabilizer()
        let full = "Shit, I just came by to see if there's somethin' I can help you with."
        let worse = "Shit, I came by to see if there somethinl I can help ya."
        XCTAssertEqual(s.feed(worse), .translate(worse))
        XCTAssertEqual(s.feed(full), .translate(full))
        XCTAssertEqual(s.feed(worse), .none)
    }

    func testFlickeringHudDoesNotSpam() {
        var s = SubtitleStabilizer()
        var sent = 0
        for i in 0..<20 { if case .translate = s.feed(i % 2 == 0 ? "24 / 120" : "") { sent += 1 } }
        XCTAssertEqual(sent, 0)
    }

    func testTypewriterSendsCompletedLine() {
        var s = SubtitleStabilizer()
        _ = s.feed("We do"); _ = s.feed("We do not have")
        XCTAssertEqual(s.feed("We do not have time for this, boy."), .translate("We do not have time for this, boy."))
        XCTAssertEqual(s.feed("We do not have time for this, boy."), .none)
    }

    /// Altyazının kalktığına okuma sayısıyla değil süreyle karar verilir: bölge 800 ms boş kalınca silinir.
    func testEmptyRegionClearsAfterClearTime() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hello there"); _ = s.feed("Hello there")
        XCTAssertEqual(s.feed(""), .none)
        clock.now += SubtitleStabilizer.clearAfterMs - 1
        XCTAssertEqual(s.feed(""), .none)
        clock.now += 1
        XCTAssertEqual(s.feed(""), .clear)
        XCTAssertEqual(s.feed(""), .none)
    }

    /// Parlak arka planda okuma birkaç kare kaçar; 800 ms'den kısa boşluk ne siler ne yeniden gönderir.
    func testShortFlickerNeitherClearsNorResends() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate")
        XCTAssertEqual(s.feed("Hold the gate"), .translate("Hold the gate"))
        for _ in 0..<3 {
            for _ in 0..<10 { clock.now += 50; XCTAssertEqual(s.feed(""), .none) }
            for _ in 0..<4 { clock.now += 50; XCTAssertEqual(s.feed("Hold the gate"), .none) }
        }
    }

    /// Kalkan satır 1,5 sn içinde geri gelirse yeniden çevrilmez; çevirisi yeniden gösterilsin diye restore döner.
    func testLineReturningSoonAfterClearIsRestored() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        XCTAssertEqual(s.feed("Hold the gate."), .translate("Hold the gate."))
        _ = s.feed("")
        clock.now += SubtitleStabilizer.clearAfterMs
        XCTAssertEqual(s.feed(""), .clear)
        clock.now += SubtitleStabilizer.restoreWithinMs
        XCTAssertEqual(s.feed("Hold the gate"), .none)
        XCTAssertEqual(s.feed("Hold the gate"), .restore("Hold the gate."))
        XCTAssertEqual(s.feed("Hold the gate."), .none)
        // Geri gelen satır da kalkınca silinir.
        _ = s.feed("")
        clock.now += SubtitleStabilizer.clearAfterMs
        XCTAssertEqual(s.feed(""), .clear)
    }

    /// Daha geç gelen aynı satır gerçek bir tekrardır (oyunda aynı söz yeniden söylendi); yeniden çevrilir.
    func testLineReturningLaterIsTranslatedAgain() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate.")
        _ = s.feed("")
        clock.now += SubtitleStabilizer.clearAfterMs
        XCTAssertEqual(s.feed(""), .clear)
        clock.now += SubtitleStabilizer.restoreWithinMs + 1
        XCTAssertEqual(s.feed("Hold the gate."), .translate("Hold the gate."))
    }

    /// Okuma iki satır arasında gidip gelirse (yerine başkası geldi, sonra geri döndü) eski satır yeniden çevrilmez.
    func testReplacedLineComingBackIsRestored() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        XCTAssertEqual(s.feed("Hold the gate."), .translate("Hold the gate."))
        clock.now += 100
        XCTAssertEqual(s.feed("Run!"), .translate("Run!"))
        clock.now += 100
        XCTAssertEqual(s.feed("Hold the gate."), .restore("Hold the gate."))
        clock.now += 100
        XCTAssertEqual(s.feed("Run!"), .restore("Run!"))
    }

    /// İki konuşmacı neredeyse aynı sözleri söylüyor; ikinci satır da çevrilmeli.
    func testTwoSpeakersWithOverlappingWordsAreBothTranslated() {
        let pairs = [
            ("Where are you going?", "Where are you going, boy?"),
            ("Where are you going, boy?", "Where are you going?"),
            ("We need to leave this place before the sun goes down.", "We need to leave this place before the sun goes down, boy."),
        ]
        for (first, second) in pairs {
            let clock = TestClock()
            var s = SubtitleStabilizer(clock: clock.read)
            XCTAssertEqual(s.feed(first), .translate(first))
            clock.now += 50
            XCTAssertEqual(s.feed(second), .translate(second), "\(first) / \(second)")
        }
    }

    func testAlreadyTranslatedIsSkipped() {
        var s = SubtitleStabilizer()
        XCTAssertFalse(s.shouldSend(source: "Kullanıcı Ekle Oturum Açtı", translation: "Kullanıcı Ekle Oturum Açtı"))
        XCTAssertTrue(s.shouldSend(source: "Add user", translation: "Kullanıcı ekle"))
    }

    func testResetClearsOnlyAfterSomethingWasSent() {
        var s = SubtitleStabilizer()
        XCTAssertEqual(s.reset(), .none)
        _ = s.feed("Hello there"); _ = s.feed("Hello there")
        XCTAssertEqual(s.reset(), .clear)
        XCTAssertEqual(s.reset(), .none)
    }
}

final class SubtitleStabilizerRetryTests: XCTestCase {
    /// Çevirisi başarısız olan satır ekranda kaldıkça yeniden denenebilmeli; ama saniyede en çok bir kez.
    func testForgottenLineIsTranslatedAgainAfterBackoff() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate")
        XCTAssertEqual(s.feed("Hold the gate"), .translate("Hold the gate"))
        s.forgetSent()
        for _ in 0..<19 { clock.now += 50; XCTAssertEqual(s.feed("Hold the gate"), .none) }
        clock.now += 50
        XCTAssertEqual(s.feed("Hold the gate"), .translate("Hold the gate"))
    }

    /// Bekleme yalnız başarısız satır için: başka bir satır hemen çevrilir.
    func testBackoffDoesNotDelayANewLine() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate"); _ = s.feed("Hold the gate")
        s.forgetSent()
        XCTAssertEqual(s.feed("Run!"), .translate("Run!"))
    }

    /// Günlük için: kararlı olmadan kalkan çöp okuma ve yok sayılan kötü yeniden okuma not edilir; kararlar değişmez.
    func testNotesGarbledDropAndWorseReread() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        let garbled = "- Nat) but, you knpw. shit, I m"
        XCTAssertEqual(s.feed(garbled), .none)
        XCTAssertNil(s.note)
        clock.now += 100
        XCTAssertEqual(s.feed(""), .none)
        XCTAssertEqual(s.note, .garbledDropped(garbled))
        XCTAssertEqual(s.feed(""), .none)
        XCTAssertNil(s.note)

        let full = "Shit, I just came by to see if there's somethin' I can help you with."
        let worse = "Shit, I came by to see if there somethinl I can help ya."
        XCTAssertEqual(s.feed(full), .translate(full))
        XCTAssertNil(s.note)
        _ = s.feed(worse)
        let second = s.feed(worse)
        XCTAssertEqual(second, .none)
        XCTAssertEqual(s.note, .worseReread(worse))
    }
}

/// Parlak zeminde beyaz altyazı (It Takes Two, 2026-11-13): yazı tanıma ekranda duran altyazıyı saniyelerce okuyamıyor,
/// TV'deki Türkçe siliniyordu. Boş okumada satırın yeri (bölge izi) son okunduğu kareyle karşılaştırılır (Windows: aynı testler).
final class SubtitleStabilizerHoldTests: XCTestCase {
    /// Altyazının bölgedeki yeri.
    private let place = TextBox(left: 0.3, top: 0.6, right: 0.7, bottom: 0.85)

    /// Bölge izi (64 × 12 gri örnek).
    private func scene(_ change: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var signature = [UInt8](repeating: 120, count: ReadScheduler.signatureWidth * ReadScheduler.signatureHeight)
        change(&signature)
        return signature
    }

    /// Altyazının yerine düşen bir örnek (satır 8, sütun 30).
    private func subtitleSpot(_ s: inout [UInt8], _ delta: Int) {
        s[8 * ReadScheduler.signatureWidth + 30] = UInt8(120 + delta)
    }

    /// Satırın yeri son okunduğu kareden beri değişmediyse (bölgenin başka yerindeki kıpırtı ve video gürültüsü
    /// sayılmaz) boş okumalar satırı silmez; yeniden okununca da yeniden çevrilmez.
    func testLineIsKeptThroughMissedReadsWhileItsPlaceIsUnchanged() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        XCTAssertEqual(s.feed("Hold the gate.", signature: scene(), box: place), .translate("Hold the gate."))
        let moving = scene { $0[0] = 250; $0[5] = 10; self.subtitleSpot(&$0, 10) }
        for _ in stride(from: 0, to: 3000, by: 50) {
            clock.now += 50
            XCTAssertEqual(s.feed("", signature: moving), .none)
        }
        XCTAssertEqual(s.feed("Hold the gate.", signature: scene(), box: place), .none)
        // Okunduktan sonra yine kaçarsa süre baştan sayılır.
        for _ in stride(from: 0, to: 3000, by: 50) {
            clock.now += 50
            XCTAssertEqual(s.feed("", signature: scene()), .none)
        }
    }

    /// Altyazı gerçekten kalkınca (yeri değişti) satır her zamanki sürede silinir.
    func testLineIsClearedOnTimeWhenItsPlaceChanges() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate.", signature: scene(), box: place)
        let gone = scene { self.subtitleSpot(&$0, 60) }
        XCTAssertEqual(s.feed("", signature: gone), .none)
        clock.now += SubtitleStabilizer.clearAfterMs - 1
        XCTAssertEqual(s.feed("", signature: gone), .none)
        clock.now += 1
        XCTAssertEqual(s.feed("", signature: gone), .clear)
    }

    /// Okuma bir süre kaçtıktan sonra satırın yeri değişirse silinme o andan itibaren her zamanki sürede olur.
    func testHeldLineIsClearedOnTimeOnceItsPlaceChanges() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate.", signature: scene(), box: place)
        clock.now += 2000
        XCTAssertEqual(s.feed("", signature: scene()), .none)
        clock.now += 1000
        XCTAssertEqual(s.feed("", signature: scene { self.subtitleSpot(&$0, -60) }), .none)
        clock.now += SubtitleStabilizer.clearAfterMs - 1
        XCTAssertEqual(s.feed("", signature: scene()), .none)
        clock.now += 1
        XCTAssertEqual(s.feed("", signature: scene()), .clear)
    }

    /// Yeri hiç değişmese de boş okunan satır en çok `holdUnchangedMs` tutulur.
    func testUnchangedPlaceHoldsTheLineOnlyForALimitedTime() {
        let clock = TestClock()
        var s = SubtitleStabilizer(clock: clock.read)
        _ = s.feed("Hold the gate.", signature: scene(), box: place)
        XCTAssertEqual(s.feed("", signature: scene()), .none)
        clock.now += SubtitleStabilizer.holdUnchangedMs - 1
        XCTAssertEqual(s.feed("", signature: scene()), .none)
        clock.now += 1
        XCTAssertEqual(s.feed("", signature: scene()), .clear)
    }

    /// Satırın yeri bilinmiyorsa (okuyucu kutu vermedi) ya da kare izi yoksa eski kural: 800 ms boşlukta silinir.
    func testWithoutPlaceOrSignatureEmptyReadsClearAsBefore() {
        for (signature, box) in [(scene(), nil), (nil, place)] as [([UInt8]?, TextBox?)] {
            let clock = TestClock()
            var s = SubtitleStabilizer(clock: clock.read)
            _ = s.feed("Hold the gate.", signature: signature, box: box)
            _ = s.feed("", signature: signature)
            clock.now += SubtitleStabilizer.clearAfterMs
            XCTAssertEqual(s.feed("", signature: signature), .clear)
        }
    }
}

/// Testlerde elle ilerletilen saat (milisaniye).
final class TestClock: @unchecked Sendable {
    var now = 1_000_000
    func read() -> Int { now }
}
