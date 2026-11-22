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
/// <para>
/// PS tuşu (HDMI-CEC "One Touch Play") TV'yi konsolun kendi HDMI girişine geçirir; oyunda PS menüsü her açıldığında olur.
/// TV uygulaması gösterdiği girişi bildirdiyse (<paramref name="consolePort"/>) o girişe geçiş kullanıcı ısrarı sayılmaz,
/// uygulama her seferinde geri getirilir; yalnız bir dakikada <see cref="ConsoleLoopLimit"/> kez olursa (bitmeyen CEC
/// döngüsü) bekçi çekilir. Başka HDMI numarası ve yayın eskisi gibi sayılır, başka uygulamalara (Netflix) dokunulmaz.
/// LG'de önplan <see cref="ForegroundPoll"/>'da bir sorulur: eskiden 5 sn'de bir soruluyordu, PS tuşundan sonra çeviri
/// 5-6 sn ekrandan gidiyordu ve kısa sürede dört PS basışı bekçiyi çekiyordu (X, Kas 2026).
/// </para>
/// </summary>
/// <param name="appConnected">
/// Verilirse (Samsung) TV'ye yalnız TV uygulaması bilgisayara bağlı değilken ve en çok <paramref name="relaunchInterval"/>'da
/// bir dokunulur: uygulama açılır, bağlantı hemen kapatılır. Samsung önplandaki uygulamayı söylemediği için sürekli açık
/// "uzaktan kumanda" bağlantısı gereksizdi; yeniden kurulan bağlantı TV'de bildirim çıkarıp PS5 kolunu düşürüyordu (#5).
/// </param>
/// <param name="consolePort">TV uygulamasının gösterdiği HDMI girişi (1-4; altyazı akışına bağlanırken bildirir), bilinmiyorsa null.</param>
/// <param name="onOpenResult">Her açma denemesinin sonucu: açıldıysa null, TV'ye ulaşılamadıysa ya da açamadıysa
/// <see cref="TvOpenProblem.Unreachable"/> (ana ekrandaki satır).</param>
public sealed class TvKeeper(Func<Task<ITvControl>> connect, string appId, IReadOnlyDictionary<string, string> parameters,
                             Func<bool>? appConnected = null, TimeSpan? relaunchInterval = null, Func<DateTime>? clock = null,
                             Func<int?>? consolePort = null, Action<TvOpenProblem?>? onOpenResult = null) : IDisposable
{
    /// <summary>Bu kadar zorla geri getirmeden sonra TV yine girişteyse bekçi çekilir.</summary>
    public const int StandDownAfter = 3;
    public static readonly TimeSpan StandDownWindow = TimeSpan.FromSeconds(90);
    /// <summary>LG'de önplandaki uygulamanın sorulma aralığı (açık SSAP bağlantısında tek istek; TV'de bir şey göstermez).</summary>
    public static readonly TimeSpan ForegroundPoll = TimeSpan.FromSeconds(1);
    /// <summary>Geri getirdikten sonra bu kadar beklenir: TV uygulamayı öne alırken önplan bir an eski girişi gösterir.</summary>
    public static readonly TimeSpan LaunchSettle = TimeSpan.FromSeconds(2);
    /// <summary>Konsol girişinden bir dakikada bu kadar geri getirmeden sonra bekçi çekilir (bitmeyen CEC döngüsü).</summary>
    public const int ConsoleLoopLimit = 10;
    public static readonly TimeSpan ConsoleLoopWindow = TimeSpan.FromSeconds(60);

    private readonly Func<DateTime> now = clock ?? (() => DateTime.UtcNow);
    /// <summary>Uygulamanın girişten geri getirildiği anlar (pencere içindekiler).</summary>
    private readonly List<DateTime> forced = [];
    /// <summary>Uygulamanın konsol girişinden (PS tuşu) geri getirildiği anlar.</summary>
    private readonly List<DateTime> consoleReturns = [];
    private DateTime? lastForced;
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

    /// <summary>Önplandaki uygulama, TV uygulamasının gösterdiği HDMI girişi mi (LG: <c>com.webos.app.hdmi2</c>).</summary>
    public static bool IsConsoleInput(string appId, int? port) =>
        port is >= 1 and <= 4 && appId == "com.webos.app.hdmi" + port;

    /// <summary>Bir kontrol. Hata fırlatmaz; bağlantı sorununda bir sonraki kontrolde yeniden dener.</summary>
    public async Task TickAsync()
    {
        await tickLock.WaitAsync();
        var opening = control is null;
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
                onOpenResult?.Invoke(null);
                return;
            }
            var time = now();
            if (lastForced is { } last && time - last < LaunchSettle) return;
            var current = await control.ForegroundAppIdAsync();
            if (current == appId)
            {
                // Uygulama önde. Bekçi çekilmişken öndeyse kullanıcı onu kendisi açmıştır: bekçi işine döner.
                if (stoodDown) { stoodDown = false; forced.Clear(); consoleReturns.Clear(); }
                return;
            }
            if (!IsInputOrLiveTv(current) || stoodDown) return;
            if (IsConsoleInput(current, consolePort?.Invoke()))
            {
                // PS tuşu: konsol TV'yi kendi girişine geçirdi. Kullanıcı ısrarı sayılmaz, hemen geri getirilir.
                consoleReturns.RemoveAll(at => time - at > ConsoleLoopWindow);
                if (consoleReturns.Count >= ConsoleLoopLimit)
                {
                    stoodDown = true;
                    return;
                }
                consoleReturns.Add(time);
                lastForced = time;
                await control.LaunchAsync(appId, parameters);
                return;
            }
            forced.RemoveAll(at => time - at > StandDownWindow);
            if (forced.Count >= StandDownAfter)
            {
                stoodDown = true;
                return;
            }
            forced.Add(time);
            lastForced = time;
            await control.LaunchAsync(appId, parameters);
        }
        catch
        {
            // Bağlanıp açma denemesi olmadıysa (TV kapalı, başka ağda, açmayı reddetti) bildirilir; açık bağlantının
            // kopması bir sonraki denemede bildirilir.
            if (opening) onOpenResult?.Invoke(TvOpenProblem.Unreachable);
            control?.Dispose();
            control = null;
        }
        finally
        {
            tickLock.Release();
        }
    }

    /// <summary>
    /// Samsung'da açma komutu gittikten sonra TV uygulamasının bağlanması için beklenen süre; bağlanmazsa ana ekranda "TV
    /// açmadı" yazar. Samsung <c>ed.apps.launch</c>'ın açılışı söyleyen bir yanıtını vermez: bazı TV'ler (Tizen 9.0, #412;
    /// iPhone'da Samsung, 21 Kas) komutu alıp uygulamayı açmıyor, neden satırı boş kalıyordu (Mac/iPhone ile aynı).
    /// </summary>
    public static readonly TimeSpan SamsungOpenCheck = TimeSpan.FromSeconds(15);

    /// <summary>Samsung: son açma komutunun gittiği an (uygulama bağlanınca ya da "TV açmadı" bildirilince sıfırlanır).</summary>
    private DateTime? sentAt;
    private TvOpenProblem? lastReported;

    private async Task LaunchIfAppIsAwayAsync(bool connected)
    {
        var time = now();
        if (connected)
        {
            sentAt = null;
            return;
        }
        if (sentAt is { } sent && time - sent >= SamsungOpenCheck)
        {
            sentAt = null;
            Report(TvOpenProblem.NotOpened);
        }
        if (lastLaunch is { } last && time - last < (relaunchInterval ?? TimeSpan.FromSeconds(30))) return;
        lastLaunch = time;
        try
        {
            using var fresh = await connect();
            await fresh.LaunchAsync(appId, parameters);
            sentAt = now();
            // TV bir önceki komutta da açmadıysa neden satırı yeniden gönderilen komutla silinmez (her 30 sn'de yanıp sönmesin).
            if (lastReported == TvOpenProblem.NotOpened) return;
            Report(null);
        }
        catch (SsapException error) when (error.Reason == SamsungClient.NotInstalledReason)
        {
            // Samsung: TV kurulu olduğunu doğrulamadı, açma komutu gönderilmedi (kurulum gerekiyor; TV yanıt verdi).
            Report(TvOpenProblem.NotInstalled);
        }
        catch (Exception)
        {
            // TV kapalı ya da ulaşılamıyor; bir sonraki denemede yeniden.
            Report(TvOpenProblem.Unreachable);
        }
    }

    private void Report(TvOpenProblem? problem)
    {
        lastReported = problem;
        onOpenResult?.Invoke(problem);
    }

    /// <summary>
    /// <paramref name="interval"/>: kontrol aralığı. LG'de (önplan sorulan bekçi) en çok <see cref="ForegroundPoll"/>;
    /// Samsung'da verilen aralık kullanılır (TV'ye yine en çok <c>relaunchInterval</c>'da bir dokunulur).
    /// </summary>
    public void Start(TimeSpan? interval = null)
    {
        loop?.Cancel();
        var cancellation = new CancellationTokenSource();
        loop = cancellation;
        var delay = PollInterval(interval ?? TimeSpan.FromSeconds(5));
        _ = Task.Run(async () =>
        {
            while (!cancellation.IsCancellationRequested)
            {
                await TickAsync();
                try { await Task.Delay(delay, cancellation.Token); } catch (OperationCanceledException) { }
            }
        });
    }

    /// <summary>Kontrol aralığı: LG'de PS tuşundan sonra en geç ~2 sn'de geri gelinsin diye en çok <see cref="ForegroundPoll"/>.</summary>
    public TimeSpan PollInterval(TimeSpan requested) =>
        appConnected is null && requested > ForegroundPoll ? ForegroundPoll : requested;

    /// <summary>Bilgisayar uykudan uyandığında: bağlantıyı yenile.</summary>
    public void Reconnect()
    {
        control?.Dispose();
        control = null;
        lastLaunch = null;
        sentAt = null;
        lastReported = null;
        stoodDown = false;
        forced.Clear();
        consoleReturns.Clear();
        lastForced = null;
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
