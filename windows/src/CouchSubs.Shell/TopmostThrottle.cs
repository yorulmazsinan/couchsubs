// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Shell;

/// <summary>
/// Altyazı penceresinin her pencerenin üstüne yeniden alınma sıklığı. Başka bir tam ekran ya da "her zaman üstte"
/// pencere (Xbox uygulaması, kenarsız oyun) öne gelince altyazı arkada kalmasın diye pencere çizimde ve ön plan
/// değişince yeniden öne alınır; çizimdeki çağrı en çok <see cref="Interval"/> başına bir kez yapılır.
/// </summary>
public sealed class TopmostThrottle(TimeSpan interval)
{
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromMilliseconds(250);

    private TimeSpan? last;

    public TopmostThrottle() : this(DefaultInterval)
    {
    }

    public TimeSpan Interval { get; } = interval;

    /// <summary>Son öne almadan bu yana yeterince zaman geçtiyse true döner ve anı kaydeder.</summary>
    public bool TryRaise(TimeSpan now)
    {
        // Saat geri gittiyse (olmamalı) bekletmeden öne alınır.
        if (last is { } previous && now >= previous && now - previous < Interval) return false;
        last = now;
        return true;
    }

    /// <summary>Sınırlamadan bağımsız (ön plan değişimi, pencere yeni göründü) öne alma yapıldı; sayaç sıfırdan başlar.</summary>
    public void Raised(TimeSpan now) => last = now;

    /// <summary>
    /// Ön plana gelen pencere bizim sürecimizin değilse altyazı yeniden öne alınır. Kendi pencerelerimiz (ayarlar, serbest
    /// alan seçimi, altyazının kendisi) için alınmaz: hem kendi ön plan olayımızda döngü olmaz hem de seçim penceresinin
    /// üstüne çıkılmaz.
    /// </summary>
    public static bool ShouldRaiseFor(uint foregroundProcessId, uint ownProcessId) =>
        foregroundProcessId != 0 && foregroundProcessId != ownProcessId;
}
