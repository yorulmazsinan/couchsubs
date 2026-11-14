// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SamsungTVTests: XCTestCase {
    func testAddressCarriesAppNameAndToken() {
        XCTAssertEqual(SamsungMessages.url(host: "192.168.1.20", token: nil)?.absoluteString,
                       "wss://192.168.1.20:8002/api/v2/channels/samsung.remote.control?name=Q291Y2hTdWJz")
        XCTAssertEqual(SamsungMessages.url(host: "192.168.1.20", token: "123")?.absoluteString.hasSuffix("&token=123"), true)
        XCTAssertEqual(SamsungMessages.url(host: "192.168.1.20", token: "")?.absoluteString.contains("token"), false)
    }

    /// Geçersiz adres uygulamayı kapatmaz: bağlantı hatayla biter.
    func testBadAddressFailsInsteadOfCrashing() async {
        XCTAssertNil(SamsungMessages.url(host: "192.168.1.20:8002", token: nil))
        let client = SamsungClient(tv: LGTV(name: "TV", host: "192.168.1.20:8002", brand: .samsung), token: nil)
        defer { client.close() }
        do {
            _ = try await client.connect()
            XCTFail("bağlanmamalıydı")
        } catch {
            XCTAssertEqual(error as? SamsungClient.SamsungError, .cannotConnect)
        }
    }

    func testLaunchMessageCarriesParametersAsMetaTag() throws {
        let data = SamsungMessages.launch(appId: "CouchSubsT.CouchSubs", params: ["server": "http://1.2.3.4:8787"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "ms.channel.emit")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["event"] as? String, "ed.apps.launch")
        let inner = try XCTUnwrap(params["data"] as? [String: Any])
        XCTAssertEqual(inner["appId"] as? String, "CouchSubsT.CouchSubs")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((inner["metaTag"] as? String ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(meta["server"] as? String, "http://1.2.3.4:8787")
    }

    func testApprovedConnectionGivesToken() throws {
        XCTAssertEqual(try SamsungMessages.connectResult(#"{"event":"ms.channel.connect","data":{"token":"55"}}"#), "55")
        XCTAssertEqual(try SamsungMessages.connectResult(#"{"event":"ms.channel.connect","data":{}}"#), "")
    }

    func testRefusedConnectionThrows() {
        XCTAssertThrowsError(try SamsungMessages.connectResult(#"{"event":"ms.channel.unauthorized"}"#))
    }

    func testUnansweredPromptStopsWaiting() {
        XCTAssertThrowsError(try SamsungMessages.connectResult(#"{"event":"ms.channel.timeOut"}"#)) { error in
            XCTAssertEqual(error as? SamsungClient.SamsungError, .cannotConnect)
        }
    }

    /// #40: TV jetonsuz "connect" dönünce saklı jeton silinmemeli; silinirse her bağlantıda TV yeniden izin sorar.
    func testEmptyTokenDoesNotReplaceSavedOne() {
        XCTAssertEqual(SamsungTokenHolder.keptToken(stored: "55", received: ""), "55")
        XCTAssertEqual(SamsungTokenHolder.keptToken(stored: "55", received: "77"), "77")
        XCTAssertEqual(SamsungTokenHolder.keptToken(stored: nil, received: ""), "")
    }

    /// #40: bekçinin bağlantısında TV yeni jeton verirse sonraki bağlantı onu kullanır ve jeton saklanır.
    func testKeeperRemembersNewToken() {
        var saved: [String] = []
        let holder = SamsungTokenHolder(token: "") { saved.append($0) }
        holder.received("")
        XCTAssertEqual(saved, [])
        holder.received("88")
        XCTAssertEqual(holder.current, "88")
        holder.received("88")
        holder.received("")
        XCTAssertEqual(holder.current, "88")
        XCTAssertEqual(saved, ["88"])
    }

    func testOtherMessagesAreIgnored() throws {
        XCTAssertNil(try SamsungMessages.connectResult(#"{"event":"ms.channel.ready"}"#))
        XCTAssertNil(try SamsungMessages.connectResult("not json"))
    }

    func testDeviceNameIsRead() {
        let data = Data(#"{"device":{"name":"[TV] Samsung QN70F"}}"#.utf8)
        XCTAssertEqual(SamsungMessages.deviceName(data), "[TV] Samsung QN70F")
        XCTAssertNil(SamsungMessages.deviceName(Data("{}".utf8)))
    }

    func testBrandDefaultsToLGForSavedTVs() throws {
        let saved = Data(#"{"name":"LG TV","host":"192.168.1.230"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LGTV.self, from: saved).brand, .lg)
    }

    func testBrandSurvivesSaving() throws {
        let tv = LGTV(name: "S", host: "1.2.3.4", brand: .samsung)
        XCTAssertEqual(try JSONDecoder().decode(LGTV.self, from: JSONEncoder().encode(tv)), tv)
    }

    func testLocatorDoesNotMoveToAnotherBrand() {
        let saved = LGTV(name: "Salon", host: "1.1.1.1", brand: .lg)
        XCTAssertNil(TVLocator.moved(saved, among: [LGTV(name: "Salon", host: "1.1.1.2", brand: .samsung)]))
    }
}
