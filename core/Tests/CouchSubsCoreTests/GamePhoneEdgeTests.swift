// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// #1369 (beta-104, Mac): gevşek doğrulamada (`confirmPicture`) açık telefonun son yeri hoparlör ya da çentik şeridinin
/// dışında kalınca satır aralığı ters kuruluyor, uygulama çöküyordu. Son yer kenarda, dışında, eksi, karenin altını aşan ya
/// da sayı olmayan bir yer olsa da arama nil döner, çökmez. Ortak deneme dosyası Fixtures/phone-near-edges.json (Windows
/// GamePhoneEdgeTests.cs, Android GamePhoneEdgeTest.kt aynı durumları koşar).
final class GamePhoneEdgeTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-near-edges.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func poses() throws -> [GamePhoneGeometry.Pose] {
        var poses = try (vectors()["near"] as! [[NSNumber]]).map {
            GamePhoneGeometry.Pose(topX: $0[0].doubleValue, topY: $0[1].doubleValue, bottomX: $0[2].doubleValue, bottomY: $0[3].doubleValue)
        }
        // JSON'da olmayan sayılar.
        for bad in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            poses.append(.init(topX: 0.5, topY: bad, bottomX: 0.5, bottomY: 0.8))
            poses.append(.init(topX: 0.5, topY: 0.2, bottomX: 0.5, bottomY: bad))
            poses.append(.init(topX: bad, topY: 0.2, bottomX: 0.5, bottomY: 0.8))
            poses.append(.init(topX: 0.5, topY: 0.2, bottomX: bad, bottomY: 0.8))
            poses.append(.init(topX: bad, topY: bad, bottomX: bad, bottomY: bad))
        }
        // Sabit tohumlu rastgele yerler (kenarların çevresi ağırlıklı).
        var seed: UInt64 = 1369
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<150 { poses.append(.init(topX: next() * 3 - 1, topY: next() * 3 - 1, bottomX: next() * 3 - 1, bottomY: next() * 3 - 1)) }
        return poses
    }

    private func image(width: Int, height: Int, tone: (Int, Int) -> UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = tone(x, y), p = (y * width + x) * 4
                (bytes[p], bytes[p + 1], bytes[p + 2]) = (t, t, t)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func testConfirmRowsStayInsideTheBand() throws {
        for item in try vectors()["rows"] as! [[String: Any]] {
            let center = (item["center"] as! NSNumber).doubleValue
            let low = (item["low"] as! NSNumber).intValue, high = (item["high"] as! NSNumber).intValue
            let rows = GamePhoneGeometry.confirmRows(center, within: low, high)
            let expected = (item["rows"] as? [NSNumber])?.map(\.intValue)
            XCTAssertEqual(rows.map { [$0.lowerBound, $0.upperBound] }, expected, "\(center) in \(low)..<\(high)")
        }
        for bad in [Double.nan, .infinity, -.infinity] { XCTAssertNil(GamePhoneGeometry.confirmRows(bad, within: 17, 75)) }
    }

    /// Telefonsuz karede (düz, karanlık: kazançlı geçişler de koşar; 16:9 olmayan pencere) hiçbir son yer telefon bulmaz.
    func testConfirmNearEveryEdgeNeverTraps() throws {
        let frames = [
            image(width: 800, height: 450) { _, _ in 128 },
            image(width: 800, height: 450) { _, _ in 10 },
            image(width: 800, height: 450) { x, y in UInt8((x * 7 + y * 13) % 256) },
            image(width: 800, height: 560) { _, y in y < 80 ? 200 : 90 },
        ]
        let near = try poses()
        for (i, frame) in frames.enumerated() {
            for pose in near {
                let confirmed = GamePhoneGeometry.confirmPicture(frame, near: pose)
                let searched = GamePhoneGeometry.search(frame, near: pose).pose
                // Desenli karede yalnız çökmemesi aranır.
                if i == 2 { continue }
                XCTAssertNil(confirmed, "kare \(i): \(pose)")
                XCTAssertNil(searched, "kare \(i): \(pose)")
            }
        }
    }

    /// Gerçek telefon karesinde kenardaki ve dışarıdaki son yerler çökmez; telefonun kendi yeri yine doğrulanır.
    func testConfirmNearEveryEdgeOnRealPhone() throws {
        let near = try poses()
        for item in try vectors()["frames"] as! [[String: Any]] {
            let frame = try GamePhoneFirstSightingTests.load(item["frame"] as! String, item["transform"] as! String)
            for pose in near { _ = GamePhoneGeometry.confirmPicture(frame, near: pose) }
            let found = try XCTUnwrap(GamePhoneGeometry.search(frame).pose)
            XCTAssertNotNil(GamePhoneGeometry.confirmPicture(frame, near: found))
            // İzleyici açık telefonu kenara taşınmış son yerle de çökmeden örnekler.
            let tracker = GamePhoneTracker()
            _ = tracker.sample(frame, now: 0)
            _ = tracker.sample(frame, now: 330)
        }
    }
}
