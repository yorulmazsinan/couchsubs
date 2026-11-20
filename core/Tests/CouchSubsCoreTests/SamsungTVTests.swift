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

    /// #637, #511: kurulu olmayan uygulamaya DEEP_LINK gidince Smart Hub "Sunucu bakım altında (1544007)" diyor; önce TV'nin
    /// kurulu uygulama listesine bakılır.
    func testInstalledAppListDecidesLaunch() throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(SamsungMessages.installedAppsRequest.utf8)) as? [String: Any])
        XCTAssertEqual((request["params"] as? [String: Any])?["event"] as? String, "ed.installedApp.get")

        let listed = #"{"data":{"data":[{"appId":"111299001912","app_type":2,"name":"YouTube"},{"appId":"CouchSubsT.CouchSubs","app_type":2,"name":"CouchSubs"}]},"event":"ed.installedApp.get","from":"host"}"#
        XCTAssertEqual(SamsungMessages.installedApp(listed, appId: "CouchSubsT.CouchSubs"), .installed(appType: 2))
        XCTAssertEqual(SamsungMessages.installedApp(listed.replacingOccurrences(of: "CouchSubsT.CouchSubs", with: "Baska.App"),
                                                    appId: "CouchSubsT.CouchSubs"), .missing)
        XCTAssertNil(SamsungMessages.installedApp(#"{"event":"ed.edenTV.update","data":{}}"#, appId: "CouchSubsT.CouchSubs"))
        XCTAssertNil(SamsungMessages.installedApp("not json", appId: "CouchSubsT.CouchSubs"))

        XCTAssertEqual(SamsungMessages.actionType(appType: 2), "DEEP_LINK")
        XCTAssertEqual(SamsungMessages.actionType(appType: nil), "DEEP_LINK")
        XCTAssertEqual(SamsungMessages.actionType(appType: 4), "NATIVE_LAUNCH")
        let native = try XCTUnwrap(JSONSerialization.jsonObject(with: SamsungMessages.launch(appId: "A.B", params: [:], actionType: "NATIVE_LAUNCH")) as? [String: Any])
        XCTAssertEqual(((native["params"] as? [String: Any])?["data"] as? [String: Any])?["action_type"] as? String, "NATIVE_LAUNCH")
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

    // #343: 8001 yanıtındaki geliştirici modu ve Host PC IP.
    func testDeveloperModeAndHostPcIpAreRead() {
        let on = Data(#"{"device":{"developerMode":"1","developerIP":"192.168.1.50"}}"#.utf8)
        XCTAssertEqual(SamsungMessages.developerMode(on), true)
        XCTAssertEqual(SamsungMessages.developerIp(on), "192.168.1.50")
        let off = Data(#"{"device":{"developerMode":"0","developerIP":"0.0.0.0"}}"#.utf8)
        XCTAssertEqual(SamsungMessages.developerMode(off), false)
        XCTAssertNil(SamsungMessages.developerIp(off))
        XCTAssertNil(SamsungMessages.developerMode(Data(#"{"device":{"name":"TV"}}"#.utf8)))
        XCTAssertNil(SamsungMessages.developerIp(Data("not json".utf8)))
    }

    func testHostPcIpMismatchNeedsBothAddresses() {
        XCTAssertTrue(SamsungDeveloperInfo.hostPcIpMismatch(developerIp: "192.168.1.50", computer: "192.168.1.34"))
        XCTAssertFalse(SamsungDeveloperInfo.hostPcIpMismatch(developerIp: "192.168.1.34", computer: "192.168.1.34"))
        XCTAssertFalse(SamsungDeveloperInfo.hostPcIpMismatch(developerIp: nil, computer: "192.168.1.34"))
        XCTAssertFalse(SamsungDeveloperInfo.hostPcIpMismatch(developerIp: "192.168.1.50", computer: nil))
    }

    /// #524: TV "geliştirici modu açık, Host PC IP bu telefon" diyor ama 26101 reddediliyor: TV tam yeniden başlamamış.
    func testRefusalCauseComesFromTheTVsOwnDeveloperState() {
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: true, developerIp: "192.168.1.6", device: "192.168.1.6"), .notRestarted)
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: true, developerIp: "192.168.0.26", device: "192.168.1.103"),
                       .otherHostIp("192.168.0.26"))
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: false, developerIp: nil, device: "192.168.1.6"), .developerModeOff)
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: true, developerIp: nil, device: "192.168.1.6"), .unknown)
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: true, developerIp: "192.168.1.6", device: nil), .unknown)
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: nil, developerIp: nil, device: "192.168.1.6"), .unknown)
        // #484: TV 192.168.1.101, telefon başka ağda 192.168.0.26 (Host PC IP de 192.168.0.26): ayar doğru görünse de ağ farklı.
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: true, developerIp: "192.168.0.26", device: "192.168.0.26", tv: "192.168.1.101"),
                       .differentNetworks(tv: "192.168.1.101", device: "192.168.0.26"))
        XCTAssertEqual(SamsungDeveloperInfo.refusal(developerMode: true, developerIp: "192.168.1.103", device: "192.168.1.103", tv: "192.168.1.101"),
                       .notRestarted)
        XCTAssertFalse(SamsungDeveloperInfo.differentNetworks("192.168.1.101", "samsung-tv.local"))
        XCTAssertFalse(SamsungDeveloperInfo.differentNetworks("10.0.0.5", "10.0.0.200"))
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
