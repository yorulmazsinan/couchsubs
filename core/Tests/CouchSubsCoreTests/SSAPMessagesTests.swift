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
