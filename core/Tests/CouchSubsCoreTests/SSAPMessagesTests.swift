// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

final class SSAPMessagesTests: XCTestCase {
    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testRegisterAsksForPromptPairingWithLaunchPermissions() throws {
        let message = try json(SSAPMessages.register(clientKey: nil))
        XCTAssertEqual(message["type"] as? String, "register")
        let payload = try XCTUnwrap(message["payload"] as? [String: Any])
        XCTAssertEqual(payload["pairingType"] as? String, "PROMPT")
        XCTAssertNil(payload["client-key"])
        let manifest = try XCTUnwrap(payload["manifest"] as? [String: Any])
        let permissions = try XCTUnwrap(manifest["permissions"] as? [String])
        XCTAssertTrue(permissions.contains("LAUNCH"))
        XCTAssertTrue(permissions.contains("READ_RUNNING_APPS"))
    }

    func testRegisterCarriesStoredClientKey() throws {
        let payload = try XCTUnwrap(try json(SSAPMessages.register(clientKey: "abc123"))["payload"] as? [String: Any])
        XCTAssertEqual(payload["client-key"] as? String, "abc123")
    }

    func testLaunchRequestCarriesAppIdAndParams() throws {
        let data = SSAPMessages.request(id: "7", uri: "ssap://system.launcher/launch",
                                        payload: ["id": "com.couchsubs.tv", "params": ["server": "http://1.2.3.4:8787"]])
        let message = try json(data)
        XCTAssertEqual(message["type"] as? String, "request")
        XCTAssertEqual(message["id"] as? String, "7")
        XCTAssertEqual(message["uri"] as? String, "ssap://system.launcher/launch")
        let payload = try XCTUnwrap(message["payload"] as? [String: Any])
        XCTAssertEqual(payload["id"] as? String, "com.couchsubs.tv")
        XCTAssertEqual((payload["params"] as? [String: Any])?["server"] as? String, "http://1.2.3.4:8787")
    }

