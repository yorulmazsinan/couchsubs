// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(CoreGraphics)
import CoreGraphics
import XCTest
@testable import CouchSubsCore

private final class OrderReader: TextReader, @unchecked Sendable {
    var text = ""
    func read(_ image: CGImage) throws -> String { text }
}
private final class OrderSender: SubtitleSending {
    var sent: [String] = []
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) { sent.append(text) }
    func clear() {}
}
/// Yavaş yapay zekâ çevirisi: `slow` içindeki satırlar `release` çağrılana kadar bekler, diğerleri hemen döner.
private final class SlowTranslator: TextTranslator {
    var slow: Set<String>
    var requested: [String] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    init(slow: Set<String>) { self.slow = slow }
    func translate(_ text: String) async throws -> String {
        requested.append(text)
        if slow.contains(text) { await withCheckedContinuation { gates[text] = $0 } }
        return "TR: " + text
    }
    func release(_ text: String) { slow.remove(text); gates.removeValue(forKey: text)?.resume() }
}

/// GitHub #893: gelişmiş (yapay zekâ) çeviri açıkken bazı satırlar TV'ye hiç gitmiyordu. Çeviri satır başına bir iki
/// saniye sürüyor; ilk satırın çevirisi yenisi geldikten 2,5 sn sonra bitince atılıyor ya da yarıda bırakılıyordu.
/// Windows (SlowTranslationOrderTests.cs) ve Android (SlowTranslationOrderTest.kt) aynı senaryoları sınar.
@MainActor
final class SlowTranslationOrderTests: XCTestCase {
    private let first = "Hold the gate."
    private let second = "Run to the boat!"
    private var image: CGImage {
        CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }

    private final class Scene {
        var time = 0
        let reader = OrderReader()
        let sender = OrderSender()
        let translator: SlowTranslator
        var pipeline: SubtitlePipeline!
        init(slow: Set<String>) { translator = SlowTranslator(slow: slow) }
    }

    private func scene(slow: Set<String>) -> Scene {
        let scene = Scene(slow: slow)
        scene.pipeline = SubtitlePipeline(reader: scene.reader, translator: scene.translator, server: scene.sender,
                                          clock: { [unowned scene] in scene.time })
        scene.pipeline.holdReadings = false
        return scene
    }

    private func frame(_ scene: Scene, _ text: String, at time: Int) async {
        scene.reader.text = text
        scene.time = time
        await scene.pipeline.process(image, region: CropRegion())
        for _ in 0..<200 { await Task.yield() }
    }

    func testSlowFirstLineIsStillShownBeforeTheFasterNextOne() async {
        let scene = scene(slow: [first])
        await frame(scene, first, at: 0)
        await frame(scene, second, at: 1500)
        // İlk satır yenisi geldikten 2,6 sn sonra hâlâ çevriliyor: eskiden yarıda bırakılıyordu.
        await frame(scene, second, at: 1500 + SubtitlePipeline.lateResultMs + 100)
        scene.time = 4500
        scene.translator.release(first)
        await scene.pipeline.waitForTranslations()
        XCTAssertEqual(scene.translator.requested, [first, second])
        XCTAssertEqual(scene.sender.sent, ["TR: " + first, "TR: " + second])
    }

    func testQueuedLastLineIsNotDroppedForTimeSpentWaiting() async {
        let scene = scene(slow: [first])
        await frame(scene, first, at: 0)
        await frame(scene, second, at: 500)
        for time in stride(from: 600, through: 2000, by: 100) { await frame(scene, "", at: time) }
        // Son satır kalktıktan 3 sn sonra sırası geldi; çevirisi hemen bitti, yine gösterilir.
        scene.time = 5000
        scene.translator.release(first)
        await scene.pipeline.waitForTranslations()
        XCTAssertEqual(scene.sender.sent, ["TR: " + first, "TR: " + second])
    }

    func testFirstLineIsGivenUpOnlyAfterTheQueuedLimit() async {
        let scene = scene(slow: [first])
        await frame(scene, first, at: 0)
        await frame(scene, second, at: 100)
        await frame(scene, second, at: 100 + SubtitlePipeline.queuedLateResultMs + 1)
        // Sahte motor iptali dinlemiyor; bırakılan satırın sonucu yine de gösterilmez.
        scene.translator.release(first)
        await scene.pipeline.waitForTranslations()
        XCTAssertEqual(scene.sender.sent, ["TR: " + second])
    }

    func testLoneLineArrivingLongAfterItLeftIsStillDropped() async {
        let scene = scene(slow: [first])
        await frame(scene, first, at: 0)
        for time in stride(from: 100, through: 1500, by: 100) { await frame(scene, "", at: time) }
        scene.time = 1500 + SubtitlePipeline.lateResultMs + 600
        scene.translator.release(first)
        await scene.pipeline.waitForTranslations()
        XCTAssertEqual(scene.sender.sent, [])
    }
}
#endif
