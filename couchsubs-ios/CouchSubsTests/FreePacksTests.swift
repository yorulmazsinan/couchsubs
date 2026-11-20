// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import XCTest
@testable import CouchSubs

@MainActor
private final class RecordingAnalytics: AnalyticsLogging {
    var events: [AnalyticsEvent] = []
    var collection: Bool?
    func log(_ event: AnalyticsEvent) { events.append(event) }
    func screen(_ name: String) {}
    func setCollection(_ enabled: Bool) { collection = enabled }
}

/// Paketler herkese ücretsiz: kapı yok, sunucudan güncellenir, ulaşılamazsa uygulamayla gelenler kalır.
@MainActor
final class FreePacksTests: XCTestCase {
    private var directory: URL!
    private var session: URLSession!
    private let pack = Data(#"{"format":1,"id":"demo","title":"Demo","entries":{"\#(PackKey.key("Hello there, my friend.")!)":"Merhaba dostum."}}"#.utf8)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.requests = []
        StubProtocol.responses = [:]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func makeApp(analytics: RecordingAnalytics, library: GamePackLibrary) -> AppModel {
        let store = PackStore(baseURL: URL(string: "https://packs.test")!, directory: directory, session: session)
        return AppModel(analytics: analytics, packStore: store, library: library, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testPacksAreUsedWithoutAnySubscription() {
        let model = PhoneModel(services: LivePhoneServices(), store: EphemeralStore(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        XCTAssertTrue(model.packsActive)
        model.settings.gamePacks = false
        XCTAssertFalse(model.packsActive)
    }

    func testRefreshDownloadsPacksAndNotifies() async {
        let sha = PackStore.sha256(pack)
        StubProtocol.responses["/v1/packs"] = (200, Data(#"{"packs":[{"id":"demo","title":"Demo","version":2,"sha256":"\#(sha)","size":10,"entries":1}]}"#.utf8))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        let analytics = RecordingAnalytics()
        let library = GamePackLibrary(bundled: nil, user: PackStore.filesDirectory(in: directory))
        let app = makeApp(analytics: analytics, library: library)
        var changed = 0
        app.onPacksChanged = { changed += 1 }
        await app.refreshPacks(force: true)
        XCTAssertEqual(app.packStatus, .ready)
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(library.match("Hello there, my friend.")?.text, "Merhaba dostum.")
        XCTAssertEqual(analytics.events, [.packsUpdated(count: 1)])
    }

    func testUnreachableServerKeepsBundledPacks() async throws {
        let bundled = directory.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try pack.write(to: bundled.appendingPathComponent("demo.json"))
        StubProtocol.responses["/v1/packs"] = (503, Data())
        let library = GamePackLibrary(bundled: bundled, user: PackStore.filesDirectory(in: directory))
        let app = makeApp(analytics: RecordingAnalytics(), library: library)
        await app.refreshPacks(force: true)
        guard case .failed = app.packStatus else { return XCTFail("hata bildirilmeli") }
        XCTAssertEqual(library.match("Hello there, my friend.")?.text, "Merhaba dostum.")
    }

    /// "Paketleri şimdi güncelle": ilk basışta paket eklendi, hemen ikinci basışta zaten güncel, sunucu düşünce Türkçe neden.
    func testUpdateNowSummarizesWhatArrived() async {
        let sha = PackStore.sha256(pack)
        StubProtocol.responses["/v1/packs"] = (200, Data(#"{"packs":[{"id":"demo","title":"Demo","version":2,"sha256":"\#(sha)","size":10,"entries":1}]}"#.utf8))
        StubProtocol.responses["/v1/packs/demo"] = (200, pack)
        let library = GamePackLibrary(bundled: nil, user: PackStore.filesDirectory(in: directory))
        let app = makeApp(analytics: RecordingAnalytics(), library: library)
        guard case let .updated(summary) = await app.updatePacksNow() else { return XCTFail("paket eklenmeli") }
        XCTAssertEqual(summary.added.map(\.title), ["Demo"])
        XCTAssertEqual(summary.newLines, 1)
        // Liste yerel önbellekten değil sunucudan (sunucu `max-age=300` gönderiyor).
        XCTAssertEqual(StubProtocol.requests.first { $0.url?.path == "/v1/packs" }?.cachePolicy, .reloadIgnoringLocalCacheData)
        let again = await app.updatePacksNow()
        XCTAssertEqual(again, .upToDate)
        StubProtocol.responses["/v1/packs"] = (503, Data())
        guard case let .failed(reason, _) = await app.updatePacksNow() else { return XCTFail("hata bildirilmeli") }
        XCTAssertEqual(reason, AppModel.reason(.server(503)))
    }

    func testNoServerConfiguredDoesNothing() async {
        let app = AppModel(analytics: RecordingAnalytics(), packStore: nil, library: GamePackLibrary(bundled: nil, user: nil),
                           defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await app.refreshPacks(force: true)
        XCTAssertEqual(app.packStatus, .idle)
    }

    func testTourIsShownOnce() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let app = AppModel(analytics: RecordingAnalytics(), packStore: nil, library: GamePackLibrary(bundled: nil, user: nil), defaults: defaults)
        XCTAssertFalse(app.tourDone)
        app.tourDone = true
        let again = AppModel(analytics: RecordingAnalytics(), packStore: nil, library: GamePackLibrary(bundled: nil, user: nil), defaults: defaults)
        XCTAssertTrue(again.tourDone)
    }
}
