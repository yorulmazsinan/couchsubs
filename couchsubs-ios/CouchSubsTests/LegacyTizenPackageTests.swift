// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubs

/// 2016 Samsung TV'lerde (Tizen 2.x) config.xml #71'de çalışan pakete döner (#621); yeni TV'lerde paket değişmez.
/// Android'deki LegacyTizenPackageTest ile aynı vakalar.
final class LegacyTizenPackageTests: XCTestCase {
    /// Depodaki gerçek config.xml.
    private func repoConfig() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("tv-tizen/config.xml"), encoding: .utf8)
    }

    private func wgt(_ config: String) -> [UInt8] {
        StoredZip.write([StoredZip.Entry(name: "config.xml", data: Array(config.utf8)),
                         StoredZip.Entry(name: "index.html", data: Array("<p>x</p>".utf8))])
    }

    private func configOf(_ wgt: [UInt8]) throws -> String {
        String(decoding: try XCTUnwrap(StoredZip.read(wgt).first { $0.name == "config.xml" }).data, as: UTF8.self)
    }

    func testAppliesOnlyToTizen2() {
        XCTAssertTrue(LegacyTizenPackage.applies("2.4.0"))
        XCTAssertTrue(LegacyTizenPackage.applies("2.4"))
        XCTAssertFalse(LegacyTizenPackage.applies("3.0"))
        XCTAssertFalse(LegacyTizenPackage.applies("4.0"))
        XCTAssertFalse(LegacyTizenPackage.applies("6.5"))
        XCTAssertFalse(LegacyTizenPackage.applies(""))
    }

    func testNetworkPublicAndScreenSettingAreRemovedOtherPrivilegesStay() throws {
        let config = try repoConfig()
        XCTAssertTrue(config.contains("privilege/network.public\""))
        XCTAssertTrue(config.contains("base_screen_resolution"))
        let adapted = try configOf(LegacyTizenPackage.adapt(wgt(config)))
        let withoutComments = adapted.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        XCTAssertFalse(withoutComments.contains("network.public"))
        XCTAssertFalse(withoutComments.contains("<tizen:metadata"))
        for kept in ["tv.window", "tv.inputdevice", "application.launch", "internet", "network.get"] {
            XCTAssertTrue(withoutComments.contains("http://tizen.org/privilege/\(kept)\""), kept)
        }
        XCTAssertTrue(withoutComments.contains("required_version=\"2.4\""))
        // Satır silinince XML hâlâ ayrışır.
        XCTAssertTrue(XMLParser(data: Data(adapted.utf8)).parse())
    }

    func testOtherFilesStayTheSame() throws {
        let files = try StoredZip.read(LegacyTizenPackage.adapt(wgt(try repoConfig())))
        XCTAssertEqual(files.map(\.name), ["config.xml", "index.html"])
        XCTAssertEqual(files[1].data, Array("<p>x</p>".utf8))
    }

    func testPackageWithoutThoseLinesIsUnchanged() throws {
        let plain = wgt("<widget><tizen:privilege name=\"http://tizen.org/privilege/internet\"/></widget>")
        XCTAssertEqual(try LegacyTizenPackage.adapt(plain), plain)
    }
}
