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

private final class FakeServices: PhoneServices {
    var registerResult: Result<RegisteredConsole, Error> = .success(RegisteredConsole(host: "192.168.1.20", name: "PS5", registKey: Data(), morning: Data()))
    var launched = true
    let stream = FakeStream()

    func discoverConsoles() async -> [ConsoleInfo] { [ConsoleInfo(host: "192.168.1.20", name: "PS5", isAwake: true)] }
    func accountId(fromRedirect url: URL) async throws -> Data { Data([1, 2, 3]) }
    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole { try registerResult.get() }
    func discoverTVs() async -> [LGTV] { [] }
    var paired: [LGTV] = []
    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing {
        paired.append(tv)
        return TVPairing(key: "key", launched: launched)
    }
    func identifyTV(host: String) async -> LGTV? { LGTV(name: "Samsung TV", host: host, brand: .samsung) }
    var streamPasscodes: [String?] = []
    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling {
        streamPasscodes.append(loginPasscode)
        return stream
    }
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling { IdleKeeper() }
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
        defaults = UserDefaults(suiteName: "PhoneModelTests-\(UUID().uuidString)")
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

    /// "GTA 6'daki telefonu otomatik çevir": kapalı gelir; yalnız çeviri sürerken, ayar açıkken ve oyun GTA 6 iken izlenir.
    func testGamePhoneIsTrackedOnlyInGTA6WhenTurnedOn() {
        XCTAssertFalse(UserSettings().autoReadGamePhone)
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
}
