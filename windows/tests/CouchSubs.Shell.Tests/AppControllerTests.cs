// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Core.Dubbing;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;

namespace CouchSubs.Shell.Tests;

internal sealed class MemoryStore : IAppStore
{
    public Dictionary<string, object?> Values { get; } = [];
    /// <summary>Şifreli deponun yazamadığı durum (dosya kilitli, DPAPI hatası).</summary>
    public bool RejectWrites { get; set; }
    public void Save<T>(string key, T value)
    {
        if (RejectWrites) throw new IOException("locked");
        Values[key] = value;
    }
    public T? Load<T>(string key) => Values.TryGetValue(key, out var value) && value is T typed ? typed : default;
    public void Remove(string key) => Values.Remove(key);
}

internal sealed class MemorySettings : ISettingsStore
{
    public UserSettings? Saved { get; private set; }
    public UserSettings Load() => Saved ?? new UserSettings();
    public void Save(UserSettings settings) => Saved = settings;
}

internal sealed class FakeSleep : ISleepGuard
{
    public bool Active { get; private set; }
    public bool DisplayOn { get; private set; }
    public void Begin(bool keepDisplayOn) => (Active, DisplayOn) = (true, keepDisplayOn);
    public void End() => (Active, DisplayOn) = (false, false);
}

internal sealed class FakeStream : IStreamSession
{
    public event Action<Frame>? FrameReceived;
    public event Action<SessionState>? StateChanged;
    public event Action<RegisteredConsole>? ConsoleMoved;
    public void EmitMoved(RegisteredConsole moved) => ConsoleMoved?.Invoke(moved);
    public bool Started { get; private set; }
    public void Start() => Started = true;
    public void Stop() => Started = false;
    public int Reconnects { get; private set; }
    public void ReconnectNow() => Reconnects++;
    /// <summary>Oturum yeniden denemeyi bıraktı (PS5'te Uzaktan Oynatma çöktü, Xbox denemeleri bitti).</summary>
    public bool GaveUp { get; set; }
    public bool HasGivenUp => GaveUp;
    public void Dispose() { }
    public void Emit(SessionState state) => StateChanged?.Invoke(state);
    public void Emit(Frame frame) => FrameReceived?.Invoke(frame);
    /// <summary>Çeviri sürerken verilen ses ayarları (Xbox).</summary>
    public List<bool> PlayAudioChanges { get; } = [];
    public void SetPlayAudio(bool enabled) => PlayAudioChanges.Add(enabled);
}

internal sealed class FakeKeeper : IKeeper
{
    public bool Running { get; private set; }
    public void Start(TimeSpan interval) => Running = true;
    public void Stop() => Running = false;
    public int Reconnects { get; private set; }
    public void Reconnect() => Reconnects++;
}

internal sealed class FakeTranslation : ITranslationModel
{
    public TranslationDevice SelectedDevice { get; private set; } = TranslationDevice.Cpu;
    public event Action? GpuFallback;
    public void SelectDevice(TranslationDevice device) => SelectedDevice = device;
    public void FallBackToCpu() => GpuFallback?.Invoke();
    public bool Installed { get; set; } = true;
    public int Downloads { get; private set; }
    public TaskCompletionSource? DownloadGate { get; set; }
    public bool IsSupported(string source, string target) => source == "en" && target == "tr";
    public bool IsInstalled(string source, string target) => Installed;
    public async Task DownloadAsync(string source, string target, IProgress<double> progress, CancellationToken cancellationToken)
    {
        Downloads++;
        progress.Report(0.5);
        if (DownloadGate is not null) await DownloadGate.Task;
        Installed = true;
        progress.Report(1);
    }
    /// <summary>Verilirse Create bunu fırlatır (ör. CTranslate2 çalışma zamanı eksik).</summary>
    public Exception? CreateError { get; set; }
    public ITextTranslator Create(string source, string target) => CreateError is { } error ? throw error : new EchoTranslator();

    public bool EngineFailed { get; private set; }
    public event Action? EngineFailure;

    /// <summary>Motor arka planda (ısınırken) açılamadı.</summary>
    public void Fail()
    {
        EngineFailed = true;
        EngineFailure?.Invoke();
    }

    private sealed class EchoTranslator : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) => Task.FromResult("TR: " + text);
    }
}

/// <summary>Okuma anındaki <c>ReaderLines</c>'ı verir; test okuyucu kurulduktan sonra ekranı değiştirebilir.</summary>
internal sealed class FakeReader(Func<Reading?> lines) : ITextReader
{
    public string Read(Frame image) => lines()?.Text ?? "";
    public Reading ReadLines(Frame image, bool deep) => lines() ?? Reading.Empty;
}

internal sealed class FakeServices : IAppServices
{
    public IXboxService? Xbox { get; set; }
    /// <summary>PS Remote Play / chiaki-ng bu bilgisayarda kurulu mu (Ayarlar'daki indirme satırları, ana ekran uyarısı).</summary>
    public bool RemotePlayIsInstalled { get; set; } = true;
    public bool RemotePlayInstalled(RemotePlayApp app) => RemotePlayIsInstalled;
    public List<ConsoleInfo> Consoles { get; } = [new("192.168.1.253", "PS5-789", true)];
    public List<LgTv> Tvs { get; } = [new("LG TV", "192.168.1.153")];
    public RegisteredConsole? Registered { get; private set; }
    public Exception? RegisterError { get; set; }
    public string? LaunchedServer { get; private set; }
    public List<FakeStream> Streams { get; } = [];
    public List<FakeKeeper> Keepers { get; } = [];
    /// <summary>Her bekçinin kurulduğu TV kaydı (adres değişince yeni bekçi yeni adrese gider).</summary>
    public List<LgTv> KeeperTvs { get; } = [];
    public List<string> ReaderLanguages { get; } = [];
    /// <summary>Okuyucunun her karede bulduğu satırlar (verilmezse karede yazı yoktur).</summary>
    public Reading? ReaderLines { get; set; }
    /// <summary>Verilirse geçmiş bu dosyaya yazılır (geçici klasörde).</summary>
    public string? HistoryFile { get; set; }
    /// <summary>Verilirse kullanım verisi buraya gider (sahte HTTP katmanıyla).</summary>
    public UsageStats? Usage { get; set; }
    public bool HasOcr { get; set; } = true;
    public bool HasOcrPack { get; set; } = true;
    public bool HasOcrLanguage(string language) => HasOcrPack;
    public IDubbingModel? Dubbing { get; set; }
    public IDubbingModel? FastDubbing { get; set; }
    public GamePackLibrary? GamePacks { get; set; }
    public PackMatch? FindInPacks(string text) => GamePacks?.Find(text) is { } found ? new PackMatch(found, []) : null;
    public FakeTranslation Translation { get; } = new();
    public IFirewall? Firewall { get; set; }
    ITranslationModel IAppServices.Translation => Translation;
    public OnlineKeyCheck KeyCheck { get; set; } = new(OnlineKeyState.Valid, 10, 500_000);
    public List<string> CheckedKeys { get; } = [];
    public List<(string Key, ITextTranslator? Fallback)> OnlineTranslators { get; } = [];
    public Task<OnlineKeyCheck> CheckOnlineKeyAsync(string key)
    {
        CheckedKeys.Add(key);
        return Task.FromResult(KeyCheck);
    }
    public ITextTranslator? MakeOnlineTranslator(string key, ITextTranslator? fallback)
    {
        OnlineTranslators.Add((key, fallback));
        return fallback ?? Translation.Create("en", "tr");
    }
    public AiTestResult AiTest { get; set; } = new(OnlineKeyState.Valid, "KRATOS: Şimdi gidiyoruz.");
    public List<(AiProvider Provider, string Key, string Model)> AiTests { get; } = [];
    public List<(AiProvider Provider, string Key, string Model)> AiTranslators { get; } = [];
    public List<string?> AiInstructions { get; } = [];
    public Task<AiTestResult> TestAiKeyAsync(AiProvider provider, string key, string model)
    {
        AiTests.Add((provider, key, model));
        return Task.FromResult(AiTest);
    }
    public ITextTranslator? MakeAiTranslator(AiProvider provider, string key, string model, ITextTranslator? fallback, Func<string?>? game,
                                             string? instruction = null, bool paidTier = false)
    {
        AiTranslators.Add((provider, key, model));
        AiInstructions.Add(instruction);
        return fallback ?? Translation.Create("en", "tr");
    }
    public List<(LocalAiServer Server, string Key)> LocalTests { get; } = [];
    public List<(LocalAiServer Server, string Key)> LocalTranslators { get; } = [];
    public Task<AiTestResult> TestLocalAiAsync(LocalAiServer server, string key)
    {
        LocalTests.Add((server, key));
        return Task.FromResult(AiTest);
    }
    public ITextTranslator? MakeLocalAiTranslator(LocalAiServer server, string key, ITextTranslator? fallback, Func<string?>? game,
                                                  string? instruction = null)
    {
        AiInstructions.Add(instruction);
        LocalTranslators.Add((server, key));
        return fallback ?? Translation.Create("en", "tr");
    }

    public Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync() => Task.FromResult<IReadOnlyList<ConsoleInfo>>(Consoles);
    public Exception? LoginError { get; set; }
    public Task<byte[]> AccountIdFromRedirectAsync(Uri redirect) =>
        LoginError is not null ? Task.FromException<byte[]>(LoginError) : Task.FromResult(Enumerable.Repeat((byte)1, 8).ToArray());
    public uint? RegisteredPin { get; private set; }
    public Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin)
    {
        RegisteredPin = pin;
        if (RegisterError is not null) throw RegisterError;
        Registered = new RegisteredConsole(host, "PS5-789", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray());
        return Task.FromResult(Registered);
    }
    /// <summary>TV'ye dokunan çağrıların sayısı (arama, eşleşme, açık tutma, uygulama denetimi).</summary>
    public int TvCalls { get; private set; }
    /// <summary>Verilirse PS5 oturumu kurulurken bu hata atılır.</summary>
    public Exception? StreamError { get; set; }
    public Task<IReadOnlyList<LgTv>> DiscoverTvsAsync()
    {
        TvCalls++;
        return Task.FromResult<IReadOnlyList<LgTv>>(Tvs);
    }
    public Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server, string accessKey)
    {
        LaunchedServer = server;
        PairCount++;
        TvCalls++;
        return Task.FromResult(new TvPairing(PairKey, AppOnTv is not null));
    }
    /// <summary>TV'nin eşleşmede döndüğü jeton (Samsung jetonla gelen bağlantıda boş dönebilir).</summary>
    public string PairKey { get; set; } = "tv-key";
    /// <summary>Eşleşme isteği gönderen TV'nin adresinden yoklanan TV (null: tanınmadı).</summary>
    public Func<string, LgTv?> Identify { get; set; } = host => new LgTv("Samsung TV", host, TvBrand.Samsung);
    public Task<LgTv?> IdentifyTvAsync(string host) => Task.FromResult(Identify(host));
    /// <summary>Son bekçiye verilen "yeni jeton" geri çağrısı.</summary>
    public Action<string>? OnKey { get; private set; }
    public Action<TvOpenProblem?>? OnOpenResult { get; private set; }
    /// <summary>Her oturuma verilen PS5 giriş şifresi.</summary>
    public List<string?> StreamPasscodes { get; } = [];
    public IStreamSession MakeStream(RegisteredConsole console, byte[] accountId, string? loginPasscode)
    {
        StreamPasscodes.Add(loginPasscode);
        if (StreamError is not null) throw StreamError;
        var stream = new FakeStream();
        Streams.Add(stream);
        return stream;
    }
    /// <summary>Her pencere kaynağına verilen Remote Play uygulaması.</summary>
    public List<RemotePlayApp> WindowStreams { get; } = [];
    public IStreamSession MakeWindowStream(RemotePlayApp app)
    {
        WindowStreams.Add(app);
        var stream = new FakeStream();
        Streams.Add(stream);
        return stream;
    }
    public List<WindowCaptureTarget> CaptureWindowStreams { get; } = [];
    public IStreamSession MakeCaptureWindowStream(WindowCaptureTarget target)
    {
        CaptureWindowStreams.Add(target);
        var stream = new FakeStream();
        Streams.Add(stream);
        return stream;
    }
    public IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved,
                              Action<string> onKey, Func<int?>? consolePort = null,
                              Action<TvOpenProblem?>? onOpenResult = null)
    {
        TvCalls++;
        OnKey = onKey;
        OnOpenResult = onOpenResult;
        var keeper = new FakeKeeper();
        Keepers.Add(keeper);
        KeeperTvs.Add(tv);
        return keeper;
    }
    public string? AppOnTv { get; set; } = "0.6.1";
    public bool DevMode { get; set; }
    public bool KeyServer { get; set; } = true;
    public bool RefuseKey { get; set; }
    public int Installs { get; private set; }
    public int PairCount { get; private set; }
    public string? BundledTvAppVersion { get; set; } = "0.6.1";
    public List<string> InstallLog { get; } = [];
    public void WriteTvInstallLog(string line) => InstallLog.Add(line);
    public Task<bool> IsDevModeOnAsync(string host)
    {
        TvCalls++;
        return Task.FromResult(DevMode);
    }
    public Task<string> FetchDevKeyAsync(string host, string passphrase)
    {
        if (!KeyServer) throw new DevModeException(DevModeError.KeyServerOff);
        if (passphrase != "ABC123") throw new DevModeException(DevModeError.WrongPassphrase);
        return Task.FromResult("dev-key");
    }
    public Task<string?> InstalledTvAppVersionAsync(string host, string devKey)
    {
        TvCalls++;
        if (RefuseKey) throw new DevModeException(DevModeError.KeyRefused);
        if (ForeignOnTv) throw new DevModeException(DevModeError.ForeignApp, "\"Başka Uygulama\" 9.0.0");
        return Task.FromResult(AppOnTv);
    }
    public Exception? LgInstallError { get; set; }
    public Task InstallTvAppAsync(string host, string devKey)
    {
        Installs++;
        if (LgInstallError is { } error) throw error;
        AppOnTv = BundledTvAppVersion;
        return Task.CompletedTask;
    }
    public int? RenewedHours { get; set; } = 999;
    public int Renewals { get; private set; }
    public Task<int?> RenewDevSessionAsync(string host, string devKey)
    {
        Renewals++;
        return Task.FromResult(RenewedHours);
    }

    // Samsung ve Android TV
    public Dictionary<TvBrand, BundledTvApp> Bundled { get; } = [];
    public bool SamsungDevMode { get; set; }
    public List<string> AndroidHosts { get; } = [];
    public DevModeError? InstallError { get; set; }
    public string? InstallDetail { get; set; }
    public List<TvInstallEvent> Events { get; } = [];
    public List<(TvBrand Brand, string Host)> BrandInstalls { get; } = [];
    public BundledTvApp? BundledApp(TvBrand brand) => Bundled.GetValueOrDefault(brand);
    public Task<bool> IsSamsungDevModeOnAsync(string host)
    {
        TvCalls++;
        return Task.FromResult(SamsungDevMode);
    }
    /// <summary>Samsung TV'nin 8001 yanıtı ve TV'ye giden yolun bu bilgisayardaki adresi.</summary>
    public SamsungPreflight SamsungCheck { get; set; } = new(null, null);
    public Task<SamsungPreflight> CheckSamsungAsync(string host) => Task.FromResult(SamsungCheck);
    /// <summary>Samsung TV'de kurulu sürüm (sahte TV'nin vd_applist'i); null: uygulama yok.</summary>
    public string? SamsungOnTv { get; set; }
    /// <summary>Her Samsung denetiminde "güncelse de aç" istendi mi.</summary>
    public List<bool> SamsungOpenRequests { get; } = [];
    public Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent)
    {
        TvCalls++;
        SamsungOpenRequests.Add(openIfInstalled);
        if (SamsungOnTv is { } onTv && !DevModeInstaller.IsNewer(app.Version, onTv)) return Task.FromResult((onTv, false));
        Events.ForEach(onEvent);
        if (InstallError is { } error) throw new DevModeException(error, InstallDetail);
        BrandInstalls.Add((TvBrand.Samsung, host));
        SamsungOnTv = app.Version;
        return Task.FromResult((app.Version, true));
    }
    public Task<bool> IsAndroidDebugOnAsync(string host)
    {
        TvCalls++;
        return Task.FromResult(AndroidHosts.Contains(host));
    }
    public Task<IReadOnlyList<string>> ScanAndroidTvsAsync() => Task.FromResult<IReadOnlyList<string>>([.. AndroidHosts]);
    /// <summary>Her Android kurulumunda "güncelse de aç" istendi mi.</summary>
    public List<bool> AndroidOpenRequests { get; } = [];
    /// <summary>Android uygulamasına açılırken verilen parametreler (#617).</summary>
    public List<string?> AndroidLaunchParams { get; } = [];
    public int? PreferredServerPort { get; set; }
    public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, string? launchParams,
                                               Action<TvInstallEvent> onEvent)
    {
        AndroidLaunchParams.Add(launchParams);
        return InstallAndroidAppAsync(host, app, openIfInstalled, onEvent);
    }
    /// <summary>TV'de CouchSubs'ın kimliğiyle başka bir uygulama var (üç marka); "Kaldırıp Kur" onayıyla gider.</summary>
    public bool ForeignOnTv { get; set; }
    /// <summary>Her kurulumda "başka uygulamayı kaldır" istendi mi.</summary>
    public List<bool> ReplaceRequests { get; } = [];
    private void Foreign(bool replace)
    {
        ReplaceRequests.Add(replace);
        if (!ForeignOnTv) return;
        if (!replace) throw new DevModeException(DevModeError.ForeignApp, "\"Başka Uygulama\" 9.0.0");
        ForeignOnTv = false;
    }
    public Task InstallTvAppAsync(string host, string devKey, bool replaceForeign)
    {
        Foreign(replaceForeign);
        return InstallTvAppAsync(host, devKey);
    }
    public Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, bool replaceForeign,
        Action<TvInstallEvent> onEvent)
    {
        Foreign(replaceForeign);
        return InstallSamsungAppAsync(host, app, openIfInstalled, onEvent);
    }
    public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, string? launchParams, bool replaceForeign,
                                               Action<TvInstallEvent> onEvent)
    {
        Foreign(replaceForeign);
        return InstallAndroidAppAsync(host, app, openIfInstalled, launchParams, onEvent);
    }
    public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent)
    {
        AndroidOpenRequests.Add(openIfInstalled);
        Events.ForEach(onEvent);
        if (InstallError is { } error) throw new DevModeException(error);
        BrandInstalls.Add((TvBrand.AndroidTv, host));
        return Task.FromResult(app.Version);
    }
    public ITextReader? MakeReader(string language)
    {
        ReaderLanguages.Add(language);
        return HasOcr ? new FakeReader(() => ReaderLines) : null;
    }
    public List<OcrEngine> ReaderEngines { get; } = [];
    public ITextReader? MakeReader(string language, OcrEngine engine)
    {
        ReaderEngines.Add(engine);
        return MakeReader(language);
    }
    public FakeOcrModel? OcrModel { get; set; }
    public IOcrModel? AdvancedOcr => OcrModel;
}

internal sealed class FakeOcrModel : IOcrModel
{
    public bool IsInstalled { get; set; }
    public long DownloadBytes => 31_000_000;
    public Exception? Error { get; set; }
    public Task DownloadAsync(IProgress<double> progress, CancellationToken cancellationToken)
    {
        if (Error is not null) throw Error;
        progress.Report(1);
        IsInstalled = true;
        return Task.CompletedTask;
    }
}

