// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;

namespace CouchSubs.Shell;

public static class StoreKeys
{
    public const string AccountId = "accountId";
    public const string Console = "console";
    public const string Tv = "tv";
    public const string TvKey = "tvKey";
    public const string TvDevKey = "tvDevKey";
    /// <summary>Samsung ve Android TV'ye CouchSubs'ın kurduğu sürüm (LG'de sürüm TV'den okunur).</summary>
    public const string TvAppVersion = "tvAppVersion";
    /// <summary>LG geliştirici modu süresinin son uzatıldığı an.</summary>
    public const string DevSessionRenewed = "devSessionRenewed";
    /// <summary>Kullanıcının DeepL anahtarı (isteğe bağlı çevrimiçi çeviri).</summary>
    public const string DeepLKey = "deepLKey";
    /// <summary>Kullanıcının yapay zekâ anahtarları (isteğe bağlı çevrimiçi çeviri).</summary>
    public const string GeminiKey = "geminiKey";
    public const string OpenAiKey = "openAIKey";
    public const string ClaudeKey = "claudeKey";
    /// <summary>Yerel model sunucusunun (Ollama, LM Studio) isteğe bağlı anahtarı.</summary>
    public const string LocalAiKey = "localAIKey";
    /// <summary>Kurulum sihirbazı bitti. TV'siz kurulumda (altyazı bilgisayar ekranında) ana ekranı bu açar.</summary>
    public const string SetupComplete = "setupComplete";
}

/// <summary>Altyazının gösterileceği yer (Mac'teki SubtitleOutput ile aynı).</summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<SubtitleOutput>))]
public enum SubtitleOutput { Tv, Computer, Both }

public static class SubtitleOutputs
{
    public static bool ShowsOnTv(this SubtitleOutput output) => output != SubtitleOutput.Computer;
    public static bool ShowsOnComputer(this SubtitleOutput output) => output != SubtitleOutput.Tv;
}

/// <summary>Uygulama pencerelerinin görünümü (Mac'teki AppAppearance ile aynı). Onaylı tasarım koyudur; varsayılan da odur.</summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<AppAppearance>))]
public enum AppAppearance { Dark, Light, System }

/// <summary>Bilgisayar ekranındaki altyazı penceresinin yeri ve genişliği (WPF birimiyle; tüm ekranları kapsayan düzlemde).</summary>
public sealed record OverlayBounds(double Left, double Top, double Width);

/// <summary>
/// Ayarlardaki çeviri motoru seçimi. Ücretsiz olan cihaz üstü modeldir; bulut motorları kullanıcının kendi anahtarıyla
/// çalışır; yerel model (Ollama, LM Studio) kullanıcının bilgisayarında çalışır, anahtarı isteğe bağlıdır (Mac'teki
/// TranslationEngine ile aynı).
/// </summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<TranslationEngine>))]
public enum TranslationEngine { Free, DeepL, Gemini, OpenAi, Claude, Local }

public static class TranslationEngines
{
    public static AiProvider? Provider(this TranslationEngine engine) => engine switch
    {
        TranslationEngine.Gemini => AiProvider.Gemini,
        TranslationEngine.OpenAi => AiProvider.OpenAi,
        TranslationEngine.Claude => AiProvider.Claude,
        TranslationEngine.Local => AiProvider.Local,
        _ => null,
    };

    public static TranslationEngine Engine(this AiProvider provider) => provider switch
    {
        AiProvider.Gemini => TranslationEngine.Gemini,
        AiProvider.OpenAi => TranslationEngine.OpenAi,
        AiProvider.Local => TranslationEngine.Local,
        _ => TranslationEngine.Claude,
    };

    /// <summary>Hizmetin adı (marka adı; çevrilmez). Yerel modelin adı çevrilir.</summary>
    public static string DisplayName(this TranslationEngine engine) =>
        engine == TranslationEngine.Local ? Localizer.Current["Local model"] : engine.Provider()?.DisplayName() ?? "DeepL";

