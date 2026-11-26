// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CouchSubsCore

/// GTA 6 telefonunun ilk açılışı (#1251, beta-102): telefon çoğu zaman hiç tanınmıyor, mesajları altyazı gibi çevriliyordu.
/// Ortak deneme dosyası Fixtures/phone-first-sighting.json (Windows GamePhoneFirstSightingTests.cs, Android
/// GamePhoneFirstSightingTest.kt aynı durumları koşar); gerçek kareler testdata/frames (yazı tanıma çalışmaz).
final class GamePhoneFirstSightingTests: XCTestCase {
    private static let frames = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../testdata/frames").standardized

    private func vectors() throws -> [String: Any] {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("phone-first-sighting.json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private static var loaded: [String: CGImage] = [:]

    /// Gerçek kare, ortak dosyadaki dönüşümleriyle ("+" ile birleşir: none, shiftUp, lowContrast, dark, night, gamma,
    /// scale1440); `shift` [dx, dy] (0..1) verilirse görüntü sağa ve aşağı kayar (el titredi), `cover` [sol, üst, sağ, alt]
    /// (0..1) verilirse o dikdörtgen el rengiyle örtülür.
    static func load(_ name: String, _ transform: String, cover: [Double]? = nil, shift: [Double]? = nil) throws -> CGImage {
        let key = "\(name)|\(transform)|\(cover?.map { "\($0)" }.joined(separator: ",") ?? "")|\(shift?.map { "\($0)" }.joined(separator: ",") ?? "")"
        if let cached = loaded[key] { return cached }
        let url = frames.appendingPathComponent(name + ".jpg")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw XCTSkip("gerçek kare yok: \(name)") }
        for part in transform.split(separator: "+").map(String.init) {
            switch part {
            case "scale1440": image = scaled(image, width: 2560, height: 1440)
            case "scale720": image = scaled(image, width: 1280, height: 720)
            case "letterbox", "pillarbox", "titlebar": image = framed(image, part)
            default: image = transformed(image, part)
            }
        }
        if let shift { image = shifted(image, dx: shift[0], dy: shift[1]) }
        let result = cover == nil ? image : transformed(image, "none", cover: cover)
        loaded[key] = result
        return result
    }

    /// Kare çift doğrusal büyütülür (1440p akış).
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Pencereden okunan kare: görüntü 16:10 pencerede siyah şeritli (letterbox), geniş pencerede yanları siyah şeritli
    /// (pillarbox) ya da üstünde açık başlık çubuğuyla (titlebar).
    static func framed(_ image: CGImage, _ kind: String) -> CGImage {
        let w = image.width, h = image.height
        var width = w, height = h, x = 0, top = 0
        switch kind {
        case "letterbox":
            height = w * 10 / 16
            top = (height - h) / 2
        case "pillarbox":
            width = w + 2 * (w / 12)
            x = w / 12
        default:
            height = h + h / 34
            top = height - h
        }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if kind == "titlebar" {
            context.setFillColor(red: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: h, width: width, height: height - h))
        }
        // CoreGraphics'te y aşağıdan yukarı: görüntünün üstü pencerenin üstünden `top` aşağıda.
        context.draw(image, in: CGRect(x: x, y: height - top - h, width: w, height: h))
        return context.makeImage()!
    }

    /// Görüntü karenin `dx`'i kadar sağa, `dy`'si kadar aşağı kayar; boşalan yer kenar pikseliyle dolar.
    static func shifted(_ image: CGImage, dx: Double, dy: Double) -> CGImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let sx = Int(dx * Double(width)), sy = Int(dy * Double(height))
        var out = pixels
        for y in 0..<height {
            let from = min(height - 1, max(0, y - sy))
            for x in 0..<width {
                let p = (y * width + x) * 4, q = (from * width + min(width - 1, max(0, x - sx))) * 4
                (out[p], out[p + 1], out[p + 2]) = (pixels[q], pixels[q + 1], pixels[q + 2])
            }
        }
        let result = CGContext(data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return result.makeImage()!
    }

