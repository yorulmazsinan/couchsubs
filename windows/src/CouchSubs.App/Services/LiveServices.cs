// SPDX-License-Identifier: AGPL-3.0-only

using System.IO;
using System.Net.Http;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;
using CouchSubs.Translation;
using CouchSubs.TvInstall.Android;
using CouchSubs.TvInstall.Samsung;

namespace CouchSubs.App.Services;

/// <summary>Uygulama denetleyicisinin gerçek dünya bağlantıları (PS5, PSN, TV, OCR, çeviri).</summary>
public sealed class LiveServices : IAppServices
{
    public IXboxService? Xbox { get; } = new XboxService();
    public ITranslationModel Translation { get; } = new MarianModel();

    // DeepL yalnız İngilizce→Türkçe için açılır; önceki oturumların çevirileri kotadan yemeden yeniden kullanılır.
    public ITextTranslator? MakeOnlineTranslator(string key, ITextTranslator? fallback) =>
        new DeepLTranslator(key, fallback, cache: TranslationCache.Shared(AppPaths.Translations, DeepLTranslator.EngineId, "en", "tr"));

    public Task<OnlineKeyCheck> CheckOnlineKeyAsync(string key) => DeepLTranslator.CheckAsync(key);

    // Her model kendi önbelleğini kullanır ("gemini:gemini-3.5-flash-lite"); model değişince eski çeviriler karışmaz.
    // Ek talimat aynı önbellekte kalır; anahtar talimatın etiketiyle ayrılır (bkz. AiTranslator.CacheKey).
    public ITextTranslator? MakeAiTranslator(AiProvider provider, string key, string model, ITextTranslator? fallback, Func<string?>? game,
                                             string? instruction = null, bool paidTier = false) =>
        new AiTranslator(provider, key, model, fallback, cache: TranslationCache.Shared(AppPaths.Translations, provider.EngineId(model), "en", "tr"),
                         game: game, instruction: instruction, paidTier: paidTier);

    public Task<AiTestResult> TestAiKeyAsync(AiProvider provider, string key, string model) => AiTranslator.TestAsync(provider, key, model);

    // Yerel model: önbellekte sunucu ve model ayrı tutulur ("local:localhost:11434/qwen2.5:7b").
    public ITextTranslator? MakeLocalAiTranslator(LocalAiServer server, string key, ITextTranslator? fallback, Func<string?>? game,
                                                  string? instruction = null) =>
        new AiTranslator(AiProvider.Local, key, server.Model, fallback, cache: TranslationCache.Shared(AppPaths.Translations, server.EngineId, "en", "tr"),
                         server: server, game: game, instruction: instruction);

    public Task<AiTestResult> TestLocalAiAsync(LocalAiServer server, string key) =>
        AiTranslator.TestAsync(AiProvider.Local, key, server.Model, server: server);
    public IDubbingModel? Dubbing { get; } = PocketDubbingModel.EngineBundled ? new PocketDubbingModel() : null;
    private readonly AdvancedOcrModel advancedOcr = new();
    public IOcrModel? AdvancedOcr => advancedOcr;
    public IDubbingModel? FastDubbing { get; } = WindowsVoiceModel.Available ? new WindowsVoiceModel() : null;
    public IAudioOutput? Audio { get; } = new WindowsAudioOutput();
    public IUpdater? Updater { get; } = new Updater();
    public IFirewall? Firewall { get; } = new WindowsFirewall();
    // Oyun paketleri: uygulamaya gömülü olanlar ve %LOCALAPPDATA%\CouchSubs\packs klasöründekiler.
    public GamePackLibrary? GamePacks { get; } = new(GamePackLibrary.EmbeddedPacks, GamePackLibrary.UserDirectory);
    public PackMatch? FindInPacks(string text) => GamePacks is { } packs ? PackLookup.Match(packs, text) : null;
    public PackPartial? FindPartialInPacks(string text) => GamePacks is { } packs ? PackLookup.MatchPartial(packs, text) : null;
    public LinePool? Pool { get; } = new(Path.Combine(AppPaths.Data, "pool.json"),
        AppVersion.Current(System.Reflection.Assembly.GetEntryAssembly() ?? typeof(LiveServices).Assembly));
    public string? HistoryFile { get; } = Path.Combine(AppPaths.Data, "history.json");
    // Kullanım verisi: ölçüm kimliği ve API sırrı derlemeden (CouchSubsGaMeasurementId, CouchSubsGaApiSecret); yoksa kapalı.
    public UsageStats? Usage { get; } = UsageStats.Config.FromBuild() is { } usage
        ? new UsageStats(usage, Path.Combine(AppPaths.Data, "usage-id"),
            AppVersion.Current(System.Reflection.Assembly.GetEntryAssembly() ?? typeof(LiveServices).Assembly),
            "Windows " + Environment.OSVersion.Version)
        : null;
    public Task<RunningGame?> RunningGameAsync(ConsoleFinder finder) => ConsoleDiscovery.RunningGameAsync(finder);
    // Paket sunucusu ve uygulama sırrı yapılandırıldıysa (COUCHSUBS_PACKS_URL ya da derlemedeki CouchSubsPacksUrl;
    // CouchSubsPacksSecret) indirilen paketler kullanıcının paket klasörüne gider. Adres ya da sır yoksa (yerel geliştirici
    // derlemesi; sunucu imzasız isteği reddeder) kapalı.
    public PackUpdater? PackUpdates { get; } = PackUpdater.ConfiguredBaseUrl() is { } url && PackSigning.ConfiguredSecret() is { } secret
        ? new PackUpdater(url, GamePackLibrary.UserDirectory, Path.Combine(AppPaths.Data, "packs-remote.json"),
            fallbackUrls: PackUpdater.ConfiguredFallbackUrl() is { } fallback ? [fallback] : null, secret: secret)
        : null;