    /// <summary>
    /// Çevrimiçi motor hatasının kullanıcıya söylenişi (ayarlar ve ana ekran aynı metni kullanır; Mac ile aynı). Yerel
    /// modelde <paramref name="server"/> sunucunun adresini ve modeli iletiye koyar.
    /// </summary>
    public static string Describe(this OnlineKeyState state, TranslationEngine engine, Localizer text, LocalAiServer? server = null)
    {
        if (engine == TranslationEngine.Local) return state.DescribeLocal(server, text);
        var name = engine.DisplayName();
        return state switch
        {
            OnlineKeyState.Valid => text["It works."],
            OnlineKeyState.Invalid => text.Format("%@ did not accept this key. Copy it again from your account page.", name),
            OnlineKeyState.QuotaExceeded => text.Format("Your %@ account has no credit left or has reached its limit.", name),
            OnlineKeyState.ModelRejected => text.Format("%@ did not accept the request. Choose the other model or try again later.", name),
            _ => text.Format("%@ could not be reached. Check your internet connection.", name),
        };
    }

    /// <summary>Yerel model sunucusunun (Ollama, LM Studio) hatası; sunucunun türüne göre ne yapılacağı söylenir (Mac ile aynı).</summary>
    public static string DescribeLocal(this OnlineKeyState state, LocalAiServer? server, Localizer text)
    {
        server ??= LocalAiServer.Create(LocalAiServer.OllamaUrl, LocalAiServer.DefaultModel)!;
        return state switch
        {
            OnlineKeyState.Valid => text["It works."],
            OnlineKeyState.Invalid => text["The local model server did not accept the API key. Check the key, or remove it if the server does not need one."],
            OnlineKeyState.QuotaExceeded => text["The local model server is busy. Try again in a moment."],
            OnlineKeyState.ModelRejected when server.Kind == LocalAiServerKind.LmStudio =>
                text.Format("LM Studio does not have the model %@. Download and load it in LM Studio, or check the model name.", server.Model),
            OnlineKeyState.ModelRejected => text.Format("The model %1$@ is not on the local server. Download it: ollama pull %1$@", server.Model),
            _ => server.Kind switch
            {
                LocalAiServerKind.Ollama => text.Format("Ollama is not running: %1$@ could not be reached, or the model did not answer in time. Open Ollama and download the model: ollama pull %2$@", server.Address, server.Model),
                LocalAiServerKind.LmStudio => text.Format("LM Studio is not running: %@ could not be reached, or the model did not answer in time. Open LM Studio, load the model and start the local server.", server.Address),
                _ => text.Format("The local model server at %@ could not be reached, or the model did not answer in time. Check the address and that the server is running.", server.Address),
            },
        };
    }

    /// <summary>Şifreli depodaki anahtar adı; ücretsiz motorda null.</summary>
    public static string? StoreKey(this TranslationEngine engine) => engine switch
    {
        TranslationEngine.DeepL => StoreKeys.DeepLKey,
        TranslationEngine.Gemini => StoreKeys.GeminiKey,
        TranslationEngine.OpenAi => StoreKeys.OpenAiKey,
        TranslationEngine.Claude => StoreKeys.ClaudeKey,
        TranslationEngine.Local => StoreKeys.LocalAiKey,
        _ => null,
    };
}

