// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// Paket eşleşme ölçümü: oyunun kendi satırlarından üretilmiş OCR benzeri ekranlar (tools/packs/bench.py).
/// İngilizce metin depoda olmadığından yalnız `COUCHSUBS_PACK_BENCH=<cases.json>` verilince çalışır;
/// `COUCHSUBS_PACK_BENCH_PACK` paket dosyası (varsayılan gta-v.json.gz). Kategori başına isabet, doğru ve yanlış yazar.
final class PackBenchmarkTests: XCTestCase {
    struct Cases: Decodable {
        struct Case: Decodable { let cat: String; let screen: String; let parts: [String] }
        let warmUp: String
        let cases: [Case]
    }

    func testPackMatchRate() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["COUCHSUBS_PACK_BENCH"] else { throw XCTSkip("COUCHSUBS_PACK_BENCH verilmedi") }
        let file = environment["COUCHSUBS_PACK_BENCH_PACK"] ?? "gta-v.json.gz"
        let fixtures = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // `COUCHSUBS_PACK_BENCH_DIR`: denenecek paketin klasörü (varsayılan gömülü paketler).
        let packs = try environment["COUCHSUBS_PACK_BENCH_DIR"].map { URL(fileURLWithPath: $0) } ?? bundledTestPack(file).deletingLastPathComponent()
        let source = packs.appendingPathComponent(file)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(file))
        let library = GamePackLibrary(bundled: directory, user: nil)
        XCTAssertNotNil(library.match(fixtures.warmUp))
        var stats: [String: (total: Int, hit: Int, correct: Int)] = [:]
        var order: [String] = []
        var wrong: [String] = []
        // `COUCHSUBS_PACK_BENCH_WRONG`: kategori başına yazılacak yanlış eşleşme sayısı (varsayılan 30).
        let wrongLimit = environment["COUCHSUBS_PACK_BENCH_WRONG"].flatMap(Int.init) ?? 30
        var missed: [String: [String]] = [:]
        for item in fixtures.cases {
            // Parçasız durum başka oyunun satırıdır: hiç eşleşmemeli, bulunursa yanlış sayılır.
            let expected = item.parts.compactMap { library.match($0)?.text }
            guard expected.count == item.parts.count else { continue }
            if stats[item.cat] == nil { order.append(item.cat) }
            var entry = stats[item.cat] ?? (0, 0, 0)
            entry.total += 1
            if let found = library.match(item.screen)?.text {
                entry.hit += 1
                if !expected.isEmpty, expected.allSatisfy({ found.contains($0) }) {
                    entry.correct += 1
                } else if wrong.filter({ $0.hasPrefix("[\(item.cat)]") }).count < wrongLimit {
                    wrong.append("[\(item.cat)] \(item.screen) → \(found) (beklenen: \(expected.joined(separator: " | ")))")
                }
            }
            else if missed[item.cat, default: []].count < 25 {
                missed[item.cat, default: []].append(item.screen)
            }
            stats[item.cat] = entry
        }
        var report: [String] = []
        var all = (total: 0, hit: 0, correct: 0)
        func row(_ name: String, _ entry: (total: Int, hit: Int, correct: Int)) -> String {
            String(format: "BENCH %@ %@ %d  doğru %.1f%%  yanlış %.1f%%", file, name, entry.total,
                   100.0 * Double(entry.correct) / Double(max(entry.total, 1)),
                   100.0 * Double(entry.hit - entry.correct) / Double(max(entry.total, 1)))
        }
        for category in order {
            let entry = stats[category]!
            all.total += entry.total
            all.hit += entry.hit
            all.correct += entry.correct
            report.append(row(category, entry))
        }
        report.append(row("TOPLAM", all))
        report += wrong.map { "BENCH-WRONG \($0)" }
        for (category, lines) in missed.sorted(by: { $0.key < $1.key }) {
            report += lines.map { "BENCH-MISS [\(category)] \($0.replacingOccurrences(of: "\n", with: " ⏎ "))" }
        }
        // Test çıktısı karışabildiği için sonuç ayrıca dosyaya yazılır: <cases.json>.<paket>.txt
        try report.joined(separator: "\n").write(toFile: "\(path).\(file).txt", atomically: true, encoding: .utf8)
        print(report.joined(separator: "\n"))
    }
}
