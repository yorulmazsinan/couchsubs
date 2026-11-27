// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>
/// CouchSubs ile bilgisayardaki resmi PS Remote Play (ya da chiaki-ng) yan yana: günlük satırları. Üç kullanıcı
/// "CouchSubs açıkken PS Remote Play kendiliğinden kapanıyor" dedi; günlük yoktu. Remote Play penceresi modunda CouchSubs
/// PS5'e bağlanmaz, uygulamayı kapatmaz, tuş göndermez, öne getirmez; yalnız penceresini okur. Pencere kaybolunca
/// uygulamanın kapanıp kapanmadığı ve (Windows'ta) çıkış kodu yazılır: kendisi mi kapandı, çöktü mü, günlükten görünsün.
/// PS5 modunda (CouchSubs'ın kendi bağlantısı) aynı bilgisayarda resmi uygulama da açıksa iki bağlantı PS5'te çakışır;
/// bu da yazılır. Metinler Mac'teki <c>RemotePlayCoexistence</c> ile aynı (ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/remote-play-coexistence.json).
/// </summary>
public static class RemotePlayCoexistence
{
    /// <summary>Remote Play penceresi modunda çeviri başlarken.</summary>
    public static string WindowModeLine(string app) =>
        $"Remote Play penceresi modu: CouchSubs PS5'e kendi bağlantısını açmaz, {app} uygulamasını kapatmaz, ona tuş göndermez, "
        + "öne getirmez; yalnız penceresini okur";

    /// <summary>
    /// Okunan Remote Play penceresi kayboldu. <paramref name="exited"/>: uygulamanın süreci kapandı mı (null: bilinmiyor);
    /// <paramref name="exitCode"/>: çıkış kodu (Windows; Mac'te bilinmez, null).
    /// </summary>
    public static string WindowGoneLine(string app, int pid, string why, bool? exited, long? exitCode)
    {
        var state = exited switch
        {
            null => "süreç durumu bilinmiyor",
            false => "hâlâ açık (pencere kapandı, gizlendi ya da yeniden açılıyor)",
            true => exitCode switch
            {
                null => "kapandı (çıkış kodu bilinmiyor)",
                0 => "kapandı, çıkış kodu 0 (uygulama kendisi kapandı ya da kullanıcı kapattı)",
                >= 0xC0000000L => $"kapandı, çıkış kodu 0x{exitCode.Value:X8} (uygulama çöktü)",
                _ => $"kapandı, çıkış kodu {exitCode.Value}",
            },
        };
        return $"Remote Play penceresi kayboldu ({why}): {app} (pid {pid}) {state}; CouchSubs bu uygulamayı kapatmadı";
    }

    /// <summary>
    /// PS5 modunda (CouchSubs'ın kendi PS5 bağlantısı) bu bilgisayarda <paramref name="app"/> da açık. <paramref name="reason"/>
    /// null: çeviri başlarken; değilse PS5 oturumumuz bu nedenle bitti.
    /// </summary>
    public static string ConsoleConflictLine(string app, string? reason) =>
        (reason is null
            ? $"Uyarı: {app} bu bilgisayarda açık ve CouchSubs PS5'e kendi bağlantısını açıyor"
            : $"PS5 oturumu bitti ({reason}) ve {app} bu bilgisayarda açık")
        + ". PS5 aynı anda tek Uzaktan Oynatma bağlantısı kabul eder; iki bağlantı birbirini düşürebilir. CouchSubs "
        + $"{app} uygulamasını kapatmaz. İkisi birlikte kullanılacaksa görüntü kaynağı \"Remote Play penceresi\" seçilmeli";
}
