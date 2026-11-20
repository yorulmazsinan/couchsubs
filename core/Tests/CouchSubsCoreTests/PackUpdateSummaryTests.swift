// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import XCTest
@testable import CouchSubsCore

/// "Paketleri şimdi güncelle" sonucunun özeti: eklenen, güncellenen paketler ve gelen satırlar.
final class PackUpdateSummaryTests: XCTestCase {
    func testNothingDownloadedIsEmpty() {
        let summary = PackUpdateSummary(before: [("gta-6", 74_673)], downloaded: [])
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.newLines, 0)
    }

    func testUpdatedAndAddedPacks() {
        let summary = PackUpdateSummary(
            before: [("gta-6", 74_673), ("rdr-2", 20_000), ("elden-ring", 37_951)],
            downloaded: [.init(id: "gta-6", title: "Grand Theft Auto VI", lines: 86_973),
                         .init(id: "rdr-2", title: "Red Dead Redemption 2", lines: 20_800),
                         .init(id: "death-stranding-2", title: "Death Stranding 2", lines: 23_132)])
        XCTAssertEqual(summary.updated.map(\.id), ["gta-6", "rdr-2"])
        XCTAssertEqual(summary.updated.map(\.lineDelta), [12_300, 800])
        XCTAssertEqual(summary.added.map(\.id), ["death-stranding-2"])
        XCTAssertEqual(summary.added.first?.lineDelta, 23_132)
        XCTAssertEqual(summary.newLines, 12_300 + 800 + 23_132)
    }

    /// Satırı azalan (temizlenen) paket güncellenmiş sayılır ama toplam yeni satırdan düşülmez.
    func testShrinkingPackDoesNotReduceNewLines() {
        let summary = PackUpdateSummary(before: [("a", 1000), ("b", 500)],
                                        downloaded: [.init(id: "a", title: "A", lines: 900), .init(id: "b", title: "B", lines: 700)])
        XCTAssertEqual(summary.updated.map(\.lineDelta), [-100, 200])
        XCTAssertEqual(summary.newLines, 200)
    }

    /// Aynı kimlik kitaplıkta iki kez (uygulamayla gelen ve indirilen): son gelen geçerli; inen paket bir kez sayılır.
    func testDuplicatesUseLastAndCountOnce() {
        let summary = PackUpdateSummary(before: [("gta-6", 60_000), ("gta-6", 74_673)],
                                        downloaded: [.init(id: "gta-6", title: "GTA VI", lines: 86_973),
                                                     .init(id: "gta-6", title: "GTA VI", lines: 86_973)])
        XCTAssertEqual(summary.changes.count, 1)
        XCTAssertEqual(summary.changes.first?.lineDelta, 12_300)
    }

    /// Liste yerel önbellekten değil sunucudan alınır (sunucu `max-age=300` gönderiyor); paketler varsayılan kuralla.
    func testListIgnoresLocalCache() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pack = Data("pack".utf8)
        let sha = PackUpdater.sha256(pack)
        let listing = Data(#"{"packs":[{"id":"gta-6","title":"GTA VI","version":5,"sha256":"\#(sha)"}]}"#.utf8)
        let policies = Policies()
        let updater = PackUpdater(baseURL: URL(string: "https://packs.test")!, directory: directory,
                                  stateFile: directory.appendingPathComponent("state.json"), fetch: { request in
            policies.add(request.url!.path, request.cachePolicy)
            let body = request.url!.path == "/v1/packs" ? listing : pack
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let result = await updater.refresh(force: true)
        XCTAssertEqual(result.downloaded, ["gta-6"])
        XCTAssertEqual(policies.value["/v1/packs"], .reloadIgnoringLocalCacheData)
        XCTAssertEqual(policies.value["/v1/packs/gta-6"], .useProtocolCachePolicy)
    }
}

private final class Policies: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: URLRequest.CachePolicy] = [:]
    func add(_ path: String, _ policy: URLRequest.CachePolicy) { lock.withLock { stored[path] = policy } }
    var value: [String: URLRequest.CachePolicy] { lock.withLock { stored } }
}
