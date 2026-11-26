// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Altyazı kapısının eleme sayacı: okunan bir satır altyazı sayılmayınca (sahne yazısı, menü/mağaza satırı, menü açıklaması,
/// telefon, sabit blok) nedeni sayılır. Kullanıcı bildirimi (beta.103, iki kullanıcı, GTA 6: "bazı altyazıları kaçırıyor,
/// öncesinde iyiydi"): günlükte hangi kuralın hangi satırı ne sıklıkla attığı görünmüyordu. Her neden satırı sonuna o nedenin
/// bu oturumdaki sayısını taşır ("[bu nedenle 12. kez]"); dakikada en çok <see cref="PerMinute"/> satır yazılır, aşan
/// satırlar sayılır. <see cref="WindowMs"/> dolunca sonraki elemede son dakikanın neden başına sayısı tek özet satırı olarak
/// yazılır. Yalnız metin yazılır. Mac/iPhone (RejectTally.swift) ve Android (RejectTally.kt) aynı biçim, aynı sınırlar.
/// </summary>
public sealed class RejectTally
{
    /// <summary>Özet aralığı (ms).</summary>
    public const long WindowMs = 60_000;
    /// <summary>Bir dakikada en çok yazılan neden satırı.</summary>
    public const int PerMinute = 20;

    private readonly object gate = new();
    private readonly Dictionary<string, int> total = [];
    private readonly Dictionary<string, int> window = [];
    private long? windowStart;
    private int written;
    private int suppressed;

    /// <summary>
    /// Elemeyi sayar. <paramref name="line"/>: bu eleme için yazılacak satır (tekrarı yazılmayacaksa null). Dönen satırlar
    /// sırayla günlüğe yazılır: varsa önce son dakikanın özeti, sonra sayaçlı neden satırı.
    /// </summary>
    public List<string> Note(string reason, string? line, long now)
    {
        lock (gate)
        {
            var output = new List<string>();
            if (windowStart is { } start && now - start >= WindowMs)
            {
                if (SummaryLine() is { } summary) output.Add(summary);
                window.Clear();
                written = 0;
                suppressed = 0;
                windowStart = now;
            }
            else if (windowStart is null)
            {
                windowStart = now;
            }
            total[reason] = total.GetValueOrDefault(reason) + 1;
            window[reason] = window.GetValueOrDefault(reason) + 1;
            if (line is not null)
            {
                if (written < PerMinute)
                {
                    written++;
                    output.Add($"{line} [bu nedenle {total[reason]}. kez]");
                }
                else
                {
                    suppressed++;
                }
            }
            return output;
        }
    }

    /// <summary>Bu oturumda <paramref name="reason"/> ile atılan satır sayısı.</summary>
    public int Count(string reason)
    {
        lock (gate) return total.GetValueOrDefault(reason);
    }

    public void Reset()
    {
        lock (gate)
        {
            total.Clear();
            window.Clear();
            windowStart = null;
            written = 0;
            suppressed = 0;
        }
    }

    private string? SummaryLine()
    {
        if (window.Count == 0) return null;
        var parts = window.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{pair.Key} ×{pair.Value}");
        var line = $"altyazı elemesi (son {WindowMs / 1000} sn): " + string.Join("; ", parts);
        if (suppressed > 0) line += $"; sınır yüzünden yazılmayan {suppressed} satır";
        return line;
    }
}