    public async Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync()
    {
        var found = await ConsoleDiscovery.DiscoverAsync();
        // Eşleştirme olmazsa remoteplay.log'da PS5'in bulunup bulunmadığı da görünsün.
        RemotePlayLog.Note("PS5 araması: " + (found.Count == 0 ? "bulunamadı"
            : string.Join(", ", found.Select(c => $"{c.Name} {c.Host}{(c.IsAwake ? "" : " (dinlenmede)")}"))));
        return found;
    }

    public Task<byte[]> AccountIdFromRedirectAsync(Uri redirect) => PsnAccount.AccountIdFromRedirectAsync(redirect);

    public Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin) => Registration.RegisterAsync(host, accountId, pin);

    public async Task<IReadOnlyList<LgTv>> DiscoverTvsAsync()
    {
        var lg = LgDiscovery.SearchAsync();
        var samsung = SamsungDiscovery.SearchAsync();
        return [.. await lg, .. await samsung];
    }

    public async Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server, string accessKey)
    {
        // Bilgisayar Android TV'yi denetlemez; TV uygulaması bilgisayarı kendisi bulur.
        if (tv.Brand == TvBrand.AndroidTv) return new TvPairing("", true);
        if (tv.Brand == TvBrand.Samsung)
        {
            SamsungAppKnowledge.InstallLog = new TvInstall.InstallLog(TvInstallLogPath).Write;
            using var samsung = new SamsungClient(tv, key);
            string token;
            try { token = await samsung.ConnectAsync(); }
            catch (Exception error) when (error is not SsapException { Reason: "rejected" })
            {
                if (await SamsungDiscovery.DeveloperInfoAsync(tv.Host) is null) throw;
                // TV uzaktan kumanda iznini sormadı ya da izin 60 saniyede gelmedi (The Frame'de Sanat Modu, izin kutusu
                // kapalı TV'ler); TV ağda yanıt veriyor. Eşleşme durmaz: TV uygulaması geliştirici bağlantısıyla (sdb)
                // kurulup açılır. Önceden "Bağlan" bir dakika bekleyip başa dönüyor, kurulum adımına hiç geçilmiyordu.
                new TvInstall.InstallLog(TvInstallLogPath).Write(
                    $"Samsung uzaktan kumanda izni alınamadı ({error.GetType().Name}: {error.Message}); TV 8001'de yanıt verdi, eşleşme izinsiz sürdü.");
                return new TvPairing(key ?? "", true);
            }
            try { await samsung.LaunchAsync(SamsungClient.AppId, new Dictionary<string, string> { ["server"] = server, ["key"] = accessKey }); }
            // TV uygulamanın kurulu olduğunu doğrulamadıysa (listede yok ya da liste 3 sn'de gelmedi) açma komutu gitmez:
            // kurulum adımları görünür (Smart Hub mağaza aramasına gidip "AS400" demesin; Mac ve iPhone ile aynı).
            catch (SsapException error) when (error.Reason == SamsungClient.NotInstalledReason) { return new TvPairing(token, false); }
            catch (Exception) { /* TV uygulaması bilgisayarı kendisi de bulabilir */ }
            return new TvPairing(token, true);
        }
        using var client = new SsapClient(tv, key);
        var newKey = await client.ConnectAsync();
        try
        {
            await client.LaunchAsync(AppController.TvAppId, new Dictionary<string, string> { ["server"] = server, ["key"] = accessKey });
            return new TvPairing(newKey, true);
        }
        catch (Exception)
        {
            return new TvPairing(newKey, false);
        }
    }

    public IStreamSession MakeStream(RegisteredConsole console, byte[] accountId, string? loginPasscode) =>
        new StreamSession(console, accountId, loginPasscode);

    public IStreamSession MakeWindowStream(RemotePlayApp app) => new RemotePlayWindowStream(app);
    public IStreamSession MakeDemoStream() => new DemoStream(DemoFrameRenderer.Render);
    public IStreamSession MakeCaptureWindowStream(WindowCaptureTarget target) => new RemotePlayWindowStream(target);
    public IReadOnlyList<WindowCaptureTarget> CaptureWindows() => RemotePlayWindowStream.ListCaptureWindows();
    public bool RemotePlayInstalled(RemotePlayApp app) => RemotePlayWindowStream.IsInstalled(app);
    public string? RunningRemotePlayApp() => RemotePlayWindowStream.RunningApp();

    public IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved,
                              Action<string> onKey, Func<int?>? consolePort = null,
                              Action<TvOpenProblem?>? onOpenResult = null)
    {
        if (tv.Brand == TvBrand.AndroidTv)
        {
            // Android TV: ADB açıksa (uygulama bu bilgisayardan kurulduysa) CouchSubs TV bilgisayarın adresiyle açılır ve
            // bağlanana kadar arada bir yeniden açılır (iPhone ve Android telefonla aynı). Eskiden bilgisayar Android TV'ye
            // hiç dokunmuyordu. TV yine ekrandaki kodun onayıyla (/pair) eşleşir; erişim anahtarı gitmez.
            var launch = parameters.TryGetValue("server", out var address)
                ? JsonSerializer.Serialize(new Dictionary<string, string> { ["server"] = address }) : null;
            Action<string> installLog = new TvInstall.InstallLog(TvInstallLogPath).Write;
            // TV'ye ulaşılamazsa ağda yeniden aranır (LG ve Samsung'daki TvLocator gibi; Mac ve iPhone ile aynı).
            var androidLocator = new AndroidTvLocator(tv, onMoved, log: installLog);
            // Uygulama çalışıyor ama 10 sn'de bağlanmazsa bir kez kapatılıp (am force-stop) temiz açılır (Samsung'daki #1248 ile
            // aynı; AndroidTvLauncher). ADB işlemleri TV başına sıradadır: kurulum sürerken açma denemesi bekler (#1223).
            return new AndroidKeeper(new AndroidTvKeeper(() => new AndroidTvLauncher(restart => AndroidTvInstaller.OpenAsync(androidLocator.Host,
                    DataDirectory("adb"), launch, restart, log: installLog), appConnected, log: installLog).OpenAsync(),
                appConnected, AndroidOpenProblem, onOpenResult, installLog, locator: androidLocator));
        }
        if (tv.Brand == TvBrand.Samsung)
        {
            SamsungAppKnowledge.InstallLog = new TvInstall.InstallLog(TvInstallLogPath).Write;
            var token = new SamsungTokenHolder(key, onKey);
            var samsungLocator = new TvLocator(tv, async target =>
            {
                // Adresi değişen TV'de kurulu olduğu bilgisi yeni adrese de geçer (yoksa bekçi listeye bakıp açmayabilir).
                SamsungAppKnowledge.Carry(tv.Host, target.Host);
                var client = new SamsungClient(target, token.Current);
                try
                {
                    token.Received(await client.ConnectAsync());
                    return client;
                }
                catch
                {
                    client.Dispose();
                    throw;
                }
            }, () => SamsungDiscovery.SearchAsync(), onMoved, log: new TvInstall.InstallLog(TvInstallLogPath).Write);
            // Önce geliştirici bağlantısı (sdb) denenir; uzaktan kumanda bağlantısıyla açma bazı TV'lerde sessizce çalışmıyordu.
            // "resumed" (uygulama çalışıyor ama bağlı değil) 8002'ye düşmez; bağlanmazsa sdb ile kapatılıp açılır (#1248).
            var host = tv.Host;
            return new Keeper(new TvKeeper(() => Task.FromResult<ITvControl>(new SamsungLauncher(restart => OpenSamsungAppAsync(host, restart),
                    appConnected, samsungLocator.ConnectAsync)),
                SamsungClient.AppId, parameters, appConnected, onOpenResult: onOpenResult));
        }
        var locator = new TvLocator(tv, async target =>
        {
            var client = new SsapClient(target, key);
            try
            {
                await client.ConnectAsync();
                return client;
            }
            catch
            {
                client.Dispose();
                throw;
            }
        }, () => LgDiscovery.SearchAsync(), onMoved, log: new TvInstall.InstallLog(TvInstallLogPath).Write);
        // Açık ve bağlı TV uygulamasına yeni bağlantıda açma komutu gitmez (#1055; Mac, iPhone ve Android ile aynı).
        return new Keeper(new TvKeeper(locator.ConnectAsync, AppController.TvAppId, parameters, consolePort: consolePort, onOpenResult: onOpenResult,
                                       tvConnected: appConnected));
    }

    /// <summary>Android TV'de açılamamanın nedeni: TV hata ayıklama iznini onaylamadıysa ayrı, gerisi "ulaşılamıyor".</summary>
    internal static TvOpenProblem AndroidOpenProblem(Exception error) =>
        error is AndroidInstallException { Error: AndroidInstallError.NotApproved } ? TvOpenProblem.DebugNotApproved : TvOpenProblem.DebugOff;

    // --- TV uygulamasını kurma ---

    private static string? BundledTvPackage
    {
        get
        {
            var folder = Path.Combine(AppContext.BaseDirectory, "tv-app");
            return Directory.Exists(folder) ? Directory.EnumerateFiles(folder, "*.ipk").FirstOrDefault() : null;
        }
    }

    public string? BundledTvAppVersion =>
        BundledTvPackage is { } package ? DevModeInstaller.VersionOfPackage(Path.GetFileName(package)) : null;

    public Task<bool> IsDevModeOnAsync(string host) => DevModeInstaller.IsDevModeOnAsync(host);

    public Task<bool> TvRespondsAsync(string host, TvBrand brand) => TvReach.RespondsAsync(host, brand);

    // LG kurulumunun adımları da tvinstall.log'a telefonlardaki satırlarla yazılır (LgInstallLog); önceden yalnız Samsung
    // ve Android TV kurulumu günlük tutuyordu.
    private static LgInstallLog LgLog => new(new TvInstall.InstallLog(TvInstallLogPath).Write);

    public void WriteTvInstallLog(string line) => new TvInstall.InstallLog(TvInstallLogPath).Write(line);

    public Task<string> FetchDevKeyAsync(string host, string passphrase) =>
        LgLog.KeyAsync(host, () => DevModeInstaller.FetchKeyAsync(host, passphrase, new ProcessRunner(), DevModeTools.ForThisSystem()));

    public Task<string?> InstalledTvAppVersionAsync(string host, string devKey) =>
        LgLog.InstalledVersionAsync(host, BundledTvAppVersion, () => WithKeyFileAsync(devKey, file => Installer(host, file).CheckInstalledVersionAsync()));

    public Task InstallTvAppAsync(string host, string devKey) => InstallTvAppAsync(host, devKey, replaceForeign: false);

    public async Task InstallTvAppAsync(string host, string devKey, bool replaceForeign)
    {
        try
        {
            await LgLog.InstallAsync(() => WithKeyFileAsync<object?>(devKey, async file =>
            {
                if (BundledTvPackage is not { } package || BundledTvAppVersion is not { } version)
                    throw new DevModeException(DevModeError.InstallFailed, "uygulamanın yanında LG paketi (tv-app/*.ipk) yok");
                // Kullanıcı "Kaldırıp Kur" dedi: CouchSubs'ın kimliğini kullanan başka uygulama önce kaldırılır.
                if (replaceForeign)
                    WriteTvInstallLog($"LG: kullanıcı onayıyla TV'deki com.couchsubs.tv kaldırıldı: {await Installer(host, file).RemoveAppAsync()}");
                // TV'nin modeli ve paketin çözünürlüğü (#1098: Full HD webOS 3.x TV'ye 1280x720).
                WriteTvInstallLog(await Installer(host, file).InstallAsync(package, version));
                return null;
            }));
        }
        catch (DevModeException error)
        {
            StartupGuard.Log("LG TV kurulumu", error);
            throw;
        }
    }

    public async Task CloseTvAppAsync(string host, string devKey)
    {
        try
        {
            var reply = await WithKeyFileAsync(devKey, file => Installer(host, file).CloseAppAsync());
            WriteTvInstallLog($"LG: TV'deki CouchSubs kapatıldı: {reply}");
        }
        catch (DevModeException error)
        {
            WriteTvInstallLog($"LG: TV'deki CouchSubs kapatılamadı: {error.Message}");
        }
    }

    public async Task<int?> RenewDevSessionAsync(string host, string devKey)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
            return await WithKeyFileAsync(devKey, file => Installer(host, file).RenewSessionAsync(http));
        }
        catch (DevModeException)
        {
            return null;
        }
    }

    // --- Samsung ve Android TV (CouchSubs.TvInstall) ---

    /// <summary>Kalıcı dosyalar: ADB anahtarı ve Samsung sertifikaları.</summary>
    private static string DataDirectory(string name) =>
        Path.Combine(AppDataPaths.Root, name);

    public BundledTvApp? BundledApp(TvBrand brand)
    {
        var pattern = brand switch { TvBrand.Samsung => "*.wgt", TvBrand.AndroidTv => "*.apk", _ => null };
        var folder = Path.Combine(AppContext.BaseDirectory, "tv-app");
        if (pattern is null || !Directory.Exists(folder)) return null;
        var file = Directory.EnumerateFiles(folder, pattern).FirstOrDefault();
        return file is not null && TvInstall.Versions.OfBundledFile(file) is { } version ? new BundledTvApp(file, version) : null;
    }

    public Task<bool> IsSamsungDevModeOnAsync(string host) => SamsungTvInstaller.IsDevModeOnAsync(host);

    /// <summary>
    /// Kurulu TV uygulamasını geliştirici bağlantısıyla (sdb) açar; <paramref name="restart"/> ise önce kapatır. Geliştirici
    /// modu kapalıysa, Host PC IP başka bilgisayarınsa ya da TV açmadıysa Failed; uygulama zaten çalışıyorsa Resumed.
    /// </summary>
    private static async Task<SamsungSdbOpen> OpenSamsungAppAsync(string host, bool restart)
    {
        if (string.IsNullOrEmpty(host) || !await SamsungTvInstaller.IsDevModeOnAsync(host)) return SamsungSdbOpen.Failed;
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var log = new TvInstall.InstallLog(TvInstallLogPath);
        var installer = new SamsungTvInstaller(host, DataDirectory("samsung"), new SamsungCertificates(http, log)) { Log = log };
        try
        {
            return await Task.Run(() => installer.OpenAsync(restart)) switch
            {
                SamsungAppLaunch.Launched => SamsungSdbOpen.Launched,
                SamsungAppLaunch.Resumed => SamsungSdbOpen.Resumed,
                _ => SamsungSdbOpen.Failed,
            };
        }
        catch (Exception error)
        {
            log.Write($"Uygulama açılamadı: {error.Message}");
            return SamsungSdbOpen.Failed;
        }
    }

    public async Task<SamsungPreflight> CheckSamsungAsync(string host)
    {
        var info = await SamsungDiscovery.DeveloperInfoAsync(host);
        return new SamsungPreflight(info, AppController.LocalAddress(host));
    }

    public Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent) =>
        InstallSamsungAppAsync(host, app, openIfInstalled, replaceForeign: false, onEvent);

    public async Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, bool replaceForeign,
        Action<TvInstallEvent> onEvent)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(1) };
        var log = new TvInstall.InstallLog(TvInstallLogPath);
        var installer = new SamsungTvInstaller(host, DataDirectory("samsung"), new SamsungCertificates(http, log))
        {
            Log = log,
            OpenIfInstalled = openIfInstalled,
            ReplaceForeign = replaceForeign,
            Progress = step => onEvent(new TvInstallEvent(TvInstallEventKind.Progress, Step: step)),
            SignIn = token => SamsungLogin.SignInAsync(url => onEvent(new TvInstallEvent(TvInstallEventKind.SignIn, new Uri(url))),
                TimeSpan.FromMinutes(10), token),
        };
        try
        {
            return await Task.Run(() => installer.EnsureInstalledAsync(app.Path, app.Version));
        }
        catch (SamsungInstallException error)
        {
            StartupGuard.Log("Samsung TV kurulumu", error);
            throw new DevModeException(SamsungError(error.Error), error.Detail);
        }
        catch (Exception error) when (error is not DevModeException)
        {
            StartupGuard.Log("TV kurulumu", error);
            log.Write($"Beklenmeyen hata: {error}");
            throw new DevModeException(DevModeError.InstallFailed, $"{error.GetType().Name}: {error.Message}");
        }
    }

    /// <summary>TV kurulum günlüğü (LG, Samsung, Android TV): %LOCALAPPDATA%\CouchSubs\tvinstall.log (hata iletisinde de yazar).</summary>
    public static string TvInstallLogPath => DataDirectory("tvinstall.log");

    internal static DevModeError SamsungError(SamsungInstallError error) => error switch
    {
        SamsungInstallError.Unreachable => DevModeError.Unreachable,
        SamsungInstallError.LoginFailed => DevModeError.SignInFailed,
        SamsungInstallError.CertificateFailed => DevModeError.CertificateFailed,
        SamsungInstallError.TooOld => DevModeError.TooOld,
        SamsungInstallError.NotEnoughSpace => DevModeError.NotEnoughSpace,
        SamsungInstallError.CertificateMismatch => DevModeError.CertificateMismatch,
        SamsungInstallError.CertificateRejected => DevModeError.CertificateRejected,
        SamsungInstallError.TvClockWrong => DevModeError.TvClockWrong,
        SamsungInstallError.PackageBlocked => DevModeError.PackageBlocked,
        SamsungInstallError.ConnectionLost => DevModeError.ConnectionLost,
        SamsungInstallError.ForeignApp => DevModeError.ForeignApp,
        _ => DevModeError.InstallFailed,
    };

    public Task<bool> IsAndroidDebugOnAsync(string host) => AndroidTvInstaller.IsReachableAsync(host);

    public Task<IReadOnlyList<string>> ScanAndroidTvsAsync() => AndroidTvInstaller.ScanAsync();

    public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent) =>
        InstallAndroidAppAsync(host, app, openIfInstalled, null, onEvent);

    public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, string? launchParams,
                                               Action<TvInstallEvent> onEvent) =>
        InstallAndroidAppAsync(host, app, openIfInstalled, launchParams, replaceForeign: false, onEvent);

    public async Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, string? launchParams,
                                                     bool replaceForeign, Action<TvInstallEvent> onEvent)
    {
        void Approve() => onEvent(new TvInstallEvent(TvInstallEventKind.ApproveOnTv));
        var installer = new AndroidTvInstaller(host, DataDirectory("adb"))
        {
            OnApprovalNeeded = Approve,
            LaunchParams = launchParams,
            ReplaceForeign = replaceForeign,
            // CouchSubs TV Play'de ve TV'de Play Store varsa TV'de Play sayfası açılır (PlayStoreRedirect.cs).
            PlayListed = AndroidTvInstaller.IsListedOnPlayAsync,
            OnPlayOpened = () => onEvent(new TvInstallEvent(TvInstallEventKind.Progress, Step: "play")),
        };
        try
        {
            // TV'den kaldırılıp kaydı kalan uygulama da kurulur (AndroidTvApp.cs); "yeniden kur"da güncel uygulama açılır.
            var log = new TvInstall.InstallLog(TvInstallLogPath);
            var (version, _) = await Task.Run(() => TvInstall.AndroidTvApp.EnsureInstalledAsync(installer, host, DataDirectory("adb"), app.Path,
                app.Version, openIfInstalled, Approve, log.Write));
            return version;
        }
        catch (AndroidInstallException error)
        {
            StartupGuard.Log("Android TV kurulumu", error);
            throw new DevModeException(error.Error switch
            {
                AndroidInstallError.Unreachable => DevModeError.Unreachable,
                AndroidInstallError.NotApproved => DevModeError.NotApproved,
                AndroidInstallError.ForeignApp => DevModeError.ForeignApp,
                _ => DevModeError.InstallFailed,
            }, error.Message);
        }
        catch (TvInstall.TvStepTimeoutException error)
        {
            // İki denemede de takıldı (TvStall): kart "Kurulum sırasında TV bağlantısı koptu" ve "Tekrar dene" gösterir.
            StartupGuard.Log("Android TV kurulumu", error);
            throw new DevModeException(DevModeError.ConnectionLost, TvInstall.TvStall.GaveUp(error));
        }
        catch (Exception error) when (error is not DevModeException)
        {
            StartupGuard.Log("TV kurulumu", error);
            throw new DevModeException(DevModeError.InstallFailed, error.Message);
        }
    }

    private static DevModeInstaller Installer(string host, string keyFile) => DevModeInstaller.ForTv(host, keyFile);

    /// <summary>ssh anahtarı dosyadan okur; dosya yalnız komut süresince durur.</summary>
    private static async Task<T> WithKeyFileAsync<T>(string key, Func<string, Task<T>> body)
    {
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        await File.WriteAllTextAsync(file, key);
        try
        {
            return await body(file);
        }
        finally
        {
            File.Delete(file);
        }
    }

    public ITextReader? MakeReader(string language)
    {
        var reader = WindowsOcrReader.Create(language);
        // Paketteki satırlar yazı tanımaya "doğru okuma" ölçüsü olur (yalnız birebir eşleşme; bulanık arama değil).
        if (reader is not null && GamePacks is { } packs) reader.IsKnownLine = text => packs.Find(text) is not null;
        // Paketli oyunlarda sözlükte olmayan sözcük içeren okuma kısa süre bekletilir (bkz. SubtitlePipeline.PackWaitMs).
        // Sözlük: bozuk okuma bekletilir; aynı karenin ve aynı satırın okumalarından en çok gerçek sözcük içeren seçilir
        // (paketi olmayan oyunlarda da: GTA 6 gibi). Sözlük İngilizcedir: başka dildeki oyunda her satır "bozuk" görünür,
        // bekletilir ve en kısa okuma seçilirdi; o dillerde kapalıdır. Dil değişince eski ayar kalmasın diye her seferinde
        // yeniden kurulur.
        var dictionary = language.StartsWith("en", StringComparison.OrdinalIgnoreCase) && WindowsSpellCheck.Available;
        SubtitlePipeline.ExtraMisreadCheck = dictionary ? WindowsSpellCheck.LooksMisread : null;
        SubtitlePipeline.ExtraReadingScore = dictionary ? WindowsSpellCheck.Score : null;
        SubtitlePipeline.DefaultHoldWithoutPacks = dictionary;
        WindowsOcrReader.DictionaryScore = dictionary ? WindowsSpellCheck.Score : null;
        return reader;
    }
    public ITextReader? MakeReader(string language, OcrEngine engine)
    {
        var reader = MakeReader(language);
        // Seçim Windows'a dönünce gelişmiş okuyucunun oturumları bırakılır (ekran kartı belleği boşalır).
        if (engine != OcrEngine.Advanced)
        {
            PaddleOcrReader.ReleaseAll();
            return reader;
        }
        // Sözlük ve bekletme ayarları (yukarıda) iki okuyucuda da geçerlidir; gelişmiş okuyucu açılamazsa Windows'unki kalır.
        // Okurken art arda hata verirse (ör. DirectML "device removed") oturumları bırakılır ve bu hatta Windows'unki okur.
        if (advancedOcr.IsInstalled && PaddleOcrReader.Create(advancedOcr.Directory, language) is { } advanced)
            return new FallbackTextReader(advanced, reader, advanced.Release);
        return reader;
    }

    public bool HasOcrLanguage(string language) => WindowsOcrReader.HasLanguage(language);

    /// <summary>Denetlenemeyen TV'ler için: TV uygulaması kendisi bağlanır.</summary>
    private sealed class IdleKeeper : IKeeper
    {
        public void Start(TimeSpan interval) { }
        public void Stop() { }
        public void Reconnect() { }
    }

    private sealed class Keeper(TvKeeper keeper) : IKeeper
    {
        public void Start(TimeSpan interval) => keeper.Start(interval);
        public void Stop() => keeper.Stop();
        public void Reconnect() => keeper.Reconnect();
        public void ReopenApp() => keeper.ReopenApp();
    }

    private sealed class AndroidKeeper(AndroidTvKeeper keeper) : IKeeper
    {
        public void Start(TimeSpan interval) => keeper.Start(interval);
        public void Stop() => keeper.Stop();
        public void Reconnect() => keeper.Reconnect();
    }

    /// <summary>OPUS-MT modelleri; şimdilik yalnız İngilizce→Türkçe.</summary>
    private sealed class MarianModel : ITranslationModel
    {
        private readonly Ct2ModelStore englishTurkish = new(Path.Combine(AppPaths.Models, "en-tr-ct2"));
        private readonly CudaRuntimeStore cuda = new(Path.Combine(AppPaths.Data, "cuda-12.8"));
        private MarianTranslator? translator;
        private Task? cudaDownload;
        private TranslationDevice device = TranslationDevice.Cpu;
        private int cpuThreads = CpuThreadOptions.Default;
        private int failed;

        public event Action? EngineFailure;
        public event Action? GpuFallback;

        public void SelectDevice(TranslationDevice selected)
        {
            if (device == selected) return;
            device = selected;
            // NVIDIA sürücüsü (nvcuda.dll) yoksa ~565 MB indirme boşa gider; doğrudan CPU'ya düşülür.
            if (selected == TranslationDevice.Gpu && File.Exists(Path.Combine(Environment.SystemDirectory, "nvcuda.dll")))
            {
                cudaDownload = cuda.StartDownload();
                _ = cudaDownload.ContinueWith(task =>
                    StartupGuard.Log("CUDA çalışma zamanı indirilemedi", task.Exception!),
                    CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted, TaskScheduler.Default);
            }
            translator?.Dispose();
            translator = null;
            Interlocked.Exchange(ref failed, 0);
        }

        public void SelectCpuThreads(int selected)
        {
            selected = CpuThreadOptions.Normalize(selected, Environment.ProcessorCount);
            if (cpuThreads == selected) return;
            cpuThreads = selected;
            translator?.Dispose();
            translator = null;
            Interlocked.Exchange(ref failed, 0);
        }

        public bool EngineFailed => Volatile.Read(ref failed) != 0;

        /// <summary>
        /// Motor açılamadı: hata.log'a bir kez yazılır, ana ekran uyarı gösterir. En sık neden: CTranslate2
        /// çalışma zamanı ya da Visual C++ DLL'leri eksik.
        /// </summary>
        private void Fail(Exception error)
        {
            if (Interlocked.Exchange(ref failed, 1) != 0) return;
            StartupGuard.Log("Ücretsiz çeviri motoru açılamadı (CTranslate2)", error);
            EngineFailure?.Invoke();
        }

        public bool IsSupported(string source, string target) => source == "en" && target == "tr";

        public bool IsInstalled(string source, string target) => IsSupported(source, target) && englishTurkish.IsInstalled;

        public async Task DownloadAsync(string source, string target, IProgress<double> progress, CancellationToken cancellationToken)
        {
            try
            {
                await englishTurkish.DownloadAsync(progress, cancellationToken);
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                // Ekran yalnız "internet bağlantınızı kontrol edin" der; asıl neden (TLS, disk, antivirüs, özet) hata.log'da kalsın.
                StartupGuard.Log("Ücretsiz çeviri modeli indirilemedi", error);
                throw;
            }
            // Önceki sürümlerin ONNX modeli (yaklaşık 530 MB) artık kullanılmaz; yeni model kurulunca silinir.
            try
            {
                var old = Path.Combine(AppPaths.Models, "en-tr");
                if (Directory.Exists(old)) Directory.Delete(old, recursive: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                StartupGuard.Log("Eski ONNX çeviri modeli silinemedi", error);
            }
        }

        // Model belleğe bir kez yüklenir; dil değişse de aynı çevirmen kullanılır. Yükleme 1–3 sn sürdüğü
        // için hemen arka planda başlar; ilk altyazı beklemez.
        public ITextTranslator Create(string source, string target)
        {
            if (translator is not null) return translator;
            MarianTranslator created;
            try
            {
                created = new MarianTranslator(englishTurkish.InstallDirectory,
                    cache: TranslationCache.Shared(AppPaths.Translations, MarianTranslator.EngineId, "en", "tr"),
                    useGpu: device == TranslationDevice.Gpu, onGpuFallback: () => GpuFallback?.Invoke(),
                    cudaReady: cudaDownload, cudaDirectory: cuda.InstallDirectory,
                    cpuThreads: cpuThreads);
            }
            catch (Exception error)
            {
                // Önbellek ya da sözlük okunamadı; denetleyici bu hat için çeviriyi kapatır, sonraki başlatmada yeniden denenir.
                StartupGuard.Log("Ücretsiz çevirmen kurulamadı", error);
                throw;
            }
            created.EngineFailed += Fail;
            translator = created;
            // WarmUpAsync hata fırlatmaz; motor açılamazsa EngineFailed ile bildirir.
            _ = created.WarmUpAsync();
            return created;
        }
    }
}

