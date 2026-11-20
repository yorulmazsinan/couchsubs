// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

/// Sahte paket sunucusu: istekleri kaydeder, yol başına yanıt verir.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.responses[request.url!.path] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PackStoreTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private let base = URL(string: "https://packs.test")!
    private let pack = Data(#"{"format":1,"id":"demo","title":"Demo","entries":{"\#(PackKey.key("Hello there, my friend.")!)":"Merhaba dostum."}}"#.utf8)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.requests = []
        StubProtocol.responses = [:]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// Sunucunun biçimi: sürüm artan bir sayı (server/packs/scripts/build-index.mjs).
    private func manifest(sha: String) -> Data {
        Data(#"{"packs":[{"id":"demo","title":"Demo","version":1,"sha256":"\#(sha)","size":10,"entries":1}]}"#.utf8)
    }

    private func store(now: Date = Date()) -> PackStore {
        PackStore(baseURL: base, directory: directory, session: session, now: { now })
    }

    func testDownloadsVerifiedPackWithoutAnAccount() async throws {
        StubProtocol.responses["/v1/packs"] = (200, manifest(sha: PackStore.sha256(pack)))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        let store = store()
        let downloaded = try await store.refresh(force: true)
        XCTAssertEqual(downloaded, 1)
        let file = store.filesDirectory.appendingPathComponent("demo.json.gz")
        XCTAssertEqual(try Data(contentsOf: file), pack)
        // Paketler ücretsiz: istekler kimlik taşımaz.
        XCTAssertTrue(StubProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        // Kütüphane indirilen paketi okur.
        let library = GamePackLibrary(bundled: nil, user: store.filesDirectory)
        XCTAssertEqual(library.packs.map(\.id), ["demo"])
    }

    func testUnchangedPackIsNotDownloadedAgain() async throws {
        StubProtocol.responses["/v1/packs"] = (200, manifest(sha: PackStore.sha256(pack)))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        let store = store()
        try await store.refresh(force: true)
        StubProtocol.requests = []
        let second = try await store.refresh(force: true)
        XCTAssertEqual(second, 0)
        XCTAssertEqual(StubProtocol.requests.map { $0.url!.path }, ["/v1/packs"])
    }

    func testChecksumMismatchKeepsFileOut() async {
        StubProtocol.responses["/v1/packs"] = (200, manifest(sha: String(repeating: "0", count: 64)))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        let store = store()
        do {
            try await store.refresh(force: true)
            XCTFail("SHA-256 tutmadı")
        } catch {
            XCTAssertEqual(error as? PackStore.Failure, .badChecksum("demo"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.filesDirectory.appendingPathComponent("demo.json.gz").path))
    }

    func testServerErrorsAreReported() async {
        StubProtocol.responses["/v1/packs"] = (200, manifest(sha: PackStore.sha256(pack)))
        StubProtocol.responses["/v1/packs/demo"] = (404, Data())
        do {
            try await store().refresh(force: true)
            XCTFail("paket yok")
        } catch {
            XCTAssertEqual(error as? PackStore.Failure, .server(404))
        }
    }

    /// İndirilen paket, uygulamayla gelen aynı kimlikli paketin yerine geçer; sunucu yoksa uygulamayla gelen kalır.
    /// Bir paket inmeyince (ör. 429) sıradaki paketler yine iner, inenler bir daha indirilmez; yalnız inemeyen yeniden denenir.
    func testOneFailingPackDoesNotBlockTheOthers() async throws {
        let other = Data(#"{"format":1,"id":"gta-6","title":"GTA VI","entries":{"\#(PackKey.key("Hello there, my friend.")!)":"Merhaba dostum."}}"#.utf8)
        StubProtocol.responses["/v1/packs"] = (200, Data(#"{"packs":[{"id":"demo","title":"Demo","version":1,"sha256":"\#(PackStore.sha256(pack))"},{"id":"gta-6","title":"GTA VI","version":5,"sha256":"\#(PackStore.sha256(other))"}]}"#.utf8))
        StubProtocol.responses["/v1/packs/demo"] = (429, Data())
        StubProtocol.responses["/v1/packs/gta-6"] = (200, other)
        let store = store()
        do {
            try await store.refresh(force: true)
            XCTFail("demo inmedi")
        } catch {
            XCTAssertEqual(error as? PackStore.Failure, .server(429))
        }
        XCTAssertEqual(try Data(contentsOf: store.filesDirectory.appendingPathComponent("gta-6.json.gz")), other)
        let partial = await store.lastDownloadCount
        XCTAssertEqual(partial, 1)
        let stillDue = await store.needsRefresh()
        XCTAssertTrue(stillDue)
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        StubProtocol.requests = []
        let downloaded = try await store.refresh(force: false)
        XCTAssertEqual(downloaded, 1)
        XCTAssertEqual(StubProtocol.requests.map { $0.url!.path }, ["/v1/packs", "/v1/packs/demo"])
    }

    func testDownloadedPackReplacesBundledOne() async throws {
        let bundled = directory.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let old = Data(#"{"format":1,"id":"demo","title":"Demo (eski)","entries":{"\#(PackKey.key("Hello there, my friend.")!)":"Eski."}}"#.utf8)
        try old.write(to: bundled.appendingPathComponent("demo.json"))
        let store = store()
        let library = GamePackLibrary(bundled: bundled, user: store.filesDirectory)
        XCTAssertEqual(library.packs.map(\.title), ["Demo (eski)"])
        StubProtocol.responses["/v1/packs"] = (200, manifest(sha: PackStore.sha256(pack)))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        try await store.refresh(force: true)
        library.reload()
        XCTAssertEqual(library.packs.map(\.title), ["Demo"])
        XCTAssertEqual(library.match("Hello there, my friend.")?.text, "Merhaba dostum.")
    }

    func testRefreshIsDaily() async throws {
        StubProtocol.responses["/v1/packs"] = (200, Data(#"{"packs":[]}"#.utf8))
        let start = Date()
        try await store(now: start).refresh(force: true)
        let soon = await store(now: start.addingTimeInterval(6 * 3600)).needsRefresh()
        XCTAssertFalse(soon)
        let later = await store(now: start.addingTimeInterval(25 * 3600)).needsRefresh()
        XCTAssertTrue(later)
        // Yeni oyun: on dakikadan eski bakış yenilenir.
        let forGame = await store(now: start.addingTimeInterval(11 * 60)).needsRefresh(maxAge: PackStore.gameCheckInterval)
        XCTAssertTrue(forGame)
        StubProtocol.requests = []
        try await store(now: start.addingTimeInterval(6 * 3600)).refresh()
        XCTAssertTrue(StubProtocol.requests.isEmpty, "gün dolmadan istek yok")
    }

    func testRemovedPackIsDeletedFromCache() async throws {
        StubProtocol.responses["/v1/packs"] = (200, manifest(sha: PackStore.sha256(pack)))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        let store = store()
        try await store.refresh(force: true)
        StubProtocol.responses["/v1/packs"] = (200, Data(#"{"packs":[]}"#.utf8))
        try await store.refresh(force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.filesDirectory.appendingPathComponent("demo.json.gz").path))
    }
}
