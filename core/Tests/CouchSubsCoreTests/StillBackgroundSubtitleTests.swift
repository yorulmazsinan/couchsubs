// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// GitHub #1019: sabit arka planda (kamera durgun) yeni altyazı satırı okunmuyor, kamera oynatılınca çeviri geliyordu.
/// Mac ve Windows'ta pencere yakalaması değişmeyen ekranda kare göndermez: yeni satırın karesi önceki okuma sürerken
/// gelip atlanırsa (`FrameGate`) ardından kare gelmiyor, satır kamera oynatılıp kareler yeniden gelene dek okunmuyordu.
/// Gerçek GTA 6 karesiyle (testdata/frames) okuma seçimi bölge izine (`RegionCropper.signature`, `ReadScheduler`)
/// bakılarak sınanır; yazı tanıma çalışmaz (Vision yok).
final class StillBackgroundSubtitleTests: XCTestCase {
    /// gta6-01-lucia: "Lucia: Could I have another ice water, please?" ve kutusu (frames.json).
    private static let subtitleBox = (left: 0.303, top: 0.88, right: 0.697, bottom: 0.924)

    private struct Scene {
        let width: Int, height: Int
        /// Gerçek kare (RGBA).
        let real: [UInt8]
        /// Altyazı kutusunun piksel sınırları (biraz payla).
        let left: Int, right: Int, top: Int, bottom: Int

        /// Kutunun içi `pixel(x, y)` ile değiştirilmiş kare.
        func frame(_ pixel: (_ x: Int, _ y: Int, _ channel: Int) -> UInt8) -> CGImage {
            var data = real
            for y in top..<bottom {
                for x in left..<right {
                    for c in 0..<4 { data[(y * width + x) * 4 + c] = pixel(x, y, c) }
                }
            }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent)!
        }

        func value(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { real[(y * width + x) * 4 + c] }
        /// Altyazısız sahne: kutu, hemen üstündeki satırla doldurulur.
        func background(_ x: Int, _ y: Int, _ c: Int) -> UInt8 { value(x, top - 1, c) }
    }

    private static func scene() throws -> Scene {
        let url = FrameReplayTests.directory.appendingPathComponent("gta6-01-lucia.jpg")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let box = subtitleBox
        return Scene(width: width, height: height, real: data,
                     left: max(0, Int(box.left * Double(width)) - 8), right: min(width, Int(box.right * Double(width)) + 8),
                     top: max(1, Int(box.top * Double(height)) - 6), bottom: min(height, Int(box.bottom * Double(height)) + 6))
    }

    private static func signature(_ frame: CGImage) -> [UInt8] {
        RegionCropper.signature(of: RegionCropper.crop(frame, to: CropRegion()))
    }

    /// Uygulamadaki kare döngüsü (Mac `AppModel.handle`, iPhone `PhoneModel.handle`, Windows `HandleFrame`): kapıdan giren
    /// kare okunur; okuma sürerken gelen kare atlanır ve okuma bitince atlanan son kare okunur. Okunan karelerin dizinleri.
    private struct Loop {
        var scheduler = ReadScheduler()
        var gate = FrameGate()
        var skipped: Int?
        var reads: [Int] = []
        var running: Int?
        let trailing: Bool

        /// Kare gelir; önceki okuma sürüyorsa atlanır.
        mutating func arrive(_ index: Int, _ signatures: [[UInt8]], now: Int) {
            guard case .enter(let token) = gate.enter(now: now) else { skipped = index; return }
            running = token
            plan(index, signatures)
        }

        /// Süren okuma bitti.
        mutating func finish(_ signatures: [[UInt8]], now: Int) {
            guard let token = running else { return }
            running = nil
            guard gate.leave(token), trailing, let index = skipped else { return }
            skipped = nil
            guard case .enter(let again) = gate.enter(now: now) else { return }
            running = again
            plan(index, signatures)
            finish(signatures, now: now)
        }

        private mutating func plan(_ index: Int, _ signatures: [[UInt8]]) {
            if case .read = scheduler.plan(signature: signatures[index]) {
                reads.append(index)
                scheduler.record(index == 1 ? "" : "satır \(index)")
            }
        }
    }

    /// Konuşma satırı kalkar, okunurken yeni satır belirir ve ekran durur (kare gelmez). Yeni satır okunmalı.
    func testNewLineArrivingDuringAReadIsReadOnAStillScreen() throws {
        let scene = try Self.scene()
        let first = scene.frame(scene.value)
        let gone = scene.frame(scene.background)
        // Aynı yerde başka bir satır: altyazı 9 piksel kaymış (başka harfler).
        let next = scene.frame { x, y, c in scene.value(min(scene.width - 1, x + 9), y, c) }
        let signatures = [first, gone, next].map(Self.signature)
        XCTAssertTrue(ReadScheduler.changed(signatures[0], signatures[1], threshold: ReadScheduler.defaultChangeThreshold))
        XCTAssertTrue(ReadScheduler.changed(signatures[1], signatures[2], threshold: ReadScheduler.defaultChangeThreshold))

        for trailing in [false, true] {
            var loop = Loop(trailing: trailing)
            loop.arrive(0, signatures, now: 0)
            loop.finish(signatures, now: 50)
            loop.arrive(1, signatures, now: 100)   // satır kalktı: okunuyor
            loop.arrive(2, signatures, now: 150)   // yeni satır okuma sürerken geldi: atlandı
            loop.finish(signatures, now: 400)      // ekran durdu, kare gelmez
            if trailing {
                XCTAssertEqual(loop.reads, [0, 1, 2], "atlanan yeni satır okunmadı")
            } else {
                // Eski davranış: yeni satır kamera oynatılana dek okunmuyordu.
                XCTAssertEqual(loop.reads, [0, 1])
            }
        }
    }

    /// Altyazı birçok karede yavaşça belirir: her kare bir öncekinden eşikten az farklı, yazı bütünüyle sahneden farklı.
    /// Karşılaştırma son okunan kareyle yapılır; yazı belirince okunur ve son okuma yazının tam görünür hâlidir.
    func testSubtitleFadingInSlowlyOverAStillSceneIsRead() throws {
        let scene = try Self.scene()
        let steps = 20
        let clean = Self.signature(scene.frame(scene.background))
        let frames = (1...steps).map { step -> [UInt8] in
            let alpha = Double(step) / Double(steps)
            return Self.signature(scene.frame { x, y, c in
                UInt8((Double(scene.background(x, y, c)) * (1 - alpha) + Double(scene.value(x, y, c)) * alpha).rounded())
            })
        }
        for (a, b) in zip([clean] + frames, frames) {
            XCTAssertFalse(ReadScheduler.changed(a, b, threshold: ReadScheduler.defaultChangeThreshold), "senaryo eski kuralı sınamıyor")
        }
        var scheduler = ReadScheduler()
        XCTAssertEqual(scheduler.plan(signature: clean), .read(deep: true))
        scheduler.record("")
        var lastRead: Int?
        for (index, signature) in frames.enumerated() {
            if case .read = scheduler.plan(signature: signature) {
                lastRead = index
                scheduler.record("Lucia: Could I have another ice water, please?")
            }
        }
        let read = try XCTUnwrap(lastRead, "altyazı belirdi ama hiç okunmadı")
        XCTAssertFalse(ReadScheduler.changed(frames[read], frames[steps - 1], threshold: ReadScheduler.defaultChangeThreshold),
                       "son okuma yazı belirirken kaldı (kare \(read + 1)/\(steps))")
    }
}
