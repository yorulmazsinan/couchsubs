// SPDX-License-Identifier: AGPL-3.0-only
// Xbox karesinin biçimi ve aralık ölçümü (#1385). Android'deki XboxPhoneFramesTest (XboxLumaRange, kaynak satırı) ile aynı.

import CoreGraphics
import XCTest
@testable import CouchSubsCore

final class XboxFrameFormatTests: XCTestCase {
    /// `width`×`height` Y düzlemi (`stride` aralıklı, aradaki baytlar parlak çöp): noktaların `share`'ı `dark` değerinde.
    private func plane(width: Int, height: Int, stride: Int, base: UInt8, dark: UInt8, darkRows: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 250, count: stride * height)
        for y in 0..<height { for x in 0..<width { bytes[y * stride + x] = y < darkRows ? dark : base } }
        return bytes
    }

    func testLimitedRangeNeverFlipsToFull() {
        let range = XboxLumaRange()
        // Sınırlı aralıkta karanlık sahne: kara 16, kodlayıcı taşmasıyla 12'ye iner.
        let bytes = plane(width: 640, height: 360, stride: 704, base: 16, dark: 12, darkRows: 360)
        for _ in 0..<(XboxLumaRange.votes + 2) {
            bytes.withUnsafeBytes { range.observe($0, width: 640, height: 360, stride: 704) }
        }
        XCTAssertFalse(range.full)
        XCTAssertEqual(range.outsidePerMille, 0, "adımın arasındaki çöp ölçülmez")
    }

    func testFullRangeIsDetectedAfterVotesAndResets() {
        let range = XboxLumaRange()
        // Tam aralıkta gece: karenin üst üçte biri 0–3.
        let bytes = plane(width: 640, height: 360, stride: 704, base: 40, dark: 2, darkRows: 120)
        for vote in 1...XboxLumaRange.votes {
            bytes.withUnsafeBytes { range.observe($0, width: 640, height: 360, stride: 704) }
            XCTAssertEqual(range.full, vote == XboxLumaRange.votes)
        }
        XCTAssertGreaterThan(range.outsidePerMille, 300)
        range.reset()
        XCTAssertFalse(range.full)
    }

    func testFormatTexts() {
        XCTAssertEqual(XboxFrameFormat.i420(width: 1280, height: 720, strideY: 1344, strideU: 704, strideV: 704, full: false),
                       "Xbox I420 1280×720, Y adımı 1344, U/V adımı 704 (ayrı düzlemler, yalnız Y), aralık sınırlı, tam aralığa açılıyor")
        XCTAssertEqual(XboxFrameFormat.i420(width: 1281, height: 721, strideY: 1344, strideU: 704, strideV: 768, full: true),
                       "Xbox I420 1281×721, Y adımı 1344, U/V adımı 704/768 (ayrı düzlemler, yalnız Y), aralık tam, olduğu gibi okunuyor")
        XCTAssertEqual(XboxFrameFormat.pixelBuffer(fourCC: 0x3432_3076, width: 1920, height: 1080, strides: [1920, 1920]),
                       "Xbox VideoToolbox 420v 1920×1080, Y adımı 1920, UV adımı 1920 (iki düzlem), aralık sınırlı")
        XCTAssertEqual(XboxFrameFormat.pixelBuffer(fourCC: 0x3432_3066, width: 1280, height: 720, strides: [1280, 1280]),
                       "Xbox VideoToolbox 420f 1280×720, Y adımı 1280, UV adımı 1280 (iki düzlem), aralık tam")
    }

    /// Durum satırının kare biçimi: Xbox oturumunda kaynak düzeni renk uzayının önünde; oturum bitince yalnız renk uzayı.
    func testStatusLineCarriesTheXboxFormat() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        defer { XboxFrameFormat.update(nil) }
        XboxFrameFormat.update("Xbox I420 1280×720, Y adımı 1344")
        XCTAssertTrue(PhoneSearchStatus.frame(image).hasPrefix("Xbox I420 1280×720, Y adımı 1344, "))
        XboxFrameFormat.update(nil)
        XCTAssertEqual(PhoneSearchStatus.frame(image), FrameColor.describe(image))
    }
}
