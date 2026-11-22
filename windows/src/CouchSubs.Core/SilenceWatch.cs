// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Sessizlik bekçisi: altyazı alanında konuşmaya benzeyen satır (<see cref="IsSpeech"/>) <see cref="SilenceMs"/> boyunca
/// okunup hiçbir çeviri gönderilmediyse o satır süzgeçler atlanarak doğrudan çevrilir. En çok <see cref="SilenceMs"/>'de
/// bir satır gönderir; aynı satırı bir kez. İlke: fazladan bir HUD çevirisi kabul, diyaloğun kaybolması kabul değil
/// (Mac/iPhone SilenceWatch.swift, Android SilenceWatch.kt ile aynı kurallar).
/// </summary>
public sealed class SilenceWatch
{
    public const int SilenceMs = 10_000;
    /// <summary>Konuşma sayılmak için en az bu kadar sözcük.</summary>
    internal const int MinWords = 3;
    /// <summary>Rakam taşıyan satır ancak bu kadar sözcükle konuşma sayılır (sayaç, para, saat gibi HUD yazıları geçmesin).</summary>
    internal const int DigitWords = 5;

    private long? since;
    private long? lastFired;
    private readonly HashSet<string> done = [];

    /// <summary>Hat bir çeviri gönderdi: sessizlik bitti.</summary>
    public void Sent() => since = null;

    /// <summary>Okunan satırlardan çevrilmesi gereken (süre dolduysa); yoksa null.</summary>
    public string? Due(IEnumerable<string> lines, long time)
    {
        var candidate = lines.Where(line => IsSpeech(line) && !done.Contains(TextMatch.Normalize(line)))
            .OrderByDescending(line => line.Length).FirstOrDefault();
        if (candidate is null)
        {
            since = null;
            return null;
        }
        if (since is not { } start)
        {
            since = time;
            return null;
        }
        if (time - start < SilenceMs || (lastFired is { } fired && time - fired < SilenceMs)) return null;
        return candidate;
    }

    /// <summary>Satır gönderildi; aynı satır yeniden gönderilmez, bekçi yeniden <see cref="SilenceMs"/> bekler.</summary>
    public void Fired(string text, long time)
    {
        done.Add(TextMatch.Normalize(text));
        lastFired = time;
        since = time;
    }

    /// <summary>
    /// Konuşmaya benzeyen satır: en az üç sözcük, küçük harf içerir ve cümle sonu noktalamasıyla biter ya da konuşan adıyla
    /// başlar. Tek sözcük, BÜYÜK HARF etiket ve rakamlı kısa HUD yazısı geçmez.
    /// </summary>
    public static bool IsSpeech(string raw)
    {
        var text = raw.Trim();
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        if (words < MinWords || !text.Any(char.IsLower)) return false;
        if (text.Any(char.IsDigit) && words < DigitWords) return false;
        return SubtitleStabilizer.EndsSentence(text) || SpeakerPrefix.Parse(text) is not null;
    }
}
