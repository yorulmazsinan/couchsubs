// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
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

    /// Yazı boyu sabit: kısa ve orta satırda seçilen boy, 3 satıra sığmayan satırda tek kademe (%80); hiç büyümez ve
    /// sonraki kısa satırlarda geri zıplamaz. Yazı boyu değişince kademe sıfırlanır.
    func testCoverFontScaleIsStableAndShrinksOneStepAtMost() {
        var font = CoverFontScale()
        let short = "Çaldın mı?"
        let long = String(repeating: "Annenin arabası demiştin hani, unuttun mu yoksa? ", count: 4)
        XCTAssertEqual(font.scale(for: short, fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: "Bu cümle iki satıra bölünecek kadar uzun ama üç satıra rahat sığıyor.", fontSize: 46), 1)
        XCTAssertEqual(font.scale(for: long, fontSize: 46), CoverFontScale.step)
        XCTAssertEqual(font.scale(for: short, fontSize: 46), CoverFontScale.step)
        XCTAssertEqual(font.scale(for: long + long, fontSize: 46), CoverFontScale.step)
        XCTAssertEqual(font.scale(for: short, fontSize: 52), 1)
    }

    /// Sabit kademeyle bölme yazıyı daha fazla küçültmez; en çok 3 satır.
    func testWrapAtAFixedScaleNeverShrinksFurther() {
        let long = String(repeating: "Annenin arabası demiştin hani, unuttun mu yoksa? ", count: 6)
        let wrapped = SubtitleWrap.fit(long, scale: CoverFontScale.step)
        XCTAssertEqual(wrapped.scale, CoverFontScale.step)
        XCTAssertEqual(wrapped.text.split(separator: "\n").count, 3)
        XCTAssertEqual(SubtitleWrap.fit("Çaldın mı?", scale: 1), SubtitleWrap.Result(text: "Çaldın mı?", scale: 1))
    }

    /// Bilgisayar penceresi 3 satırı 66 karakterle sayar: 150 karakter TV/OBS'te bir kademe küçülür, pencerede seçilen boyda kalır.
    func testDesktopWindowCountsThreeLinesOfSixtySixChars() {
        let text = String(repeating: "Annenin arabası demiştin hani, unuttun mu yoksa? ", count: 3)
        var tv = CoverFontScale()
        var desktop = CoverFontScale()
        XCTAssertEqual(tv.scale(for: text, fontSize: 46), CoverFontScale.step)
        XCTAssertEqual(desktop.scale(for: text, fontSize: 46, maxChars: SubtitleWrap.desktopMaxChars), 1)
        let rows = SubtitleWrap.fit(text, scale: 1, maxChars: SubtitleWrap.desktopMaxChars).text.split(separator: "\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.count <= SubtitleWrap.desktopMaxChars })
    }
}