public class AppControllerTests
{
    private static readonly RegisteredConsole Console =
        new("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray());

    internal static AppController Make(FakeServices? services = null, MemoryStore? store = null, MemorySettings? settings = null, FakeSleep? sleep = null) =>
        new(services ?? new FakeServices(), store ?? new MemoryStore(), settings ?? new MemorySettings(), sleep ?? new FakeSleep(), Localizer.ForLanguage("en"), action => action());

    [Fact]
    public void PaidGeminiOptInIsOffByDefaultAndSurvivesSettingsSerialization()
    {
        var legacy = System.Text.Json.JsonSerializer.Deserialize<UserSettings>("{}")!;
        Assert.False(legacy.GeminiPaidTier);
        var optedIn = legacy with { GeminiPaidTier = true };
        var restored = System.Text.Json.JsonSerializer.Deserialize<UserSettings>(
            System.Text.Json.JsonSerializer.Serialize(optedIn))!;
        Assert.True(restored.GeminiPaidTier);
    }

    [Fact]
    public void FreshInstallStartsAtWelcome() => Assert.Equal(OnboardingStep.Welcome, Make().Step);

    /// <summary>Kol ikinci hesaba atanınca PS5 her yeniden bağlanışta kolu kapatıyor (Play yorumu 20 Kas): "ana hesabı seçin"
    /// ipucu bağlantı koptuğunda da görünmeli (Mac/iPhone MainAccountTipTests, Android MainAccountTipTest ile aynı).</summary>
    [Theory]
    [InlineData(true, false, false, true)]
    [InlineData(true, false, true, true)]
    [InlineData(true, true, true, false)]
    [InlineData(true, true, false, true)]
    [InlineData(false, false, false, false)]
    [InlineData(false, true, false, false)]
    public void MainAccountTipShowsBeforeFirstSubtitleAndWhenConnectionDrops(bool ps5, bool hasSubtitle, bool streaming, bool expected) =>
        Assert.Equal(expected, AppController.MainAccountTipVisible(ps5, hasSubtitle, streaming));

    /// <summary>"Oyunun kendi altyazısını açın": görüntü bir dakikadır geliyor ama tek satır yok (Mac/iPhone
    /// SubtitleOffTipTests, Android SubtitleOffTipTest ile aynı; GitHub #503, #566, #572).</summary>
    [Theory]
    [InlineData(true, false, 60.0, true)]
    [InlineData(true, false, 59.9, false)]
    [InlineData(true, true, 600.0, false)]
    [InlineData(false, false, 600.0, false)]
    [InlineData(true, false, null, false)]
    public void SubtitleOffTipShowsAfterAMinuteOfPictureWithoutAnyLine(bool streaming, bool sawLine, double? seconds, bool expected) =>
        Assert.Equal(expected, SubtitleOffTip.IsVisible(streaming, sawLine, seconds is { } value ? TimeSpan.FromSeconds(value) : null));

    [Fact]
    public async Task ReloadGamePacksRefreshesInstalledPacksAfterWritingAUserPack()
    {
        var directory = Directory.CreateTempSubdirectory("couchsubs-pack-");
        try
        {
            var library = new GamePackLibrary(null, directory.FullName);
            var startup = new TaskCompletionSource<Action>(TaskCreationOptions.RunContinuationsAsynchronously);
            var controller = new AppController(new FakeServices { GamePacks = library }, new MemoryStore(),
                new MemorySettings(), new FakeSleep(), Localizer.ForLanguage("en"), action => startup.TrySetResult(action));
            var publishStartupList = await startup.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.Empty(controller.InstalledPacks);

            File.WriteAllText(Path.Combine(directory.FullName, "community-test-game.json"),
                """{"format":1,"id":"community-test-game","title":"Test Game","entries":{"ebf811f2fee9a8cc":"Yere yat!"}}""");
            controller.ReloadGamePacks();

            var pack = Assert.Single(controller.InstalledPacks);
            Assert.Equal("Test Game", pack.Title);
            Assert.Equal(1, pack.Entries);

            // A startup update already queued on the dispatcher must not restore the cached empty list.
            publishStartupList();
            Assert.Equal(pack, Assert.Single(controller.InstalledPacks));
        }
        finally
        {
            directory.Delete(recursive: true);
        }
    }

    [Fact]
    public void CompleteSetupOpensMainScreen()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, Console);
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "192.168.1.153"));
        store.Save(StoreKeys.TvKey, "tv-key");
        Assert.Equal(OnboardingStep.Done, Make(store: store).Step);
        Assert.True(store.Load<bool?>(StoreKeys.SetupComplete), "Eski kurulum bir kez 'bitti' diye kaydedilir");
    }

    /// Sihirbaz PS5 adımını geçmiş: hesap ve konsol kayıtlı, kurulum bitmemiş.
    private static MemoryStore StoreUpToTv()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, Console);
        return store;
    }

    /// Samsung: TV eşleşti, uygulama kurulurken CouchSubs kapatıldı. Yeniden açılınca kurulum bitmiş sayılmaz, TV
    /// adımından sürer.
    [Fact]
    public async Task InterruptedTvInstallIsNotComplete()
    {
        var store = StoreUpToTv();
        var controller = Make(store: store);
        Assert.Equal(OnboardingStep.Tv, controller.Step);
        await controller.PairAsync(new LgTv("Samsung", "192.168.1.20", TvBrand.Samsung));
        Assert.True(controller.HasTv);
        var reopened = Make(store: store);
        Assert.Equal(OnboardingStep.Tv, reopened.Step);
        Assert.True(reopened.HasTv, "Eşleşme kaybolmaz; TV adımında uygulama kurulumu sürer");
        Assert.False(store.Load<bool?>(StoreKeys.SetupComplete));
    }

    [Fact]
    public async Task FinishedTvSetupIsComplete()
    {
        var store = StoreUpToTv();
        var controller = Make(store: store);
        await controller.PairAsync(new LgTv("Samsung", "192.168.1.20", TvBrand.Samsung));
        controller.Advance(); // TV -> çeviri modeli
        controller.Advance(); // çeviri modeli -> deneme
        controller.Advance(); // deneme -> daha iyi çeviri
        controller.Advance(); // daha iyi çeviri -> bitti
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(OnboardingStep.Done, Make(store: store).Step);
    }

    /// "TV'm yok, bilgisayar ekranında göster" de kurulumu bitirir; yarıda kapatılırsa TV adımından sürer.
    [Fact]
    public void ComputerScreenChoiceCompletesSetup()
    {
        var store = StoreUpToTv();
        var settings = new MemorySettings();
        var controller = Make(store: store, settings: settings);
        controller.UseComputerScreen();
        Assert.Equal(OnboardingStep.Tv, Make(store: store, settings: settings).Step);
        controller.Advance();
        controller.Advance();
        controller.Advance();
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(OnboardingStep.Done, Make(store: store, settings: settings).Step);
    }

    [Fact]
    public async Task PsnStepNeedsAccountId()
    {
        var controller = Make();
        controller.Step = OnboardingStep.PsnLogin;
        Assert.False(controller.CanAdvance);
        await controller.CompletePsnLoginAsync(new Uri("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=x"));
        Assert.True(controller.CanAdvance);
    }

    [Fact]
    public async Task ConsoleStepNeedsRegistration()
    {
        var services = new FakeServices();
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        controller.Step = OnboardingStep.Console;
        Assert.False(controller.CanAdvance);
        await controller.RegisterAsync("192.168.1.253", "12345678");
        Assert.True(controller.CanAdvance);
        Assert.Equal("192.168.1.253", services.Registered?.Host);
    }

    /// Eşleşme açıkça söylenir (kullanıcılar fark etmeyip tekrar Bağlan'a basıyordu) ve kaydedildiği günlüğe yazılır.
    [Fact]
    public async Task PairingSuccessIsAnnouncedAndLogged()
    {
        var lines = new System.Collections.Concurrent.ConcurrentQueue<string>();
        void Collect(string line) => lines.Enqueue(line);
        RemotePlayLog.MessageLogged += Collect;
        try
        {
            var store = new MemoryStore();
            var controller = Make(store: store);
            await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
            controller.Step = OnboardingStep.Console;
            Assert.Equal("", controller.PairedText);
            await controller.RegisterAsync("192.168.1.253", "12345678");
            Assert.Equal("PS5 paired: PS5-789 (192.168.1.253). Press Continue.", controller.PairedText);
            Assert.NotNull(store.Load<RegisteredConsole>(StoreKeys.Console));
            Assert.Contains("[couchsubs] PS5 kaydı kaydedildi (192.168.1.253): PS5-789", lines);
        }
        finally
        {
            RemotePlayLog.MessageLogged -= Collect;
        }
    }

    /// Ayarlar › Konsol (Mac ile aynı): kurulumdan sonra da PS5 ↔ Xbox geçilir; Microsoft'tan çıkış jetonu siler, Xbox
    /// bağlama kurulumun Xbox adımlarını açar ve Xbox seçilince ana ekrana döner.
    [Fact]
    public void ConsoleKindChangesAfterSetupAndXboxCanBeLinkedAndSignedOut()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.SetupComplete, true);
        store.Save(StoreKeys.ConsoleKindLocked, true);
        store.Save(StoreKeys.XboxToken, "{}");
        var controller = new AppController(new FakeServices { Xbox = new FakeXbox([]) }, store, new MemorySettings(), new FakeSleep(),
            Localizer.ForLanguage("tr"), action => action());
        Assert.False(controller.IsXbox);
        controller.ChangeConsoleKind(GameConsoleKind.Xbox);
        Assert.True(controller.IsXbox);
        Assert.Equal(GameConsoleKind.Xbox, store.Load<GameConsoleKind?>(StoreKeys.ConsoleKind));
        Assert.True(controller.NeedsXboxLink);

        controller.LinkXbox();
        Assert.Equal(OnboardingStep.Console, controller.Step);
        controller.SelectXboxConsole(new XboxConsole("F4", "Salon Xbox", "XboxSeriesX", true));
        Assert.False(controller.NeedsXboxLink);
        controller.Advance();
        Assert.Equal(OnboardingStep.Done, controller.Step);

        controller.SignOutXbox();
        Assert.False(controller.HasXboxAccount);
        Assert.Null(store.Load<string>(StoreKeys.XboxToken));
        Assert.True(controller.NeedsXboxLink);
        Assert.Equal("Salon Xbox", controller.SelectedXboxConsole?.Name);
        controller.LinkXbox();
        Assert.Equal(OnboardingStep.PsnLogin, controller.Step);

        controller.ChangeConsoleKind(GameConsoleKind.PlayStation);
        Assert.False(controller.IsXbox);
        Assert.False(controller.NeedsXboxLink);
    }

    /// Eski sürüm Xbox adını bozuk kaydettiyse (#223) liste sorulunca kayıtlı ad düzelir; konsol yeniden seçilmez.
    [Fact]
    public async Task XboxDiscoveryRepairsSavedConsoleName()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.XboxToken, "{}");
        store.Save(StoreKeys.XboxConsole, new XboxConsole("F4", "Oturma OdasA+ Xbox", "XboxSeriesX", true));
        var xbox = new FakeXbox([new XboxConsole("F4", "Oturma Odası Xbox", "XboxSeriesX", true)]);
        var controller = new AppController(new FakeServices { Xbox = xbox }, store, new MemorySettings(), new FakeSleep(), Localizer.ForLanguage("tr"), action => action());
        await controller.DiscoverXboxConsolesAsync();
        Assert.Equal("Oturma Odası Xbox", controller.SelectedXboxConsole?.Name);
        Assert.Equal("Oturma Odası Xbox", store.Load<XboxConsole>(StoreKeys.XboxConsole)?.Name);
    }

    /// beta.45 öncesi ANSI (1254) okunup bozuk kaydedilen ad (#268) açılışta, liste sorulmadan düzelir; doğru ad değişmez.
    [Theory]
    [InlineData("Oturma OdasÄ± Xbox", "Oturma Odası Xbox")]
    [InlineData("Oturma Odası Xbox", "Oturma Odası Xbox")]
    [InlineData("Salon Xbox", "Salon Xbox")]
    [InlineData("Çalışma Odası", "Çalışma Odası")]
    public void SavedXboxNameMisreadAsAnsiIsRepairedOnLaunch(string saved, string expected)
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.XboxToken, "{}");
        store.Save(StoreKeys.XboxConsole, new XboxConsole("F4", saved, "XboxSeriesX", true));
        var controller = new AppController(new FakeServices(), store, new MemorySettings(), new FakeSleep(), Localizer.ForLanguage("tr"), action => action());
        Assert.Equal(expected, controller.SelectedXboxConsole?.Name);
        Assert.Equal(expected, store.Load<XboxConsole>(StoreKeys.XboxConsole)?.Name);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task XboxFrameRateSettingIsPassedToStreamAndPersisted(bool legacyFrameRate)
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.ConsoleKind, GameConsoleKind.Xbox);
        store.Save(StoreKeys.XboxToken, "{}");
        store.Save(StoreKeys.XboxConsole, new XboxConsole("F4", "Xbox", "XboxSeriesX", true));
        var savedSettings = new MemorySettings();
        savedSettings.Save(new UserSettings { Output = SubtitleOutput.Computer });
        var xbox = new FakeXbox([]);
        var controller = Make(new FakeServices { Xbox = xbox }, store, savedSettings);
        try
        {
            Assert.False(controller.Settings.XboxLegacyFrameRate);
            controller.Settings = controller.Settings with { XboxLegacyFrameRate = legacyFrameRate };
            await controller.StartAsync();
            Assert.Equal([legacyFrameRate], xbox.LegacyFrameRateRequests);
            Assert.Equal(legacyFrameRate, savedSettings.Load().XboxLegacyFrameRate);
        }
        finally { controller.Dispose(); }
    }

    /// <summary>#871: ses ayarı çeviri sürerken değişince akış yeniden kurulmaz (Xbox yeni oturumda hizmetini başlatamıyordu).</summary>
    [Fact]
    public async Task XboxAudioSettingChangesSoundWithoutNewSession()
    {
        var store = new MemoryStore();
        store.Save(StoreKeys.ConsoleKind, GameConsoleKind.Xbox);
        store.Save(StoreKeys.XboxToken, "{}");
        store.Save(StoreKeys.XboxConsole, new XboxConsole("F4", "Xbox", "XboxSeriesX", true));
        var savedSettings = new MemorySettings();
        savedSettings.Save(new UserSettings { Output = SubtitleOutput.Computer });
        var xbox = new FakeXbox([]);
        var controller = Make(new FakeServices { Xbox = xbox }, store, savedSettings);
        try
        {
            await controller.StartAsync();
            Assert.Single(xbox.Streams);
            Assert.True(xbox.Streams[0].PlayAudio);
            controller.Settings = controller.Settings with { XboxAudioOnComputer = false };
            await Task.Delay(50);
            Assert.Single(xbox.Streams);
            Assert.True(xbox.Streams[0].Stream.Started);
            Assert.Equal([false], xbox.Streams[0].Stream.PlayAudioChanges);
        }
        finally { controller.Dispose(); }
    }

    [Fact]
    public async Task PairingTextIsTurkish()
    {
        var controller = new AppController(new FakeServices(), new MemoryStore(), new MemorySettings(), new FakeSleep(), Localizer.ForLanguage("tr"), action => action());
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        await controller.RegisterAsync("192.168.1.253", "12345678");
        Assert.Equal("PS5 eşleşti: PS5-789 (192.168.1.253). Devam'a basın.", controller.PairedText);
    }

    /// Eşleşince sonraki adıma kendiliğinden geçilir; kullanıcı bu arada Geri'ye bastıysa ilerlenmez.
    [Fact]
    public async Task ContinueAfterPairingAdvancesOnlyFromConsoleStep()
    {
        var controller = Make();
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        controller.Step = OnboardingStep.Console;
        controller.ContinueAfterPairing();
        Assert.Equal(OnboardingStep.Console, controller.Step);
        await controller.RegisterAsync("192.168.1.253", "12345678");
        controller.Back();
        controller.ContinueAfterPairing();
        Assert.Equal(OnboardingStep.PsnLogin, controller.Step);
        controller.Step = OnboardingStep.Console;
        controller.ContinueAfterPairing();
        Assert.Equal(OnboardingStep.Tv, controller.Step);
    }

    /// Sony girişi engellenen kullanıcı hesap kimliğini base64 olarak elle yazar; web girişiyle aynı biçimde saklanır.
    [Fact]
    public void ManualAccountIdIsStoredLikeWebLogin()
    {
        var store = new MemoryStore();
        var controller = Make(store: store);
        controller.Step = OnboardingStep.PsnLogin;
        var id = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
        Assert.True(controller.UseManualAccountId($"  {Convert.ToBase64String(id)} "));
        Assert.True(controller.HasAccount);
        Assert.True(controller.CanAdvance);
        Assert.Equal(id, store.Load<byte[]>(StoreKeys.AccountId));
    }

    [Theory]
    [InlineData("")]
    [InlineData("AQIDBAUGBw==")] // 7 bayt
    [InlineData("AQIDBAUGBwgJ")] // 9 bayt
    [InlineData("AQIDBAUGBw!=")]
    [InlineData("1234567890")]
    public void InvalidManualAccountIdIsRejected(string value)
    {
        var store = new MemoryStore();
        var controller = Make(store: store);
        Assert.False(controller.UseManualAccountId(value));
        Assert.False(controller.HasAccount);
        Assert.Null(store.Load<byte[]>(StoreKeys.AccountId));
    }

    /// PS5 hesabı tanımazsa kullanıcıya kodu hangi kullanıcıdan alacağı söylenmeli.
    [Fact]
    public async Task WrongAccountRegistrationExplainsWhatToDo()
    {
        var services = new FakeServices { RegisterError = new RegistrationException(RegistrationFailure.WrongAccount) };
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(AppError.WrongAccount, error.Error);
    }

    [Fact]
    public async Task OtherRegistrationFailureSuggestsNewCode()
    {
        var services = new FakeServices { RegisterError = new RegistrationException(RegistrationFailure.Failed) };
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(AppError.RegistrationFailed, error.Error);
    }

    [Theory]
    [InlineData(RegistrationFailure.NoAnswer, AppError.ConsoleNoAnswer)]
    [InlineData(RegistrationFailure.InUse, AppError.ConsoleInUse)]
    [InlineData(RegistrationFailure.ConsoleCrashed, AppError.ConsoleCrashed)]
    [InlineData(RegistrationFailure.VersionMismatch, AppError.ConsoleVersion)]
    [InlineData(RegistrationFailure.WrongCode, AppError.WrongCode)]
    [InlineData(RegistrationFailure.NoReply, AppError.ConsoleNoReply)]
    [InlineData(RegistrationFailure.Canceled, AppError.ConsoleNoReply)]
    [InlineData(RegistrationFailure.BadAddress, AppError.BadAddress)]
    [InlineData(RegistrationFailure.PairingClosed, AppError.ConsolePairingClosed)]
    [InlineData(RegistrationFailure.ConnectFailed, AppError.ConsoleConnectFailed)]
    [InlineData(RegistrationFailure.NoFreePort, AppError.NoFreePort)]
    public async Task RegistrationFailureMapsToItsOwnMessage(RegistrationFailure failure, AppError expected)
    {
        var services = new FakeServices { RegisterError = new RegistrationException(failure) };
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Equal(expected, error.Error);
        // Genel "kodu kabul etmedi" iletisine düşmez.
        Assert.DoesNotContain(AppException.Describe(AppError.RegistrationFailed, Localizer.ForLanguage("en")), error.Message);
        Assert.Null(controller.Console);
    }

    /// İletide PS5'in kodu ve gönderilecek günlük dosyası yazar.
    [Fact]
    public async Task RegistrationErrorShowsThePs5CodeAndLogFile()
    {
        var services = new FakeServices { RegisterError = new RegistrationException(RegistrationFailure.WrongCode, 0x80108b09, "0x80108b09 (Regist failed, probably invalid PIN)") };
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", "12345678"));
        Assert.Contains("0x80108b09 (Regist failed, probably invalid PIN)", error.Message);
        Assert.Contains(RemotePlayLog.DisplayPath, error.Message);
    }

    [Theory]
    [InlineData("1234")]
    [InlineData("")]
    [InlineData("123456789")]
    [InlineData("1234567O")]
    public async Task PinMustBeEightDigits(string pin)
    {
        var services = new FakeServices();
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("192.168.1.253", pin));
        Assert.Equal(AppError.InvalidPin, error.Error);
        Assert.Null(controller.Console);
        Assert.Null(services.Registered);
    }

    /// PS5'in ekranındaki gibi boşluklu ya da tireli yazılan kod da kabul edilir.
    [Fact]
    public async Task PinWithSpacesIsAccepted()
    {
        var services = new FakeServices();
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        await controller.RegisterAsync(" 192.168.1.253 ", "1234 5678");
        Assert.Equal("192.168.1.253", services.Registered?.Host);
        Assert.Equal(12345678u, services.RegisteredPin);
    }

    /// PSN girişinin her hatası kendi iletisini alır (eskiden hepsi "Giriş tamamlanmadı" idi); Sony'nin hatası ve HTTP
    /// kodu iletide yazar, hesap kaydedilmez.
    [Theory]
    [InlineData(PsnLoginFailure.Refused, 400, AppError.LoginRefused)]
    [InlineData(PsnLoginFailure.RateLimited, 429, AppError.LoginRateLimited)]
    [InlineData(PsnLoginFailure.Http, 503, AppError.LoginServer)]
    [InlineData(PsnLoginFailure.Network, null, AppError.LoginNetwork)]
    [InlineData(PsnLoginFailure.BadResponse, null, AppError.LoginBadResponse)]
    [InlineData(PsnLoginFailure.NoCode, null, AppError.InvalidLogin)]
    public async Task LoginFailureMapsToItsOwnMessage(PsnLoginFailure failure, int? status, AppError expected)
    {
        var services = new FakeServices { LoginError = new PsnAccountException(failure, status, "invalid_grant: Invalid authorization code") };
        var controller = Make(services);
        var error = await Assert.ThrowsAsync<AppException>(() => controller.CompletePsnLoginAsync(new Uri("https://x/?code=x")));
        Assert.Equal(expected, error.Error);
        Assert.Contains("invalid_grant", error.Message);
        if (status is { } code) Assert.Contains($"HTTP {code}", error.Message);
        Assert.Contains(RemotePlayLog.DisplayPath, error.Message);
        Assert.False(controller.HasAccount);
    }

    [Fact]
    public async Task UnexpectedLoginErrorKeepsItsDetail()
    {
        var services = new FakeServices { LoginError = new InvalidOperationException("boom") };
        var controller = Make(services);
        var error = await Assert.ThrowsAsync<AppException>(() => controller.CompletePsnLoginAsync(new Uri("https://x/?code=x")));
        Assert.Equal(AppError.InvalidLogin, error.Error);
        Assert.Contains("boom", error.Message);
    }

    /// Giriş penceresi yönlendirmesiz kapanırsa sessiz kalınmaz; sayfanın sorunu varsa o söylenir.
    [Fact]
    public void ClosedLoginWindowIsExplained()
    {
        var controller = Make();
        Assert.Equal(AppError.LoginWindowClosed, controller.LoginWindowError(null).Error);
        var failed = controller.LoginWindowError("ConnectionAborted");
        Assert.Equal(AppError.LoginPageFailed, failed.Error);
        Assert.Contains("ConnectionAborted", failed.Message);
        Assert.Equal(AppError.LoginRateLimited, controller.LoginWindowError("HTTP 429").Error);
    }

    /// PS5 seçilmeden ya da adres yazılmadan bağlanılırsa "PS5 bulunamadı" denir.
    [Fact]
    public async Task MissingConsoleIsExplained()
    {
        var services = new FakeServices();
        var controller = Make(services);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        var error = await Assert.ThrowsAsync<AppException>(() => controller.RegisterAsync("  ", "12345678"));
        Assert.Equal(AppError.MissingConsole, error.Error);
        Assert.Null(services.Registered);
    }

    [Fact]
    public async Task PairingTvPassesServerAddressAndStoresKey()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("LG TV", "192.168.1.153"));
        Assert.StartsWith("http://", services.LaunchedServer);
        Assert.EndsWith($":{controller.ServerPort}", services.LaunchedServer);
        Assert.Equal("tv-key", store.Load<string>(StoreKeys.TvKey));
        controller.Dispose();
    }

    /// PR #870 incelemesi: TV'nin başlattığı eşleşme onaylanınca TV kaydedilmiyordu (bekçi ve TV kartı çalışmıyordu). Onaylanan
    /// TV elle seçilmiş gibi eşlenir; kullanıcının seçtiği izinli TV değiştirilmez, türü tanınmayan TV kaydedilmez.
    [Fact]
    public async Task ApprovedTvRequestSavesTheTv()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        var controller = Make(services, store);
        Assert.False(controller.HasTv);
        await controller.AdoptPairedTvAsync("192.168.1.40");
        Assert.True(controller.HasTv);
        Assert.Equal(new LgTv("Samsung TV", "192.168.1.40", TvBrand.Samsung), controller.Tv);
        Assert.Equal(new LgTv("Samsung TV", "192.168.1.40", TvBrand.Samsung), store.Load<LgTv>(StoreKeys.Tv));
        Assert.Equal(1, services.PairCount);
        // Kayıtlı, izinli TV varken başka TV'nin isteği onu değiştirmez.
        await controller.AdoptPairedTvAsync("192.168.1.41");
        Assert.Equal("192.168.1.40", controller.Tv?.Host);
        Assert.Equal(1, services.PairCount);
        controller.Dispose();

        var unknown = new FakeServices { Identify = _ => null };
        var other = Make(unknown, new MemoryStore());
        await other.AdoptPairedTvAsync("192.168.1.40");
        Assert.False(other.HasTv);
        Assert.Equal(0, unknown.PairCount);
        other.Dispose();
    }

    [Fact]
    public void PairedTvRuleAndPeerAddress()
    {
        var lg = new LgTv("LG", "192.168.1.30");
        Assert.True(PairedTv.ShouldAdopt("192.168.1.40", null, false));
        Assert.True(PairedTv.ShouldAdopt("192.168.1.40", lg, false));
        Assert.True(PairedTv.ShouldAdopt("192.168.1.40", new LgTv("Android TV", "", TvBrand.AndroidTv), true));
        Assert.False(PairedTv.ShouldAdopt("192.168.1.40", lg, true));
        Assert.False(PairedTv.ShouldAdopt("", null, false));
        Assert.Equal("192.168.1.40", SubtitleAccess.TvHost(System.Net.IPAddress.Parse("::ffff:192.168.1.40")));
        Assert.Equal("192.168.1.40", SubtitleAccess.TvHost(System.Net.IPAddress.Parse("192.168.1.40")));
        Assert.Equal("fe80::1", SubtitleAccess.TvHost(System.Net.IPAddress.Parse("fe80::1%3")));
        Assert.Equal("", SubtitleAccess.TvHost(System.Net.IPAddress.Loopback));
        Assert.Equal("", SubtitleAccess.TvHost(System.Net.IPAddress.IPv6Loopback));
        Assert.Equal("", SubtitleAccess.TvHost(System.Net.IPAddress.Parse("8.8.8.8")));
    }

    /// #40: Samsung jetonla gelen bağlantıda jeton göndermeyince saklı jeton silinmemeli (yoksa TV her seferinde izin sorar).
    [Fact]
    public async Task PairingWithoutNewTokenKeepsSavedToken()
    {
        var services = new FakeServices { PairKey = "" };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvKey, "samsung-token");
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Samsung", "192.168.1.20", TvBrand.Samsung));
        Assert.Equal("samsung-token", store.Load<string>(StoreKeys.TvKey));
        controller.Dispose();
    }

    /// Çeviri modeli (~534 MB) sihirbazın başında arka planda inmeye başlar; model adımına gelindiğinde çoğunlukla hazırdır.
    [Fact]
    public void ModelDownloadStartsInBackgroundAfterWelcome()
    {
        var services = new FakeServices();
        services.Translation.Installed = false;
        services.Translation.DownloadGate = new TaskCompletionSource();
        var controller = Make(services);
        Assert.Equal(0, services.Translation.Downloads);
        controller.Advance();
        Assert.Equal(1, services.Translation.Downloads);
        Assert.True(controller.ModelDownloading);
        services.Translation.DownloadGate.SetResult();
    }

    [Fact]
    public async Task ModelStepWaitsForDownload()
    {
        var services = new FakeServices();
        services.Translation.Installed = false;
        services.Translation.DownloadGate = new TaskCompletionSource();
        var controller = Make(services);
        controller.Advance();
        controller.Step = OnboardingStep.Translation;
        Assert.False(controller.CanAdvance);
        services.Translation.DownloadGate.SetResult();
        await controller.WaitForModelAsync();
        Assert.True(controller.CanAdvance);
        Assert.Equal(1.0, controller.ModelProgress);
    }

    [Fact]
    public async Task OnboardingWalksAllStepsInOrder()
    {
        var controller = Make();
        Assert.Equal(OnboardingStep.Welcome, controller.Step); controller.Advance();
        Assert.Equal(OnboardingStep.SecondAccount, controller.Step); controller.Advance();
        Assert.Equal(OnboardingStep.PsnLogin, controller.Step);
        await controller.CompletePsnLoginAsync(new Uri("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=x"));
        controller.Advance();
        Assert.Equal(OnboardingStep.Console, controller.Step);
        await controller.RegisterAsync("192.168.1.253", "12345678"); controller.Advance();
        Assert.Equal(OnboardingStep.Tv, controller.Step);
        await controller.PairAsync(new LgTv("LG TV", "192.168.1.153")); controller.Advance();
        Assert.Equal(OnboardingStep.Translation, controller.Step); controller.Advance();
        Assert.Equal(OnboardingStep.Test, controller.Step); controller.Advance();
        Assert.Equal(OnboardingStep.BetterTranslation, controller.Step);
        Assert.True(controller.CanAdvance);
        controller.Advance();
        Assert.Equal(OnboardingStep.Done, controller.Step);
        controller.Dispose();
    }

    /// <summary>"Daha iyi çeviri" adımı isteğe bağlıdır: geçilirse ücretsiz çeviri kalır; anahtar kabul edilirse Gemini seçilir.</summary>
    [Fact]
    public void BetterTranslationStepCanBeSkipped()
    {
        var controller = Make();
        controller.Step = OnboardingStep.BetterTranslation;
        Assert.False(controller.UsesFreeGemini);
        Assert.True(controller.CanAdvance);
        controller.Advance();
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(TranslationEngine.Free, controller.Settings.Engine);
        controller.Back();
        Assert.Equal(OnboardingStep.BetterTranslation, controller.Step);
        controller.Back();
        Assert.Equal(OnboardingStep.Test, controller.Step);
    }

    [Fact]
    public async Task BetterTranslationStepSavesTheKeyAndSelectsGemini()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        var controller = Make(services, store);
        controller.Step = OnboardingStep.BetterTranslation;
        var changed = new List<string?>();
        controller.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        var result = await controller.SetAiKeyAsync(AiProvider.Gemini, "  AIza-free  ");
        Assert.Equal(OnlineKeyState.Valid, result.State);
        // Ücretsiz katmandaki varsayılan model denenir.
        Assert.Equal((AiProvider.Gemini, "AIza-free", AiProvider.Gemini.DefaultModel().Id), Assert.Single(services.AiTests));
        Assert.True(AiProvider.Gemini.DefaultModel().FreeTier);
        Assert.Equal("AIza-free", store.Load<string>(StoreKeys.GeminiKey));
        Assert.Equal(TranslationEngine.Gemini, controller.Settings.Engine);
        Assert.True(controller.UsesFreeGemini);
        // Alttaki düğme "Şimdilik geç"ten "Devam"a döner.
        Assert.Contains(nameof(AppController.UsesFreeGemini), changed);
        controller.Advance();
        Assert.Equal(OnboardingStep.Done, controller.Step);
    }

    /// <summary>Yanlış anahtar kaydedilmez, motor değişmez; dakikalık sınıra takılan anahtar geçerlidir ve kaydedilir.</summary>
    [Fact]
    public async Task BetterTranslationStepRejectsAWrongKey()
    {
        var services = new FakeServices { AiTest = new AiTestResult(OnlineKeyState.Invalid) };
        var controller = Make(services);
        controller.Step = OnboardingStep.BetterTranslation;
        Assert.Equal(OnlineKeyState.Invalid, (await controller.SetAiKeyAsync(AiProvider.Gemini, "wrong")).State);
        Assert.False(controller.HasKey(TranslationEngine.Gemini));
        Assert.Equal(TranslationEngine.Free, controller.Settings.Engine);
        Assert.False(controller.UsesFreeGemini);

        services.AiTest = new AiTestResult(OnlineKeyState.QuotaExceeded);
        await controller.SetAiKeyAsync(AiProvider.Gemini, "AIza-busy");
        Assert.True(controller.UsesFreeGemini);
    }

    /// <summary>
    /// Hizmet anahtarı kabul etse de şifreli depoya yazılamazsa (dosya kilitli, DPAPI hatası) kayıt başarılı sayılmaz,
    /// motor değişmez ve ayrı bir ileti gösterilir (Mac'teki Anahtar Zinciri kuralıyla aynı).
    /// </summary>
    [Fact]
    public async Task KeyIsNotReportedSavedWhenTheSecureStoreRejectsIt()
    {
        var store = new MemoryStore();
        var controller = Make(new FakeServices(), store);
        store.RejectWrites = true;
        Assert.Equal(OnlineKeyState.KeychainWriteFailed, (await controller.SetAiKeyAsync(AiProvider.Claude, "claude-key")).State);
        Assert.Equal(OnlineKeyState.KeychainWriteFailed, (await controller.SetDeepLKeyAsync("deepl-key")).State);
        Assert.False(controller.HasKey(TranslationEngine.Claude));
        Assert.False(controller.HasDeepLKey);
        Assert.Equal(TranslationEngine.Free, controller.Settings.Engine);
        Assert.Equal("The API key could not be saved to this computer's secure storage.",
                     OnlineKeyState.KeychainWriteFailed.Describe(TranslationEngine.Claude, Localizer.ForLanguage("en")));
    }

    /// <summary>
    /// Hizmet o an yoğunsa (503, zaman aşımı, dakikalık sınır) anahtar reddedilmedi: kaydedilir. İleti internet
    /// bağlantısını ya da bakiyeyi suçlamaz; yerel modelde ise sunucunun açık olup olmadığı sorulur.
    /// </summary>
    [Fact]
    public async Task BusyServiceStillSavesTheKey()
    {
        var services = new FakeServices { AiTest = new AiTestResult(OnlineKeyState.Busy) };
        var store = new MemoryStore();
        var controller = Make(services, store);
        Assert.Equal(OnlineKeyState.Busy, (await controller.SetAiKeyAsync(AiProvider.Gemini, "AIza-slow")).State);
        Assert.Equal("AIza-slow", store.Load<string>(StoreKeys.GeminiKey));

        var en = Localizer.ForLanguage("en");
        var busy = OnlineKeyState.Busy.Describe(TranslationEngine.Gemini, en);
        Assert.Equal("Gemini is busy or did not answer in time. Try again in a moment, or choose the faster model.", busy);
        Assert.DoesNotContain("internet", OnlineKeyState.Busy.Describe(TranslationEngine.Gemini, Localizer.ForLanguage("tr")));
        Assert.DoesNotContain("bakiye", OnlineKeyState.Busy.Describe(TranslationEngine.Gemini, Localizer.ForLanguage("tr")));
        Assert.Equal(OnlineKeyState.Unreachable.DescribeLocal(null, en), OnlineKeyState.Busy.DescribeLocal(null, en));
    }

    /// <summary>Ayarlardaki "Ücretsiz anahtar al" Gemini'yi seçer; anahtar gelene dek ücretsiz çeviri sürer.</summary>
    [Fact]
    public void ChooseFreeGeminiSelectsGeminiWithoutAKey()
    {
        var controller = Make();
        controller.ChooseFreeGemini();
        Assert.Equal(TranslationEngine.Gemini, controller.Settings.Engine);
        Assert.False(controller.OnlineTranslationActive);
        Assert.False(controller.UsesFreeGemini);
    }

    /// <summary>Yeni metinler ortak metin dosyasında Türkçesiyle durur.</summary>
    [Theory]
    [InlineData("Better translation (free)")]
    [InlineData("Get a free key")]
    [InlineData("Skip for now")]
    [InlineData("For better translation, get a free Gemini key.")]
    [InlineData("Gemini is ready. Subtitles will be translated with Gemini.")]
    [InlineData("Press Get a free key and sign in with your Google account.")]
    [InlineData("Press Create API key and copy the key.")]
    [InlineData("Paste the key here and press Save and test.")]
    [InlineData("The free translation works without the internet but often sounds stiff. Google's Gemini translates much more naturally, and a free Google key is enough.")]
    [InlineData("Subtitle text is sent to Google. With a free key, Google may use it to improve its products, and people at Google may read it. Only the game's subtitles are sent.")]
    [InlineData("The free key has a per-minute limit. When it is reached, that line is translated by the free translation.")]
    public void FreeGeminiStringsAreTranslated(string key) => Assert.NotEqual(key, Localizer.ForLanguage("tr")[key]);

    [Theory]
    [InlineData("The free translation engine could not start on this computer.", "Ücretsiz çeviri motoru bu bilgisayarda açılamadı.")]
    [InlineData("Choose Gemini (free) or DeepL in Settings › Translation.", "Ayarlar › Çeviri'den Gemini (ücretsiz) ya da DeepL seçin.")]
    public void EngineFailureStringsAreTranslated(string key, string turkish) => Assert.Equal(turkish, Localizer.ForLanguage("tr")[key]);
}