/// <summary>Kalıcı ayarlar (şifreli depo değil, sıradan ayar dosyası).</summary>
public sealed record UserSettings
{
    public CropRegion Region { get; init; } = new();
    private readonly AreaPreset? areaPreset;
    /// <summary>
    /// Altyazı bölgesinin hazır seçimi (alt, üst, tam ekran ya da özel). Eski ayar dosyalarında yoktur; o zaman
    /// <see cref="Region"/>'dan çıkarılır.
    /// </summary>
    public AreaPreset AreaPreset { get => areaPreset ?? AreaPresets.Matching(Region); init => areaPreset = value; }
    /// <summary>Ek bölge 1 (ör. sağ üstteki görev paneli); null ise kapalı. Num 1 tuşuyla bir kez okunup çevrilir.</summary>
    public CropRegion? ExtraRegion1 { get; init; }
    /// <summary>Ek bölge 2 (ör. sağ alttaki bilgi kutusu); null ise kapalı. Num 2 tuşuyla bir kez okunup çevrilir.</summary>
    public CropRegion? ExtraRegion2 { get; init; }
    /// <summary>Ek bölge 3 (ör. ekranın ortası); null ise kapalı. Num 3 tuşuyla bir kez okunup çevrilir.</summary>
    public CropRegion? ExtraRegion3 { get; init; }
    /// <summary>Ek bölgelerin çevirisi nerede gösterilir (TV'de, bilgisayarda ya da ikisinde de).</summary>
    public ResultTarget ExtraTarget1 { get; init; } = ResultTarget.Tv;
    public ResultTarget ExtraTarget2 { get; init; } = ResultTarget.Tv;
    public ResultTarget ExtraTarget3 { get; init; } = ResultTarget.Tv;
    /// <summary>Serbest alan çevirisinin (Num 5) sonucu nerede gösterilir.</summary>
    public ResultTarget FreeAreaTarget { get; init; } = ResultTarget.Tv;
    public SubtitleStyle Style { get; init; } = new();
    /// <summary>
    /// Gelişmiş: bozuk okunan satırın daha iyi okuma için en çok bekletileceği süre (ms; 0: beklenmez). Eski kayıtlar
    /// varsayılanla açılır.
    /// </summary>
    public int MisreadWaitMs { get; init; } = SubtitlePipeline.PackWaitMs;
    /// <summary>Gelişmiş: yarım görünen satırın tamamı için en çok bekletileceği süre (ms; 0: beklenmez).</summary>
    public int PartialWaitMs { get; init; } = SubtitlePipeline.CleanWaitMs;
    public string SourceLanguage { get; init; } = "en";
    public string TargetLanguage { get; init; } = "tr";
    public DubbingSettings Dubbing { get; init; } = new();
    /// <summary>
    /// Açıksa çeviri <see cref="OnlineEngine"/> ile yapılır (anahtarı kayıtlıysa); kapalıysa ya da hizmete ulaşılamazsa
    /// cihaz üstü model. Eski sürümlerde yalnız DeepL vardı; o kayıtlar DeepL ile açılır.
    /// </summary>
    public bool OnlineTranslation { get; init; }
    /// <summary>Seçili çevrimiçi motor (hiçbir zaman Free değildir).</summary>
    public TranslationEngine OnlineEngine { get; init; } = TranslationEngine.DeepL;
    /// <summary>Seçili yapay zekâ modelleri (listedeki kimlikler; bkz. <see cref="AiProviders.Models"/>).</summary>
    public string GeminiModel { get; init; } = AiProvider.Gemini.DefaultModel().Id;
    public string OpenAiModel { get; init; } = AiProvider.OpenAi.DefaultModel().Id;
    public string ClaudeModel { get; init; } = AiProvider.Claude.DefaultModel().Id;
    /// <summary>
    /// Yerel model sunucusunun adresi (Ollama: http://localhost:11434/v1, LM Studio: http://localhost:1234/v1) ve
    /// kullanıcının yazdığı model adı.
    /// </summary>
    public string LocalAiBaseUrl { get; init; } = LocalAiServer.OllamaUrl;
    public string LocalAiModel { get; init; } = LocalAiServer.DefaultModel;
    /// <summary>Altyazı TV'de mi, bilgisayar ekranındaki pencerede mi, ikisinde de mi. Eski kayıtlar TV ile açılır.</summary>
    public SubtitleOutput Output { get; init; } = SubtitleOutput.Tv;
    /// <summary>Bilgisayar ekranındaki altyazı penceresi tıklamaları alttaki pencereye (oyun, PS Remote Play) geçirir.</summary>
    public bool OverlayClickThrough { get; init; }
    /// <summary>Altyazı penceresinin son yeri; null ise ana ekranın altında ortada açılır.</summary>
    public OverlayBounds? Overlay { get; init; }
    /// <summary>Oyun paketlerindeki hazır Türkçe çeviriler kullanılır (yalnız İngilizce→Türkçe).</summary>
    public bool GamePacks { get; init; } = true;
    /// <summary>Pakette bulunmayan İngilizce satırlar ortak havuza gönderilir (anonim; bkz. <see cref="LinePool"/>).</summary>
    public bool SharePool { get; init; } = LinePool.EnabledByDefault;
    /// <summary>Koyu, açık ya da sistemle aynı. Eski ayar dosyalarında yoktur; onlar da koyu açılır.</summary>
    public AppAppearance Appearance { get; init; } = AppAppearance.Dark;