    static func transformed(_ image: CGImage, _ transform: String, cover: [Double]? = nil) -> CGImage {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var out = pixels
        switch transform {
        case "shiftUp":
            let shift = height / 12
            for y in 0..<height {
                let from = min(height - 1, y + shift) * width * 4
                out.replaceSubrange(y * width * 4..<(y + 1) * width * 4, with: pixels[from..<from + width * 4])
            }
        case "lowContrast", "dark", "night", "gamma":
            for i in 0..<out.count where i % 4 != 3 {
                let value = Int(pixels[i])
                let mapped: Int
                switch transform {
                case "dark": mapped = value * 6 / 10
                case "night": mapped = value * 35 / 100
                case "gamma": mapped = Int(255 * pow(Double(value) / 255, 2.2))
                default: mapped = 128 + (value - 128) * 6 / 10
                }
                out[i] = UInt8(max(0, min(255, mapped)))
            }
        default:
            break
        }
        if let cover {
            let left = Int(cover[0] * Double(width)), top = Int(cover[1] * Double(height))
            let right = Int(cover[2] * Double(width)), bottom = Int(cover[3] * Double(height))
            for y in top..<bottom {
                for x in left..<right {
                    let p = (y * width + x) * 4
                    (out[p], out[p + 1], out[p + 2]) = (196, 140, 110)
                }
            }
        }
        let result = CGContext(data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return result.makeImage()!
    }

    private func pose(_ values: Any?) -> GamePhoneGeometry.Pose {
        let v = (values as! [Any]).map { ($0 as! NSNumber).doubleValue }
        return GamePhoneGeometry.Pose(topX: v[0], topY: v[1], bottomX: v[2], bottomY: v[3])
    }

    private func expected(_ sequence: [String: Any]) -> Int? { (sequence["opensAt"] as? NSNumber)?.intValue }

    func testSequencesOpenTheSameWayOnEveryPlatform() throws {
        let all = try vectors()
        let fallback = pose(all["defaultPose"])
        let image = GamePhoneTestFrame.image(width: 2, height: 2) { _, _ in (0, 0, 0) }
        for sequence in all["sequences"] as! [[String: Any]] {
            let name = sequence["name"] as! String
            var next: (pose: GamePhoneGeometry.Pose, strict: Bool)?
            let tracker = GamePhoneTracker(sight: { _ in next })
            var opened: Int?
            for (index, sample) in (sequence["samples"] as! [[String: Any]]).enumerated() {
                let place = sample["pose"].map(pose) ?? fallback
                switch sample["kind"] as! String {
                case "strict": next = (place, true)
                case "weak": next = (place, false)
                default: next = nil
                }
                let result = tracker.sample(image, now: (sample["t"] as! NSNumber).intValue)
                XCTAssertTrue(result.sampled, name)
                if result.pose != nil, opened == nil { opened = index }
            }
            XCTAssertEqual(opened, expected(sequence), name)
        }
    }

    func testRealFramesFromTheLogOpenThePhone() throws {
        for sequence in try vectors()["frames"] as! [[String: Any]] {
            let name = sequence["name"] as! String
            let tracker = GamePhoneTracker()
            var opened: Int?
            var closedAfterOpening = false
            for (index, sample) in (sequence["samples"] as! [[String: Any]]).enumerated() {
                let cover = (sample["cover"] as? [NSNumber])?.map(\.doubleValue)
                let shift = (sample["shift"] as? [NSNumber])?.map(\.doubleValue)
                let frame = try Self.load(sample["frame"] as! String, sample["transform"] as! String, cover: cover, shift: shift)
                let open = tracker.sample(frame, now: (sample["t"] as! NSNumber).intValue).pose != nil
                if open, opened == nil { opened = index }
                if !open, opened != nil { closedAfterOpening = true }
            }
            XCTAssertEqual(opened, expected(sequence), name)
            if sequence["staysOpen"] as? Bool == true { XCTAssertFalse(closedAfterOpening, "\(name): telefon kapandı") }
        }
    }

    /// Telefonsuz gerçek kareler (frames.json'da telefon işareti olmayanlar) hiçbir dönüşümde telefon açmaz, aday da olmaz.
    func testFramesWithoutPhoneNeverOpenOrHoldIt() throws {
        let noPhone = try vectors()["noPhone"] as! [String: Any]
        let transforms = noPhone["transforms"] as! [String]
        let samples = (noPhone["samples"] as! NSNumber).intValue
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.frames.appendingPathComponent("frames.json"))) as! [String: Any]
        let names = Set((manifest["frames"] as! [[String: Any]]).filter { $0["phone"] == nil }
            .map { ($0["file"] as! String).replacingOccurrences(of: ".jpg", with: "") })
        XCTAssertGreaterThan(names.count, 50)
        for name in names.sorted() {
            let url = Self.frames.appendingPathComponent(name + ".jpg")
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw XCTSkip("gerçek kare yok: \(name)") }
            for transform in transforms {
                let frame = transform == "none" ? original : Self.transformed(original, transform)
                let tracker = GamePhoneTracker()
                for i in 0..<samples {
                    XCTAssertNil(tracker.sample(frame, now: i * 330).pose, "\(name) (\(transform)): telefon açıldı")
                }
                let search = ScreenPhoneCard.search(in: frame)
                XCTAssertNil(search.phone, "\(name) (\(transform)): telefon")
                XCTAssertNil(search.candidate, "\(name) (\(transform)): telefon adayı")
            }
        }
    }

    func testSubtitleFilterHoldsTheCandidateAndConfirmsItInPlace() throws {
        for item in try vectors()["candidates"] as! [[String: Any]] {
            let name = item["name"] as! String
            let frame = try Self.load(item["frame"] as! String, item["transform"] as! String)
            let search = ScreenPhoneCard.search(in: frame)
            XCTAssertNil(search.phone, name)
            let candidate = try XCTUnwrap(search.candidate, "\(name): aday yok")
            XCTAssertNotNil(ScreenPhoneCard.phone(in: frame, near: candidate), "\(name): adayın yerinde telefon doğrulanmadı")
        }
    }

    func testMissedFirstSightingIsLoggedOncePerWindow() throws {
        let spec = try vectors()["missLog"] as! [String: Any]
        let frame = try Self.load(spec["frame"] as! String, spec["transform"] as! String)
        let interval = (spec["intervalMs"] as! NSNumber).intValue, duration = (spec["durationMs"] as! NSNumber).intValue
        var log: [String] = []
        var tracker = GamePhoneTracker()
        tracker.onLog = { log.append($0) }
        for t in stride(from: 0, through: duration, by: interval) { _ = tracker.sample(frame, now: t) }
        let missed = log.filter { $0.contains("telefon ilk aramada bulunamadı") }
        XCTAssertEqual(missed.count, 1, "\(log)")
        for part in spec["contains"] as! [String] { XCTAssertTrue(missed.first?.contains(part) == true, "\(missed)") }

        // Telefonsuz oyunda (aramalar hoparlör yarığında kalır) satır yazılmaz.
        log = []
        let empty = try Self.load("gta6-01-lucia", "none")
        tracker = GamePhoneTracker()
        tracker.onLog = { log.append($0) }
        for t in stride(from: 0, through: duration, by: interval) { _ = tracker.sample(empty, now: t) }
        XCTAssertEqual(log, [])
    }

    func testMissedFirstLineNamesTheCriterion() {
        XCTAssertEqual(PhoneTrace.missedFirst(samples: 61, furthest: PhoneTrace.reason(.sides), common: PhoneTrace.reason(.sides),
                                              commonCount: 61, side: 3, unconfirmed: 1, strict: 1),
                       "telefon ilk aramada bulunamadı (61 arama): en ileri ölçüt yan kenarlar zayıf, en sık yan kenarlar zayıf (61), "
                       + "en iyi aday yan gücü 3/12, doğrulanmayan gözlem 1 (1 sıkı)")
        XCTAssertEqual(PhoneTrace.missedFirst(samples: 5, furthest: PhoneTrace.reason(.noCamera), common: PhoneTrace.reason(.noTopSlot),
                                              commonCount: 4, side: -1, unconfirmed: 0, strict: 0),
                       "telefon ilk aramada bulunamadı (5 arama): en ileri ölçüt ön kamera yok, en sık hoparlör yarığı yok (4), "
                       + "doğrulanmayan gözlem 0 (0 sıkı)")
    }

    /// Altyazı hattının adayı: ilk görüldüğü an yakınında korunur, satırlar `candidateHoldMs` boyunca bekletilir.
    @MainActor
    func testCandidateHoldIsShortAndDoesNotExtendItself() throws {
        let frame = try Self.load("gta6-telefon-sohbet-2", "shiftUp")
        let weak = try XCTUnwrap(ScreenPhoneCard.search(in: frame).candidate)
        let (first, since) = SubtitlePipeline.candidate(weak, previous: nil, since: 0, now: 1000)
        XCTAssertNotNil(first)
        XCTAssertEqual(since, 1000)
        XCTAssertEqual(SubtitlePipeline.candidate(weak, previous: first, since: since, now: 1330).1, 1000)
        XCTAssertTrue(SubtitlePipeline.holdsCandidate(first, since: since, now: 1000 + SubtitlePipeline.candidateHoldMs - 1))
        XCTAssertFalse(SubtitlePipeline.holdsCandidate(first, since: since, now: 1000 + SubtitlePipeline.candidateHoldMs))
        let gone = SubtitlePipeline.candidate(nil, previous: first, since: since, now: 1660)
        XCTAssertNil(gone.0)
        XCTAssertEqual(gone.1, 0)
        XCTAssertFalse(SubtitlePipeline.holdsCandidate(nil, since: 0, now: 10))
    }
}
