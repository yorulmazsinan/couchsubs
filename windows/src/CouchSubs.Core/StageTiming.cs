// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core;

/// <summary>
/// Ek alan turunun ve kare işlerinin aşama süreleri; <see cref="PeriodMs"/>'de bir tek günlük satırı. Altyazı ya da telefon
/// çevirisi geç kalınca hangi işin (okuma, çizim ölçümü, telefon izleme) zaman aldığı günlükte görünsün diye (beta.103:
/// "telefon mesajları yavaş, altyazı gecikiyor"). Mac/iPhone StageTiming.swift ve Android StageTiming.kt aynı biçim.
/// </summary>
public sealed class StageTiming(long periodMs = StageTiming.PeriodMs)
{
    public const long PeriodMs = 30_000;

    private sealed class Stat
    {
        public int Count;
        public long TotalTicks;
        public long MaxTicks;
    }

    private readonly object gate = new();
    private readonly List<string> order = [];
    private readonly Dictionary<string, Stat> stats = [];
    private long? since;

    /// <summary><paramref name="stage"/> bir kez <paramref name="elapsed"/> sürdü.</summary>
    public void Add(string stage, TimeSpan elapsed)
    {
        var ticks = elapsed.Ticks;
        lock (gate)
        {
            if (!stats.TryGetValue(stage, out var stat))
            {
                stat = new Stat();
                stats[stage] = stat;
                order.Add(stage);
            }
            stat.Count++;
            stat.TotalTicks += Math.Max(0, ticks);
            stat.MaxTicks = Math.Max(stat.MaxTicks, ticks);
        }
    }

    /// <summary>
    /// Süre dolduysa (<paramref name="now"/>, ms) satır, sayaçlar sıfırlanır; dolmadıysa ya da ölçüm yoksa null. İlk çağrı
    /// süreyi başlatır.
    /// </summary>
    public string? Report(long now)
    {
        lock (gate)
        {
            if (since is not { } start)
            {
                since = now;
                return null;
            }
            if (now >= start && now - start < periodMs) return null;
            since = now;
            if (order.Count == 0) return null;
            var line = Format(Math.Max(0, now - start),
                [.. order.Select(stage => (stage, stats[stage].Count, stats[stage].TotalTicks, stats[stage].MaxTicks))]);
            order.Clear();
            stats.Clear();
            return line;
        }
    }

    /// <summary>"aşama süreleri (30 sn): okuma 12× ort 85,0 en çok 140,2 ms; çizim 4× ort 30,1 en çok 52,0 ms".</summary>
    internal static string Format(long spanMs, IReadOnlyList<(string Stage, int Count, long TotalTicks, long MaxTicks)> stages)
    {
        // 1 tick = 100 ns; ms'nin onda biri = 1000 tick.
        static string Ms(long ticks)
        {
            var tenths = (ticks + 500) / 1000;
            return $"{tenths / 10},{tenths % 10}";
        }
        return $"aşama süreleri ({spanMs / 1000} sn): " + string.Join("; ", stages.Select(s =>
            $"{s.Stage} {s.Count}× ort {Ms(s.TotalTicks / Math.Max(1, s.Count))} en çok {Ms(s.MaxTicks)} ms"));
    }
}
