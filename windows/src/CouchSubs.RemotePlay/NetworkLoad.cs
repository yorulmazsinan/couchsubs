// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.RemotePlay;

/// <summary>
/// PS5 aramasının ağa bindirdiği yük (Mac/iPhone <c>SweepPacing</c>, Android <c>SweepPacing</c> ve yerel kütüphanedeki döngü
/// (couchsubs_native.c) aynı kural).
///
/// #1366: çeviri başlayınca evdeki bütün cihazların Wi-Fi'ı kopuyordu. Ağ taraması bağlı ağların bütün adreslerine (/22'ye
/// kadar ~1000 adres) yarım saniyede bir, 3 sn boyunca aralıksız paket gönderiyordu: her turda birkaç milisaniyede yüzlerce
/// paket ve boştaki her adres için ARP genel yayını. Artık tarama yalnız iki tur gönderir ve paketler arasında 4 ms beklenir
/// (en çok ~250 paket/sn); tek adrese soru eskisi gibi yarım saniyede bir gider.
/// </summary>
public static class SweepPacing
{
    /// <summary>Bu sayıdan çok hedef "ağ taraması"dır.</summary>
    public const int SweepMinTargets = 8;
    /// <summary>Taramada iki paket arası.</summary>
    public const int PaceMs = 4;
    /// <summary>Taramada hedeflerin hepsine kaç tur gönderilir.</summary>
    public const int SweepRounds = 2;
    private const int RoundMs = 500;

    public static bool IsSweep(int targetCount) => targetCount > SweepMinTargets;

    /// <summary><paramref name="round"/> (0'dan) turunda hedeflere paket gider mi.</summary>
    public static bool SendsInRound(int round, int targetCount) => !IsSweep(targetCount) || round < SweepRounds;

    /// <summary>Yerel döngünün süre içinde kaç paket göndereceği (günlükteki sayım için; döngü couchsubs_native.c'de, aynı kural).</summary>
    public static int PlannedPackets(int targetCount, int timeoutMs) => targetCount <= 0 ? 0
        : !IsSweep(targetCount) ? targetCount * Math.Max(1, (timeoutMs + RoundMs - 1) / RoundMs)
        : Math.Min(targetCount * SweepRounds, Math.Max(targetCount, timeoutMs / PaceMs));
}

/// <summary>
/// PS5 aramalarının ve yeniden denemelerin sayacı: dakikada en çok bir satır günlüğe yazılır, böylece kullanıcı günlüğünde ağa
/// ne kadar yük bindiği görünür ("Ağ yükü (son 60 sn): PS5 ağ taraması 1 kez, 508 paket; ..."). İlk olay hemen yazılır,
/// sonrakiler biriktirilip dakikası dolunca tek satırda yazılır. Mac/iPhone ve Android <c>NetworkLoad</c> ile aynı.
/// </summary>
public sealed class NetworkLoad(Action<string> write)
{
    public static readonly NetworkLoad Shared = new(RemotePlayLog.Note);
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(60);

    private readonly object gate = new();
    private int sweeps, sweepPackets, queries, queryPackets, retries;
    private DateTime? windowStart, lastLine;

    /// <summary>Bir PS5 araması bitti: <paramref name="sweep"/> ağ taraması mı, <paramref name="packets"/> kaç paket gitti.</summary>
    public void Discovery(bool sweep, int packets, DateTime? now = null) => Record(now ?? DateTime.UtcNow, () =>
    {
        if (sweep) { sweeps++; sweepPackets += packets; }
        else { queries++; queryPackets += packets; }
    });

    /// <summary>PS5 oturumu yeniden denendi.</summary>
    public void Retry(DateTime? now = null) => Record(now ?? DateTime.UtcNow, () => retries++);

    private void Record(DateTime now, Action change)
    {
        string text;
        lock (gate)
        {
            windowStart ??= now;
            change();
            if (lastLine is { } last && now - last < Interval) return;
            var seconds = Math.Max(0, (long)Math.Round((now - windowStart.Value).TotalSeconds));
            text = Line(seconds, sweeps, sweepPackets, queries, queryPackets, retries);
            sweeps = sweepPackets = queries = queryPackets = retries = 0;
            lastLine = now;
            windowStart = null;
        }
        write(text);
    }

    internal static string Line(long seconds, int sweeps, int sweepPackets, int queries, int queryPackets, int retries) =>
        $"Ağ yükü (son {seconds} sn): PS5 ağ taraması {sweeps} kez, {sweepPackets} paket; tek adres sorgusu {queries} kez, " +
        $"{queryPackets} paket; PS5'e yeniden bağlanma {retries}";
}