    /// <summary>Ayarlarda seçili motor: çevrimiçi çeviri kapalıysa ücretsiz olan.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public TranslationEngine Engine => OnlineTranslation && OnlineEngine != TranslationEngine.Free ? OnlineEngine : TranslationEngine.Free;

    public UserSettings WithEngine(TranslationEngine engine) => engine == TranslationEngine.Free
        ? this with { OnlineTranslation = false }
        : this with { OnlineTranslation = true, OnlineEngine = engine };

    /// <summary>Yapay zekâ hizmetinin seçili model kimliği.</summary>
    public string ModelFor(AiProvider provider) => provider switch
    {
        AiProvider.Gemini => GeminiModel,
        AiProvider.OpenAi => OpenAiModel,
        AiProvider.Local => LocalAiModel,
        _ => ClaudeModel,
    };

    public UserSettings WithModel(AiProvider provider, string id) => provider switch
    {
        AiProvider.Gemini => this with { GeminiModel = id },
        AiProvider.OpenAi => this with { OpenAiModel = id },
        AiProvider.Local => this with { LocalAiModel = id },
        _ => this with { ClaudeModel = id },
    };

    /// <summary>Yerel model sunucusu; adres geçersizse null.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public LocalAiServer? LocalAiServer => CouchSubs.Core.LocalAiServer.Create(LocalAiBaseUrl, AiProvider.Local.Model(LocalAiModel).Id);

    /// <summary>Listede olmayan kayıtlı modeller (eski ayar ya da listeden çıkarılan model) varsayılana döner.</summary>
    public UserSettings WithCuratedModels() => Enum.GetValues<AiProvider>()
        .Aggregate(this, (settings, provider) => settings.WithModel(provider, provider.Model(settings.ModelFor(provider)).Id));

    /// <summary>Hazır seçimi uygular: bölge seçimin bölgesi olur (Özel'de kayıtlı bölge kalır).</summary>
    public UserSettings WithAreaPreset(AreaPreset preset) =>
        this with { AreaPreset = preset, Region = preset.Region() ?? Region };

    /// <summary>Bölge elle değişti (kaydırıcı ya da çerçeve): seçim Özel olur.</summary>
    public UserSettings WithCustomRegion(CropRegion region) => this with { AreaPreset = AreaPreset.Custom, Region = region };

    /// <summary>Ek bölgenin sayısı; <see cref="ExtraRegion"/> 1..ExtraRegionCount arasında çalışır.</summary>
    public const int ExtraRegionCount = 3;

    /// <summary>1, 2 ya da 3 numaralı ek bölge; kapalıysa null.</summary>
    public CropRegion? ExtraRegion(int slot) => slot switch { 1 => ExtraRegion1, 2 => ExtraRegion2, 3 => ExtraRegion3, _ => null };

    public UserSettings WithExtraRegion(int slot, CropRegion? region) => slot switch
    {
        1 => this with { ExtraRegion1 = region },
        2 => this with { ExtraRegion2 = region },
        3 => this with { ExtraRegion3 = region },
        _ => this,
    };

    /// <summary>Ek bölgenin çevirisinin gösterileceği yer.</summary>
    public ResultTarget ExtraTarget(int slot) => slot switch { 1 => ExtraTarget1, 2 => ExtraTarget2, 3 => ExtraTarget3, _ => ResultTarget.Tv };

    public UserSettings WithExtraTarget(int slot, ResultTarget target) => slot switch
    {
        1 => this with { ExtraTarget1 = target },
        2 => this with { ExtraTarget2 = target },
        3 => this with { ExtraTarget3 = target },
        _ => this,
    };
}

/// <summary>Tek seferlik çevirinin sonucunun gösterileceği yer.</summary>
public enum ResultTarget { Tv, Pc, Both }

/// <summary>Hesap kimliği, PS5 ve TV anahtarları (gerçekte DPAPI ile şifreli dosya).</summary>
public interface IAppStore
{
    void Save<T>(string key, T value);
    T? Load<T>(string key);
    void Remove(string key);
}

