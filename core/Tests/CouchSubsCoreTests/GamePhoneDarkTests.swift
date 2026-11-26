// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import XCTest
@testable import CouchSubsCore

/// Karanlık sahnede ve koyu ekranlı GTA 6 telefonu (X, beta.104: "telefonda parlaklık varsa çeviri oluyor karanlıksa
/// olmuyor"). Ortak deneme dosyası Fixtures/phone-dark.json (Windows GamePhoneDarkTests.cs, Android GamePhoneDarkTest.kt
/// aynı durumları koşar); telefonsuz karelerin karanlık hâlleri phone-first-sighting.json'da (`noPhone`).
final class GamePhoneDarkTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-dark.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static let steps: [String: GamePhoneGeometry.Step] = [
        "noPicture": .noPicture, "noTopSlot": .noTopSlot, "topCrowded": .topCrowded, "noCamera": .noCamera,
        "noBottomSlot": .noBottomSlot, "bottomCrowded": .bottomCrowded, "shape": .shape, "rim": .rim, "sides": .sides,
        "implausible": .implausible, "found": .found,
    ]

    func testDarkSceneGains() throws {
        for item in try vectors()["gains"] as! [[String: Any]] {
            let level = (item["level"] as! NSNumber).intValue
            XCTAssertEqual(GamePhoneGeometry.darkGains(level: level), (item["gains"] as! [NSNumber]).map(\.intValue), "level \(level)")
        }
    }

    func testDarkFramesFindThePhone() throws {
        for item in try vectors()["frames"] as! [[String: Any]] {
            let name = item["name"] as! String
            let frame = try GamePhoneFirstSightingTests.load(item["frame"] as! String, item["transform"] as! String)
            let (pose, probe) = GamePhoneGeometry.search(frame)
            XCTAssertNotNil(pose, "\(name): \(probe)")
            if item["gain"] as? Bool == true { XCTAssertGreaterThan(probe.gain, 256, name) }
            // İzleyici de iki gözlemde açar.
            let tracker = GamePhoneTracker()
            XCTAssertNil(tracker.sample(frame, now: 0).pose, name)
            XCTAssertNotNil(tracker.sample(frame, now: 330).pose, name)
        }
    }

    func testDarkScreenPreparation() throws {
        for item in try vectors()["darkScreen"] as! [[String: Any]] {
            let name = item["name"] as! String
            var counts = [Int](repeating: 0, count: 256), total = 0
            for pair in item["histogram"] as! [[NSNumber]] {
                counts[pair[0].intValue] += pair[1].intValue
                total += pair[1].intValue
            }
            let map = PhoneDarkScreen.mapping(counts: counts, total: total)
            XCTAssertEqual(map != nil, item["prepared"] as! Bool, name)
            for pair in (item["map"] as? [[NSNumber]]) ?? [] {
                XCTAssertEqual(map.map { Int($0[pair[0].intValue]) }, pair[1].intValue, "\(name): \(pair[0])")
            }
            // Ton dizisiyle aynı sonuç.
            var tones: [UInt8] = []
            for (tone, count) in counts.enumerated() { tones += [UInt8](repeating: UInt8(tone), count: count) }
            XCTAssertEqual(PhoneDarkScreen.prepared(tones), map.map { m in tones.map { m[Int($0)] } }, name)
        }
    }

    /// Düzeltilmiş ekranın RGBA'sı: koyu temada gri, ters çevrilmiş; aydınlık ekran aynen.
    func testFlatScreenIsPreparedOnlyWhenDark() {
        func rgba(_ pixels: [(UInt8, UInt8, UInt8)]) -> Data { Data(pixels.flatMap { [$0.0, $0.1, $0.2, 255] }) }
        let light = rgba(Array(repeating: (230, 230, 235), count: 90) + Array(repeating: (20, 20, 25), count: 10))
        XCTAssertEqual(GamePhoneReader.darkScreenPrepared(light), light)
        let dark = rgba(Array(repeating: (20, 20, 20), count: 90) + Array(repeating: (220, 220, 220), count: 10))
        let prepared = GamePhoneReader.darkScreenPrepared(dark)
        XCTAssertEqual(Array(prepared.prefix(4)), [255, 255, 255, 255])
        XCTAssertEqual(Array(prepared.suffix(4)), [0, 0, 0, 255])
    }

    func testDarkMissIsLoggedWithBrightness() throws {
        let spec = try vectors()["missLog"] as! [String: Any]
        let frame = try GamePhoneFirstSightingTests.load(spec["frame"] as! String, spec["transform"] as! String)
        let interval = (spec["intervalMs"] as! NSNumber).intValue, duration = (spec["durationMs"] as! NSNumber).intValue
        var log: [String] = []
        let tracker = GamePhoneTracker()
        tracker.onLog = { log.append($0) }
        for t in stride(from: 0, through: duration, by: interval) { XCTAssertNil(tracker.sample(frame, now: t).pose) }
        let missed = log.filter { $0.contains("telefon ilk aramada bulunamadı") }
        XCTAssertEqual(missed.count, 1, "\(log)")
        for part in spec["contains"] as! [String] { XCTAssertTrue(missed.first?.contains(part) == true, "\(missed)") }
    }

    func testDarkMissLineText() throws {
        let spec = try vectors()["missLine"] as! [String: Any]
        func int(_ key: String) -> Int { (spec[key] as! NSNumber).intValue }
        XCTAssertEqual(PhoneTrace.missedFirst(samples: int("samples"), furthest: PhoneTrace.reason(Self.steps[spec["furthest"] as! String]!),
                                              common: PhoneTrace.reason(Self.steps[spec["common"] as! String]!),
                                              commonCount: int("commonCount"), side: int("side"), unconfirmed: int("unconfirmed"),
                                              strict: int("strict"), level: int("level"), gain: int("gain")),
                       spec["line"] as! String)
    }
}
