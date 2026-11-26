// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;

namespace CouchSubs.Shell;

/// <summary>
/// Xbox oturumlarının kapanış sırası. Yeni oturum önceki oturumun kapanışını (oynatıcı, köprüye "stop" ve DELETE) en çok
/// <see cref="WaitLimit"/> bekler (XboxStreamSession.RunAfterAsync); uygulama kapanırken açık oturum en çok
/// <see cref="ExitLimit"/> içinde kapatılır. Eskiden kapanırken oturum Xbox'ta açık kalıyor, sonraki bağlantı reddediliyor
/// ve Xbox'ı yeniden başlatmak gerekiyordu. Satırlar Android ve iPhone/Mac'teki XboxCloseWait ile aynı.
/// </summary>
public static class XboxCloseWait
{
    public static readonly TimeSpan WaitLimit = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan ExitLimit = TimeSpan.FromSeconds(2);

    /// <summary>"önceki oturumun kapanması beklendi (1 oturum, 0.4 sn)"; süre dolduysa "... bitmedi; yeni oturum yine açılıyor".</summary>
    public static string Line(int sessions, TimeSpan elapsed, bool timedOut)
    {
        var seconds = elapsed.TotalSeconds.ToString("0.0", CultureInfo.InvariantCulture);
        return timedOut
            ? $"önceki oturumun kapanması {seconds} sn'de bitmedi ({sessions} oturum); yeni oturum yine açılıyor"
            : $"önceki oturumun kapanması beklendi ({sessions} oturum, {seconds} sn)";
    }

    /// <summary>Uygulama kapanırken kapatılan oturumlar: "1/1 Xbox oturumu kapatıldı".</summary>
    public static string ExitLine(int sessions, int closed) =>
        closed == sessions ? $"{closed}/{sessions} Xbox oturumu kapatıldı"
            : $"{closed}/{sessions} Xbox oturumu kapatıldı; kapatılamayan oturum Xbox'ta açık kalmış olabilir";
}
