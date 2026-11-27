// SPDX-License-Identifier: AGPL-3.0-only

@testable import CouchSubsCore
import XCTest

/// Vestel Linux TV (deneysel): kayıtlı TV doğru geri okunur; eski kayıtlar ve diğer markalar etkilenmez.
final class VestelLinuxTVTests: XCTestCase {
    func testVestelTVRoundTrips() throws {
        let tv = LGTV(name: "Vestel Linux TV", host: "192.168.1.54", brand: .vestelLinux)
        let data = try JSONEncoder().encode(tv)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"vestelLinux\""))
        XCTAssertEqual(try JSONDecoder().decode(LGTV.self, from: data), tv)
    }

    func testOldRecordsStayLG() throws {
        let old = Data(#"{"name":"LG","host":"192.168.1.20"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LGTV.self, from: old).brand, .lg)
    }

    /// Bilgisayarın TV'de uygulama açamadığı markalar: TV uygulaması bilgisayara kendisi bağlanır.
    func testConnectsByItself() {
        XCTAssertTrue(TVBrand.vestelLinux.connectsByItself)
        XCTAssertTrue(TVBrand.androidTV.connectsByItself)
        XCTAssertFalse(TVBrand.lg.connectsByItself)
        XCTAssertFalse(TVBrand.samsung.connectsByItself)
    }
}
