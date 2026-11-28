// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// "Yazı kadar" kutu oyundaki altyazının ekrandaki boyu kadar, her yana pay (Windows: OverlayPlacementTests).
final class OverlayCoverTests: XCTestCase {
    func testCoverSizeIsTheSubtitleOnScreenPlusMargin() {
        let box = TextBox(left: 0.25, top: 0.75, right: 0.75, bottom: 0.875)
        XCTAssertEqual(OverlayCover.size(of: box, screen: CGSize(width: 1920, height: 1080), scale: 1), CGSize(width: 976, height: 151))
        // 4K'da (ölçek 2) pay da iki katı.
        XCTAssertEqual(OverlayCover.size(of: box, screen: CGSize(width: 3840, height: 2160), scale: 2), CGSize(width: 1952, height: 302))
    }

    /// Kutu yoksa, boşsa ya da altyazı olamayacak kadar yüksekse kutu eskisi gibi yazı kadar kalır.
    /// "Örtsün"ün güncel satırı her koyulukta tam opak (X, MertTurna19); öbür yerleşimlerde ve önceki satırda koyuluk geçerli.
    func testCoverBoxIsOpaqueAtEveryDarkness() {
        for background in [1, 30, 72, 100] {
            XCTAssertEqual(OverlayCover.boxOpacity(background: background, covering: true, current: true), 1)
        }
        XCTAssertEqual(OverlayCover.boxOpacity(background: 30, covering: false, current: true), 0.3, accuracy: 1e-9)
        XCTAssertEqual(OverlayCover.boxOpacity(background: 100, covering: true, current: false), 0.83, accuracy: 1e-9)
        XCTAssertEqual(OverlayCover.boxOpacity(background: 150, covering: false, current: true), 1)
    }

    /// "Zeminsiz" (koyuluk 0) "Örtsün"de de zemin çizmez (X, beta.105: saydam seçen kullanıcı gri kutu görüyordu).
    func testNoBackgroundIsTransparentInEveryPlacement() {
        for covering in [true, false] {
            for current in [true, false] {
                XCTAssertEqual(OverlayCover.boxOpacity(background: 0, covering: covering, current: current), 0)
                XCTAssertEqual(OverlayCover.boxOpacity(background: -5, covering: covering, current: current), 0)
            }
        }
    }

    /// Ortak vakalar Fixtures/box-opacity.json (Windows OverlayPlacementTests, Android OverlayCoverTest aynı): kutunun opaklığı
    /// ve ayar ekranındaki "Koyuluk" notu. İki kullanıcı (X ve Google Play, beta.107) "zemin koyuluğu ayarlanamıyor" dedi:
    /// "Örtsün"de en yeni satır her koyulukta opak kalır (İngilizce görünmesin), not bunu söyler, önizleme de öyle çizer.
    func testSharedBoxOpacityCases() throws {
        struct Opacity: Decodable { let background: Int; let covering: Bool; let current: Bool; let opacity: Double }
        struct Note: Decodable { let placement: String; let background: Int; let shown: Bool }
        struct Fixture: Decodable { let opacity: [Opacity]; let note: [Note] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/box-opacity.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertFalse(fixture.opacity.isEmpty)
        for item in fixture.opacity {
            XCTAssertEqual(OverlayCover.boxOpacity(background: item.background, covering: item.covering, current: item.current), item.opacity,
                           accuracy: 1e-9, "\(item)")
        }
        for item in fixture.note {
            let placement = try XCTUnwrap(SubtitlePlacement(rawValue: item.placement))
            XCTAssertEqual(OverlayCover.darknessFixedByCover(placement: placement, background: item.background), item.shown, "\(item)")
        }
    }

    func testBoxesThatAreNotASubtitleKeepTheTextSizedBox() {
        let screen = CGSize(width: 1920, height: 1080)
        XCTAssertNil(OverlayCover.size(of: nil, screen: screen, scale: 1))
        XCTAssertNil(OverlayCover.size(of: TextBox(left: 0.4, top: 0.8, right: 0.4, bottom: 0.9), screen: screen, scale: 1))
        XCTAssertNil(OverlayCover.size(of: TextBox(left: 0.2, top: 0.1, right: 0.8, bottom: 0.9), screen: screen, scale: 1))
    }

    /// İki satırlık İngilizce altyazı: kısa Türkçe satırda da kutu altyazının hem genişliğini hem yüksekliğini örter.
    func testCoverSizeCoversATwoLineSubtitle() throws {
        let twoLines = TextBox(left: 0.3, top: 0.8, right: 0.7, bottom: 0.9)
        let size = try XCTUnwrap(OverlayCover.size(of: twoLines, screen: CGSize(width: 1920, height: 1080), scale: 1))
        XCTAssertGreaterThanOrEqual(size.width, 0.4 * 1920)
        XCTAssertGreaterThanOrEqual(size.height, 0.1 * 1080)
    }

    /// Yazı boyu sabit: her satır seçilen boyda; 3 satıra sığmayan satır da küçülmez, sonraki satırlar da (X, beta.89).
    func testCoverFontScaleNeverShrinks() {
        var font = CoverFontScale()
        let short = "Çaldın mı?"
        let long = String(repeating: "Annenin arabası demiştin hani, unuttun mu yoksa? ", count: 4)
        XCTAssertEqual(font.scale(for: short, fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: "Bu cümle iki satıra bölünecek kadar uzun ama üç satıra rahat sığıyor.", fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: long, fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: short, fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: long + long, fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: short, fontSize: 52), 1)
    }

    /// Sabit boyda bölme yazıyı küçültmez; en çok 3 dengeli satır (pencere daha uzununu kendisi böler).
    func testWrapAtAFixedScaleNeverShrinks() {
        let long = String(repeating: "Annenin arabası demiştin hani, unuttun mu yoksa? ", count: 6)
        let wrapped = SubtitleWrap.fit(long, scale: 1)
        XCTAssertEqual(wrapped.scale, 1)
        XCTAssertEqual(wrapped.text.split(separator: "\n").count, 3)
        XCTAssertEqual(SubtitleWrap.fit("Çaldın mı?", scale: 1), SubtitleWrap.Result(text: "Çaldın mı?", scale: 1))
    }
}
