// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using CouchSubs.Core;
using CouchSubs.Core.Dubbing;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;

namespace CouchSubs.Shell;

/// <summary>
/// Uygulamanın durumu ve akışı (Mac'teki AppModel'in karşılığı): kurulum sihirbazı, çeviriyi
/// başlatma/durdurma, PS5 ve TV durumları. Arayüz bu nesneye bağlanır; olaylar <c>post</c> ile
/// arayüz iş parçacığına aktarılır.
/// </summary>
public sealed class AppController : INotifyPropertyChanged, IDisposable
{
    public const string TvAppId = "com.couchsubs.tv";
    public const int DefaultServerPort = 8787;

    private readonly IAppServices services;
    private readonly IAppStore store;
    private readonly ISettingsStore settingsStore;
    private readonly ISleepGuard sleep;
    private readonly Localizer text;
    private readonly Action<Action> post;

    private OnboardingStep step;
    private byte[]? accountId;
    private RegisteredConsole? console;
    private GameConsoleKind consoleKind;
    private bool consoleKindLocked;
    private string? xboxToken;
    private XboxConsole? xboxConsole;
    private int xboxGeneration;
    private bool xboxNameChecked;
    private LgTv? tv;
    private TvAppState tvApp = TvAppState.Unknown;
    /// <summary>Son eşleşmede TV uygulaması açılamadı.</summary>
    private bool tvAppMissing;
    /// <summary>TV uygulaması denetimi sürüyor (bekleme ekranı ve çeviri başlangıcı aynı anda çağırabilir).</summary>
    private bool refreshingTvApp;
    /// <summary>"TV uygulamasını yeniden kur"a basıldı: Samsung ve Android TV'de uygulama kuruluysa da TV'de açılır.</summary>
    private bool openTvAppAfterCheck;
    /// <summary>Birden çok Android TV bulununca kullanıcının seçtiği TV; yalnız bir sonraki denetimde kullanılır. Kurulum
    /// başarılı olursa TV'nin adresi zaten kaydedilir; olmazsa bir sonraki denemede yeniden sorulur (#425).</summary>
    private string? androidTvChoice;
    private int? devModeHoursLeft;
    private UserSettings settings;
    private bool isRunning;
    private bool isStarting;
    private SessionState sessionState = SessionState.Disconnected(DisconnectKind.Stopped);
    private int tvClients;
    private string lastSource = "";
    private string lastTranslation = "";
    private TranslatorStatus translatorStatus = TranslatorStatus.Ready;
    private OnlineKeyState? onlineIssue;
    private bool ocrMissing;
    private Frame? lastFrame;
    private bool modelDownloading;
    private double modelProgress;
    private string? modelError;
    private Task? modelDownload;

    private SubtitleServer server = new(DefaultServerPort);
    private bool serverStarted;
    private IStreamSession? session;
    private IKeeper? keeper;
    private SubtitlePipeline? pipeline;
    /// <summary>Hattın yazı okuyucusu; ek bölgelerin tek seferlik okuması da bunu kullanır.</summary>
    private ITextReader? activeReader;
    private int extraBusy;
    private bool subtitlesPaused;
    /// <summary>Oyundaki altyazının son görüldüğü yer; deneme altyazısı TV'de oraya yerleşir.</summary>
    private TextBox? lastSubtitleBox;
    /// <summary>Hatta aynı anda tek kare girer; durdurma ve yeni hat kapıyı sıfırlar, takılan okuma hattı yeniden kurdurur.</summary>
    private readonly FrameGate frameGate = new();
    private Dubber? dubber;
    private string? updateVersion;
    private bool updating;
    private double updateProgress;
    private string? updateError;
    private bool dubbingDownloading;
    private double dubbingProgress;
    private string? dubbingError;
    private IReadOnlyList<GamePackLibrary.Info> installedPacks = [];
    private Timer? poolTimer;
    /// <summary>Bağlıyken iki dakikada bir PS5'e çalışan oyunu sorar (havuza giden satırlar oyunla gider).</summary>
    private CancellationTokenSource? gameProbe;
    public static readonly TimeSpan GameProbeInterval = TimeSpan.FromMinutes(2);
    /// <summary>
    /// Oynanan oyun: PS5'in bildirdiği, kullanıcının seçtiği ya da paketten tanınan (havuza giden satırlar bu oyunla gider;
    /// Mac ve iPhone'daki GameChoice ile aynı davranış).
    /// </summary>
    private readonly GameSense gameSense = new();
    private RunningGame? publishedGame;
    private string? playedGame;
    private bool askingGame;
    private CancellationTokenSource? gameAsk;
    /// <summary>Bu oturumda geri alınan ya da istenmeyen alan profilleri (oturum boyunca yeniden uygulanmaz).</summary>
    private readonly HashSet<string> declinedAreaProfiles = [];
    /// <summary>Paketten tanınan oyunun önerilen profili ("Kayıtlı alanlar kullanılsın mı?"); yoksa null.</summary>
    private string? offeredAreaProfile;
    private Timer? packTimer;
    private string metricsText = "";
    /// <summary>Çevrilen satırların geçmişi (arayüz iş parçacığında değişir).</summary>
    private readonly SubtitleHistory history;
    /// <summary>Geçmiş dosyaya sırayla yazılır; yazmalar üst üste binmez.</summary>
    private Task historySave = Task.CompletedTask;

    public event PropertyChangedEventHandler? PropertyChanged;

    public AppController(IAppServices services, IAppStore store, ISettingsStore settingsStore, ISleepGuard sleep, Localizer text, Action<Action> post)
    {
        this.services = services;
        this.store = store;
        this.settingsStore = settingsStore;
        this.sleep = sleep;
        this.text = text;
        this.post = post;
        var accessKey = store.Load<string>(StoreKeys.SubtitleAccessKey);
        if (string.IsNullOrEmpty(accessKey))
        {
            accessKey = SubtitleAccess.CreateKey();
            store.Save(StoreKeys.SubtitleAccessKey, accessKey);
        }
        server.RotateKey(accessKey);
        if (services.Xbox is { } xbox) xbox.TokenUpdated += OnXboxTokenUpdated;
        accountId = store.Load<byte[]>(StoreKeys.AccountId);
        console = store.Load<RegisteredConsole>(StoreKeys.Console);
        consoleKind = store.Load<GameConsoleKind?>(StoreKeys.ConsoleKind) ?? GameConsoleKind.PlayStation;
        consoleKindLocked = store.Load<bool?>(StoreKeys.ConsoleKindLocked) ?? false;
        xboxToken = store.Load<string>(StoreKeys.XboxToken);
        xboxConsole = store.Load<XboxConsole>(StoreKeys.XboxConsole);
        if (xboxConsole is { } savedXbox && RepairMisreadName(savedXbox.Name) is { } repairedName)
        {
            xboxConsole = savedXbox with { Name = repairedName };
            store.Save(StoreKeys.XboxConsole, xboxConsole);
        }
        tv =store.Load<LgTv>(StoreKeys.Tv);
        var loaded = settingsStore.Load();
        settings = loaded.WithCuratedModels() with
        {
            CpuTranslationThreads = CpuThreadOptions.Normalize(loaded.CpuTranslationThreads, Environment.ProcessorCount),
        };
        // Uygulama oturum sürerken kapandıysa oyunun profili açık kalmış olabilir: açılışta genel alanlar geri gelir.
        if (settings.ActiveAreaProfile is not null || settings.GeneralAreas is not null) settings = settings.WithGeneralAreas();
        services.Translation.SelectCpuThreads(settings.CpuTranslationThreads);
        services.Translation.SelectDevice(settings.TranslationDevice);
        // Listede olmayan model varsayılana döndüyse ayar hemen kaydedilir.
        if (settings != loaded) settingsStore.Save(settings);
        var paired = tv is not null && store.Load<string>(StoreKeys.TvKey) is not null;
        // Remote Play penceresinden okurken PS5 eşleşmesi gerekmez.
        var consoleReady = consoleKind == GameConsoleKind.Xbox ? xboxToken is not null && xboxConsole is not null : accountId is not null && console is not null;
        var ready = (!IsXbox && (settings.FrameSource is FrameSource.RemotePlayWindow or FrameSource.CaptureWindow))
                    || SetupIsComplete(store, consoleReady, paired);
        // Yarım kalan kurulum (ör. TV uygulaması kurulurken kapatıldı) PS5 kayıtlıysa TV adımından sürer.
        step = ready ? OnboardingStep.Done : consoleReady ? OnboardingStep.Tv : OnboardingStep.Welcome;
        AttachServer();
        StartPacksAndPool();
        services.Translation.EngineFailure += OnEngineFailure;
        services.Translation.GpuFallback += OnGpuFallback;
        history = services.HistoryFile is { } file ? SubtitleHistory.Load(file) : new SubtitleHistory();
    }

    /// <summary>
    /// Kurulum bitmiş mi. "Bitti" yalnız sihirbazın sonuna gelinince kaydedilir (TV adımı başarıyla geçildi ya da
    /// "TV'm yok" seçildi). Sihirbaz başlarken false yazılır: Samsung'da TV eşleşip uygulama kurulurken CouchSubs
    /// kapatılırsa eşleşme kayıtlı olsa da kurulum bitmiş sayılmaz. Hiç kayıt yoksa (beta.25'ten önce kurulmuş)
    /// eskisi gibi eşleşmiş TV yeter ve "bitti" kaydedilir.
    /// </summary>
    internal static bool SetupIsComplete(IAppStore store, bool consoleReady, bool paired)
    {
        var saved = store.Load<bool?>(StoreKeys.SetupComplete);
        var ready = consoleReady && (saved ?? paired);
        if (saved is null) store.Save(StoreKeys.SetupComplete, ready);
        return ready;
    }

    /// <summary>Ücretsiz çeviri motoru açılamadı (arka planda, ısınma sırasında da olabilir): ana ekran uyarısı çıksın.</summary>
    private void OnEngineFailure() => post(RefreshTranslatorStatus);

    private void OnGpuFallback() => post(() => GpuFallbackWarning = true);

    /// <summary>Sunucunun TV sayısını, altyazı yerini ve bilgisayar ekranına giden olayları bağlar (sunucu yeniden kurulunca da).</summary>
    private void AttachServer()
    {
        server.ClientsChanged += OnClientsChanged;
        server.EventSent += OnSubtitleEvent;
        server.LegacyClientConnected += OnLegacyClient;
        server.PairingRequested += OnPairingRequest;
        server.SendsToTv = settings.Output.ShowsOnTv();
        server.SpeakerColors = settings.SpeakerColors;
    }

    private void DetachServer()
    {
        server.ClientsChanged -= OnClientsChanged;
        server.EventSent -= OnSubtitleEvent;
        server.LegacyClientConnected -= OnLegacyClient;
        server.PairingRequested -= OnPairingRequest;
    }

    public event Action<SubtitlePairing.Ticket>? TvPairingRequested;
    private void OnPairingRequest(SubtitlePairing.Ticket ticket) => post(() => {
        if (server.Pairing.Poll(ticket.Id) == "pending") TvPairingRequested?.Invoke(ticket);
    });
    public bool ResolveTvPairing(string id, bool accept) => server.Pairing.Resolve(id, accept);
    /// <summary>Onay penceresini olay anında açamayan arayüzler (Linux paneli) isteğin hâlâ beklediğini buradan sorar.</summary>
    public bool IsTvPairingPending(string id) => server.Pairing.Poll(id) == "pending";
    public async Task OpenTvPairingAsync() { await StartServerAsync(); server.Pairing.Open(); }
    public bool LegacyTvWarning => server.HasLegacyClient;
    public string ObsAddress => $"http://localhost:{ServerPort}/obs?k={server.AccessKey}";

    private void OnLegacyClient() => post(() =>
    {
        SubtitleLog.Write("TV bağlantısı geçiş izniyle anahtarsız açıldı; TV uygulamasını güncelleyin.");
        Changed(nameof(LegacyTvWarning));
        _ = RefreshTvAppAsync();
    });

    public void RotateSubtitleKey()
    {
        var key = SubtitleAccess.CreateKey();
        store.Save(StoreKeys.SubtitleAccessKey, key);
        keeper?.Stop();
        keeper = null;
        server.RotateKey(key);
        StartKeeper();
        Changed(nameof(ObsAddress), nameof(NetworkObsAddress));
    }

    // --- Durum ---

    public OnboardingStep Step
    {
        get => step;
        set
        {
            // Eşleştirme adımındaki güvenlik duvarı önerisi başka adıma taşınmaz.
            if (!Set(ref step, value, [nameof(CanAdvance), nameof(StepNumber)])) return;
            ClearFirewallPrompt();
            // Sihirbaz bitince ana ekran TV'siz de açılsın.
            if (value == OnboardingStep.Done) store.Save(StoreKeys.SetupComplete, true);
        }
    }
    public int StepCount => (int)OnboardingStep.Done - (consoleKind == GameConsoleKind.Xbox ? 1 : 0);
    public int StepNumber => Math.Min((int)step + 1 - (consoleKind == GameConsoleKind.Xbox && step > OnboardingStep.SecondAccount ? 1 : 0), StepCount);
    public GameConsoleKind ConsoleKind => consoleKind;
    public bool ConsoleKindLocked => consoleKindLocked;
    public bool IsXbox => consoleKind == GameConsoleKind.Xbox;
    public string ConsoleTitle => IsXbox ? "Xbox" : settings.FrameSource == FrameSource.CaptureWindow ? text["Selected window"] : "PS5";
    /// <summary>
    /// Ana ekrandaki "Görüntü kaynağı" satırının değeri: görüntünün nereden okunduğu, dokununca Ayarlar › Görüntü kaynağı
    /// açılır. DM'de bildirildi: ayar yalnız Ayarlar'ın alt sıralarında olduğu için bulunamıyordu. Xbox'ta seçim yok, null.
    /// </summary>
    public string? PictureSourceTitle => IsXbox ? null : text[settings.FrameSource switch
    {
        FrameSource.RemotePlayWindow => "Remote Play window on this PC",
        FrameSource.CaptureWindow => "OBS projector or game window",
        _ => "The PS5 (second account)",
    }];
    public bool HasXboxAccount => xboxToken is not null;
    public XboxConsole? SelectedXboxConsole => xboxConsole;
    public void SelectConsoleKind(GameConsoleKind kind)
    {
        if (step != OnboardingStep.Welcome || consoleKindLocked || kind == consoleKind || kind == GameConsoleKind.Xbox && services.Xbox is null) return;
        consoleKind = kind;
        store.Save(StoreKeys.ConsoleKind, kind);
        Changed(nameof(ConsoleKind), nameof(IsXbox), nameof(ConsoleTitle), nameof(StepCount), nameof(StepNumber), nameof(CanStart), nameof(CanAdvance), nameof(Ps5StatusText));
    }
    public async Task<XboxLoginChallenge> BeginXboxLoginAsync()
    {
        var login = await (services.Xbox ?? throw new InvalidOperationException(text["Xbox streaming isn't available in this version."])).BeginLoginAsync();
        OpenInBrowser(login.Url);
        return login;
    }
    public async Task CompleteXboxLoginAsync()
    {
        xboxToken = await (services.Xbox ?? throw new InvalidOperationException(text["Xbox streaming isn't available in this version."])).CompleteLoginAsync();
        store.Save(StoreKeys.XboxToken, xboxToken);
        Changed(nameof(HasXboxAccount), nameof(CanAdvance), nameof(CanStart));
    }
    private void OnXboxTokenUpdated(string token)
    {
        var generation = xboxGeneration;
        post(() =>
        {
            if (generation != xboxGeneration || !IsXbox || token == xboxToken) return;
            xboxToken = token;
            store.Save(StoreKeys.XboxToken, token);
        });
    }
    public async Task<IReadOnlyList<XboxConsole>> DiscoverXboxConsolesAsync()
    {
        var found = await (services.Xbox ?? throw new InvalidOperationException(text["Xbox streaming isn't available in this version."])).DiscoverAsync(xboxToken ?? throw new InvalidOperationException(text["Microsoft sign-in isn't finished."]));
        RenameSelectedXbox(found);
        return found;
    }

    /// <summary>
    /// Kayıtlı Xbox'ın adı listedekiyle değiştirilir: eski sürümler köprünün UTF-8 çıktısını yanlış kodlamayla okuyup
    /// "Oturma Odası"nı "Oturma OdasA+" diye kaydediyordu (#223). Konsol yeniden seçilmeden ad düzelir.
    /// </summary>
    private void RenameSelectedXbox(IReadOnlyList<XboxConsole> found)
    {
        if (xboxConsole is not { } saved || found.FirstOrDefault(item => item.Id == saved.Id) is not { } current || current.Name == saved.Name) return;
        xboxConsole = saved with { Name = current.Name };
        store.Save(StoreKeys.XboxConsole, xboxConsole);
        Changed(nameof(SelectedXboxConsole), nameof(Ps5StatusText));
    }

    /// <summary>
    /// beta.45'ten önceki sürümler köprünün UTF-8 çıktısını Windows'un ANSI kod sayfasıyla (Türkçe Windows'ta 1254) okudu,
    /// "Oturma Odası" "Oturma OdasÄ±" diye kaydedildi (#223, #268). Ad listeden tazelenene kadar ana ekranda bozuk kalıyordu.
    /// Ad o kod sayfasına geri çevrilip geçerli UTF-8 olarak çözülüyorsa düzeltilmiş adı döner. Doğru adlar ("ı" tek başına
    /// geçerli UTF-8 değildir) ve ASCII adlar dokunulmadan kalır (null).
    /// </summary>
    private static string? RepairMisreadName(string name)
    {
        if (name.All(char.IsAscii)) return null;
        var strictUtf8 = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
        foreach (var codePage in new[] { 1254, 1252 })
        {
            try
            {
                var ansi = System.Text.CodePagesEncodingProvider.Instance.GetEncoding(codePage,
                    System.Text.EncoderFallback.ExceptionFallback, System.Text.DecoderFallback.ExceptionFallback);
                if (ansi is null) continue;
                var repaired = strictUtf8.GetString(ansi.GetBytes(name));
                if (repaired != name) return repaired;
            }
            catch (ArgumentException) { /* Ad bu kod sayfasıyla bozulmamış. */ }
        }
        return null;
    }

