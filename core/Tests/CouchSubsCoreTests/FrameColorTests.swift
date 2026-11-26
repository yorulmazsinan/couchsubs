// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// Kullanıcı bildirimi (X, Mac mini, beta-101): aynı kare dosyadan verilince telefon bulunuyor, canlıda bulunmuyordu; kare
/// RGB'ye çevrilince canlıda da bulunuyordu. Aynı sentetik telefon her kare biçiminde (kanal düzeni, alfa, derinlik, renk
/// uzayı) aynı baytlarla okunur ve aynı yerde bulunur (`GamePhonePixels`, `FrameColor`). Windows'ta kare tek biçimde gelir
/// (BGRA; Remote Play karesinde aralık ve matris sws_setColorspaceDetails ile çözülür, pencere yakalama sRGB BGRA);
/// Android aynı telefonu RGB ve sınırlı/tam aralıklı YUV karede dener (FrameColorTest.kt).
final class FrameColorTests: XCTestCase {
    private struct Format {
        let name: String
        let space: CGColorSpace
        let bits: Int
        let info: UInt32
        let tolerance: Int
    }

    private static let formats: [Format] = {
        let premultipliedLast = CGImageAlphaInfo.premultipliedLast.rawValue
        let premultipliedFirst = CGImageAlphaInfo.premultipliedFirst.rawValue
        let skipFirst = CGImageAlphaInfo.noneSkipFirst.rawValue
        let float = CGBitmapInfo.floatComponents.rawValue
        func space(_ name: CFString) -> CGColorSpace { CGColorSpace(name: name)! }
        return [
            Format(name: "sRGB RGBA", space: space(CGColorSpace.sRGB), bits: 8,
                   info: premultipliedLast | CGBitmapInfo.byteOrder32Big.rawValue, tolerance: 0),
            Format(name: "sRGB BGRA (ScreenCaptureKit, VideoToolbox)", space: space(CGColorSpace.sRGB), bits: 8,
                   info: premultipliedFirst | CGBitmapInfo.byteOrder32Little.rawValue, tolerance: 0),
            Format(name: "sRGB BGRX", space: space(CGColorSpace.sRGB), bits: 8,
                   info: skipFirst | CGBitmapInfo.byteOrder32Little.rawValue, tolerance: 0),
            Format(name: "Display P3 BGRA (Mac ekranı)", space: space(CGColorSpace.displayP3), bits: 8,
                   info: premultipliedFirst | CGBitmapInfo.byteOrder32Little.rawValue, tolerance: 2),
            Format(name: "Adobe RGB (ekranın ICC profili, gama 2.2)", space: space(CGColorSpace.adobeRGB1998), bits: 8,
                   info: premultipliedFirst | CGBitmapInfo.byteOrder32Little.rawValue, tolerance: 3),
            Format(name: "doğrusal RGB 8 bit", space: space(CGColorSpace.genericRGBLinear), bits: 8,
                   info: premultipliedLast | CGBitmapInfo.byteOrder32Big.rawValue, tolerance: 12),
            Format(name: "sRGB 16 bit", space: space(CGColorSpace.sRGB), bits: 16,
                   info: premultipliedLast | CGBitmapInfo.byteOrder16Little.rawValue, tolerance: 1),
            Format(name: "genişletilmiş doğrusal sRGB yarım kayan nokta (EDR/HDR)", space: space(CGColorSpace.extendedLinearSRGB),
                   bits: 16, info: premultipliedLast | float | CGBitmapInfo.byteOrder16Little.rawValue, tolerance: 2),
        ]
    }()