public interface ISettingsStore
{
    UserSettings Load();
    void Save(UserSettings settings);
}

/// <summary>Çeviri sürerken bilgisayarın boşta uykuya geçmesini engeller.</summary>
public interface ISleepGuard
{
    void Begin();
    void End();
}

/// <summary>TV uygulamasını açık tutan görevli (gerçekte TvKeeper).</summary>
public interface IKeeper
{
    void Start(TimeSpan interval);
    void Stop();
    void Reconnect();
}

/// <summary>Cihaz üstü çeviri modeli: kurulu mu, indir, çevirmen oluştur.</summary>
public interface ITranslationModel
{
    bool IsSupported(string source, string target);
    bool IsInstalled(string source, string target);
    Task DownloadAsync(string source, string target, IProgress<double> progress, CancellationToken cancellationToken);
    ITextTranslator Create(string source, string target);

    /// <summary>Model kurulu ama çeviri motoru bu bilgisayarda açılamadı (ör. ONNX Runtime yüklenemedi).</summary>
    bool EngineFailed => false;

    /// <summary><see cref="EngineFailed"/> true olunca bir kez, herhangi bir iş parçacığından çağrılır.</summary>
    event Action? EngineFailure { add { } remove { } }
}

/// <summary>Dış dünyayla (PS5, PSN, TV, OCR, çeviri) konuşan her şey; testlerde sahtesi kullanılır.</summary>
public interface IAppServices
{
    Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync();
    Task<byte[]> AccountIdFromRedirectAsync(Uri redirect);
    Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin);
    Task<IReadOnlyList<LgTv>> DiscoverTvsAsync();
    /// <summary>TV ile eşleşir ve TV uygulamasını sunucu adresiyle başlatmayı dener.</summary>
    Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server);
    IStreamSession MakeStream(RegisteredConsole console, byte[] accountId);
    /// <param name="appConnected">TV uygulaması bilgisayara bağlı mı (Samsung'da bağlıyken TV'ye dokunulmaz).</param>
    /// <param name="onMoved">TV ağda yeni bir adreste bulununca çağrılır.</param>
    IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved);
    /// <summary>Uygulamayla gelen TV paketinin sürümü (geliştirici derlemesinde paket olmayabilir).</summary>
    string? BundledTvAppVersion { get; }
    Task<bool> IsDevModeOnAsync(string host);
    Task<string> FetchDevKeyAsync(string host, string passphrase);
    Task<string?> InstalledTvAppVersionAsync(string host, string devKey);
    Task InstallTvAppAsync(string host, string devKey);
    /// <summary>LG geliştirici modunun süresini baştan başlatır; kalan saati döner (bilinmiyorsa null).</summary>
    Task<int?> RenewDevSessionAsync(string host, string devKey);
    /// <summary>Samsung ve Android TV için uygulamayla gelen paket (geliştirici derlemesinde olmayabilir).</summary>
    BundledTvApp? BundledApp(TvBrand brand);
    Task<bool> IsSamsungDevModeOnAsync(string host);
    /// <summary>TV'deki sürüme bakar, eksik ya da eskiyse kurar; TV'deki sürümü ve kurulup kurulmadığını döner.</summary>
    Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, Action<TvInstallEvent> onEvent);
    Task<bool> IsAndroidDebugOnAsync(string host);
    /// <summary>Ağda ADB'si açık cihazlar.</summary>
    Task<IReadOnlyList<string>> ScanAndroidTvsAsync();
    /// <summary>Eksikse ya da eskiyse kurar; TV'deki sürümü döner.</summary>
    Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, Action<TvInstallEvent> onEvent);
    /// <summary>Oyun dili için yazı tanıyıcı; bilgisayarda hiç OCR dili yoksa null.</summary>
    ITextReader? MakeReader(string language);
    /// <summary>
    /// Oyun dilinin kendi yazı tanıma paketi yüklü mü. Değilse okuyucu sistemin diliyle (ör. Türkçe) okur ve İngilizce
    /// altyazı "thıs.messs" gibi bozulur; kullanıcıya paketi yüklemesi söylenir.
    /// </summary>
    bool HasOcrLanguage(string language) => true;
    ITranslationModel Translation { get; }
    /// <summary>DeepL çevirmeni; <paramref name="fallback"/> DeepL'e ulaşılamayan satırları çevirir. Bu derlemede yoksa null.</summary>
    ITextTranslator? MakeOnlineTranslator(string key, ITextTranslator? fallback) => null;
    Task<OnlineKeyCheck> CheckOnlineKeyAsync(string key) => Task.FromResult(new OnlineKeyCheck(OnlineKeyState.Unreachable));
    /// <summary>Yapay zekâ çevirmeni; <paramref name="fallback"/> hizmete ulaşılamayan satırları çevirir. Bu derlemede yoksa null.</summary>
    ITextTranslator? MakeAiTranslator(AiProvider provider, string key, string model, ITextTranslator? fallback) => null;
    /// <summary>Yapay zekâ anahtarını örnek bir satırı çevirerek dener.</summary>
    Task<AiTestResult> TestAiKeyAsync(AiProvider provider, string key, string model) => Task.FromResult(new AiTestResult(OnlineKeyState.Unreachable));
    /// <summary>Yerel model (Ollama, LM Studio) çevirmeni; anahtar boş olabilir. Bu derlemede yoksa null.</summary>
    ITextTranslator? MakeLocalAiTranslator(LocalAiServer server, string key, ITextTranslator? fallback) => null;
    /// <summary>Yerel model sunucusunu örnek bir satırı çevirerek dener ("Bağlantıyı dene").</summary>
    Task<AiTestResult> TestLocalAiAsync(LocalAiServer server, string key) => Task.FromResult(new AiTestResult(OnlineKeyState.Unreachable));
    /// <summary>Türkçe dublaj modeli; bu derlemede yoksa null.</summary>
    IDubbingModel? Dubbing => null;
    /// <summary>Hızlı dublaj: sistemin kendi Türkçe sesi (Windows'ta Microsoft Tolga); yoksa null.</summary>
    IDubbingModel? FastDubbing => null;
    /// <summary>Bilgisayardan ses çalma (dublaj).</summary>
    IAudioOutput? Audio => null;
    /// <summary>Uygulama güncellemesi; geliştirici derlemesinde null.</summary>
    IUpdater? Updater => null;
    /// <summary>Windows Güvenlik Duvarı izni; Windows dışında ve testlerde null (hiçbir şey önerilmez).</summary>
    IFirewall? Firewall => null;
    /// <summary>Oyun çeviri paketleri (uygulamayla gelenler ve kullanıcının klasöründekiler); bu derlemede yoksa null.</summary>
    GamePackLibrary? GamePacks => null;
    /// <summary>Satırın paketteki Türkçesi: konuşmacı etiketi, satır ve cümle parçalarıyla (CouchSubs.Translation.PackLookup).</summary>
    PackMatch? FindInPacks(string text) => null;
    /// <summary>Ortak havuz; testlerde null (hiçbir şey gönderilmez).</summary>
    LinePool? Pool => null;
    /// <summary>Altyazı geçmişinin dosyası (%LOCALAPPDATA%\CouchSubs\history.json); testlerde null (diske yazılmaz).</summary>
    string? HistoryFile => null;
}

