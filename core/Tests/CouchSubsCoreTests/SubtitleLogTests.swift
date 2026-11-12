// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

final class SubtitleLogTests: XCTestCase {
    func testWritesOnlyWhileEnabledAndKeepsOneBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("altyazi-log-\(UUID())")
        let file = folder.appendingPathComponent("altyazi.log")
        defer { try? FileManager.default.removeItem(at: folder) }
        SubtitleLog.write("yazılmamalı")
        SubtitleLog.enable(file: file)
        SubtitleLog.write("#1 \"Get down!\" → paket:mafia")
        SubtitleLog.disable()
        SubtitleLog.write("bu da yazılmamalı")
        SubtitleLog.flush()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("] #1 \"Get down!\" → paket:mafia\n"))
        XCTAssertFalse(text.contains("yazılmamalı"))
        XCTAssertTrue(text.hasPrefix("[20"))

        // Dosya 1 MB'yi geçince .1'e taşınır; ikinci taşımada eski yedek silinir (en çok ~2 MB).
        try Data(repeating: UInt8(ascii: "x"), count: SubtitleLog.maxBytes).write(to: file)
        SubtitleLog.enable(file: file)
        SubtitleLog.write("yeni dosya")
        SubtitleLog.flush()
        let backup = file.appendingPathExtension("1")
        XCTAssertEqual(try Data(contentsOf: backup).count, SubtitleLog.maxBytes)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("yeni dosya"))
        try Data(repeating: UInt8(ascii: "y"), count: SubtitleLog.maxBytes).write(to: file)
        SubtitleLog.write("üçüncü")
        SubtitleLog.disable()
        XCTAssertEqual(try Data(contentsOf: backup).first, UInt8(ascii: "y"))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("üçüncü"))
    }

    func testDefaultFileIsNextToRemotePlayLog() {
        XCTAssertTrue(SubtitleLog.defaultFile.path.hasSuffix("Library/Logs/CouchSubs/altyazi.log"))
    }

    func testExcerptIsQuotedSingleLineAndShort() {
        XCTAssertEqual(SubtitleLog.excerpt("ENZO: Get down!\nNow!"), "\"ENZO: Get down! / Now!\"")
        let long = SubtitleLog.excerpt(String(repeating: "a", count: 300))
        XCTAssertEqual(long.count, SubtitleLog.excerptLength + 2)
        XCTAssertTrue(long.hasSuffix("…\""))
    }

    func testVideoStallTrackerReportsGapFromChiakiLines() {
        let clock = TestClock()
        let tracker = VideoStallTracker(clock: clock.read)
        XCTAssertNil(tracker.note("[chiaki info] Received IDR frame, resuming decode"))
        XCTAssertEqual(tracker.note("[chiaki info] FEC failed, waiting for IDR frame"), "görüntü durdu: FEC hatası, IDR karesi bekleniyor")
        XCTAssertNil(tracker.note("[chiaki warning] Video FEC failure, already waiting for requested IDR"))
        clock.now += 1234
        XCTAssertEqual(tracker.note("[chiaki info] Received IDR frame, resuming decode"), "görüntü sürdü: IDR karesi geldi (1234 ms boşluk)")
        XCTAssertNil(tracker.note("[chiaki info] StreamConnection requesting IDR frame"))
    }

    /// Önbellekten dönen satır "önbellek", motorun yeni çevirdiği satır o motorun adıyla görünür.
    func testProbeTellsCacheHitsFromFreshTranslations() async {
        let cache = TranslationCache(engine: "deepl")
        let fresh = TranslationProbe()
        await TranslationProbe.$current.withValue(fresh) {
            if cache.value(for: "Run!") == nil { cache.store("Koş!", for: "Run!") }
        }
        XCTAssertEqual(fresh.outcome(), "çeviri:deepl")
        let cached = TranslationProbe()
        await TranslationProbe.$current.withValue(cached) {
            _ = cache.value(for: "Run!")
            cache.store("Koş!", for: "Run!")
        }
        XCTAssertEqual(cached.outcome(), "önbellek")
        XCTAssertEqual(TranslationProbe().outcome(fallbackEngine: "apple"), "çeviri:apple")
        XCTAssertEqual(cache.value(for: "Run!"), "Koş!")
    }
}
