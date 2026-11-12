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
    public void Save<T>(string key, T value) => Values[key] = value;
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
    public void Begin() => Active = true;
    public void End() => Active = false;
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
    public void Dispose() { }
    public void Emit(SessionState state) => StateChanged?.Invoke(state);
    public void Emit(Frame frame) => FrameReceived?.Invoke(frame);
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
    /// <summary>Verilirse Create bunu fırlatır (ör. onnxruntime.dll yüklenemedi).</summary>
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

internal sealed class FakeReader(Reading? lines = null) : ITextReader
{
    public string Read(Frame image) => lines?.Text ?? "";
    public Reading ReadLines(Frame image, bool deep) => lines ?? Reading.Empty;
}

internal sealed class FakeServices : IAppServices
{
    public List<ConsoleInfo> Consoles { get; } = [new("192.168.1.253", "PS5-789", true)];
    public List<LgTv> Tvs { get; } = [new("LG TV", "192.168.1.153")];
    public RegisteredConsole? Registered { get; private set; }
    public Exception? RegisterError { get; set; }
    public string? LaunchedServer { get; private set; }
    public List<FakeStream> Streams { get; } = [];
    public List<FakeKeeper> Keepers { get; } = [];
    public List<string> ReaderLanguages { get; } = [];
    /// <summary>Okuyucunun her karede bulduğu satırlar (verilmezse karede yazı yoktur).</summary>
    public Reading? ReaderLines { get; set; }
    public bool HasOcr { get; set; } = true;
    public bool HasOcrPack { get; set; } = true;
    public bool HasOcrLanguage(string language) => HasOcrPack;
    public IDubbingModel? Dubbing { get; set; }
    public IDubbingModel? FastDubbing { get; set; }
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
    public Task<AiTestResult> TestAiKeyAsync(AiProvider provider, string key, string model)
    {
        AiTests.Add((provider, key, model));
        return Task.FromResult(AiTest);
    }
    public ITextTranslator? MakeAiTranslator(AiProvider provider, string key, string model, ITextTranslator? fallback)
    {
        AiTranslators.Add((provider, key, model));
        return fallback ?? Translation.Create("en", "tr");
    }
    public List<(LocalAiServer Server, string Key)> LocalTests { get; } = [];
    public List<(LocalAiServer Server, string Key)> LocalTranslators { get; } = [];
    public Task<AiTestResult> TestLocalAiAsync(LocalAiServer server, string key)
    {
        LocalTests.Add((server, key));
        return Task.FromResult(AiTest);
    }
    public ITextTranslator? MakeLocalAiTranslator(LocalAiServer server, string key, ITextTranslator? fallback)
    {
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
    public Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server)
    {
        LaunchedServer = server;
        PairCount++;
        TvCalls++;
        return Task.FromResult(new TvPairing("tv-key", AppOnTv is not null));
    }
    public IStreamSession MakeStream(RegisteredConsole console, byte[] accountId)
    {
        if (StreamError is not null) throw StreamError;
        var stream = new FakeStream();
        Streams.Add(stream);
        return stream;
    }
    public IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved)
    {
        TvCalls++;
        var keeper = new FakeKeeper();
        Keepers.Add(keeper);
        return keeper;
    }
    public string? AppOnTv { get; set; } = "0.6.1";
    public bool DevMode { get; set; }
    public bool KeyServer { get; set; } = true;
    public bool RefuseKey { get; set; }
    public int Installs { get; private set; }
    public int PairCount { get; private set; }
    public string? BundledTvAppVersion { get; set; } = "0.6.1";
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
        return Task.FromResult(AppOnTv);
    }
    public Task InstallTvAppAsync(string host, string devKey)
    {
        Installs++;
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
    /// <summary>Samsung TV'de kurulu sürüm (sahte TV'nin vd_applist'i); null: uygulama yok.</summary>
    public string? SamsungOnTv { get; set; }
    public Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, Action<TvInstallEvent> onEvent)
    {
        TvCalls++;
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
    public Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, Action<TvInstallEvent> onEvent)
    {
        Events.ForEach(onEvent);
        if (InstallError is { } error) throw new DevModeException(error);
        BrandInstalls.Add((TvBrand.AndroidTv, host));
        return Task.FromResult(app.Version);
    }
    public ITextReader? MakeReader(string language)
    {
        ReaderLanguages.Add(language);
        return HasOcr ? new FakeReader(ReaderLines) : null;
    }
}

public class AppControllerTests
{
    private static readonly RegisteredConsole Console =
        new("192.168.1.253", "PS5", Enumerable.Repeat((byte)0x31, 16).ToArray(), Enumerable.Repeat((byte)2, 16).ToArray());

    internal static AppController Make(FakeServices? services = null, MemoryStore? store = null, MemorySettings? settings = null, FakeSleep? sleep = null) =>
        new(services ?? new FakeServices(), store ?? new MemoryStore(), settings ?? new MemorySettings(), sleep ?? new FakeSleep(), Localizer.ForLanguage("en"), action => action());