/// <param name="Launched">false ise TV uygulaması açılamadı; büyük olasılıkla TV'de kurulu değil.</param>
public sealed record TvPairing(string Key, bool Launched);

/// <param name="Path">Paket dosyası.</param>
public sealed record BundledTvApp(string Path, string Version);

public enum TvInstallEventKind { SignIn, ApproveOnTv, Progress }

/// <summary>Samsung ve Android TV kurulumu sırasında kullanıcıdan bir şey isteyen olay.</summary>
/// <param name="Step">Progress'te kurulum adımı (reading, signin, certificate, signing, installing, uninstalling).</param>
public sealed record TvInstallEvent(TvInstallEventKind Kind, Uri? Url = null, string? Step = null);

/// <summary>
/// SignIn: Samsung sertifikası için tarayıcıda Samsung hesabıyla giriş bekleniyor. ApproveOnTv: Android TV ekranında
/// hata ayıklama izni bekleniyor.
/// </summary>
public enum TvAppKind { Unknown, Working, UpToDate, DevModeOff, NeedsPassphrase, Failed, SignIn, ApproveOnTv }

/// <summary>TV uygulamasının kurulum durumu.</summary>
public sealed record TvAppState(TvAppKind Kind, string? Version = null, DevModeError? Error = null, Uri? Url = null, string? Reason = null)
{
    public static readonly TvAppState Unknown = new(TvAppKind.Unknown);
}

