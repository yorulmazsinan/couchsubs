// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;
using CouchSubs.Translation;
using CouchSubs.TvInstall.Android;
using CouchSubs.TvInstall.Samsung;

namespace CouchSubs.Linux;

/// <summary>
/// Uygulama denetleyicisinin Linux'taki gerçek dünya bağlantıları (PS5, PSN, TV, OCR, çeviri). Windows'taki
/// <c>LiveServices</c> ile aynı katmanları kullanır; farkı yazı tanımanın Tesseract olması ve dublaj, güncelleme,
/// güvenlik duvarı gibi Windows'a özgü parçaların bulunmamasıdır.
/// </summary>
public sealed class LinuxServices : IAppServices
{
    public ITranslationModel Translation { get; } = new MarianModel();

    // Paneldeki çevrimiçi çeviri anahtarı Claude (sk-ant-…) ya da DeepL olabilir.
    public ITextTranslator? MakeOnlineTranslator(string key, ITextTranslator? fallback) =>
        ClaudeTranslator.IsClaudeKey(key) ? new ClaudeTranslator(key, fallback) : new DeepLTranslator(key, fallback);

    public Task<OnlineKeyCheck> CheckOnlineKeyAsync(string key) =>
        ClaudeTranslator.IsClaudeKey(key) ? ClaudeTranslator.CheckAsync(key) : DeepLTranslator.CheckAsync(key);

    public Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync() => ConsoleDiscovery.DiscoverAsync();

    public async Task<byte[]> AccountIdFromRedirectAsync(Uri redirect)
    {
        var code = PsnAccount.CodeFromRedirect(redirect)
                   ?? throw new AppException(AppError.InvalidLogin, AppException.Describe(AppError.InvalidLogin, Program.Text));
        return await PsnAccount.AccountIdAsync(code);
    }