    /// <summary>
    /// Xbox görüntüsü ilk kez gelince liste arka planda bir kez sorulur; yalnız kayıtlı adı tazeler, hata yok sayılır.
    /// Görüntü gelene kadar beklenir: köprüye o sırada yayının yenilediği jeton yüklüdür, iki istek çakışmaz.
    /// </summary>
    private async Task RefreshXboxNameAsync()
    {
        if (services.Xbox is not { } xbox || xboxToken is not { } token) return;
        var generation = xboxGeneration;
        try
        {
            var found = await xbox.DiscoverAsync(token);
            post(() => { if (generation == xboxGeneration) RenameSelectedXbox(found); });
        }
        catch (Exception) { /* Ad tazelemesi isteğe bağlıdır; yayın kendi hatasını gösterir. */ }
    }
    public void SelectXboxConsole(XboxConsole selected)
    {
        if (!selected.StreamingEnabled) return;
        xboxConsole = selected;
        store.Save(StoreKeys.XboxConsole, selected);
        Changed(nameof(SelectedXboxConsole), nameof(CanAdvance), nameof(CanStart), nameof(Ps5StatusText));
    }
    public bool HasAccount => accountId is not null;
    public RegisteredConsole? Console => console;
    public LgTv? Tv => tv;
    public bool IsRunning { get => isRunning; private set => Set(ref isRunning, value, [nameof(Ps5StatusText), nameof(Ps5Tone), nameof(TvTone), nameof(ShowsMainAccountTip)]); }
    public bool IsStarting { get => isStarting; private set => Set(ref isStarting, value); }
    public SessionState SessionState { get => sessionState; private set => Set(ref sessionState, value, [nameof(Ps5StatusText), nameof(Ps5Tone), nameof(ShowsMainAccountTip)]); }
    public string Ps5StatusText => IsXbox ? XboxStatusText()
        : settings.FrameSource == FrameSource.RemotePlayWindow
            ? WindowStatusText(sessionState, isRunning, text, installed: !RemotePlayMissing)
            : settings.FrameSource == FrameSource.CaptureWindow
                ? CaptureWindowStatusText(sessionState, isRunning, text, settings.CaptureWindow)
                : StatusText(sessionState, isRunning, text, console is null ? null : string.IsNullOrEmpty(console.Name) ? "PS5" : console.Name);
    private string XboxStatusText() => sessionState.Phase switch
    {
        SessionPhase.Streaming => text["Connected"],
        SessionPhase.Connecting => text["Connecting…"],
        _ when !isRunning => xboxConsole is null ? text["Not connected"] : text.Format("%@ is ready. It connects when you start translating.", xboxConsole.Name),
        // Denemeler bitti ya da konsol yayını reddetti: oturum durdu, yeniden denenmiyor.
        _ when sessionState.Reason is { Kind: DisconnectKind.Refused, Detail.Length: > 0 } stopped => stopped.Detail,
        _ when !string.IsNullOrWhiteSpace(sessionState.Reason?.Detail) => text.Format("Retrying the Xbox connection: %@", sessionState.Reason.Detail),
        _ => text["Retrying the Xbox connection…"],
    };
    public StatusTone Ps5Tone => Ps5ToneFor(sessionState, isRunning);
    public int TvClients { get => tvClients; private set => Set(ref tvClients, value, [nameof(TvTone), nameof(TvStatusText), nameof(CanReinstallTvApp)]); }
    public StatusTone TvTone => HasTv ? TvToneFor(tvClients, isRunning) : StatusTone.Idle;
    public string TvStatusText => !HasTv ? text["Not set up"] : tvClients > 0 ? text["Connected"] : text["Waiting for the TV app"];
    /// <summary>Eşleşmiş bir TV var.</summary>
    public bool HasTv => tv is not null && store.Load<string>(StoreKeys.TvKey) is not null;
    /// <summary>Ana ekranda TV durumu gösterilir mi (altyazı yalnız bilgisayar ekranındaysa gösterilmez).</summary>
    public bool ShowsOnTv => settings.Output.ShowsOnTv();
    public bool ShowsOnComputer => settings.Output.ShowsOnComputer();
    /// <summary>Altyazı TV'ye de gidecek ama TV eşleşmedi: ana ekranda "TV bağla" düğmesi çıkar.</summary>
    public bool NeedsTv => ShowsOnTv && !HasTv;
    /// <summary>Çeviri başlatılabilir mi: PS5 kurulu ve altyazının gideceği bir yer var (TV eşleşmiş ya da bilgisayar ekranı seçili).</summary>
    /// <summary>Görüntü kaynağı hazır ve altyazının gideceği bir yer var.</summary>
    public bool CanStart => (IsXbox ? xboxToken is not null && xboxConsole is not null
                            : settings.FrameSource == FrameSource.RemotePlayWindow
                              || settings.FrameSource == FrameSource.CaptureWindow && settings.CaptureWindow is
                                 { ProcessName.Length: > 0, Title.Length: > 0 }
                              || settings.FrameSource == FrameSource.Ps5 && console is not null && accountId is not null)
                            && (ShowsOnComputer || HasTv);
    public string LastSource { get => lastSource; private set => Set(ref lastSource, value); }
    public string LastTranslation { get => lastTranslation; private set => Set(ref lastTranslation, value, [nameof(ShowsMainAccountTip)]); }
    /// <summary>PS5'ten (ikinci hesap) çeviri sürüyor, ilk altyazı gelmedi ya da bağlantı koptu: "kolu açınca ana hesabı seçin"
    /// ipucu görünür (GitHub #231, <see cref="MainAccountTipVisible"/>).</summary>
    public bool ShowsMainAccountTip => isRunning && MainAccountTipVisible(!IsXbox && settings.FrameSource == FrameSource.Ps5,
        lastTranslation.Length > 0, sessionState.Phase == SessionPhase.Streaming);

    /// <summary>
    /// "Kolu açınca ana hesabı seçin" ipucunun kuralı (Mac/iPhone MainAccountTip, Android MainAccountTip.kt ile aynı).
    /// CouchSubs PS5'e ikinci hesapla bağlanır. Fiziksel kol da o hesaba atanmışsa PS5 her bağlanışta kolu Uzaktan Oynatma'ya
    /// devredip kapatır; oyuncu kolu açıp yine ikinci hesabı seçince Uzaktan Oynatma kesilir, yeniden bağlanınca kol yine kapanır
    /// (Play yorumu 20 Kas, #231, #5). İpucu eskiden yalnız ilk altyazıdan önce görünüyordu; artık bağlantı koptuğunda da görünür.
    /// </summary>
    public static bool MainAccountTipVisible(bool ps5, bool hasSubtitle, bool streaming) => ps5 && (!hasSubtitle || !streaming);
    /// <summary>
    /// Görüntü bir dakikadır geliyor ama bu çeviride tek altyazı satırı okunmadı: "oyunun kendi altyazısını açın" ipucu
    /// (<see cref="SubtitleOffTip"/>; GitHub #503, #554, #566, #572).
    /// </summary>
    public bool ShowsSubtitleOffTip { get => showsSubtitleOffTip; private set => Set(ref showsSubtitleOffTip, value, [nameof(ShowsSubtitleBackgroundTip)]); }
    /// <summary>İpucu görünürken GTA 6 altyazı zemini izleme açıksa ayrıca söylenir: zemin yoksa bütün satırlar atlanır.</summary>
    public bool ShowsSubtitleBackgroundTip => showsSubtitleOffTip && settings.WatchSubtitleBackground;
    private bool showsSubtitleOffTip;
    /// <summary>Görüntünün bu bağlantıda ilk geldiği an (bağlantı koparsa sıfırlanır).</summary>
    private DateTime? framesSince;
    /// <summary>Bu çeviride en az bir altyazı satırı gösterildi.</summary>
    private bool sawLineThisRun;

    /// <summary>Kare geldi ya da satır gösterildi: ipucu yeniden değerlendirilir (arayüz iş parçacığında).</summary>
    private void UpdateSubtitleOffTip(bool frameArrived = false)
    {
        if (frameArrived && isRunning && sessionState.Phase == SessionPhase.Streaming) framesSince ??= Clock();
        ShowsSubtitleOffTip = isRunning && !subtitlesPaused && SubtitleOffTip.IsVisible(sessionState.Phase == SessionPhase.Streaming,
            sawLineThisRun, framesSince is { } since ? Clock() - since : null);
    }
    /// <summary>TV'ye giden son satırın ölçümleri tek satırda ("OCR 40 ms · Çeviri 300 ms · Gecikme 520 ms"); satır gelene kadar boş.</summary>
    public string MetricsText { get => metricsText; private set => Set(ref metricsText, value); }
    /// <summary>Çevrilen satırlar, en yenisi başta (bu ve önceki oturumlar). Değişince bu özellik bildirilir.</summary>
    public IReadOnlyList<SubtitleHistory.Entry> History => [.. history.Entries];
    public TranslatorStatus TranslatorStatus { get => translatorStatus; private set => Set(ref translatorStatus, value); }
    private bool gpuFallbackWarning;
    /// <summary>CUDA kullanılamadığı için ücretsiz çeviri CPU'da çalışıyor.</summary>
    public bool GpuFallbackWarning { get => gpuFallbackWarning; private set => Set(ref gpuFallbackWarning, value); }
    /// <summary>Çevrimiçi çeviri (DeepL ya da yapay zekâ) şu an çeviremiyor; o satırlar cihaz üstü modelle çevriliyor.</summary>
    public OnlineKeyState? OnlineIssue { get => onlineIssue; private set => Set(ref onlineIssue, value); }
    /// <summary>Bilgisayarda yazı tanıma dili yok; ayarlardan eklenmesi gerekir.</summary>
    public bool OcrMissing { get => ocrMissing; private set => Set(ref ocrMissing, value); }
    /// <summary>Canlı altyazı çevirisi duraklatıldı (Num 0); ek bölge ve serbest alan çevirileri çalışmaya devam eder.</summary>
    public bool SubtitlesPaused { get => subtitlesPaused; private set => Set(ref subtitlesPaused, value); }
    public Frame? LastFrame { get => lastFrame; private set => Set(ref lastFrame, value); }
    public string? ActiveSourceLanguage { get; private set; }
    /// <summary>Sunucunun gerçekten dinlediği port (8787 doluysa rastgele bir port).</summary>
    public int ServerPort { get; private set; } = DefaultServerPort;

    /// <summary>Bu oyun dilinden hedef dile çeviri modeli var mı (ayarlarda listelenecek diller).</summary>
    public bool SupportsLanguage(string source) => services.Translation.IsSupported(source, settings.TargetLanguage);

    public bool ModelInstalled => services.Translation.IsInstalled(settings.SourceLanguage, settings.TargetLanguage);
    public bool ModelDownloading { get => modelDownloading; private set => Set(ref modelDownloading, value); }
    public double ModelProgress { get => modelProgress; private set => Set(ref modelProgress, value); }
    public string? ModelError { get => modelError; private set => Set(ref modelError, value); }

    public UserSettings Settings
    {
        get => settings;
        set
        {
            value = value with { CpuTranslationThreads = CpuThreadOptions.Normalize(value.CpuTranslationThreads, Environment.ProcessorCount) };
            var old = settings;
            if (!Set(ref settings, value, [nameof(UsesFreeGemini)])) return;
            settingsStore.Save(value);
            server.SendStyle(value.Style);
            if (old.Output != value.Output) OutputChanged();
            if (old.Dubbing != value.Dubbing) DubbingSettingsChanged(old.Dubbing);
            if (old.GamePacks != value.GamePacks && pipeline is not null) ConnectPacks(pipeline);
            if (pipeline is not null) pipeline.ShowSpeakerNames = value.ShowSpeakerNames;
            server.SpeakerColors = value.SpeakerColors;
            if ((old.MisreadWaitMs != value.MisreadWaitMs || old.PartialWaitMs != value.PartialWaitMs) && pipeline is not null) ApplyWaits(pipeline);
            if (old.SharePool != value.SharePool) services.Pool?.SetEnabled(value.SharePool);
            if (old.TranslationDevice != value.TranslationDevice)
            {
                GpuFallbackWarning = false;
                services.Translation.SelectDevice(value.TranslationDevice);
            }
            if (old.CpuTranslationThreads != value.CpuTranslationThreads)
                services.Translation.SelectCpuThreads(value.CpuTranslationThreads);
            UpdateRegionWatcher();
            if (old.ActiveAreaProfile != value.ActiveAreaProfile || old.AreaProfiles != value.AreaProfiles || old.Areas != value.Areas
                || old.FrameSource != value.FrameSource)
                Changed(nameof(AreaProfileGame), nameof(AreaProfileUnsaved), nameof(AreaProfileTarget));
            if (old.FrameSource != value.FrameSource || old.CaptureWindow != value.CaptureWindow)
                Changed(nameof(CanStart), nameof(Ps5StatusText), nameof(ConsoleTitle));
            var windowAppChanged = value.FrameSource == FrameSource.RemotePlayWindow && old.RemotePlayApp != value.RemotePlayApp;
            var captureWindowChanged = value.FrameSource == FrameSource.CaptureWindow && old.CaptureWindow != value.CaptureWindow;
            var xboxFrameRateChanged = IsXbox && old.XboxLegacyFrameRate != value.XboxLegacyFrameRate;
            var xboxAudioChanged = IsXbox && old.XboxAudioOnComputer != value.XboxAudioOnComputer;
            if (isRunning && (old.FrameSource != value.FrameSource || windowAppChanged || captureWindowChanged || xboxFrameRateChanged || xboxAudioChanged))
            {
                // Görüntü kaynağı, Xbox kare aralığı ya da Xbox ses çıkışı değişti: akış yeni seçimle yeniden başlar.
                // TV uygulaması kapatılmaz; kapanıp yeniden açılsa TV girişi gidip gelirdi.
                StopForRestart();
                _ = StartAsync().ContinueWith(task => RemotePlayLog.Note($"Çeviri yeniden başlatılamadı: {task.Exception?.GetBaseException().Message}"),
                                              TaskContinuationOptions.OnlyOnFaulted);
            }
            var translationChanged = old.OnlineTranslation != value.OnlineTranslation || old.OnlineEngine != value.OnlineEngine
                                     || old.GeminiModel != value.GeminiModel || old.GeminiPaidTier != value.GeminiPaidTier
                                     || old.OpenAiModel != value.OpenAiModel
                                     || old.ClaudeModel != value.ClaudeModel
                                     || old.LocalAiBaseUrl != value.LocalAiBaseUrl || old.LocalAiModel != value.LocalAiModel
                                     || old.AiInstruction != value.AiInstruction
                                     || old.TranslationDevice != value.TranslationDevice
                                     || old.CpuTranslationThreads != value.CpuTranslationThreads;
            if (translationChanged && !isRunning) RefreshTranslatorStatus();
            if (isRunning && (old.SourceLanguage != value.SourceLanguage || old.TargetLanguage != value.TargetLanguage
                              || translationChanged || old.FastSubtitleDetection != value.FastSubtitleDetection
                              || old.WatchSubtitleBackground != value.WatchSubtitleBackground
                              || old.OcrEngine != value.OcrEngine))
            {
                RefreshTranslatorStatus();
                MakePipeline();
            }
        }
    }

    // --- Sihirbaz ---

    public bool CanAdvance => step switch
    {
        OnboardingStep.Welcome or OnboardingStep.SecondAccount or OnboardingStep.Test or OnboardingStep.BetterTranslation => true,
        OnboardingStep.PsnLogin => IsXbox ? xboxToken is not null : accountId is not null,
        OnboardingStep.Console => IsXbox ? xboxConsole is not null : console is not null,
        OnboardingStep.Tv => HasTv || settings.Output == SubtitleOutput.Computer,
        OnboardingStep.Translation => ModelInstalled,
        _ => false,
    };

    public void Advance()
    {
        if (!CanAdvance || step == OnboardingStep.Done) return;
        // Model büyük; kullanıcı diğer adımlarla uğraşırken arka planda iner.
        if (step == OnboardingStep.Welcome)
        {
            StartModelDownload();
            consoleKindLocked = true;
            store.Save(StoreKeys.ConsoleKindLocked, true);
            Changed(nameof(ConsoleKindLocked));
        }
        Step = step == OnboardingStep.Welcome && IsXbox ? OnboardingStep.PsnLogin : step + 1;
    }

    public void Back()
    {
        if (step > OnboardingStep.Welcome) Step = step == OnboardingStep.PsnLogin && IsXbox ? OnboardingStep.Welcome : step - 1;
    }

    /// <summary>Ücretsiz Gemini anahtarı kayıtlı ve çeviri Gemini ile yapılıyor ("Daha iyi çeviri" adımı tamam).</summary>
    public bool UsesFreeGemini => settings.Engine == TranslationEngine.Gemini && HasKey(TranslationEngine.Gemini);

    /// <summary>Ayarlardaki "Ücretsiz anahtar al": Gemini seçilir, anahtar alanı görünür (anahtar gelene dek ücretsiz çeviri sürer).</summary>
    public void ChooseFreeGemini() => Settings = settings.WithEngine(TranslationEngine.Gemini);

    /// <summary>Giriş penceresinin yönlendirmesinden hesap kimliği. Her başarısızlık kendi iletisiyle
    /// <see cref="AppException"/> olur ve günlüğe yazılır; genel "Giriş tamamlanmadı" yalnız son çaredir.</summary>
    public async Task CompletePsnLoginAsync(Uri redirect)
    {
        byte[] id;
        try
        {
            id = await services.AccountIdFromRedirectAsync(redirect);
        }
        catch (PsnAccountException error)
        {
            RemotePlayLog.Note($"PSN girişi başarısız: {error.Failure} HTTP {error.StatusCode?.ToString() ?? "-"} {error.Detail}");
            throw LoginError(error);
        }
        catch (Exception error) when (error is not AppException)
        {
            RemotePlayLog.Note($"PSN girişi beklenmedik hatayla bitti: {error}");
            throw new AppException(AppError.InvalidLogin, WithLogHint($"{AppException.Describe(AppError.InvalidLogin, text)} ({error.Message})"));
        }
        RemotePlayLog.Note("PSN girişi tamam");
        accountId = id;
        store.Save(StoreKeys.AccountId, id);
        Changed(nameof(HasAccount), nameof(CanAdvance));
    }

    /// <summary>Sony'nin giriş sayfası sistem tarayıcısında açılır. Uygulama içi pencerede Sony "Can't connect to the
    /// server" derse giriş bu yoldan yapılır; kullanıcı yönlendirme adresini kopyalayıp <see cref="CompletePsnLoginAsync"/>'e verir.</summary>
    public void OpenPsnLoginInBrowser()
    {
        RemotePlayLog.Note("PSN girişi tarayıcıda açılıyor");
        OpenInBrowser(PsnAccount.AuthorizeUrl);
    }

    public Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync() => services.DiscoverConsolesAsync();

    /// <summary>PS5'e kayıt olur. Her başarısızlık <see cref="AppException"/> ile anlatılır; sessiz dönüş yok.</summary>
    public async Task RegisterAsync(string host, string pin)
    {
        host = host.Trim();
        if (host.Length == 0) throw Error(AppError.MissingConsole);
        if (Registration.ParsePin(pin) is not { } value) throw Error(AppError.InvalidPin);
        if (accountId is null) throw Error(AppError.MissingAccount);
        RegisteredConsole registered;
        try
        {
            registered = await services.RegisterAsync(host, accountId, value);
        }
        catch (RegistrationException error)
        {
            // PS5 kendi kodunu bildirdiyse yanıt bize ulaşmıştır, güvenlik duvarı sebep değildir.
            if (error.Reason is null && error.Failure is not (RegistrationFailure.WrongAccount or RegistrationFailure.BadAddress))
                await OfferFirewallAsync();
            throw RegistrationError(error);
        }
        catch (Exception error) when (error is not AppException)
        {
            // Beklenmedik hata da (ör. yerel kütüphane yüklenemedi) iletiye dönüşür ve günlüğe yazılır.
            RemotePlayLog.Note($"PS5 kaydı beklenmedik hatayla bitti ({host}): {error}");
            await OfferFirewallAsync();
            throw new AppException(AppError.RegistrationFailed, WithLogHint($"{AppException.Describe(AppError.RegistrationFailed, text)} ({error.Message})"));
        }
        ClearFirewallPrompt();
        console = registered;
        store.Save(StoreKeys.Console, registered);
        // Günlükte eşleşmenin kaydedildiği de görünsün (kullanıcılar başarıyı fark etmeyip yeniden bağlanıyordu).
        RemotePlayLog.Note($"PS5 kaydı kaydedildi ({registered.Host}): {registered.Name}");
        Changed(nameof(Console), nameof(CanAdvance), nameof(Ps5StatusText), nameof(PairedText));
    }

    /// <summary>PS5 adımında, eşleşme bitince Bağlan düğmesinin altında gösterilen başarı iletisi; eşleşme yoksa boş.</summary>
    public string PairedText => console is null
        ? ""
        : text.Format("PS5 paired: %@ (%@). Press Continue.", string.IsNullOrEmpty(console.Name) ? "PS5" : console.Name, console.Host);

    /// <summary>
    /// Eşleşmeden kısa süre sonra kendiliğinden sonraki adıma geçilir. Kullanıcı bu arada Geri'ye bastıysa ya da
    /// adım değiştiyse hiçbir şey yapılmaz (yalnız PS5 adımından ilerler).
    /// </summary>
    public void ContinueAfterPairing()
    {
        if (step == OnboardingStep.Console && console is not null) Advance();
    }

    /// <summary>
    /// "Hesap kimliğini elle gir": Sony girişi açılamayan kullanıcılar (ör. servis sağlayıcı engelliyor) PSN hesap
    /// kimliğini base64 olarak (8 bayt, 12 karakter) yazar. Web girişiyle aynı biçimde saklanır. Geçersizse false.
    /// </summary>
    public bool UseManualAccountId(string value)
    {
        if (ParseAccountId(value) is not { } id) return false;
        RemotePlayLog.Note("PSN hesap kimliği elle girildi");
        accountId = id;
        store.Save(StoreKeys.AccountId, id);
        Changed(nameof(HasAccount), nameof(CanAdvance));
        return true;
    }