public class AppControllerRunTests
{
    private static (AppController Controller, FakeServices Services, FakeSleep Sleep) Ready(FakeServices? services = null)
    {
        services ??= new FakeServices();
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("LG TV", "127.0.0.1"));
        store.Save(StoreKeys.TvKey, "tv-key");
        var sleep = new FakeSleep();
        return (AppControllerTests.Make(services, store, sleep: sleep), services, sleep);
    }

    [Fact]
    public void FreeTranslationDeviceDefaultsToCpuAndReportsGpuFallback()
    {
        var (controller, services, _) = Ready();
        Assert.Equal(TranslationDevice.Cpu, controller.Settings.TranslationDevice);
        Assert.Equal(TranslationDevice.Cpu, services.Translation.SelectedDevice);

        controller.Settings = controller.Settings with { TranslationDevice = TranslationDevice.Gpu };
        Assert.Equal(TranslationDevice.Gpu, services.Translation.SelectedDevice);
        services.Translation.FallBackToCpu();
        Assert.True(controller.GpuFallbackWarning);

        controller.Settings = controller.Settings with { TranslationDevice = TranslationDevice.Cpu };
        Assert.False(controller.GpuFallbackWarning);
        controller.Dispose();
    }

    /// <summary>Ayarlar'daki PS5 giriş şifresi oturuma verilir; yalnız 4 hane kaydedilir, kurulum sıfırlanınca silinir.</summary>
    [Fact]
    public async Task LoginPasscodeIsSavedAndPassedToTheSession()
    {
        var (controller, services, _) = Ready();
        Assert.False(controller.HasLoginPasscode);
        Assert.False(controller.SetLoginPasscode("12a4"));
        Assert.True(controller.SetLoginPasscode(" 4321 "));
        Assert.True(controller.HasLoginPasscode);
        await controller.StartAsync();
        Assert.Equal(["4321"], services.StreamPasscodes);
        controller.Stop();
        controller.RemoveLoginPasscode();
        Assert.False(controller.HasLoginPasscode);
        await controller.StartAsync();
        Assert.Equal(["4321", null], services.StreamPasscodes);
        controller.Stop();
        Assert.True(controller.SetLoginPasscode("1111"));
        controller.ResetSetup();
        Assert.False(controller.HasLoginPasscode);
        controller.Dispose();
    }

    /// <summary>
    /// X'te bildirildi: Remote Play penceresinden okurken altyazı ~10 dakikada bir kesiliyordu. Kullanıcı TV'de oynayıp
    /// bilgisayara dokunmayınca ekran kendi ayarıyla kapanıyor, kapalı ekranda pencere yakalama kare vermiyordu. Pencereden
    /// okunurken ya da altyazı bu ekrandayken ekran açık tutulur; PS5'ten okunup yalnız TV'ye gidiyorsa tutulmaz.
    /// </summary>
    [Fact]
    public async Task DisplayStaysOnWhileReadingAWindowOrShowingOnComputer()
    {
        var (controller, _, sleep) = Ready();
        Assert.Equal(FrameSource.Ps5, controller.Settings.FrameSource);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Tv };
        await controller.StartAsync();
        Assert.True(sleep.Active);
        Assert.False(sleep.DisplayOn);
        // Çeviri sürerken altyazı bilgisayar ekranına da alınırsa ekran açık kalır, geri alınınca yine kapanabilir.
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Both };
        Assert.True(sleep.DisplayOn);
        controller.Settings = controller.Settings with { Output = SubtitleOutput.Tv };
        Assert.False(sleep.DisplayOn);
        controller.Stop();
        Assert.False(sleep.Active);

        controller.Settings = controller.Settings with { FrameSource = FrameSource.RemotePlayWindow };
        await controller.StartAsync();
        Assert.True(sleep.DisplayOn);
        controller.Stop();
        Assert.False(sleep.DisplayOn);
        controller.Dispose();
    }

    /// "İkinci hesap yok mu?": PSN girişi ve PS5 olmadan kurulum biter; görüntü Remote Play penceresinden, altyazı
    /// bilgisayar ekranında. Yeniden açılınca sihirbaz çıkmaz.
    [Fact]
    public void NoSecondAccountReadsRemotePlayWindowAndCompletesSetup()
    {
        var store = new MemoryStore();
        var settings = new MemorySettings();
        var controller = AppControllerTests.Make(store: store, settings: settings);
        controller.Advance();
        Assert.Equal(OnboardingStep.SecondAccount, controller.Step);
        controller.UseRemotePlayWindow();
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(FrameSource.RemotePlayWindow, controller.Settings.FrameSource);
        Assert.Equal(SubtitleOutput.Computer, controller.Settings.Output);
        Assert.False(controller.HasAccount);
        Assert.True(controller.CanStart);
        Assert.Equal(OnboardingStep.Done, AppControllerTests.Make(store: store, settings: settings).Step);
    }

    /// DM'de bildirildi: "Görüntü kaynağı" ayarı bulunamıyordu. Ana ekrandaki satır seçili kaynağı gösterir (Ayarlar'daki
    /// seçeneklerle aynı ad); Xbox'ta da (#853) seçim olduğundan satır vardır.
    [Fact]
    public void PictureSourceTitleFollowsTheSelectedSource()
    {
        var controller = AppControllerTests.Make();
        Assert.Equal("The PS5 (second account)", controller.PictureSourceTitle);
        controller.Settings = controller.Settings with { FrameSource = FrameSource.RemotePlayWindow };
        Assert.Equal("Remote Play window on this PC", controller.PictureSourceTitle);
        controller.Settings = controller.Settings with { FrameSource = FrameSource.CaptureWindow };
        Assert.Equal("OBS projector or game window", controller.PictureSourceTitle);
    }

    /// Pencere modunda kurulmuş, sonra Ayarlar'da PS5 seçilmiş: "Hesabı bağla" görünür, sihirbaz ikinci hesap adımından açılır.
    [Fact]
    public void LinkAccountOpensWizardAtSecondAccount()
    {
        var settings = new MemorySettings();
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer });
        var controller = AppControllerTests.Make(settings: settings);
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.False(controller.NeedsPs5Link);
        controller.Settings = controller.Settings with { FrameSource = FrameSource.Ps5 };
        Assert.True(controller.NeedsPs5Link);
        Assert.False(controller.CanStart);
        controller.LinkPs5Account();
        Assert.Equal(OnboardingStep.SecondAccount, controller.Step);
    }

    /// Remote Play uygulaması kurulu değilse ana ekran bunu ve nereden indirileceğini söyler.
    [Fact]
    public void MissingRemotePlayAppIsReported()
    {
        var settings = new MemorySettings();
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, Output = SubtitleOutput.Computer });
        var services = new FakeServices { RemotePlayIsInstalled = false };
        var controller = AppControllerTests.Make(services, settings: settings);
        Assert.True(controller.RemotePlayMissing);
        Assert.Equal("The Remote Play app isn't installed on this PC. Download it in Settings › Picture source.", controller.Ps5StatusText);
        services.RemotePlayIsInstalled = true;
        Assert.False(controller.RemotePlayMissing);
        Assert.Equal("Reads the Remote Play window on this PC when you start translating.", controller.Ps5StatusText);
    }

    [Fact]
    public void SelectedWindowSetupSkipsPsnPairingButRequiresExplicitTarget()
    {
        var store = new MemoryStore();
        var settings = new MemorySettings();
        var controller = AppControllerTests.Make(store: store, settings: settings);
        controller.Advance();
        Assert.Equal(OnboardingStep.SecondAccount, controller.Step);

        controller.UseCaptureWindow();
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(FrameSource.CaptureWindow, controller.Settings.FrameSource);
        Assert.Equal(SubtitleOutput.Computer, controller.Settings.Output);
        Assert.False(controller.HasAccount);
        Assert.False(controller.CanStart); // Never fall back to scanning the entire desktop.

        var target = new WindowCaptureTarget("obs64", "Fullscreen Projector (Scene)");
        controller.Settings = controller.Settings with { CaptureWindow = target };
        Assert.True(controller.CanStart);
        Assert.Equal(OnboardingStep.Done, AppControllerTests.Make(store: store, settings: settings).Step);
        controller.Dispose();
    }

    [Fact]
    public async Task SelectedWindowStartsAndSwitchesTargetsWithoutOpeningPs5Session()
    {
        var first = new WindowCaptureTarget("obs64", "Fullscreen Projector (Scene)");
        var second = new WindowCaptureTarget("game", "Gameplay");
        var settings = new MemorySettings();
        settings.Save(new UserSettings
        {
            FrameSource = FrameSource.CaptureWindow,
            CaptureWindow = first,
            Output = SubtitleOutput.Computer,
        });
        var services = new FakeServices { RemotePlayIsInstalled = false };
        var controller = AppControllerTests.Make(services: services, settings: settings);

        await controller.StartAsync();
        Assert.Equal([first], services.CaptureWindowStreams);
        Assert.Empty(services.StreamPasscodes);
        Assert.Empty(services.WindowStreams);
        Assert.True(controller.IsRunning);

        controller.Settings = controller.Settings with { CaptureWindow = second };
        for (var i = 0; i < 200 && services.CaptureWindowStreams.Count < 2; i++) await Task.Delay(10);
        Assert.Equal([first, second], services.CaptureWindowStreams);
        Assert.Equal(2, services.Streams.Count);
        Assert.True(controller.IsRunning);
        controller.Dispose();
    }

    /// #853: Xbox seçiliyken OBS/oyun penceresi (Xbox uygulaması, play.xbox.com, capture card) seçilirse CouchSubs Xbox'a
    /// hiç bağlanmaz (Xbox tek bağlantıya izin verir, kullanıcının oturumu düşerdi); Microsoft girişi ve Xbox seçimi gerekmez.
    [Fact]
    public async Task XboxWithSelectedWindowReadsOnlyTheWindowAndNeverConnectsToTheXbox()
    {
        var target = new WindowCaptureTarget("msedge", "Xbox Cloud Gaming");
        var store = new MemoryStore();
        store.Save(StoreKeys.ConsoleKind, GameConsoleKind.Xbox);
        var settings = new MemorySettings();
        settings.Save(new UserSettings { XboxFrameSource = XboxFrameSource.CaptureWindow, CaptureWindow = target, Output = SubtitleOutput.Computer });
        var xbox = new FakeXbox([]);
        var services = new FakeServices { Xbox = xbox };
        var controller = AppControllerTests.Make(services, store, settings);
        try
        {
            Assert.True(controller.IsXbox);
            Assert.True(controller.XboxReadsWindow);
            Assert.False(controller.NeedsXboxLink);
            Assert.True(controller.CanStart);
            Assert.Equal(OnboardingStep.Done, controller.Step);
            Assert.Equal("OBS projector or game window", controller.PictureSourceTitle);

            await controller.StartAsync();
            Assert.True(controller.IsRunning);
            Assert.Equal([target], services.CaptureWindowStreams);
            Assert.Empty(xbox.LegacyFrameRateRequests);

            // Xbox bağlantısına dönülünce giriş ve Xbox seçimi yine gerekir.
            controller.Settings = controller.Settings with { XboxFrameSource = XboxFrameSource.Xbox };
            Assert.False(controller.XboxReadsWindow);
            Assert.True(controller.NeedsXboxLink);
            Assert.False(controller.CanStart);
            Assert.Equal("Xbox (this app connects)", controller.PictureSourceTitle);
        }
        finally { controller.Dispose(); }
    }

    /// #853: sihirbazın Xbox girişi adımındaki "Bilgisayarda Xbox uygulaması/play.xbox.com ile mi oynuyorsunuz?" kurulumu
    /// bitirir; Microsoft girişi istenmez, TV yoksa altyazı bilgisayar ekranında.
    [Fact]
    public void XboxWizardWindowChoiceFinishesSetupWithoutSignIn()
    {
        var controller = AppControllerTests.Make(new FakeServices { Xbox = new FakeXbox([]) });
        controller.SelectConsoleKind(GameConsoleKind.Xbox);
        controller.Advance();
        Assert.Equal(OnboardingStep.PsnLogin, controller.Step);
        controller.UseXboxWindow();
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Equal(XboxFrameSource.CaptureWindow, controller.Settings.XboxFrameSource);
        Assert.Equal(SubtitleOutput.Computer, controller.Settings.Output);
        Assert.False(controller.NeedsXboxLink);
        Assert.False(controller.CanStart);
        controller.Settings = controller.Settings with { CaptureWindow = new WindowCaptureTarget("XboxPcApp", "Xbox") };
        Assert.True(controller.CanStart);
        controller.Dispose();
    }

    /// Remote Play penceresinden okurken PS5 kaydı gerekmez: sihirbaz açılmaz, kurulum kaydı değişmez, çeviri pencere
    /// kaynağıyla (PS5'e bağlanmadan) başlar.
    [Fact]
    public async Task WindowSourceStartsWithoutPairedPs5()
    {
        var settings = new MemorySettings();
        settings.Save(new UserSettings { FrameSource = FrameSource.RemotePlayWindow, RemotePlayApp = RemotePlayApp.Chiaki, Output = SubtitleOutput.Computer });
        var services = new FakeServices();
        var store = new MemoryStore();
        var controller = AppControllerTests.Make(services, store, settings);
        Assert.Equal(OnboardingStep.Done, controller.Step);
        Assert.Null(store.Load<bool?>(StoreKeys.SetupComplete));
        Assert.True(controller.CanStart);
        Assert.Equal("Reads the Remote Play window on this PC when you start translating.", controller.Ps5StatusText);
        await controller.StartAsync();
        Assert.Equal([RemotePlayApp.Chiaki], services.WindowStreams);
        Assert.Empty(services.StreamPasscodes);
        Assert.True(controller.IsRunning);
        controller.Dispose();
    }

    /// Görüntü kaynağı çeviri sürerken değişince çeviri yeni kaynakla yeniden başlar.
    [Fact]
    public async Task ChangingFrameSourceRestartsTranslation()
    {
        var (controller, services, _) = Ready();
        await controller.StartAsync();
        Assert.Single(services.Streams);
        controller.Settings = controller.Settings with { FrameSource = FrameSource.RemotePlayWindow };
        for (var i = 0; i < 200 && services.WindowStreams.Count == 0; i++) await Task.Delay(10);
        Assert.Equal([RemotePlayApp.Automatic], services.WindowStreams);
        Assert.Equal(2, services.Streams.Count);
        Assert.True(controller.IsRunning);
        controller.Dispose();
    }

    /// <summary>
    /// Android TV DHCP'den yeni adres aldı (#985): kurulum TV'yi yeni adreste bulup kaydı güncelliyordu ama çalışan bekçi
    /// eski adresi tutuyor, TV uygulaması hep eski adreste açılmaya çalışılıyordu. Bekçi yeni adresle yeniden kurulur;
    /// eski bekçinin geç gelen açma sonucu yok sayılır.
    /// </summary>
    [Fact]
    public async Task AndroidTvKeeperFollowsTheNewAddressAfterInstall()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = new BundledTvApp("couchsubs-androidtv_0.7.0.apk", "0.7.0");
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("Android TV", "192.168.1.40", TvBrand.AndroidTv));
        store.Save(StoreKeys.TvKey, "tv-key");
        var controller = AppControllerTests.Make(services, store);
        await controller.StartAsync();
        for (var i = 0; i < 200 && controller.TvApp.Kind == TvAppKind.Working; i++) await Task.Delay(10);
        var old = Assert.Single(services.Keepers);
        var staleResult = services.OnOpenResult!;
        Assert.Equal("192.168.1.40", services.KeeperTvs[0].Host);

        services.AndroidHosts.Add("192.168.1.41");
        await controller.RefreshTvAppAsync();
        Assert.Equal("192.168.1.41", controller.Tv?.Host);
        Assert.Equal(2, services.Keepers.Count);
        Assert.False(old.Running);
        Assert.True(services.Keepers[1].Running);
        Assert.Equal("192.168.1.41", services.KeeperTvs[1].Host);
        staleResult(TvOpenProblem.Unreachable);
        Assert.False(controller.HasTvOpenReason);

        // Adres değişmeyen denetim bekçiyi yenilemez.
        await controller.RefreshTvAppAsync();
        Assert.Equal(2, services.Keepers.Count);
        controller.Dispose();
    }

    [Fact]
    public async Task DoubleStartCreatesOneSession()
    {
        var (controller, services, _) = Ready();
        await Task.WhenAll(controller.StartAsync(), controller.StartAsync());
        Assert.Single(services.Streams);
        Assert.Single(services.Keepers);
        Assert.True(controller.IsRunning);
        controller.Dispose();
    }

    // "TV'de test et": TV uygulaması bağlı değilse önce TV'de açılır (Samsung 65S95F'de TV'ye hiçbir şey gelmiyordu).
    private static (AppController Controller, FakeServices Services) SamsungReady()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("Samsung", "127.0.0.1", TvBrand.Samsung));
        store.Save(StoreKeys.TvKey, "samsung-token");
        var controller = AppControllerTests.Make(services, store);
        controller.TestTvWait = TimeSpan.FromMilliseconds(300);
        return (controller, services);
    }

    /// Mobil sürümü deneyen kullanıcı (21 Kas): "ilk başta olmadı, TV'den de uygulamayı açmak lazımmış". TV uygulaması
    /// bağlı değilken ana ekran CouchSubs'ın TV'de nerede olduğunu, otomatik açmanın neden olmadığını ve
    /// "Otomatik açmayı dene"yi gösterir.
    [Fact]
    public async Task HomeSaysWhereToOpenTheTvAppAndWhyAutoOpenFailed()
    {
        var (controller, services) = SamsungReady();
        Assert.False(controller.ShowTvOpenHint);
        await controller.StartAsync();
        var keeper = Assert.Single(services.Keepers);
        Assert.True(controller.ShowTvOpenHint);
        Assert.Contains("app list", controller.TvOpenHintText);
        Assert.False(controller.HasTvOpenReason);
        services.OnOpenResult!(TvOpenProblem.Unreachable);
        Assert.True(controller.HasTvOpenReason);
        Assert.Contains("didn't answer", controller.TvOpenReasonText);
        controller.RetryTvOpen();
        Assert.False(controller.HasTvOpenReason);
        Assert.Equal(1, keeper.Reconnects);
        services.OnOpenResult!(TvOpenProblem.Unreachable);
        controller.Stop();
        Assert.False(controller.ShowTvOpenHint);
        Assert.False(controller.HasTvOpenReason);
        controller.Dispose();
    }

    [Fact]
    public void OpenProblemDependsOnTheSavedKey()
    {
        Assert.Equal(TvOpenProblem.NotPaired, TvOpenText.Shown(TvOpenProblem.Unreachable, TvBrand.Lg, hasKey: false));
        Assert.Equal(TvOpenProblem.Unreachable, TvOpenText.Shown(TvOpenProblem.Unreachable, TvBrand.Samsung, hasKey: true));
        Assert.Equal(TvOpenProblem.DebugOff, TvOpenText.Shown(TvOpenProblem.DebugOff, TvBrand.AndroidTv, hasKey: false));
        Assert.Null(TvOpenText.Shown(null, TvBrand.Lg, hasKey: false));
        Assert.Contains("Apps", TvOpenText.OpenOnTv(TvBrand.AndroidTv));
        foreach (var problem in Enum.GetValues<TvOpenProblem>())
            Assert.Equal(TvOpenText.Reason(problem), Localizer.ForLanguage("en")[TvOpenText.Reason(problem)!]);
        var turkish = Localizer.ForLanguage("tr");
        Assert.Equal("Otomatik açmayı dene", turkish[TvOpenText.TryButton]);
        Assert.StartsWith("Her oyunda", turkish[TvOpenText.WizardNote]);
        Assert.StartsWith("CouchSubs TV'de", turkish[TvOpenText.OpenOnTv(TvBrand.Lg)]);
    }

    [Fact]
    public async Task TestOnTvOpensTheTvAppWhenTranslationIsNotRunning()
    {
        var (controller, services) = SamsungReady();
        await controller.SendTestSubtitleAsync();
        var keeper = Assert.Single(services.Keepers);
        // Geçici bekçi bekleme bitince kapanır; çeviri başlamadan TV'ye dokunmaya devam etmez.
        Assert.False(keeper.Running);
        Assert.False(controller.OpeningTvAppForTest);
        controller.Dispose();
    }

    [Fact]
    public async Task TestOnTvAsksTheRunningKeeperToOpenTheTvApp()
    {
        var (controller, services) = SamsungReady();
        await controller.StartAsync();
        var keeper = Assert.Single(services.Keepers);
        await controller.SendTestSubtitleAsync();
        Assert.Single(services.Keepers);
        Assert.Equal(1, keeper.Reconnects);
        Assert.True(keeper.Running);
        controller.Dispose();
    }

    /// X @Eaglaris (20 Kas): çeviri sürmeden "TV'de test et"e basılınca Android TV 0.9.34'ün eşleştirme isteği 409 ile
    /// reddediliyordu; TV "Eşleştirme tamamlanmadı" yazıyor, deneme altyazısı hiç çıkmıyordu. Deneme onay penceresini açar.
    [Fact]
    public async Task TestOnTvOpensThePairingWindowForAnAndroidTv()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        store.Save(StoreKeys.Tv, new LgTv("Android TV", "127.0.0.1", TvBrand.AndroidTv));
        var controller = AppControllerTests.Make(services, store);
        controller.TestPairWait = TimeSpan.FromMilliseconds(300);
        SubtitlePairing.Ticket? asked = null;
        controller.TvPairingRequested += ticket => asked = ticket;
        await controller.SendTestSubtitleAsync();
        Assert.False(controller.OpeningTvAppForTest);
        using var http = new HttpClient();
        using var response = await http.PostAsync($"http://127.0.0.1:{controller.ServerPort}/pair", null);
        Assert.Equal(System.Net.HttpStatusCode.OK, response.StatusCode);
        Assert.NotNull(asked);
        Assert.True(controller.ResolveTvPairing(asked!.Id, true));
        controller.Dispose();
    }

    /// #40: bekçinin bağlantısında TV yeni jeton verirse saklanır; sonraki açılışta TV yeniden izin sormaz.
    [Fact]
    public async Task KeeperSavesNewTvToken()
    {
        var services = new FakeServices();
        var store = new MemoryStore();
        store.Save(StoreKeys.AccountId, Enumerable.Repeat((byte)1, 8).ToArray());
        store.Save(StoreKeys.Console, new RegisteredConsole("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray()));
        store.Save(StoreKeys.Tv, new LgTv("Samsung", "127.0.0.1", TvBrand.Samsung));
        store.Save(StoreKeys.TvKey, "");
        var controller = AppControllerTests.Make(services, store);
        await controller.StartAsync();
        Assert.NotNull(services.OnKey);
        services.OnKey!("new-token");
        Assert.Equal("new-token", store.Load<string>(StoreKeys.TvKey));
        controller.Dispose();
    }

    [Fact]
    public async Task RunningPreventsIdleSleep()
    {
        var (controller, _, sleep) = Ready();
        await controller.StartAsync();
        Assert.True(sleep.Active);
        controller.Stop();
        Assert.False(sleep.Active);
        controller.Dispose();
    }

    [Fact]
    public async Task MovedConsoleAddressIsKept()
    {
        var (controller, services, _) = Ready();
        await controller.StartAsync();
        var moved = controller.Console!.WithHost("192.168.1.77");
        services.Streams[0].EmitMoved(moved);
        Assert.Equal("192.168.1.77", controller.Console!.Host);
        controller.Dispose();
    }

    /// <summary>Görüntü bir dakikadır geliyor ama tek satır yok: "oyunun kendi altyazısını açın" ipucu (#503, #566, #572).</summary>
    [Fact]
    public async Task SubtitleOffTipAppearsAfterAMinuteOfFramesAndResetsWhenConnectionDrops()
    {
        var (controller, services, _) = Ready();
        var now = new DateTime(2026, 11, 20, 12, 0, 0, DateTimeKind.Utc);
        controller.Clock = () => now;
        await controller.StartAsync();
        var stream = services.Streams[0];
        stream.Emit(SessionState.Streaming);
        var frame = new Frame(new byte[4 * 4 * 4], 4, 4, 16);
        stream.Emit(frame);
        now += TimeSpan.FromSeconds(59);
        stream.Emit(frame);
        Assert.False(controller.ShowsSubtitleOffTip);
        now += TimeSpan.FromSeconds(2);
        stream.Emit(frame);
        Assert.True(controller.ShowsSubtitleOffTip);
        // Bağlantı kopunca ipucu kalkar, görüntü süresi baştan sayılır.
        stream.Emit(SessionState.Disconnected(DisconnectKind.Network));
        Assert.False(controller.ShowsSubtitleOffTip);
        stream.Emit(SessionState.Streaming);
        stream.Emit(frame);
        now += TimeSpan.FromSeconds(30);
        stream.Emit(frame);
        Assert.False(controller.ShowsSubtitleOffTip);
        controller.Stop();
        Assert.False(controller.ShowsSubtitleOffTip);
        controller.Dispose();
    }

    [Fact]
    public async Task DisconnectClearsSubtitleOnTv()
    {
        var (controller, services, _) = Ready();
        await controller.StartAsync();
        using var http = new HttpClient();
        using var response = await http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        await Task.Delay(200);
        services.Streams[0].Emit(SessionState.Disconnected(DisconnectKind.Network));
        var sawClear = false;
        while (await reader.ReadLineAsync() is { } line)
            if (line == "event: clear") { sawClear = true; break; }
        Assert.True(sawClear);
        controller.Dispose();
    }

    /// TV'nin aldığı olay satırlarını arka planda toplar.
    private static (List<string> Lines, Task Reading) CollectEvents(StreamReader reader)
    {
        var lines = new List<string>();
        var reading = Task.Run(async () =>
        {
            try
            {
                while (await reader.ReadLineAsync() is { } line)
                    lock (lines) lines.Add(line);
            }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        });
        return (lines, reading);
    }

    private static int Count(List<string> lines, string line)
    {
        lock (lines) return lines.Count(l => l == line);
    }

    /// #268: ayar değişikliğiyle yeniden başlatmada TV uygulaması kapanmaz; kullanıcı durdurunca kapanır.
    [Fact]
    public async Task TvAppExitsOnlyWhenUserStops()
    {
        var (controller, services, _) = Ready();
        await controller.StartAsync();
        using var http = new HttpClient();
        using var response = await http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var (lines, reading) = CollectEvents(reader);
        for (var i = 0; i < 200 && controller.TvClients == 0; i++) await Task.Delay(10);

        controller.Settings = controller.Settings with { FrameSource = FrameSource.RemotePlayWindow };
        for (var i = 0; i < 200 && services.Streams.Count < 2; i++) await Task.Delay(10);
        Assert.True(controller.IsRunning);
        await Task.Delay(300);
        Assert.Equal(0, Count(lines, "event: exit"));

        controller.Stop();
        for (var i = 0; i < 300 && Count(lines, "event: exit") == 0; i++) await Task.Delay(10);
        Assert.Equal(1, Count(lines, "event: exit"));
        controller.Dispose();
        // Okuyucu, arka planda okuma sürerken kapatılırsa HttpContentReadStream.Dispose NullReferenceException atar.
        await reading.WaitAsync(TimeSpan.FromSeconds(5));
    }

    /// Çeviri sürerken TV bağlantısı düşünce TV durumu "Yeniden bağlanılıyor…" der; TV bağlanınca ya da 60 sn sonra kalkar.
    [Fact]
    public async Task LostTvShowsReconnectingUntilItReturnsOrTimesOut()
    {
        var (controller, _, _) = Ready();
        var now = DateTime.UtcNow;
        controller.Clock = () => now;
        await controller.StartAsync();
        using var http = new HttpClient();
        var first = await http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        for (var i = 0; i < 200 && controller.TvClients == 0; i++) await Task.Delay(10);
        Assert.Equal(1, controller.TvClients);
        Assert.False(controller.TvReconnecting);

        first.Dispose();
        for (var i = 0; i < 300 && controller.TvClients > 0; i++) await Task.Delay(10);
        Assert.True(controller.TvReconnecting);
        if (controller.HasTv) Assert.Equal("Reconnecting…", controller.TvStatusText);

        using var second = await http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        for (var i = 0; i < 200 && controller.TvClients == 0; i++) await Task.Delay(10);
        Assert.False(controller.TvReconnecting);
        second.Dispose();
        for (var i = 0; i < 300 && controller.TvClients > 0; i++) await Task.Delay(10);
        Assert.True(controller.TvReconnecting);

        now += TimeSpan.FromSeconds(61);
        await controller.CheckConnectionsAsync();
        Assert.False(controller.TvReconnecting);
        controller.Dispose();
    }

    /// #268: uygulama kapanırken çıkış mesajı sunucu kapanmadan TV'ye yazılır.
    [Fact]
    public async Task DisposeSendsTvExitBeforeServerCloses()
    {
        var (controller, _, _) = Ready();
        await controller.StartAsync();
        using var http = new HttpClient();
        using var response = await http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var (lines, reading) = CollectEvents(reader);
        for (var i = 0; i < 200 && controller.TvClients == 0; i++) await Task.Delay(10);

        controller.Dispose();
        await reading.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(1, Count(lines, "event: exit"));
    }

    /// Çeviri sürerken altyazı TV'den kaldırılınca TV uygulaması kapanır.
    [Fact]
    public async Task RemovingTvOutputExitsTvApp()
    {
        var (controller, _, _) = Ready();
        await controller.StartAsync();
        using var http = new HttpClient();
        using var response = await http.GetAsync($"http://127.0.0.1:{controller.ServerPort}/events", HttpCompletionOption.ResponseHeadersRead);
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync());
        var (lines, reading) = CollectEvents(reader);
        for (var i = 0; i < 200 && controller.TvClients == 0; i++) await Task.Delay(10);

        controller.Settings = controller.Settings with { Output = SubtitleOutput.Computer };
        for (var i = 0; i < 300 && Count(lines, "event: exit") == 0; i++) await Task.Delay(10);
        Assert.Equal(1, Count(lines, "event: exit"));
        Assert.True(controller.IsRunning);
        controller.Dispose();
        await reading.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task PendingTvPairingIsVisibleUntilAnswered()
    {
        // Linux paneli onay penceresi açamaz; bekleyen isteği bu soruyla gösterir.
        var controller = AppControllerTests.Make();
        SubtitlePairing.Ticket? asked = null;
        controller.TvPairingRequested += ticket => asked = ticket;
        await controller.OpenTvPairingAsync();
        using var http = new HttpClient();
        using var created = await http.PostAsync($"http://127.0.0.1:{controller.ServerPort}/pair", null);
        Assert.Equal(200, (int)created.StatusCode);
        Assert.NotNull(asked);
        Assert.True(controller.IsTvPairingPending(asked!.Id));
        Assert.False(controller.IsTvPairingPending("not-the-request-secret"));
        Assert.True(controller.ResolveTvPairing(asked.Id, true));
        Assert.False(controller.IsTvPairingPending(asked.Id));
        controller.Dispose();
    }

    [Fact]
    public async Task TvRetryReplacesTheShownRequest()
    {
        // TV'de Tamam ile yeniden denenince bekleyen istek yenisiyle değişir; eski pencereden verilen onay yok sayılır,
        // yeni istek bekler ve onaylanınca anahtar TV'ye döner (Mac ve iPhone ile aynı).
        var controller = AppControllerTests.Make();
        var asked = new List<SubtitlePairing.Ticket>();
        controller.TvPairingRequested += asked.Add;
        await controller.OpenTvPairingAsync();
        using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{controller.ServerPort}") };
        using (var first = await http.PostAsync("/pair", null)) Assert.Equal(200, (int)first.StatusCode);
        using (var tooSoon = await http.PostAsync("/pair", null)) Assert.Equal(409, (int)tooSoon.StatusCode);
        await Task.Delay(TimeSpan.FromMilliseconds(SubtitlePairing.SupersedeAfterMs + 100));
        using var second = await http.PostAsync("/pair", null);
        Assert.Equal(200, (int)second.StatusCode);
        Assert.Equal(2, asked.Count);
        Assert.Equal(asked[1], controller.PendingTvPairing);
        Assert.False(controller.ResolveTvPairing(asked[0].Id, true));
        Assert.Equal(asked[1], controller.PendingTvPairing);
        Assert.True(controller.ResolveTvPairing(asked[1].Id, true));
        Assert.Null(controller.PendingTvPairing);
        Assert.Contains("approved", await http.GetStringAsync("/pair?id=" + asked[1].Id));
        controller.Dispose();
    }

    [Fact]
    public void SettingsArePersistedOutsideTheSecureStore()
    {
        var store = new MemoryStore();
        var settings = new MemorySettings();
        var controller = AppControllerTests.Make(store: store, settings: settings);
        controller.Settings = controller.Settings with { Style = new SubtitleStyle(58, 7) };
        // Görünüm ayarları ayrı; kurulum durumu ve TV erişim anahtarı güvenli depodadır.
        Assert.Equal(new[] { StoreKeys.SetupComplete, StoreKeys.SubtitleAccessKey }.Order(), store.Values.Keys.Order());
        Assert.Equal(58, AppControllerTests.Make(store: store, settings: settings).Settings.Style.FontSize);
    }

    [Fact]
    public async Task ChangingTextRecognitionWhileRunningRebuildsPipelineWithTheNewReader()
    {
        var (controller, services, _) = Ready();
        await controller.StartAsync();
        controller.Settings = controller.Settings with { OcrEngine = OcrEngine.Advanced };
        Assert.Equal([OcrEngine.Windows, OcrEngine.Advanced], services.ReaderEngines);
        controller.Dispose();
    }

    [Fact]
    public async Task DownloadingTheAdvancedModelWhileItIsChosenSwitchesTheReader()
    {
        var (controller, services, _) = Ready();
        services.OcrModel = new FakeOcrModel();
        controller.Settings = controller.Settings with { OcrEngine = OcrEngine.Advanced };
        await controller.StartAsync();
        Assert.False(controller.AdvancedOcrInstalled);
        await controller.DownloadAdvancedOcrAsync();
        Assert.True(controller.AdvancedOcrInstalled);
        Assert.Null(controller.AdvancedOcrError);
        Assert.Equal([OcrEngine.Advanced, OcrEngine.Advanced], services.ReaderEngines);
        controller.Dispose();
    }

    [Fact]
    public async Task AFailedAdvancedModelDownloadIsReported()
    {
        var (controller, services, _) = Ready();
        services.OcrModel = new FakeOcrModel { Error = new HttpRequestException("offline") };
        await controller.DownloadAdvancedOcrAsync();
        Assert.False(controller.AdvancedOcrInstalled);
        Assert.Equal("offline", controller.AdvancedOcrError);
        Assert.False(controller.AdvancedOcrDownloading);
        controller.Dispose();
    }

    [Fact]
    public async Task ChangingLanguageWhileRunningRebuildsPipeline()
    {
        var (controller, services, _) = Ready();
        await controller.StartAsync();
        Assert.Equal("en", controller.ActiveSourceLanguage);
        controller.Settings = controller.Settings with { SourceLanguage = "ja" };
        Assert.Equal("ja", controller.ActiveSourceLanguage);
        Assert.Equal(["en", "ja"], services.ReaderLanguages);
        controller.Dispose();
    }

    /// Oyun dilinin paketi yokken Windows sistemin diliyle okur; okuma sürse de ana ekran uyarır.
    [Fact]
    public async Task OcrFallingBackToSystemLanguageIsReported()
    {
        var (controller, _, _) = Ready(new FakeServices { HasOcrPack = false });
        await controller.StartAsync();
        Assert.True(controller.OcrMissing);
        controller.Dispose();
    }

    /// Hızlı ses (Windows'un Türkçe sesi) indirme beklemez; doğal ses indirilmemişken de dublaj hazırdır.
    [Fact]
    public void FastVoiceNeedsNoDownload()
    {
        var services = new FakeServices { Dubbing = new FakeDubbingModel(installed: false), FastDubbing = new FakeDubbingModel(installed: true) };
        var (controller, _, _) = Ready(services);
        Assert.True(controller.DubbingAvailable);
        Assert.False(controller.DubbingInstalled);
        controller.Settings = controller.Settings with { Dubbing = controller.Settings.Dubbing with { Engine = DubbingEngine.Fast } };
        Assert.True(controller.DubbingInstalled);
        controller.Dispose();
    }

    /// DeepL anahtarı yalnız denenip kabul edilirse saklanır; reddedilen anahtar ne saklanır ne çeviriyi açar.
    [Fact]
    public async Task RejectedDeepLKeyIsNotSaved()
    {
        var services = new FakeServices { KeyCheck = new OnlineKeyCheck(OnlineKeyState.Invalid) };
        var (controller, _, _) = Ready(services);
        var check = await controller.SetDeepLKeyAsync("  wrong  ");
        Assert.Equal(OnlineKeyState.Invalid, check.State);
        Assert.Equal(["wrong"], services.CheckedKeys);
        Assert.False(controller.HasDeepLKey);
        Assert.False(controller.Settings.OnlineTranslation);
        controller.Dispose();
    }

    /// DeepL 429 (çok sık istek) anahtarı reddetmez: anahtar kaydedilir (Mac, iPhone ve Android ile aynı); görünmez
    /// karakterler denemeden önce silinir.
    [Fact]
    public async Task RateLimitedDeepLKeyIsSavedAndCleaned()
    {
        var services = new FakeServices { KeyCheck = new OnlineKeyCheck(OnlineKeyState.Busy, Reason: OnlineKeyReason.RateLimited, Code: 429) };
        var (controller, _, _) = Ready(services);
        var check = await controller.SetDeepLKeyAsync("ab c​:fx\n");
        Assert.Equal(OnlineKeyState.Busy, check.State);
        Assert.Equal(["abc:fx"], services.CheckedKeys);
        Assert.True(controller.HasDeepLKey);
        controller.Dispose();
    }

    /// Geçerli anahtarla çeviri DeepL'e geçer; cihaz üstü model inmemiş olsa da çeviri hazır sayılır.
    [Fact]
    public async Task AcceptedDeepLKeyTurnsOnlineTranslationOn()
    {
        var services = new FakeServices();
        services.Translation.Installed = false;
        var (controller, _, _) = Ready(services);
        await controller.SetDeepLKeyAsync("key:fx");
        Assert.True(controller.HasDeepLKey);
        Assert.True(controller.Settings.OnlineTranslation);
        Assert.Equal(TranslatorStatus.Ready, controller.TranslatorStatus);

        await controller.StartAsync();
        Assert.Equal("key:fx", Assert.Single(services.OnlineTranslators).Key);
        Assert.Null(services.OnlineTranslators[0].Fallback);

        controller.RemoveDeepLKey();
        Assert.False(controller.HasDeepLKey);
        Assert.False(controller.Settings.OnlineTranslation);
        Assert.Equal(TranslatorStatus.NeedsDownload, controller.TranslatorStatus);
        controller.Dispose();
    }

    /// Ücretsiz motor açılamazsa çeviri yine başlar ve ana ekranda uyarı çıkar.
    [Fact]
    public async Task StartSurvivesFreeEngineThatCannotBeCreated()
    {
        var services = new FakeServices();
        services.Translation.CreateError = new FileNotFoundException("CTranslate2 runtime is missing");
        var (controller, _, _) = Ready(services);

        await controller.StartAsync();

        Assert.True(controller.IsRunning);
        Assert.Equal(TranslatorStatus.EngineFailed, controller.TranslatorStatus);
        controller.Dispose();
    }

    /// Motor ısınırken açılamadı: uyarı hemen çıkar; çevrimiçi motor seçilince kalkar ve açılamayan motor yedek olmaz.
    [Fact]
    public async Task FreeEngineFailureShowsWarningUntilAnOnlineEngineIsChosen()
    {
        var services = new FakeServices();
        var (controller, _, _) = Ready(services);
        await controller.StartAsync();
        Assert.Equal(TranslatorStatus.Ready, controller.TranslatorStatus);

        services.Translation.Fail();
        Assert.Equal(TranslatorStatus.EngineFailed, controller.TranslatorStatus);

        await controller.SetDeepLKeyAsync("key:fx");
        Assert.Equal(TranslatorStatus.Ready, controller.TranslatorStatus);
        var (_, fallback) = Assert.Single(services.OnlineTranslators);
        Assert.Null(fallback);

        controller.RemoveDeepLKey();
        Assert.Equal(TranslatorStatus.EngineFailed, controller.TranslatorStatus);
        controller.Dispose();
    }

    /// Yapay zekâ anahtarı yalnız kabul edilirse saklanır; seçilen model ve anahtar çevirmene gider.
    [Fact]
    public async Task AiKeyIsSavedOnlyWhenAcceptedAndSelectsTheEngine()
    {
        var services = new FakeServices { AiTest = new AiTestResult(OnlineKeyState.Invalid) };
        var (controller, _, _) = Ready(services);
        Assert.Equal(OnlineKeyState.Invalid, (await controller.SetAiKeyAsync(AiProvider.Claude, " wrong ")).State);
        Assert.Equal((AiProvider.Claude, "wrong", "claude-haiku-5-5"), Assert.Single(services.AiTests));
        Assert.False(controller.HasKey(TranslationEngine.Claude));
        Assert.Equal(TranslationEngine.Free, controller.Settings.Engine);

        services.AiTest = new AiTestResult(OnlineKeyState.Valid, "KRATOS: Şimdi gidiyoruz.");
        controller.Settings = controller.Settings.WithModel(AiProvider.Claude, "claude-sonnet-5-5");
        await controller.SetAiKeyAsync(AiProvider.Claude, "sk-good");
        Assert.True(controller.HasKey(TranslationEngine.Claude));
        Assert.Equal(TranslationEngine.Claude, controller.Settings.Engine);
        Assert.False(controller.HasDeepLKey);

        await controller.StartAsync();
        Assert.Equal((AiProvider.Claude, "sk-good", "claude-sonnet-5-5"), Assert.Single(services.AiTranslators));
        Assert.Equal("", Assert.Single(services.AiInstructions));
        // Ek talimat değişince çeviri hattı yeni talimatla kurulur (#306).
        controller.Settings = controller.Settings with { AiInstruction = "Be blunt." };
        Assert.Equal("Be blunt.", services.AiInstructions[^1]);
        Assert.Empty(services.OnlineTranslators);


        controller.RemoveKey(TranslationEngine.Claude);
        Assert.False(controller.HasKey(TranslationEngine.Claude));
        Assert.Equal(TranslationEngine.Free, controller.Settings.Engine);
        controller.Dispose();
    }

    /// Yerel model anahtarsız hazırdır; "Bağlantıyı dene" ayardaki adres ve modelle gider, yazılan anahtarı yalnız sunucu
    /// kabul ederse saklar; çevirmene sunucu ve anahtar gider; anahtar kaldırılınca yerel model seçili kalır.
    [Fact]
    public async Task LocalModelNeedsNoKey()
    {
        var services = new FakeServices();
        var (controller, _, _) = Ready(services);
        controller.Settings = controller.Settings.WithEngine(TranslationEngine.Local);
        Assert.True(controller.IsReady(TranslationEngine.Local));
        Assert.True(controller.OnlineTranslationActive);
        Assert.False(controller.HasKey(TranslationEngine.Local));

        controller.Settings = controller.Settings with { LocalAiBaseUrl = LocalAiServer.LmStudioUrl, LocalAiModel = " qwen2.5-7b-instruct " };
        Assert.Equal(OnlineKeyState.Valid, (await controller.TestLocalAiAsync()).State);
        var (server, key) = Assert.Single(services.LocalTests);
        Assert.Equal("http://127.0.0.1:1234/v1/chat/completions", server.ChatUrl.AbsoluteUri);
        Assert.Equal("qwen2.5-7b-instruct", server.Model);
        Assert.Equal("", key);
        Assert.False(controller.HasKey(TranslationEngine.Local));

        services.AiTest = new AiTestResult(OnlineKeyState.Invalid);
        await controller.TestLocalAiAsync("wrong");
        Assert.False(controller.HasKey(TranslationEngine.Local));
        services.AiTest = new AiTestResult(OnlineKeyState.Valid, "KRATOS: Şimdi gidiyoruz.");
        await controller.TestLocalAiAsync(" lm-key ");
        Assert.True(controller.HasKey(TranslationEngine.Local));
        Assert.Equal(TranslationEngine.Local, controller.Settings.Engine);

        await controller.StartAsync();
        var made = Assert.Single(services.LocalTranslators);
        Assert.Equal("local:localhost:1234/qwen2.5-7b-instruct", made.Server.EngineId);
        Assert.Equal("lm-key", made.Key);
        Assert.Empty(services.AiTranslators);

        controller.RemoveKey(TranslationEngine.Local);
        Assert.False(controller.HasKey(TranslationEngine.Local));
        Assert.Equal(TranslationEngine.Local, controller.Settings.Engine);

        // Geçersiz adreste yerel model hazır sayılmaz; çeviri ücretsiz motorla sürer.
        controller.Settings = controller.Settings with { LocalAiBaseUrl = "ftp://nowhere" };
        Assert.False(controller.OnlineTranslationActive);
        Assert.Equal(OnlineKeyState.Unreachable, (await controller.TestLocalAiAsync()).State);
        controller.Dispose();
    }

    /// Listede olmayan kayıtlı model (eski sürümün boş alanı, elle yazılmış ad) varsayılana döner ve hemen kaydedilir.
    [Fact]
    public void UnknownSavedModelFallsBackToDefaultAndIsSaved()
    {
        var settingsStore = new MemorySettings();
        settingsStore.Save(new UserSettings { OpenAiModel = "gpt-4o", GeminiModel = "", ClaudeModel = "claude-sonnet-5-5" });
        var controller = AppControllerTests.Make(settings: settingsStore);
        Assert.Equal("gpt-6-luna", controller.Settings.OpenAiModel);
        Assert.Equal("gemini-3.5-flash-lite", controller.Settings.GeminiModel);
        Assert.Equal("claude-sonnet-5-5", controller.Settings.ClaudeModel);
        Assert.Equal(controller.Settings, settingsStore.Saved);
        controller.Dispose();
    }

    /// Eski sürümlerin ayarı (yalnız DeepL açık/kapalı) DeepL olarak açılır.
    [Fact]
    public void OldSettingsOpenWithDeepL()
    {
        var old = System.Text.Json.JsonSerializer.Deserialize<UserSettings>("""{"OnlineTranslation":true}""")!;
        Assert.Equal(TranslationEngine.DeepL, old.Engine);
        var saved = System.Text.Json.JsonSerializer.Serialize(new UserSettings().WithEngine(TranslationEngine.Gemini));
        Assert.Contains("\"OnlineEngine\":\"Gemini\"", saved);
        Assert.Equal(TranslationEngine.Gemini, System.Text.Json.JsonSerializer.Deserialize<UserSettings>(saved)!.Engine);
        Assert.Equal(TranslationEngine.Free, new UserSettings().WithEngine(TranslationEngine.Gemini).WithEngine(TranslationEngine.Free).Engine);
    }

    /// Windows'ta oyun dilinin OCR paketi yoksa ana ekran bunu söyler.
    [Fact]
    public async Task MissingOcrLanguageIsReported()
    {
        var (controller, _, _) = Ready(new FakeServices { HasOcr = false });
        await controller.StartAsync();
        Assert.True(controller.OcrMissing);
        controller.Dispose();
    }

    [Fact]
    public void LoginPasscodeIsExplained()
    {
        var text = Localizer.ForLanguage("en");
        Assert.Equal("The PS5 asks for this account's login passcode. Enter it in Settings, or turn off this account's login passcode on the PS5.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.LoginPasscode), true, text));
        Assert.Equal("The PS5 didn't accept the login passcode in Settings. Correct it, or turn off this account's login passcode on the PS5.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.LoginPasscodeIncorrect), true, text));
        Assert.Equal("PS5 bu hesap için giriş şifresi istiyor. Ayarlar'dan şifreyi girin ya da PS5'te bu hesabın giriş şifresini kapatın.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.LoginPasscode), true, Localizer.ForLanguage("tr")));
    }

    [Fact]
    public void DisconnectReasonsAreExplained()
    {
        var text = Localizer.ForLanguage("en");
        Assert.Equal("Turn on your PS5", AppController.StatusText(SessionState.Disconnected(DisconnectKind.ConsoleAsleep), true, text));
        Assert.Equal("Remote Play is in use on another device", AppController.StatusText(SessionState.Disconnected(DisconnectKind.InUse), true, text));
        Assert.Equal("The PS5 did not accept the connection yet. It may still be starting up, or its network address may have changed. Reconnecting and searching for the PS5… If this keeps happening, make sure the PS5 is on and on the same network.", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Refused), true, text));
        Assert.Equal("Lost the connection to the PS5. Reconnecting… If this keeps happening, connect the PS5 to the router with a cable.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Network), true, text));
        Assert.Equal("PS5 ile bağlantı koptu, yeniden bağlanılıyor… Sık oluyorsa PS5'i modeme kabloyla bağlayın.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Network), true, Localizer.ForLanguage("tr")));
        // 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9); genel "başka Remote Play açık olabilir" metni yanıltıyordu.
        Assert.Equal("PS5'te Uzaktan Oynama kapalı (kod 0x80108b12). PS5'te Ayarlar › Sistem › Uzaktan Oynama'ya gidip Uzaktan Oynama'yı Etkinleştir'i açın.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Rejected, ApplicationReasons.RemotePlayDisabled), true, Localizer.ForLanguage("tr")));
        Assert.Equal("The PS5 didn't accept this pairing. Pair the PS5 again with the second account in Settings.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.RegistrationInvalid), true, text));
        // X, 21 Kas: PS5 akışı kendisi kapatınca (oyun sırasında kullanıcı değişti) "kabloyla bağlayın" denmez.
        Assert.Equal("The PS5 ended Remote Play. This usually happens when the user is switched on the PS5 during the game. Reconnecting…",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.ConsoleClosed, "x"), true, text));
        Assert.Equal("PS5 Uzaktan Oynatma'yı kapattı. Bu çoğunlukla oyun sırasında PS5'te kullanıcı değiştirilince olur. Yeniden bağlanılıyor…",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.ConsoleClosed, "x"), true, Localizer.ForLanguage("tr")));
        // GitHub #519: İngilizce "Remote Play on Console has crashed" yerine yerelleştirilmiş yönlendirme.
        Assert.Equal("Remote Play on the PS5 has crashed. Turn the PS5 off completely (not rest mode) and back on, then connect again.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.ConsoleRemotePlayCrashed), true, text));
        Assert.Equal("PS5'teki Uzaktan Oynatma çöktü. PS5'i tamamen kapatıp (bekleme modu değil) açın, sonra yeniden bağlanın.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.ConsoleRemotePlayCrashed), true, Localizer.ForLanguage("tr")));
        Assert.Equal("PS5 not found at 192.168.1.70. Make sure it is on and on the same network. Reconnecting…",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.NotFound, "192.168.1.70"), true, text));
        Assert.Equal("Reconnecting… (Session Request RP Version Mismatch)",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Other, "Session Request RP Version Mismatch"), true, text));
        Assert.Equal("Reconnecting…", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Other), true, text));
        Assert.Equal("Not connected", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Stopped), false, text));
        // PS5 oturum isteğini reddetti: libchiaki'nin "Unknown Session Request Error"u yerine anlamlı metin ve kod.
        Assert.Equal("PS5 bağlantıyı reddetti (kod 0x80108bff). Başka bir Uzaktan Oynatma (PS Remote Play) açık olabilir ya da PS5 başka bir oturumda olabilir. PS Remote Play'i kapatın, PS5'i yeniden başlatıp tekrar deneyin.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Rejected, "0x80108bff"), true, Localizer.ForLanguage("tr")));
        Assert.Equal("The PS5 didn't start the session. Another Remote Play app (PS Remote Play) may be open, or the PS5 may be in another session. Close PS Remote Play, restart the PS5, then try again.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Rejected), true, text));
    }

    /// Eşleştirme başarılıyken çeviri başlamadan ana ekran "Bağlı değil" demez (kullanıcı PS5'i bağlanmamış sanıyordu).
    [Fact]
    public async Task PairedConsoleIsNotShownAsDisconnectedBeforeStart()
    {
        var services = new FakeServices();
        var controller = AppControllerTests.Make(services);
        Assert.Equal("Not connected", controller.Ps5StatusText);
        await controller.CompletePsnLoginAsync(new Uri("https://x/?code=x"));
        await controller.RegisterAsync("192.168.1.70", "12345678");
        Assert.Equal("Paired with PS5-789. Connects when you start translating.", controller.Ps5StatusText);
        Assert.Equal("PS5-789 ile eşleşti. Çeviriyi başlatınca bağlanır.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Stopped), false, Localizer.ForLanguage("tr"), "PS5-789"));
    }

    [Fact]
    public void TurkishStatusTextComesFromSharedCatalog() =>
        Assert.Equal("Bağlı", AppController.StatusText(SessionState.Streaming, true, Localizer.ForLanguage("tr")));
}

public class StatusToneTests
{
    /// Çeviri başlamamışken "bağlı değil" bir uyarı değildir; nokta gri kalır.
    [Fact]
    public void IdleWhenNotRunning()
    {
        Assert.Equal(StatusTone.Idle, AppController.Ps5ToneFor(SessionState.Disconnected(DisconnectKind.Stopped), running: false));
        Assert.Equal(StatusTone.Idle, AppController.TvToneFor(clients: 0, running: false));
    }

    [Fact]
    public void WarningWhileRunningButNotConnected()
    {
        Assert.Equal(StatusTone.Warning, AppController.Ps5ToneFor(SessionState.Disconnected(DisconnectKind.Network), running: true));
        Assert.Equal(StatusTone.Warning, AppController.Ps5ToneFor(SessionState.Connecting, running: true));
        Assert.Equal(StatusTone.Warning, AppController.TvToneFor(clients: 0, running: true));
    }

    [Fact]
    public void GoodWhenConnected()
    {
        Assert.Equal(StatusTone.Good, AppController.Ps5ToneFor(SessionState.Streaming, running: true));
        Assert.Equal(StatusTone.Good, AppController.TvToneFor(clients: 1, running: false));
    }
}

public class TvAppInstallTests
{
    private static readonly LgTv Tv = new("LG TV", "192.168.1.153");

    private static AppController Make(FakeServices services, MemoryStore? store = null) =>
        new(services, store ?? new MemoryStore(), new MemorySettings(), new FakeSleep(), Localizer.ForLanguage("en"), action => action());

    [Fact]
    public async Task MissingAppWithDevModeOffShowsTheSteps()
    {
        var services = new FakeServices { AppOnTv = null };
        var controller = Make(services);
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        Assert.NotNull(controller.Tv);
    }

    [Fact]
    public async Task PassphraseInstallsAndOpensTheApp()
    {
        var services = new FakeServices { AppOnTv = null, DevMode = true };
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
        var pairs = services.PairCount;
        await controller.InstallTvAppAsync(" ABC123 ");
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
        Assert.Equal(1, services.Installs);
        Assert.Equal("dev-key", store.Load<string>(StoreKeys.TvDevKey));
        Assert.Equal(pairs + 1, services.PairCount);
    }

    [Fact]
    public async Task WrongPassphraseAndClosedKeyServerAreExplained()
    {
        var services = new FakeServices { AppOnTv = null, DevMode = true };
        var controller = Make(services);
        await controller.PairAsync(Tv);
        await controller.InstallTvAppAsync("WRONG");
        Assert.Equal(DevModeError.WrongPassphrase, controller.TvApp.Error);
        services.KeyServer = false;
        await controller.InstallTvAppAsync("ABC123");
        Assert.Equal(DevModeError.KeyServerOff, controller.TvApp.Error);
        Assert.Equal(0, services.Installs);
    }

    [Fact]
    public async Task OlderAppIsUpdatedWithoutAsking()
    {
        var services = new FakeServices { AppOnTv = "0.4.0", DevMode = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        Assert.Equal(1, services.Installs);
        Assert.Equal(TvAppKind.UpToDate, controller.TvApp.Kind);
    }

    [Fact]
    public async Task CurrentAppIsNotReinstalled()
    {
        var services = new FakeServices { DevMode = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        Assert.Equal(0, services.Installs);
    }

    [Fact]
    public async Task RefusedKeyIsForgottenAndPassphraseAskedAgain()
    {
        var services = new FakeServices { DevMode = true, RefuseKey = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "old-key");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
        Assert.Null(store.Load<string>(StoreKeys.TvDevKey));
    }

    [Fact]
    public async Task LgDeveloperModeIsExtendedOncePerDay()
    {
        var services = new FakeServices { DevMode = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        Assert.Equal(999, controller.DevModeHoursLeft);
        await controller.RefreshTvAppAsync();
        Assert.Equal(1, services.Renewals);
    }

    private static readonly LgTv Samsung = new("Samsung", "192.168.1.20", TvBrand.Samsung);
    private static readonly BundledTvApp SamsungApp = new("couchsubs-samsung_0.7.0.wgt", "0.7.0");

    [Fact]
    public async Task SamsungWithDevModeOffShowsTheSteps()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var controller = Make(services);
        await controller.PairAsync(Samsung);
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        Assert.True(controller.CanInstallTvApp);
    }

    [Fact]
    public async Task SamsungInstallOpensSignInAndRemembersTheVersion()
    {
        var page = new Uri("https://account.samsung.com/signin");
        var services = new FakeServices { SamsungDevMode = true };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        services.Events.Add(new TvInstallEvent(TvInstallEventKind.SignIn, page));
        var store = new MemoryStore();
        var controller = Make(services, store);
        var opened = new List<Uri>();
        controller.OpenInBrowser = opened.Add;
        await controller.PairAsync(Samsung);
        Assert.Equal([page], opened);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
        Assert.Equal("0.7.0", store.Load<string>(StoreKeys.TvAppVersion));
        await controller.RefreshTvAppAsync();
        Assert.Single(services.BrandInstalls);
    }

    [Fact]
    public async Task OldSamsungAppOnTheTvIsUpdatedEvenIfThisComputerThinksItIsCurrent()
    {
        // Q60: TV'de 0.9.7 kalmıştı, bilgisayar kendi kaydına bakıp hiç güncellemiyordu.
        var services = new FakeServices { SamsungOnTv = "0.6.0" };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(Samsung);
        store.Save(StoreKeys.TvAppVersion, "0.7.0");
        services.SamsungDevMode = true;
        await controller.RefreshTvAppAsync();
        Assert.Single(services.BrandInstalls);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
    }

    [Fact]
    public async Task CurrentSamsungAppOnTheTvIsNotReinstalled()
    {
        var services = new FakeServices { SamsungDevMode = true, SamsungOnTv = "0.7.0" };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(Samsung);
        Assert.Empty(services.BrandInstalls);
        Assert.Equal("0.7.0", store.Load<string>(StoreKeys.TvAppVersion));
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
    }

    [Fact]
    public async Task SamsungCheckThatCannotReachTheTvKeepsAWorkingAppReady()
    {
        var services = new FakeServices { InstallError = DevModeError.Unreachable, InstallDetail = "sdb: closed" };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(Samsung);
        store.Save(StoreKeys.TvAppVersion, "0.7.0");
        services.SamsungDevMode = true;
        await controller.RefreshTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);

        // Bu bilgisayar kurmadıysa aynı hata gösterilir.
        store.Remove(StoreKeys.TvAppVersion);
        await controller.RefreshTvAppAsync();
        Assert.Equal(DevModeError.Unreachable, controller.TvApp.Error);
        Assert.Equal("sdb: closed", controller.TvApp.Reason);
    }

    // #343: TV'deki Host PC IP başka bir adres; sdb denenmez, iki adres de söylenir.
    [Fact]
    public async Task SamsungWithAnotherHostPcIpSaysWhichAddressToTypeWithoutTryingSdb()
    {
        var services = new FakeServices
        {
            SamsungDevMode = true,
            SamsungCheck = new SamsungPreflight(new SamsungDeveloperInfo(true, "192.168.1.50"), "192.168.1.34"),
        };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var controller = Make(services);
        await controller.PairAsync(Samsung);
        Assert.Equal(new TvAppState(TvAppKind.Failed, Error: DevModeError.HostPcMismatch, HostPcIp: "192.168.1.50",
            ComputerAddress: "192.168.1.34"), controller.TvApp);
        Assert.Empty(services.BrandInstalls);

        var tr = TvAppMessages.Problem(controller.TvApp, TvBrand.Samsung, Localizer.ForLanguage("tr"), "x.log");
        Assert.Contains("192.168.1.50", tr);
        Assert.Contains("192.168.1.34", tr);
        Assert.Contains("Samsung logosu", tr);
        var en = TvAppMessages.Problem(controller.TvApp, TvBrand.Samsung, Localizer.ForLanguage("en"), "x.log");
        Assert.StartsWith("The TV's Host PC IP is 192.168.1.50, but this computer's address is 192.168.1.34.", en);

        // Host PC IP düzeltilince kurulur.
        services.SamsungCheck = new SamsungPreflight(new SamsungDeveloperInfo(true, "192.168.1.34"), "192.168.1.34");
        await controller.RefreshTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
    }

    [Fact]
    public async Task SamsungSayingDeveloperModeIsOffShowsTheSteps()
    {
        // 26101 açık görünse de TV geliştirici modunun kapalı olduğunu söylüyorsa adımlar gösterilir.
        var services = new FakeServices
        {
            SamsungDevMode = true,
            SamsungCheck = new SamsungPreflight(new SamsungDeveloperInfo(false, null), "192.168.1.34"),
        };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var controller = Make(services);
        await controller.PairAsync(Samsung);
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        Assert.Empty(services.BrandInstalls);
    }

    [Fact]
    public void SamsungUnreachableSaysThisComputersAddress()
    {
        var state = new TvAppState(TvAppKind.Failed, Error: DevModeError.Unreachable);
        var text = TvAppMessages.Problem(state, TvBrand.Samsung, Localizer.ForLanguage("tr"), "x.log", "192.168.1.34");
        Assert.Contains("192.168.1.34", text);
        Assert.NotEqual(TvAppMessages.ComputerAddressLine, Localizer.ForLanguage("tr")[TvAppMessages.ComputerAddressLine]);
        Assert.DoesNotContain("192.168.1.34", TvAppMessages.Problem(state, TvBrand.Lg, Localizer.ForLanguage("tr"), "x.log", "192.168.1.34"));
    }

    [Fact]
    public async Task SamsungFailureIsShown()
    {
        var services = new FakeServices { SamsungDevMode = true, InstallError = DevModeError.SignInFailed };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var controller = Make(services);
        await controller.PairAsync(Samsung);
        Assert.Equal(new TvAppState(TvAppKind.Failed, Error: DevModeError.SignInFailed), controller.TvApp);
    }

    [Fact]
    public async Task SamsungFailureShowsWhatSamsungOrTheTvSaid()
    {
        var services = new FakeServices
        {
            SamsungDevMode = true, InstallError = DevModeError.PackageBlocked,
            InstallDetail = "app_id[CouchSubsT.CouchSubs] install failed[118, -22]",
        };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var controller = Make(services);
        await controller.PairAsync(Samsung);
        Assert.Equal(new TvAppState(TvAppKind.Failed, Error: DevModeError.PackageBlocked,
            Reason: "app_id[CouchSubsT.CouchSubs] install failed[118, -22]"), controller.TvApp);

        var text = TvAppMessages.Problem(controller.TvApp, TvBrand.Samsung, Localizer.ForLanguage("tr"), @"C:\CouchSubs\tvinstall.log");
        Assert.Contains("Smart Hub", text);
        Assert.Contains("Ayrıntı: app_id[CouchSubsT.CouchSubs] install failed[118, -22]", text);
        Assert.EndsWith(@"C:\CouchSubs\tvinstall.log", text);
    }

    [Fact]
    public async Task SamsungSignInFailureAlsoShowsItsReason()
    {
        var services = new FakeServices { SamsungDevMode = true, InstallError = DevModeError.SignInFailed, InstallDetail = "giriş 10 dakika içinde tamamlanmadı" };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var controller = Make(services);
        await controller.PairAsync(Samsung);
        Assert.Equal("giriş 10 dakika içinde tamamlanmadı", controller.TvApp.Reason);
    }

    [Theory]
    [InlineData(DevModeError.CertificateMismatch)]
    [InlineData(DevModeError.CertificateRejected)]
    [InlineData(DevModeError.TvClockWrong)]
    [InlineData(DevModeError.PackageBlocked)]
    [InlineData(DevModeError.ConnectionLost)]
    public void SamsungInstallErrorsHaveTheirOwnTranslatedMessage(DevModeError error)
    {
        var key = TvAppMessages.Key(error, TvBrand.Samsung);
        Assert.NotEqual(TvAppMessages.Key(DevModeError.InstallFailed, TvBrand.Samsung), key);
        Assert.NotEqual(key, Localizer.ForLanguage("tr")[key]);
    }

    [Fact]
    public void SamsungPairingSaysWhetherThePermissionBoxWasMissedOrRefused()
    {
        var text = Localizer.ForLanguage("tr");
        var timeout = TvAppMessages.PairingProblem(new TaskCanceledException(), TvBrand.Samsung, text);
        var refused = TvAppMessages.PairingProblem(new SsapException("rejected"), TvBrand.Samsung, text);
        Assert.Contains("60 saniye", timeout);
        Assert.Contains("reddetti", refused);
        Assert.Equal(timeout, TvAppMessages.PairingProblem(new SsapException("cannot connect"), TvBrand.Samsung, text));
        var offline = TvAppMessages.PairingProblem(new System.Net.WebSockets.WebSocketException(), TvBrand.Samsung, text);
        Assert.Equal(text["The TV did not respond. Make sure it is on and on the same network."], offline);
        // LG'de eski davranış: sebep parantez içinde.
        Assert.EndsWith("(timeout)", TvAppMessages.PairingProblem(new SsapException("timeout"), TvBrand.Lg, Localizer.ForLanguage("en")));
    }

    /// LG ve Android TV hatasında da gönderilecek günlük dosyası yazar (önceden yalnız Samsung'da); Samsung'a özgü
    /// ipuçları eklenmez.
    [Theory]
    [InlineData(TvBrand.Lg)]
    [InlineData(TvBrand.AndroidTv)]
    public void LgAndAndroidFailuresNameTheLogFileToo(TvBrand brand)
    {
        var state = new TvAppState(TvAppKind.Failed, Error: DevModeError.InstallFailed, Reason: "Invalid package");
        var text = TvAppMessages.Problem(state, brand, Localizer.ForLanguage("en"), @"C:\CouchSubs\tvinstall.log");
        Assert.Contains("TV says: Invalid package", text);
        Assert.EndsWith(@"send us this file: C:\CouchSubs\tvinstall.log", text);
        Assert.DoesNotContain("Samsung", text);
    }

    /// LG kurulumunun adımları günlüğe telefonlardaki satırlarla yazılır; hata da sebebiyle yazılır.
    [Fact]
    public async Task LgInstallStepsAreWrittenToTheInstallLog()
    {
        var lines = new List<string>();
        var log = new LgInstallLog(lines.Add);
        Assert.Equal("anahtar", await log.KeyAsync("192.168.1.20", () => Task.FromResult("anahtar")));
        Assert.Null(await log.InstalledVersionAsync("192.168.1.20", "0.9.43", () => Task.FromResult<string?>(null)));
        await log.InstallAsync(() => Task.CompletedTask);
        Assert.Equal(new[]
        {
            "--- LG kurulumu başlıyor: TV 192.168.1.20, Key Server'dan anahtar isteniyor",
            "Key Server'dan anahtar alındı.",
            "--- LG kurulumu başlıyor: TV 192.168.1.20, paket 0.9.43",
            "TV'deki CouchSubs: yok",
            "Kurulum tamam.",
        }, lines);

        lines.Clear();
        var error = await Assert.ThrowsAsync<DevModeException>(() =>
            log.InstallAsync(() => throw new DevModeException(DevModeError.InstallFailed, "FAILED_IPKG_INSTALL")));
        Assert.Equal(DevModeError.InstallFailed, error.Error);
        Assert.Equal(new[] { "HATA InstallFailed: FAILED_IPKG_INSTALL" }, lines);

        lines.Clear();
        await Assert.ThrowsAsync<DevModeException>(() => log.KeyAsync("192.168.1.20", () => throw new DevModeException(DevModeError.WrongPassphrase)));
        Assert.Equal("HATA WrongPassphrase: ", lines[^1]);
    }

    /// Samsung kısa basışta tam kapanmaz: "yeniden başlatın" diyen hatada güç tuşunun basılı tutulacağı yazar.
    /// Kurulum sırasında bağlantı koparsa HDMI-CEC (Anynet+) ve otomatik kaynak değiştirme anlatılır.
    [Fact]
    public void SamsungFailureExplainsRestartAndSourceSwitching()
    {
        var text = Localizer.ForLanguage("tr");
        var unreachable = TvAppMessages.Problem(new TvAppState(TvAppKind.Failed, Error: DevModeError.Unreachable), TvBrand.Samsung, text, "x.log");
        Assert.Contains("Samsung logosuyla", unreachable);
        Assert.DoesNotContain("Anynet+", unreachable);
        var dropped = TvAppMessages.Problem(new TvAppState(TvAppKind.Failed, Error: DevModeError.ConnectionLost), TvBrand.Samsung, text, "x.log");
        Assert.Contains("Anynet+ (HDMI-CEC)", dropped);
        Assert.Contains("Otomatik Kaynak Değiştirme", dropped);
        Assert.EndsWith("x.log", dropped);
        Assert.NotEqual(TvAppMessages.SourceSwitchTip, text[TvAppMessages.SourceSwitchTip]);
        Assert.NotEqual(TvAppMessages.RestartTip, text[TvAppMessages.RestartTip]);
        // LG'de Samsung'a özgü ipucu çıkmaz.
        var lg = TvAppMessages.Problem(new TvAppState(TvAppKind.Failed, Error: DevModeError.Unreachable), TvBrand.Lg, text, "x.log");
        Assert.DoesNotContain("Samsung logosu", lg);
    }

    /// <summary>
    /// TV'de CouchSubs'ın kimliğiyle başka uygulama: onaysız hiçbir şey silinmez, kart soruyu gösterir; "Kaldırıp Kur"
    /// bir kerelik olarak kaldırıp kurar (Mac, iPhone ve Android ile aynı).
    /// </summary>
    [Fact]
    public async Task ForeignAppOnAndroidTvIsReplacedOnlyAfterConsent()
    {
        var services = new FakeServices { ForeignOnTv = true };
        services.Bundled[TvBrand.AndroidTv] = new BundledTvApp("couchsubs-androidtv_0.7.0.apk", "0.7.0");
        services.AndroidHosts.Add("192.168.1.40");
        var controller = Make(services, new MemoryStore());
        await controller.PairAsync(new LgTv("Android TV", "192.168.1.40", TvBrand.AndroidTv));
        await controller.RefreshTvAppAsync();
        Assert.Equal(TvAppKind.Failed, controller.TvApp.Kind);
        Assert.Equal(DevModeError.ForeignApp, controller.TvApp.Error);
        Assert.True(services.ForeignOnTv);
        Assert.Empty(services.BrandInstalls);
        var text = Localizer.ForLanguage("tr");
        Assert.Equal("Bu TV'de CouchSubs kimliğini kullanan başka bir uygulama kurulu. Kaldırıp CouchSubs'ı kuralım mı?",
            TvAppMessages.Problem(controller.TvApp, TvBrand.AndroidTv, text, "x.log"));
        Assert.Equal("Kaldırıp Kur", text[TvAppMessages.ForeignAppConfirm]);
        Assert.Equal("Vazgeç", text[TvAppMessages.ForeignAppCancel]);
        Assert.Equal("Başka Bir Uygulama Kurulu", text[TvAppMessages.ForeignAppTitle]);

        await controller.ReplaceForeignTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
        Assert.False(services.ForeignOnTv);
        Assert.True(services.ReplaceRequests[^1]);
        Assert.DoesNotContain(true, services.ReplaceRequests[..^1]);
        // Onay bir kerelik: sonraki denetimler yine onaysız.
        await controller.RefreshTvAppAsync();
        Assert.False(services.ReplaceRequests[^1]);
    }

    [Fact]
    public async Task ForeignAppOnLgIsReplacedOnlyAfterConsent()
    {
        var services = new FakeServices { DevMode = true, ForeignOnTv = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("LG", "192.168.1.30", TvBrand.Lg));
        await controller.RefreshTvAppAsync();
        Assert.Equal(DevModeError.ForeignApp, controller.TvApp.Error);
        Assert.Equal(0, services.Installs);

        await controller.ReplaceForeignTvAppAsync();
        Assert.Equal(TvAppKind.UpToDate, controller.TvApp.Kind);
        Assert.Equal(1, services.Installs);
        Assert.True(services.ReplaceRequests[^1]);
        Assert.DoesNotContain(true, services.ReplaceRequests[..^1]);
        Assert.False(services.ForeignOnTv);
    }

    [Fact]
    public async Task AndroidTvIsFoundOnTheNetworkAndRemembered()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = new BundledTvApp("couchsubs-androidtv_0.7.0.apk", "0.7.0");
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);

        services.AndroidHosts.Add("192.168.1.40");
        services.Events.Add(new TvInstallEvent(TvInstallEventKind.ApproveOnTv));
        await controller.RefreshTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
        Assert.Equal("192.168.1.40", controller.Tv?.Host);
        Assert.Equal("192.168.1.40", store.Load<LgTv>(StoreKeys.Tv)?.Host);
    }

    /// <summary>
    /// Android TV uygulaması altyazı sunucusunun adresiyle açılır; sunucu elle seçilen portta (Linux'ta
    /// COUCHSUBS_SERVER_PORT) dinler ve TV uygulaması 8787'yi taramadan onu bulur (#617).
    /// </summary>
    [Fact]
    public async Task AndroidTvAppGetsTheServerAddressOnItsPort()
    {
        using var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        probe.Start();
        var free = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        var services = new FakeServices { PreferredServerPort = free };
        services.Bundled[TvBrand.AndroidTv] = new BundledTvApp("couchsubs-androidtv_0.7.0.apk", "0.7.0");
        services.AndroidHosts.Add("192.168.1.40");
        var controller = Make(services, new MemoryStore());
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
        Assert.Equal(free, controller.ServerPort);
        var launch = Assert.Single(services.AndroidLaunchParams);
        using var json = System.Text.Json.JsonDocument.Parse(launch!);
        Assert.EndsWith($":{free}", json.RootElement.GetProperty("server").GetString());
    }

    /// <summary>Aynı ağda iki Android TV: kurulum ilk bulunana gitmez, TV sorulur; seçilen TV'ye kurulur ve hatırlanır (#425).</summary>
    [Fact]
    public async Task SeveralAndroidTvsAreAskedAndTheChosenOneIsInstalled()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = new BundledTvApp("couchsubs-androidtv_0.7.0.apk", "0.7.0");
        services.AndroidHosts.AddRange(["192.168.1.105", "192.168.1.106"]);
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Equal(TvAppKind.ChooseAndroidTv, controller.TvApp.Kind);
        Assert.Equal(["192.168.1.105", "192.168.1.106"], controller.TvApp.Hosts);
        Assert.Empty(services.BrandInstalls);

        await controller.ChooseAndroidTvAsync("192.168.1.106");
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
        Assert.Equal([(TvBrand.AndroidTv, "192.168.1.106")], services.BrandInstalls);
        Assert.Equal("192.168.1.106", store.Load<LgTv>(StoreKeys.Tv)?.Host);
    }

    [Fact]
    public void AndroidTvPickPrefersTheKnownTvAndOtherwiseAsks()
    {
        Assert.Equal("192.168.1.105", AndroidTvPick.Pick(["192.168.1.105"], []));
        Assert.Null(AndroidTvPick.Pick([], ["192.168.1.105"]));
        Assert.Null(AndroidTvPick.Pick(["192.168.1.105", "192.168.1.106"], [null, ""]));
        Assert.Equal("192.168.1.106", AndroidTvPick.Pick(["192.168.1.105", "192.168.1.106"], [null, "192.168.1.106"]));
        Assert.Null(AndroidTvPick.Pick(["192.168.1.105", "192.168.1.106"], ["192.168.1.7"]));
        Assert.Equal("192.168.1.105", AndroidTvPick.Pick(["192.168.1.105", "192.168.1.105"], []));
    }

    private static readonly BundledTvApp AndroidApp = new("couchsubs-androidtv_0.7.0.apk", "0.7.0");

    // #352, #389: TV'den kaldırılan uygulama; TV sihirbazda yeniden seçilince adres boşalıyor, kayıtlı sürüm kalıyordu.
    // Kart "hazır" diyor, ağda TV aranmıyor, kurulum hiç denenmiyordu; ana ekran "TV uygulaması bekleniyor"da kalıyordu.
    [Fact]
    public async Task ReselectedAndroidTvWithARememberedVersionIsCheckedOnTheTv()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        services.AndroidHosts.Add("192.168.1.40");
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Single(services.BrandInstalls);
        Assert.Equal("0.7.0", store.Load<string>(StoreKeys.TvAppVersion));

        // Uygulama TV'den kaldırıldı; kullanıcı TV'yi sihirbazda yeniden seçti.
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Equal(2, services.BrandInstalls.Count);
        Assert.Equal("192.168.1.40", services.BrandInstalls[1].Host);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
    }

    [Fact]
    public async Task ReselectedAndroidTvThatCannotBeFoundShowsTheDebuggingSteps()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        store.Save(StoreKeys.TvAppVersion, "0.7.0");
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        await controller.RefreshTvAppAsync();
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
    }

    [Fact]
    public async Task KnownAndroidTvWithDebuggingOffKeepsTheRememberedVersion()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        controller.TvMoved(new LgTv("Android TV", "192.168.1.40", TvBrand.AndroidTv));
        store.Save(StoreKeys.TvAppVersion, "0.7.0");
        await controller.RefreshTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);
        Assert.Empty(services.BrandInstalls);
        // TV uygulaması bağlı değil: "yeniden kur" görünür.
        Assert.True(controller.CanReinstallTvApp);
    }

    [Fact]
    public async Task ReinstallForgetsTheVersionChecksTheTvAndOpensTheApp()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        services.AndroidHosts.Add("192.168.1.40");
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Equal([false], services.AndroidOpenRequests);

        await controller.ReinstallTvAppAsync();
        Assert.Equal([false, true], services.AndroidOpenRequests);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);

        // "Açılsın" isteği bir kerelik: sonraki denetim uygulamayı açmaz.
        await controller.RefreshTvAppAsync();
        Assert.Equal([false, true, false], services.AndroidOpenRequests);
    }

    [Fact]
    public async Task SamsungReinstallOpensTheCurrentAppOnTheTv()
    {
        // Samsung'da düğme güncel uygulamayı açmıyordu: TV uygulaması kapalı kalıyor, altyazı gelmiyordu.
        var services = new FakeServices { SamsungDevMode = true, SamsungOnTv = "0.7.0" };
        services.Bundled[TvBrand.Samsung] = SamsungApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(Samsung);
        Assert.Equal([false], services.SamsungOpenRequests);

        await controller.ReinstallTvAppAsync();
        Assert.Equal([false, true], services.SamsungOpenRequests);
        Assert.Empty(services.BrandInstalls);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.7.0"), controller.TvApp);

        // "Açılsın" isteği bir kerelik.
        await controller.RefreshTvAppAsync();
        Assert.Equal([false, true, false], services.SamsungOpenRequests);
    }

    [Fact]
    public async Task ReinstallWithoutDebuggingShowsTheDebuggingSteps()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        var store = new MemoryStore();
        var controller = Make(services, store);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        controller.TvMoved(new LgTv("Android TV", "192.168.1.40", TvBrand.AndroidTv));
        store.Save(StoreKeys.TvAppVersion, "0.7.0");
        await controller.ReinstallTvAppAsync();
        Assert.Null(store.Load<string>(StoreKeys.TvAppVersion));
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
    }

    [Fact]
    public async Task OpenedPlayPageAsksToPressInstallOnTheTv()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        services.AndroidHosts.Add("192.168.1.40");
        var states = new List<TvAppKind>();
        var controller = Make(services);
        controller.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(AppController.TvApp)) states.Add(controller.TvApp.Kind); };
        services.Events.Add(new TvInstallEvent(TvInstallEventKind.Progress, Step: "play"));
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.Contains(TvAppKind.PressInstallOnTv, states);
        Assert.Equal(TvAppKind.UpToDate, controller.TvApp.Kind);
    }

    [Fact]
    public async Task ReinstallIsOfferedForAllThreeBrandsWhileTheTvAppIsNotConnected()
    {
        var services = new FakeServices();
        services.Bundled[TvBrand.AndroidTv] = AndroidApp;
        var controller = Make(services);
        Assert.False(controller.CanReconnectTv);
        Assert.False(controller.CanChangeTv);
        await controller.PairAsync(Tv);
        // LG'de de "yeniden kur" var (önceden yalnız Samsung ve Android TV); "TV'ye bağlan" onunla birlikte çıkmaz,
        // TV adımına "TV'yi değiştir" götürür.
        Assert.True(controller.CanReinstallTvApp);
        Assert.False(controller.CanReconnectTv);
        Assert.True(controller.CanChangeTv);
        await controller.PairAsync(new LgTv("Android TV", "", TvBrand.AndroidTv));
        Assert.True(controller.CanReinstallTvApp);
        Assert.False(controller.CanReconnectTv);
        Assert.True(controller.CanChangeTv);
    }

    /// LG paketi uygulamayla gelmediyse yeniden kurulamaz; TV adımına "TV'ye bağlan" götürür (#662), iki düğme birden çıkmaz.
    [Fact]
    public async Task WithoutTheLgPackageConnectATvIsOfferedInstead()
    {
        var controller = Make(new FakeServices { BundledTvAppVersion = null });
        await controller.PairAsync(Tv);
        Assert.False(controller.CanReinstallTvApp);
        Assert.True(controller.CanReconnectTv);
        Assert.False(controller.CanChangeTv);
    }

    /// LG'de "yeniden kur": kayıtlı anahtar varsa Passphrase sorulmadan, TV'deki sürüm güncel olsa da yeniden kurulur.
    [Fact]
    public async Task LgReinstallWithASavedKeyInstallsAgainWithoutAskingThePassphrase()
    {
        var services = new FakeServices { DevMode = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        // TV'deki sürüm güncel: açılışta kurulmaz.
        Assert.Equal(0, services.Installs);
        await controller.ReinstallTvAppAsync();
        Assert.Equal(1, services.Installs);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
        // İstek bir kerelik: sonraki denetim güncel uygulamayı yeniden kurmaz.
        await controller.RefreshTvAppAsync();
        Assert.Equal(1, services.Installs);
    }

    /// Kayıtlı anahtar yoksa Passphrase adımı açılır; parola yazılınca güncel uygulama da yeniden kurulur.
    [Fact]
    public async Task LgReinstallWithoutAKeyAsksThePassphraseThenInstallsAgain()
    {
        var services = new FakeServices { DevMode = true };
        var controller = Make(services);
        await controller.PairAsync(Tv);
        await controller.ReinstallTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.NeedsPassphrase), controller.TvApp);
        Assert.Equal(0, services.Installs);
        await controller.InstallTvAppAsync("ABC123");
        Assert.Equal(1, services.Installs);
        Assert.Equal(TvAppKind.UpToDate, controller.TvApp.Kind);
    }

    /// TV kayıtlı anahtarı reddederse (geliştirici modu yeniden açılmış) anahtar bırakılır ve Passphrase adımı açılır;
    /// geliştirici modu kapalıysa adımları görünür.
    [Fact]
    public async Task LgReinstallFallsBackToThePassphraseOrDeveloperModeSteps()
    {
        var services = new FakeServices { DevMode = true, RefuseKey = true };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "eski-anahtar");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        await controller.ReinstallTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.NeedsPassphrase), controller.TvApp);
        Assert.Null(store.Load<string>(StoreKeys.TvDevKey));
        services.RefuseKey = false;
        await controller.InstallTvAppAsync("ABC123");
        Assert.Equal(1, services.Installs);

        services.DevMode = false;
        await controller.ReinstallTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.DevModeOff), controller.TvApp);
    }

    /// "TV'yi değiştir" yalnız TV adımını açar; kayıtlı PS5, hesap ve TV silinmez ("Yeniden kur…" değil).
    [Fact]
    public async Task ChangeTvOpensOnlyTheTvStepAndKeepsTheSetup()
    {
        var store = new MemoryStore();
        var controller = Make(new FakeServices(), store);
        await controller.PairAsync(Tv);
        Assert.True(controller.CanChangeTv);
        controller.Step = OnboardingStep.Tv;
        Assert.Equal(OnboardingStep.Tv, controller.Step);
        Assert.Equal(Tv, controller.Tv);
        Assert.NotNull(store.Load<LgTv>(StoreKeys.Tv));
    }

    [Fact]
    public async Task WorkingAppWithoutKeyAsksNothing()
    {
        var controller = Make(new FakeServices { DevMode = true });
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
    }

    /// <summary>#884, #891: anahtar bu bilgisayarda yokken TV'deki LG uygulaması eski kalıyor, hiç uyarı çıkmıyordu. TV
    /// sürümünü altyazı akışıyla bildirir (bildirmeyen eski sayılır); ana ekran "TV uygulamasını güncelle" der.</summary>
    [Fact]
    public async Task OldLgAppReportedOnTheStreamAsksForAnUpdate()
    {
        var services = new FakeServices { DevMode = true };
        var controller = Make(services);
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
        controller.TvAppReported("");
        await Task.Yield();
        Assert.Equal(new TvAppOutdated(TvAppOutdated.Unreported, "0.6.1"), controller.TvAppOutdated);
        Assert.True(controller.ShowTvAppUpdate);
        Assert.Equal(StatusTone.Warning, controller.TvTone);
        Assert.Equal("TV app is out of date (< 0.9.69 → 0.6.1)", controller.TvStatusText);
        controller.TvAppReported("0.5.0");
        Assert.Equal(new TvAppOutdated("0.5.0", "0.6.1"), controller.TvAppOutdated);
        var step = controller.Step;
        await controller.UpdateTvAppAsync();
        Assert.Equal(step, controller.Step);
        Assert.True(controller.TvAppUpdating);
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
        await controller.InstallTvAppAsync("ABC123");
        Assert.Equal(1, services.Installs);
        Assert.Null(controller.TvAppOutdated);
        controller.TvAppReported("0.6.1");
        Assert.Null(controller.TvAppOutdated);
        Assert.False(controller.ShowTvAppUpdate);
    }

    /// <summary>Eski TV uygulaması bağlı (eksik değil) ve geliştirici modu kapalı: TV adımında Developer Mode adımları
    /// görünür. Önceden kart boş kalıyor, "TV uygulamasını güncelle" yalnız eşleştirme/test gösteriyordu (Mac ile aynı).</summary>
    [Fact]
    public async Task OldLgAppWithDevModeOffShowsTheDevModeSteps()
    {
        var services = new FakeServices();
        var controller = Make(services);
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
        controller.TvAppReported("");
        await controller.RefreshTvAppAsync();
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        var step = controller.Step;
        await controller.UpdateTvAppAsync();
        Assert.Equal(step, controller.Step);
        Assert.True(controller.TvAppUpdating);
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        await controller.RefreshTvAppAsync();
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        services.DevMode = true;
        await controller.RefreshTvAppAsync();
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
    }

    /// <summary>Eski TV uygulaması bağlı, geliştirici modu açık, anahtar bu bilgisayarda yok: Passphrase kartı görünür.</summary>
    [Fact]
    public async Task OldLgAppWithoutKeyShowsThePassphraseCard()
    {
        var controller = Make(new FakeServices { DevMode = true });
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
        controller.TvAppReported("0.5.0");
        await controller.RefreshTvAppAsync();
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
    }

    /// <summary>TV'den silinen uygulama için "Yeniden kur": geliştirici modu açık, anahtar yok → Passphrase kartı; neden
    /// kurulum günlüğüne yazılır (önceden tvinstall.log'a hiç satır düşmüyordu).</summary>
    [Fact]
    public async Task ReinstallForADeletedLgAppAsksThePassphraseAndLogsWhy()
    {
        var services = new FakeServices { DevMode = true };
        var controller = Make(services);
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
        await controller.ReinstallTvAppAsync();
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
        Assert.Contains(services.InstallLog, line => line.Contains("yeniden kurma/güncelleme istendi"));
        Assert.Contains(services.InstallLog, line => line.Contains("Passphrase isteniyor"));
    }

    // "TV uygulamasını güncelle" senaryoları: ana ekranda (TV adımına gidilmez), her adım tvinstall.log'da (Mac ile aynı).

    private static async Task<AppController> UpdateScenario(FakeServices services, bool key)
    {
        var store = new MemoryStore();
        if (key) store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        var dev = services.DevMode;
        var app = services.AppOnTv;
        services.DevMode = false;
        await controller.PairAsync(Tv);
        services.DevMode = dev;
        services.AppOnTv = app;
        services.InstallLog.Clear();
        return controller;
    }

    [Fact]
    public async Task UpdateWithEverythingReadyInstallsAtOnce()
    {
        var services = new FakeServices { DevMode = true, AppOnTv = "0.5.0" };
        var controller = await UpdateScenario(services, key: true);
        await controller.UpdateTvAppAsync();
        Assert.NotEqual(OnboardingStep.Tv, controller.Step);
        Assert.Equal(1, services.Installs);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
        Assert.True(controller.ShowTvAppUpdateDone);
        Assert.Contains(services.InstallLog, line => line.Contains("Ana ekrandan"));
        controller.DismissTvAppUpdate();
        Assert.False(controller.TvAppUpdating);
    }

    [Fact]
    public async Task UpdateWithDevModeOffContinuesByItselfOnceItIsOn()
    {
        var services = new FakeServices { AppOnTv = "0.5.0" };
        var controller = await UpdateScenario(services, key: true);
        await controller.UpdateTvAppAsync();
        Assert.Equal(TvAppKind.DevModeOff, controller.TvApp.Kind);
        Assert.Contains(services.InstallLog, line => line.Contains("geliştirici modu kapalı"));
        services.DevMode = true;
        // Kartın 3 sn'lik bekleme döngüsü.
        await controller.RefreshTvAppAsync();
        Assert.Equal(1, services.Installs);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
    }

    [Fact]
    public async Task UpdateWithoutAKeyAsksThePassphraseThenInstalls()
    {
        var services = new FakeServices { DevMode = true, AppOnTv = "0.5.0" };
        var controller = await UpdateScenario(services, key: false);
        await controller.UpdateTvAppAsync();
        Assert.Equal(TvAppKind.NeedsPassphrase, controller.TvApp.Kind);
        Assert.Contains(services.InstallLog, line => line.Contains("Passphrase isteniyor"));
        await controller.InstallTvAppAsync("ABC123");
        Assert.Equal(1, services.Installs);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
    }

    [Fact]
    public async Task ReinstallingADeletedAppFromHomeInstallsIt()
    {
        var services = new FakeServices { DevMode = true, AppOnTv = null };
        var controller = await UpdateScenario(services, key: true);
        Assert.Null(controller.TvAppOutdated);
        await controller.UpdateTvAppAsync();
        Assert.NotEqual(OnboardingStep.Tv, controller.Step);
        Assert.Equal(1, services.Installs);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
    }

    [Fact]
    public async Task FailedUpdateShowsWhyAndRetrySucceeds()
    {
        var services = new FakeServices { DevMode = true, AppOnTv = "0.5.0", LgInstallError = new DevModeException(DevModeError.InstallFailed, "disk dolu") };
        var controller = await UpdateScenario(services, key: true);
        await controller.UpdateTvAppAsync();
        Assert.Equal(TvAppKind.Failed, controller.TvApp.Kind);
        Assert.Equal("disk dolu", controller.TvApp.Reason);
        services.LgInstallError = null;
        await controller.RefreshTvAppAsync();
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
    }

    [Fact]
    public async Task OldLgAppReportedOnTheStreamIsUpdatedWithTheSavedKey()
    {
        var services = new FakeServices { DevMode = true, AppOnTv = "0.5.0" };
        var store = new MemoryStore();
        store.Save(StoreKeys.TvDevKey, "dev-key");
        var controller = Make(services, store);
        await controller.PairAsync(Tv);
        Assert.Equal(1, services.Installs);
        services.AppOnTv = "0.6.1";
        controller.TvAppReported("");
        for (var i = 0; i < 200 && controller.TvApp.Kind == TvAppKind.Working; i++) await Task.Delay(10);
        Assert.Equal(new TvAppState(TvAppKind.UpToDate, "0.6.1"), controller.TvApp);
        Assert.Null(controller.TvAppOutdated);
    }

    [Fact]
    public async Task OtherBrandsAreNotInstalledThroughLgDeveloperMode()
    {
        var services = new FakeServices { AppOnTv = null, DevMode = true };
        var controller = Make(services);
        await controller.PairAsync(new LgTv("Samsung", "192.168.1.20", TvBrand.Samsung));
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
        Assert.Equal(0, services.Installs);
    }

    [Fact]
    public void MovedTvIsSaved()
    {
        var store = new MemoryStore();
        var controller = Make(new FakeServices(), store);
        var moved = new LgTv("LG TV", "192.168.1.230");
        controller.TvMoved(moved);
        Assert.Equal(moved, controller.Tv);
        Assert.Equal(moved, store.Load<LgTv>(StoreKeys.Tv));
    }

    /// <summary>
    /// Samsung TV yeni adrese taşındı: uygulamanın orada kurulu olduğu bilgisi de taşınır ve saklanır (tvAppSeen), bekçi
    /// yeni adreste listeye bakmadan açar.
    /// </summary>
    [Fact]
    public void MovedSamsungTvStaysKnownInstalled()
    {
        var old = "198.51.100." + Random.Shared.Next(1, 120);
        var moved = "198.51.100." + Random.Shared.Next(130, 250);
        var store = new MemoryStore();
        store.Save(StoreKeys.Tv, new LgTv("Samsung", old, TvBrand.Samsung));
        store.Save(StoreKeys.TvAppSeen, old);
        try
        {
            var controller = Make(new FakeServices(), store);
            Assert.True(SamsungAppKnowledge.IsKnown(old));
            controller.TvMoved(new LgTv("Samsung", moved, TvBrand.Samsung));
            Assert.True(SamsungAppKnowledge.IsKnown(moved));
            Assert.Equal(moved, store.Load<string>(StoreKeys.TvAppSeen));
        }
        finally
        {
            SamsungAppKnowledge.Forget(old);
            SamsungAppKnowledge.Forget(moved);
        }
    }
}

