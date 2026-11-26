// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore

final class SubtitleAccessTests: XCTestCase {
    struct Vectors: Decodable {
        struct Request: Decodable { let origin: String?; let query: String; let legacy: Bool; let status: Int; let usedLegacy: Bool }
        let key: String
        let requests: [Request]
        let peers: [String: Bool]
    }
    func testSharedAccessVectors() throws {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("subtitle-access.json")
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        for row in vectors.requests {
            for path in ["/events", "/speech/1.wav", "/voices/sample.wav", "/published.bin"] {
                let head = "GET \(path)\(row.query) HTTP/1.1\r\nHost: localhost:8787\r\n" + (row.origin.map { "Origin: \($0)\r\n" } ?? "")
                let request = try XCTUnwrap(SubtitleAccess.parse(head))
                let result = SubtitleAccess.authorize(request, key: vectors.key, allowLegacy: row.legacy)
                XCTAssertEqual(result.status, row.status, head)
                XCTAssertEqual(result.legacy, row.usedLegacy, head)
                // Paketli (http olmayan) ve kabul edilen her Origin aynen geri yansıtılır.
                let cors = row.status != 403 && row.origin.map { !$0.hasPrefix("http") } == true ? "Access-Control-Allow-Origin: \(row.origin!)\r\nVary: Origin\r\n" : ""
                XCTAssertEqual(SubtitleAccess.cors(request), cors)
            }
        }
        for (address, allowed) in vectors.peers { XCTAssertEqual(SubtitleAccess.isLocalPeer(address), allowed, address) }
    }
    /// İkinci ekran eski TV'lere tanınan anahtarsız geçişten yararlanmaz (Windows ve Android'de aynı durumlar).
    func testSecondScreenAlwaysNeedsTheKey() throws {
        let cases: [(String, Int)] = [("/view", 401), ("/view?k=yanlis", 401), ("/view?k=anahtar", 200),
                                      ("/events?viewer=second", 401), ("/events?viewer=second&k=anahtar", 200),
                                      ("/events", 200), ("/events?viewer=obs", 200)]
        for (target, status) in cases {
            let request = try XCTUnwrap(SubtitleAccess.parse("GET \(target) HTTP/1.1\r\nHost: 192.168.1.20:8787\r\n"))
            XCTAssertEqual(SubtitleAccess.authorize(request, key: "anahtar", allowLegacy: true).status, status, target)
        }
        // Tarayıcı aynı adresten açtığı sayfanın akışına Origin ile bağlanır.
        let same = try XCTUnwrap(SubtitleAccess.parse("GET /events?viewer=second&k=anahtar HTTP/1.1\r\nHost: 192.168.1.20:8787\r\nOrigin: http://192.168.1.20:8787\r\n"))
        XCTAssertEqual(SubtitleAccess.authorize(same, key: "anahtar", allowLegacy: true).status, 200)
    }

    /// Reddedilen Origin günlüğe değeriyle bir kez yazılır; en çok 16 farklı değer (Windows ve Android'de aynı).
    func testRejectedOriginIsLoggedOnce() throws {
        let log = SubtitleAccess.RejectedOrigins()
        let request = try XCTUnwrap(SubtitleAccess.parse("POST /pair HTTP/1.1\r\nHost: 192.168.1.20:8787\r\nOrigin: http://other.example\r\n"))
        XCTAssertEqual(SubtitleAccess.authorize(request, key: "anahtar", allowLegacy: true).status, 403)
        XCTAssertEqual(log.line(request), "altyazı sunucusu isteği reddetti (403): Origin \"http://other.example\" kabul edilmedi (yol /pair, Host 192.168.1.20:8787)")
        XCTAssertNil(log.line(request))
        for index in 0..<20 {
            let other = try XCTUnwrap(SubtitleAccess.parse("GET /events HTTP/1.1\r\nHost: a\r\nOrigin: http://o\(index).example\r\n"))
            XCTAssertEqual(log.line(other) != nil, index < 15)
        }
    }

    func testKeysAndAmbiguousRequests() throws {
        let key = SubtitleAccess.createKey()
        XCTAssertEqual(key.count, 22)
        XCTAssertNotEqual(key, SubtitleAccess.createKey())
        for head in ["Origin: null\r\nOrigin: null", "Host: localhost\r\nHost: other", " Origin: null"] {
            XCTAssertNil(SubtitleAccess.parse("GET /events HTTP/1.1\r\n" + head))
        }
        let request = try XCTUnwrap(SubtitleAccess.parse("GET /events?k=\(key)&k=\(key) HTTP/1.1\r\nHost: localhost"))
        XCTAssertEqual(SubtitleAccess.authorize(request, key: key, allowLegacy: true).status, 401)
    }
    func testKeylessObsPageIsNotReportedAsOldTVApp() async throws {
        let server = SubtitleServer(port: 0, allowLegacy: true)
        let port = try await server.start()
        defer { server.stop() }
        let (_, obs) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?viewer=obs")!)
        XCTAssertEqual((obs as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(server.hasLegacyClient)
        let (_, tv) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        XCTAssertEqual((tv as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(server.hasLegacyClient)
    }
    func testRotationRejectsPreviousKey() async throws {
        let server = SubtitleServer(port: 0, allowLegacy: false)
        let port = try await server.start()
        defer { server.stop() }
        let old = server.accessKey
        let (_, opened) = try await URLSession.shared.bytes(from: URL(string: "http://127.0.0.1:\(port)/events?k=\(old)")!)
        XCTAssertEqual((opened as? HTTPURLResponse)?.statusCode, 200)
        server.rotateKey(SubtitleAccess.createKey())
        XCTAssertEqual(server.connectedClients, 0)
        let (_, expired) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/events?k=\(old)")!)
        XCTAssertEqual((expired as? HTTPURLResponse)?.statusCode, 401)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/events")!)
        XCTAssertEqual((missing as? HTTPURLResponse)?.statusCode, 401)
    }
}
