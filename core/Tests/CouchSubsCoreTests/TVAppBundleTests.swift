// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
@testable import CouchSubsCore

/// TV sayfasının bilgisayardan/telefondan sunulması (ince kabuk, docs/tv-ince-kabuk.md). Ortak deneme dosyası
/// Fixtures/tv-app-bundle.json (Windows TvAppBundleTests, Android TvAppBundleTest ve scripts/tv-shell.test.js ile aynı).
final class TVAppBundleTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Invalid: Decodable { let name: String; let app: String; enum CodingKeys: String, CodingKey { case name, app = "app.js" } }
        let key: String
        let files: [String: String]
        let version: String
        let shellApi: Int
        let sizes: [String: Int]
        let sha256: [String: String]
        let canonical: String
        let hmac: String
        let invalid: [Invalid]
    }

    private func fixture() throws -> Fixture {
        let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("tv-app-bundle.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func bundle(_ fixture: Fixture) throws -> TVAppBundle {
        try XCTUnwrap(TVAppBundle(files: fixture.files.mapValues { Data($0.utf8) }))
    }

    func testSharedVectors() throws {
        let fixture = try fixture()
        let bundle = try bundle(fixture)
        XCTAssertEqual(bundle.version, fixture.version)
        XCTAssertEqual(bundle.shellAPI, fixture.shellApi)
        XCTAssertEqual(bundle.files.map(\.path), TVAppBundle.paths)
        for file in bundle.files {
            XCTAssertEqual(file.sha256, fixture.sha256[file.path], file.path)
            XCTAssertEqual(file.data.count, fixture.sizes[file.path], file.path)
        }
        XCTAssertEqual(bundle.canonical, fixture.canonical)
        XCTAssertEqual(TVAppBundle.signature(bundle.canonical, key: fixture.key), fixture.hmac)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: bundle.manifest(key: fixture.key)) as? [String: Any])
        XCTAssertEqual(manifest["hmac"] as? String, fixture.hmac)
        XCTAssertEqual(manifest["version"] as? String, fixture.version)
        XCTAssertEqual(manifest["shellApi"] as? Int, fixture.shellApi)
        XCTAssertEqual(manifest["format"] as? Int, 1)
        let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
        XCTAssertEqual(files.compactMap { $0["path"] as? String }, TVAppBundle.paths)
    }

    func testRejectsPagesWithoutVersionOrShellAPI() throws {
        let fixture = try fixture()
        for invalid in fixture.invalid {
            var files = fixture.files.mapValues { Data($0.utf8) }
            files["app.js"] = Data(invalid.app.utf8)
            XCTAssertNil(TVAppBundle(files: files), invalid.name)
        }
        var missing = fixture.files.mapValues { Data($0.utf8) }
        missing["style.css"] = nil
        XCTAssertNil(TVAppBundle(files: missing))
    }

    func testFileLookupOnlyForOwnVersion() throws {
        let bundle = try bundle(fixture())
        XCTAssertEqual(bundle.file(at: "/tv/app/0.9.80/app.js")?.path, "app.js")
        XCTAssertNil(bundle.file(at: "/tv/app/0.9.79/app.js"))
        XCTAssertNil(bundle.file(at: "/tv/app/0.9.80/platform.js"))
        XCTAssertNil(bundle.file(at: "/tv/app/0.9.80/../app.js"))
        XCTAssertNil(bundle.file(at: "/tv/app/0.9.80/x/app.js"))
    }

    /// Depodaki TV sayfası (tv-webos) paketlenebilir olmalı: sürümü TV uygulamasıyla aynı, kabuk arayüzü bildirilmiş.
    func testRepositoryPageIsServable() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../tv-webos").standardized
        let bundle = try XCTUnwrap(TVAppBundle.load(directory: root))
        let appinfo = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("appinfo.json"))) as? [String: Any]
        XCTAssertEqual(bundle.version, appinfo?["version"] as? String)
        XCTAssertGreaterThanOrEqual(bundle.shellAPI, 1)
    }

    func testServerServesSignedManifestAndFilesOnlyWithKey() async throws {
        let fixture = try fixture()
        let server = SubtitleServer(port: 0, key: fixture.key, allowLegacy: true)
        server.tvApp = try bundle(fixture)
        let port = try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"

        // Eski TV'lere tanınan anahtarsız geçiş /tv/app'e uygulanmaz.
        let (_, open) = try await URLSession.shared.data(from: URL(string: base + "/tv/app/manifest")!)
        XCTAssertEqual((open as? HTTPURLResponse)?.statusCode, 401)
        let (_, wrong) = try await URLSession.shared.data(from: URL(string: base + "/tv/app/manifest?k=AAAAAAAAAAAAAAAAAAAAAA")!)
        XCTAssertEqual((wrong as? HTTPURLResponse)?.statusCode, 401)

        var request = URLRequest(url: URL(string: base + "/tv/app/manifest?k=\(fixture.key)")!)
        request.setValue("null", forHTTPHeaderField: "Origin")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "null")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["hmac"] as? String, fixture.hmac)

        let (app, fileResponse) = try await URLSession.shared.data(from: URL(string: base + "/tv/app/0.9.80/app.js?k=\(fixture.key)")!)
        let file = try XCTUnwrap(fileResponse as? HTTPURLResponse)
        XCTAssertEqual(file.statusCode, 200)
        XCTAssertEqual(String(decoding: app, as: UTF8.self), fixture.files["app.js"])
        XCTAssertEqual(file.value(forHTTPHeaderField: "Cache-Control"), TVAppBundle.fileCache)
        XCTAssertEqual(file.value(forHTTPHeaderField: "Content-Type"), "application/javascript; charset=utf-8")
        XCTAssertEqual(file.value(forHTTPHeaderField: "Content-Length"), String(fixture.sizes["app.js"]!))

        let (_, old) = try await URLSession.shared.data(from: URL(string: base + "/tv/app/0.9.70/app.js?k=\(fixture.key)")!)
        XCTAssertEqual((old as? HTTPURLResponse)?.statusCode, 404)

        server.tvApp = nil
        let (_, none) = try await URLSession.shared.data(from: URL(string: base + "/tv/app/manifest?k=\(fixture.key)")!)
        XCTAssertEqual((none as? HTTPURLResponse)?.statusCode, 404)
    }
}
