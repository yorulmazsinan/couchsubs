// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Shell;

/// <summary>
/// Altyazı hattının göndericisi: ekranda menü varken (<see cref="ScreenTextDetector.InMenu"/>) altyazı satırları
/// gönderilmez, temizleme geçer. Menüde altyazı alanı da otomatik ekran yazısı olarak okunuyor; menü satırları ayrıca
/// altyazı kutusunda görünmesin.
/// </summary>
public sealed class MenuPausedSender(ISubtitleSender inner, Func<bool> inMenu) : ISubtitleSender
{
    public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false)
    {
        if (inMenu()) return;
        inner.SendSubtitle(text, durationMs, box, paragraphs, replaces);
    }

    public void Clear() => inner.Clear();
}