    public Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin) => Registration.RegisterAsync(host, accountId, pin);

    public async Task<IReadOnlyList<LgTv>> DiscoverTvsAsync()
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var lg = Timed("LG", LgDiscovery.SearchAsync(), watch);
        var samsung = Timed("Samsung", SamsungDiscovery.SearchAsync(), watch);
        return [.. await lg, .. await samsung];

        static async Task<IReadOnlyList<LgTv>> Timed(string brand, Task<IReadOnlyList<LgTv>> search, System.Diagnostics.Stopwatch watch)
        {
            var found = await search;
            Log.Write("tv", $"{brand} araması: {found.Count} TV, {watch.ElapsedMilliseconds} ms");
            return found;
        }
    }

    public async Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server)
    {
        // Sunucu Android TV'yi denetlemez; TV uygulaması sunucuyu kendisi bulur.
        if (tv.Brand == TvBrand.AndroidTv) return new TvPairing("", true);
        if (tv.Brand == TvBrand.Samsung)
        {
            using var samsung = new SamsungClient(tv, key);
            var token = await samsung.ConnectAsync();
            try { await samsung.LaunchAsync(SamsungClient.AppId, new Dictionary<string, string> { ["server"] = server }); }
            catch (Exception) { /* TV uygulaması sunucuyu kendisi de bulabilir */ }
            return new TvPairing(token, true);
        }
        using var client = new SsapClient(tv, key);
        var newKey = await client.ConnectAsync();
        try
        {
            await client.LaunchAsync(AppController.TvAppId, new Dictionary<string, string> { ["server"] = server });
            return new TvPairing(newKey, true);
        }
        catch (Exception error)
        {
            Log.Write("tv", $"TV uygulaması açılamadı: {error.Message}");
            return new TvPairing(newKey, false);
        }
    }

    public IStreamSession MakeStream(RegisteredConsole console, byte[] accountId) => new StreamSession(console, accountId);

    public IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved)
    {
        if (tv.Brand == TvBrand.AndroidTv) return new IdleKeeper();
        if (tv.Brand == TvBrand.Samsung)
        {
            var samsungLocator = new TvLocator(tv, async target =>
            {
                var client = new SamsungClient(target, key);
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
            }, () => SamsungDiscovery.SearchAsync(), onMoved);
            return new Keeper(new TvKeeper(samsungLocator.ConnectAsync, SamsungClient.AppId, parameters, appConnected));
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
        }, () => LgDiscovery.SearchAsync(), onMoved);
        return new Keeper(new TvKeeper(locator.ConnectAsync, AppController.TvAppId, parameters));
    }

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

    public Task<string> FetchDevKeyAsync(string host, string passphrase) =>
        DevModeInstaller.FetchKeyAsync(host, passphrase, new ProcessRunner(), DevModeTools.ForThisSystem());

    public Task<string?> InstalledTvAppVersionAsync(string host, string devKey) =>
        WithKeyFileAsync(devKey, file => Installer(host, file).InstalledVersionAsync());

    public async Task InstallTvAppAsync(string host, string devKey)
    {
        try
        {
            await WithKeyFileAsync<object?>(devKey, async file =>
            {
                if (BundledTvPackage is not { } package || BundledTvAppVersion is not { } version)
                    throw new DevModeException(DevModeError.InstallFailed, "uygulamanın yanında LG paketi (tv-app/*.ipk) yok");
                await Installer(host, file).InstallAsync(package, version);
                return null;
            });
        }
        catch (DevModeException error)
        {
            Log.Write("tv", $"LG TV kurulumu: {error.Error} {error.Detail}");
            throw;
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

    public BundledTvApp? BundledApp(TvBrand brand)
    {
        var pattern = brand switch { TvBrand.Samsung => "*.wgt", TvBrand.AndroidTv => "*.apk", _ => null };
        var folder = Path.Combine(AppContext.BaseDirectory, "tv-app");
        if (pattern is null || !Directory.Exists(folder)) return null;
        var file = Directory.EnumerateFiles(folder, pattern).FirstOrDefault();
        return file is not null && TvInstall.Versions.OfBundledFile(file) is { } version ? new BundledTvApp(file, version) : null;
    }

    public Task<bool> IsSamsungDevModeOnAsync(string host) => SamsungTvInstaller.IsDevModeOnAsync(host);

    public async Task InstallSamsungAppAsync(string host, BundledTvApp app, Action<TvInstallEvent> onEvent)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(1) };
        var installer = new SamsungTvInstaller(host, AppPaths.Folder("samsung"), new SamsungCertificates(http))
        {
            Progress = _ => onEvent(new TvInstallEvent(TvInstallEventKind.Progress)),
            SignIn = token => SamsungLogin.SignInAsync(url => onEvent(new TvInstallEvent(TvInstallEventKind.SignIn, new Uri(url))),
                TimeSpan.FromMinutes(10), token),
        };
        try
        {
            await Task.Run(() => installer.InstallAsync(app.Path));
        }
        catch (SamsungInstallException error)
        {
            Log.Write("tv", $"Samsung TV kurulumu: {error.Message}");
            throw new DevModeException(error.Error switch
            {
                SamsungInstallError.Unreachable => DevModeError.Unreachable,
                SamsungInstallError.LoginFailed => DevModeError.SignInFailed,
                SamsungInstallError.CertificateFailed => DevModeError.CertificateFailed,
                SamsungInstallError.TooOld => DevModeError.TooOld,
                _ => DevModeError.InstallFailed,
            }, error.Message);
        }
        catch (Exception error) when (error is not DevModeException)
        {
            Log.Write("tv", $"TV kurulumu: {error.Message}");
            throw new DevModeException(DevModeError.InstallFailed, error.Message);
        }
    }

    public Task<bool> IsAndroidDebugOnAsync(string host) => AndroidTvInstaller.IsReachableAsync(host);

    public Task<IReadOnlyList<string>> ScanAndroidTvsAsync() => AndroidTvInstaller.ScanAsync();

    public async Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, Action<TvInstallEvent> onEvent)
    {
        var installer = new AndroidTvInstaller(host, AppPaths.Folder("adb"))
        {
            OnApprovalNeeded = () => onEvent(new TvInstallEvent(TvInstallEventKind.ApproveOnTv)),
        };
        try
        {
            var (version, _) = await Task.Run(() => installer.EnsureInstalledAsync(app.Path, app.Version));
            return version;
        }
        catch (AndroidInstallException error)
        {
            Log.Write("tv", $"Android TV kurulumu: {error.Message}");
            throw new DevModeException(error.Error switch
            {
                AndroidInstallError.Unreachable => DevModeError.Unreachable,
                AndroidInstallError.NotApproved => DevModeError.NotApproved,
                _ => DevModeError.InstallFailed,
            }, error.Message);
        }
        catch (Exception error) when (error is not DevModeException)
        {
            Log.Write("tv", $"TV kurulumu: {error.Message}");
            throw new DevModeException(DevModeError.InstallFailed, error.Message);
        }
    }

    private static DevModeInstaller Installer(string host, string keyFile) => DevModeInstaller.ForTv(host, keyFile);

    /// <summary>ssh anahtarı dosyadan okur; dosya yalnız komut süresince durur ve yalnız sahibi okuyabilir.</summary>
    private static async Task<T> WithKeyFileAsync<T>(string key, Func<string, Task<T>> body)
    {
        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        await File.WriteAllTextAsync(file, key);
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        try
        {
            return await body(file);
        }
        finally
        {
            File.Delete(file);
        }
    }

    // --- Yazı tanıma ---

    private TesseractReader? reader;
    private string? readerLanguage;

    /// <summary>Tesseract motorları belleğe bir kez yüklenir; dil değişmedikçe aynı okuyucu kullanılır.</summary>
    public ITextReader? MakeReader(string language)
    {
        if (reader is not null && readerLanguage == language) return timedReader;
        reader?.Dispose();
        reader = TesseractReader.Create(language);
        readerLanguage = language;
        if (reader is null)
        {
            Log.Write("ocr", "Tesseract bulunamadı (libtesseract ve tesseract-ocr-eng kurulu mu?)");
            return null;
        }
        timedReader = new TimedReader(reader);
        return timedReader;
    }

    private TimedReader? timedReader;

    public bool HasOcrLanguage(string language) => TesseractReader.HasLanguage(language);

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
    }

    /// <summary>OPUS-MT modelleri; şimdilik yalnız İngilizce→Türkçe.</summary>
    private sealed class MarianModel : ITranslationModel
    {
        private readonly ModelStore englishTurkish = new(Path.Combine(AppPaths.Models, "en-tr"));
        private ITextTranslator? translator;

        public bool IsSupported(string source, string target) => source == "en" && target == "tr";

        public bool IsInstalled(string source, string target) => IsSupported(source, target) && englishTurkish.IsInstalled;

        public Task DownloadAsync(string source, string target, IProgress<double> progress, CancellationToken cancellationToken) =>
            englishTurkish.DownloadAsync(progress, cancellationToken);

        // Model belleğe bir kez yüklenir; yükleme 1–3 sn sürdüğü için hemen arka planda başlar.
        public ITextTranslator Create(string source, string target)
        {
            if (translator is not null) return translator;
            var marian = new MarianTranslator(englishTurkish.InstallDirectory);
            _ = marian.WarmUpAsync();
            translator = new TimedTranslator(marian, "yerel model");
            return translator;
        }
    }
}