internal sealed class FakeDubbingModel(bool installed) : IDubbingModel
{
    public bool IsInstalled => installed;
    public long DownloadBytes => 0;
    public Task DownloadAsync(IProgress<double> progress, CancellationToken cancellationToken) => Task.CompletedTask;
    public byte[] VoiceFile(DubbingVoice voice) => [];
    public ISpeechSynthesizer CreateSynthesizer() => throw new NotSupportedException();
}

internal sealed class FakeXbox(IReadOnlyList<XboxConsole> consoles) : IXboxService
{
    public List<bool> LegacyFrameRateRequests { get; } = [];
    public event Action<string>? TokenUpdated { add { } remove { } }
    public void Clear() { }
    public Task<XboxLoginChallenge> BeginLoginAsync() => throw new NotSupportedException();
    public Task<string> CompleteLoginAsync() => throw new NotSupportedException();
    public Task<IReadOnlyList<XboxConsole>> DiscoverAsync(string token) => Task.FromResult(consoles);
    public List<(bool PlayAudio, FakeStream Stream)> Streams { get; } = [];
    public IStreamSession MakeStream(XboxConsole console, string token, bool legacyFrameRate, bool playAudio)
    {
        LegacyFrameRateRequests.Add(legacyFrameRate);
        var stream = new FakeStream();
        Streams.Add((playAudio, stream));
        return stream;
    }
}

public class DisconnectLogNameTests
{
    /// altyazi.log'a kopmanın nedeni yazılır, PS5'in adresi yazılmaz (GitHub #456).
    [Fact]
    public void ReasonIsLoggedWithoutAddress()
    {
        Assert.Equal("NotFound", AppController.DisconnectLogName(new DisconnectReason(DisconnectKind.NotFound, "192.168.1.5")));
        Assert.Equal("Network", AppController.DisconnectLogName(new DisconnectReason(DisconnectKind.Network)));
        Assert.Equal("Rejected: 0x80108b12", AppController.DisconnectLogName(new DisconnectReason(DisconnectKind.Rejected, "0x80108b12")));
        Assert.Equal("?", AppController.DisconnectLogName(null));
    }
}
