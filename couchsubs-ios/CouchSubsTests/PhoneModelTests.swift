// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import RemotePlay
import XCTest
@testable import CouchSubs

private final class FakeStream: StreamControlling {
    var onFrame: ((CGImage) -> Void)?
    var onState: ((SessionState) -> Void)?
    var onConsoleMoved: ((RegisteredConsole) -> Void)?
    private(set) var started = false
    private(set) var stopped = false
    private(set) var starts = 0
    func start() { started = true; starts += 1; hasGivenUp = false }
    func stop() { stopped = true }
    private(set) var reconnects = 0
    func reconnectNow() { reconnects += 1 }
    var hasGivenUp = false
}

private final class FakeKeeper: KeeperControlling {
    private(set) var running = false
    func start(interval: Duration) { running = true }
    func stop() { running = false }
    func reconnect() {}
}

private final class FakeServices: PhoneServices {
    var registerResult: Result<RegisteredConsole, Error> = .success(RegisteredConsole(host: "192.168.1.20", name: "PS5", registKey: Data(), morning: Data()))
    var launched = true
    let stream = FakeStream()

    func discoverConsoles() async -> [ConsoleInfo] { [ConsoleInfo(host: "192.168.1.20", name: "PS5", isAwake: true)] }
    func accountId(fromRedirect url: URL) async throws -> Data { Data([1, 2, 3]) }
    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole { try registerResult.get() }
    /// Ağda bulunan TV'ler ve yanıt vermeyen adresler (gerçek ağa çıkılmaz).
    var tvs: [LGTV] = []
    var silentHosts: Set<String> = []
    private(set) var searches = 0
    func discoverTVs() async -> [LGTV] { searches += 1; return tvs }
    func tvResponds(host: String, brand: TVBrand) async -> Bool { !silentHosts.contains(host) }
    var paired: [LGTV] = []
    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing {
        paired.append(tv)
        return TVPairing(key: "key", launched: launched)
    }
    var identify: (String) -> LGTV? = { LGTV(name: "Samsung TV", host: $0, brand: .samsung) }
    func identifyTV(host: String) async -> LGTV? { identify(host) }
    var streamPasscodes: [String?] = []
    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling {
        streamPasscodes.append(loginPasscode)
        return stream
    }
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling {
        let keeper = FakeKeeper()
        keepers.append((tv, keeper))
        openResults.append(onOpenResult)
        return keeper
    }
    /// Kurulan her bekçi ve kurulduğu TV kaydı.
    var keepers: [(tv: LGTV, keeper: FakeKeeper)] = []
    var openResults: [@Sendable (TVOpenProblem?) -> Void] = []
    func checkDeepLKey(_ key: String) async -> OnlineKeyCheck {
        key == "good" ? OnlineKeyCheck(state: .valid, used: 12_345, limit: 500_000) : OnlineKeyCheck(state: .invalid)
    }
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure> {
        key == "good" ? .success("Merhaba") : .failure(.invalidKey)
    }
    func testLocalAI(server: LocalAIServer, key: String) async -> Result<String, AIFailure> {
        server.address == "http://192.168.1.20:11434" ? .success("Merhaba") : .failure(.unreachable)
    }
}

@MainActor
final class PhoneModelTests: XCTestCase {
    private var services: FakeServices!
    private var defaults: UserDefaults!

    override func setUp() {
        services = FakeServices()
        defaults = scratchDefaults("PhoneModelTests")
    }

    private func makeModel() -> PhoneModel { PhoneModel(services: services, store: EphemeralStore(), defaults: defaults) }

