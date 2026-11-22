// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubs

/// 21:9 / 32:9 Samsung monitörde paket geniş uygulama yüzeyiyle kurulur (#886); TV'lerde değişmez. Android'deki
/// WideScreenPackageTest ve Windows'taki WideScreenPackageTests ile aynı vakalar.
final class WideScreenPackageTests: XCTestCase {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func read(_ wgt: [UInt8], _ name: String) throws -> String {
        String(decoding: try XCTUnwrap(StoredZip.read(wgt).first { $0.name == name }).data, as: UTF8.self)
    }

    func testAppliesOnlyToUltraWideMonitors() {
        XCTAssertTrue(WideScreenPackage.applies(model: "LS49CG954SUXEN", resolution: nil))
        XCTAssertTrue(WideScreenPackage.applies(model: "LS34BG850SUXEN", resolution: nil))
        XCTAssertTrue(WideScreenPackage.applies(model: "LS57CG952NUXEN", resolution: nil))
        XCTAssertTrue(WideScreenPackage.applies(model: nil, resolution: "5120x1440"))
        XCTAssertTrue(WideScreenPackage.applies(model: nil, resolution: "3440x1440"))
        XCTAssertFalse(WideScreenPackage.applies(model: "LS32BM801UUXEN", resolution: "3840x2160"))
        XCTAssertFalse(WideScreenPackage.applies(model: "QE75QN900A", resolution: "7680x4320"))
        XCTAssertFalse(WideScreenPackage.applies(model: "QE55LS03B", resolution: "3840x2160"))
        XCTAssertFalse(WideScreenPackage.applies(model: "UE60KU7000", resolution: "1920x1080"))
        XCTAssertFalse(WideScreenPackage.applies(model: nil, resolution: nil))
        XCTAssertFalse(WideScreenPackage.applies(model: "", resolution: "garbage"))
    }

    func testResolutionIsReadFromThe8001Answer() {
        let info = SamsungTvInfo.parse(Data(#"{"device":{"modelName":"LS49CG95","resolution":"5120x1440"}}"#.utf8))
        XCTAssertEqual(info?.model, "LS49CG95")
        XCTAssertEqual(info?.resolution, "5120x1440")
    }

    func testRealPackageGetsWideSurfaceSettingAndViewport() throws {
        let config = try repoFile("tv-tizen/config.xml")
        XCTAssertFalse(config.contains(#"app_ui_type/base_screen_resolution""#))
        let original = StoredZip.write([StoredZip.Entry(name: "config.xml", data: Array(config.utf8)),
                                        StoredZip.Entry(name: "index.html", data: Array(try repoFile("tv-webos/index.html").utf8)),
                                        StoredZip.Entry(name: "app.js", data: Array("x".utf8))])
        let adapted = try WideScreenPackage.adapt(original)
        let adaptedConfig = try read(adapted, "config.xml")
        XCTAssertTrue(adaptedConfig.contains(WideScreenPackage.metadata))
        XCTAssertTrue(adaptedConfig.hasPrefix("<?xml"))
        XCTAssertTrue(XMLParser(data: Data(adaptedConfig.utf8)).parse())
        let html = try read(adapted, "index.html")
        XCTAssertTrue(html.contains(#"<meta name="viewport" content="width=device-width">"#))
        XCTAssertFalse(html.contains(#"content="width=1920""#))
        XCTAssertEqual(try read(adapted, "app.js"), "x")
        // İkinci kez: değişen bir şey yok.
        XCTAssertEqual(try WideScreenPackage.adapt(adapted), adapted)
    }
}