    [Fact]
    public void FreshInstallStartsAtWelcome() => Assert.Equal(OnboardingStep.Welcome, Make().Step);

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
    public async Task DoubleStartCreatesOneSession()
    {
        var (controller, services, _) = Ready();
        await Task.WhenAll(controller.StartAsync(), controller.StartAsync());
        Assert.Single(services.Streams);
        Assert.Single(services.Keepers);
        Assert.True(controller.IsRunning);
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

    [Fact]
    public void SettingsArePersistedOutsideTheSecureStore()
    {
        var store = new MemoryStore();
        var settings = new MemorySettings();
        var controller = AppControllerTests.Make(store: store, settings: settings);
        controller.Settings = controller.Settings with { Style = new SubtitleStyle(58, 7) };
        // Güvenli depoda yalnız kurulumun bitip bitmediği durur.
        Assert.Equal([StoreKeys.SetupComplete], store.Values.Keys);
        Assert.Equal(58, AppControllerTests.Make(store: store, settings: settings).Settings.Style.FontSize);
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

    /// Ücretsiz motor açılamazsa (onnxruntime.dll yüklenemedi) çeviri yine başlar ve ana ekranda uyarı çıkar.
    [Fact]
    public async Task StartSurvivesFreeEngineThatCannotBeCreated()
    {
        var services = new FakeServices();
        services.Translation.CreateError = new TypeInitializationException("Microsoft.ML.OnnxRuntime.NativeMethods",
            new DllNotFoundException("Unable to load DLL 'onnxruntime'"));
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
        Assert.Equal("http://localhost:1234/v1/chat/completions", server.ChatUrl.AbsoluteUri);
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
        Assert.Equal("The second user has a login passcode on the PS5. Turn it off in Settings › Users and Accounts.",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.LoginPasscode), true, text));
    }

    [Fact]
    public void DisconnectReasonsAreExplained()
    {
        var text = Localizer.ForLanguage("en");
        Assert.Equal("Turn on your PS5", AppController.StatusText(SessionState.Disconnected(DisconnectKind.ConsoleAsleep), true, text));
        Assert.Equal("Remote Play is in use on another device", AppController.StatusText(SessionState.Disconnected(DisconnectKind.InUse), true, text));
        Assert.Equal("The PS5 refused the connection. Set up the PS5 again.", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Refused), true, text));
        Assert.Equal("Can't reach the PS5. Reconnecting…", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Network), true, text));
        Assert.Equal("PS5 not found at 192.168.1.70. Make sure it is on and on the same network. Reconnecting…",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.NotFound, "192.168.1.70"), true, text));
        Assert.Equal("Reconnecting… (Session Request RP Version Mismatch)",
            AppController.StatusText(SessionState.Disconnected(DisconnectKind.Other, "Session Request RP Version Mismatch"), true, text));
        Assert.Equal("Reconnecting…", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Other), true, text));
        Assert.Equal("Not connected", AppController.StatusText(SessionState.Disconnected(DisconnectKind.Stopped), false, text));
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

    [Fact]
    public void LgFailureKeepsItsShortForm()
    {
        var state = new TvAppState(TvAppKind.Failed, Error: DevModeError.InstallFailed, Reason: "Invalid package");
        var text = TvAppMessages.Problem(state, TvBrand.Lg, Localizer.ForLanguage("en"), "x.log");
        Assert.EndsWith("TV says: Invalid package", text);
    }

    /// Samsung kısa basışta tam kapanmaz: "yeniden başlatın" diyen hatada güç tuşunun basılı tutulacağı yazar.
    /// Kurulum sırasında bağlantı koparsa HDMI-CEC (Anynet+) ve otomatik kaynak değiştirme anlatılır.
    [Fact]
    public void SamsungFailureExplainsRestartAndSourceSwitching()
    {
        var text = Localizer.ForLanguage("tr");
        var unreachable = TvAppMessages.Problem(new TvAppState(TvAppKind.Failed, Error: DevModeError.Unreachable), TvBrand.Samsung, text, "x.log");
        Assert.Contains("2 saniye", unreachable);
        Assert.DoesNotContain("Anynet+", unreachable);
        var dropped = TvAppMessages.Problem(new TvAppState(TvAppKind.Failed, Error: DevModeError.ConnectionLost), TvBrand.Samsung, text, "x.log");
        Assert.Contains("Anynet+ (HDMI-CEC)", dropped);
        Assert.Contains("Otomatik Kaynak Değiştirme", dropped);
        Assert.EndsWith("x.log", dropped);
        Assert.NotEqual(TvAppMessages.SourceSwitchTip, text[TvAppMessages.SourceSwitchTip]);
        Assert.NotEqual(TvAppMessages.RestartTip, text[TvAppMessages.RestartTip]);
        // LG'de Samsung'a özgü ipucu çıkmaz.
        var lg = TvAppMessages.Problem(new TvAppState(TvAppKind.Failed, Error: DevModeError.Unreachable), TvBrand.Lg, text, "x.log");
        Assert.DoesNotContain("2 saniye", lg);
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

    [Fact]
    public async Task WorkingAppWithoutKeyAsksNothing()
    {
        var controller = Make(new FakeServices { DevMode = true });
        await controller.PairAsync(Tv);
        Assert.Equal(TvAppKind.Unknown, controller.TvApp.Kind);
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
}

internal sealed class FakeDubbingModel(bool installed) : IDubbingModel
{
    public bool IsInstalled => installed;
    public long DownloadBytes => 0;
    public Task DownloadAsync(IProgress<double> progress, CancellationToken cancellationToken) => Task.CompletedTask;
    public byte[] VoiceFile(DubbingVoice voice) => [];
    public ISpeechSynthesizer CreateSynthesizer() => throw new NotSupportedException();
}
