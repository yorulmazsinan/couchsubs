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

    /// Ton eşitleme eşlemesi (`GamePhoneGeometry.equalization`): her platformda aynı tonlar.
    func testEqualizationMap() throws {
        for item in try vectors()["equalization"] as! [[String: Any]] {
            let name = item["name"] as! String
            var counts = [Int](repeating: 0, count: 1021), total = 0
            for pair in item["counts"] as! [[NSNumber]] {
                counts[pair[0].intValue] += pair[1].intValue
                total += pair[1].intValue
            }
            let map = GamePhoneGeometry.equalization(counts: counts, total: total)
            for pair in item["map"] as! [[NSNumber]] {
                XCTAssertEqual(Int(map[pair[0].intValue]), pair[1].intValue, "\(name): \(pair[0])")
            }
        }
    }

    /// Gece, kapalı yer ve karanlık sahne: gerçek telefon karelerinin karartılmış hâlleri (parlaklık × k, gama, gece renk
    /// ayarı, kararan kenarlar, koyu arka plan; kare ortalaması ~5–60/255) telefonu açar.
    func testDarkVariantsOpenThePhone() throws {
        for item in try vectors()["darkVariants"] as! [[String: Any]] {
            let frame = item["frame"] as! String
            for transform in item["transforms"] as! [String] {
                let image = try GamePhoneFirstSightingTests.load(frame, transform)
                let tracker = GamePhoneTracker()
                var opened = false
                for i in 0..<3 where tracker.sample(image, now: i * GamePhoneTracker.intervalMs).pose != nil { opened = true }
                XCTAssertTrue(opened, "\(frame) (\(transform)): \(GamePhoneGeometry.search(image).probe)")
            }
        }
    }

    /// İz benzerliği (`PhonePrint.similarity`): parlaklıktan ve karşıtlıktan bağımsız; düz ya da çok sönük iz 0.
    func testPrintSimilarity() throws {
        for item in try vectors()["printSimilarity"] as! [[String: Any]] {
            let a = (item["a"] as! [NSNumber]).map(\.intValue), b = (item["b"] as! [NSNumber]).map(\.intValue)
            XCTAssertEqual(PhonePrint.similarity(a, b), (item["similarity"] as! NSNumber).doubleValue, accuracy: 1e-6,
                           item["name"] as! String)
        }
    }

    /// Telefon aydınlıkta açılır, sahne kararır (sıkı arama ıskalar): son yerindeki iziyle açık kalır, okuma sürer. Telefon
    /// indirilince (telefonsuz kare) iz tutmaz, telefon her zamanki sürede kapanır.
    func testOpenPhoneIsHeldByItsPrint() throws {
        for item in try vectors()["hold"] as! [[String: Any]] {
            let name = item["name"] as! String
            let open = try GamePhoneFirstSightingTests.load(item["frame"] as! String, "none")
            let then = try GamePhoneFirstSightingTests.load(item["then"] as! String, item["transform"] as! String)
            var log: [String] = []
            let tracker = GamePhoneTracker()
            tracker.onLog = { log.append($0) }
            var t = 0
            for _ in 0..<3 { _ = tracker.sample(open, now: t); t += GamePhoneTracker.intervalMs }
            XCTAssertNotNil(tracker.sample(open, now: t).pose, name)
            t += GamePhoneTracker.intervalMs
            var last: GamePhoneGeometry.Pose?
            var kept = 0
            for _ in 0..<(item["samples"] as! NSNumber).intValue {
                last = tracker.sample(then, now: t).pose
                if last != nil { kept += 1 }
                t += GamePhoneTracker.intervalMs
            }
            if item["held"] as! Bool {
                XCTAssertEqual(kept, (item["samples"] as! NSNumber).intValue, "\(name): \(log)")
            } else {
                XCTAssertNil(last, "\(name): \(log)")
            }
            for part in (item["log"] as? [String]) ?? [] {
                XCTAssertTrue(log.contains { $0.contains(part) }, "\(name): \(part) yok: \(log)")
            }
        }
    }

    /// İz telefonsuz karede telefonu tutmaz: telefon açıldıktan sonra telefonsuz gerçek kareler (karanlık hâlleriyle) gelince
    /// telefon kapanır.
    func testPrintNeverHoldsPhoneFreeFrames() throws {
        let spec = try vectors()["holdNoPhone"] as! [String: Any]
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("../../../testdata/frames/frames.json").standardized)) as! [String: Any]
        let names = Set((manifest["frames"] as! [[String: Any]]).filter { $0["phone"] == nil }
            .map { ($0["file"] as! String).replacingOccurrences(of: ".jpg", with: "") })
        let openers = try (spec["openers"] as! [String]).map { try GamePhoneFirstSightingTests.load($0, "none") }
        let samples = (spec["samples"] as! NSNumber).intValue
        for name in names.sorted() {
            for transform in spec["transforms"] as! [String] {
                let frame = try GamePhoneFirstSightingTests.fresh(name, transform)
                for (i, opener) in openers.enumerated() {
                    let tracker = GamePhoneTracker()
                    var t = 0
                    for _ in 0..<3 { _ = tracker.sample(opener, now: t); t += GamePhoneTracker.intervalMs }
                    var last: GamePhoneGeometry.Pose?
                    for _ in 0..<samples {
                        last = tracker.sample(frame, now: t).pose
                        t += GamePhoneTracker.intervalMs
                    }
                    XCTAssertNil(last, "\(name) (\(transform)) telefon \(i) açık kaldı")
                }
            }
        }
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
