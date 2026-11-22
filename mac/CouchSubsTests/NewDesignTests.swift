// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

/// Yeni arayüzün mantık parçaları: tasarım değerleri, sürüm notları, altyazı görünümü eşlemeleri, hazır bekleme değerleri.
@MainActor
final class NewDesignTests: XCTestCase {
    /// tasarim.json uygulama paketinde ve okunuyor (eksikse açılışta çökerdi).
    func testDesignTokensLoad() {
        XCTAssertEqual(DS.size("windowWidth"), 1200)
        XCTAssertEqual(DS.size("windowHeight"), 760)
        XCTAssertNotNil(DS.tokens.color["amber"])
        XCTAssertEqual(DSTokens.rgba("#F5B83D33")?.3 ?? 0, 0.2, accuracy: 0.01)
    }

    func testReleaseNotesParseCurrentAndPrevious() {
        let text = """
        Giriş.

        **Bu sürümde yeni** (yalnız hata düzeltmeleri)

        - **Android TV'de siyah ekran**: Görüntü modu Otomatik.
        - **Güncelleme penceresi:** Yalnız yeni notlar.

        **beta.83'te gelenler:** GTA 6 telefon mesajları, haber bandı (#933), Samsung'da AS400 uyarısı düzeltmesi.
        """
        let notes = ReleaseNotes.parse(text)
        XCTAssertEqual(notes.current, ["Android TV'de siyah ekran: Görüntü modu Otomatik.", "Güncelleme penceresi: Yalnız yeni notlar."])
        XCTAssertEqual(notes.previous.count, 3)
        XCTAssertEqual(notes.previous.first, "GTA 6 telefon mesajları.")
        // Uygulamayla gelen dosya da okunuyor.
        XCTAssertFalse(ReleaseNotes.load().current.isEmpty)
    }

    /// 16–50 kaydırıcısı TV yazı boyuna (16–90) doğrusal eşlenir; uçlar korunur, varsayılan 46 ≈ 30.
    func testTextSizeMapping() {
        XCTAssertEqual(SubtitlePalette.fontSize(16), 16)
        XCTAssertEqual(SubtitlePalette.fontSize(50), 90)
        XCTAssertEqual(SubtitlePalette.display(90), 50)
        XCTAssertEqual(SubtitlePalette.display(46), 30)
        for value in 16...50 { XCTAssertEqual(SubtitlePalette.display(SubtitlePalette.fontSize(value)), value) }
    }

    func testLowContrastWarning() {
        var style = SubtitleStyle()
        style.textHex = "#FFFFFF"
        XCTAssertFalse(SubtitlePalette.lowContrast(style))
        style.textHex = "#111114"
        XCTAssertTrue(SubtitlePalette.lowContrast(style))
        style.backgroundColor = "#FFFFFF"
        style.background = 100
        XCTAssertFalse(SubtitlePalette.lowContrast(style))
    }

    /// Hızlı / Dengeli / Doğru mevcut iki beklemenin hazır değerleridir; Dengeli varsayılandır.
    func testTranslationPacePresets() {
        XCTAssertEqual(TranslationPace.of(UserSettings()), .balanced)
        var settings = UserSettings()
        settings.misreadWaitMs = 400
        settings.partialWaitMs = 0
        XCTAssertEqual(TranslationPace.of(settings), .fast)
        settings.partialWaitMs = 123
        XCTAssertNil(TranslationPace.of(settings))
    }

    func testSpeakerSplit() {
        let split = SpeakerSplit("Jason: Tamam. Gidelim.")
        XCTAssertEqual(split.speaker, "Jason:")
        XCTAssertEqual(split.line, "Tamam. Gidelim.")
        XCTAssertNil(SpeakerSplit("Gel buraya.").speaker)
    }

    /// Denetimler her maddeyi döner; PS5 bulunamadıysa "PS5 Yanıt Veriyor" sorunlu, Uzaktan Oynama hep bilinmiyor.
    func testSetupChecksNeverGuess() {
        let checks = SetupCheck.run(consoles: [])
        XCTAssertEqual(checks.map(\.kind), SetupCheck.Kind.allCases)
        XCTAssertEqual(checks.first { $0.kind == .ps5Responds }?.state, .problem)
        XCTAssertEqual(checks.first { $0.kind == .remotePlay }?.state, .unknown)
        XCTAssertEqual(checks.first { $0.kind == .restModeInternet }?.state, .unknown)
    }
}