    func testSetupFlowNeedsSignInAndPS5() async throws {
        let model = makeModel()
        XCTAssertEqual(model.step, .welcome)
        model.advance()
        XCTAssertEqual(model.step, .psnLogin)
        XCTAssertFalse(model.canAdvance)
        try await model.completePSNLogin(redirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=x")!)
        model.advance()
        XCTAssertEqual(model.step, .console)
        XCTAssertFalse(model.canAdvance)
        try await model.register(host: "192.168.1.20", pin: "1234 5678")
        model.advance()
        XCTAssertEqual(model.step, .output)
        XCTAssertFalse(model.canAdvance)
        model.usePhoneScreen()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(model.settings.output, .computer)
        XCTAssertTrue(model.canStart)
    }

    func testRegisterExplainsFailures() async {
        let model = makeModel()
        do {
            try await model.register(host: "192.168.1.20", pin: "123")
            XCTFail("kod kısa")
        } catch {
            XCTAssertEqual(error as? PhoneError, .invalidPin)
        }
        try? await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        services.registerResult = .failure(Registration.RegistrationError(.wrongCode, detail: "PS5 kodu"))
        do {
            try await model.register(host: "192.168.1.20", pin: "12345678")
            XCTFail("kod yanlış")
        } catch {
            XCTAssertEqual(error as? PhoneFailure, PhoneFailure(error: .wrongCode, detail: "PS5 kodu"))
        }
    }

    func testPairingRemembersMissingTVApp() async throws {
        services.launched = false
        let model = makeModel()
        try await model.pair(LGTV(name: "LG", host: "192.168.1.30", brand: .lg))
        XCTAssertTrue(model.hasTV)
        XCTAssertTrue(model.tvAppMissing)
        XCTAssertEqual(model.settings.output, .tv)
    }

    /// İki TV'li ev (X, beta.105): LG eşli ama CouchSubs onda yok, altyazı Android TV'deki (TCL) uygulamaya gidiyor. Ana
    /// ekrandaki "TV uygulamasını bu telefondan kur" hiç kalkmıyordu; öbür TV'nin bildirdiği sürüm de LG'ninki sayılıyordu.
    /// Öbür TV'nin uygulaması bağlanınca öneri kalkar, kayıtlı TV ve sürümü değişmez; kayıtlı TV'nin bağlanması da kaldırır.
    func testOtherTVsAppDoesNotKeepTheInstallPromptOrTouchTheSavedTV() async throws {
        services.launched = false
        let model = makeModel()
        try await model.pair(LGTV(name: "LG", host: "192.168.1.30", brand: .lg))
        XCTAssertTrue(model.tvAppMissing)
        model.tvAppReported("0.9.50", from: "192.168.1.41")
        XCTAssertFalse(model.tvAppMissing)
        XCTAssertNil(model.tvAppUpdate)
        XCTAssertEqual(model.tv?.host, "192.168.1.30")
        XCTAssertNil(model.installedTVApp)

        try await model.pair(LGTV(name: "LG", host: "192.168.1.30", brand: .lg))
        XCTAssertTrue(model.tvAppMissing)
        model.tvAppReported("0.9.120", from: "192.168.1.30")
        XCTAssertFalse(model.tvAppMissing)
        model.stop()
    }

    /// #985: Android TV DHCP'den yeni adres aldı. Kurulum TV'yi yeni adreste bulup kaydı güncelliyordu ama çeviri sürerken
    /// çalışan bekçi eski adresi tutuyor, TV uygulaması hep eski adreste açılmaya çalışılıyordu. Bekçi yeni adresle yeniden
    /// kurulur; eski bekçinin geç gelen açma sonucu yok sayılır.
    func testAndroidTVKeeperFollowsTheNewAddressAfterInstall() async throws {
        let model = makeModel()
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        try await model.pair(LGTV(name: "Android TV", host: "192.168.1.40", brand: .androidTV))
        await model.start()
        XCTAssertEqual(services.keepers.map { $0.tv.host }, ["192.168.1.40"])
        let stale = try XCTUnwrap(services.openResults.first)

        await model.tvAppInstalled(brand: .androidTV, host: "192.168.1.41", port: nil, version: "0.9.76")
        XCTAssertEqual(model.tv?.host, "192.168.1.41")
        XCTAssertEqual(services.keepers.map { $0.tv.host }, ["192.168.1.40", "192.168.1.41"])
        XCTAssertFalse(services.keepers[0].keeper.running)
        XCTAssertTrue(services.keepers[1].keeper.running)
        stale(.unreachable)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.tvOpenProblem)

        // Aynı adreste yeniden kurulum bekçiyi yenilemez.
        await model.tvAppInstalled(brand: .androidTV, host: "192.168.1.41", port: nil, version: "0.9.76")
        XCTAssertEqual(services.keepers.count, 2)
        model.stop()
    }

