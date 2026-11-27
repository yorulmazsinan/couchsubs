// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// CouchSubs ile bilgisayardaki resmi PS Remote Play (ya da chiaki-ng) yan yana: günlük satırları. Üç kullanıcı "CouchSubs
/// açıkken PS Remote Play kendiliğinden kapanıyor" dedi; günlük yoktu. Remote Play penceresi modunda CouchSubs PS5'e
/// bağlanmaz, uygulamayı kapatmaz, tuş göndermez, öne getirmez; yalnız penceresini okur. Pencere kaybolunca uygulamanın
/// kapanıp kapanmadığı yazılır (Windows'ta çıkış kodu da; Mac'te bilinmez). PS5 modunda (CouchSubs'ın kendi bağlantısı) aynı
/// bilgisayarda resmi uygulama da açıksa iki bağlantı PS5'te çakışır; bu da yazılır. Metinler Windows'taki
/// `RemotePlayCoexistence` ile aynı (ortak deneme dosyası Fixtures/remote-play-coexistence.json).
public enum RemotePlayCoexistence {
    /// Remote Play penceresi modunda çeviri başlarken.
    public static func windowModeLine(app: String) -> String {
        "Remote Play penceresi modu: CouchSubs PS5'e kendi bağlantısını açmaz, \(app) uygulamasını kapatmaz, ona tuş göndermez, "
            + "öne getirmez; yalnız penceresini okur"
    }

    /// Okunan Remote Play penceresi kayboldu. `exited`: uygulamanın süreci kapandı mı (nil: bilinmiyor); `exitCode`:
    /// çıkış kodu (Windows'ta; Mac'te bilinmez, nil).
    public static func windowGoneLine(app: String, pid: Int, why: String, exited: Bool?, exitCode: Int64?) -> String {
        let state: String
        switch (exited, exitCode) {
        case (nil, _): state = "süreç durumu bilinmiyor"
        case (false?, _): state = "hâlâ açık (pencere kapandı, gizlendi ya da yeniden açılıyor)"
        case (true?, nil): state = "kapandı (çıkış kodu bilinmiyor)"
        case (true?, 0?): state = "kapandı, çıkış kodu 0 (uygulama kendisi kapandı ya da kullanıcı kapattı)"
        case (true?, let code?) where code >= 0xC000_0000:
            let hex = String(code, radix: 16, uppercase: true)
            state = "kapandı, çıkış kodu 0x\(String(repeating: "0", count: max(0, 8 - hex.count)))\(hex) (uygulama çöktü)"
        case (true?, let code?): state = "kapandı, çıkış kodu \(code)"
        }
        return "Remote Play penceresi kayboldu (\(why)): \(app) (pid \(pid)) \(state); CouchSubs bu uygulamayı kapatmadı"
    }

    /// PS5 modunda (CouchSubs'ın kendi PS5 bağlantısı) bu bilgisayarda `app` da açık. `reason` nil: çeviri başlarken;
    /// değilse PS5 oturumumuz bu nedenle bitti.
    public static func consoleConflictLine(app: String, reason: String?) -> String {
        (reason.map { "PS5 oturumu bitti (\($0)) ve \(app) bu bilgisayarda açık" }
            ?? "Uyarı: \(app) bu bilgisayarda açık ve CouchSubs PS5'e kendi bağlantısını açıyor")
            + ". PS5 aynı anda tek Uzaktan Oynatma bağlantısı kabul eder; iki bağlantı birbirini düşürebilir. CouchSubs "
            + "\(app) uygulamasını kapatmaz. İkisi birlikte kullanılacaksa görüntü kaynağı \"Remote Play penceresi\" seçilmeli"
    }
}
