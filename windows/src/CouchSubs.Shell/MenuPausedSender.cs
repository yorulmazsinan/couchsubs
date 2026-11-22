// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Shell;

/// <summary>
/// Altyazı hattının göndericisi: ekranda menü varken (<see cref="ScreenTextDetector.InMenu"/>) altyazı satırları
/// gönderilmez, temizleme geçer. Menüde altyazı alanı da otomatik ekran yazısı olarak okunuyor; menü satırları ayrıca
/// altyazı kutusunda görünmesin. Menü yüzünden gönderilmeyen ilk satırda ve menü kalkınca altyazı günlüğüne yazılır
/// (<paramref name="log"/>): menü durumu takılı kalınca altyazının neden hiç görünmediği günlükten anlaşılsın (Mac ve
/// iPhone da menü durumunu yazar).
/// </summary>
public sealed class MenuPausedSender(ISubtitleSender inner, Func<bool> inMenu, Action<string>? log = null) : ISubtitleSender
{
    private bool paused;

    public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false)
    {
        var menu = inMenu();
        if (menu != paused)
        {
            paused = menu;
            log?.Invoke(menu ? "ekran menüsü açık: altyazı gösterilmiyor" : "ekran menüsü kapandı: altyazı gösteriliyor");
        }
        if (menu) return;
        inner.SendSubtitle(text, durationMs, box, paragraphs, replaces);
    }

    public void Clear() => inner.Clear();
}
