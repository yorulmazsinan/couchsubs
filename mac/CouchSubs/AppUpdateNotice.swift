// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI
#if !APP_STORE
import Sparkle
#endif

/// "Güncelleme var" penceresi güncellemeden sonra yeniden çıkıyordu (beta.107, X bildirimi). Sparkle sürümü yapı
/// numarasıyla doğru karşılaştırıyor; neden çalışan kopya: güncelleme İndirilenler'deki ya da disk görüntüsündeki kopyaya
/// gidip Dock/Launchpad /Applications'taki eskisini açınca pencere her açılışta yeniden gelir. Windows'taki
/// `UpdateAttemptJournal` ve zip kopyası şeridinin karşılığı (windows/src/CouchSubs.Shell/Updates.cs):
/// - Sparkle kurmadan hemen önce hedef sürüm kaydedilir (`AppUpdateRecorder`).
/// - Açılışta yapı hâlâ hedefin gerisindeyse, kopya disk görüntüsünden/geçici yerden çalışıyorsa ya da bu Mac'te daha
///   yeni bir kopya varsa ana ekran nedenini söyler; günlüğe (altyazi.log) her açılışta bu kopyanın ve diğer
///   kopyaların yolu ile sürümü yazılır.
@MainActor
final class AppUpdateNotice: ObservableObject {
    static let shared = AppUpdateNotice()
    static let downloadPage = URL(string: "https://couchsubs.enmeraapps.com/#indir")!

    @Published private(set) var issue: AppUpdateIssue?
    private var checked = false

    static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// Çalışan kopya: yol, sürüm ve yapı numarası (CFBundleVersion).
    nonisolated static func copy(at url: URL) -> AppCopy? {
        guard let info = Bundle(url: url)?.infoDictionary else { return nil }
        return AppCopy(path: url.path, version: info["CFBundleShortVersionString"] as? String ?? "?",
                       build: Int(info["CFBundleVersion"] as? String ?? "") ?? 0)
    }

    nonisolated static var current: AppCopy {
        copy(at: Bundle.main.bundleURL) ?? AppCopy(path: Bundle.main.bundlePath, version: "?", build: 0)
    }

    nonisolated static func journal() -> AppUpdateJournal {
        let current = current
        return AppUpdateJournal(file: AppUpdateJournal.defaultFile, currentVersion: current.version,
                                currentBuild: current.build, currentPath: current.path)
    }

    /// Açılışta bir kez; testlerde ve Mac App Store sürümünde bakmaz.
    func checkOnce() {
        guard !checked, !Self.isTesting, !Distribution.isAppStore else { return }
        checked = true
        let current = Self.current
        let failed = Self.journal().failedAttempt()
        let location = AppCopyLocation.of(path: current.path)
        let copies = (NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.couchsubs.mac"))
            .filter { !$0.path.contains("/.Trash/") }
            .compactMap(Self.copy(at:))
        SubtitleLog.write("uygulama: \(current.logText)\(location == .normal ? "" : " (\(location == .diskImage ? "disk görüntüsünden" : "geçici yerden (App Translocation)") açıldı, kendini güncelleyemez)")")
        let others = copies.filter { URL(fileURLWithPath: $0.path).standardizedFileURL != URL(fileURLWithPath: current.path).standardizedFileURL }
        if !others.isEmpty { SubtitleLog.write("bu Mac'teki diğer CouchSubs kopyaları: \(others.map(\.logText).joined(separator: "; "))") }
        if let failed {
            SubtitleLog.write("güncelleme uygulanamadı: \(failed.fromVersion) (\(failed.fromBuild)) → \(failed.targetVersion) (\(failed.targetBuild)), \(failed.at); güncellenen kopya \(failed.appPath), açılan kopya hâlâ \(current.logText)")
        }
        issue = AppUpdateIssue.atLaunch(failed: failed, location: location, current: current, copies: copies)
    }

    func dismiss() {
        if case .failed = issue { Self.journal().clear() }
        issue = nil
    }
}

#if !APP_STORE
/// Sparkle güncellemeyi kurmadan hemen önce hedefi kaydeder; sonraki açılış hedefe ulaşıp ulaşmadığına bakar.
final class AppUpdateRecorder: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        let target = Int(item.versionString) ?? 0
        let journal = AppUpdateNotice.journal()
        journal.record(targetVersion: item.displayVersionString, targetBuild: target)
        SubtitleLog.write("güncelleme kuruluyor: \(journal.currentVersion) (\(journal.currentBuild)) → \(item.displayVersionString) (\(target)), kopya \(journal.currentPath)")
        SubtitleLog.flush()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        SubtitleLog.write("güncelleme durdu: \(error.localizedDescription)")
    }
}
#endif

/// Ana ekrandaki güncelleme notu.
struct AppUpdateNoticeText {
    let issue: AppUpdateIssue
    let currentPath: String

    var text: String {
        switch issue {
        case .failed(let attempt, let newer):
            let title = String(format: String(localized: "CouchSubs couldn't be updated to %@"), attempt.targetVersion)
            if let newer {
                return title + "\n" + String(format: String(localized: "The update went to another copy of CouchSubs (%@). Open that copy and delete this one, or the update prompt will keep coming back."), newer.path)
            }
            if attempt.appPath != currentPath {
                return title + "\n" + String(format: String(localized: "The update went to another copy of CouchSubs (%@). Open that copy and delete this one, or the update prompt will keep coming back."), attempt.appPath)
            }
            return title + "\n" + String(localized: "The update couldn't be applied. Download CouchSubs from our website, drag it into the Applications folder and replace the old one.")
        case .cannotUpdateItself:
            return String(localized: "This copy of CouchSubs can't update itself because it is running from the disk image or the Downloads folder. Drag CouchSubs into the Applications folder and open it from there.")
        case .newerCopyElsewhere(let newer):
            return String(format: String(localized: "There is a newer copy of CouchSubs (%@) at %@. Open that copy and delete this one, or the update prompt will keep coming back."), newer.version, newer.path)
        }
    }

    /// Finder'da gösterilecek kopya (varsa).
    var otherCopy: URL? {
        switch issue {
        case .failed(let attempt, let newer):
            if let newer { return URL(fileURLWithPath: newer.path) }
            return attempt.appPath != currentPath ? URL(fileURLWithPath: attempt.appPath) : nil
        case .newerCopyElsewhere(let newer): return URL(fileURLWithPath: newer.path)
        case .cannotUpdateItself: return nil
        }
    }
}
