// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import XCTest
@testable import CouchSubsCore

/// "Yazı boyu oyundaki altyazı kadar" (Windows: OverlayPlacementTests.GameTextSizeFollowsTheMedianSubtitleBox).
final class OverlayTextSizeTests: XCTestCase {
    func testGameTextSizeFollowsTheMedianSubtitleBox() {
        // Çoğu tek satır (0,04), biri iki satır (0,1): ortanca tek satırın yüksekliği. 0,95 × 0,04 × 1080 = 41,04.
        XCTAssertEqual(OverlayTextSize.size(boxHeights: [0.04, 0.1, 0.04], screenHeight: 1080, manual: 40), 41.04, accuracy: 1e-6)
        // Ölçüm yoksa seçilen boy; çok büyük ya da küçükse sınırda.
        XCTAssertEqual(OverlayTextSize.size(boxHeights: [], screenHeight: 1080, manual: 40), 40, accuracy: 1e-6)
        XCTAssertEqual(OverlayTextSize.size(boxHeights: [0.2], screenHeight: 1080, manual: 40), 60, accuracy: 1e-6)
        XCTAssertEqual(OverlayTextSize.size(boxHeights: [0.01], screenHeight: 1080, manual: 40), 28, accuracy: 1e-6)
    }

    /// Yazı oyundaki kadar büyüyebildiğinde pencere seçilen boyun %150'sine göre yüksek açılır.
    func testWindowIsTallerWhenTheTextFollowsTheGame() {
        XCTAssertEqual(OverlayTextSize.windowFontSize(SubtitleStyle()), 46)
        XCTAssertEqual(OverlayTextSize.windowFontSize(SubtitleStyle(autoTextSize: true)), 69)
    }
}