    /// #1158: uygulama TV'den silinince telefon onu "kurulu" gösteriyor, kurulum önerilmiyordu. TV "CouchSubs yok" deyince
    /// kayıt silinir, ana ekran kurulumu önerir; başka TV'nin bildirimi kayda dokunmaz.
    func testSamsungAppMissingForgetsTheInstalledRecord() async throws {
        let model = makeModel()
        await model.tvAppInstalled(brand: .samsung, host: "192.168.1.50", port: nil, version: "0.9.80")
        XCTAssertEqual(model.installedTVApp?.version, "0.9.80")
        XCTAssertTrue(SamsungAppKnowledge.shared.isKnown(host: "192.168.1.50"))
        XCTAssertFalse(model.tvAppMissing)
        model.samsungAppMissing(host: "192.168.1.99")
        XCTAssertNotNil(model.installedTVApp)
        model.samsungAppMissing(host: " 192.168.1.50 ")
        XCTAssertNil(model.installedTVApp)
        XCTAssertNil(defaults.data(forKey: StoreKey.tvAppInstalled))
        XCTAssertFalse(SamsungAppKnowledge.shared.isKnown(host: "192.168.1.50"))
        XCTAssertTrue(model.tvAppMissing)
        model.stop()
    }

    private func pairCall(_ method: String, _ model: PhoneModel, _ query: String = "") async throws -> (Int, [String: String]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.serverPort)/pair\(query)")!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, body)
    }

    private func waitForRequest(_ model: PhoneModel, id: String?) async throws {
        for _ in 0..<200 where model.tvPairingRequest?.id != id { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.tvPairingRequest?.id, id)
    }

    /// TestFlight, 21 Kas: TV kod beklerken sunucu yeniden açılınca (sağlık yoklaması, arka plandan dönüş) istek siliniyor,
    /// TV "Eşleştirme tamamlanmadı" diyor, telefondaki onay hiçbir şey yapmıyordu. İstek yeniden açılıştan sağ çıkar,
    /// onay TV'ye anahtarı verir; eşleşmiş TV'nin anahtarı yeniden açılıştan sonra da geçerlidir.
    func testTVPairingSurvivesServerRestart() async throws {
        let model = makeModel()
        await model.openTVPairing()
        XCTAssertTrue(model.tvPairingOpened)
        let (status, ticket) = try await pairCall("POST", model)
        XCTAssertEqual(status, 200)
        let id = try XCTUnwrap(ticket["id"])
        try await waitForRequest(model, id: id)
        await model.restartServer()
        XCTAssertEqual(model.tvPairingRequest?.id, id)
        model.resolveTVPairing(try XCTUnwrap(model.tvPairingRequest), accept: true)
        XCTAssertNil(model.tvPairingRequest)
        let (_, approved) = try await pairCall("GET", model, "?id=" + id)
        XCTAssertEqual(approved["key"], model.subtitleAccessKey)
        await model.restartServer()
        let (_, valid) = try await pairCall("GET", model, "?validate=1&k=" + model.subtitleAccessKey)
        XCTAssertEqual(valid["state"], "valid")
        // "TV eşleştir"in iki dakikası yeniden açılışta kapanmaz: yeni TV isteği arayüze ulaşır.
        let (again, next) = try await pairCall("POST", model)
        XCTAssertEqual(again, 200)
        try await waitForRequest(model, id: next["id"])
        model.resolveTVPairing(try XCTUnwrap(model.tvPairingRequest), accept: false)
        XCTAssertNil(model.tvPairingRequest)
    }

    /// PR #870 incelemesi: TV'nin başlattığı eşleşme onaylanınca TV kaydedilmiyordu (bekçi ve TV kartı çalışmıyordu). Onaylanan
    /// TV, elle seçilmiş gibi eşlenir: adres ve marka kayıtlı, izni saklı.
    func testApprovedTVRequestSavesTheTV() async throws {
        let model = makeModel()
        await model.openTVPairing()
        let (_, ticket) = try await pairCall("POST", model)
        try await waitForRequest(model, id: ticket["id"])
        let shown = try XCTUnwrap(model.tvPairingRequest)
        model.resolveTVPairing(SubtitlePairing.Ticket(id: shown.id, code: shown.code, host: "192.168.1.40"), accept: true)
        for _ in 0..<50 where !model.hasTV { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.hasTV)
        XCTAssertEqual(model.tv, LGTV(name: "Samsung TV", host: "192.168.1.40", brand: .samsung))
        XCTAssertEqual(services.paired.map(\.host), ["192.168.1.40"])
    }

    /// TV'de Tamam ile yeniden denenince telefondaki istek yenisiyle değişir; eski pencereden verilen onay yok sayılır ve
    /// yeni istek ekranda kalır.
    func testTVRetryReplacesTheShownRequest() async throws {
        let model = makeModel()
        await model.openTVPairing()
        let (_, first) = try await pairCall("POST", model)
        try await waitForRequest(model, id: first["id"])
        let old = try XCTUnwrap(model.tvPairingRequest)
        try await Task.sleep(nanoseconds: 2_100_000_000)
        let (status, second) = try await pairCall("POST", model)
        XCTAssertEqual(status, 200)
        try await waitForRequest(model, id: second["id"])
        model.resolveTVPairing(old, accept: true)
        XCTAssertEqual(model.tvPairingRequest?.id, second["id"])
        model.resolveTVPairing(try XCTUnwrap(model.tvPairingRequest), accept: true)
        let (_, approved) = try await pairCall("GET", model, "?id=" + (second["id"] ?? ""))
        XCTAssertEqual(approved["state"], "approved")
    }

    /// Ayarlar'daki PS5 giriş şifresi oturuma verilir; yalnız 4 hane kaydedilir.
    func testLoginPasscodeIsPassedToTheSession() async throws {
        let model = makeModel()
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        model.settings.output = .computer
        XCTAssertFalse(model.setLoginPasscode("123"))
        XCTAssertFalse(model.hasLoginPasscode)
        XCTAssertTrue(model.setLoginPasscode("0042"))
        XCTAssertTrue(model.hasLoginPasscode)
        await model.start()
        XCTAssertEqual(services.streamPasscodes, ["0042"])
        model.stop()
        model.removeLoginPasscode()
        XCTAssertFalse(model.hasLoginPasscode)
    }

    func testStartKeepsScreenAwakeAndStopReleasesIt() async throws {
        let model = makeModel()
        var awake: [Bool] = []
        model.keepScreenAwake = { awake.append($0) }
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        XCTAssertTrue(model.isRunning)
        XCTAssertTrue(services.stream.started)
        model.stop()
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(services.stream.stopped)
        XCTAssertEqual(awake, [true, false])
    }

    /// Denetim Merkezi ya da bildirimden dönmek bağlı PS5 oturumunu kapatıp açmaz; arka plandan dönmek yeniler.
    func testReturningWithoutBackgroundKeepsTheLiveSession() async throws {
        let model = makeModel()
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        services.stream.onState?(.streaming)
        for _ in 0..<100 where model.sessionState != .streaming { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.sessionState, .streaming)
        model.becameActive(afterBackground: false)
        XCTAssertEqual(services.stream.reconnects, 0)
        model.becameActive(afterBackground: true)
        XCTAssertEqual(services.stream.reconnects, 1)
        services.stream.onState?(.disconnected(.network))
        for _ in 0..<100 where model.sessionState == .streaming { try await Task.sleep(nanoseconds: 10_000_000) }
        model.becameActive(afterBackground: false)
        XCTAssertEqual(services.stream.reconnects, 2)
        model.stop()
    }

    /// TestFlight (iPhone): "bağlı olmasına rağmen çok kopuyor, sürekli uygulamayı açıp kapatmak zorunda kalıyorum". Oturum
    /// yeniden denemeyi bırakınca `reconnectNow` bir şey yapmıyordu; öne dönmek de bağlantıyı kurmuyordu. Artık dönüşte
    /// yeni oturum açılır, "Yeniden bağlan" düğmesi hemen görünür; kayıt ya da şifre sorununda kendiliğinden açılmaz.
    func testGivenUpSessionIsReopenedOnReturnAndByTheButton() async throws {
        let model = makeModel()
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        XCTAssertEqual(services.stream.starts, 1)
        XCTAssertFalse(model.offersReconnect())
        services.stream.onState?(.streaming)
        for _ in 0..<100 where model.sessionState != .streaming { try await Task.sleep(nanoseconds: 10_000_000) }

        // Görüntü hiç gelmedi, oturum bıraktı: düğme hemen görünür, öne dönünce yeni oturum açılır.
        services.stream.hasGivenUp = true
        services.stream.onState?(.disconnected(.noPicture))
        for _ in 0..<100 where model.sessionState == .streaming { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.offersReconnect())
        model.becameActive(afterBackground: false)
        XCTAssertEqual(services.stream.starts, 2)
        XCTAssertEqual(services.streamPasscodes.count, 2)
        XCTAssertEqual(services.stream.reconnects, 0)
        XCTAssertTrue(model.isRunning)
        XCTAssertFalse(model.offersReconnect())

        // Yanlış giriş şifresi: dönüşte yeniden gönderilmez, düğme görünür; düğme yeni oturum açar.
        services.stream.hasGivenUp = true
        services.stream.onState?(.disconnected(.loginPasscodeIncorrect))
        for _ in 0..<100 where model.sessionState != .disconnected(.loginPasscodeIncorrect) { try await Task.sleep(nanoseconds: 10_000_000) }
        model.becameActive(afterBackground: true)
        XCTAssertEqual(services.stream.starts, 2)
        XCTAssertTrue(model.offersReconnect())
        model.reconnect()
        XCTAssertEqual(services.stream.starts, 3)
        XCTAssertFalse(model.offersReconnect())

        // Süren denemelerde düğme 45 sn sonra görünür.
        services.stream.onState?(.disconnected(.network))
        for _ in 0..<100 where model.sessionState != .disconnected(.network) { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.offersReconnect())
        XCTAssertTrue(model.offersReconnect(now: Date().addingTimeInterval(ReconnectOffer.after + 1)))
        model.stop()
        XCTAssertFalse(model.offersReconnect(now: Date().addingTimeInterval(1000)))
    }

    /// X/DM'de bildirildi: iPhone arka plana alınınca ya da kilitlenince altyazı sessizce duruyordu. Çeviri sürerken arka
    /// plana geçilince uyarı kurulur, öne dönünce geri alınır; çeviri yokken ya da bildirim tercihi kapalıyken kurulmaz.
    func testGoingToBackgroundWhileTranslatingWarnsAndReturningClears() async throws {
        let model = makeModel()
        var paused = 0
        var resumed = 0
        model.onPausedInBackground = { paused += 1 }
        model.onResumedFromBackground = { resumed += 1 }
        model.enteredBackground()
        XCTAssertEqual(paused, 0)
        try await model.completePSNLogin(redirect: URL(string: "https://example.com")!)
        try await model.register(host: "192.168.1.20", pin: "12345678")
        model.settings.output = .computer
        await model.start()
        model.enteredBackground()
        XCTAssertEqual(paused, 1)
        model.becameActive(afterBackground: true)
        XCTAssertEqual(resumed, 1)
        // Denetim Merkezi'nden dönmek arka plan değildir.
        model.becameActive(afterBackground: false)
        XCTAssertEqual(resumed, 1)
        defaults.set(false, forKey: PhoneModel.notifyDisconnectKey)
        model.enteredBackground()
        XCTAssertEqual(paused, 1)
        model.stop()
    }

    func testPhoneScreenShowsSubtitlesOnlyWhenChosen() {
        let model = makeModel()
        model.clock = { 100 }
        // "Arka planda sürdür" (varsayılan açık) satırları PiP penceresi için TV seçiliyken de tutar (#775).
        model.backgroundPiP = false
        model.settings.output = .tv
        model.phoneReceive(.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false))
        XCTAssertTrue(model.phoneLines.isEmpty)
        model.settings.output = .computer
        model.phoneReceive(.subtitle(text: "Merhaba", durationMs: 4000, paragraphs: false))
        XCTAssertEqual(model.phoneLines.map(\.text), ["Merhaba"])
        model.stop()
        XCTAssertTrue(model.phoneLines.isEmpty)
    }

    func testKeysAreTestedBeforeSaving() async {
        let model = makeModel()
        let rejected = await model.saveKey("bad", for: .deepL)
        XCTAssertEqual(rejected, .rejected)
        XCTAssertFalse(model.hasKey(.deepL))
        let accepted = await model.saveKey("good", for: .gemini)
        XCTAssertEqual(accepted, .saved)
        XCTAssertTrue(model.hasKey(.gemini))
        XCTAssertEqual(model.settings.translationEngine, .gemini)
        model.removeKey(.gemini)
        XCTAssertEqual(model.settings.translationEngine, .free)
    }

    /// Yerel model (aynı ağdaki Ollama/LM Studio): anahtarsız çalışır; "Bağlantıyı dene" başarılıysa motor seçilir,
    /// isteğe bağlı anahtar kaydedilir; ulaşılamayan sunucuda motor değişmez (Mac ile aynı kural).
    func testLocalModelNeedsNoKeyAndIsSelectedAfterASuccessfulTest() async {
        let model = makeModel()
        model.settings.localAIBaseURL = "http://10.0.0.9:11434/v1"
        let unreachable = await model.testLocalAI()
        XCTAssertEqual(unreachable, .failure(.unreachable))
        XCTAssertEqual(model.settings.translationEngine, .free)
        model.settings.localAIBaseURL = "192.168.1.20:11434"
        XCTAssertTrue(model.isReady(.local))
        let works = await model.testLocalAI(key: "secret")
        XCTAssertEqual(works, .success("Merhaba"))
        XCTAssertEqual(model.settings.translationEngine, .local)
        XCTAssertTrue(model.hasKey(.local))
        model.removeKey(.local)
        XCTAssertEqual(model.settings.translationEngine, .local, "anahtarsız çeviri sürer")
    }

    /// Hizmet anahtarı kabul etse de Anahtarlık'a yazılamazsa anahtar kayıtlı sayılmaz, motor değişmez (Mac ile aynı).
    func testKeyIsNotReportedSavedWhenKeychainRejectsIt() async {
        final class RejectingStore: AppStore {
            func save<T: Encodable>(_ value: T, for key: String) {}
            func load<T: Decodable>(_ type: T.Type, for key: String) -> T? { nil }
            func remove(_ key: String) {}
        }
        let model = PhoneModel(services: services, store: RejectingStore(), defaults: defaults)
        let result = await model.saveKey("good", for: .gemini)
        XCTAssertEqual(result, .notStored)
        XCTAssertFalse(model.hasKey(.gemini))
        XCTAssertEqual(model.settings.translationEngine, .free)
    }

    /// "GTA 6'daki telefonu otomatik çevir": açık gelir (#1202); yalnız çeviri sürerken, ayar açıkken ve oyun GTA 6 iken izlenir.
    func testGamePhoneIsTrackedOnlyInGTA6WhenTurnedOn() {
        XCTAssertTrue(UserSettings().autoReadGamePhone)
        XCTAssertTrue(PhoneModel.tracksGamePhone(running: true, enabled: true, game: "Grand Theft Auto VI"))
        XCTAssertTrue(PhoneModel.tracksGamePhone(running: true, enabled: true, game: "GTA 6"))
        XCTAssertFalse(PhoneModel.tracksGamePhone(running: true, enabled: false, game: "GTA 6"))
        XCTAssertFalse(PhoneModel.tracksGamePhone(running: false, enabled: true, game: "GTA 6"))
        XCTAssertFalse(PhoneModel.tracksGamePhone(running: true, enabled: true, game: "Red Dead Redemption 2"))
        XCTAssertFalse(PhoneModel.tracksGamePhone(running: true, enabled: true, game: nil))
    }

    /// Oyun telefonunun çevirisi telefon ekranında her mesaj kendi balonunun yerinde çizilir (bloklar korunur; TV ve
    /// Android gibi); boş liste yalnız o alanı kaldırır. Bildirim (iPhone, 1.0.5): mesajlar telefonun üstünde tek kutuda
    /// birleşiyor, kimin ne yazdığı belli olmuyordu.
    func testGamePhoneMessagesArePlacedOnTheirOwnBubbles() {
        let other = PhoneModel.PhoneRegion(id: "help", text: "Yardım", box: nil)
        let items = [ScreenTranslation.Item(source: "Hi", translation: "Selam", box: TextBox(left: 0.7, top: 0.3, right: 0.9, bottom: 0.35), lineHeight: 0.03),
                     ScreenTranslation.Item(source: "Bye", translation: "Hoşça kal", box: TextBox(left: 0.72, top: 0.4, right: 0.88, bottom: 0.45), lineHeight: 0.03)]
        let shown = PhoneModel.phoneRegions([other], gamePhone: items)
        XCTAssertEqual(shown.map(\.id), ["help", "game-phone"])
        XCTAssertEqual(shown.last?.text, "Selam\nHoşça kal")
        XCTAssertEqual(shown.last?.box, TextBox(left: 0.7, top: 0.3, right: 0.9, bottom: 0.45))
        let placed = PhoneModel.placedItems(shown, screen: [])
        XCTAssertEqual(placed.map(\.translation), ["Selam", "Hoşça kal"])
        XCTAssertEqual(placed.map(\.box), items.map(\.box))
        // "Ekranı çevir" sonucu aynı balonu örterse o balonun telefon bloğu çizilmez, sonuç en üstte.
        let screen = ScreenTranslation.Item(source: "Hi", translation: "Merhaba", box: items[0].box, lineHeight: 0.03)
        XCTAssertEqual(PhoneModel.placedItems(shown, screen: [screen]).map(\.translation), ["Hoşça kal", "Merhaba"])
        XCTAssertEqual(PhoneModel.phoneRegions(shown, gamePhone: []), [other])
    }

    /// Ayarlar'daki DeepL kullanım satırı: kayıtlı anahtarın bu ayki kullanımı; anahtar yoksa satır çıkmaz.
    func testDeepLUsageNeedsASavedKey() async {
        let model = makeModel()
        let none = await model.deepLUsage()
        XCTAssertNil(none)
        let accepted = await model.saveKey("good", for: .deepL)
        XCTAssertEqual(accepted, .saved)
        let usage = await model.deepLUsage()
        XCTAssertEqual(usage, OnlineKeyCheck(state: .valid, used: 12_345, limit: 500_000))
        model.removeKey(.deepL)
        let removed = await model.deepLUsage()
        XCTAssertNil(removed)
    }

    /// Sony girişi engellenen kullanıcı hesap kimliğini base64 olarak elle yazar; web girişiyle aynı biçimde saklanır.
    func testManualAccountIdIsStoredLikeWebLogin() {
        let store = EphemeralStore()
        let model = PhoneModel(services: services, store: store, defaults: defaults)
        model.step = .psnLogin
        let id = Data([1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertTrue(model.useManualAccountId("  \(id.base64EncodedString()) "))
        XCTAssertEqual(model.accountId, id)
        XCTAssertTrue(model.canAdvance)
        XCTAssertEqual(store.load(Data.self, for: StoreKey.accountId), id)
    }

    func testInvalidManualAccountIdIsRejected() {
        for value in ["", "   ", "AQIDBAUGBw==", "AQIDBAUGBwgJ", "AQIDBAUGBw!=", "1234567890", "AQIDBAUGBwg"] {
            let store = EphemeralStore()
            let model = PhoneModel(services: services, store: store, defaults: defaults)
            XCTAssertFalse(model.useManualAccountId(value), value)
            XCTAssertNil(model.accountId, value)
            XCTAssertNil(store.load(Data.self, for: StoreKey.accountId), value)
        }
    }
}

// MARK: - TV'nin adresi değişince yeniden bulma (Mac, Windows ve Android ile aynı senaryolar)

@MainActor
final class TVRelocationTests: XCTestCase {
    private var services: FakeServices!
    private var defaults: UserDefaults!
    private let old = "192.168.1.238"
    private let new = "192.168.1.156"

    override func setUp() {
        services = FakeServices()
        defaults = scratchDefaults("TVRelocationTests")
    }

    private func pairedModel() async throws -> PhoneModel {
        let model = PhoneModel(services: services, store: EphemeralStore(), defaults: defaults)
        try await model.pair(LGTV(name: "LG TV", host: old, brand: .lg))
        return model
    }

    /// beta.89: kayıtlı adres sessiz, TV ağda yeni adreste. Kart kendiliğinden bulur, kayıt (ve kartta adres) güncellenir.
    func testSilentSavedTVIsFoundAtItsNewAddress() async throws {
        let model = try await pairedModel()
        services.silentHosts = [old]
        services.tvs = [LGTV(name: "LG TV", host: new, brand: .lg)]
        await model.checkTVReachable()
        XCTAssertEqual(model.tv?.host, new)
        XCTAssertFalse(model.tvNotResponding)
        XCTAssertEqual(model.tvStatusText, String(localized: "Waiting for the TV app"))
    }

    func testRespondingTVIsNotSearched() async throws {
        let model = try await pairedModel()
        await model.checkTVReachable()
        XCTAssertEqual(services.searches, 0)
        XCTAssertFalse(model.tvNotResponding)
        XCTAssertEqual(model.tv?.host, old)
    }

    /// Bulunamazsa "TV uygulaması bekleniyor" denmez; ağ en çok 30 sn'de bir aranır.
    func testSilentTVNotFoundSaysNotResponding() async throws {
        let model = try await pairedModel()
        services.silentHosts = [old]
        await model.checkTVReachable()
        XCTAssertTrue(model.tvNotResponding)
        XCTAssertEqual(model.tvStatusText, String(localized: "Not responding — searching again…"))
        XCTAssertEqual(model.tv?.host, old)
        await model.checkTVReachable()
        XCTAssertEqual(services.searches, 1, "Ağ her yoklamada aranmaz")
    }

    /// "TV'yi Eşleştir" eşli TV'ye ulaşamazsa açık hata; "TV'yi Yeniden Ara" beklemeden arar ve bulunca hata kalkar.
    func testPairButtonShowsErrorAndSearchAgainFindsTV() async throws {
        let model = try await pairedModel()
        services.silentHosts = [old]
        await model.openTVPairing()
        XCTAssertEqual(model.tvUnreachableHost, old)
        services.tvs = [LGTV(name: "LG TV", host: new, brand: .lg)]
        await model.searchTVAgain()
        XCTAssertNil(model.tvUnreachableHost)
        XCTAssertEqual(model.tv?.host, new)
    }

    /// "IP Adresi Gir": yazılan adreste aynı marka TV tanınırsa eşli TV o adrese taşınır; tanınmazsa taşınmaz.
    func testTypedAddressMovesPairedTV() async throws {
        let model = try await pairedModel()
        services.identify = { _ in nil }
        let rejected = await model.useTVAddress("192.168.1.99")
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.tv?.host, old)
        services.identify = { LGTV(name: "LG webOS TV", host: $0, brand: .lg) }
        let used = await model.useTVAddress(" 192.168.1.156 ")
        XCTAssertTrue(used)
        XCTAssertEqual(model.tv, LGTV(name: "LG TV", host: new, brand: .lg))
    }

    func testRemovePairingForgetsTheTV() async throws {
        let model = try await pairedModel()
        model.removeTVPairing()
        XCTAssertNil(model.tv)
        XCTAssertFalse(model.hasTV)
        XCTAssertEqual(model.settings.output, .computer)
    }

    /// Kurulum ("TV uygulamasını güncelle" dahil) kayıtlı adres sessizse TV'yi ağda arar; bulamazsa "yanıt vermiyor" (nil),
    /// "Key Server kapalı" denmez. Yanıt veren adres olduğu gibi kullanılır.
    func testInstallTargetFollowsTheTV() async throws {
        let model = try await pairedModel()
        let here = await model.relocateForInstall(host: old, brand: .lg)
        XCTAssertEqual(here, old)
        services.silentHosts = [old]
        let missing = await model.relocateForInstall(host: old, brand: .lg)
        XCTAssertNil(missing)
        services.tvs = [LGTV(name: "LG TV", host: new, brand: .lg)]
        let moved = await model.relocateForInstall(host: old, brand: .lg)
        XCTAssertEqual(moved, new)
        XCTAssertEqual(model.tv?.host, new)
    }

    /// Ayarlar'da "IP Adresi Gir": PS5'in yeni adresi elle yazılır; kayıt korunur, geçersiz adres reddedilir.
    func testEnteredConsoleAddressMovesTheRegisteredPS5() async throws {
        let model = makeModel()
        XCTAssertFalse(model.enterConsoleAddress("192.168.1.44"), "kayıtlı PS5 yokken adres yazılmaz")
        try await model.register(host: "192.168.1.20", pin: "12345678")
        XCTAssertFalse(model.enterConsoleAddress("192.168.1.300"))
        XCTAssertEqual(model.console?.host, "192.168.1.20")
        XCTAssertTrue(model.enterConsoleAddress(" 192.168.1.44 "))
        XCTAssertEqual(model.console?.host, "192.168.1.44")
        XCTAssertEqual(model.console?.name, "PS5")
    }
}
