// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import CouchSubsCore
final class SubtitlePairingTests: XCTestCase {
    func testSharedLifecycleVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)?.appendingPathComponent("subtitle-pairing.json"))
        let scenarios = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        for scenario in scenarios {
            var time: Int64 = 1000
            let pairing = SubtitlePairing(clock: { time })
            var id = ""
            for step in scenario["steps"] as! [[String: Any]] {
                let who = step["wrong"] as? Bool == true ? "not-the-request-secret" : id
                switch step["op"] as! String {
                case "session": pairing.setSession(step["value"] as! Bool)
                case "open": pairing.open()
                case "reset": pairing.reset()
                case "advance": time += Int64(step["ms"] as! Int)
                case "begin":
                    let ticket = pairing.begin()
                    XCTAssertEqual(ticket != nil, step["ok"] as! Bool, scenario["name"] as! String)
                    if let ticket { XCTAssertEqual(ticket.id.count, 22); XCTAssertEqual(ticket.code.count, 6); id = ticket.id }
                case "resolve": XCTAssertEqual(pairing.resolve(who, accept: step["accept"] as! Bool), step["ok"] as! Bool)
                case "poll": XCTAssertEqual(pairing.poll(who), step["state"] as! String)
                default: XCTFail("Bilinmeyen adım")
                }
            }
        }
    }

    func testWireApprovalAndRotation() async throws {
        let server = SubtitleServer(port: 0, allowLegacy: false)
        let port = try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        var request = URLRequest(url: URL(string: base + "/pair")!)
        request.httpMethod = "POST"
        let (_, closed) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((closed as? HTTPURLResponse)?.statusCode, 409)
        server.pairing.open()
        request.setValue("https://foreign.example", forHTTPHeaderField: "Origin")
        let (_, denied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        request.setValue(nil, forHTTPHeaderField: "Origin")
        let (data, _) = try await URLSession.shared.data(for: request)
        let ticket = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let id = try XCTUnwrap(ticket["id"])
        let url = URL(string: base + "/pair?id=" + id)!
        let (pending, _) = try await URLSession.shared.data(from: url)
        XCTAssertFalse(String(decoding: pending, as: UTF8.self).contains(server.accessKey))
        XCTAssertTrue(server.pairing.resolve(id, accept: true))
        let (approved, _) = try await URLSession.shared.data(from: url)
        XCTAssertTrue(String(decoding: approved, as: UTF8.self).contains(server.accessKey))
        server.rotateKey(SubtitleAccess.createKey())
        let (expired, _) = try await URLSession.shared.data(from: url)
        XCTAssertFalse(String(decoding: expired, as: UTF8.self).contains(server.accessKey))
        XCTAssertTrue(String(decoding: expired, as: UTF8.self).contains("expired"))
    }
}