/// <summary>Şifreli depo (hesap, PS5, TV anahtarları).</summary>
public sealed class DpapiAppStore : IAppStore
{
    public void Save<T>(string key, T value) => SecureStore.Default.Save(key, value);
    public T? Load<T>(string key) => SecureStore.Default.Load<T>(key);
    public void Remove(string key) => SecureStore.Default.Remove(key);
}

/// <summary>Sıradan ayarlar: %LOCALAPPDATA%\CouchSubs\settings.json.</summary>
public sealed class FileSettingsStore : ISettingsStore
{
    private static readonly string FilePath = Path.Combine(AppPaths.Data, "settings.json");

    public UserSettings Load()
    {
        try { return ExtraAreaMigration.Load(File.ReadAllText(FilePath)); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { return new UserSettings(); }
    }

    /// <summary>
    /// Dosya o an yazılamıyorsa (antivirüs ya da eşitleme kilitlemiş) ayar bellekte geçerli kalır ve sonraki kayıtta
    /// yazılır; hata ayarı değiştiren işi (pencereyi taşıma, Num 7) yarıda bırakmaz.
    /// </summary>
    public void Save(UserSettings settings)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.Data);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(settings));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            StartupGuard.Log("Ayarlar kaydedilemedi", error);
        }
    }
}

public sealed class WindowsSleepGuard : ISleepGuard
{
    public void Begin(bool keepDisplayOn) => SleepGuard.Begin(keepDisplayOn);
    public void End() => SleepGuard.End();
}
