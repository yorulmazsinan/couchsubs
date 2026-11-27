// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Uygulanmak üzere uygulamayı kapatan güncelleme: hangi sürümden (yapı numarasıyla) hangisine, hangi kopyada, ne zaman.
public struct AppUpdateAttempt: Codable, Equatable, Sendable {
    public var fromVersion: String
    public var fromBuild: Int
    public var targetVersion: String
    public var targetBuild: Int
    /// Güncellenen kopyanın yolu (ör. /Applications/CouchSubs.app).
    public var appPath: String
    public var at: Date

    public init(fromVersion: String, fromBuild: Int, targetVersion: String, targetBuild: Int, appPath: String, at: Date) {
        self.fromVersion = fromVersion
        self.fromBuild = fromBuild
        self.targetVersion = targetVersion
        self.targetBuild = targetBuild
        self.appPath = appPath
        self.at = at
    }
}

/// Mac'te güncelleme denemesinin kaydı (Windows'taki CouchSubs.Shell/Updates.cs `UpdateAttemptJournal`'ın karşılığı).
///
/// "Güncelleme var" penceresi güncellemeden sonra yeniden çıkıyordu (X bildirimi, beta.107). Sparkle sürümleri yapı
/// numarasıyla karşılaştırır (appcast'teki sparkle:version = CFBundleVersion = commit sayısı; beta.99: 1271 …
/// beta.107: 1345, tekdüze artıyor), sürüm metni karşılaştırılmaz. Güncelleme uygulanmış ama açılan uygulama hâlâ eski
/// sürümse nedeni kopyadır: Sparkle yalnız çalışan kopyayı değiştirir; kullanıcı İndirilenler'deki ya da disk
/// görüntüsündeki kopyayı güncelleyip Dock/Launchpad'den /Applications'taki eskisini açınca aynı pencere her açılışta
/// gelir. Kurmadan önce hedef yazılır; sonraki açılışta yapı hâlâ hedefin gerisindeyse deneme başarısız sayılır, günlüğe
/// iki kopyanın yolu yazılır ve ana ekran nedenini söyler. Hedefe ulaşılınca kayıt silinir.
public struct AppUpdateJournal: Sendable {
    /// ~/Library/Application Support/CouchSubs/guncelleme-denemesi.json (Windows: %LOCALAPPDATA%\CouchSubs\ ile aynı ad).
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CouchSubs/guncelleme-denemesi.json")
    }

    public let file: URL
    public let currentVersion: String
    public let currentBuild: Int
    public let currentPath: String

    public init(file: URL, currentVersion: String, currentBuild: Int, currentPath: String) {
        self.file = file
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.currentPath = currentPath
    }

    public func record(targetVersion: String, targetBuild: Int, now: Date = Date()) {
        let attempt = AppUpdateAttempt(fromVersion: currentVersion, fromBuild: currentBuild, targetVersion: targetVersion,
                                       targetBuild: targetBuild, appPath: currentPath, at: now)
        guard let data = try? JSONEncoder().encode(attempt) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    public func read() -> AppUpdateAttempt? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(AppUpdateAttempt.self, from: data)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    /// Açılışta: önceki deneme bu yapıya ulaşamadıysa o deneme; ulaştıysa kayıt silinir ve nil döner.
    public func failedAttempt() -> AppUpdateAttempt? {
        guard let attempt = read(), attempt.targetBuild > 0 else { return nil }
        guard currentBuild < attempt.targetBuild else {
            clear()
            return nil
        }
        return attempt
    }
}

/// Uygulamanın çalıştığı yer: Sparkle kendini yalnız yazılabilir, kalıcı bir yerdeki kopyada değiştirebilir.
public enum AppCopyLocation: Equatable, Sendable {
    /// /Applications ya da kullanıcının başka bir klasörü.
    case normal
    /// İndirilen zip'ten açılan kopya macOS'un geçici yerinde (App Translocation) çalışıyor; güncelleme kalıcı olmaz.
    case translocated
    /// Disk görüntüsünün (CouchSubs-macos.dmg) içinden açıldı; salt okunur, güncellenemez.
    case diskImage

    public static func of(path: String) -> AppCopyLocation {
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .diskImage }
        return .normal
    }

    /// Bu kopya kendini güncelleyebilir mi (Windows'ta zip'ten açılan kopyanın karşılığı).
    public var canUpdateItself: Bool { self == .normal }
}

/// Bu Mac'teki CouchSubs kopyalarından biri (Launch Services'in bildiği).
public struct AppCopy: Equatable, Sendable {
    public var path: String
    public var version: String
    public var build: Int

    public init(path: String, version: String, build: Int) {
        self.path = path
        self.version = version
        self.build = build
    }

    /// Çalışan kopyadan yeni olan başka bir kopya (en yenisi); yoksa nil. Güncelleme o kopyaya uygulanmış olabilir.
    public static func newerElsewhere(than current: AppCopy, in copies: [AppCopy]) -> AppCopy? {
        let currentPath = URL(fileURLWithPath: current.path).standardizedFileURL.path
        return copies
            .filter { URL(fileURLWithPath: $0.path).standardizedFileURL.path != currentPath && $0.build > current.build }
            .max { $0.build < $1.build }
    }

    /// Günlük satırı: "/Applications/CouchSubs.app 0.1.0-beta.107 (1345)".
    public var logText: String { "\(path) \(version) (\(build))" }
}

/// Açılışta ana ekranda söylenecek güncelleme sorunu (Windows'taki uygulanamayan güncelleme ve zip kopyası şeridinin
/// karşılığı).
public enum AppUpdateIssue: Equatable, Sendable {
    /// Önceki güncelleme bu kopyaya ulaşmadı; `newerCopy` güncellemenin gittiği (daha yeni) başka kopya.
    case failed(AppUpdateAttempt, newerCopy: AppCopy?)
    /// Bu kopya disk görüntüsünden ya da macOS'un geçici yerinden çalışıyor; güncelleme kalıcı olmaz.
    case cannotUpdateItself(AppCopyLocation)
    /// Bu Mac'te daha yeni bir kopya var; Dock/Launchpad eskisini açıyor.
    case newerCopyElsewhere(AppCopy)

    /// Öncelik: uygulanamayan güncelleme, güncellenemeyen yer, başka yerdeki yeni kopya.
    public static func atLaunch(failed: AppUpdateAttempt?, location: AppCopyLocation, current: AppCopy,
                                copies: [AppCopy]) -> AppUpdateIssue? {
        let newer = AppCopy.newerElsewhere(than: current, in: copies)
        if let failed { return .failed(failed, newerCopy: newer) }
        if !location.canUpdateItself { return .cannotUpdateItself(location) }
        if let newer { return .newerCopyElsewhere(newer) }
        return nil
    }
}
