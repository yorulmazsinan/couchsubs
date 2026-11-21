// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import Foundation
import RemotePlay
import XboxStream

/// PS5 bağlantısı (gerçekte `StreamSession`).
protocol StreamControlling: AnyObject {
    var onFrame: ((CGImage) -> Void)? { get set }
    var onState: ((SessionState) -> Void)? { get set }
    var onConsoleMoved: ((RegisteredConsole) -> Void)? { get set }
    func start()
    func stop()
    func reconnectNow()
    /// Oturum yeniden denemeyi kendisi bıraktı (kullanıcı durdurmadı); `reconnectNow` artık bir şey yapmaz.
    var hasGivenUp: Bool { get }
    /// Xbox: "Xbox sesini bu cihazda çal" çeviri sürerken değişti; yalnız yerel ses açılır/kısılır, yeni oturum açılmaz (#871).
    func setPlayAudio(_ enabled: Bool)
}

extension StreamControlling {
    func setPlayAudio(_ enabled: Bool) {}
}

/// TV uygulamasını açık tutan görevli (gerçekte `TVKeeper`).
protocol KeeperControlling: AnyObject {
    func start(interval: Duration)
    func stop()
    func reconnect()
}

extension StreamSession: StreamControlling {}
/// Xbox ev yayını (Beta): Mac uygulamasıyla ortak oturum (remoteplay/Sources/XboxStream).
extension XboxStreamSession: StreamControlling {}
extension TVKeeper: KeeperControlling {}

/// Deneme modunun "konsolu": uygulamadaki örnek kareleri (`DemoFrameSource`) akış gibi verir; ağ kullanmaz.
final class DemoStream: StreamControlling {
    var onFrame: ((CGImage) -> Void)?
    var onState: ((SessionState) -> Void)?
    var onConsoleMoved: ((RegisteredConsole) -> Void)?
    private let source = DemoFrameSource()

    func start() {
        source.onFrame = { [weak self] frame in self?.onFrame?(frame) }
        source.start()
        onState?(.streaming)
    }

    func stop() { source.stop() }

    func reconnectNow() {}

    var hasGivenUp: Bool { false }
}

/// Adresi bilinmeyen TV için: TV uygulaması telefonu ağda kendisi bulur.
final class IdleKeeper: KeeperControlling {
    func start(interval: Duration) {}
    func stop() {}
    func reconnect() {}
}

struct TVPairing: Equatable {
    let key: String
    /// false ise TV uygulaması açılamadı; büyük olasılıkla TV'de kurulu değil.
    let launched: Bool
}

/// Dış dünyayla (PS5, PSN, TV, çeviri hizmetleri) konuşan her şey; testlerde sahtesi kullanılır.
/// Mac'teki `AppServices`'in telefonda çalışan kısmı: TV uygulamasını kurmak (ssh, sdb, adb) iOS'ta yapılamaz.
protocol PhoneServices: AnyObject {
    func discoverConsoles() async -> [ConsoleInfo]
    func accountId(fromRedirect url: URL) async throws -> Data
    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole
    func discoverTVs() async -> [LGTV]
    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing
    /// Eşleşme isteği gönderen TV: marka ve ad adresten yoklanır (bkz. `PairedTV.identify`); tanınmazsa nil.
    func identifyTV(host: String) async -> LGTV?
    /// `loginPasscode`: PS5 bu hesap için giriş şifresi isterse gönderilecek 4 hane (Ayarlar'da kayıtlıysa).
    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling
    /// `onKey`: TV bağlantıda yeni jeton verdi (Samsung); saklanır.
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling
    func checkDeepLKey(_ key: String) async -> OnlineKeyCheck
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure>
    /// Yerel model sunucusunu (aynı ağdaki Ollama, LM Studio) örnek satırla dener; anahtar boş olabilir.
    func testLocalAI(server: LocalAIServer, key: String) async -> Result<String, AIFailure>
}

extension PhoneServices {
    func identifyTV(host: String) async -> LGTV? { await PairedTV.identify(host: host) }

    /// PS5'te o an çalışan oyun: yalnız bağlı PS5'in adresine keşif sorusu gider (ortak havuz için; bkz. `RunningGame`).
    func runningGame(host: String) async -> RunningGame? {
        guard let info = await Console.discover(timeout: .seconds(2), host: host).first else { return nil }
        return RunningGame(titleId: info.runningAppTitleId, name: info.runningAppName)
    }
}

final class LivePhoneServices: PhoneServices {
    func discoverConsoles() async -> [ConsoleInfo] {
        // İlk aramada iOS "Yerel Ağ" izin penceresini açar; kullanıcı izin verene kadar giden istekler düşer. Bulunamazsa
        // bir kez daha aranır.
        var found = await Console.discover()
        if found.isEmpty { found = await Console.discover() }
        RemotePlayLog.write("PS5 araması: \(found.isEmpty ? "bulunamadı" : found.map { "\($0.name) \($0.host)" }.joined(separator: ", "))")
        return found
    }

    func accountId(fromRedirect url: URL) async throws -> Data { try await PSNAccount.accountId(fromRedirect: url) }

