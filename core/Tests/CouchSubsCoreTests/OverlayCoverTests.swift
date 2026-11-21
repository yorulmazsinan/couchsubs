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
}
