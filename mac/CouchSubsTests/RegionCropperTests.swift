// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import XCTest
@testable import CouchSubs

final class RegionCropperTests: XCTestCase {
    private func blankImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    func testDefaultRegionCropsBottomCenterBand() {
        let cropped = RegionCropper.crop(blankImage(width: 1600, height: 1600), to: CropRegion())
        XCTAssertEqual(Double(cropped.width), 1152, accuracy: 1)
        XCTAssertEqual(Double(cropped.height), 560, accuracy: 1)
    }
}