    /// <summary>Base64 PSN hesap kimliği: boşluklar atılır, çözülen değer tam 8 bayt olmalı (12 karakter).</summary>
    public static byte[]? ParseAccountId(string? value)
    {
        var trimmed = string.Concat((value ?? "").Where(c => !char.IsWhiteSpace(c)));
        if (trimmed.Length != 12) return null;
        try
        {
            var bytes = Convert.FromBase64String(trimmed);
            return bytes.Length == 8 ? bytes : null;
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>Kullanıcıya gösterilen hata; destek bildirimleri teşhis edilebilsin diye PS5'in kodu da yazılır.</summary>
    private AppException RegistrationError(RegistrationException error)
    {
        var kind = error.Failure switch
        {
            RegistrationFailure.WrongAccount => AppError.WrongAccount,
            RegistrationFailure.NoAnswer => AppError.ConsoleNoAnswer,
            RegistrationFailure.InUse => AppError.ConsoleInUse,
            RegistrationFailure.ConsoleCrashed => AppError.ConsoleCrashed,
            RegistrationFailure.VersionMismatch => AppError.ConsoleVersion,
            RegistrationFailure.WrongCode => AppError.WrongCode,
            // İptal yalnız cs_register'ın süresi dolunca olur: PS5 yanıt vermemiştir.
            RegistrationFailure.NoReply or RegistrationFailure.Canceled => AppError.ConsoleNoReply,
            RegistrationFailure.BadAddress => AppError.BadAddress,
            RegistrationFailure.PairingClosed => AppError.ConsolePairingClosed,
            RegistrationFailure.ConnectFailed => AppError.ConsoleConnectFailed,
            RegistrationFailure.NoFreePort => AppError.NoFreePort,
            _ => AppError.RegistrationFailed,
        };
        var message = AppException.Describe(kind, text);
        return new AppException(kind, WithLogHint(string.IsNullOrEmpty(error.Detail) ? message : $"{message} ({error.Detail})"));
    }

    /// <summary>PSN girişinin hatası: Sony'nin bildirdiği hata ya da HTTP kodu iletiye eklenir.</summary>
    private AppException LoginError(PsnAccountException error)
    {
        var kind = error.Failure switch
        {
            PsnLoginFailure.Refused => AppError.LoginRefused,
            PsnLoginFailure.RateLimited => AppError.LoginRateLimited,
            PsnLoginFailure.Http => AppError.LoginServer,
            PsnLoginFailure.Network => AppError.LoginNetwork,
            PsnLoginFailure.BadResponse => AppError.LoginBadResponse,
            _ => AppError.InvalidLogin,
        };
        var message = AppException.Describe(kind, text);
        var detail = string.Join(", ", new[] { error.StatusCode is { } status ? $"HTTP {status}" : null, error.Detail }.Where(part => !string.IsNullOrEmpty(part)));
        return new AppException(kind, WithLogHint(detail.Length == 0 ? message : $"{message} ({detail})"));
    }

    /// <summary>Giriş penceresi yönlendirme olmadan kapandı (kullanıcı kapattı ya da sayfa açılamadı).</summary>
    /// <param name="problem">Pencerenin gördüğü sorun (ör. "HTTP 429", WebView2 hatası); yoksa null.</param>
    public AppException LoginWindowError(string? problem)
    {
        RemotePlayLog.Note($"PSN giriş penceresi giriş bitmeden kapandı{(problem is null ? "" : $": {problem}")}");
        if (problem is null) return Error(AppError.LoginWindowClosed);
        var kind = problem.Contains("429", StringComparison.Ordinal) ? AppError.LoginRateLimited : AppError.LoginPageFailed;
        return new AppException(kind, WithLogHint($"{AppException.Describe(kind, text)} ({problem})"));
    }

    /// <summary>Eşleştirme olmazsa kullanıcı remoteplay.log'u gönderebilsin diye yolu iletinin sonuna eklenir.</summary>
    private string WithLogHint(string message) =>
        $"{message} {text.Format("If this keeps happening, send us this file: %@", RemotePlayLog.DisplayPath)}";

    public Task<IReadOnlyList<LgTv>> DiscoverTvsAsync() => services.DiscoverTvsAsync();

    /// <summary>
    /// Sihirbazdaki "TV'm yok": TV aranmaz ve kurulmaz, altyazı bilgisayar ekranında gösterilir; sonraki adıma geçilir.
    /// </summary>
    public void UseComputerScreen()
    {
        Settings = settings with { Output = SubtitleOutput.Computer };
        Advance();
    }

    /// <summary>
    /// Sihirbazdaki "İkinci hesap yok mu?": görüntü bu bilgisayardaki Remote Play penceresinden okunur. PSN girişi, PS5
    /// eşleştirmesi ve TV adımı atlanır, kurulum biter; TV eşleşmemişse altyazı bilgisayar ekranında gösterilir (TV ve
    /// daha iyi çeviri sonra Ayarlar'dan).
    /// </summary>
    public void UseRemotePlayWindow()
    {
        Settings = settings with { FrameSource = FrameSource.RemotePlayWindow, Output = HasTv ? settings.Output : SubtitleOutput.Computer };
        Step = OnboardingStep.Done;
    }

    /// <summary>OBS veya oyun penceresi kullanıcı tarafından sonradan seçilir; PSN eşleştirmesine gerek yoktur.</summary>
    public void UseCaptureWindow()
    {
        Settings = settings with { FrameSource = FrameSource.CaptureWindow, Output = HasTv ? settings.Output : SubtitleOutput.Computer };
        Step = OnboardingStep.Done;
    }

    public IReadOnlyList<WindowCaptureTarget> AvailableCaptureWindows() => services.CaptureWindows();

    /// <summary>Görüntü PS5'ten (ikinci hesap) alınacak ama hesap ya da PS5 eşleşmesi yok: Ayarlar'da "Hesabı bağla" görünür.</summary>
    public bool NeedsPs5Link => settings.FrameSource == FrameSource.Ps5 && (accountId is null || console is null);

    /// <summary>Ayarlar › Görüntü kaynağı › "Hesabı bağla": sihirbaz ikinci hesap adımından açılır (PSN girişi, PS5 eşleştirmesi).</summary>
    public void LinkPs5Account() => Step = OnboardingStep.SecondAccount;

    /// <summary>Seçilen Remote Play uygulaması bu bilgisayarda kurulu mu (Ayarlar'daki "Kurulu" / "İndir" satırları).</summary>
    public bool RemotePlayInstalled(RemotePlayApp app) => services.RemotePlayInstalled(app);

    /// <summary>Görüntü Remote Play penceresinden okunacak ama seçilen uygulama kurulu değil: ana ekran nereden indirileceğini söyler.</summary>
    public bool RemotePlayMissing => settings.FrameSource == FrameSource.RemotePlayWindow && !services.RemotePlayInstalled(settings.RemotePlayApp);

    /// <summary>Resmi indirme sayfaları: Sony PS Remote Play ve chiaki-ng'nin son sürümü.</summary>
    public const string SonyRemotePlayDownload = "https://remoteplay.dl.playstation.net/remoteplay/";
    public const string ChiakiDownload = "https://github.com/chiaki-ng/chiaki-ng/releases/latest";

    public async Task PairAsync(LgTv target)
    {
        await StartServerAsync();
        var savedKey = store.Load<string>(StoreKeys.TvKey);
        var pairing = await services.PairTvAsync(target, savedKey, ServerAddress(target), server.AccessKey);
        if (tv?.Brand != target.Brand || (target.Brand != TvBrand.AndroidTv && tv?.Host != target.Host))
            store.Remove(StoreKeys.TvAppVersion);
        tv = target;
        store.Save(StoreKeys.Tv, target);
        // Samsung jetonla gelen bağlantıda jetonu yeniden göndermeyebilir; boş jeton saklı olanı silmez (#40).
        store.Save(StoreKeys.TvKey, SamsungTokenHolder.KeptToken(savedKey, pairing.Key));
        tvAppMissing = !pairing.Launched;
        // Daha önce "TV'm yok" seçildiyse TV bağlanınca altyazı TV'ye gider.
        if (settings.Output == SubtitleOutput.Computer) Settings = settings with { Output = SubtitleOutput.Tv };
        Changed(nameof(Tv), nameof(CanAdvance), nameof(CanInstallTvApp), nameof(CanReinstallTvApp), nameof(HasTv), nameof(NeedsTv), nameof(CanStart),
            nameof(TvStatusText), nameof(TvTone));
        if (target.Brand == TvBrand.Lg) await RefreshTvAppAsync();
        // Samsung girişi ya da Android onayı dakikalar sürebilir; eşleşme beklemesin.
        else _ = RefreshTvAppAsync();
    }

    // --- TV uygulamasını kurma ---

    public TvAppState TvApp
    {
        get => tvApp;
        private set
        {
            tvApp = value;
            Changed(nameof(TvApp));
        }
    }

    /// <summary>LG geliştirici modunun kalan süresi (saat); CouchSubs uzattıktan sonra bilinir.</summary>
    public int? DevModeHoursLeft
    {
        get => devModeHoursLeft;
        private set
        {
            devModeHoursLeft = value;
            Changed(nameof(DevModeHoursLeft));
        }
    }

    /// <summary>Seçili TV'ye uygulamayı CouchSubs kurabilir mi (paket uygulamayla geldi mi)?</summary>
    public bool CanInstallTvApp => tv is { } target &&
        (target.Brand == TvBrand.Lg ? services.BundledTvAppVersion is not null : services.BundledApp(target.Brand) is not null);

    /// <summary>Samsung'un sertifika sayfasını tarayıcıda açar (arayüz atar; testlerde boş kalır).</summary>
    public Action<Uri> OpenInBrowser { get; set; } = _ => { };

    /// <summary>Samsung'da geliştirici modunda "Host PC IP" olarak yazılacak bu bilgisayarın adresi.</summary>
    public string? ComputerAddress => LocalAddress(tv is { Host.Length: > 0 } target ? target.Host : null);

    /// <summary>
    /// Geliştirici modu açık TV'de uygulamayı eksikse kurar, eskiyse günceller.
    /// Anahtar yoksa ve uygulama çalışıyorsa kullanıcıdan bir şey istenmez.
    /// </summary>
    public async Task RefreshTvAppAsync()
    {
        if (tv is not { } target || refreshingTvApp) return;
        refreshingTvApp = true;
        try
        {
            switch (target.Brand)
            {
                case TvBrand.Lg: await RefreshLgAppAsync(target); break;
                case TvBrand.Samsung: await RefreshSamsungAppAsync(target); break;
                case TvBrand.AndroidTv: await RefreshAndroidAppAsync(target); break;
            }
        }
        finally
        {
            refreshingTvApp = false;
        }
    }

    private string? InstalledAppVersion => store.Load<string>(StoreKeys.TvAppVersion);

    private bool NeedsInstall(BundledTvApp bundled) =>
        InstalledAppVersion is not { } installed || DevModeInstaller.IsNewer(bundled.Version, installed);

    private async Task RefreshLgAppAsync(LgTv target)
    {
        if (services.BundledTvAppVersion is not { } bundled) return;
        var devModeOn = await services.IsDevModeOnAsync(target.Host);
        // Beklerken parola alanından kurulum başladıysa kart geri "geliştirici modu kapalı"ya dönmez.
        if (TvApp.Kind == TvAppKind.Working) return;
        if (!devModeOn)
        {
            TvApp = tvAppMissing ? new TvAppState(TvAppKind.DevModeOff) : TvAppState.Unknown;
            return;
        }
        if (store.Load<string>(StoreKeys.TvDevKey) is not { } devKey)
        {
            TvApp = tvAppMissing ? new TvAppState(TvAppKind.NeedsPassphrase) : TvAppState.Unknown;
            return;
        }
        await InstallTvAppAsync(target, devKey, bundled);
    }

    /// <summary>
    /// Kurulum hatasında TV'nin verdiği sebep de gösterilir; genel mesaj tek başına sorunu bulmaya yetmiyordu. Samsung'da
    /// her hatanın ayrıntısı (Samsung'un yanıtı, sdb hatası, TV'nin kurulum çıktısı) gösterilir: hiçbiri sessiz kalmasın.
    /// </summary>
    private static TvAppState FailedState(DevModeException error, bool alwaysShowDetail = false) =>
        new(TvAppKind.Failed, Error: error.Error,
            Reason: (alwaysShowDetail || error.Error is DevModeError.InstallFailed or DevModeError.NotEnoughSpace) &&
                    !string.IsNullOrWhiteSpace(error.Detail)
                ? error.Detail.Trim() : null);

    /// <summary>Samsung kurulumu ya da sürüm denetimi sürüyor: olaylar (giriş, kurulum adımı) kartı değiştirebilir.</summary>
    private bool samsungCheckRunning;

    /// <summary>
    /// Samsung: geliştirici modu açıksa TV'deki CouchSubs sürümüne bakar, yoksa ya da eskiyse imzalayıp kurar
    /// (sertifika yoksa Samsung girişi istenir). Önceden yalnız bu bilgisayarın kurduğu sürüm hatırlanıyordu; TV'de eski
    /// kalan uygulama (ör. 0.9.10 gelirken 0.9.7) hiç güncellenmiyordu.
    /// </summary>
    private async Task RefreshSamsungAppAsync(LgTv target)
    {
        if (services.BundledApp(TvBrand.Samsung) is not { } bundled) return;
        // "TV uygulamasını yeniden kur": güncel uygulama da TV'de açılır (Android'deki gibi). İstek bir kerelik.
        var open = openTvAppAfterCheck;
        openTvAppAfterCheck = false;
        var remembered = !NeedsInstall(bundled);
        // TV 8001'de geliştirici modunu ve Host PC IP'yi söyler (Android ve iPhone uygulaması da buna bakar). Host PC IP
        // bu bilgisayarınki değilse TV 26101'de sdb el sıkışmasında bağlantıyı keser ve önceden yalnız genel "TV bu
        // bilgisayarı kabul etmedi" görünüyordu (#343); bu durumda sdb hiç denenmez, iki adres de söylenir.
        var check = await services.CheckSamsungAsync(target.Host);
        var devModeOn = check.Info?.DeveloperMode != false && await services.IsSamsungDevModeOnAsync(target.Host);
        if (!devModeOn)
        {
            // Geliştirici modu kapalıyken TV'ye sorulamaz; bu bilgisayarın kurduğu sürüme bakılır.
            TvApp = remembered ? new TvAppState(TvAppKind.UpToDate, InstalledAppVersion ?? bundled.Version) : new TvAppState(TvAppKind.DevModeOff);
            return;
        }
        if (SamsungMessages.HostPcIpMismatch(check.Info?.DeveloperIp, check.ComputerAddress))
        {
            // Çalışan uygulama "kurulamadı" diye gösterilmez (Unreachable'daki gibi); güncelleme Host PC IP düzelince gelir.
            TvApp = remembered
                ? new TvAppState(TvAppKind.UpToDate, InstalledAppVersion ?? bundled.Version)
                : new TvAppState(TvAppKind.Failed, Error: DevModeError.HostPcMismatch, HostPcIp: check.Info!.DeveloperIp,
                    ComputerAddress: check.ComputerAddress);
            return;
        }
        // Güncel bilinen uygulamada denetim sessiz sürer; kart ancak kurulum başlarsa değişir.
        TvApp = remembered ? new TvAppState(TvAppKind.UpToDate, InstalledAppVersion ?? bundled.Version) : new TvAppState(TvAppKind.Working);
        samsungCheckRunning = true;
        try
        {
            var (version, installed) = await services.InstallSamsungAppAsync(target.Host, bundled, open, e => post(() => InstallEvent(e)));
            version = string.IsNullOrWhiteSpace(version) ? bundled.Version : version;
            store.Save(StoreKeys.TvAppVersion, version);
            TvApp = new TvAppState(TvAppKind.UpToDate, version);
            if (installed) await OpenTvAppAfterInstallAsync(target);
        }
        catch (DevModeException error) when (remembered && error.Error == DevModeError.Unreachable)
        {
            // TV sdb bağlantısını kabul etmedi (ör. Host PC IP değişti): çalışan uygulama "kurulamadı" diye gösterilmez.
            TvApp = new TvAppState(TvAppKind.UpToDate, InstalledAppVersion ?? bundled.Version);
        }
        catch (DevModeException error)
        {
            TvApp = FailedState(error, alwaysShowDetail: true);
        }
        finally
        {
            samsungCheckRunning = false;
        }
    }

    /// <summary>Kurulumun TV'yi değiştiren adımları (yalnız sürüm okumak değil).</summary>
    private static bool IsInstallStep(string? step) =>
        step is "signin" or "certificate" or "signing" or "installing" or "uninstalling";

    /// <summary>Android TV: ağda ADB'si açık TV'yi bulur, uygulamayı kurar ve açar.</summary>
    private async Task RefreshAndroidAppAsync(LgTv target)
    {
        if (services.BundledApp(TvBrand.AndroidTv) is not { } bundled) return;
        var host = target.Host;
        if (host.Length == 0 || !await services.IsAndroidDebugOnAsync(host))
        {
            // Bu bilgisayarın kurduğu sürüm kayıtlıysa ve TV'de hata ayıklama kapalıysa yapılacak bir şey yok. Ama kayda
            // ancak TV'nin adresi biliniyorsa ya da TV uygulaması şu an bağlıysa güvenilir: TV sihirbazda yeniden seçilince
            // adres boşalıyor, kayıt kalıyordu; TV'den kaldırılan uygulama "hazır" görünüyor, ağda TV hiç aranmıyor ve
            // kurulum denenmiyordu (#352, #389).
            if (!NeedsInstall(bundled) && (target.Host.Length > 0 || tvClients > 0))
            {
                TvApp = new TvAppState(TvAppKind.UpToDate, InstalledAppVersion ?? bundled.Version);
                return;
            }
            // Birden çok TV varsa ilk bulunana gidilmez: kayıtlı ya da seçilen TV, yoksa kullanıcıya sorulur. Eskiden izin
            // sorusu başka odadaki TV'de çıkıyor, kurulum "onaylanmadı" diye bitiyordu (#425).
            var choice = androidTvChoice;
            androidTvChoice = null;
            var found = await services.ScanAndroidTvsAsync();
            var hosts = AndroidTvPick.Hosts(found);
            if (AndroidTvPick.Pick(found, [choice, target.Host]) is not { } picked)
            {
                TvApp = hosts.Count == 0 ? new TvAppState(TvAppKind.DevModeOff) : new TvAppState(TvAppKind.ChooseAndroidTv, Hosts: hosts);
                return;
            }
            host = picked;
        }
        TvApp = new TvAppState(TvAppKind.Working);
        var open = openTvAppAfterCheck;
        openTvAppAfterCheck = false;
        try
        {
            // Açılan uygulamaya altyazı sunucusunun adresi verilir: sunucu 8787 dışında bir portta olsa da (8787 doluysa ya da
            // Linux'ta COUCHSUBS_SERVER_PORT) TV uygulaması onu bulur (#617). Eşleştirme yine TV'deki kodla yapılır.
            try { await StartServerAsync(); } catch (SocketException) { }
            var launch = System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string> { ["server"] = ServerAddress(target with { Host = host }) });
            var version = await services.InstallAndroidAppAsync(host, bundled, open, launch, e => post(() => InstallEvent(e)));
            // TV'nin adresi bundan sonra sürüm denetimi için kullanılır.
            var located = target with { Host = host };
            tv = located;
            store.Save(StoreKeys.Tv, located);
            store.Save(StoreKeys.TvAppVersion, version);
            Changed(nameof(Tv));
            TvApp = new TvAppState(TvAppKind.UpToDate, version);
        }
        catch (DevModeException error)
        {
            TvApp = FailedState(error);
        }
    }

    private void InstallEvent(TvInstallEvent e)
    {
        // Kurulum bittikten sonra gelen geç olay sonucu ezmesin.
        if (!samsungCheckRunning && TvApp.Kind is not (TvAppKind.Working or TvAppKind.SignIn or TvAppKind.ApproveOnTv or TvAppKind.PressInstallOnTv)) return;
        switch (e.Kind)
        {
            // Android TV'de Google Play sayfası açıldı: kullanıcı TV'de Yükle'ye basmalı. Önceden kart yalnız "kuruluyor"
            // diyordu; TV'deki sayfayı görmeyen kullanıcı dört dakika boyunca bir şey olmuyor sanıyordu.
            case TvInstallEventKind.Progress when e.Step == "play":
                TvApp = new TvAppState(TvAppKind.PressInstallOnTv);
                break;
            case TvInstallEventKind.SignIn when e.Url is { } url:
                TvApp = new TvAppState(TvAppKind.SignIn, Url: url);
                OpenInBrowser(url);
                break;
            case TvInstallEventKind.ApproveOnTv:
                TvApp = new TvAppState(TvAppKind.ApproveOnTv);
                break;
            case TvInstallEventKind.Progress when TvApp.Kind == TvAppKind.SignIn:
                TvApp = new TvAppState(TvAppKind.Working);
                break;
            // Sürüm denetimi güncelleme kurmaya başladı: kart "kuruluyor"a geçer.
            case TvInstallEventKind.Progress when TvApp.Kind != TvAppKind.Working && IsInstallStep(e.Step):
                TvApp = new TvAppState(TvAppKind.Working);
                break;
        }
    }

    /// <summary>
    /// Samsung ve Android TV'de TV uygulaması bağlı değilken "TV uygulamasını yeniden kur" görünür (ana ekran ve TV kartı).
    /// TV'den kaldırılan uygulama bu bilgisayarın kaydında "kurulu" kalıyordu (#352, #389).
    /// </summary>
    public bool CanReinstallTvApp => tv is { Brand: TvBrand.Samsung or TvBrand.AndroidTv } && CanInstallTvApp && tvClients == 0;

    /// <summary>
    /// Kurulan sürüm kaydını unutur ve TV'ye yeniden bakar: uygulama TV'de yoksa kurulur, Android TV'de varsa açılır.
    /// TV'ye ulaşılamazsa kart geliştirici modu / hata ayıklama adımlarını gösterir.
    /// </summary>
    /// <summary>Birden çok Android TV arasından seçilen TV'ye kurulur (#425).</summary>
    public async Task ChooseAndroidTvAsync(string host)
    {
        androidTvChoice = host;
        TvApp = new TvAppState(TvAppKind.Working);
        await RefreshTvAppAsync();
    }

    public async Task ReinstallTvAppAsync()
    {
        if (tv is null) return;
        store.Remove(StoreKeys.TvAppVersion);
        openTvAppAfterCheck = true;
        TvApp = TvAppState.Unknown;
        await RefreshTvAppAsync();
    }

    /// <summary>Key Server'dan anahtarı alır (TV ekranındaki parolayla) ve uygulamayı kurar.</summary>
    public async Task InstallTvAppAsync(string passphrase)
    {
        if (tv is not { } target || services.BundledTvAppVersion is not { } bundled) return;
        TvApp = new TvAppState(TvAppKind.Working);
        try
        {
            var devKey = await services.FetchDevKeyAsync(target.Host, passphrase.Trim());
            store.Save(StoreKeys.TvDevKey, devKey);
            await InstallTvAppAsync(target, devKey, bundled);
        }
        catch (DevModeException error)
        {
            TvApp = new TvAppState(TvAppKind.NeedsPassphrase, Error: error.Error);
        }
    }

    private async Task InstallTvAppAsync(LgTv target, string devKey, string bundled)
    {
        TvApp = new TvAppState(TvAppKind.Working);
        try
        {
            var installed = await services.InstalledTvAppVersionAsync(target.Host, devKey);
            if (installed is not null && !DevModeInstaller.IsNewer(bundled, installed))
            {
                TvApp = new TvAppState(TvAppKind.UpToDate, installed);
                await RenewDevSessionIfDueAsync(target, devKey);
                return;
            }
            await services.InstallTvAppAsync(target.Host, devKey);
            TvApp = new TvAppState(TvAppKind.UpToDate, bundled);
            tvAppMissing = false;
            await RenewDevSessionIfDueAsync(target, devKey);
            await OpenTvAppAfterInstallAsync(target);
        }
        catch (DevModeException error) when (error.Error == DevModeError.KeyRefused)
        {
            // Geliştirici modu yeniden açılınca TV yeni anahtar üretir; eskisi işe yaramaz.
            store.Remove(StoreKeys.TvDevKey);
            TvApp = new TvAppState(TvAppKind.NeedsPassphrase);
        }
        catch (DevModeException error)
        {
            TvApp = FailedState(error);
        }
    }

    /// <summary>
    /// LG geliştirici modunun 1000 saatlik süresini günde en çok bir kez baştan başlatır; kullanıcı TV'den uzatmak
    /// zorunda kalmaz.
    /// </summary>
    private async Task RenewDevSessionIfDueAsync(LgTv target, string devKey)
    {
        // Süre TV başına tutulur: ikinci TV'nin uzatması birincinin kaydıyla atlanmaz.
        var key = StoreKeys.DevSessionRenewedFor(target.Host);
        var last = store.Load<DateTimeOffset?>(key) ?? DateTimeOffset.MinValue;
        if (DateTimeOffset.UtcNow - last < TimeSpan.FromHours(20)) return;
        if (await services.RenewDevSessionAsync(target.Host, devKey) is { } hours)
        {
            DevModeHoursLeft = hours;
            store.Save(key, (DateTimeOffset?)DateTimeOffset.UtcNow);
        }
    }

    private async Task OpenTvAppAfterInstallAsync(LgTv target)
    {
        if (keeper is not null)
        {
            keeper.Reconnect();
            return;
        }
        try { await services.PairTvAsync(target, store.Load<string>(StoreKeys.TvKey), ServerAddress(target), server.AccessKey); }
        catch (Exception) { /* TV uygulaması kuruldu; açılmadıysa kullanıcı açabilir */ }
    }

    /// <summary>TV ağda yeni bir adreste bulundu.</summary>
    public void TvMoved(LgTv moved)
    {
        tv = moved;
        store.Save(StoreKeys.Tv, moved);
        Changed(nameof(Tv));
    }

    public void StartModelDownload()
    {
        if (ModelInstalled || modelDownload is { IsCompleted: false }) return;
        ModelDownloading = true;
        ModelError = null;
        var download = services.Translation.DownloadAsync(settings.SourceLanguage, settings.TargetLanguage, new ImmediateProgress(value => post(() => ModelProgress = value)), CancellationToken.None);
        modelDownload = FinishDownload(download);
    }

    private async Task FinishDownload(Task download)
    {
        try
        {
            await download;
            post(() => ModelProgress = 1);
        }
        catch (Exception error)
        {
            post(() => ModelError = error.Message);
        }
        finally
        {
            post(() =>
            {
                ModelDownloading = false;
                Changed(nameof(ModelInstalled), nameof(CanAdvance));
                RefreshTranslatorStatus();
                // Çeviri sürerken model indiyse hat yeni çevirmenle kurulur.
                if (isRunning && TranslatorStatus == TranslatorStatus.Ready) MakePipeline();
            });
        }
    }

    public Task WaitForModelAsync() => modelDownload ?? Task.CompletedTask;

    public void SendTestSubtitle()
    {
        server.SendStyle(settings.Style);
        // Oyunda henüz altyazı görülmediyse altyazı bölgesinin altına yakın tipik bir yer kullanılır.
        var region = settings.Region;
        var box = lastSubtitleBox ?? new TextBox(0.3, region.Bottom - 0.1, 0.7, region.Bottom - 0.03);
        server.SendSubtitle(text["This is a test subtitle. Can you see it on top of the game?"], 8000, box);
    }

    /// <summary>
    /// Ana ekrandaki "TV'de dene": çeviri başlamadıysa altyazı sunucusu da açılır (TV uygulaması ona bağlanabilsin),
    /// sonra deneme altyazısı gönderilir. Port açılamazsa yalnız bilgisayar ekranındaki pencereye gider.
    /// </summary>
    public async Task SendTestSubtitleAsync()
    {
        try { await StartServerAsync(); } catch (SocketException) { }
        // Çeviri sürmüyorken TV'nin eşleştirme isteği (TV 0.9.34+) reddediliyordu: Android TV anahtarı başlatma yoluyla
        // alamaz, "TV'de test et"e TV'de yalnız "Eşleştirme tamamlanmadı" çıkıyordu. Deneme, Ayarlar'daki "TV eşleştir"
        // gibi iki dakikalık onay penceresi açar; TV kodu gösterince bilgisayarda onay sorulur.
        if (!isRunning) server.Pairing.Open();
        // TV uygulaması bağlı değilse deneme altyazısı kimseye gitmiyordu: bekçi yalnız çeviri sürerken çalışır, TV
        // uygulaması kapalıysa ya da bilgisayarı arıyorsa "TV'de test et"e TV'de hiçbir şey çıkmıyordu (Samsung 65S95F).
        // Önce TV uygulaması açılır (Samsung'da geliştirici bağlantısıyla) ve bağlanması beklenir.
        if (ShowsOnTv && HasTv && tv is { Brand: not TvBrand.AndroidTv } target && server.ConnectedClients == 0)
            await OpenTvAppForTestAsync(target);
        // Android TV uygulaması bilgisayarı kendisi bulur; eşleştirme onayı da gerekebilir. Yazı TV bağlanınca gitsin.
        else if (ShowsOnTv && HasTv && tv is { Brand: TvBrand.AndroidTv } && server.ConnectedClients == 0)
            await WaitForTvForTestAsync(TestPairWait);
        SendTestSubtitle();
    }

    /// <summary>"TV'de test et"te TV uygulamasının açılıp bağlanması için en çok bu kadar beklenir.</summary>
    public TimeSpan TestTvWait { get; set; } = TimeSpan.FromSeconds(20);

    /// <summary>Android TV'de deneme altyazısı için TV'nin bağlanması (gerekirse eşleştirme onayı) en çok bu kadar beklenir.</summary>
    public TimeSpan TestPairWait { get; set; } = TimeSpan.FromSeconds(30);

    private async Task WaitForTvForTestAsync(TimeSpan wait)
    {
        OpeningTvAppForTest = true;
        try
        {
            var deadline = DateTime.UtcNow + wait;
            while (server.ConnectedClients == 0 && DateTime.UtcNow < deadline) await Task.Delay(250);
        }
        finally { OpeningTvAppForTest = false; }
    }

    /// <summary>Deneme altyazısından önce TV uygulaması bağlanıyor (ana ekrandaki düğme beklerken bunu gösterir).</summary>
    public bool OpeningTvAppForTest
    {
        get => openingTvAppForTest;
        private set => Set(ref openingTvAppForTest, value);
    }

    private bool openingTvAppForTest;

    /// <summary>
    /// TV uygulamasını açar ve bağlanmasını bekler. Çeviri sürüyorsa bekçi hemen yeniden dener; sürmüyorsa geçici bir
    /// bekçi kurulur, bekleme bitince kapanır.
    /// </summary>
    private async Task OpenTvAppForTestAsync(LgTv target)
    {
        IKeeper? temporary = null;
        if (keeper is not null) keeper.Reconnect();
        else
        {
            var running = server;
            temporary = services.MakeKeeper(target, store.Load<string>(StoreKeys.TvKey),
                new Dictionary<string, string> { ["server"] = ServerAddress(target), ["key"] = running.AccessKey }, () => running.ConnectedClients > 0,
                moved => post(() => TvMoved(moved)), key => post(() => store.Save(StoreKeys.TvKey, key)));
            temporary.Start(TimeSpan.FromSeconds(5));
        }
        OpeningTvAppForTest = true;
        try
        {
            var deadline = DateTime.UtcNow + TestTvWait;
            while (server.ConnectedClients == 0 && DateTime.UtcNow < deadline) await Task.Delay(250);
        }
        finally
        {
            temporary?.Stop();
            OpeningTvAppForTest = false;
        }
    }

    /// <summary>
    /// Num 0: canlı altyazı çevirisini duraklatır ya da sürdürür. Alan çevirirken sürekli çeviri de TV'de görünüp
    /// karışmasın diye kullanılır. TV'de kısa bir bildirim çıkar. Çeviri sürmüyorsa bir şey yapmaz.
    /// </summary>
    public void ToggleSubtitles()
    {
        if (!isRunning) return;
        var pause = !subtitlesPaused;
        SubtitlesPaused = pause;
        if (pause)
        {
            pipeline?.Reset();
            server.Clear();
        }
        // Duraklatınca ek bölgeler de okunmaz, kutuları kalkar.
        UpdateRegionWatcher();
        server.SendStyle(settings.Style);
        server.SendSubtitle(text[pause ? "Subtitle translation paused" : "Subtitle translation resumed"], 1800);
    }

    /// <summary>Num 8: ayar ekranı, oyunun şu anki görüntüsünü yeniden alsın.</summary>
    public event Action? SnapshotRequested;

    public void RequestSnapshot() => SnapshotRequested?.Invoke();

    /// <summary>Çeviri bilgisayarda da gösterilecekse (metin, kalma süresi ms) ile çağrılır.</summary>
    public event Action<string, int>? PcResultReady;

    /// <summary>
    /// 1, 2 ya da 3 numaralı ek bölgeyi şimdi bir kez okuyup çevirir; sonuç ayardaki yere (TV, bilgisayar ya da ikisi) gider
    /// (görev paneli gibi yazılar için). Çeviri sürmüyorsa, bölge kapalıysa ya da önceki istek bitmediyse hiçbir şey yapılmaz.
    /// </summary>
    public async Task<ExtraRegionOutcome> TranslateExtraRegionAsync(int slot)
    {
        if (settings.ExtraRegion(slot) is not { } region) return ExtraRegionOutcome.NotConfigured;
        if (lastFrame is not { } frame) return ExtraRegionOutcome.NotRunning;
        var target = settings.ExtraTarget(slot);
        return (await RunRegionAsync(frame, region, target != ResultTarget.Pc, target != ResultTarget.Tv)).Outcome;
    }

    /// <summary>
    /// Serbest alan (Num 5): verilen karedeki alanı bir kez okuyup çevirir. Sonuç, ayardaki hedefe göre TV'ye de gönderilir;
    /// bilgisayarda gösterilmek üzere her durumda döner (serbest alan penceresi kendisi gösterir).
    /// </summary>
    public Task<(ExtraRegionOutcome Outcome, RegionTranslation.Result? Result)> TranslateAreaAsync(Frame frame, CropRegion region) =>
        RunRegionAsync(frame, region, settings.FreeAreaTarget != ResultTarget.Pc, false);

    private async Task<(ExtraRegionOutcome Outcome, RegionTranslation.Result? Result)> RunRegionAsync(Frame frame, CropRegion region, bool toTv, bool toPcPopup)
    {
        var reader = activeReader;
        if (!isRunning || reader is null) return (ExtraRegionOutcome.NotRunning, null);
        // Tuşa üst üste basılınca ikinci bir okuma başlamaz.
        if (Interlocked.Exchange(ref extraBusy, 1) == 1) return (ExtraRegionOutcome.Busy, null);
        try
        {
            RegionTranslation.Result? result;
            try
            {
                result = await RegionTranslation.TranslateOnceAsync(frame, region, reader, MakeTranslator());
            }
            catch (TranslatorException error)
            {
                post(() => TranslatorStatus = error.Status);
                return (ExtraRegionOutcome.TranslatorUnavailable, null);
            }
            catch
            {
                return (ExtraRegionOutcome.Failed, null);
            }
            if (result is null)
            {
                var message = text["No text found in this area."];
                if (toTv)
                {
                    server.SendStyle(settings.Style);
                    server.SendSubtitle(message, 2500, new TextBox(region.Left, region.Top, region.Right, region.Bottom));
                }
                if (toPcPopup) post(() => PcResultReady?.Invoke(message, 2500));
                return (ExtraRegionOutcome.NoText, null);
            }
            var milliseconds = RegionTranslation.DisplayMilliseconds(result.Translation);
            if (toTv)
            {
                server.SendStyle(settings.Style);
                server.SendSubtitle(result.Translation, milliseconds, result.Box, paragraphs: result.Structured);
            }
            post(() =>
            {
                LastSource = result.Source;
                LastTranslation = result.Translation;
                if (toPcPopup) PcResultReady?.Invoke(result.Translation, milliseconds);
            });
            return (ExtraRegionOutcome.Shown, result);
        }
        finally
        {
            Volatile.Write(ref extraBusy, 0);
        }
    }

    /// <summary>Süren "ekranı çevir" işi; yeniden basılınca iptal edilir.</summary>
    private CancellationTokenSource? screenWork;
    /// <summary>TV'deki ekran çevirilerinin kalkacağı an; bu andan önce yeniden basmak onları kaldırır.</summary>
    private DateTime screenShownUntil;

    /// <summary>
    /// Num 9: oyunun şu anki karesinin tamamını bir kez okur, her yazı grubunu ayrı çevirip TV'de kendi yerine koyar.
    /// Çeviriler hazırlandıkça TV'ye gider. Çeviri sürerken ya da çeviriler TV'deyken yeniden basmak onları kaldırır.
    /// </summary>
    public async Task<ScreenOutcome> TranslateScreenAsync()
    {
        var reader = activeReader;
        if (!isRunning || reader is null) return ScreenOutcome.NotRunning;
        if (lastFrame is not { } frame)
        {
            // Çeviri sürüyor ama PS5'ten henüz görüntü gelmedi: tuş sessizce yok sayılmasın.
            server.SendSubtitle(text["Couldn't capture the screen: no picture from the PS5 yet."], 4000);
            return ScreenOutcome.NotRunning;
        }
        if (screenWork is { } running)
        {
            running.Cancel();
            screenWork = null;
            HideScreen();
            return ScreenOutcome.Cleared;
        }
        if (DateTime.UtcNow < screenShownUntil)
        {
            HideScreen();
            return ScreenOutcome.Cleared;
        }

        using var work = new CancellationTokenSource();
        screenWork = work;
        server.SendStyle(settings.Style);
        server.SendSubtitle(text["Translating the screen…"], 2500);
        ITextTranslator? translator = null;
        try
        {
            translator = MakeTranslator();
            // Yapay zekâda ekranın bütün yazıları tek istekte gider (bkz. AiTranslator.TranslateAllAsync).
            var items = await ScreenTranslation.TranslateAsync(frame, reader, translator, shown =>
            {
                if (work.IsCancellationRequested) return;
                server.SendScreen(shown, ScreenTranslation.DisplayMilliseconds(shown));
                screenShownUntil = DateTime.UtcNow.AddMilliseconds(ScreenTranslation.DisplayMilliseconds(shown));
            }, work.Token);
            server.Clear();
            if (items.Count == 0)
            {
                server.SendSubtitle(text["No text found on the screen."], 2500);
                return ScreenOutcome.NoText;
            }
            return ScreenOutcome.Shown;
        }
        catch (OperationCanceledException)
        {
            return ScreenOutcome.Cleared;
        }
        catch (TranslatorException error)
        {
            post(() => TranslatorStatus = error.Status);
            ShowScreenFailure(error, translator);
            return ScreenOutcome.TranslatorUnavailable;
        }
        catch (Exception error)
        {
            RemotePlayLog.Note($"Ekran çevrilemedi: {error.GetType().Name}: {error.Message}");
            ShowScreenFailure(error, translator);
            return ScreenOutcome.Failed;
        }
        finally
        {
            if (screenWork == work) screenWork = null;
        }
    }

    /// <summary>Ekran çevrilemedi: nedeni TV'de (ve bilgisayardaki altyazıda) birkaç saniye görünür, sessizce kaybolmaz.</summary>
    private void ShowScreenFailure(Exception error, ITextTranslator? translator)
    {
        server.Clear();
        var reason = ScreenFailureReason(error, translator, settings.OnlineEngine, text, settings.LocalAiServer);
        server.SendSubtitle(text.Format("Couldn't translate the screen: %@", reason), 6000);
    }

    /// <summary>Ekran çevirisinin neden olmadığı: önce çevrimiçi motorun hatası, sonra ücretsiz çevirinin durumu.</summary>
    public static string ScreenFailureReason(Exception error, ITextTranslator? translator, TranslationEngine engine, Localizer text,
                                             LocalAiServer? server = null)
    {
        if (translator is IOnlineTranslator online)
        {
            if (online.LastError is { } failure) return failure.Describe(engine, text, server);
            if (online.LastLineWasRateLimited)
                return text.Format("%@ has reached its per-minute limit. Try again in a minute.", engine.DisplayName());
        }
        return (error as TranslatorException)?.Status switch
        {
            TranslatorStatus.NeedsDownload => text["The free translation isn't downloaded yet."],
            TranslatorStatus.EngineFailed => text["The free translation couldn't be started."],
            _ => text["Something went wrong. Try again."],
        };
    }

    private void HideScreen()
    {
        screenShownUntil = default;
        server.ClearScreen();
        server.Clear();
    }

    /// <summary>Kurulumu baştan başlatır (kayıtlı her şeyi siler).</summary>
    public void ResetSetup()
    {
        Stop();
        xboxGeneration++;
        services.Xbox?.Clear();
        foreach (var key in new[] { StoreKeys.AccountId, StoreKeys.Console, StoreKeys.ConsoleKind, StoreKeys.ConsoleKindLocked, StoreKeys.XboxToken, StoreKeys.XboxConsole,
                     StoreKeys.Tv, StoreKeys.TvKey, StoreKeys.TvDevKey, StoreKeys.TvAppVersion, StoreKeys.SetupComplete, StoreKeys.LoginPasscode }) store.Remove(key);
        accountId = null;
        console = null;
        consoleKind = GameConsoleKind.PlayStation;
        consoleKindLocked = false;
        xboxToken = null;
        xboxConsole = null;
        tv = null;
        tvAppMissing = false;
        TvApp = TvAppState.Unknown;
        Step = OnboardingStep.Welcome;
        Changed(nameof(HasAccount), nameof(Console), nameof(ConsoleKind), nameof(ConsoleKindLocked), nameof(IsXbox), nameof(ConsoleTitle), nameof(HasXboxAccount),
            nameof(SelectedXboxConsole), nameof(StepCount), nameof(StepNumber), nameof(Ps5StatusText), nameof(Tv), nameof(CanReinstallTvApp), nameof(HasTv), nameof(NeedsTv), nameof(CanStart), nameof(HasLoginPasscode));
    }

    /// <summary>İkinci hesabın PS5 giriş şifresi şifreli depoda kayıtlı mı (şifrenin kendisi arayüze dönmez).</summary>
    public bool HasLoginPasscode => LoginPasscode.Normalized(store.Load<string>(StoreKeys.LoginPasscode)) is not null;

    /// <summary>Yalnız 4 hane şifreli depoya yazılır; geçersizse false. Sonraki bağlantıda kullanılır.</summary>
    public bool SetLoginPasscode(string value)
    {
        if (LoginPasscode.Normalized(value) is not { } pin) return false;
        store.Save(StoreKeys.LoginPasscode, pin);
        Changed(nameof(HasLoginPasscode));
        return true;
    }

    public void RemoveLoginPasscode()
    {
        store.Remove(StoreKeys.LoginPasscode);
        Changed(nameof(HasLoginPasscode));
    }

    // --- Çeviri ---

    public async Task StartAsync()
    {
        // Düğmeye iki kez basılması ya da beklerken tekrar çağrılması ikinci bir oturum açmaz.
        if (isRunning || isStarting || !CanStart) return;
        // PS5 için hesap gerekir; Remote Play, açıkça seçilen OBS/oyun penceresi ve Xbox için gerekmez.
        var readsWindow = !IsXbox && settings.FrameSource == FrameSource.RemotePlayWindow;
        var readsCapture = !IsXbox && settings.FrameSource == FrameSource.CaptureWindow;
        if (!IsXbox && !readsWindow && !readsCapture && (console is null || accountId is null)) return;
        IsStarting = true;
        try
        {
            // Uygulama başlatırken kapanırsa günlükte hangi adımda kaldığı görünsün.
            RemotePlayLog.Note($"Çeviri hazırlanıyor; altyazı: {settings.Output}, TV: {(tv is null ? "yok" : tv.Brand.ToString())}");
            RefreshTranslatorStatus();
            try { await StartServerAsync(); } catch { /* port açılamadıysa TV durumu "bekleniyor" kalır */ }
            server.SendStyle(settings.Style);
            SubtitlesPaused = false;
            MetricsText = "";
            framesSince = null;
            sawLineThisRun = false;
            ShowsSubtitleOffTip = false;
            MakePipeline();
            if (settings.Dubbing.Enabled && DubbingInstalled) MakeDubber()?.Prepare();
            SubtitleLog.Write($"oturum başladı: {settings.SourceLanguage}→{settings.TargetLanguage}, "
                + $"motor: {(OnlineTranslationActive ? settings.OnlineEngine.ToString() : "ücretsiz")}, paketler: {(settings.GamePacks ? "açık" : "kapalı")}, "
                + $"görüntü: {(IsXbox ? "Xbox" : readsWindow ? "Remote Play penceresi" : readsCapture ? "seçilen pencere" : "PS5")}");

            IStreamSession stream;
            if (IsXbox)
            {
                RemotePlayLog.Note($"Çeviri başladı; {ConsoleTitle} bağlantısı açılıyor.");
                stream = (services.Xbox ?? throw new InvalidOperationException(text["Xbox streaming isn't available in this version."]))
                    .MakeStream(xboxConsole!, xboxToken!, settings.XboxLegacyFrameRate, settings.XboxAudioOnComputer);
                xboxNameChecked = false;
            }
            else if (readsWindow)
            {
                RemotePlayLog.Note($"Çeviri başladı; görüntü bu bilgisayardaki Remote Play penceresinden ({settings.RemotePlayApp})");
                stream = services.MakeWindowStream(settings.RemotePlayApp);
            }
            else if (readsCapture)
            {
                var target = settings.CaptureWindow ?? throw new InvalidOperationException("A capture window must be selected.");
                RemotePlayLog.Note($"Çeviri başladı; seçilen pencere: {target.ProcessName} / {target.Title}");
                stream = services.MakeCaptureWindowStream(target);
            }
            else
            {
                RemotePlayLog.Note($"Çeviri başladı; PS5'e bağlanılıyor: {console!.Name} {console.Host}");
                stream = services.MakeStream(console, accountId!, store.Load<string>(StoreKeys.LoginPasscode));
            }
            stream.StateChanged += state => post(() => SessionStateChanged(state));
            stream.ConsoleMoved += moved => post(() => ConsoleMoved(moved));
            stream.FrameReceived += HandleFrame;
            stream.Start();
            session = stream;

            server.Pairing.SetSession(true);
            StartKeeper();
            StartGameSense();

            sleep.Begin(KeepsDisplayOn);
            IsRunning = true;
            UpdateTroubleClocks();
        }
        catch (Exception error)
        {
            // Yarım kalan başlatma geride çalışan bir PS5 oturumu bırakmasın; düğme yeniden "Başlat" olur.
            RemotePlayLog.Note($"Çeviri başlatılamadı: {error.GetType().Name}: {error.Message}");
            Stop();
            throw;
        }
        finally
        {
            IsStarting = false;
        }
    }

    /// <summary>
    /// TV uygulamasını başlatır ve açık tutar; TV kapalıysa açıldığında bağlanır. Altyazı TV'ye gitmiyorsa ya da TV
    /// yoksa bir şey yapmaz.
    /// </summary>
    private void StartKeeper()
    {
        if (keeper is not null || !ShowsOnTv || !HasTv || tv is not { } target) return;
        var running = server;
        var tvKeeper = services.MakeKeeper(target, store.Load<string>(StoreKeys.TvKey), new Dictionary<string, string> { ["server"] = ServerAddress(target), ["key"] = server.AccessKey },
            () => running.ConnectedClients > 0, moved => post(() => TvMoved(moved)), key => post(() => store.Save(StoreKeys.TvKey, key)));
        tvKeeper.Start(TimeSpan.FromSeconds(5));
        keeper = tvKeeper;
        _ = RefreshTvAppAsync();
    }

    /// <summary>Altyazının yeri değişti: TV seçildiyse TV uygulaması açılır, kaldırıldıysa artık açık tutulmaz.</summary>
    /// <summary>
    /// Çeviri sürerken bilgisayar ekranı da açık kalsın mı: görüntü bu bilgisayardaki Remote Play ya da seçilen pencereden
    /// okunuyorsa (ekran kapanınca yakalama kare vermez) ya da altyazı bu ekranda gösteriliyorsa. PS5'ten ya da Xbox'tan
    /// doğrudan okunup yalnız TV'ye gönderiliyorsa ekran kendi ayarıyla kapanabilir.
    /// </summary>
    private bool KeepsDisplayOn =>
        (!IsXbox && settings.FrameSource is FrameSource.RemotePlayWindow or FrameSource.CaptureWindow) || ShowsOnComputer;

    private void OutputChanged()
    {
        server.SendsToTv = ShowsOnTv;
        if (!ShowsOnComputer)
        {
            OverlayAdjusting = false;
            OverlayHidden?.Invoke();
        }
        Changed(nameof(ShowsOnTv), nameof(ShowsOnComputer), nameof(NeedsTv), nameof(CanStart), nameof(CanAdvance));
        UpdateTroubleClocks();
        if (!isRunning) return;
        sleep.Begin(KeepsDisplayOn);
        if (ShowsOnTv) StartKeeper();
        else
        {
            // Altyazı artık TV'ye gitmiyor: TV uygulaması kapanır, TV kendi girişine döner.
            var stoppedKeeper = keeper;
            keeper = null;
            stoppedKeeper?.Stop();
            if (stoppedKeeper is not null) _ = server.ExitTvApp();
        }
    }

    // --- Bilgisayar ekranındaki altyazı penceresi ---

    /// <summary>
    /// TV'ye giden altyazı ve temizleme olaylarının aynısı (arayüz iş parçacığında); bilgisayar ekranındaki pencere bunları
    /// TV uygulamasıyla aynı yığınla (<see cref="SubtitleStack"/>) gösterir. Altyazı bilgisayarda gösterilmiyorsa gelmez.
    /// </summary>
    public event Action<SubtitleEvent>? OverlayEvent;
    /// <summary>Penceredeki her şey hemen kalksın (çeviri durdu ya da altyazı artık bilgisayarda değil).</summary>
    public event Action? OverlayHidden;

    private bool overlayAdjusting;

    /// <summary>Pencerenin yeri ve genişliği ayarlanıyor: örnek yazı görünür, tıklamalar geçmez.</summary>
    public bool OverlayAdjusting { get => overlayAdjusting; set => Set(ref overlayAdjusting, value); }

    private bool hotkeysPaused;

    /// <summary>
    /// Ayarlar'da yeni kısayol bekleniyor: genel kısayollar bırakılır, böylece basılan tuş (çeviri sürerken bile) işi
    /// çalıştırmadan seçim kutusuna ulaşır.
    /// </summary>
    public bool HotkeysPaused { get => hotkeysPaused; set => Set(ref hotkeysPaused, value); }

    /// <summary>Num 7 ve ana ekrandaki seçenek: altyazı penceresinde tıklamaların geçmesini açar/kapatır.</summary>
    public void ToggleClickThrough() => Settings = settings with { OverlayClickThrough = !settings.OverlayClickThrough };

    /// <summary>Taşınan ya da genişletilen pencerenin yeri kaydedilir.</summary>
    public void SaveOverlayBounds(OverlayBounds bounds) => Settings = settings with { Overlay = bounds };

    private void OnSubtitleEvent(SubtitleEvent e)
    {
        post(() => StreamEvent?.Invoke(e));
        if (!ShowsOnComputer) return;
        post(() => OverlayEvent?.Invoke(e));
    }

    // --- Yayın penceresi (yayın programlarının pencere yakalamayla aldığı düz zeminli altyazı) ---

    /// <summary>
    /// <see cref="OverlayEvent"/> ile aynı olaylar, ama altyazı yalnız TV'de gösterilse de gelir: yayın penceresi açıkken
    /// yayındaki altyazı ekrandaki seçimden bağımsızdır.
    /// </summary>
    public event Action<SubtitleEvent>? StreamEvent;
    /// <summary>Yayın penceresindeki her şey hemen kalksın (çeviri durdu).</summary>
    public event Action? StreamHidden;

    /// <summary>Yayın penceresinin zemin rengi (chroma key ile silinir).</summary>
    public StreamBackground StreamBackground
    {
        get => StreamBackgrounds.FromStored(store.Load<string>(StoreKeys.StreamBackground));
        set
        {
            if (value == StreamBackground) return;
            store.Save(StoreKeys.StreamBackground, value.StoredName());
            Changed(nameof(StreamBackground));
        }
    }

    /// <summary>Bilgisayarın ağ adresiyle OBS sayfası; localhost'u kabul etmeyen yayın programları (TikTok LIVE Studio) için.</summary>
    public string? NetworkObsAddress => LocalAddress(null) is { } address ? $"http://{address}:{ServerPort}/obs?k={server.AccessKey}" : null;

    /// <summary>Kullanıcı çeviriyi durdurdu: oturum biter, TV uygulaması da kapanır (#268).</summary>
    public void Stop() => _ = StopSession(closeTvApp: true);

    /// <summary>
    /// Ayar değişikliği gibi iç yeniden başlatmalarda kullanılır: oturum biter ama TV uygulaması açık kalır; hemen
    /// ardından gelen <see cref="StartAsync"/> aynı TV bağlantısını kullanır.
    /// </summary>
    public void StopForRestart() => _ = StopSession(closeTvApp: false);

    /// <summary>Oturumu bitirir; TV uygulamasına çıkış gönderildiyse mesajın yazılmasını bekleyen görevi döner.</summary>
    private Task StopSession(bool closeTvApp)
    {
        server.Pairing.SetSession(false);
        var stoppedKeeper = keeper;
        keeper = null;
        stoppedKeeper?.Stop();
        var exiting = closeTvApp && stoppedKeeper is not null ? server.ExitTvApp() : Task.CompletedTask;
        session?.Stop();
        session?.Dispose();
        session = null;
        UpdateGameProbe(connected: false);
        StopGameSense();
        EndGameAreas();
        pipeline?.Reset();
        framesSince = null;
        ShowsSubtitleOffTip = false;
        if (pipeline is not null) SubtitleLog.Write("oturum bitti");
        pipeline = null;
        UpdateRegionWatcher();
        // Yeni "Başlat" eski oturumdan kalan (belki takılmış) okumayı beklemeden temiz başlar.
        frameGate.Reset();
        activeReader = null;
        screenWork?.Cancel();
        screenWork = null;
        if (DateTime.UtcNow < screenShownUntil) server.ClearScreen();
        screenShownUntil = default;
        SubtitlesPaused = false;
        ActiveSourceLanguage = null;
        OnlineIssue = null;
        StopDubber();
        if (isRunning) sleep.End();
        IsRunning = false;
        SessionState = SessionState.Disconnected(DisconnectKind.Stopped);
        UpdateTroubleClocks();
        firewallRuleSeen = false;
        ClearFirewallPrompt();
        OverlayHidden?.Invoke();
        StreamHidden?.Invoke();
        return exiting;
    }

    /// <summary>Bilgisayar uykudan uyanınca bağlantıları hemen yenile.</summary>
    public void SystemResumed()
    {
        session?.ReconnectNow();
        keeper?.Reconnect();
    }

    /// <summary>Çeviri başlamamışken bağlı olmamak bir sorun değildir; nokta gri kalır.</summary>
    public static StatusTone Ps5ToneFor(SessionState state, bool running) =>
        state.Phase == SessionPhase.Streaming ? StatusTone.Good : running ? StatusTone.Warning : StatusTone.Idle;

    public static StatusTone TvToneFor(int clients, bool running) =>
        clients > 0 ? StatusTone.Good : running ? StatusTone.Warning : StatusTone.Idle;

    /// <summary>PS5 durumunun kullanıcıya gösterilecek metni.</summary>
    /// <param name="pairedName">Eşleşmiş PS5'in adı. Çeviri başlamamışken eşleşmiş PS5 için "Bağlı değil" yerine "eşleşti,
    /// başlatınca bağlanır" denir: eskiden eşleştirme başarılı olsa da ana ekran "Bağlı değil" diyordu.</param>
    /// <summary>Görüntü bu bilgisayardaki Remote Play penceresinden okunurken durumun metni.</summary>
    public static string CaptureWindowStatusText(SessionState state, bool running, Localizer text, WindowCaptureTarget? target)
    {
        if (target is not { ProcessName.Length: > 0, Title.Length: > 0 })
            return text["Choose an OBS or game window in Settings › Picture source."];
        if (state.Phase == SessionPhase.Streaming) return text["Reading the selected window"];
        if (!running) return text.Format("Ready to read %@ when translation starts.", target.Title);
        return state.Reason?.Detail is { Length: > 0 } detail
            ? detail
            : text.Format("Waiting for the selected window: %@", target.Title);
    }

    public static string WindowStatusText(SessionState state, bool running, Localizer text, bool installed = true)
    {
        const string waiting = "Waiting for the Remote Play window. Open PS Remote Play or chiaki-ng on this PC.";
        if (state.Phase != SessionPhase.Streaming && !installed)
            return text["The Remote Play app isn't installed on this PC. Download it in Settings › Picture source."];
        switch (state.Phase)
        {
            case SessionPhase.Streaming: return text["Reading the Remote Play window"];
            case SessionPhase.Connecting: return text[waiting];
        }
        if (!running) return text["Reads the Remote Play window on this PC when you start translating."];
        return state.Reason?.Detail is { Length: > 0 } detail ? detail : text[waiting];
    }

    public static string StatusText(SessionState state, bool running, Localizer text, string? pairedName = null)
    {
        switch (state.Phase)
        {
            case SessionPhase.Streaming: return text["Connected"];
            case SessionPhase.Connecting: return text["Connecting…"];
        }
        if (!running)
            return pairedName is null ? text["Not connected"] : text.Format("Paired with %@. Connects when you start translating.", pairedName);
        var detail = state.Reason?.Detail;
        return state.Reason?.Kind switch
        {
            DisconnectKind.ConsoleAsleep => text["Turn on your PS5"],
            DisconnectKind.InUse => text["Remote Play is in use on another device"],
            // Eskiden "PS5'i yeniden kurun" deniyordu; TCP reddi eşleme sorunu değildir, yeniden eşlemek çözmez.
            DisconnectKind.Refused => text["The PS5 did not accept the connection yet. It may still be starting up, or its network address may have changed. Reconnecting and searching for the PS5… If this keeps happening, make sure the PS5 is on and on the same network."],
            DisconnectKind.LoginPasscode => text["The PS5 asks for this account's login passcode. Enter it in Settings, or turn off this account's login passcode on the PS5."],
            // Yanlış şifre bir kez gönderilir; PS5 yeniden isterse oturum kapanır (döngü yok).
            DisconnectKind.LoginPasscodeIncorrect => text["The PS5 didn't accept the login passcode in Settings. Correct it, or turn off this account's login passcode on the PS5."],
            // Eskiden "Yeniden bağlanılıyor… (Unknown Session Request Error)" diye sonsuza kadar deneniyordu.
            DisconnectKind.RegistrationInvalid => text["The PS5 didn't accept this pairing. Pair the PS5 again with the second account in Settings."],
            // Eskiden ağ hatası, bulunamayan PS5 ve diğer nedenler hep yalnız "Yeniden bağlanılıyor…" idi.
            DisconnectKind.NotFound => text.Format("PS5 not found at %@. Make sure it is on and on the same network. Reconnecting…", detail ?? "?"),
            // Kablosuz ağda akış sık kopuyordu (GitHub #388, #401): yeniden bağlanılır, kalıcı çözüm kablodur.
            DisconnectKind.Network => text["Lost the connection to the PS5. Reconnecting… If this keeps happening, connect the PS5 to the router with a cable."],
            // 0x80108b12: PS5'te Uzaktan Oynatma kapalı (GitHub #9). Ayar açılınca yeniden denemede bağlanılır.
            DisconnectKind.Rejected when detail == ApplicationReasons.RemotePlayDisabled =>
                text.Format("Remote Play is turned off on the PS5 (code %@). On the PS5, go to Settings › System › Remote Play and turn on Enable Remote Play.", detail),
            // Eskiden "Yeniden bağlanılıyor… (Unknown Session Request Error)" görünüyordu (GitHub #33, #202).
            DisconnectKind.Rejected when !string.IsNullOrEmpty(detail) => text.Format("The PS5 rejected the connection (code %@). Another Remote Play app (PS Remote Play) may be open, or the PS5 may be in another session. Close PS Remote Play, restart the PS5, then try again.", detail),
            DisconnectKind.Rejected => text["The PS5 didn't start the session. Another Remote Play app (PS Remote Play) may be open, or the PS5 may be in another session. Close PS Remote Play, restart the PS5, then try again."],
            // Eskiden İngilizce "Remote Play on Console has crashed" ile sonsuza kadar "Yeniden bağlanılıyor…" (GitHub #519).
            DisconnectKind.ConsoleRemotePlayCrashed => text["Remote Play on the PS5 has crashed. Turn the PS5 off completely (not rest mode) and back on, then connect again."],
            DisconnectKind.Other when !string.IsNullOrEmpty(detail) => text.Format("Reconnecting… (%@)", detail),
            _ => text["Reconnecting…"],
        };
    }

    public void Dispose()
    {
        services.Translation.EngineFailure -= OnEngineFailure;
        services.Translation.GpuFallback -= OnGpuFallback;
        if (services.Xbox is { } xbox) xbox.TokenUpdated -= OnXboxTokenUpdated;
        var exiting = StopSession(closeTvApp: true);
        if (services.Xbox is IDisposable disposableXbox) disposableXbox.Dispose();
        // Sunucu kapanmadan TV'ye çıkış mesajı yazılsın; TV yanıt vermiyorsa kapanış en çok bir saniye bekler.
        try { exiting.Wait(TimeSpan.FromSeconds(1)); }
        catch (AggregateException) { }
        server.Dispose();
        poolTimer?.Dispose();
        packTimer?.Dispose();
        // Kapanırken kuyruk bir kez daha gönderilir; en çok birkaç saniye beklenir.
        if (services.Pool is { } pool)
        {
            try { pool.FlushAsync().Wait(TimeSpan.FromSeconds(3)); }
            catch (AggregateException) { }
            pool.Save();
        }
    }

    // --- Oyun paketleri ve ortak havuz ---

    /// <summary>Ayarlarda listelenen paketler (açılışta arka planda yüklenince dolar).</summary>
    public IReadOnlyList<GamePackLibrary.Info> InstalledPacks { get => installedPacks; private set => Set(ref installedPacks, value); }

    public void ReloadGamePacks()
    {
        if (services.GamePacks is not { } packs) return;
        packs.Reload();
        InstalledPacks = packs.Packs;
    }

    /// <summary>Oynanan oyunun adı (bilinmiyorsa null): ana ekrandaki "Oynanan oyun: X · Değiştir".</summary>
    public string? PlayedGame { get => playedGame; private set => Set(ref playedGame, value); }

    /// <summary>"Hangi oyunu oynuyorsunuz?" kartı açık.</summary>
    public bool AskingGame { get => askingGame; private set => Set(ref askingGame, value); }

    /// <summary>Bu PS5'te son seçilen oyun.</summary>
    public string? LastPlayedGame =>
        GameConsoleName is { } name && store.Load<Dictionary<string, string>>(StoreKeys.LastGames) is { } saved ? saved.GetValueOrDefault(name) : null;

    private string? GameConsoleName => console is null ? null : string.IsNullOrEmpty(console.Name) ? console.Host : console.Name;

    /// <summary>Kartın önerileri: son oynanan, kurulu paketlerin oyunları ve popüler oyunlar.</summary>
    public IReadOnlyList<string> GameSuggestions(string query) =>
        GameCatalog.Suggestions(query, GameCatalog.PackGames(installedPacks), LastPlayedGame);

    /// <summary>Kullanıcı bir oyun seçti ya da adını yazdı; seçim PS5'in adıyla saklanır.</summary>
    public void ChooseGame(string name)
    {
        if (RunningGame.Named(name)?.Name is not { } clean) return;
        gameSense.Choose(clean);
        if (GameConsoleName is { } consoleName)
        {
            var saved = store.Load<Dictionary<string, string>>(StoreKeys.LastGames) ?? new Dictionary<string, string>();
            saved[consoleName] = clean;
            store.Save(StoreKeys.LastGames, saved);
        }
        AskingGame = false;
        PublishGame();
    }

    /// <summary>"Değiştir": kart elle açılır.</summary>
    public void AskGame()
    {
        gameSense.MarkAsked();
        AskingGame = true;
    }

    /// <summary>"Sorma": bu oturumda bir daha sorulmaz.</summary>
    public void DismissGame()
    {
        gameSense.MarkAsked();
        AskingGame = false;
    }

    // --- Oyuna göre alanlar (Ayarlar › Alan ve ana ekrandaki oyun kartı) ---

    /// <summary>Uygulanan alan profilinin oyunu; genel alanlar kullanılıyorsa null.</summary>
    public string? AreaProfileGame => settings.FindAreaProfile(settings.ActiveAreaProfile)?.Game;

    /// <summary>Profil etkin ve alanlar profilden sonra değişti: "Profile kaydet" gösterilir (kaydedilmezse oturum bitince bırakılır).</summary>
    public bool AreaProfileUnsaved => settings.AreasDifferFromProfile;

    /// <summary>
    /// Alanların kaydedilebileceği oyun: çeviri sürüyor ve oyun biliniyor. Profil etkinse o profilin oyunu; değilse
    /// oynanan oyun ("Bu alanları X için kaydet").
    /// </summary>
    public string? AreaProfileTarget => session is null ? null : AreaProfileGame ?? PlayedGame;

    /// <summary>Paketten tanınan oyunun kayıtlı alanları var; kullanıcıya sorulur. Kartta gösterilen oyun adı.</summary>
    public string? OfferedAreaProfileGame => settings.FindAreaProfile(offeredAreaProfile)?.Game;

    /// <summary>"Kullan": önerilen profil uygulanır.</summary>
    public void UseOfferedAreaProfile()
    {
        if (settings.FindAreaProfile(offeredAreaProfile) is { } profile) ApplyAreaProfile(profile);
        SetOfferedAreaProfile(null);
    }

    /// <summary>"Hayır": önerilen profil bu oturumda bir daha sorulmaz.</summary>
    public void DeclineOfferedAreaProfile()
    {
        if (offeredAreaProfile is { } key) declinedAreaProfiles.Add(key);
        SetOfferedAreaProfile(null);
    }

    /// <summary>"Geri al": genel alanlara dönülür; bu oyunun profili bu oturumda yeniden uygulanmaz.</summary>
    public void UndoAreaProfile()
    {
        if (settings.ActiveAreaProfile is not { } key) return;
        declinedAreaProfiles.Add(key);
        Settings = settings.WithGeneralAreas();
        SubtitleLog.Write("alan profili geri alındı: " + key);
    }

    /// <summary>Okunan alanlar etkin profile, profil yoksa oynanan oyuna kaydedilir.</summary>
    public void SaveAreaProfile()
    {
        if (AreaProfileTarget is not { } game) return;
        declinedAreaProfiles.RemoveWhere(key => key == AreaProfiles.Key(game, settings.AreaSource));
        Settings = settings.WithSavedAreaProfile(game);
        SubtitleLog.Write("alan profili kaydedildi: " + settings.ActiveAreaProfile);
    }

    /// <summary>Etkin profil silinir ve genel alanlara dönülür.</summary>
    public void DeleteAreaProfile()
    {
        if (settings.ActiveAreaProfile is not { } key) return;
        Settings = settings.WithoutAreaProfile(key);
        SubtitleLog.Write("alan profili silindi: " + key);
    }

    private void ApplyAreaProfile(AreaProfile profile)
    {
        Settings = settings.WithAreaProfile(profile);
        SubtitleLog.Write("alan profili uygulandı: " + profile.Key);
    }

    private void SetOfferedAreaProfile(string? key)
    {
        if (offeredAreaProfile == key) return;
        offeredAreaProfile = key;
        Changed(nameof(OfferedAreaProfileGame));
    }

    /// <summary>Oyun değişti (ya da çeviri başladı): o oyunun kayıtlı alanları uygulanır, önerilir ya da genel alanlara dönülür.</summary>
    private void FollowGameAreas()
    {
        Changed(nameof(AreaProfileTarget));
        if (session is null) return;
        var decision = AreaProfiles.Decide(settings.ActiveAreaProfile, gameSense.Current?.Name, gameSense.Source, settings.AreaSource,
                                           key => settings.FindAreaProfile(key) is not null, declinedAreaProfiles.Contains);
        SetOfferedAreaProfile(decision.Step == AreaProfiles.Step.Offer ? decision.Key : null);
        switch (decision.Step)
        {
            case AreaProfiles.Step.Apply when settings.FindAreaProfile(decision.Key) is { } profile:
                ApplyAreaProfile(profile);
                break;
            case AreaProfiles.Step.UseGeneral:
                Settings = settings.WithGeneralAreas();
                SubtitleLog.Write("başka oyun: genel alanlara dönüldü");
                break;
        }
    }

    /// <summary>Oturum bitti: profil bırakılır (kaydedilmemiş alan değişiklikleri de), sorular sıfırlanır.</summary>
    private void EndGameAreas()
    {
        declinedAreaProfiles.Clear();
        SetOfferedAreaProfile(null);
        if (settings.ActiveAreaProfile is not null || settings.GeneralAreas is not null) Settings = settings.WithGeneralAreas();
        Changed(nameof(AreaProfileTarget));
    }

    /// <summary>Oyun değiştiyse havuza bildirilir; yeni oyunun (havuzdan otomatik) paketi sunucuda yeni çıkmış olabilir.</summary>
    private void PublishGame()
    {
        // Elle seçilen oyunda satırlar yalnız o oyunun paketinde aranır, paketi yoksa hiç aranmaz (#218).
        services.GamePacks?.LimitToGame(gameSense.PackLimit);
        var current = gameSense.Current;
        PlayedGame = current?.Name;
        FollowGameAreas();
        if (current == publishedGame) return;
        // Yeni oyunda aynı HUD satırının çevirisi ve paketi farklı olabilir.
        regionWatcher?.Reset();
        publishedGame = current;
        UpdateRegionWatcher();
        services.Pool?.SetGame(current);
        if (current is not null && services.PackUpdates is { } packUpdater) _ = RefreshPacksAsync(packUpdater, maxAge: PackUpdater.GameCheckInterval);
    }

    /// <summary>Çeviri başladı: oyun penceresi sıfırlanır, iki dakika sonra oyun hâlâ bilinmiyorsa kart açılır.</summary>
    private void StartGameSense()
    {
        gameSense.StartSession();
        publishedGame = null;
        AskingGame = false;
        PublishGame();
        gameAsk?.Cancel();
        gameAsk?.Dispose();
        var cancel = new CancellationTokenSource();
        gameAsk = cancel;
        var token = cancel.Token;
        var started = DateTime.UtcNow;
        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(15), token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                if (!gameSense.ShouldAsk(DateTime.UtcNow - started, settings.AskGame && settings.SharePool)) continue;
                gameSense.MarkAsked();
                post(() => { if (!token.IsCancellationRequested) AskingGame = true; });
                return;
            }
        }, CancellationToken.None);
    }

    private void StopGameSense()
    {
        gameAsk?.Cancel();
        gameAsk?.Dispose();
        gameAsk = null;
        AskingGame = false;
    }

    /// <summary>Paketler yalnız İngilizce→Türkçede ve ayar açıkken kullanılır.</summary>
    private bool PacksActive => settings.GamePacks && settings.SourceLanguage == "en" && settings.TargetLanguage == "tr" && services.GamePacks is not null;

    private void StartPacksAndPool()
    {
        // Paketler ilk altyazıyı bekletmesin diye açılışta arka planda yüklenir.
        if (services.GamePacks is { } packs)
            _ = Task.Run(() =>
            {
                packs.WarmUp();
                post(() => InstalledPacks = packs.Packs);
            });
        StartPackUpdates();
        if (services.Pool is not { } pool) return;
        pool.SetEnabled(settings.SharePool);
        // Beş dakikada bir gönderilir; sunucuya ulaşılamazsa kuyruk diskte bekler, sonra yeniden denenir.
        poolTimer = new Timer(_ => _ = pool.FlushAsync(), null, LinePool.FlushInterval, LinePool.FlushInterval);
    }

    /// <summary>
    /// Paket sunucusu yapılandırıldıysa açılışta ve günde bir bakılır; PS5'te yeni bir oyun tanınınca da
    /// (<see cref="PackUpdater.GameCheckInterval"/>). Yeni paket inince paketler yeniden okunur.
    /// </summary>
    private void StartPackUpdates()
    {
        if (services.PackUpdates is not { } updater) return;
        var first = true;
        packTimer = new Timer(_ =>
        {
            _ = RefreshPacksAsync(updater, force: first);
            first = false;
        }, null, TimeSpan.Zero, PackUpdater.RefreshInterval);
    }

    private async Task RefreshPacksAsync(PackUpdater updater, bool force = false, TimeSpan? maxAge = null)
    {
        try
        {
            var result = await updater.RefreshAsync(force, maxAge: maxAge).ConfigureAwait(false);
            if (!result.Changed || services.GamePacks is not { } packs) return;
            packs.Reload();
            post(() => InstalledPacks = packs.Packs);
            SubtitleLog.Write("paketler güncellendi: " + string.Join(", ", result.Downloaded.Concat(result.Removed)));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or HttpRequestException)
        {
            // Sonraki bakışta yeniden denenir.
        }
    }

    /// <summary>PS5'e bağlanınca çalışan oyun okunmaya başlar, bağlantı gidince bırakılır (havuz satırı oyunsuz gider).</summary>
    private void UpdateGameProbe(bool connected)
    {
        if (services.Pool is null) return;
        if (!connected || console?.Host is not { } host)
        {
            gameProbe?.Cancel();
            gameProbe?.Dispose();
            gameProbe = null;
            gameSense.SetConsole(null);
            PublishGame();
            return;
        }
        if (gameProbe is not null) return;
        var cancel = new CancellationTokenSource();
        gameProbe = cancel;
        var token = cancel.Token;
        _ = Task.Run(async () =>
        {
            RunningGame? last = null;
            while (!token.IsCancellationRequested)
            {
                RunningGame? game;
                try { game = await services.RunningGameAsync(host).ConfigureAwait(false); }
                catch (Exception) { game = null; }
                // Bu arada bağlantı bittiyse oyun yazılmaz (bırakılan oyun geri gelmesin).
                if (token.IsCancellationRequested) break;
                gameSense.SetConsole(game);
                // Paket sunucusuna bakılması PublishGame'de.
                post(() => { if (!token.IsCancellationRequested) PublishGame(); });
                if (game is not null && game != last) SubtitleLog.Write($"PS5'te çalışan oyun: {game.Name ?? "?"} ({game.TitleId ?? "?"})");
                last = game;
                try { await Task.Delay(GameProbeInterval, token).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }, CancellationToken.None);
    }

    private void ConnectPacks(SubtitlePipeline target)
    {
        target.PackLookup = PacksActive ? services.FindInPacks : null;
        // Kısmi eşleşme yalnız GTA'da denendi; öteki oyunlarda okumanın tamamı eskisi gibi motora gider.
        target.PartialPackLookup = PacksActive ? text => ScreenText.IsGta(gameSense.Current?.Name) ? services.FindPartialInPacks(text) : null : null;
    }

    /// <summary>Gelişmiş ayarlardaki bekleme süreleri (0–2 sn).</summary>
    private void ApplyWaits(SubtitlePipeline target)
    {
        target.PackWait = Math.Clamp(settings.MisreadWaitMs, 0, 2000);
        target.CleanWait = Math.Clamp(settings.PartialWaitMs, 0, 2000);
    }

    /// <summary>Pakette olmayan İngilizce satır havuza önerilir (paketler kapalıysa da yalnız hiçbir pakette olmayanlar).</summary>
    private void OfferToPool(string text)
    {
        if (settings.SourceLanguage != "en" || services.Pool is not { } pool) return;
        if (!PacksActive && services.FindInPacks(text) is not null) return;
        pool.Offer(text);
    }

    // --- İç işleyiş ---

    /// <summary>Okuma hattını güncel dillerle (yeniden) kurar.</summary>
    private void MakePipeline()
    {
        pipeline?.Reset();
        pipeline = null;
        // Ek bölge okuyucusu da yeni dil ve motorla yeniden kurulur.
        ResetRegionWatcher(discard: true);
        // Eski hatta süren okuma beklenmez; yeni hat ilk karesini hemen alır.
        frameGate.Reset();
        ActiveSourceLanguage = settings.SourceLanguage;
        var reader = services.MakeReader(settings.SourceLanguage, settings.OcrEngine);
        activeReader = reader;
        // Gelişmiş yazı tanıma Windows'un dil paketine gerek duymaz.
        OcrMissing = reader is null || (!(settings.OcrEngine == OcrEngine.Advanced && AdvancedOcrInstalled)
                                        && !services.HasOcrLanguage(settings.SourceLanguage));
        if (reader is null) return;
        var scheduler = new ReadScheduler(maxReuse: settings.FastSubtitleDetection
            ? ReadScheduler.FastMaxReuse : ReadScheduler.DefaultMaxReuse);
        var built = new SubtitlePipeline(reader, MakeTranslator(), server, scheduler)
        {
            ShowSpeakerNames = settings.ShowSpeakerNames,
            SkipsTurkish = settings.TargetLanguage == "tr",
            WatchSubtitleBackground = settings.WatchSubtitleBackground,
            DropsScreenText = () => ScreenText.IsGta(gameSense.Current?.Name),
        };
        built.MetricsReady += metrics => post(() => MetricsText = metrics.Summary(text));
        built.PairShown += (source, translation) =>
        {
            var box = built.LastBox;
            var origin = built.LastOrigin == "paket" ? LineOrigin.Pack : LineOrigin.Engine;
            // Satır yalnız tek bir pakette bulunduysa o pakete bir oy: son 20 satırın 5'i aynı paketten gelince oyun odur.
            var hit = services.GamePacks?.TakeDistinctiveHit();
            var recognised = gameSense.NoteLine(origin == LineOrigin.Pack ? hit?.Id : null, origin == LineOrigin.Pack ? hit?.Title : null);
            post(() =>
            {
                if (recognised)
                {
                    AskingGame = false;
                    PublishGame();
                }
                LastSource = source;
                LastTranslation = translation;
                sawLineThisRun = true;
                UpdateSubtitleOffTip();
                if (box is not null) lastSubtitleBox = box;
                AddToHistory(source, translation, origin);
            });
        };
        // Model bu arada inmiş olabilir; her çeviri sonucu durumu günceller.
        built.TranslationResult += error => post(() => TranslatorStatus = error ?? TranslatorStatus.Ready);
        built.SpeechReady += lines => post(() => Speak(lines));
        built.PackMissed += OfferToPool;
        built.Log = SubtitleLog.Write;
        built.PackName = () => services.GamePacks?.SearchScope;
        ConnectPacks(built);
        ApplyWaits(built);
        OnlineIssue = null;
        pipeline = built;
        UpdateRegionWatcher();
    }

    /// <summary>Sürekli okunan ek bölgeleri okuyup çeviren; çeviri sürerken ve en az bir bölge sürekli okunurken var.</summary>
    private RegionWatcher? regionWatcher;
    private readonly object regionGate = new();
    private IReadOnlyList<WatchedArea> savedWatchedAreas = [];
    private IReadOnlyList<WatchedArea> watchedAreas = [];
    private GamePhoneTracker? phoneTracker;
    private WatchedArea? phoneArea;
    private CancellationTokenSource? phoneLifetime;
    private bool watcherRequested;

    /// <summary>
    /// Ek bölge okuyucusu gerekiyorsa kurulur, gerekmiyorsa kaldırılır (kutuları TV'den kalkar). Kendi yazı tanıma motoru
    /// vardır: aynı motor iki okumayı birden yapamaz, ek bölge okuması altyazıyı bekletmesin. Paketler altyazıyla aynıdır;
    /// ek bölge satırları havuza önerilmez.
    /// </summary>
    private void UpdateRegionWatcher()
    {
        lock (regionGate)
        {
            watcherRequested = false;
            var running = pipeline is not null && !subtitlesPaused;
            if (running && settings.AutoReadGamePhone && GameName.Key(gameSense.Current?.Name) == "gta 6")
                phoneTracker ??= new GamePhoneTracker();
            else
            {
                ClosePhone();
                phoneTracker = null;
            }
            savedWatchedAreas = running ? settings.WatchedAreas() : [];
            watchedAreas = phoneArea is null ? savedWatchedAreas : [.. savedWatchedAreas, phoneArea];
            if (watchedAreas.Count == 0)
            {
                if (phoneTracker is null)
                {
                    regionWatcher?.Reset();
                    regionWatcher = null;
                }
                return;
            }
            if (regionWatcher is null)
            {
                if (services.MakeReader(settings.SourceLanguage, settings.OcrEngine) is not { } reader)
                {
                    // Okuyucu kurulamadıysa her örnekte tekrar açma. Yeni telefon veya ayar değişikliği yeniden dener.
                    watcherRequested = phoneArea is not null;
                    return;
                }
                regionWatcher = new RegionWatcher(reader, MakeTranslator(), server) { Log = SubtitleLog.Write };
            }
            regionWatcher.PackLookup = PacksActive ? services.FindInPacks : null;
            regionWatcher.SkipsTurkish = settings.TargetLanguage == "tr";
            regionWatcher.TranslatesUiCommands = settings.SourceLanguage == "en" && settings.TargetLanguage == "tr";
            regionWatcher.EnglishPhoneMessages = settings.SourceLanguage == "en";
            regionWatcher.Game = () => gameSense.Current?.Name;
        }
    }

    // regionGate altında. Kapanan telefonun geç tamamlanan isteği yeni bir telefona veya diğer alanlara yazamaz.
    private void ClosePhone()
    {
        if (phoneArea is null) return;
        phoneLifetime!.Cancel();
        regionWatcher?.RemovePanel(phoneArea.Id);
        phoneLifetime.Dispose();
        phoneLifetime = null;
        phoneArea = null;
        watcherRequested = false;
        watchedAreas = savedWatchedAreas;
    }

    private void ResetRegionWatcher(bool discard)
    {
        lock (regionGate)
        {
            ClosePhone();
            phoneTracker?.Reset();
            regionWatcher?.Reset();
            if (discard) regionWatcher = null;
        }
    }

    private void OfferWatchedAreas(Frame frame, long arrived)
    {
        if (Volatile.Read(ref regionWatcher) is null && Volatile.Read(ref phoneTracker) is null) return;
        // Okuyucu ayarlar değişirken kuruluyorsa ana altyazı karesini bekletme.
        if (!Monitor.TryEnter(regionGate)) return;
        var requestWatcher = false;
        try
        {
            if (phoneTracker is not null && phoneTracker.TrySample(frame, arrived, out var region))
            {
                if (region is null)
                    ClosePhone();
                else
                {
                    phoneLifetime ??= new CancellationTokenSource();
                    var area = phoneTracker.WithPose(new WatchedArea("game-phone", "Phone", region) { PanelLifetime = phoneLifetime.Token });
                    if (area != phoneArea)
                    {
                        phoneArea = area;
                        watchedAreas = [.. savedWatchedAreas, area];
                    }
                }
                if (region is not null && regionWatcher is null && !watcherRequested)
                    requestWatcher = watcherRequested = true;
            }
            regionWatcher?.Offer(frame, watchedAreas);
        }
        finally { Monitor.Exit(regionGate); }
        // OCR/çevirmen yalnız doğrulanmış bir panelde gerekir. İlk kuruluş kare iş parçacığını tutmaz.
        if (requestWatcher) post(UpdateRegionWatcher);
    }

    // --- Geçmiş ---

    /// <summary>Gösterilen satır geçmişe eklenir (arayüz iş parçacığında) ve dosyaya yazılır.</summary>
    private void AddToHistory(string source, string translation, LineOrigin origin)
    {
        if (!history.Add(source, translation, origin)) return;
        Changed(nameof(History));
        SaveHistory();
    }

    /// <summary>Geçmişi siler (dosyadaki de boşalır).</summary>
    public void ClearHistory()
    {
        history.Clear();
        Changed(nameof(History));
        SaveHistory();
    }

    /// <summary>Bekleyen geçmiş yazmalarının bitmesini bekler (testler ve kapanış için).</summary>
    public Task WaitForHistoryAsync() => historySave;

    /// <summary>
    /// Geçmişin kopyası arayüzü bekletmeden, önceki yazmanın ardından dosyaya yazılır. Yazılamazsa (dosya kilitli) bir
    /// sonraki satırda yeniden denenir.
    /// </summary>
    private void SaveHistory()
    {
        if (services.HistoryFile is not { } file) return;
        var copy = history.Copy();
        historySave = historySave.ContinueWith(_ =>
        {
            try { copy.Save(file); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
    }

    private ITextTranslator MakeTranslator()
    {
        var local = MakeLocalTranslator();
        // Açılamayan ücretsiz motor yedek olamaz; çevrimiçi motor çeviremeyince satır yeniden denenir.
        var fallback = local is UnavailableTranslator || services.Translation.EngineFailed ? null : local;
        var engine = settings.OnlineEngine;
        if (!OnlineTranslationActive || engine.StoreKey() is not { } storeKey) return local;
        // Oynanan oyunun adı modele bağlam olarak gider, önbellek de oyuna göre ayrılır. Ad kararlı oyundur (GameSense:
        // PS5'in bildirdiği, kullanıcının seçtiği ya da son 20 satırın 5'i aynı paketten gelince o paketin oyunu); son
        // eşleşen paket değil, yoksa tek bir ortak satır adı başka oyuna geçirirdi (#27). Oyun bilinmiyorsa ad gitmez.
        Func<string?> game = () => gameSense.Current?.Name;
        ITextTranslator? online;
        if (engine == TranslationEngine.Local && settings.LocalAiServer is { } server)
        {
            // Yerel modelin anahtarı isteğe bağlıdır; önbellekte sunucu ve model ayrı tutulur.
            online = services.MakeLocalAiTranslator(server, store.Load<string>(storeKey) ?? "", fallback, game, settings.AiInstruction);
        }
        else
        {
            if (store.Load<string>(storeKey) is not { Length: > 0 } key) return local;
            online = engine.Provider() is { } provider
                ? services.MakeAiTranslator(provider, key, provider.Model(settings.ModelFor(provider)).Id, fallback, game, settings.AiInstruction,
                    settings.GeminiPaidTier && provider == AiProvider.Gemini)
                : services.MakeOnlineTranslator(key, fallback);
        }
        if (online is null) return local;
        // Hizmet çeviremeyince ana ekranda uyarı çıkar; düzelince kalkar.
        if (online is IOnlineTranslator reporting) reporting.FailureChanged += state => post(() => OnlineIssue = state);
        return online;
    }

    private ITextTranslator MakeLocalTranslator()
    {
        var translation = services.Translation;
        var (source, target) = (settings.SourceLanguage, settings.TargetLanguage);
        if (!translation.IsSupported(source, target)) return new UnavailableTranslator(TranslatorStatus.Unsupported);
        if (!translation.IsInstalled(source, target)) return new UnavailableTranslator(TranslatorStatus.NeedsDownload);
        if (translation.EngineFailed) return new UnavailableTranslator(TranslatorStatus.EngineFailed);
        try
        {
            return translation.Create(source, target);
        }
        catch (Exception error)
        {
            // Çeviriyi başlatma, motor açılamadı diye yarıda kalmasın: oyun paketleri ve çevrimiçi motorlar çalışır,
            // ana ekranda uyarı çıkar.
            RemotePlayLog.Note($"Ücretsiz çeviri motoru açılamadı: {error.GetType().Name}: {error.Message}");
            if (!OnlineTranslationActive) post(() => TranslatorStatus = TranslatorStatus.EngineFailed);
            return new UnavailableTranslator(TranslatorStatus.EngineFailed);
        }
    }

    /// <summary>Çevrimiçi çeviri yalnız İngilizce→Türkçe için ve seçili motor hazırsa açılır.</summary>
    public bool OnlineTranslationActive =>
        settings.OnlineTranslation && settings.SourceLanguage == "en" && settings.TargetLanguage == "tr" && IsReady(settings.OnlineEngine);

    /// <summary>
    /// Motor kullanılabilir mi: bulut motorlarında anahtar kayıtlıdır; yerel modelde anahtar gerekmez, adres ve model adı
    /// geçerli olmalıdır. Sunucu kapalıysa satırlar ücretsiz çeviriyle gelir ve ana ekranda uyarı çıkar.
    /// </summary>
    public bool IsReady(TranslationEngine engine) =>
        engine == TranslationEngine.Local ? settings.LocalAiServer is not null : HasKey(engine);

    /// <summary>Bu motorun anahtarı kayıtlı mı (anahtarın kendisi arayüze hiç dönmez).</summary>
    public bool HasKey(TranslationEngine engine) => engine.StoreKey() is { } storeKey && store.Load<string>(storeKey) is { Length: > 0 };

    /// <summary>Kayıtlı bir DeepL anahtarı var mı.</summary>
    public bool HasDeepLKey => HasKey(TranslationEngine.DeepL);

    /// <summary>Anahtar denenir; geçerliyse (kotası bitmiş olsa da) şifreli depoya yazılır ve DeepL seçilir.</summary>
    public async Task<OnlineKeyCheck> SetDeepLKeyAsync(string key)
    {
        key = key.Trim();
        var check = await services.CheckOnlineKeyAsync(key);
        if (check.State is OnlineKeyState.Valid or OnlineKeyState.QuotaExceeded) SaveKey(TranslationEngine.DeepL, key);
        return check;
    }

    /// <summary>Kayıtlı anahtarın bu ayki kullanımı.</summary>
    public Task<OnlineKeyCheck> CheckDeepLKeyAsync() =>
        store.Load<string>(StoreKeys.DeepLKey) is { Length: > 0 } key ? services.CheckOnlineKeyAsync(key)
            : Task.FromResult(new OnlineKeyCheck(OnlineKeyState.Invalid));

    public void RemoveDeepLKey() => RemoveKey(TranslationEngine.DeepL);

    /// <summary>
    /// Yapay zekâ anahtarı örnek bir satırla denenir. Anahtar kabul edildiyse (bakiye bitmiş ya da model adı yanlış olsa
    /// da) şifreli depoya yazılır ve bu motor seçilir.
    /// </summary>
    public async Task<AiTestResult> SetAiKeyAsync(AiProvider provider, string key)
    {
        key = key.Trim();
        var result = await services.TestAiKeyAsync(provider, key, provider.Model(settings.ModelFor(provider)).Id);
        if (result.State is OnlineKeyState.Valid or OnlineKeyState.QuotaExceeded or OnlineKeyState.ModelRejected or OnlineKeyState.Busy)
            SaveKey(provider.Engine(), key);
        return result;
    }

    /// <summary>Kayıtlı anahtar ve modelle örnek satırı çevirir (ayarlardaki "Dene").</summary>
    public Task<AiTestResult> TestAiKeyAsync(AiProvider provider) =>
        provider.Engine().StoreKey() is { } storeKey && store.Load<string>(storeKey) is { Length: > 0 } key
            ? services.TestAiKeyAsync(provider, key, provider.Model(settings.ModelFor(provider)).Id)
            : Task.FromResult(new AiTestResult(OnlineKeyState.Invalid));

    /// <summary>
    /// Ayarlardaki "Bağlantıyı dene": yerel model sunucusuna örnek satırı gönderir. <paramref name="typed"/> yazıldıysa o,
    /// yoksa kayıtlı anahtar kullanılır; yazılan anahtar sunucu kabul ettiyse şifreli depoya yazılır. Adres geçersizse
    /// sunucuya ulaşılamadı sayılır.
    /// </summary>
    public async Task<AiTestResult> TestLocalAiAsync(string typed = "")
    {
        if (settings.LocalAiServer is not { } server) return new AiTestResult(OnlineKeyState.Unreachable);
        typed = typed.Trim();
        var key = typed.Length > 0 ? typed : store.Load<string>(StoreKeys.LocalAiKey) ?? "";
        var result = await services.TestLocalAiAsync(server, key);
        if (typed.Length > 0 && result.State is OnlineKeyState.Valid or OnlineKeyState.QuotaExceeded or OnlineKeyState.ModelRejected or OnlineKeyState.Busy)
            SaveKey(TranslationEngine.Local, typed);
        return result;
    }

    public void RemoveKey(TranslationEngine engine)
    {
        if (engine.StoreKey() is not { } storeKey) return;
        store.Remove(storeKey);
        if (engine == TranslationEngine.Local)
        {
            // Yerel modelin anahtarı isteğe bağlıdır: anahtarsız çeviri sürer, hat anahtarsız yeniden kurulur.
            if (settings.Engine == engine && isRunning) MakePipeline();
            return;
        }
        Changed(nameof(HasDeepLKey), nameof(UsesFreeGemini));
        if (settings.Engine == engine) Settings = settings.WithEngine(TranslationEngine.Free);
        RefreshTranslatorStatus();
    }

    private void SaveKey(TranslationEngine engine, string key)
    {
        if (engine.StoreKey() is not { } storeKey) return;
        store.Save(storeKey, key);
        Changed(nameof(HasDeepLKey));
        // Motor zaten seçiliydi, anahtar yeni geldi: hat yeni anahtarla kurulsun.
        if (settings.Engine == engine && isRunning) MakePipeline();
        else Settings = settings.WithEngine(engine);
        Changed(nameof(UsesFreeGemini));
        RefreshTranslatorStatus();
    }

    private void RefreshTranslatorStatus()
    {
        var translation = services.Translation;
        TranslatorStatus = OnlineTranslationActive ? TranslatorStatus.Ready
            : !translation.IsSupported(settings.SourceLanguage, settings.TargetLanguage) ? TranslatorStatus.Unsupported
            : !translation.IsInstalled(settings.SourceLanguage, settings.TargetLanguage) ? TranslatorStatus.NeedsDownload
            : translation.EngineFailed ? TranslatorStatus.EngineFailed
            : TranslatorStatus.Ready;
    }

    /// <summary>PS5'in adresi değişti: sonraki açılışlar yeni adresle başlasın.</summary>
    private void ConsoleMoved(RegisteredConsole moved)
    {
        if (console is null) return;
        console = moved;
        store.Save(StoreKeys.Console, moved);
        Changed(nameof(Console), nameof(Ps5StatusText));
    }

    /// <summary>altyazi.log'a yazılan kopma nedeni: türü; adres (NotFound) yazılmaz, PS5'in kodu ve libchiaki metni yazılır.</summary>
    public static string DisconnectLogName(DisconnectReason? reason) => reason switch
    {
        null => "?",
        { Kind: DisconnectKind.Rejected or DisconnectKind.Other, Detail: { Length: > 0 } detail } => $"{reason.Kind}: {detail}",
        _ => reason.Kind.ToString(),
    };

    private void SessionStateChanged(SessionState state)
    {
        // Altyazı günlüğünde durumun türü ve kopmanın nedeni (adres remoteplay.log'da). Neden eskiden yazılmıyordu; GitHub
        // #456'daki altyazi.log'da 30 kopmanın hiçbirinin nedeni görünmüyordu.
        if (state.Phase != SessionState.Phase)
            SubtitleLog.Write(state.Phase switch
            {
                SessionPhase.Connecting => $"{ConsoleTitle}: bağlanıyor",
                SessionPhase.Streaming => $"{ConsoleTitle}: bağlandı",
                _ => $"{ConsoleTitle}: bağlantı yok ({DisconnectLogName(state.Reason)})",
            });
        // PS5'in kendi tarafındaki çökme ayrıca yazılır: kullanıcının günlüğünde nedeni görünsün (GitHub #519).
        if (state.Reason?.Kind == DisconnectKind.ConsoleRemotePlayCrashed && SessionState.Reason?.Kind != DisconnectKind.ConsoleRemotePlayCrashed)
            SubtitleLog.Write("PS5: Uzaktan Oynatma PS5'te çöktü (Remote Play on Console has crashed); PS5 tamamen kapatılıp açılmalı");
        SessionState = state;
        // Bağlantı kopunca görüntü süresi baştan sayılır.
        if (state.Phase != SessionPhase.Streaming) framesSince = null;
        UpdateSubtitleOffTip();
        UpdateTroubleClocks();
        if (!IsXbox) UpdateGameProbe(state.Phase == SessionPhase.Streaming);
        else if (state.Phase == SessionPhase.Streaming && !xboxNameChecked)
        {
            xboxNameChecked = true;
            _ = RefreshXboxNameAsync();
        }
        // Bağlantı koptuysa TV'de eski altyazı kalmasın.
        if (state.Phase == SessionPhase.Disconnected)
        {
            pipeline?.Reset();
            ResetRegionWatcher(discard: false);
            server.Clear();
            dubber?.Stop();
        }
    }

    /// <summary>
    /// Kare iş parçacığında çağrılır. async void olduğu için buradan hiçbir hata kaçmamalı: kaçan hata eşzamanlama
    /// bağlamı olmayan iş parçacığında süreci kapatırdı.
    /// </summary>
    private async void HandleFrame(Frame frame)
    {
        // Gecikme karenin geldiği andan ölçülür (hattın varsayılan saatiyle aynı saat).
        var arrived = Environment.TickCount64;
        try
        {
            post(() =>
            {
                LastFrame = frame;
                UpdateSubtitleOffTip(frameArrived: true);
            });
            // Duraklatıldıysa kare yalnız ek bölgeler ve serbest alan için saklanır; altyazı okunmaz.
            if (subtitlesPaused) return;
            // Önceki kare hâlâ işleniyorsa bu kare atlanır; okuma kareleri biriktirmez.
            var current = pipeline;
            if (current is null) return;
            // Ek bölgeler ayrı ve seyrek okunur (saniyede bir, kendi okuyucusuyla); altyazı okumasını beklemez, onu bekletmez.
            OfferWatchedAreas(frame, arrived);
            var entry = frameGate.TryEnter(Environment.TickCount64);
            if (entry.Kind == FrameGate.EntryKind.Stuck)
            {
                // Okuma bitmedi: önizleme canlıyken altyazı hiç gelmiyordu ve ancak uygulamayı kapatıp açmak düzeltiyordu.
                SubtitleLog.Write($"okuma {entry.Ms} ms'dir bitmedi; okuma hattı yeniden kuruldu");
                post(MakePipeline);
                return;
            }
            if (entry.Kind != FrameGate.EntryKind.Enter) return;
            try
            {
                await current.ProcessAsync(frame, settings.Region, arrived);
            }
            finally
            {
                frameGate.Leave(entry.Token);
            }
        }
        catch
        {
            // Tek bir karenin okunamaması akışı durdurmaz.
        }
    }

    private bool preferredPortApplied;

    private async Task StartServerAsync()
    {
        if (serverStarted) return;
        // Linux sunucusunda port elle seçilebilir (COUCHSUBS_SERVER_PORT, #617); doluysa aşağıdaki gibi boş bir porta geçilir.
        if (!preferredPortApplied && services.PreferredServerPort is { } preferred && preferred != DefaultServerPort)
        {
            preferredPortApplied = true;
            DetachServer();
            server = new SubtitleServer(preferred, key: server.AccessKey);
            AttachServer();
        }
        try
        {
            ServerPort = await server.StartAsync();
        }
        catch (SocketException)
        {
            // 8787 başka bir uygulamada; TV'ye adres her seferinde bildirildiği için herhangi bir boş port olur.
            DetachServer();
            server = new SubtitleServer(0, key: server.AccessKey);
            AttachServer();
            ServerPort = await server.StartAsync();
        }
        serverStarted = true;
    }

    private void OnClientsChanged(int count) => post(() =>
    {
        TvClients = count;
        UpdateTroubleClocks();
    });

    /// <summary>TV ile aynı ağdaki bilgisayar adresi.</summary>
    private string ServerAddress(LgTv target) => $"http://{LocalAddress(target.Host) ?? "127.0.0.1"}:{ServerPort}";

    /// <summary>
    /// <paramref name="near"/> adresine (TV) ulaşan bu bilgisayar adresi; TV adresi bilinmiyorsa (null ya da geçersiz)
    /// Wi-Fi/Ethernet adresi. TV adresi biliniyorsa işletim sisteminin TV'ye çıkacağı bağdaştırıcının adresi önce gelir
    /// (birden çok bağdaştırıcıda doğru kaynak adres, #343). VPN ve sanal bağdaştırıcılar ancak başka adres yoksa seçilir
    /// (<see cref="LocalNetwork.ChooseComputerAddress(IReadOnlyList{LocalNetwork.AdapterAddress}, IPAddress?, IPAddress?, IPAddress?)"/>).
    /// TV adresi bilinmiyorsa internete çıkılan bağdaştırıcının (varsayılan yol) adresi önce gelir.
    /// </summary>
    public static string? LocalAddress(string? near)
    {
        IPAddress? target = IPAddress.TryParse(near, out var parsed) && parsed.AddressFamily == AddressFamily.InterNetwork ? parsed : null;
        var route = target is null ? null : LocalNetwork.RouteSourceAddress(target);
        var defaultRoute = target is null ? LocalNetwork.DefaultRouteSourceAddress() : null;
        return LocalNetwork.ChooseComputerAddress(LocalNetwork.Ipv4Adapters(), target, route, defaultRoute);
    }

    /// <summary>
    /// Samsung kurulumunda Host PC IP için gösterilen adresin dışındaki ev ağı adresleri (Wi-Fi ve Ethernet ikisi de
    /// bağlıysa ya da birden çok ağ varsa). TV gösterilen adresi kabul etmezse bunlar denenir.
    /// </summary>
    public string[] OtherComputerAddresses
    {
        get
        {
            var chosen = ComputerAddress;
            return [.. LocalNetwork.HomeAddresses(LocalNetwork.Ipv4Adapters()).Where(a => a != chosen)];
        }
    }

    // --- Windows Güvenlik Duvarı ---

    /// <summary>PS5 bu kadar süre "Yeniden bağlanıyor…" kalırsa güvenlik duvarı kuralına bakılır.</summary>
    public static readonly TimeSpan Ps5TroubleDelay = TimeSpan.FromSeconds(20);
    /// <summary>TV uygulaması bu kadar süre bağlanmazsa güvenlik duvarı kuralına bakılır.</summary>
    public static readonly TimeSpan TvWaitDelay = TimeSpan.FromSeconds(60);

    private FirewallPrompt firewallPrompt;
    /// <summary>Bu çeviri oturumunda kural bulundu; her denetimde kurallar yeniden taranmaz.</summary>
    private bool firewallRuleSeen;
    /// <summary>Beta.44'ün her profili açan geniş kuralı bulundu; TV bağlıyken bu kural çalışıyor demektir.</summary>
    private bool legacyFirewallRule;
    private bool checkingFirewall;
    private DateTime? ps5TroubleSince;
    private DateTime? tvWaitingSince;

    /// <summary>Güvenlik duvarı kartı ya da eşleştirme adımındaki düğme; yalnız kural eksikken önerilir.</summary>
    public FirewallPrompt FirewallPrompt { get => firewallPrompt; private set => Set(ref firewallPrompt, value); }

    /// <summary>Zaman (testlerde ileri sarılır).</summary>
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;

    /// <summary>
    /// Ana ekran birkaç saniyede bir çağırır: PS5 20 saniyedir yeniden bağlanıyorsa ya da TV 60 saniyedir bağlanmadıysa ve
    /// güvenlik duvarında CouchSubs'a izin yoksa kart önerilir. İkisi de bağlanınca kart kalkar.
    /// </summary>
    public async Task CheckConnectionsAsync()
    {
        UpdateTroubleClocks();
        if (!isRunning || services.Firewall is not { } firewall) return;
        if (ps5TroubleSince is null && tvWaitingSince is null)
        {
            ClearFirewallPrompt();
            return;
        }
        // Eski geniş kural varken TV bağlanıyorsa izin sorunu yoktur; kart çıkmaz, eski kural silinmeye açılmaz.
        if (legacyFirewallRule && tvClients > 0)
        {
            if (firewallPrompt is FirewallPrompt.Offer or FirewallPrompt.Failed or FirewallPrompt.PublicNetwork)
                FirewallPrompt = FirewallPrompt.None;
            return;
        }
        var now = Clock();
        var stuck = now - ps5TroubleSince >= Ps5TroubleDelay || now - tvWaitingSince >= TvWaitDelay;
        if (!stuck || firewallPrompt != FirewallPrompt.None || firewallRuleSeen || checkingFirewall) return;
        checkingFirewall = true;
        try
        {
            var prompt = await FirewallProblemAsync(firewall);
            if (!isRunning) return;
            // Eski kuralla TV bağlıyken None döner; TV sonra düşerse yeniden bakılsın diye kilitlenmez.
            if (prompt == FirewallPrompt.None) firewallRuleSeen = !legacyFirewallRule;
            else FirewallPrompt = prompt;
        }
        finally
        {
            checkingFirewall = false;
        }
    }

    /// <summary>
    /// Kuralı yönetici izniyle ekler. Çeviri sürüyorsa PS5 ve TV hemen yeniden denenir; eşleştirmede kullanıcı yeni
    /// kodla yeniden bağlanır.
    /// </summary>
    public async Task<bool> AllowThroughFirewallAsync()
    {
        if (services.Firewall is not { } firewall || firewallPrompt == FirewallPrompt.Working) return false;
        // Ortak ağda eski geniş kuralı silmek çalışan TV bağlantısını keser; önce ağ Özel yapılmalı.
        if (await LegacyRuleOnPublicNetworkAsync(firewall))
        {
            FirewallPrompt = FirewallPrompt.PublicNetwork;
            return false;
        }
        FirewallPrompt = FirewallPrompt.Working;
        bool added;
        try { added = await firewall.AddRuleAsync(); }
        catch (Exception) { added = false; }
        FirewallPrompt = added ? FirewallPrompt.Allowed : FirewallPrompt.Failed;
        if (!added) return false;
        firewallRuleSeen = true;
        legacyFirewallRule = false;
        if (isRunning)
        {
            session?.ReconnectNow();
            keeper?.Reconnect();
        }
        return true;
    }

    /// <summary>Ayarlar: güvenlik duvarı desteklenmiyorsa null; yoksa (kural var mı, ağ "Ortak" mı).</summary>
    public async Task<(bool HasRule, bool PublicNetwork)?> GetFirewallStateAsync()
    {
        if (services.Firewall is not { } firewall) return null;
        var hasRule = await HasFirewallRuleAsync(firewall);
        bool publicNetwork;
        try { publicNetwork = await Task.Run(firewall.HasPublicNetwork); }
        catch (Exception) { publicNetwork = false; }
        return (hasRule, publicNetwork);
    }

    /// <summary>Eşleştirme başarısız oldu: kural eksikse düğme önerilir.</summary>
    private async Task OfferFirewallAsync()
    {
        if (services.Firewall is not { } firewall || firewallPrompt == FirewallPrompt.Working) return;
        FirewallPrompt = await FirewallProblemAsync(firewall);
    }

    /// <summary>
    /// Bağlantı takıldığında gösterilecek kart. İzin yalnız Özel ağda geçerlidir: kural olsa da bilgisayarın ağı "Ortak"
    /// ise TV ve PS5 yine engellenir. Eskiden kural varsa hiçbir şey gösterilmiyor, kullanıcı sebebini göremiyordu.
    /// Eski geniş kural varsa izin düğmesi o kuralı siler: TV bağlıysa kart çıkmaz, ağ Ortak ise ağı Özel yapmak söylenir.
    /// </summary>
    private async Task<FirewallPrompt> FirewallProblemAsync(IFirewall firewall)
    {
        if (!await HasFirewallRuleAsync(firewall))
        {
            try { legacyFirewallRule = await Task.Run(firewall.HasLegacyRule); }
            catch (Exception) { legacyFirewallRule = false; }
            if (!legacyFirewallRule) return FirewallPrompt.Offer;
            if (tvClients > 0) return FirewallPrompt.None;
            return await IsPublicNetworkAsync(firewall) ? FirewallPrompt.PublicNetwork : FirewallPrompt.Offer;
        }
        return await IsPublicNetworkAsync(firewall) ? FirewallPrompt.PublicNetwork : FirewallPrompt.None;
    }

    private static async Task<bool> IsPublicNetworkAsync(IFirewall firewall)
    {
        try { return await Task.Run(firewall.HasPublicNetwork); }
        catch (Exception) { return false; }
    }

    private static async Task<bool> LegacyRuleOnPublicNetworkAsync(IFirewall firewall)
    {
        try { return await Task.Run(firewall.HasLegacyRule) && await IsPublicNetworkAsync(firewall); }
        catch (Exception) { return false; }
    }

    /// <summary>Kurallar arka planda taranır; okunamayan izin verilmiş gibi gösterilmez.</summary>
    private static async Task<bool> HasFirewallRuleAsync(IFirewall firewall)
    {
        try { return await Task.Run(firewall.HasRule); }
        catch (Exception) { return false; }
    }

    private void ClearFirewallPrompt()
    {
        if (firewallPrompt != FirewallPrompt.Working) FirewallPrompt = FirewallPrompt.None;
    }

    /// <summary>
    /// PS5'in ve TV'nin ne zamandan beri bağlanamadığı. PS5 uykudaysa, başka cihazdaysa ya da bağlantıyı reddettiyse
    /// sorun güvenlik duvarı değildir; sayılmaz.
    /// </summary>
    private void UpdateTroubleClocks()
    {
        var now = Clock();
        var ps5Trouble = !IsXbox && isRunning && sessionState.Phase != SessionPhase.Streaming && sessionState.Reason?.Kind is not
            (DisconnectKind.ConsoleAsleep or DisconnectKind.InUse or DisconnectKind.Refused or DisconnectKind.LoginPasscode
             or DisconnectKind.LoginPasscodeIncorrect or DisconnectKind.RegistrationInvalid or DisconnectKind.Rejected
             or DisconnectKind.ConsoleRemotePlayCrashed);
        ps5TroubleSince = ps5Trouble ? ps5TroubleSince ?? now : null;
        // Altyazı TV'ye gitmiyorsa ya da TV yoksa TV beklenmez.
        tvWaitingSince = isRunning && ShowsOnTv && HasTv && tvClients == 0 ? tvWaitingSince ?? now : null;
    }

    // --- Uygulama güncellemesi ---

    /// <summary>GitHub'da daha yeni sürüm varsa numarası.</summary>
    public string? UpdateVersion { get => updateVersion; private set => Set(ref updateVersion, value); }
    public bool Updating { get => updating; private set => Set(ref updating, value); }
    public double UpdateProgress { get => updateProgress; private set => Set(ref updateProgress, value); }
    public string? UpdateError { get => updateError; private set => Set(ref updateError, value); }
    /// <summary>Kurulum dosyasıyla kurulduysa tek tıkla güncellenir; değilse sürüm sayfası açılır.</summary>
    public bool CanUpdateItself => services.Updater?.CanUpdateItself == true;

    public Task<IReadOnlyList<ReleaseNoteRun>> LoadUpdateNotesAsync(string version) =>
        UpdateVersion == version && services.Updater is { } updater ? updater.ReleaseNotesAsync(version)
            : Task.FromResult<IReadOnlyList<ReleaseNoteRun>>([]);

    /// <summary>Açılışta bir kez; ağ yoksa sessizce geçer.</summary>
    public async Task CheckForUpdateAsync()
    {
        if (services.Updater is not { } updater) return;
        try { UpdateVersion = await updater.CheckAsync(); }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException or InvalidOperationException) { }
    }

    public async Task InstallUpdateAsync()
    {
        if (services.Updater is not { } updater || updating) return;
        if (!updater.CanUpdateItself)
        {
            OpenInBrowser(updater.DownloadPage);
            return;
        }
        Updating = true;
        UpdateError = null;
        try
        {
            // Çeviri sürüyorsa önce durur; uygulama güncellenip yeniden açılır.
            Stop();
            await updater.InstallAsync(new ImmediateProgress(value => post(() => UpdateProgress = value)));
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException or InvalidOperationException
                                          or UnauthorizedAccessException)
        {
            UpdateError = error.Message;
        }
        finally
        {
            Updating = false;
        }
    }

    // --- Gelişmiş yazı tanıma ---

    /// <summary>Bu derlemede gelişmiş yazı tanıma var mı.</summary>
    public bool AdvancedOcrAvailable => services.AdvancedOcr is not null;
    public bool AdvancedOcrInstalled => services.AdvancedOcr?.IsInstalled == true;
    public long AdvancedOcrDownloadBytes => services.AdvancedOcr?.DownloadBytes ?? 0;
    public bool AdvancedOcrDownloading { get => advancedOcrDownloading; private set => Set(ref advancedOcrDownloading, value); }
    public double AdvancedOcrProgress { get => advancedOcrProgress; private set => Set(ref advancedOcrProgress, value); }
    public string? AdvancedOcrError { get => advancedOcrError; private set => Set(ref advancedOcrError, value); }
    private bool advancedOcrDownloading;
    private double advancedOcrProgress;
    private string? advancedOcrError;

    /// <summary>Gelişmiş yazı tanımanın modellerini indirir (~31 MB); çeviri sürüyorsa okuyucu hemen değişir.</summary>
    public async Task DownloadAdvancedOcrAsync()
    {
        if (services.AdvancedOcr is not { } model || advancedOcrDownloading || model.IsInstalled) return;
        AdvancedOcrDownloading = true;
        AdvancedOcrError = null;
        try
        {
            await Task.Run(() => model.DownloadAsync(new ImmediateProgress(value => post(() => AdvancedOcrProgress = value)), CancellationToken.None));
            if (isRunning && settings.OcrEngine == OcrEngine.Advanced) MakePipeline();
        }
        catch (Exception error) when (error is HttpRequestException or IOException or InvalidDataException or TaskCanceledException
                                          or TimeoutException or UnauthorizedAccessException)
        {
            AdvancedOcrError = error.Message;
        }
        finally
        {
            AdvancedOcrDownloading = false;
            Changed(nameof(AdvancedOcrInstalled));
        }
    }

    // --- Türkçe dublaj ---

    /// <summary>Bu derlemede dublaj var mı (ses motoru uygulamayla geliyor mu).</summary>
    public bool DubbingAvailable => services.Dubbing is not null || services.FastDubbing is not null;
    public bool FastDubbingAvailable => services.FastDubbing is not null;
    /// <summary>Ayarlarda seçili motor; hızlı ses yoksa doğal sese düşer.</summary>
    private IDubbingModel? ActiveDubbing =>
        settings.Dubbing.Engine == DubbingEngine.Fast && services.FastDubbing is { } fast ? fast : services.Dubbing;
    public bool DubbingInstalled => ActiveDubbing?.IsInstalled == true;
    public long DubbingDownloadBytes => services.Dubbing?.DownloadBytes ?? 0;
    public bool DubbingDownloading { get => dubbingDownloading; private set => Set(ref dubbingDownloading, value); }
    public double DubbingProgress { get => dubbingProgress; private set => Set(ref dubbingProgress, value); }
    public string? DubbingError { get => dubbingError; private set => Set(ref dubbingError, value); }

    /// <summary>Ses modelini indirir (ilk kullanımda bir kez, ~440 MB).</summary>
    public async Task DownloadDubbingAsync()
    {
        if (services.Dubbing is not { } model || dubbingDownloading || model.IsInstalled) return;
        DubbingDownloading = true;
        DubbingError = null;
        try
        {
            await Task.Run(() => model.DownloadAsync(new ImmediateProgress(value => post(() => DubbingProgress = value)), CancellationToken.None));
            if (settings.Dubbing.Enabled && isRunning) MakeDubber()?.Prepare();
        }
        catch (Exception error) when (error is HttpRequestException or IOException or InvalidDataException or TaskCanceledException
                                          or TimeoutException or UnauthorizedAccessException)
        {
            DubbingError = error.Message;
        }
        finally
        {
            DubbingDownloading = false;
            Changed(nameof(DubbingInstalled));
        }
    }

    /// <summary>Ayarlardaki "Dinle": sesi bilgisayardan çalar.</summary>
    public async Task PreviewVoiceAsync(DubbingVoice voice)
    {
        if (!DubbingInstalled) return;
        DubbingError = null;
        try { await StartServerAsync(); } catch (SocketException) { return; }
        MakeDubber()?.Preview(voice);
    }

    public void AssignVoice(DubbingVoice voice, string name)
    {
        var cast = settings.Dubbing.Cast.Copy();
        cast.Assign(voice, name);
        Settings = settings with { Dubbing = settings.Dubbing with { Cast = cast } };
    }

    private Dubber? MakeDubber()
    {
        if (dubber is not null) return dubber;
        if (ActiveDubbing is not { } model || services.Audio is not { } audio) return null;
        var made = new Dubber(model, audio, () => server, () => ServerPort, post)
        {
            Cast = settings.Dubbing.Cast.Copy(),
            Output = settings.Dubbing.Output,
        };
        made.CastChanged += cast => Settings = settings with { Dubbing = settings.Dubbing with { Cast = cast } };
        made.Failed += message => DubbingError = message;
        dubber = made;
        return made;
    }

    private void Speak(IReadOnlyList<SpokenLine> lines)
    {
        if (!settings.Dubbing.Enabled || !DubbingInstalled) return;
        MakeDubber()?.Speak(lines);
    }

    private void DubbingSettingsChanged(DubbingSettings old)
    {
        var now = settings.Dubbing;
        if (now.Engine != old.Engine)
        {
            // Motor değişti: eski dublaj kapanır, yenisi hazırlanır.
            StopDubber();
            Changed(nameof(DubbingInstalled));
            if (now.Enabled && isRunning && DubbingInstalled) MakeDubber()?.Prepare();
            return;
        }
        if (dubber is null)
        {
            if (now.Enabled && !old.Enabled && isRunning && DubbingInstalled) MakeDubber()?.Prepare();
            return;
        }
        // Dublajın kendi atadığı ses (CastChanged) zaten dublajda; kullanıcının seçimi kopyalanır.
        if (!ReferenceEquals(now.Cast, old.Cast)) dubber.Cast = now.Cast.Copy();
        if (now.Output != old.Output)
        {
            dubber.Stop();
            dubber.Output = now.Output;
        }
        if (!now.Enabled) StopDubber();
    }

    private void StopDubber()
    {
        if (dubber is not { } stopping) return;
        dubber = null;
        _ = stopping.DisposeAsync().AsTask();
    }

    private AppException Error(AppError error) => new(error, AppException.Describe(error, text));

    /// <summary>Değer değiştiyse yazar ve özelliği (ve ona bağlı olanları) bildirir.</summary>
    private bool Set<T>(ref T field, T value, string[]? also = null, [CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed([name, .. also ?? []]);
        return true;
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names) PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    /// <summary>Model eksikken ya da dil desteklenmezken kullanılan çevirmen: nedeni bildirir.</summary>
    private sealed class UnavailableTranslator(TranslatorStatus status) : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) => throw new TranslatorException(status);
    }

    /// <summary>İlerlemeyi bağlama yakalamadan doğrudan iletir (post zaten arayüze aktarır).</summary>
    private sealed class ImmediateProgress(Action<double> report) : IProgress<double>
    {
        public void Report(double value) => report(value);
    }
}

/// <summary>Ek bölgenin tek seferlik çevirisinin sonucu.</summary>
public enum ExtraRegionOutcome { Shown, NoText, NotConfigured, NotRunning, Busy, TranslatorUnavailable, Failed }

/// <summary>"Ekranı çevir"in sonucu; <see cref="Cleared"/>: TV'deki çeviriler kaldırıldı ya da süren iş iptal edildi.</summary>
public enum ScreenOutcome { Shown, NoText, Cleared, NotRunning, TranslatorUnavailable, Failed }

/// <summary>Ağda hata ayıklaması açık bulunan Android TV'ler arasından kurulumun gideceği TV (Mac: AndroidTVPick).</summary>
public static class AndroidTvPick
{
    /// <summary>Bulunan adresler (boşlar ve tekrarlar atılır, sıra korunur).</summary>
    public static IReadOnlyList<string> Hosts(IEnumerable<string> found) => [.. found.Where(h => h.Length > 0).Distinct()];

    /// <summary><paramref name="preferred"/>: seçilen ya da kayıtlı TV adresi (önce gelen önce). Bulunanlar arasındaysa o; tek TV
    /// bulunduysa odur; hiç yoksa ya da birden çoksa (kullanıcıya sorulur) null.</summary>
    public static string? Pick(IEnumerable<string> found, IEnumerable<string?> preferred)
    {
        var hosts = Hosts(found);
        foreach (var host in preferred)
            if (!string.IsNullOrEmpty(host) && hosts.Contains(host)) return host;
        return hosts.Count == 1 ? hosts[0] : null;
    }
}
