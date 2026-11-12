// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CouchSubsCore
import Foundation
import RemotePlay

/// PS5 bağlantısı (gerçekte `StreamSession`).
protocol StreamControlling: AnyObject {
    var onFrame: ((CGImage) -> Void)? { get set }
    var onState: ((SessionState) -> Void)? { get set }
    var onConsoleMoved: ((RegisteredConsole) -> Void)? { get set }
    func start()
    func stop()
    func reconnectNow()
}

/// TV uygulamasını açık tutan görevli (gerçekte `TVKeeper`).
protocol KeeperControlling: AnyObject {
    func start(interval: Duration)
    func stop()
    func reconnect()
}

extension StreamSession: StreamControlling {}
extension TVKeeper: KeeperControlling {}

/// Denetlenemeyen TV'ler (Android TV) için: TV uygulaması telefonu ağda kendisi bulur.
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
    func pairTV(_ tv: LGTV, key: String?, server: String) async throws -> TVPairing
    func makeStream(console: RegisteredConsole, accountId: Data) -> StreamControlling
    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void) -> KeeperControlling
    func checkDeepLKey(_ key: String) async -> OnlineKeyCheck
    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure>
}

final class LivePhoneServices: PhoneServices {
    func discoverConsoles() async -> [ConsoleInfo] {
        let found = await Console.discover()
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

    func pairTV(_ tv: LGTV, key: String?, server: String) async throws -> TVPairing {
        switch tv.brand {
        case .androidTV:
            // Telefon bu TV'yi denetlemez; TV uygulaması altyazı sunucusunu ağda kendisi bulur.
            return TVPairing(key: "", launched: true)
        case .samsung:
            let client = SamsungClient(tv: tv, token: key)
            defer { client.close() }
            let token = try await client.connect()
            let launched = (try? await client.launch(appId: AppIdentity.samsungAppId, params: ["server": server])) != nil
            return TVPairing(key: token, launched: launched)
        case .lg:
            let client = SSAPClient(tv: tv, clientKey: key)
            defer { client.close() }
            let newKey = try await client.connect()
            let launched = (try? await client.launch(appId: AppIdentity.tvAppId, params: ["server": server])) != nil
            return TVPairing(key: newKey, launched: launched)
        }
    }

    func makeStream(console: RegisteredConsole, accountId: Data) -> StreamControlling {
        StreamSession(console: console, accountId: accountId)
    }

    func makeKeeper(tv: LGTV, key: String?, params: [String: Any], appConnected: @escaping @Sendable () -> Bool,
                    onMoved: @escaping (LGTV) -> Void) -> KeeperControlling {
        switch tv.brand {
        case .androidTV:
            return IdleKeeper()
        case .samsung:
            let locator = TVLocator(tv: tv, connect: { tv in
                let client = SamsungClient(tv: tv, token: key)
                do { _ = try await client.connect() } catch { client.close(); throw error }
                return client
            }, search: { await SamsungDiscovery.search() }, onMoved: onMoved)
            return TVKeeper(connect: { try await locator.connect() }, appId: AppIdentity.samsungAppId, params: params,
                            appConnected: appConnected)
        case .lg:
            let locator = TVLocator(tv: tv, connect: { tv in
                let client = SSAPClient(tv: tv, clientKey: key)
                do { _ = try await client.connect() } catch { client.close(); throw error }
                return client
            }, search: { await LGDiscovery.search() }, onMoved: onMoved)
            return TVKeeper(connect: { try await locator.connect() }, appId: AppIdentity.tvAppId, params: params)
        }
    }

    func checkDeepLKey(_ key: String) async -> OnlineKeyCheck { await DeepLTranslator.check(key: key) }

    func testAIKey(provider: AIProvider, key: String, model: String?) async -> Result<String, AIFailure> {
        await AITranslationCore.test(provider: provider, key: key, model: model)
    }
}
