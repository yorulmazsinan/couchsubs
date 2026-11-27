// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CouchSubsCore

/// Ekran kilidi (Sinan Bey: "stabil olsun artık"): bütün ekran okuması her turda her bloğun kutusuna yeniden karar
/// veriyordu; kutular titriyor, yer değiştiriyor, kalkıp geliyordu. Kararlı ekran kilitlenir; küçük değişiklikte (imleç,
/// sayaç, bir bloğun yazısı) kutu taşınmaz, eklenmez, kalkmaz; ekran gerçekten değişince bir kez yeniden kurulur; aynı
/// ekrana dönülünce önbellekten aynı kutularla çizilir. Gerçek GTA 6 kareleri ve kayıtlı okumalar art arda turlarla
/// (Fixtures/screen-lock.json; Windows ScreenLockTests.cs ve Android ScreenLockTest.kt aynı dosyayı okur).
@MainActor
final class ScreenLockTests: XCTestCase {
    // MARK: - Ortak oynatma dosyası

    struct Plan: Decodable {
        struct Pass: Decodable {
            var jitter: Int?
            var drop: [String]?
            var edit: [[String]]?
        }
        struct Segment: Decodable {
            var screen: String?
            var idBase: Int
            var passes: [Pass]
        }
        struct Expect: Decodable {
            var locks: Int
            var unlocks: Int
            var cacheHits: Int
            var rebuildsPerChange: Int
        }
        var passMs: Int
        var segments: [Segment]
        var expect: Expect
    }

    private struct Fixture: Decodable {
        struct Word: Decodable { let text: String; let box: [Double] }
        struct Line: Decodable { let text: String; let box: [Double]?; let confidence: Double?; let words: [Word]? }
        struct Area: Decodable { let id: String; let menu: Bool?; let region: [Double]; let lines: [Line] }
        let areas: [Area]
    }

    private struct Screen {
        let image: CGImage
        let areas: [Fixture.Area]
    }

    static func plan() throws -> Plan {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("screen-lock.json")
        return try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
    }

