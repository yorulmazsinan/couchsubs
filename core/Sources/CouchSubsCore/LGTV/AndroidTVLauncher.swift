// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Bekçinin Android TV'de TV uygulamasını açma yolu; Samsung'daki `SamsungLauncher` ile aynı kural (#1248). Uygulama TV'de
/// çalışırken bulunursa (`AndroidTVApp.alreadyRunning`: `am start` gönderilmedi, adres yayınla bildirildi) ya da `am start`
/// "zaten çalışıyor, öne getirildi" derse, uygulamaya kendisi bağlanması için `SamsungLauncher.resumeWait` (10 sn) tanınır;
/// bağlanmazsa bir kez kapatılıp (`am force-stop`) temiz açılır (`am start`). Bağlanırsa uygulamaya dokunulmaz. Windows'taki
/// AndroidTvLauncher ve Android telefondaki openAndroidTv ile aynı.
///
/// Eskiden Android TV'de bu yol yoktu: akışı kopan ama çalışmayı sürdüren TV uygulaması "zaten açık" sayılıyor, bekçi her
/// denemede yalnız adres yayını gönderiyordu; eski adrese takılmış ya da donmuş sayfa çeviri boyunca bağlanmıyordu.
public enum AndroidTVLauncher {
    /// Açma sonucu uygulamanın zaten çalıştığını söylüyor mu: açıcı `am start` göndermedi ("zaten açık") ya da `am start`
    /// "Activity not started" dedi (ekran yalnız öne geldi). Samsung'daki "resumed"ın karşılığı.
    public static func isResumed(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == AndroidTVApp.alreadyRunning || text.contains("Activity not started")
    }

    static func restartLine(_ output: String, seconds: Int64) -> String {
        "Android TV: TV uygulaması çalışıyordu (\(output)) ama \(seconds) sn'de bağlanmadı; kapatılıp (kapanma isteği, gerekirse am force-stop) yeniden açılıyor"
    }

    /// Açar (`open(false)`); çalışan ama bağlanmayan uygulamayı bir kez kapatıp açar (`open(true)`). Son açma çıktısı döner;
    /// açılamazsa hata.
    public static func open(_ open: (_ restart: Bool) async throws -> String, appConnected: () -> Bool,
                            resumeWait: Duration = SamsungLauncher.resumeWait, poll: Duration = .milliseconds(500),
                            log: (String) -> Void = { _ in }) async throws -> String {
        let output = try await open(false).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isResumed(output) else { return output }
        let deadline = ContinuousClock.now + resumeWait
        while ContinuousClock.now < deadline {
            if appConnected() { return output }
            try? await Task.sleep(for: poll)
        }
        if appConnected() { return output }
        log(restartLine(output, seconds: resumeWait.components.seconds))
        return try await open(true).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `open`'ın bloklayan hâli (iPhone'un ADB kurucusu bloklar).
    public static func openBlocking(_ open: (_ restart: Bool) throws -> String, appConnected: () -> Bool,
                                    resumeWait: TimeInterval = TimeInterval(SamsungLauncher.resumeWait.components.seconds),
                                    poll: TimeInterval = 0.5, sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                                    now: () -> Date = Date.init, log: (String) -> Void = { _ in }) throws -> String {
        let output = try open(false).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isResumed(output) else { return output }
        let deadline = now().addingTimeInterval(resumeWait)
        while now() < deadline {
            if appConnected() { return output }
            sleep(poll)
        }
        if appConnected() { return output }
        log(restartLine(output, seconds: Int64(resumeWait)))
        return try open(true).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
