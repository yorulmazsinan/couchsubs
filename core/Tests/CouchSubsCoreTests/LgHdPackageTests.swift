// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// #1098: LG 43LH590V (Full HD, webOS 3.x) sayfanın yalnız sol üst 1280x720'sini çiziyordu. Kurulumda Full HD webOS 3.x
/// TV'ye paket appinfo.json'da 1280x720 çözünürlükle gider. Ortak vakalar Fixtures/lg-hd-package.json (Windows
/// LgHdPackageTests.cs, Android LgHdPackageTest.kt aynı dosyayı okur).
final class LgHdPackageTests: XCTestCase {
    struct Fixture: Decodable {
        struct Case: Decodable { let note: String; let reply: String; let hd: Bool; let model: String? }
        let systemInfo: [Case]
        let package: String
        let appInfo: String
        let adaptedAppInfo: String
        let appJs: String
    }

    private func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("lg-hd-package.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func ipk(_ fixture: Fixture) -> [UInt8] { [UInt8](Data(base64Encoded: fixture.package)!) }

    /// tar'daki dosyalar (ad → içerik).
    private func files(_ ipk: [UInt8]) throws -> [String: String] {
        let members = try XCTUnwrap(LgHdPackage.readAr(ipk))
        let data = try XCTUnwrap(members.first { $0.name == "data.tar.gz" })
        let tar = [UInt8](try Gzip.decompress(Data(data.body)))
        var out: [String: String] = [:]
        var offset = 0
        while offset + 512 <= tar.count, !tar[offset..<(offset + 512)].allSatisfy({ $0 == 0 }) {
            let name = String(decoding: tar[offset..<(offset + 100)].prefix { $0 != 0 }, as: UTF8.self)
            let size = Int(String(decoding: tar[(offset + 124)..<(offset + 136)].prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            out[name] = String(decoding: tar[(offset + 512)..<(offset + 512 + size)], as: UTF8.self)
            offset += 512 + (size + 511) / 512 * 512
        }
        return out
    }

    func testOnlyFullHDWebOS3TVsGetThe720pPackage() throws {
        for item in try fixture().systemInfo {
            let screen = LgHdPackage.screen(reply: item.reply)
            XCTAssertEqual(screen.hd, item.hd, item.note)
            XCTAssertEqual(screen.model, item.model, item.note)
        }
        XCTAssertEqual(LgHdPackage.screen(reply: try fixture().systemInfo[0].reply).summary,
                       "43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720")
    }

    func testAppInfoResolutionBecomes720pAndNothingElseChanges() throws {
        let fixture = try fixture()
        let original = ipk(fixture)
        let adapted = try XCTUnwrap(LgHdPackage.adapt(original))
        let before = try files(original), after = try files(adapted)
        let appInfo = "usr/palm/applications/com.couchsubs.tv/appinfo.json"
        XCTAssertEqual(before[appInfo], fixture.appInfo)
        XCTAssertEqual(after[appInfo], fixture.adaptedAppInfo)
        XCTAssertTrue(after[appInfo]!.contains(#""resolution": "1280x720" ,"#))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(after[appInfo]!.utf8)))
        // app.js'teki "1920x1080" ve diğer dosyalar değişmez.
        XCTAssertEqual(after["usr/palm/applications/com.couchsubs.tv/app.js"], fixture.appJs)
        XCTAssertEqual(after.count, before.count)
        for (name, text) in before where name != appInfo { XCTAssertEqual(after[name], text, name) }
        // ar üyeleri ve control.tar.gz aynı; ar boyutu yeni gövdeye göre.
        let a = try XCTUnwrap(LgHdPackage.readAr(original)), b = try XCTUnwrap(LgHdPackage.readAr(adapted))
        XCTAssertEqual(a.map(\.name), ["debian-binary", "control.tar.gz", "data.tar.gz"])
        XCTAssertEqual(b.map(\.name), a.map(\.name))
        XCTAssertEqual(b[0].body, a[0].body)
        XCTAssertEqual(b[1].body, a[1].body)
        // Zaten 1280x720 olan paket bir daha değişmez; bozuk paket değişmez.
        XCTAssertNil(LgHdPackage.adapt(adapted))
        XCTAssertNil(LgHdPackage.adapt(Array("not an ipk".utf8)))
    }

    func testCompressedDataRoundTripsThroughGzip() throws {
        let data = Array((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        XCTAssertEqual([UInt8](try Gzip.decompress(Data(Gzip.compress(data)))), data)
        // Sıkıştırmasız bloklar (70000 bayt: iki blok) Foundation'ın açıcısıyla açılır.
        let stored = Gzip.stored(data)
        XCTAssertEqual(stored.count, data.count + 10)
        XCTAssertEqual([UInt8](try (Data(stored) as NSData).decompressed(using: .zlib) as Data), data)
        XCTAssertEqual(Gzip.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Kurulum

    final class FakeRunner: CommandRunning, @unchecked Sendable {
        var calls: [(arguments: [String], input: URL?, bytes: [UInt8]?)] = []
        let reply: String
        let version: String
        init(reply: String, version: String) { self.reply = reply; self.version = version }
        func run(_ executable: String, _ arguments: [String], input: URL?) async throws -> CommandResult {
            calls.append((arguments, input, input.flatMap { try? [UInt8](Data(contentsOf: $0)) }))
            let line = arguments.last ?? ""
            if line == LgHdPackage.systemInfoCommand { return CommandResult(status: 0, output: reply) }
            if line.contains("appinfo.json") { return CommandResult(status: 0, output: "\"version\": \"\(version)\"") }
            return CommandResult(status: 0, output: "")
        }
    }

    private func install(reply: String) async throws -> (FakeRunner, URL, String) {
        let fixture = try fixture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lg-hd-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appendingPathComponent("com.couchsubs.tv_0.9.122_all.ipk")
        try Data(ipk(fixture)).write(to: package)
        let runner = FakeRunner(reply: reply, version: "0.9.122")
        let installer = DevModeInstaller(host: "192.168.1.8", keyFile: URL(fileURLWithPath: "/tmp/key"), runner: runner,
                                         pollInterval: .milliseconds(1), installTimeout: .milliseconds(200),
                                         verifyTimeout: .milliseconds(200), keyServerOpen: { _ in false })
        let note = try await installer.install(package: package, version: "0.9.122")
        return (runner, package, note)
    }

    func testFullHDWebOS3TVGetsTheAdaptedPackageUnderTheSameName() async throws {
        let fixture = try fixture()
        let (runner, package, note) = try await install(reply: fixture.systemInfo[0].reply)
        XCTAssertEqual(note, "LG paketi: 43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720")
        let upload = try XCTUnwrap(runner.calls.first { $0.input != nil })
        XCTAssertNotEqual(upload.input, package)
        XCTAssertEqual(upload.input?.lastPathComponent, package.lastPathComponent)
        XCTAssertTrue(upload.arguments.last!.contains("cat > '/media/developer/temp/com.couchsubs.tv_0.9.122_all.ipk'"))
        let sent = try XCTUnwrap(upload.bytes)
        XCTAssertEqual(try files(sent)["usr/palm/applications/com.couchsubs.tv/appinfo.json"], fixture.adaptedAppInfo)
        // Geçici kopya silinir.
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.input!.path))
    }

    func testOtherTVsGetThePackageUnchanged() async throws {
        let fixture = try fixture()
        for reply in [fixture.systemInfo.first { !$0.hd && $0.model == "OLED55C24LA" }!.reply, ""] {
            let (runner, package, note) = try await install(reply: reply)
            let upload = try XCTUnwrap(runner.calls.first { $0.input != nil })
            XCTAssertEqual(upload.input, package)
            XCTAssertEqual(upload.bytes, ipk(fixture))
            XCTAssertTrue(note.hasSuffix("→ 1920x1080"), note)
        }
    }
}
