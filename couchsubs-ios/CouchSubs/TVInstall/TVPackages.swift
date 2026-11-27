// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// Uygulamayla gelen TV paketleri (derlemede konur: scripts/ios-tv-packages.sh). `tv/tv-packages.properties` hangi
/// sürümden geldiklerini ve sürümlerini yazar.
enum TVPackages {
    static var directory: URL? { Bundle.main.resourceURL?.appendingPathComponent("tv", isDirectory: true) }

    static let index: [String: String] = {
        guard let url = directory?.appendingPathComponent("tv-packages.properties"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }()

    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            result[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private static func bytes(_ name: String) throws -> [UInt8] {
        guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else {
            throw TVCryptoError("\(name) uygulamada yok")
        }
        return Array(data)
    }

    static var samsungVersion: String? { index["couchsubs-samsung.wgt.version"] }
    static func samsungPackage() throws -> [UInt8] { try bytes("couchsubs-samsung.wgt") }

    static var androidVersion: String? { index["couchsubs-androidtv.apk"] == nil ? nil : index["couchsubs-androidtv.apk.version"] }
    static func androidPackage() throws -> [UInt8] { try bytes("couchsubs-androidtv.apk") }

    /// Sürümdeki adı (`com.couchsubs.tv_0.9.18_all.ipk`).
    static var lgName: String? { index["couchsubs-lg.ipk"] }
    static var lgVersion: String? { lgName.flatMap(DevModeInstaller.version(ofPackage:)) }
    static func lgPackage() throws -> [UInt8] { try bytes("couchsubs-lg.ipk") }

    static func version(for brand: TVBrand) -> String? {
        switch brand {
        case .samsung: samsungVersion
        case .androidTV: androidVersion
        case .lg: lgVersion
        case .vestelLinux: nil
        }
    }
}

/// Bu telefonun TV uygulamasını kurduğu ya da sürümünü okuduğu TV (sonraki güncelleme denetimi buna bakar).
struct InstalledTVApp: Codable, Equatable {
    let brand: TVBrand
    let host: String
    /// Android TV'nin ADB portu (kablosuz hata ayıklamada değişir).
    var port: UInt16?
    var version: String

    /// Bu Android TV'ye en son hangi ADB portundan ulaşıldı (kablosuz hata ayıklamada değişir); bilinmiyorsa 5555.
    static func adbPort(for host: String, defaults: UserDefaults = .standard) -> UInt16 {
        let saved = defaults.data(forKey: StoreKey.tvAppInstalled).flatMap { try? JSONDecoder().decode(InstalledTVApp.self, from: $0) }
        guard let saved, saved.brand == .androidTV, saved.host == host, let port = saved.port else { return AdbConnection.defaultPort }
        return port
    }
}

extension StoreKey {
    /// Telefondan kurulan TV uygulaması (UserDefaults, `InstalledTVApp`).
    static let tvAppInstalled = "tvAppInstalled"
}

/// Telefondaki paketten eski TV uygulaması: ana ekranda "TV uygulamasını güncelle".
struct TVAppUpdate: Equatable {
    let brand: TVBrand
    let host: String
    let port: UInt16?
    let installed: String
    let bundled: String
}

/// TV'deki CouchSubs sürümünü sessizce okur (kurmadan, TV'de pencere açmadan). Ulaşılamazsa nil.
enum TVAppVersionCheck {
    /// Sessiz denetimin sonucu: sürüm, kesin "TV'de CouchSubs yok" (Samsung'da sdb bağlandı, `vd_applist` okundu,
    /// CouchSubs yok) ya da bilinmiyor (TV'ye ulaşılamadı, liste okunamadı).
    enum Outcome: Equatable {
        case version(String)
        case missing
        case unknown
    }

    static func installedVersion(brand: TVBrand, host: String, port: UInt16?) async -> String? {
        if case .version(let version) = await check(brand: brand, host: host, port: port) { return version }
        return nil
    }

    static func check(brand: TVBrand, host: String, port: UInt16?) async -> Outcome {
        guard !host.isEmpty else { return .unknown }
        return await Task.detached(priority: .utility) { () -> Outcome in
            switch brand {
            case .samsung:
                guard PosixSocket.isOpen(host: host, port: SdbConnection.port) else { return .unknown }
                return (try? SamsungInstaller(host: host, signIn: nil).installedPresence()) ?? .unknown
            case .androidTV:
                let port = port ?? AdbConnection.defaultPort
                guard PosixSocket.isOpen(host: host, port: port),
                      let version = try? AndroidTvInstaller(host: host, port: port).installedVersion() else { return .unknown }
                return .version(version)
            case .lg:
                return LGPhoneInstall.installedVersion(host: host).map(Outcome.version) ?? .unknown
            case .vestelLinux:
                return .unknown
            }
        }.value
    }
}
