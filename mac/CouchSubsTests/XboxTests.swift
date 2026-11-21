// SPDX-License-Identifier: AGPL-3.0-only
// Mac'te Xbox (Beta): konsol seçimi, Microsoft girişi, Xbox seçimi, çevirinin Xbox oturumuyla başlaması, durum metinleri
// ve ortak oturumun (XboxStreamSession) hizmet yanıtlarına tepkisi. Gerçek Microsoft/Xbox hizmetine gidilmez: bütün
// istekler sahte HTTP'den yanıtlanır (yanıt biçimleri core/Tests XboxTests'teki kayıtlı örneklerle aynı).

import CouchSubsCore
import RemotePlay
import XboxStream
import XCTest
@testable import CouchSubs

/// Adrese göre yanıt veren sahte Microsoft/Xbox hizmeti; istekleri kaydeder.
final class FakeXboxHTTP: XboxHTTP, @unchecked Sendable {
    struct Call { let method: String; let url: String; let body: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let answer: (String, String, String?) -> XboxHTTPResponse?

    init(_ answer: @escaping (String, String, String?) -> XboxHTTPResponse? = { _, _, _ in nil }) { self.answer = answer }

    var calls: [Call] { lock.withLock { recorded } }

    static func ok(_ json: String) -> XboxHTTPResponse { XboxHTTPResponse(status: 200, body: Data(json.utf8)) }
    static func status(_ code: Int, _ json: String = "") -> XboxHTTPResponse { XboxHTTPResponse(status: code, body: Data(json.utf8)) }