/// <summary>Durum noktasının rengi: bağlı (yeşil), sorun var (turuncu), boşta (gri).</summary>
public enum StatusTone { Idle, Warning, Good }

/// <summary><c>BetterTranslation</c>: isteğe bağlı ücretsiz Gemini anahtarı; atlanabilir (Mac'teki betterTranslation).</summary>
public enum OnboardingStep { Welcome, SecondAccount, PsnLogin, Console, Tv, Translation, Test, BetterTranslation, Done }

public enum AppError
{
    InvalidPin, InvalidLogin, MissingAccount, WrongAccount, RegistrationFailed, ConsoleNoAnswer, ConsoleInUse, ConsoleCrashed, ConsoleVersion,
    /// <summary>PS5 seçilmedi ve IP adresi yazılmadı.</summary>
    MissingConsole,
    WrongCode, ConsoleNoReply, BadAddress,
    /// <summary>PSN girişinin ayrı ayrı anlatılan sonuçları (eskiden hepsi InvalidLogin'di).</summary>
    LoginRefused, LoginRateLimited, LoginServer, LoginNetwork, LoginBadResponse, LoginWindowClosed, LoginPageFailed,
}

/// <summary>Kullanıcıya gösterilecek, ne yapması gerektiğini söyleyen hata.</summary>
public sealed class AppException(AppError error, string message) : Exception(message)
{
    public AppError Error { get; } = error;

    public static string Describe(AppError error, Localizer text) => text[error switch
    {
        AppError.InvalidPin => "The code must be 8 digits.",
        AppError.InvalidLogin => "Sign-in did not complete. Please try again.",
        AppError.MissingAccount => "Sign in to PlayStation Network first.",
        AppError.WrongAccount => "The PS5 did not recognise this account. Get the code from the PS5 user signed in with the account you used in CouchSubs, or sign in again with that user's account.",
        AppError.ConsoleNoAnswer => "The PS5 did not answer. Make sure it is on (not in rest mode), on the same network as this computer, and that Remote Play is turned on, then try again.",
        AppError.ConsoleInUse => "Remote Play is in use on another device. Close it there and enter a new code.",
        AppError.ConsoleCrashed => "The PS5 Remote Play service stopped unexpectedly. Restart the PS5 and enter a new code.",
        AppError.ConsoleVersion => "This PS5 system version is not supported yet. Update CouchSubs and try again.",
        AppError.MissingConsole => "No PS5 found. Make sure it is on and on the same network, or enter its IP address.",
        AppError.WrongCode => "The code is wrong or has expired. Open Pair Device again on the PS5 and enter the new code.",
        AppError.ConsoleNoReply => "The PS5 received the request but did not answer in time. Open Pair Device again on the PS5 and enter the new code.",
        AppError.BadAddress => "No PS5 found at this address. Check the PS5's IP address under Settings › Network › Connection Status.",
        AppError.LoginRefused => "Sony did not complete the sign-in. Wait a minute, then press Sign in again and sign in with the second account.",
        AppError.LoginRateLimited => "Sony received too many sign-in attempts. Wait about 15 minutes, then sign in again.",
        AppError.LoginServer => "Sony's sign-in server returned an error. Wait a few minutes, then sign in again.",
        AppError.LoginNetwork => "Could not reach Sony's sign-in server. Check the internet connection, then sign in again.",
        AppError.LoginBadResponse => "Sony's answer could not be read. Sign in again; if it keeps happening, update CouchSubs.",
        AppError.LoginWindowClosed => "The sign-in window was closed before sign-in finished. Press Sign in and finish signing in in the window.",
        AppError.LoginPageFailed => "Sony's sign-in page could not be loaded. Check the internet connection, then sign in again.",
        _ => "The PS5 refused the code. Open Pair Device again on the PS5 and enter the new code.",
    }];
}