    private static func screen(_ id: String) throws -> Screen {
        let directory = FrameReplayTests.directory
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("ocr/screen/\(id).json")))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent("\(id).jpg") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return Screen(image: image, areas: fixture.areas.filter { !$0.lines.isEmpty })
    }

    private static func box(_ v: [Double]) -> TextBox { TextBox(left: v[0], top: v[1], right: v[2], bottom: v[3]) }

    /// Kayıtlı okumanın turdaki hâli (`Plan.Pass`; kural screen-lock.json'da).
    private static func reading(_ lines: [Fixture.Line], _ pass: Plan.Pass) -> Reading {
        var result: [TextLine] = []
        for (i, line) in lines.enumerated() {
            if pass.drop?.contains(line.text) == true { continue }
            var text = line.text
            for edit in pass.edit ?? [] where edit.count == 2 && edit[0] == line.text { text = edit[1] }
            func moved(_ v: [Double]) -> TextBox {
                guard let k = pass.jitter else { return box(v) }
                let dx = 0.002 * Double((k + i) % 3 - 1), dy = 0.0015 * Double((k + 2 * i) % 3 - 1)
                return TextBox(left: v[0] + dx, top: v[1] + dy, right: v[2] + dx + 0.001 * Double(k % 2), bottom: v[3] + dy)
            }
            let words: [TextWord]? = text == line.text ? line.words?.map { TextWord($0.text, box: moved($0.box)) } : nil
            result.append(TextLine(text, box: line.box.map(moved), confidence: line.confidence, words: words))
        }
        return Reading(lines: result)
    }

    private final class Reader: TextReader, @unchecked Sendable {
        var queue: [Reading] = []
        func read(_ image: CGImage) throws -> String { try readLines(image, deep: false).text }
        func read(_ image: CGImage, deep: Bool) throws -> String { try readLines(image, deep: deep).text }
        func readLines(_ image: CGImage, deep: Bool) throws -> Reading { queue.isEmpty ? .empty : queue.removeFirst() }
    }

    private final class Translator: TextTranslator {
        var requests = 0
        func translate(_ text: String) async throws -> String {
            requests += 1
            return "TR " + text
        }
    }

    /// TV'nin gördüğü: alan alan çizili kutular (`region` olayı).
    private final class TV: RegionSending {
        var shown: [String: [ScreenTranslation.Item]] = [:]
        var sends = 0
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) {
            sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil, blocks: nil)
        }
        func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                        blocks: [ScreenTranslation.Item]?) {
            sends += 1
            if text.isEmpty { shown[id] = nil } else {
                shown[id] = blocks ?? [ScreenTranslation.Item(source: "", translation: text, box: box ?? TextBox(left: 0, top: 0, right: 0, bottom: 0), lineHeight: lineHeight ?? 0)]
            }
        }
        func clearRegions() { shown.removeAll() }
        var boxes: [(box: TextBox, text: String)] { shown.values.flatMap { $0.map { ($0.box, $0.translation) } } }
    }

    /// İki TV görüntüsü arasında kutu değişiklikleri: aynı yerde kalan kutu değişiklik değildir; örtüşen kutu taşınmıştır,
    /// kalanlar eklenen ya da kalkan kutudur. Yazısı değişen kutu ayrıca sayılır.
    struct Changes: Equatable {
        var added = 0
        var moved = 0
        var removed = 0
        var retexted = 0
        var boxes: Int { added + moved + removed }
    }

    static func changes(_ old: [(box: TextBox, text: String)], _ new: [(box: TextBox, text: String)]) -> Changes {
        var result = Changes()
        var left = old
        var fresh: [(box: TextBox, text: String)] = []
        for item in new {
            if let i = left.firstIndex(where: { $0.box == item.box }) {
                if left[i].text != item.text { result.retexted += 1 }
                left.remove(at: i)
            } else {
                fresh.append(item)
            }
        }
        for item in fresh {
            if let i = left.firstIndex(where: { ScreenLock.overlap($0.box, item.box) >= 0.3 }) {
                result.moved += 1
                left.remove(at: i)
            } else {
                result.added += 1
            }
        }
        result.removed = left.count
        return result
    }

    struct Run {
        /// Ekran (bölüm) başına kutu değişikliği ve gönderi sayısı.
        var perSegment: [Changes] = []
        var sendsPerSegment: [Int] = []
        /// Kilitliyken (tur başında ve sonunda kilitli, arada açılmadı) görülen kutu değişikliği.
        var whileLocked = Changes()
        /// Bölüm bölüm kilit açılışları.
        var unlocksPerSegment: [Int] = []
        var locks = 0
        var unlocks = 0
        var cacheHits = 0
        var log: [String] = []
        var finalShown = 0
    }

    private func replay(lock: Bool) async throws -> Run {
        let plan = try Self.plan()
        let reader = Reader()
        let tv = TV()
        var clock = 0
        let watcher = RegionWatcher(reader: reader, translator: Translator(), server: tv, intervalMs: plan.passMs,
                                    clock: { clock })
        watcher.locksScreen = lock
        watcher.rereadsEveryPass = true
        var run = Run()
        watcher.onLog = { run.log.append($0) }
        var screens: [String: Screen] = [:]
        let blank = try Self.screen("gta6-menu-gorevler").image
        for segment in plan.segments {
            var total = Changes()
            let sendsBefore = tv.sends
            let unlocksBefore = watcher.screenLock.unlocks
            for pass in segment.passes {
                var areas: [ExtraArea] = []
                var image = blank
                if let id = segment.screen {
                    if screens[id] == nil { screens[id] = try Self.screen(id) }
                    let screen = screens[id]!
                    image = screen.image
                    reader.queue = []
                    for (k, area) in screen.areas.enumerated() {
                        var extra = ExtraArea(id: "auto-\(segment.idBase + k)", name: ScreenTextDetector.areaName,
                                              region: CropRegion(top: area.region[1], bottom: area.region[3],
                                                                 left: area.region[0], right: area.region[2]), auto: true)
                        extra.menu = area.menu ?? false
                        areas.append(extra)
                        reader.queue.append(Self.reading(area.lines, pass))
                    }
                }
                let before = tv.boxes
                let lockedBefore = watcher.screenLock.locked
                let unlocks = watcher.screenLock.unlocks
                await watcher.pass(image, areas: areas)
                XCTAssertTrue(reader.queue.isEmpty, "her alan bir kez okunmalı")
                clock += plan.passMs
                let change = Self.changes(before, tv.boxes)
                total.added += change.added
                total.moved += change.moved
                total.removed += change.removed
                total.retexted += change.retexted
                if lockedBefore, watcher.screenLock.locked, watcher.screenLock.unlocks == unlocks {
                    run.whileLocked.added += change.added
                    run.whileLocked.moved += change.moved
                    run.whileLocked.removed += change.removed
                    run.whileLocked.retexted += change.retexted
                }
            }
            run.perSegment.append(total)
            run.sendsPerSegment.append(tv.sends - sendsBefore)
            run.unlocksPerSegment.append(watcher.screenLock.unlocks - unlocksBefore)
        }
        run.locks = watcher.screenLock.locks
        run.unlocks = watcher.screenLock.unlocks
        run.cacheHits = watcher.screenLock.cacheHits
        run.finalShown = tv.boxes.count
        return run
    }

    /// Kilitliyken hiçbir kutu taşınmaz, eklenmez, kalkmaz; her ekran değişikliğinde tam bir yeniden kurulum; menüye
    /// dönülünce önbellek tutar. Kilitsiz hâlin sayıları önce/sonra karşılaştırması için yazdırılır.
    func testReplayOfMenusAndCardsKeepsLockedBoxesStill() async throws {
        let plan = try Self.plan()
        let before = try await replay(lock: false)
        let after = try await replay(lock: true)
        let names = plan.segments.map { $0.screen ?? "(boş)" }
        for (k, name) in names.enumerated() {
            print("ekran kilidi \(name): kutu değişikliği önce \(before.perSegment[k].boxes) (ekle \(before.perSegment[k].added), "
                  + "taşı \(before.perSegment[k].moved), kaldır \(before.perSegment[k].removed)), sonra \(after.perSegment[k].boxes) "
                  + "(ekle \(after.perSegment[k].added), taşı \(after.perSegment[k].moved), kaldır \(after.perSegment[k].removed)); "
                  + "gönderi önce \(before.sendsPerSegment[k]), sonra \(after.sendsPerSegment[k])")
        }
        print("ekran kilidi günlüğü:\n" + after.log.filter { $0.hasPrefix("ekran kilidi") }.joined(separator: "\n"))
        XCTAssertEqual(after.whileLocked, Changes(), "kilitliyken kutu değişti")
        XCTAssertEqual(after.locks, plan.expect.locks, after.log.filter { $0.hasPrefix("ekran kilidi") }.joined(separator: "\n"))
        XCTAssertEqual(after.unlocks, plan.expect.unlocks)
        XCTAssertEqual(after.cacheHits, plan.expect.cacheHits)
        // Kilitli ekrandan sonra gelen her bölümde (başka ekran ya da yazının kalkması) tam bir yeniden kurulum.
        for k in 1..<plan.segments.count where plan.segments[k - 1].screen != nil {
            XCTAssertEqual(after.unlocksPerSegment[k], plan.expect.rebuildsPerChange, "\(names[k]): yeniden kurulum sayısı")
        }
        // Her kilit ve açılış günlükte nedeni ve blok sayısıyla.
        let lines = after.log.filter { $0.hasPrefix("ekran kilidi") }
        XCTAssertEqual(lines.count, after.locks + after.unlocks)
        XCTAssertTrue(lines.allSatisfy { $0.contains(" blok") }, "\(lines)")
        // Kilitli hâlde ekran başına kutu değişikliği kilitsizden az, ve en çok bir kez kurulum kadar.
        let total = { (r: Run) in r.perSegment.reduce(0) { $0 + $1.boxes } }
        XCTAssertLessThan(total(after), total(before))
        XCTAssertGreaterThan(after.finalShown, 0)
    }

    // MARK: - Kilit kuralları (ScreenLock tek başına)

    private static func block(_ key: String, _ top: Double, left: Double = 0.1) -> ScreenLock.Block {
        ScreenLock.Block(key: key, box: TextBox(left: left, top: top, right: left + 0.3, bottom: top + 0.04))
    }

    private static func item(_ source: String, _ block: ScreenLock.Block) -> ScreenTranslation.Item {
        ScreenTranslation.Item(source: source, translation: "TR " + source, box: block.box, lineHeight: 0.04)
    }

    private static func payload(_ items: [ScreenTranslation.Item]) -> ScreenLock.Payload {
        ScreenLock.Payload(text: items.map(\.translation).joined(separator: "\n"), box: items.first?.box, lineHeight: 0.04,
                           icons: nil, blocks: items)
    }

    private static let menu = ["resume", "map", "brief", "settings", "quit game"]

    private static func screen(_ texts: [String] = menu, dy: Double = 0) -> [ScreenLock.Block] {
        texts.enumerated().map { block($0.element, 0.1 + 0.08 * Double($0.offset) + dy) }
    }

    func testLocksAfterTwoSteadyPassesAndHoldsBoxesThroughSmallChanges() {
        let lock = ScreenLock()
        var log: [String] = []
        lock.onLog = { log.append($0) }
        let blocks = Self.screen()
        XCTAssertEqual(lock.offer(id: "auto-1", payload: Self.payload(blocks.map { Self.item($0.key, $0) })).count, 1)
        XCTAssertTrue(lock.observe(blocks, at: 0).isEmpty)
        XCTAssertFalse(lock.locked)
        XCTAssertTrue(lock.observe(Self.screen(dy: 0.002), at: 500).isEmpty)
        XCTAssertTrue(lock.locked)
        XCTAssertEqual(log, ["ekran kilidi: kilitlendi, 5 blok (5 çevirili)"])
        // Kutusu oynayan, bir satırı eksik ve yeni bir blokla gelen gönderi: kutu taşınmaz, kalkmaz, eklenmez.
        var moved = Self.screen(dy: 0.004).map { Self.item($0.key, $0) }
        moved.removeLast()
        moved.append(Self.item("tooltip", Self.block("tooltip", 0.8)))
        XCTAssertTrue(lock.offer(id: "auto-1", payload: Self.payload(moved)).isEmpty)
        XCTAssertTrue(lock.offer(id: "auto-1", payload: nil).isEmpty)
        XCTAssertTrue(lock.offer(id: "auto-2", payload: Self.payload([Self.item("tooltip", Self.block("tooltip", 0.8))])).isEmpty)
        XCTAssertEqual(lock.displayed["auto-1"]?.blocks?.map(\.box), blocks.map(\.box))
        // Bir blokta yazı değişti (sayaç): iki tur aynı okunmadan güncellenmez; sonra yalnız yazı güncellenir, kutu aynı.
        var ticked = Self.screen()
        ticked[1].key = "map 2"
        let tickedItem = Self.item("map 2", ticked[1])
        XCTAssertTrue(lock.observe(ticked, at: 1000).isEmpty)
        XCTAssertTrue(lock.offer(id: "auto-1", payload: Self.payload([tickedItem])).isEmpty)
        let sends = lock.observe(ticked, at: 1500)
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?.payload?.blocks?.map(\.box), blocks.map(\.box))
        XCTAssertEqual(sends.first?.payload?.blocks?[1].translation, "TR map 2")
        XCTAssertTrue(lock.locked)
        XCTAssertEqual(lock.unlocks, 0)
    }

    func testUnlocksOnceWhenTheScreenReallyChangesAndShowsTheNewScreen() {
        let lock = ScreenLock()
        var log: [String] = []
        lock.onLog = { log.append($0) }
        let first = Self.screen()
        _ = lock.offer(id: "auto-1", payload: Self.payload(first.map { Self.item($0.key, $0) }))
        _ = lock.observe(first, at: 0)
        _ = lock.observe(first, at: 500)
        XCTAssertTrue(lock.locked)
        // İki blok (5'te 2, %40) değişti: tek tur yetmez, ikinci turda açılır; izleyicinin yeni ekranı çizilir.
        let other = Self.screen(["resume", "map", "brief", "graphics", "audio"])
        XCTAssertTrue(lock.observe(other, at: 1000).isEmpty)
        XCTAssertTrue(lock.locked)
        XCTAssertTrue(lock.offer(id: "auto-1", payload: Self.payload(other.map { Self.item($0.key, $0) })).isEmpty)
        let sends = lock.observe(other, at: 1500)
        XCTAssertEqual(lock.unlocks, 1)
        XCTAssertEqual(sends.map(\.id), ["auto-1"])
        XCTAssertEqual(sends.first?.payload?.blocks?.map(\.translation).last, "TR audio")
        let unlocked = log.filter { $0.hasPrefix("ekran kilidi açıldı") }
        XCTAssertEqual(unlocked.count, 1)
        XCTAssertTrue(unlocked.first?.hasPrefix("ekran kilidi açıldı: ekran değişti") == true, "\(log)")
        XCTAssertTrue(unlocked.first?.hasSuffix("5 blok") == true, "\(log)")
        // Yeni ekran iki turdur aynı okunuyordu: çizildiği anda kilitlenir (tek yeniden kurulum).
        XCTAssertTrue(lock.locked)
        XCTAssertEqual(lock.locks, 2)
        XCTAssertTrue(lock.observe(other, at: 2000).isEmpty)
        // Yerleşim kaydı (aynı yazılar başka yerde) da açar; aynı yazı kümesi önbellekte olsa da eski kutular çizilmez.
        let shifted = Self.screen(["resume", "map", "brief", "graphics", "audio"], dy: 0.5)
        _ = lock.observe(shifted, at: 2500)
        _ = lock.observe(shifted, at: 3000)
        XCTAssertEqual(lock.unlocks, 2)
        XCTAssertEqual(lock.cacheHits, 0)
        XCTAssertTrue(log.contains { $0.hasPrefix("ekran kilidi açıldı: yerleşim değişti (5 blok başka yerde)") }, "\(log)")
    }

    func testClearsWhenScreenTextIsGoneForMoreThanASecondAndRedrawsFromCache() {
        let lock = ScreenLock()
        let blocks = Self.screen()
        let items = blocks.map { Self.item($0.key, $0) }
        _ = lock.offer(id: "auto-1", payload: Self.payload(items))
        _ = lock.observe(blocks, at: 0)
        _ = lock.observe(blocks, at: 500)
        XCTAssertTrue(lock.locked)
        XCTAssertTrue(lock.observe([], at: 1000).isEmpty)
        XCTAssertTrue(lock.observe([], at: 1500).isEmpty)
        XCTAssertTrue(lock.observe([], at: 2000).isEmpty)
        let cleared = lock.observe([], at: 2500)
        XCTAssertEqual(cleared, [ScreenLock.Send(id: "auto-1", payload: nil, forget: true)])
        XCTAssertFalse(lock.locked)
        XCTAssertTrue(lock.displayed.isEmpty)
        // Aynı ekrana dönüldü (dedektör yeni kimlik verdi): ilk okumada aynı kutular ve çevirilerle çizilir.
        let back = lock.observe(Self.screen(dy: 0.003), at: 3000)
        XCTAssertTrue(lock.locked)
        XCTAssertEqual(lock.cacheHits, 1)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.payload?.blocks, items)
        // İzleyicinin yeni kimlikle gönderdiği aynı ekran ikinci kutu açmaz.
        XCTAssertTrue(lock.offer(id: "auto-7", payload: Self.payload(Self.screen(dy: 0.003).map { Self.item($0.key, $0) })).isEmpty)
    }

    func testMissionNoticeAndPhoneStayOutOfTheLock() {
        XCTAssertTrue(ScreenLock.covers("auto-3"))
        XCTAssertFalse(ScreenLock.covers(MissionLine.areaId))
        XCTAssertFalse(ScreenLock.covers(ScreenNotices.idPrefix + "1"))
        XCTAssertFalse(ScreenLock.covers("game-phone"))
        XCTAssertFalse(ScreenLock.covers("preset-help"))
    }
}
