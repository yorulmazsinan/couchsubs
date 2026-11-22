// SPDX-License-Identifier: AGPL-3.0-only

import Network
import XCTest
@testable import CouchSubsCore

/// SSAP konuşan sahte bir TV: register'a client-key ile, isteklere sırayla verilen yanıtlarla döner.
final class FakeLGTV: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-lgtv")
    private(set) var receivedURIs: [String] = []
    private(set) var receivedPayloads: [[String: Any]] = []
    var foregroundApps: [String] = []
    /// true ise register'a yalnız "soru gösterildi" yanıtı verir, onay hiç gelmez.
    var neverApprove = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { continuation in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { continuation.resume(returning: listener.port!.rawValue) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil, let data else { return }
            // Gerçek LG TV ikili çerçeveyi reddeder; yalnız metin çerçevesi kabul edilir.
            let frame = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard frame?.opcode == .text else {
                self.send(["type": "error", "id": "", "error": "400 binary messages not supported", "payload": [:]], on: connection)
                return self.receive(on: connection)
            }
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.handle(message, on: connection)
            self.receive(on: connection)
        }
    }

    private func handle(_ message: [String: Any], on connection: NWConnection) {
        let id = message["id"] as? String ?? ""
        if message["type"] as? String == "register" {
            send(["type": "response", "id": id, "payload": ["pairingType": "PROMPT", "returnValue": true]], on: connection)
            if !neverApprove { send(["type": "registered", "id": id, "payload": ["client-key": "fake-key"]], on: connection) }
            return
        }
        let uri = message["uri"] as? String ?? ""
        receivedURIs.append(uri)
        receivedPayloads.append(message["payload"] as? [String: Any] ?? [:])
        var payload: [String: Any] = ["returnValue": true]
        if uri.hasSuffix("getForegroundAppInfo") {
            payload["appId"] = foregroundApps.isEmpty ? "" : foregroundApps.removeFirst()
        }
        send(["type": "response", "id": id, "payload": payload], on: connection)
    }

    private func send(_ object: [String: Any], on connection: NWConnection) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

final class SSAPClientTests: XCTestCase {
    func testConnectReturnsClientKeyAndLaunchSendsUri() async throws {
        let tv = try FakeLGTV()
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: nil)
        let key = try await client.connect()
        XCTAssertEqual(key, "fake-key")

        try await client.launch(appId: "com.couchsubs.tv", params: ["server": "http://1.2.3.4:8787"])
        XCTAssertEqual(tv.receivedURIs.last, "ssap://system.launcher/launch")
        XCTAssertEqual(tv.receivedPayloads.last?["id"] as? String, "com.couchsubs.tv")
        client.close()
    }

    func testForegroundAppId() async throws {
        let tv = try FakeLGTV()
        tv.foregroundApps = ["com.webos.app.hdmi2"]
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: "fake-key")
        _ = try await client.connect()
        let app = try await client.foregroundAppId()
        XCTAssertEqual(app, "com.webos.app.hdmi2")
        client.close()
    }

    func testUnansweredPairingPromptTimesOut() async throws {
        let tv = try FakeLGTV()
        tv.neverApprove = true
        let port = await tv.start()
        defer { tv.stop() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(port)")!], clientKey: nil, approvalTimeout: .seconds(1))
        let begin = Date()
        do {
            _ = try await client.connect()
            XCTFail("Onaysız eşleşme başarılı olmamalı")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(begin), 5)
    }

    func testEndpointThatNeverAnswersIsAbandonedQuickly() async throws {
        // Adres artık başka bir cihazdaysa TCP kabul edilip yanıt gelmeyebilir; yeniden arama gecikmesin.
        let silent = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "silent")
        var held: [NWConnection] = []
        silent.newConnectionHandler = { connection in queue.async { held.append(connection); connection.start(queue: queue) } }
        let ready = expectation(description: "dinliyor")
        silent.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        silent.start(queue: queue)
        await fulfillment(of: [ready], timeout: 3)
        defer { silent.cancel() }

        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:\(silent.port!.rawValue)")!], clientKey: "k",
                                handshakeTimeout: .milliseconds(300))
        let begin = Date()
        do {
            _ = try await client.connect()
            XCTFail("Yanıtsız adres başarılı olmamalı")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(begin), 3)
        client.close()
    }

    func testFallsBackToNextEndpoint() async throws {
        let tv = try FakeLGTV()
        let port = await tv.start()
        defer { tv.stop() }

        // İlk adreste kimse dinlemiyor; ikinciye düşmeli.
        let client = SSAPClient(endpoints: [URL(string: "ws://127.0.0.1:1")!, URL(string: "ws://127.0.0.1:\(port)")!], clientKey: nil)
        let key = try await client.connect()
        XCTAssertEqual(key, "fake-key")
        client.close()
    }
}

