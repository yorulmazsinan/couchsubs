// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// #1443 (beta-108): GTA 6 telefonu karanlık sahnede ~1 sn'de bir kapanıp açılıyor, her kapanışta kutuları siliniyor, görev
/// satırı yolu telefonun mesajlarını okuyordu. Telefon karanlıkta ekranının ışığıyla tutulur (`PhoneGlow`), gerçekten
/// indirilince her zamanki sürede kapanır; telefon açıkken başka yolların telefonun alanındaki satırları bastırılır
/// (`PhoneShield`). Ortak deneme dosyası Fixtures/phone-glow.json (Windows PhoneGlowTests.cs, Android PhoneGlowTest.kt aynı
/// durumları koşar).
final class PhoneGlowTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-glow.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static func doubles(_ value: Any?) -> [Double] { (value as! [NSNumber]).map(\.doubleValue) }
    private static func glow(_ value: Any?) -> PhoneGlow.Glow {
        let v = doubles(value)
        return PhoneGlow.Glow(screen: v[0], ring: v[1])
    }
    private static func region(_ v: [Double]) -> CropRegion { CropRegion(top: v[1], bottom: v[3], left: v[0], right: v[2]) }
    private static func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    func testGlowHoldsOnlyALitScreenInTheDark() throws {
        for item in try vectors()["holds"] as! [[String: Any]] {
            let name = item["name"] as! String
            let recorded = Self.glow(item["recorded"]), current = Self.glow(item["current"])
            XCTAssertEqual(PhoneGlow.lit(current), item["lit"] as! Bool, name)
            XCTAssertEqual(PhoneGlow.holds(recorded, current), item["holds"] as! Bool, name)
        }
    }

    /// Sentetik kare: her yer `background`, ekran kutusu `screen` tonunda (nil: ekran yok).
    private static func frame(width: Int, height: Int, background: Int, screen: Int?, box: [Double]) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ tone: Int, _ rect: CGRect) {
            let v = CGFloat(tone) / 255
            context.setFillColor(red: v, green: v, blue: v, alpha: 1)
            context.fill(rect)
        }
        fill(background, CGRect(x: 0, y: 0, width: width, height: height))
        if let screen {
            // CGContext'in y ekseni aşağıdan yukarı.
            let w = Double(width), h = Double(height)
            fill(screen, CGRect(x: box[0] * w, y: (1 - box[3]) * h, width: (box[2] - box[0]) * w, height: (box[3] - box[1]) * h))
        }
        return context.makeImage()!
    }

    func testDarkPhoneIsHeldByItsScreenAndClosesWhenLowered() throws {
        let vectors = try vectors()
        let scene = vectors["scene"] as! [String: Any]
        let width = (scene["width"] as! NSNumber).intValue, height = (scene["height"] as! NSNumber).intValue
        let p = Self.doubles(scene["pose"]), screenBox = Self.doubles(scene["screenBox"])
        let pose = GamePhoneGeometry.Pose(topX: p[0], topY: p[1], bottomX: p[2], bottomY: p[3])
        for sequence in vectors["sequences"] as! [[String: Any]] {
            let name = sequence["name"] as! String
            let background = (sequence["background"] as! NSNumber).intValue, screen = (sequence["screen"] as! NSNumber).intValue
            let opener = Self.frame(width: width, height: height, background: background, screen: screen, box: screenBox)
            let tracker = GamePhoneTracker(sight: { $0 === opener ? (pose, true) : nil }, glows: true)
            var log: [String] = []
            tracker.onLog = { log.append($0) }
            var t = 0
            var open = false
            for _ in 0..<(sequence["open"] as! NSNumber).intValue {
                open = tracker.sample(opener, now: t).pose != nil
                t += GamePhoneTracker.intervalMs
            }
            XCTAssertTrue(open, "\(name): telefon açılmadı")
            for part in sequence["then"] as! [[String: Any]] {
                let lit = part["frame"] as! String == "lit"
                let image = Self.frame(width: width, height: height, background: (part["background"] as? NSNumber)?.intValue ?? background,
                                       screen: lit ? (part["screen"] as? NSNumber)?.intValue ?? screen : nil, box: screenBox)
                for i in 0..<(part["samples"] as! NSNumber).intValue {
                    open = tracker.sample(image, now: t).pose != nil
                    t += GamePhoneTracker.intervalMs
                    if part["openAll"] as? Bool == true { XCTAssertTrue(open, "\(name): \(i + 1). örnekte kapandı") }
                }
                if let end = part["openAtEnd"] as? Bool { XCTAssertEqual(open, end, "\(name): parçanın sonunda") }
            }
            let text = log.joined(separator: "\n")
            for needle in (sequence["log"] as? [String]) ?? [] { XCTAssertTrue(text.contains(needle), "\(name): günlükte yok: \(needle)\n\(text)") }
            for needle in (sequence["noLog"] as? [String]) ?? [] { XCTAssertFalse(text.contains(needle), "\(name): günlükte var: \(needle)") }
        }
    }

    /// Gerçek karanlık oda karesinde telefonun ekranı ışıklı sayılır; telefonsuz gerçek karelerin aynı yerinde ışık o kaydı
    /// tutmaz (telefon indirilince ışıkla açık kalmaz).
    func testRealDarkRoomScreenIsLitAndNoPhoneFrameHoldsIt() throws {
        let spec = try vectors()["realFrame"] as! [String: Any]
        let phone = try GamePhoneFirstSightingTests.load(spec["frame"] as! String, spec["transform"] as! String)
        let pose = try XCTUnwrap(GamePhoneGeometry.locate(phone))
        let recorded = try XCTUnwrap(GamePhoneGeometry.glow(phone, pose))
        XCTAssertTrue(PhoneGlow.lit(recorded), "\(recorded)")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../testdata/frames/frames.json").standardized)) as! [String: Any]
        let names = (manifest["frames"] as! [[String: Any]]).filter { $0["phone"] == nil }
            .map { ($0["file"] as! String).replacingOccurrences(of: ".jpg", with: "") }
        for name in names.sorted() {
            for transform in spec["transforms"] as! [String] {
                let frame = try GamePhoneFirstSightingTests.fresh(name, transform)
                let current = try XCTUnwrap(GamePhoneGeometry.glow(frame, pose), name)
                XCTAssertFalse(PhoneGlow.holds(recorded, current), "\(name) (\(transform)): \(current)")
            }
        }
    }

    func testShieldDropsOtherRoutesLinesOnThePhone() throws {
        let vectors = try vectors()
        for item in vectors["shield"] as! [[String: Any]] {
            let name = item["name"] as! String
            let lines = (item["lines"] as! [[String: Any]]).map { line in
                TextLine(line["text"] as! String, box: (line["box"] as? [NSNumber]).map { Self.box($0.map(\.doubleValue)) })
            }
            let phone = (item["phone"] as? [NSNumber]).map { Self.region($0.map(\.doubleValue)) }
            let result = PhoneShield.filter(Reading(lines: lines), region: Self.region(Self.doubles(item["region"])), phone: phone)
            let kept = (item["kept"] as! [String])
            XCTAssertEqual(result.kept.lines.map(\.text), kept, name)
            XCTAssertEqual(result.dropped, lines.count - kept.count, name)
        }
        for item in vectors["covers"] as! [[String: Any]] {
            XCTAssertEqual(PhoneShield.covers(Self.box(Self.doubles(item["box"])), phone: Self.region(Self.doubles(item["phone"]))),
                           item["covers"] as! Bool)
        }
    }
}