    /// Kaynak resim `format`'ta yeniden çizilir (renkler korunur, baytlar biçime göre değişir).
    private func render(_ image: CGImage, as format: Format) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: format.bits,
                                              bytesPerRow: 0, space: format.space, bitmapInfo: format.info), format.name)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage(), format.name)
    }

    private func srgb(_ image: CGImage) throws -> CGImage { try render(image, as: Self.formats[0]) }

    func testSamePixelsInEveryFrameFormat() throws {
        let reference = try srgb(GamePhoneTestFrame.phone())
        let expected = try XCTUnwrap(GamePhonePixels(reference))
        for format in Self.formats {
            let frame = try render(reference, as: format)
            let pixels = try XCTUnwrap(GamePhonePixels(frame), format.name)
            XCTAssertEqual(pixels.bytes.count, expected.bytes.count, format.name)
            var worst = 0
            for i in 0..<pixels.bytes.count { worst = max(worst, abs(Int(pixels.bytes[i]) - Int(expected.bytes[i]))) }
            XCTAssertLessThanOrEqual(worst, format.tolerance, format.name)
            XCTAssertTrue(stride(from: 3, to: pixels.bytes.count, by: 4).allSatisfy { pixels.bytes[$0] == 255 }, format.name)
        }
    }

    func testSamePhoneInEveryFrameFormat() throws {
        let reference = try srgb(GamePhoneTestFrame.phone())
        let expected = try XCTUnwrap(GamePhoneGeometry.search(reference).pose)
        for format in Self.formats {
            let pose = GamePhoneGeometry.search(try render(reference, as: format)).pose
            XCTAssertNotNil(pose, format.name)
            guard let pose else { continue }
            for (a, b) in [(pose.topX, expected.topX), (pose.topY, expected.topY), (pose.bottomX, expected.bottomX),
                           (pose.bottomY, expected.bottomY)] {
                XCTAssertEqual(a, b, accuracy: 0.01, format.name)
            }
        }
    }

    /// Renkli zeminde de (telefon balonu, mavi/yeşil) örnekler sRGB'dir: Display P3 karesindeki mavi sRGB'deki maviyle aynı okunur.
    func testColorsComeBackAsSRGB() throws {
        let colored = GamePhoneTestFrame.image(width: 64, height: 32) { x, _ in x < 32 ? (40, 120, 230) : (60, 200, 90) }
        let reference = try srgb(colored)
        let expected = try XCTUnwrap(GamePhonePixels(reference))
        for format in Self.formats {
            let pixels = try XCTUnwrap(GamePhonePixels(try render(reference, as: format)), format.name)
            var worst = 0
            for i in 0..<pixels.bytes.count { worst = max(worst, abs(Int(pixels.bytes[i]) - Int(expected.bytes[i]))) }
            XCTAssertLessThanOrEqual(worst, max(3, format.tolerance), format.name)
        }
    }

    /// Video karesinin (VideoToolbox, BT.709) ve sRGB/aygıt karesinin baytları değiştirilmez; ekranın uzayı, doğrusal,
    /// derin ya da gri kare sRGB'ye çevrilir.
    func testTargetSpace() throws {
        func image(_ space: CGColorSpace, bits: Int = 8, info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: bits, bytesPerRow: 0,
                                                  space: space, bitmapInfo: info))
            return try XCTUnwrap(context.makeImage())
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        XCTAssertTrue(FrameColor.target(for: try image(srgb)) === srgb)
        let video = CGColorSpace(name: CGColorSpace.itur_709)!
        XCTAssertTrue(FrameColor.target(for: try image(video)) === video)
        let device = CGColorSpaceCreateDeviceRGB()
        XCTAssertTrue(FrameColor.target(for: try image(device)) === device)
        for name in [CGColorSpace.displayP3, CGColorSpace.genericRGBLinear, CGColorSpace.adobeRGB1998] {
            XCTAssertTrue(FrameColor.target(for: try image(CGColorSpace(name: name)!)) === FrameColor.sRGB, name as String)
        }
        XCTAssertTrue(FrameColor.target(for: try image(srgb, bits: 16)) === FrameColor.sRGB)
        let gray = try image(CGColorSpaceCreateDeviceGray(), info: CGImageAlphaInfo.none.rawValue)
        XCTAssertTrue(FrameColor.target(for: gray) === FrameColor.sRGB)
        XCTAssertTrue(FrameColor.describe(try image(srgb)).contains("SRGB"))
    }

    /// Xbox'ın yazılım çözücüsünden gelen gri (Y) kare sınırlı aralıklıdır: tam aralığa açılır.
    func testVideoRangeLumaExpandsToFullRange() {
        XCTAssertEqual(VideoRange.limitedToFull[0], 0)
        XCTAssertEqual(VideoRange.limitedToFull[16], 0)
        XCTAssertEqual(VideoRange.limitedToFull[126], 128)
        XCTAssertEqual(VideoRange.limitedToFull[235], 255)
        XCTAssertEqual(VideoRange.limitedToFull[255], 255)
        var data = Data([16, 126, 235, 200])
        VideoRange.expandLuma(&data)
        XCTAssertEqual([UInt8](data), [0, 128, 255, 214])
    }
}
