// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.LgTv;

/// <summary>
/// TV uygulamasını açık tutar: TV kendi HDMI ya da yayın girişine geçerse (SimpLink/CEC) uygulamayı
/// yeniden öne getirir. TV kapalıysa ya da bağlantı koparsa bir sonraki kontrolde yeniden bağlanır.
/// <para>
/// Kullanıcı TV'de bilerek başka girişe geçiyorsa zorlanmaz: uygulama <see cref="StandDownAfter"/> kez
/// <see cref="StandDownWindow"/> içinde girişten geri getirildiyse ve TV yine girişteyse bekçi çekilir ("PS kapalıyken HDMI
/// değiştirince TV sürekli CouchSubs'a geri atıyor"). Kullanıcı CouchSubs'ı TV'de kendisi açınca, bağlantı yenilenince
/// ya da çeviri yeniden başlayınca bekçi işine döner. SimpLink/CEC'in bir iki kez girişe geçirmesi sınırın altında kalır.
/// </para>
/// </summary>
/// <param name="appConnected">
/// Verilirse (Samsung) TV'ye yalnız TV uygulaması bilgisayara bağlı değilken ve en çok <paramref name="relaunchInterval"/>'da
/// bir dokunulur: uygulama açılır, bağlantı hemen kapatılır. Samsung önplandaki uygulamayı söylemediği için sürekli açık
/// "uzaktan kumanda" bağlantısı gereksizdi; yeniden kurulan bağlantı TV'de bildirim çıkarıp PS5 kolunu düşürüyordu (#5).
/// </param>
public sealed class TvKeeper(Func<Task<ITvControl>> connect, string appId, IReadOnlyDictionary<string, string> parameters,
                             Func<bool>? appConnected = null, TimeSpan? relaunchInterval = null, Func<DateTime>? clock = null) : IDisposable
{
    /// <summary>Bu kadar zorla geri getirmeden sonra TV yine girişteyse bekçi çekilir.</summary>
    public const int StandDownAfter = 3;
    public static readonly TimeSpan StandDownWindow = TimeSpan.FromSeconds(90);

    private readonly Func<DateTime> now = clock ?? (() => DateTime.UtcNow);
    /// <summary>Uygulamanın girişten geri getirildiği anlar (pencere içindekiler).</summary>
    private readonly List<DateTime> forced = [];
    private bool stoodDown;

    /// <summary>Kullanıcı girişte kalmakta ısrar etti; bekçi uygulamayı öne getirmiyor.</summary>
    public bool StoodDown => stoodDown;

    private readonly SemaphoreSlim tickLock = new(1, 1);
    private ITvControl? control;
    private CancellationTokenSource? loop;
    private DateTime? lastLaunch;

    /// <summary>Kullanıcının bilerek açtığı uygulamalara (Netflix vb.) dokunulmaz; yalnız giriş ve yayın ekranları.</summary>
    public static bool IsInputOrLiveTv(string appId) =>
        appId.StartsWith("com.webos.app.hdmi", StringComparison.Ordinal)
        || appId.StartsWith("com.webos.app.externalinput", StringComparison.Ordinal)
        || appId == "com.webos.app.livetv";

    /// <summary>Bir kontrol. Hata fırlatmaz; bağlantı sorununda bir sonraki kontrolde yeniden dener.</summary>
    public async Task TickAsync()
    {
        await tickLock.WaitAsync();
        try
        {
            if (appConnected is not null)
            {
                await LaunchIfAppIsAwayAsync(appConnected());
                return;
            }
            if (control is null)
            {
                var fresh = await connect();
                control = fresh;
                await fresh.LaunchAsync(appId, parameters);
                return;
            }
            var current = await control.ForegroundAppIdAsync();
            if (current == appId)
            {
                // Uygulama önde. Bekçi çekilmişken öndeyse kullanıcı onu kendisi açmıştır: bekçi işine döner.
                if (stoodDown) { stoodDown = false; forced.Clear(); }
                return;
            }
            if (!IsInputOrLiveTv(current) || stoodDown) return;
            var time = now();
            forced.RemoveAll(at => time - at > StandDownWindow);
            if (forced.Count >= StandDownAfter)
            {
                stoodDown = true;
                return;
            }
            forced.Add(time);
            await control.LaunchAsync(appId, parameters);
        }
        catch
        {
            control?.Dispose();
            control = null;
        }
        finally
        {
            tickLock.Release();
        }
    }

    private async Task LaunchIfAppIsAwayAsync(bool connected)
    {
        if (connected) return;
        if (lastLaunch is { } last && DateTime.UtcNow - last < (relaunchInterval ?? TimeSpan.FromSeconds(30))) return;
        lastLaunch = DateTime.UtcNow;
        try
        {
            using var fresh = await connect();
            await fresh.LaunchAsync(appId, parameters);
        }
        catch (Exception)
        {
            // TV kapalı ya da ulaşılamıyor; bir sonraki denemede yeniden.
        }
    }

    public void Start(TimeSpan? interval = null)
    {
        loop?.Cancel();
        var cancellation = new CancellationTokenSource();
        loop = cancellation;
        var delay = interval ?? TimeSpan.FromSeconds(5);
        _ = Task.Run(async () =>
        {
            while (!cancellation.IsCancellationRequested)
            {
                await TickAsync();
                try { await Task.Delay(delay, cancellation.Token); } catch (OperationCanceledException) { }
            }
        });
    }

    /// <summary>Bilgisayar uykudan uyandığında: bağlantıyı yenile.</summary>
    public void Reconnect()
    {
        control?.Dispose();
        control = null;
        lastLaunch = null;
        stoodDown = false;
        forced.Clear();
    }

    public void Stop()
    {
        loop?.Cancel();
        loop = null;
        control?.Dispose();
        control = null;
    }

    public void Dispose() => Stop();
}