    /// Jeton zinciri ve konsol listesi (her testte aynı).
    static func chain(_ url: String) -> XboxHTTPResponse? {
        if url.hasSuffix("/devicecode") {
            return ok(#"{"user_code":"ABCD1234","device_code":"D","verification_uri":"https://www.microsoft.com/link","expires_in":900,"interval":5}"#)
        }
        if url.hasSuffix("/oauth2/v2.0/token") { return ok(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#) }
        if url.contains("user.auth") || url.contains("xsts.auth") {
            return ok(#"{"Token":"X","NotAfter":"2099-01-01T00:00:00Z","DisplayClaims":{"xui":[{"uhs":"H"}]}}"#)
        }
        if url.contains("/v2/login/user") {
            return ok(#"{"gsToken":"GS","durationInSeconds":14400,"offeringSettings":{"regions":[{"baseUri":"https://uks.example/","isDefault":true}]}}"#)
        }
        if url.contains("login.live.com") { return ok(#"{"access_token":"LPT"}"#) }
        if url.contains("/lists/devices") {
            return ok(#"""
                {"result":[{"id":"F1","name":"Salon","consoleType":"XboxSeriesX","consoleStreamingEnabled":true,"remoteManagementEnabled":true},
                {"id":"F2","name":"Oda","consoleType":"XboxOne","consoleStreamingEnabled":true,"remoteManagementEnabled":false}]}
                """#)
        }
        return nil
    }

    func request(_ method: String, _ url: String, headers: [String: String], body: String?) async throws -> XboxHTTPResponse {
        lock.withLock { recorded.append(Call(method: method, url: url, body: body)) }
        if let response = answer(method, url, body) ?? Self.chain(url) { return response }
        throw XboxError(.network, "test: beklenmeyen istek \(method) \(url)")
    }
}

@MainActor
final class XboxModelTests: XCTestCase {
    private let salon = XboxConsole(id: "F1", name: "Salon", model: "XboxSeriesX", streamingEnabled: true)
    private let storedToken = #"{"access_token":"A","refresh_token":"R","expires_on":"2099-01-01T00:00:00Z"}"#

    private func defaults(platform: ConsolePlatform? = nil) -> UserDefaults {
        let defaults = UserDefaults.isolated()
        if let platform { defaults.set(platform.rawValue, forKey: XboxStoreKey.platform) }
        return defaults
    }

    /// Kurulumu bitmiş Xbox: jeton, seçili Xbox, altyazı bilgisayar ekranında.
    private func linkedModel(services: FakeServices = FakeServices(), store: MemoryStore = MemoryStore()) -> AppModel {
        store.save(storedToken, for: XboxStoreKey.userToken)
        store.save(salon, for: XboxStoreKey.console)
        store.save(true, for: StoreKey.setupComplete)
        let model = AppModel(services: services, store: store, defaults: defaults(platform: .xbox))
        model.settings.output = .computer
        return model
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    func testPlayStationIsTheDefaultAndTheChoiceIsRemembered() {
        let userDefaults = defaults()
        let model = AppModel(services: FakeServices(), store: MemoryStore(), defaults: userDefaults)
        XCTAssertFalse(model.isXbox)
        XCTAssertEqual(model.wizardSteps.count, AppModel.Step.allCases.count - 1)
        XCTAssertEqual(model.wizardSteps[1], .secondAccount)
        model.choosePlatform(.xbox)
        XCTAssertTrue(model.isXbox)
        XCTAssertEqual(model.wizardSteps[1], .psnLogin)
        XCTAssertTrue(AppModel(services: FakeServices(), store: MemoryStore(), defaults: userDefaults).isXbox)
    }

    func testWizardSkipsSecondAccountAndSignsInWithDeviceCode() async throws {
        let services = FakeServices()
        let polls = Counter()
        let http = FakeXboxHTTP { _, url, _ in
            // İlk iki soruda kullanıcı kodu henüz onaylamadı.
            url.hasSuffix("/oauth2/v2.0/token") && polls.next() < 3 ? FakeXboxHTTP.status(400, #"{"error":"authorization_pending"}"#) : nil
        }
        services.xboxHTTP = http
        let store = MemoryStore()
        let model = AppModel(services: services, store: store, defaults: defaults())
        XCTAssertEqual(model.step, .welcome)
        model.choosePlatform(.xbox)
        XCTAssertTrue(model.isXbox)
        XCTAssertFalse(model.wizardSteps.contains(.secondAccount))

        model.advance()
        XCTAssertEqual(model.step, .psnLogin, "Xbox'ta ikinci hesap adımı yok")
        XCTAssertFalse(model.canAdvance)
        model.back()
        XCTAssertEqual(model.step, .welcome)
        model.advance()

        let code = try await model.beginXboxLogin()
        XCTAssertEqual(code.userCode, "ABCD1234")
        XCTAssertEqual(code.verificationURI, "https://www.microsoft.com/link")
        try await model.completeXboxLogin(code)
        XCTAssertTrue(model.xboxSignedIn)
        XCTAssertEqual(http.calls.filter { $0.url.hasSuffix("/oauth2/v2.0/token") }.count, 3)
        XCTAssertEqual(XboxUserToken.parse(store.load(String.self, for: XboxStoreKey.userToken))?.refreshToken, "R")
        XCTAssertTrue(model.canAdvance)

        model.advance()
        XCTAssertEqual(model.step, .console)
        XCTAssertFalse(model.canAdvance)
        let found = try await model.discoverXboxConsoles()
        XCTAssertEqual(found.map(\.name), ["Salon", "Oda"])
        XCTAssertEqual(found.map(\.streamingEnabled), [true, false])
        model.chooseXbox(found[0])
        XCTAssertEqual(store.load(XboxConsole.self, for: XboxStoreKey.console), found[0])
        XCTAssertTrue(model.canAdvance)
        model.advance()
        XCTAssertEqual(model.step, .tv)
    }

    func testSignInProblemsAreExplained() async {
        let services = FakeServices()
        services.xboxHTTP = FakeXboxHTTP { _, url, _ in
            url.hasSuffix("/oauth2/v2.0/token") ? FakeXboxHTTP.status(400, #"{"error":"authorization_declined"}"#) : nil
        }
        let model = AppModel(services: services, store: MemoryStore(), defaults: defaults())
        model.choosePlatform(.xbox)
        do {
            let code = try await model.beginXboxLogin()
            try await model.completeXboxLogin(code)
            XCTFail("reddedilen giriş başarılı sayıldı")
        } catch let error as XboxError {
            XCTAssertEqual(error.kind, .signInDeclined)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(model.xboxSignedIn)

        // Hesabın Xbox profili yok: liste alınamaz, neden kullanıcıya anlatılır.
        let noProfile = FakeServices()
        noProfile.xboxHTTP = FakeXboxHTTP { _, url, _ in url.contains("xsts.auth") ? FakeXboxHTTP.status(401, #"{"XErr":2148916233}"#) : nil }
        let linked = linkedModel(services: noProfile)
        do {
            _ = try await linked.discoverXboxConsoles()
            XCTFail("profilsiz hesapta liste geldi")
        } catch let error as XboxError {
            XCTAssertEqual(error.kind, .noXboxAccount)
            XCTAssertFalse(XboxText.problem(error).isEmpty)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testSavedXboxOpensMainScreenAndHalfSetupResumesAtTV() {
        let model = linkedModel()
        XCTAssertEqual(model.step, .done)
        XCTAssertTrue(model.isXbox)
        XCTAssertTrue(model.canStart)
        XCTAssertFalse(model.needsXboxLink)
        XCTAssertFalse(model.needsPS5Link)

        // Sihirbaz bitmeden kapatıldı: Xbox bağlı, kurulum TV adımından sürer.
        let store = MemoryStore()
        store.save(storedToken, for: XboxStoreKey.userToken)
        store.save(salon, for: XboxStoreKey.console)
        XCTAssertEqual(AppModel(services: FakeServices(), store: store, defaults: defaults(platform: .xbox)).step, .tv)

        // Yalnız konsol türü seçilmiş: baştan.
        let fresh = AppModel(services: FakeServices(), store: MemoryStore(), defaults: defaults(platform: .xbox))
        XCTAssertEqual(fresh.step, .welcome)
        XCTAssertTrue(fresh.needsXboxLink)
        XCTAssertFalse(fresh.canStart)
    }

    func testStartUsesTheXboxSessionAndAudioSetting() async {
        let services = FakeServices()
        let model = linkedModel(services: services)
        // Kayıtlı bir PS5 olsa da Xbox seçiliyken PS5'e bağlanılmaz.
        model.accountId = Data(repeating: 1, count: 8)
        model.console = RegisteredConsole(host: "192.168.1.253", name: "PS5", registKey: Data(repeating: 0x31, count: 16), morning: Data(repeating: 2, count: 16))
        XCTAssertEqual(model.ps5StatusText, String(format: String(localized: "%@ is ready. It connects when you start translating."), "Salon"))

        await model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(services.streams.isEmpty)
        XCTAssertEqual(services.xboxStreams.count, 1)
        XCTAssertEqual(services.xboxStreams[0].console, salon)
        XCTAssertTrue(services.xboxStreams[0].playAudio)
        XCTAssertTrue(services.xboxStreams[0].stream.started)

        // Oturumun bildirdiği metin (yeniden deneniyor ya da yayın durdu) ana ekranda aynen görünür.
        services.xboxStreams[0].stream.onState?(.disconnected(.other(XboxText.session(.busy))))
        await settle()
        XCTAssertEqual(model.ps5StatusText, XboxText.session(.busy))
        services.xboxStreams[0].stream.onState?(.streaming)
        await settle()
        XCTAssertEqual(model.ps5StatusText, String(localized: "Connected"))

        // #871: ses ayarı değişince yayın yeniden kurulmaz (Xbox yeni oturumda hizmetini başlatamıyordu); yalnız yerel ses kısılır.
        model.settings.xboxAudioOnDevice = false
        for _ in 0..<5 { await settle() }
        XCTAssertEqual(services.xboxStreams.count, 1)
        XCTAssertTrue(services.xboxStreams[0].stream.started)
        XCTAssertEqual(services.xboxStreams[0].stream.playAudioChanges, [false])
        model.stop()
        // Sonraki başlatmada yeni ayarla açılır.
        await model.start()
        XCTAssertFalse(services.xboxStreams[1].playAudio)
        model.stop()
    }

    func testSwitchingBackToPlayStationAndSigningOut() async {
        let services = FakeServices()
        let store = MemoryStore()
        let model = linkedModel(services: services, store: store)
        await model.start()
        XCTAssertEqual(services.xboxStreams.count, 1)

        model.signOutXbox()
        await settle()
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.xboxSignedIn)
        XCTAssertNil(store.load(String.self, for: XboxStoreKey.userToken))
        XCTAssertNotNil(model.xboxConsole, "çıkış seçilen Xbox'ı silmez")
        XCTAssertTrue(model.needsXboxLink)
        XCTAssertFalse(model.canStart)
        XCTAssertEqual(model.ps5StatusText, String(localized: "Not connected"))
        model.linkXbox()
        XCTAssertEqual(model.step, .psnLogin)

        model.choosePlatform(.playstation)
        XCTAssertFalse(model.isXbox)
        XCTAssertTrue(model.wizardSteps.contains(.secondAccount))
    }

    func testResetSetupForgetsTheXbox() async {
        let store = MemoryStore()
        let userDefaults = defaults(platform: .xbox)
        store.save(storedToken, for: XboxStoreKey.userToken)
        store.save(salon, for: XboxStoreKey.console)
        store.save(true, for: StoreKey.setupComplete)
        let model = AppModel(services: FakeServices(), store: store, defaults: userDefaults)
        model.resetSetup()
        await settle()
        XCTAssertEqual(model.step, .welcome)
        XCTAssertFalse(model.isXbox)
        XCTAssertNil(model.xboxConsole)
        XCTAssertFalse(model.xboxSignedIn)
        XCTAssertNil(store.load(String.self, for: XboxStoreKey.userToken))
        XCTAssertNil(store.load(XboxConsole.self, for: XboxStoreKey.console))
        XCTAssertNil(userDefaults.string(forKey: XboxStoreKey.platform))
    }

    func testStatusTextFollowsWindowsRules() {
        XCTAssertEqual(AppModel.xboxStatusText(.connecting, running: true, console: salon, signedIn: true), String(localized: "Connecting…"))
        XCTAssertEqual(AppModel.xboxStatusText(.disconnected(.stopped), running: false, console: nil, signedIn: true), String(localized: "Not connected"))
        XCTAssertEqual(AppModel.xboxStatusText(.disconnected(.stopped), running: true, console: salon, signedIn: true), String(localized: "Retrying the Xbox connection…"))
        let stopped = XboxText.stopped(.other, "Xbox WebRTC bağlantısı kesildi")
        XCTAssertTrue(stopped.contains("Xbox WebRTC bağlantısı kesildi"))
        XCTAssertEqual(AppModel.xboxStatusText(.disconnected(.other(stopped)), running: true, console: salon, signedIn: true), stopped)
        // Üç durma metni birbirinden ayrı; meşgul ve ulaşılamıyor metinleri ham nedeni göstermez.
        XCTAssertFalse(XboxText.stopped(.busy, "ServerInUse").contains("ServerInUse"))
        XCTAssertFalse(XboxText.stopped(.consoleUnavailable, "ConsoleOffline").contains("ConsoleOffline"))
        XCTAssertNotEqual(XboxText.stopped(.busy, ""), XboxText.stopped(.consoleUnavailable, ""))
        // #871: Xbox'ın JSON hata nesnesi ekranda gösterilmez; hizmet hatasında yeniden başlatma önerisi, bilinmeyende kod.
        let json = #"{"message":"Agent : -2147019873 : Timed out waiting for Cloud Streaming Service to be ready."}"#
        let kind = XboxStop.classify(json)
        let notReady = XboxText.stopped(kind, XboxStop.displayReason(json, kind))
        XCTAssertEqual(kind, .serviceNotReady)
        XCTAssertFalse(notReady.contains("{"))
        XCTAssertTrue(notReady.contains("10"))
        let unknown = XboxText.stopped(.startFailed, XboxStop.displayReason(#"{"message":"Agent : -2147024891 : x"}"#, .startFailed))
        XCTAssertTrue(unknown.contains("0x80070005"))
        XCTAssertFalse(unknown.contains("{"))
    }
}

/// Ortak oturumun (iPhone ve Mac) hizmet yanıtlarına tepkisi: WebRTC el sıkışmasına gelmeden biten durumlar.
final class XboxSessionFlowTests: XCTestCase {
    private let salon = XboxConsole(id: "F1", name: "Salon", model: "XboxSeriesX", streamingEnabled: true)

    private func auth(_ http: XboxHTTP) -> XboxAuth {
        XboxAuth(http: http, sleep: { _ in },
                 userToken: XboxUserToken.parse(#"{"access_token":"A","refresh_token":"R","expires_on":"2099-01-01T00:00:00Z"}"#))
    }

    /// Oturumu başlatır ve ilk "yayın durdu / giriş gerekli" durumuna kadar bekler.
    private func run(_ http: FakeXboxHTTP, until done: @escaping ([SessionState]) -> Bool) async -> [SessionState] {
        let states = StateBox()
        let session = XboxStreamSession(auth: auth(http), console: salon, playAudio: false, http: http,
                                        describe: { "yeniden:\($0.rawValue)" }, stopped: { kind, reason in "durdu:\(kind):\(reason)" })
        session.onState = { states.add($0) }
        session.start()
        for _ in 0..<200 where !done(states.values) { try? await Task.sleep(for: .milliseconds(50)) }
        session.stop()
        try? await Task.sleep(for: .milliseconds(100))
        return states.values
    }

    private func texts(_ states: [SessionState]) -> [String] {
        states.compactMap { if case .disconnected(.other(let text)) = $0 { return text } else { return nil } }
    }

    func testConsoleRefusingTheStreamStopsWithoutRetrying() async {
        let http = FakeXboxHTTP { method, url, _ in
            if url.hasSuffix("/v5/sessions/home/play") { return FakeXboxHTTP.ok(#"{"sessionPath":"v5/sessions/home/ABC"}"#) }
            if url.hasSuffix("/ABC/state") { return FakeXboxHTTP.ok(#"{"state":"Failed","errorDetails":{"code":"ServerInUse","message":"busy"}}"#) }
            if method == "DELETE" { return FakeXboxHTTP.status(204) }
            return nil
        }
        let states = await run(http) { states in self.texts(states).contains { $0.hasPrefix("durdu:") } }
        XCTAssertEqual(states.first, .connecting)
        let stopped = texts(states).first { $0.hasPrefix("durdu:") }
        XCTAssertEqual(stopped?.hasPrefix("durdu:busy:"), true, "\(states)")
        // Konsol reddetti: oturum kapatılır, yeniden açılmaz (eskiden her 5 sn'de bir yeniden açılıyordu).
        XCTAssertEqual(http.calls.filter { $0.url.hasSuffix("/play") }.count, 1)
        XCTAssertEqual(http.calls.filter { $0.method == "DELETE" && $0.url.hasSuffix("/v5/sessions/home/ABC") }.count, 1)
        XCTAssertEqual(states.last, .disconnected(.stopped))
    }

    func testExpiredSignInIsReportedAndNotRetried() async {
        let http = FakeXboxHTTP { _, url, _ in url.hasSuffix("/v5/sessions/home/play") ? FakeXboxHTTP.status(401, "Unauthorized") : nil }
        let states = await run(http) { states in !self.texts(states).isEmpty }
        XCTAssertEqual(texts(states).first, "yeniden:signInRequired")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(http.calls.filter { $0.url.hasSuffix("/play") }.count, 1)
    }

    /// Hazır yayında WebRTC teklifi gerçekten kurulur (Mac'teki libwebrtc ile): dört veri kanalı, ses ve görüntü
    /// alıcısı, oynatıcının stereo düzeltmesi; teklif Xbox'ın beklediği gövdeyle gönderilir. Yanıt gelmez (Xbox yok).
    func testProvisionedStreamSendsAWebRTCOffer() async throws {
        let http = FakeXboxHTTP { method, url, _ in
            if url.hasSuffix("/v5/sessions/home/play") { return FakeXboxHTTP.ok(#"{"sessionPath":"v5/sessions/home/ABC"}"#) }
            if url.hasSuffix("/ABC/state") { return FakeXboxHTTP.ok(#"{"state":"Provisioned","errorDetails":null}"#) }
            if url.hasSuffix("/ABC/sdp") { return FakeXboxHTTP.status(method == "POST" ? 202 : 204) }
            if method == "DELETE" { return FakeXboxHTTP.status(204) }
            return nil
        }
        _ = await run(http) { _ in http.calls.contains { $0.method == "POST" && $0.url.hasSuffix("/ABC/sdp") } }
        let post = try XCTUnwrap(http.calls.first { $0.method == "POST" && $0.url.hasSuffix("/ABC/sdp") }, "SDP teklifi gönderilmedi")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((post.body ?? "").utf8)) as? [String: Any])
        XCTAssertEqual(body["messageType"] as? String, "offer")
        let sdp = try XCTUnwrap(body["sdp"] as? String)
        XCTAssertTrue(sdp.contains("m=audio"), sdp)
        XCTAssertTrue(sdp.contains("m=video"), sdp)
        XCTAssertTrue(sdp.contains("m=application"), sdp)
        XCTAssertTrue(sdp.contains("useinbandfec=1; stereo=1"), sdp)
        XCTAssertTrue(sdp.contains("H264"), sdp)
        let configuration = try XCTUnwrap(body["configuration"] as? [String: Any])
        XCTAssertEqual((configuration["input"] as? [String: Any])?["maxVersion"] as? Int, 8)
    }

    func testReadyToConnectSendsTheTransferTokenOnce() async {
        let polls = Counter()
        let http = FakeXboxHTTP { method, url, _ in
            if url.hasSuffix("/v5/sessions/home/play") { return FakeXboxHTTP.ok(#"{"sessionPath":"v5/sessions/home/ABC"}"#) }
            if url.hasSuffix("/ABC/connect") { return FakeXboxHTTP.status(202) }
            if url.hasSuffix("/ABC/state") {
                // Hazırlanıyor → bağlanmaya hazır (iki kez) → konsol vazgeçti.
                switch polls.next() {
                case 1: return FakeXboxHTTP.ok(#"{"state":"Provisioning","errorDetails":null}"#)
                case 2, 3: return FakeXboxHTTP.ok(#"{"state":"ReadyToConnect","errorDetails":{"code":null,"message":null}}"#)
                default: return FakeXboxHTTP.ok(#"{"state":"Failed","errorDetails":{"code":"ConsoleOffline"}}"#)
                }
            }
            if method == "DELETE" { return FakeXboxHTTP.status(204) }
            return nil
        }
        let states = await run(http) { states in self.texts(states).contains { $0.hasPrefix("durdu:") } }
        let connects = http.calls.filter { $0.url.hasSuffix("/ABC/connect") }
        XCTAssertEqual(connects.count, 1)
        XCTAssertEqual(connects.first?.body, #"{"userToken":"LPT"}"#)
        XCTAssertEqual(texts(states).first { $0.hasPrefix("durdu:") }?.hasPrefix("durdu:consoleUnavailable:"), true, "\(states)")
    }
}

private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SessionState] = []
    func add(_ state: SessionState) { lock.withLock { list.append(state) } }
    var values: [SessionState] { lock.withLock { list } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