    func register(host: String, accountId: Data, pin: UInt32) async throws -> RegisteredConsole {
        try await Registration.register(host: host, accountId: accountId, pin: pin)
    }

    func discoverTVs() async -> [LGTV] {
        async let lg = LGDiscovery.search()
        async let samsung = SamsungDiscovery.search()
        return await lg + samsung
    }

    func pairTV(_ tv: LGTV, key: String?, server: String, accessKey: String) async throws -> TVPairing {
        switch tv.brand {
        case .androidTV:
            // ADB açıksa (uygulama bu telefondan kurulduysa) TV uygulaması telefonun adresiyle açılır; değilse TV
            // uygulaması altyazı sunucusunu ağda kendisi bulur. İkisinde de TV, ekrandaki kodun onayıyla eşleşir.
            guard !tv.host.isEmpty else { return TVPairing(key: "", launched: true) }
            let port = InstalledTVApp.adbPort(for: tv.host)
            _ = await Task.detached(priority: .utility) {
                try? AndroidTvInstaller(host: tv.host, port: port).open(launchParams: AndroidTvInstaller.launchParams(server: server))
            }.value
            return TVPairing(key: "", launched: true)
        case .samsung:
            let client = SamsungClient(tv: tv, token: key)
            defer { client.close() }
            let token = try await client.connect()
            let launched = (try? await client.launch(appId: AppIdentity.samsungAppId, params: ["server": server, "key": accessKey])) != nil
            return TVPairing(key: token, launched: launched)
        case .lg:
            let client = SSAPClient(tv: tv, clientKey: key)
            defer { client.close() }
            let newKey = try await client.connect()
            let launched = (try? await client.launch(appId: AppIdentity.tvAppId, params: ["server": server, "key": accessKey])) != nil
            return TVPairing(key: newKey, launched: launched)
        }
    }

    func makeStream(console: RegisteredConsole, accountId: Data, loginPasscode: String?) -> StreamControlling {
        StreamSession(console: console, accountId: accountId, loginPasscode: loginPasscode)
    }

    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void, onKey: @escaping @Sendable (String) -> Void,
                    consolePort: @escaping @Sendable () -> Int?,
                    onOpenResult: @escaping @Sendable (TVOpenProblem?) -> Void) -> KeeperControlling {
        switch tv.brand {
        case .androidTV:
            guard let server = params["server"] as? String, !tv.host.isEmpty else { return IdleKeeper() }
            return AndroidTVKeeper(host: tv.host, port: InstalledTVApp.adbPort(for: tv.host), server: server, appConnected: appConnected,
                                   onOpenResult: onOpenResult)
        case .samsung:
            let token = SamsungTokenHolder(token: key, onChange: onKey)
            let paired = tv.host
            let locator = TVLocator(tv: tv, connect: { tv in
                // Adresi değişen TV'de kurulu olduğu bilgisi yeni adrese de geçer (yoksa bekçi listeye bakıp açmayabilir).
                SamsungAppKnowledge.shared.carry(from: paired, to: tv.host)
                let client = SamsungClient(tv: tv, token: token.current)
                do {
                    let received = try await client.connect()
                    token.received(received)
                } catch {
                    client.close()
                    throw error
                }
                return client
            }, search: { await SamsungDiscovery.search() }, onMoved: onMoved)
            // Önce geliştirici bağlantısı (sdb) denenir (Mac ve Windows ile aynı): uzaktan kumanda bağlantısıyla açmayı bazı
            // TV'ler sessizce yok sayıyor, kullanıcı CouchSubs'ı kumandayla açmak zorunda kalıyordu (TestFlight build 27).
            let host = tv.host
            return TVKeeper(connect: { SamsungLauncher(openWithSdb: { await Self.openSamsungApp(host: host) },
                                                       connectRemote: { try await locator.connect() }) },
                            appId: AppIdentity.samsungAppId, params: params, appConnected: appConnected, onOpenResult: onOpenResult)
        case .lg:
            let locator = TVLocator(tv: tv, connect: { tv in
                let client = SSAPClient(tv: tv, clientKey: key)
                do { _ = try await client.connect() } catch { client.close(); throw error }
                return client
            }, search: { await LGDiscovery.search() }, onMoved: onMoved)
            return TVKeeper(connect: { try await locator.connect() }, appId: AppIdentity.tvAppId, params: params, consolePort: consolePort,
                            onOpenResult: onOpenResult)
        }
    }

    /// Kurulu Samsung TV uygulamasını geliştirici bağlantısıyla açar; sdb portu (26101) kapalıysa beklemeden false.
    static func openSamsungApp(host: String) async -> Bool {
        guard !host.isEmpty, await DevModeInstaller.isPortOpen(host: host, port: 26101) else { return false }
        return await Task.detached(priority: .utility) { SamsungInstaller(host: host, signIn: nil).openApp() }.value
    }

    func checkDeepLKey(_ key: String) async -> OnlineKeyCheck { await DeepLTranslator.check(key: key) }

    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure> {
        await AITranslationCore.test(provider: provider, key: key, model: model)
    }

    func testLocalAI(server: LocalAIServer, key: String) async -> Result<String, AIFailure> {
        await AITranslationCore.test(provider: .local, key: key, model: server.model, server: server)
    }
}