    func testSSDPResponseYieldsHost() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.153:1990/abc/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\nSERVER: WebOS/4.4.0 UPnP/1.0\r\n\r\n"
        XCTAssertEqual(LGDiscovery.host(fromSSDPResponse: response), "192.168.1.153")
        XCTAssertNil(LGDiscovery.host(fromSSDPResponse: "HTTP/1.1 200 OK\r\nST: urn:other\r\n\r\n"))
    }

    // Sorulan hedefi aynen geri söyleyen yanıt (webOS başlığı yok, cihaz tanımı 1990'da değil) LG diye doğrulanmaz: Mac'te
    // Android TV "LG TV — 192.168.1.133" diye listeleniyor, Bağlan "TV yanıt vermedi" diyordu (X, Toshiba Android TV).
    func testEchoedSearchTargetIsNotTakenAsLG() {
        let lg = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.153:1990/abc/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\nSERVER: WebOS/4.4.0 UPnP/1.0\r\n\r\n"
        XCTAssertEqual(LGDiscovery.hit(fromSSDPResponse: lg), .init(host: "192.168.1.153", confirmed: true))
        let lgNoServer = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.153:1990/x.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\n\r\n"
        XCTAssertEqual(LGDiscovery.hit(fromSSDPResponse: lgNoServer)?.confirmed, true)
        let echo = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.133:49152/description.xml\r\nST: urn:lge-com:service:webos-second-screen:1\r\nUSN: uuid:5f9ec1b3-ed59-1900-4530-00a0ded0e7e6::urn:lge-com:service:webos-second-screen:1\r\nSERVER: Linux/4.9.125 UPnP/1.0 Portable SDK for UPnP devices/1.6.18\r\n\r\n"
        XCTAssertEqual(LGDiscovery.hit(fromSSDPResponse: echo), .init(host: "192.168.1.133", confirmed: false))
        // Doğrulanmamış adres: LG yoklaması tanırsa LG, Android TV portu açıksa Android TV, hiçbiri değilse listelenmez.
        let android = LGDiscovery.classify(host: "192.168.1.133", probed: nil, androidPortOpen: true)
        XCTAssertEqual(android, LGTV(name: "Android TV", host: "192.168.1.133", brand: .androidTV))
        XCTAssertNil(LGDiscovery.classify(host: "192.168.1.133", probed: nil, androidPortOpen: false))
        let real = LGTV(name: "[LG] webOS TV", host: "192.168.1.133")
        XCTAssertEqual(LGDiscovery.classify(host: "192.168.1.133", probed: real, androidPortOpen: true), real)
        // "ssdp:all" yanıtında LG başlığı zaten kanıttır.
        let root = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:1259/\r\nST: upnp:rootdevice\r\nUSN: uuid:LGTV2017-1234::upnp:rootdevice\r\n\r\n"
        XCTAssertEqual(LGDiscovery.hit(fromSSDPResponse: root, searchTarget: LGDiscovery.allTarget)?.confirmed, true)
    }

    // Yanlış etiketlenen Android TV, kapalı LG'nin "yeni adresi" sanılmaz (bekçi eskiden onu LG kaydına yazabiliyordu).
    func testLocatorDoesNotMoveLGToAnAndroidTV() {
        let saved = LGTV(name: "[LG] webOS TV", host: "192.168.1.20")
        XCTAssertNil(TVLocator.moved(saved, among: [LGTV(name: "Android TV", host: "192.168.1.133", brand: .androidTV)]))
    }

    // webOS 3.x (2017) ikinci ekran hedefine cevap vermiyor; "ssdp:all" yanıtı LG olarak tanınır, başka cihaz alınmaz (#498).
    func testSSDPAllResponseFromOldWebOSIsRecognised() {
        let root = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:1259/\r\nST: upnp:rootdevice\r\nUSN: uuid:LGTV2017-1234::upnp:rootdevice\r\nSERVER: Linux/3.10.19-32.afro.4 UPnP/1.0 LGE WebOS TV LGE_DLNA_SDK/1.6.0\r\n\r\n"
        XCTAssertEqual(LGDiscovery.host(fromSSDPResponse: root, searchTarget: LGDiscovery.allTarget), "192.168.1.40")
        let netflix = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.40:9080\r\nST: urn:mdx-netflix-com:service:target:1\r\nUSN: uuid:LGTV2017-1234::urn:mdx-netflix-com:service:target:1\r\n\r\n"
        XCTAssertEqual(LGDiscovery.host(fromSSDPResponse: netflix, searchTarget: LGDiscovery.allTarget), "192.168.1.40")
        let router = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.1:49152/desc.xml\r\nST: upnp:rootdevice\r\nUSN: uuid:abcd::upnp:rootdevice\r\nSERVER: Linux UPnP/1.0 MiniUPnPd\r\n\r\n"
        XCTAssertNil(LGDiscovery.host(fromSSDPResponse: router, searchTarget: LGDiscovery.allTarget))
        // Asıl aramada "webOS" geçen başka hedefler sayılmaz: yalnız ikinci ekran servisi.
        XCTAssertNil(LGDiscovery.host(fromSSDPResponse: root))
    }

    // Adres adres tarama (iPhone'da multicast izni yokken): LG cihaz tanımı ve ikinci ekran sunucusunun karşılığı tanınır.
    func testScanRecognisesAnLGTV() {
        let xml = "<?xml version=\"1.0\"?><root><device><friendlyName> [LG] webOS TV UK7550 </friendlyName><manufacturer>LG Electronics</manufacturer></device></root>"
        XCTAssertTrue(LGDiscovery.isLGDescription(xml))
        XCTAssertEqual(LGDiscovery.friendlyName(fromDescription: xml), "[LG] webOS TV UK7550")
        XCTAssertFalse(LGDiscovery.isLGDescription("<root><device><manufacturer>Synology</manufacturer></device></root>"))
        XCTAssertFalse(LGDiscovery.isLGDescription("<html>LG Electronics router</html>"))
        XCTAssertNil(LGDiscovery.friendlyName(fromDescription: "<device><friendlyName></friendlyName></device>"))
        XCTAssertTrue(LGDiscovery.isSSAPGreeting("Hello world\n"))
        XCTAssertFalse(LGDiscovery.isSSAPGreeting("<html>Grafana</html>"))
    }

    func testUnicastSearchNamesTheTarget() {
        let request = LGDiscovery.searchRequest(searchTarget: LGDiscovery.searchTarget, host: "192.168.1.153:1900")
        XCTAssertTrue(request.hasPrefix("M-SEARCH * HTTP/1.1\r\nHOST: 192.168.1.153:1900\r\n"))
        XCTAssertTrue(request.contains("ST: urn:lge-com:service:webos-second-screen:1\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
    }
}
