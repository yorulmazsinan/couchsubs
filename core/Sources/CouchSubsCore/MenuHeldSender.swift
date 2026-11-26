// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Altyazı hattının göndericisi: ekranda menü varken (`ScreenTextDetector.inMenu`) altyazı satırları hemen gönderilmez,
/// bekletilir; temizleme geçer. Menü kapanınca (`poll()`) bekletilen satır sessizce düşmez (#1240): menü `shortMenuMs`'den
/// kısa sürdüyse bekletilen bütün satırlar, yoksa son `holdMs` içinde gelen en son konuşma satırı (`SilenceWatch.isSpeech`;
/// menü etiketi değil) gönderilir. Eskiden menü sırasında altyazı hiç okunmuyordu: GTA 6'nın karanlık balık tutma
/// sahnesinde tuş ipucu ve görev yazısı birlikte belirip menü sanılınca her seferinde bir iki konuşma satırı kayboluyordu.
/// Geçişler ve bekletilen/gönderilen satırlar altyazı günlüğüne yazılır (`DropLog`). Windows (MenuPausedSender.cs) ve
/// Android (MenuHeldSender.kt) aynı kurallar.
public final class MenuHeldSender: SubtitleSending, @unchecked Sendable {
    /// Menü kapanınca bundan eski bekletilen satır gönderilmez (ekrandan çoktan kalkmıştır).
    public static let holdMs = 5000
    /// Bundan kısa süren menü durumu yanlış algıdır: bekletilen bütün satırlar hemen gönderilir.
    public static let shortMenuMs = 300

    private struct Held {
        let text: String
        let durationMs: Int
        let box: TextBox?
        let replaces: Bool
        let at: Int
    }

    private let inner: SubtitleSending
    private let inMenu: () -> Bool
    private let log: (String) -> Void
    private let now: () -> Int
    private let drops: DropLog
    private let lock = NSLock()
    private var held: [Held] = []
    private var paused = false
    private var pausedAt = 0

    public init(_ inner: SubtitleSending, inMenu: @escaping () -> Bool,
                log: @escaping (String) -> Void = { SubtitleLog.write($0) },
                clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.inner = inner
        self.inMenu = inMenu
        self.log = log
        self.now = clock
        self.drops = DropLog(clock: clock, sink: log)
    }

    /// Menü durumunu yeniden okur; menü kapandıysa bekletilen satırları gönderir. Uygulama her karede çağırır (menü
    /// kapandıktan sonra yeni satır gelmese de bekletilen satır gitsin). Şu an menü var mı döner.
    @discardableResult
    public func poll() -> Bool {
        let (menu, release) = lock.withLock { observe() }
        for line in release { inner.sendSubtitle(line.text, durationMs: line.durationMs, box: line.box, replaces: line.replaces) }
        return menu
    }

    public func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool) {
        let (menu, release) = lock.withLock { () -> (Bool, [Held]) in
            let result = observe()
            if result.0 {
                held.append(Held(text: text, durationMs: durationMs, box: box, replaces: replaces, at: now()))
                drops.note("Menü", "menü sırasında bekletildi", text)
            }
            return result
        }
        for line in release { inner.sendSubtitle(line.text, durationMs: line.durationMs, box: line.box, replaces: line.replaces) }
        if menu { return }
        inner.sendSubtitle(text, durationMs: durationMs, box: box, replaces: replaces)
    }

    public func clear() { inner.clear() }

    /// Görev satırının yeri menüde de bekletilmez.
    public func sendObjective(_ box: TextBox?) { inner.sendObjective(box) }

    /// Altyazı alanında menünün geçmiş listesi okundu (`SubtitlePipeline.onList`): menü sırasında bekletilen satırlar
    /// listenin satırlarıdır (kaydırırken tek satır okunabiliyor), menü kapanınca altyazı olarak gönderilmez.
    public func forget() {
        lock.withLock {
            for line in held { drops.note("Menü", "menü listesinin satırı, gönderilmedi", line.text) }
            held.removeAll()
        }
    }

    private func observe() -> (Bool, [Held]) {
        let menu = inMenu()
        guard menu != paused else { return (menu, []) }
        paused = menu
        let time = now()
        if menu {
            pausedAt = time
            log(ScreenTextDetector.menuLog(true))
            return (true, [])
        }
        let lasted = time - pausedAt
        let release: [Held]
        if lasted < Self.shortMenuMs {
            release = held
        } else {
            release = held.filter { time - $0.at <= Self.holdMs && SilenceWatch.isSpeech($0.text) }.suffix(1).map { $0 }
        }
        for line in held {
            let sent = release.contains { $0.at == line.at && $0.text == line.text }
            drops.note("Menü", sent ? "menü kapanınca gönderildi" : "menü sırasında bekletildi, gönderilmedi", line.text)
        }
        held.removeAll()
        log("\(ScreenTextDetector.menuLog(false)) (\(lasted) ms)")
        return (false, release)
    }
}