final class TVKeeperTests: XCTestCase {
    final class FakeControl: TVControlling, @unchecked Sendable {
        var foreground: [String]
        var launches: [(String, [String: String])] = []
        var failNext = false
        var launchError: Error?
        var closes = 0
        init(foreground: [String]) { self.foreground = foreground }
        func close() { closes += 1 }
        func foregroundAppId() async throws -> String {
            if failNext { failNext = false; throw URLError(.networkConnectionLost) }
            return foreground.isEmpty ? "com.couchsubs.tv" : foreground.removeFirst()
        }
        func launch(appId: String, params: [String: Any]) async throws {
            if let launchError { throw launchError }
            launches.append((appId, params.compactMapValues { $0 as? String }))
        }
    }

    func testRelaunchesOnlyWhenHdmiInputIsInFront() async throws {
        let control = FakeControl(foreground: ["com.couchsubs.tv", "com.webos.app.hdmi2", "com.couchsubs.tv", "netflix"])
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: ["server": "http://1.2.3.4:8787"])
        await keeper.tick()   // bağlanır ve uygulamayı bir kez başlatır
        await keeper.tick()   // önde HDMI girişi → geri getir
        await keeper.tick()   // önde bizimki
        await keeper.tick()   // kullanıcı Netflix'i açtı → dokunma
        XCTAssertEqual(control.launches.count, 2)
        XCTAssertEqual(control.launches.last?.0, "com.couchsubs.tv")
        XCTAssertEqual(control.launches.last?.1["server"], "http://1.2.3.4:8787")
    }

    func testStandsDownWhenTheUserKeepsReturningToTheInput() async throws {
        // Kullanıcı PS5 kapalıyken TV'yi başka girişe alıyor; bekçi her seferinde CouchSubs'ı geri getiriyordu.
        let hdmi = "com.webos.app.hdmi1"
        let control = FakeControl(foreground: ["com.couchsubs.tv", hdmi, hdmi, hdmi, hdmi, hdmi, "com.couchsubs.tv", hdmi])
        var time = ContinuousClock.now
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:], now: { time })
        await keeper.tick()   // bağlanır ve başlatır
        await keeper.tick()   // uygulama önde
        for _ in 0..<TVKeeper.standDownAfter {
            time += .seconds(10)
            await keeper.tick()   // girişte → geri getir
        }
        XCTAssertEqual(control.launches.count, 1 + TVKeeper.standDownAfter)
        time += .seconds(10)
        await keeper.tick()   // yine girişte: kullanıcı ısrarlı → bekçi çekilir
        XCTAssertTrue(keeper.stoodDown)
        time += .seconds(600)
        await keeper.tick()   // sonra da zorlamaz
        XCTAssertEqual(control.launches.count, 1 + TVKeeper.standDownAfter)
        await keeper.tick()   // kullanıcı CouchSubs'ı TV'de kendisi açtı → bekçi işine döner
        XCTAssertFalse(keeper.stoodDown)
        await keeper.tick()   // TV yine girişe geçti (SimpLink) → geri getir
        XCTAssertEqual(control.launches.count, 2 + TVKeeper.standDownAfter)
    }

    func testOccasionalInputSwitchesNeverStandDown() async throws {
        // SimpLink/CEC arada bir TV'yi girişe geçirir: aralıklı geçişler sınıra takılmaz.
        let control = FakeControl(foreground: ["com.couchsubs.tv"] + Array(repeating: "com.webos.app.hdmi2", count: 12))
        var time = ContinuousClock.now
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:], now: { time })
        await keeper.tick()
        await keeper.tick()
        for _ in 0..<12 {
            time += .seconds(60)
            await keeper.tick()
        }
        XCTAssertFalse(keeper.stoodDown)
        XCTAssertEqual(control.launches.count, 13)
    }

    func testPSButtonOnTheConsoleInputIsNeverCountedAsInsisting() async throws {
        // X (Kas 2026): oyunda PS tuşu TV'yi PS5'in girişine (CEC) geçiriyor. Eskiden her basış "ısrar" sayılıyordu;
        // 90 sn'de dördüncü basışta bekçi çekiliyor, çeviri bir daha TV'ye gelmiyordu (Windows ile aynı test).
        let presses = 8
        var foreground = ["com.couchsubs.tv"]
        for _ in 0..<presses { foreground += ["com.webos.app.hdmi2", "com.couchsubs.tv"] }
        let control = FakeControl(foreground: foreground)
        var time = ContinuousClock.now
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:], consolePort: { 2 }, now: { time })
        await keeper.tick()
        await keeper.tick()
        for _ in 0..<presses {
            time += .seconds(5)
            await keeper.tick()   // PS tuşu → konsol girişi → hemen geri getir
            time += .seconds(3)
            await keeper.tick()   // uygulama yine önde
        }
        XCTAssertFalse(keeper.stoodDown)
        XCTAssertEqual(control.launches.count, 1 + presses)
    }

    func testAnotherHdmiNumberIsStillRespected() async throws {
        // Konsol HDMI 2'de; kullanıcı HDMI 1'e (başka cihaz) geçiyor: eskisi gibi üç geri getirmeden sonra bekçi çekilir.
        let control = FakeControl(foreground: ["com.couchsubs.tv"] + Array(repeating: "com.webos.app.hdmi1", count: 5))
        var time = ContinuousClock.now
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:], consolePort: { 2 }, now: { time })
        await keeper.tick()
        await keeper.tick()
        for _ in 0...TVKeeper.standDownAfter {
            time += .seconds(10)
            await keeper.tick()
        }
        XCTAssertTrue(keeper.stoodDown)
        XCTAssertEqual(control.launches.count, 1 + TVKeeper.standDownAfter)
    }

    func testEndlessConsoleBounceStandsDown() async throws {
        let control = FakeControl(foreground: ["com.couchsubs.tv"] + Array(repeating: "com.webos.app.hdmi3", count: 30))
        var time = ContinuousClock.now
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:], consolePort: { 3 }, now: { time })
        await keeper.tick()
        await keeper.tick()
        for _ in 0..<20 {
            time += .seconds(3)
            await keeper.tick()
        }
        XCTAssertTrue(keeper.stoodDown)
        XCTAssertEqual(control.launches.count, 1 + TVKeeper.consoleLoopLimit)
    }

    func testWaitsForTheAppToComeForwardBeforeLookingAgain() async throws {
        let control = FakeControl(foreground: ["com.couchsubs.tv", "com.webos.app.hdmi1", "com.webos.app.hdmi1", "com.couchsubs.tv"])
        var time = ContinuousClock.now
        let keeper = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:], now: { time })
        await keeper.tick()
        await keeper.tick()
        time += .seconds(1)
        await keeper.tick()   // girişte → geri getir
        time += .seconds(1)
        await keeper.tick()   // daha öne gelmedi: bekle
        XCTAssertEqual(control.launches.count, 2)
    }

    func testLGPollsEverySecondSamsungKeepsItsInterval() {
        let control = FakeControl(foreground: [])
        let lg = TVKeeper(connect: { control }, appId: "com.couchsubs.tv", params: [:])
        let samsung = TVKeeper(connect: { control }, appId: "x", params: [:], appConnected: { true })
        XCTAssertEqual(lg.pollInterval(.seconds(5)), .seconds(1))
        XCTAssertEqual(samsung.pollInterval(.seconds(5)), .seconds(5))
        XCTAssertTrue(TVKeeper.isConsoleInput("com.webos.app.hdmi2", port: 2))
        XCTAssertFalse(TVKeeper.isConsoleInput("com.webos.app.hdmi2", port: 1))
        XCTAssertFalse(TVKeeper.isConsoleInput("com.webos.app.hdmi2", port: nil))
        XCTAssertFalse(TVKeeper.isConsoleInput("com.webos.app.livetv", port: 2))
    }

    func testReconnectsWhenTVWasOffOrConnectionDropped() async throws {
        struct Off: Error {}
        let control = FakeControl(foreground: [])
        var attempts = 0
        let keeper = TVKeeper(connect: {
            attempts += 1
            if attempts == 1 { throw Off() }   // TV kapalı
            return control
        }, appId: "com.couchsubs.tv", params: [:])
        await keeper.tick()
        XCTAssertTrue(control.launches.isEmpty)
        await keeper.tick()                     // TV açıldı → bağlan ve başlat
        XCTAssertEqual(control.launches.count, 1)

        control.failNext = true                 // bağlantı koptu
        await keeper.tick()
        await keeper.tick()                     // yeniden bağlanır ve tekrar başlatır
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(control.launches.count, 2)
        XCTAssertEqual(control.closes, 1, "kopan bağlantı kapatılır")
    }

    func testReportsWhetherTheTVAppCouldBeOpened() async throws {
        // Açma sessizce başarısız oluyordu; ana ekran nedenini söylesin diye her denemenin sonucu bildirilir.
        struct Off: Error {}
        let control = FakeControl(foreground: [])
        var attempts = 0
        var results: [TVOpenProblem?] = []
        let keeper = TVKeeper(connect: {
            attempts += 1
            if attempts == 1 { throw Off() }
            return control
        }, appId: "com.couchsubs.tv", params: [:], onOpenResult: { results.append($0) })
        await keeper.tick()                     // TV kapalı
        await keeper.tick()                     // açıldı
        XCTAssertEqual(results, [.unreachable, nil])

        var samsungResults: [TVOpenProblem?] = []
        let samsung = TVKeeper(connect: { throw Off() }, appId: "x", params: [:], appConnected: { false },
                               onOpenResult: { samsungResults.append($0) })
        await samsung.tick()
        XCTAssertEqual(samsungResults, [.unreachable])
    }

    func testOpenProblemShownByKeyAndBrand() {
        // Kayıtlı anahtar yokken yanıt vermeyen LG/Samsung "izin yok" sayılır; Android TV kendi nedenini söyler.
        XCTAssertEqual(TVOpenProblem.shown(.unreachable, brand: .lg, hasKey: false), .notPaired)
        XCTAssertEqual(TVOpenProblem.shown(.unreachable, brand: .samsung, hasKey: true), .unreachable)
        XCTAssertEqual(TVOpenProblem.shown(.debugOff, brand: .androidTV, hasKey: false), .debugOff)
        XCTAssertNil(TVOpenProblem.shown(nil, brand: .lg, hasKey: false))
        XCTAssertNotEqual(TVOpenText.openOnTV(.androidTV), TVOpenText.openOnTV(.lg))
        XCTAssertEqual(TVOpenText.openOnTV(.lg), TVOpenText.openOnTV(.samsung))
        XCTAssertNil(TVOpenText.reason(nil))
        for problem in [TVOpenProblem.unreachable, .notPaired, .debugOff, .debugNotApproved, .notOpened, .notInstalled] {
            XCTAssertNotNil(TVOpenText.reason(problem))
        }
    }

    func testSamsungFirstOpenIsImmediateAndIgnoredCommandIsReported() async throws {
        // iPhone, Samsung (TestFlight build 27): TV açma komutunu alıp CouchSubs'ı açmıyordu; ekranda neden yoktu.
        let control = FakeControl(foreground: [])
        var time = ContinuousClock.now
        var results: [TVOpenProblem?] = []
        let keeper = TVKeeper(connect: { control }, appId: "x", params: [:], appConnected: { false },
                              onOpenResult: { results.append($0) }, now: { time })
        await keeper.tick()                     // çeviri başlar başlamaz (beklemeden) açar
        XCTAssertEqual(control.launches.count, 1)
        XCTAssertEqual(results, [nil])
        time += .seconds(10)
        await keeper.tick()                     // henüz bekleniyor
        XCTAssertEqual(results, [nil])
        time += TVKeeper.samsungOpenCheck
        await keeper.tick()                     // uygulama bağlanmadı → "TV açmadı"
        XCTAssertEqual(results, [nil, .notOpened])
        time += .seconds(10)
        await keeper.tick()                     // 30 sn doldu → yeniden açar; neden satırı silinmez
        XCTAssertEqual(control.launches.count, 2)
        XCTAssertEqual(results, [nil, .notOpened])
        keeper.reconnect()                      // "Otomatik açmayı dene": hemen açar
        await keeper.tick()
        XCTAssertEqual(control.launches.count, 3)
        XCTAssertEqual(results, [nil, .notOpened, nil])
        XCTAssertNotNil(TVOpenText.reason(.notOpened))
    }

    func testSamsungUnconfirmedAppIsReportedAsNotInstalled() async throws {
        // Samsung 7 Series 2018 (21 Kas): kurulu olduğu doğrulanmayan uygulamaya açma komutu gitmez; ana ekran "TV
        // uygulamasını kurun" ve AS400 ipucunu gösterir, "TV yanıt vermedi" demez.
        let control = FakeControl(foreground: [])
        control.launchError = SamsungClient.SamsungError.notInstalled
        var results: [TVOpenProblem?] = []
        let keeper = TVKeeper(connect: { control }, appId: "x", params: [:], appConnected: { false },
                              onOpenResult: { results.append($0) })
        await keeper.tick()
        XCTAssertEqual(results, [.notInstalled])
        XCTAssertTrue(TVOpenText.reason(.notInstalled)!.contains("AS400"))
        XCTAssertTrue(TVOpenText.samsungServerHint.contains("Host PC IP"))
    }

    func testSamsungConnectedAppIsNotReportedAsNotOpened() async throws {
        let control = FakeControl(foreground: [])
        let connected = Flag()
        var time = ContinuousClock.now
        var results: [TVOpenProblem?] = []
        let keeper = TVKeeper(connect: { control }, appId: "x", params: [:], appConnected: { connected.value },
                              onOpenResult: { results.append($0) }, now: { time })
        await keeper.tick()
        connected.value = true
        time += TVKeeper.samsungOpenCheck
        await keeper.tick()
        connected.value = false                 // kullanıcı sonradan çıktı: yeni açma, eski komut "açmadı" sayılmaz
        time += .seconds(20)
        await keeper.tick()
        XCTAssertEqual(results, [nil, nil])
    }

    func testSamsungLauncherTriesDeveloperConnectionFirst() async throws {
        let remote = FakeControl(foreground: [])
        var remoteConnects = 0
        let bySdb = SamsungLauncher(openWithSdb: { true }, connectRemote: { remoteConnects += 1; return remote })
        try await bySdb.launch(appId: "x", params: [:])
        XCTAssertEqual(remoteConnects, 0)
        let byRemote = SamsungLauncher(openWithSdb: { false }, connectRemote: { remoteConnects += 1; return remote })
        try await byRemote.launch(appId: "x", params: [:])
        XCTAssertEqual(remoteConnects, 1)
        XCTAssertEqual(remote.launches.count, 1)
        XCTAssertEqual(remote.closes, 1)
        XCTAssertTrue(SamsungLauncher.sdbLaunched("launch app CouchSubsT.CouchSubs\napp_id[CouchSubsT.CouchSubs] launched\n"))
        XCTAssertFalse(SamsungLauncher.sdbLaunched("app_id[CouchSubsT.CouchSubs] launch start\napp_id[CouchSubsT.CouchSubs] launch failed"))
        XCTAssertFalse(SamsungLauncher.sdbLaunched(""))
    }

    func testSamsungIsLeftAloneWhileTheAppIsConnected() async throws {
        let control = FakeControl(foreground: [])
        let connected = Flag()
        var connects = 0
        let keeper = TVKeeper(connect: { connects += 1; return control }, appId: "com.couchsubs.tv", params: [:],
                              appConnected: { connected.value }, relaunchInterval: .milliseconds(200))
        await keeper.tick()                     // uygulama bağlı değil → aç ve bağlantıyı kapat
        XCTAssertEqual(control.launches.count, 1)
        XCTAssertEqual(control.closes, 1)
        await keeper.tick()                     // hemen yeniden açmaya çalışmaz
        XCTAssertEqual(connects, 1)
        connected.value = true
        try await Task.sleep(for: .milliseconds(250))
        for _ in 0..<5 { await keeper.tick() }  // uygulama bağlıyken TV'ye hiç dokunulmaz
        XCTAssertEqual(connects, 1)
        connected.value = false
        await keeper.tick()                     // uygulama kapandı → bir kez daha aç
        XCTAssertEqual(control.launches.count, 2)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
