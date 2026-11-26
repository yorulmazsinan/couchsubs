// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// Aşama süreleri satırı (Android StageTimingTest, Windows StageTimingTests ile aynı durumlar).
final class StageTimingTests: XCTestCase {
    func testReportsOncePerPeriodAndResets() {
        let timing = StageTiming(period: 30_000)
        XCTAssertNil(timing.report(now: 0))
        timing.add("okuma", nanoseconds: 80_000_000)
        timing.add("okuma", nanoseconds: 140_250_000)
        timing.add("çizim", nanoseconds: 30_040_000)
        XCTAssertNil(timing.report(now: 29_999))
        XCTAssertEqual(timing.report(now: 30_000),
                       "aşama süreleri (30 sn): okuma 2× ort 110,1 en çok 140,3 ms; çizim 1× ort 30,0 en çok 30,0 ms")
        // Sıfırlandı: yeni ölçüm yoksa satır yok.
        XCTAssertNil(timing.report(now: 60_000))
        timing.add("tur", milliseconds: 5)
        XCTAssertNil(timing.report(now: 60_001))
        XCTAssertEqual(timing.report(now: 90_000), "aşama süreleri (30 sn): tur 1× ort 5,0 en çok 5,0 ms")
    }

    func testClockGoingBackReportsAndRestarts() {
        let timing = StageTiming(period: 30_000)
        _ = timing.report(now: 100_000)
        timing.add("tur", milliseconds: 1)
        XCTAssertEqual(timing.report(now: 50), "aşama süreleri (0 sn): tur 1× ort 1,0 en çok 1,0 ms")
    }

    /// Erken duran sayım saf sayımla aynı sonucu verir (bütün kare ölçümü hızlandı, sonuç değişmedi).
    func testEarlyStopCountsMatchFullCounts() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4000 {
            let from = Int.random(in: 0..<20, using: &generator)
            let to = from + Int.random(in: 0..<140, using: &generator)
            let step = 1 + Int.random(in: 0..<5, using: &generator)
            let share = [0.1, 0.5, 0.7, 0.03].randomElement(using: &generator)!
            let density = Double.random(in: 0..<1, using: &generator)
            let cells = (0..<200).map { _ in Double.random(in: 0..<1, using: &generator) < density }
            var n = 0, ok = 0
            for at in stride(from: from, to: to, by: step) {
                n += 1
                if cells[at] { ok += 1 }
            }
            XCTAssertEqual(n > 0 && Double(ok) >= share * Double(n),
                           TextPainter.shareAtLeast(from: from, to: to, step: step, share: share) { cells[$0] })
            let free: [Bool?] = (0..<200).map { _ in
                Double.random(in: 0..<1, using: &generator) < 0.02 ? nil : Double.random(in: 0..<1, using: &generator) < density * 0.2
            }
            let list = Array(free[from..<to])
            let open = !list.isEmpty && !list.contains(where: { $0 == nil })
                && Double(list.filter { $0 == true }.count) < TextPainter.besideShare * Double(list.count)
            XCTAssertEqual(open, TextPainter.roomOpen(from: from, to: to) { free[$0] })
        }
        XCTAssertFalse(TextPainter.shareAtLeast(from: 5, to: 5, step: 1, share: 0.5) { _ in true })
        XCTAssertTrue(TextPainter.roomOpen(from: 0, to: 3) { _ in false })
    }
}

/// Turun bütün karesi bir kez çizilir; ölçüm ve kişi resmi aynı noktaları kullanır.
final class ScreenFrameTests: XCTestCase {
    @MainActor func testWholeFrameIsDrawnOnce() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let image = try XCTUnwrap(context.makeImage())
        let timing = StageTiming(period: 1)
        _ = timing.report(now: 0)
        let screen = RegionWatcher.ScreenFrame(image, timing: timing)
        await screen.prepare()
        await screen.prepare()
        let pixels = try XCTUnwrap(screen.measured())
        XCTAssertEqual(pixels.width, 64)
        XCTAssertEqual(pixels.bytes[0], 255)
        XCTAssertEqual(timing.report(now: 10)?.contains("\(RegionWatcher.stageScreen) 1×"), true)
    }
}
