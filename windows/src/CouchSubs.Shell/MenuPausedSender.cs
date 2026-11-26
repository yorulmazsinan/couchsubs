// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Shell;

/// <summary>
/// Altyazı hattının göndericisi: ekranda menü varken (<see cref="ScreenTextDetector.InMenu"/>) altyazı satırları hemen
/// gönderilmez, bekletilir; temizleme geçer. Menüde altyazı alanı da otomatik ekran yazısı olarak okunuyor; menü satırları
/// ayrıca altyazı kutusunda görünmesin. Menü kapanınca (<see cref="Poll"/>) bekletilen satır sessizce düşmez (#1240):
/// menü <see cref="ShortMenuMs"/>'den kısa sürdüyse bekletilen bütün satırlar, yoksa son <see cref="HoldMs"/> içinde gelen
/// en son konuşma satırı (<see cref="SilenceWatch.IsSpeech"/>; menü etiketi değil) gönderilir. Eskiden menü sırasında
/// gelen satır hiç gönderilmiyordu: GTA 6'nın karanlık balık tutma sahnesinde tuş ipucu ve görev yazısı birlikte belirip
/// menü sanılınca her seferinde bir iki konuşma satırı kayboluyordu. Geçişler ve bekletilen/gönderilen satırlar altyazı
/// günlüğüne yazılır (<paramref name="log"/>, <see cref="DropLog"/>). Mac/iPhone (MenuHeldSender.swift) ve Android
/// (MenuHeldSender.kt) aynı kurallar.
/// </summary>
public sealed class MenuPausedSender(ISubtitleSender inner, Func<bool> inMenu, Action<string>? log = null, Func<long>? clock = null) : ISubtitleSender
{
    /// <summary>Menü kapanınca bundan eski bekletilen satır gönderilmez (ekrandan çoktan kalkmıştır).</summary>
    public const long HoldMs = 5000;
    /// <summary>Bundan kısa süren menü durumu yanlış algıdır: bekletilen bütün satırlar hemen gönderilir.</summary>
    public const long ShortMenuMs = 300;

    private sealed record Held(string Text, int DurationMs, TextBox? Box, bool Paragraphs, bool Replaces, long At);

    private readonly object gate = new();
    private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
    private readonly DropLog drops = new(clock, log);
    private readonly List<Held> held = [];
    private bool paused;
    private long pausedAt;

    /// <summary>
    /// Menü durumunu yeniden okur; menü kapandıysa bekletilen satırları gönderir. Okuma hattı her karede çağırır (menü
    /// kapandıktan sonra yeni satır gelmese de bekletilen satır gitsin). Şu an menü var mı döner.
    /// </summary>
    public bool Poll()
    {
        List<Held> release;
        bool menu;
        lock (gate) (menu, release) = Observe();
        foreach (var line in release) inner.SendSubtitle(line.Text, line.DurationMs, line.Box, line.Paragraphs, line.Replaces);
        return menu;
    }

    public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false)
    {
        List<Held> release;
        bool menu;
        lock (gate)
        {
            (menu, release) = Observe();
            if (menu)
            {
                held.Add(new Held(text, durationMs, box, paragraphs, replaces, now()));
                drops.Note("Menü", "menü sırasında bekletildi", text);
            }
        }
        foreach (var line in release) inner.SendSubtitle(line.Text, line.DurationMs, line.Box, line.Paragraphs, line.Replaces);
        if (!menu) inner.SendSubtitle(text, durationMs, box, paragraphs, replaces);
    }

    public void Clear() => inner.Clear();

    /// <summary>Görev satırının yeri menüde de bekletilmez.</summary>
    public void SendObjective(TextBox? box) => inner.SendObjective(box);

    /// <summary>
    /// Altyazı alanında menünün geçmiş listesi okundu (SubtitlePipeline.ListRead): menü sırasında bekletilen satırlar
    /// listenin satırlarıdır (kaydırırken tek satır okunabiliyor), menü kapanınca altyazı olarak gönderilmez.
    /// </summary>
    public void Forget()
    {
        lock (gate)
        {
            foreach (var line in held) drops.Note("Menü", "menü listesinin satırı, gönderilmedi", line.Text);
            held.Clear();
        }
    }

    private (bool Menu, List<Held> Release) Observe()
    {
        var menu = inMenu();
        if (menu == paused) return (menu, []);
        paused = menu;
        var time = now();
        if (menu)
        {
            pausedAt = time;
            log?.Invoke("ekran menüsü açık: altyazı bekletiliyor");
            return (true, []);
        }
        var lasted = time - pausedAt;
        List<Held> release = lasted < ShortMenuMs
            ? [.. held]
            : [.. held.Where(line => time - line.At <= HoldMs && SilenceWatch.IsSpeech(line.Text)).TakeLast(1)];
        foreach (var line in held)
            drops.Note("Menü", release.Contains(line) ? "menü kapanınca gönderildi" : "menü sırasında bekletildi, gönderilmedi", line.Text);
        held.Clear();
        log?.Invoke($"ekran menüsü kapandı: altyazı gösteriliyor ({lasted} ms)");
        return (false, release);
    }
}
