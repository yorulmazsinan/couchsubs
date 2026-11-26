// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;

namespace CouchSubs.Shell;

public static class StoreKeys
{
    public const string SubtitleAccessKey = "subtitleAccessKey";
    public const string ConsoleKind = "consoleKind";
    public const string ConsoleKindLocked = "consoleKindLocked";
    public const string XboxToken = "xboxToken";
    public const string XboxConsole = "xboxConsole";
    public const string AccountId = "accountId";
    public const string Console = "console";
    public const string Tv = "tv";
    /// <summary>PS5'in adına göre son seçilen oyun ("Hangi oyunu oynuyorsunuz?" kartının ilk önerisi).</summary>
    public const string LastGames = "lastGames";
    public const string TvKey = "tvKey";
    public const string TvDevKey = "tvDevKey";
    /// <summary>Samsung ve Android TV'ye CouchSubs'ın kurduğu sürüm (LG'de sürüm TV'den okunur).</summary>
    public const string TvAppVersion = "tvAppVersion";
    /// <summary>TV uygulamasının daha önce bağlandığı Samsung TV'nin adresi (bkz. SamsungAppKnowledge).</summary>
    public const string TvAppSeen = "tvAppSeen";
    /// <summary>LG geliştirici modu süresinin son uzatıldığı an.</summary>
    public const string DevSessionRenewed = "devSessionRenewed";
    public static string DevSessionRenewedFor(string host) => $"{DevSessionRenewed}.{host.Trim().ToLowerInvariant()}";
    /// <summary>Kullanıcının DeepL anahtarı (isteğe bağlı çevrimiçi çeviri).</summary>
    public const string DeepLKey = "deepLKey";
    /// <summary>Kullanıcının yapay zekâ anahtarları (isteğe bağlı çevrimiçi çeviri).</summary>
    public const string GeminiKey = "geminiKey";
    public const string OpenAiKey = "openAIKey";
    public const string ClaudeKey = "claudeKey";
    public const string DeepSeekKey = "deepSeekKey";
    /// <summary>Yerel model sunucusunun (Ollama, LM Studio) isteğe bağlı anahtarı.</summary>
    public const string LocalAiKey = "localAIKey";
    /// <summary>Kurulum sihirbazı bitti. TV'siz kurulumda (altyazı bilgisayar ekranında) ana ekranı bu açar.</summary>
    public const string SetupComplete = "setupComplete";
    /// <summary>İkinci hesabın PS5 giriş şifresi (4 hane, isteğe bağlı); PS5 isterse oturum açılırken gönderilir.</summary>
    public const string LoginPasscode = "loginPasscode";
    /// <summary>"Yayın penceresi"nin zemin rengi (<see cref="StreamBackground"/>).</summary>
    public const string StreamBackground = "streamBackground";
}

/// <summary>
/// "Yayın penceresi"nin ve OBS sayfasının (<c>/obs?bg=green</c>) düz zemin rengi (Mac: StreamBackground.swift). Şeffaflık
/// tanımayan yayın programları (TikTok LIVE Studio, pencere yakalama) pencereyi yakalar, zemini chroma key ile siler.
/// </summary>
public enum StreamBackground { Green, Black, Magenta }

public static class StreamBackgrounds
{
    /// <summary>0-255 RGB; chroma key'in varsayılanlarıyla (yeşil #00FF00, mor #FF00FF) aynı.</summary>
    public static (byte Red, byte Green, byte Blue) Rgb(this StreamBackground background) => background switch
    {
        StreamBackground.Black => (0x00, 0x00, 0x00),
        StreamBackground.Magenta => (0xFF, 0x00, 0xFF),
        _ => (0x00, 0xFF, 0x00),
    };

    /// <summary>Kayıttaki ad (Mac ile aynı: green, black, magenta).</summary>
    public static string StoredName(this StreamBackground background) => background.ToString().ToLowerInvariant();

    /// <summary>Kayıtlı değer okunamazsa yeşil (chroma key'in en yaygın rengi).</summary>
    public static StreamBackground FromStored(string? stored) =>
        Enum.TryParse<StreamBackground>(stored, ignoreCase: true, out var value) && Enum.IsDefined(value) ? value : StreamBackground.Green;

    /// <summary>Düz zeminde yarı saydam altyazı kutusu zeminle karışır ve chroma key'i bozar: kutu ya tam koyu ya hiç yoktur.</summary>
    public static double BoxOpacity(int backgroundPercent) => backgroundPercent > 0 ? 1 : 0;
}

/// <summary>
/// Altyazının gösterileceği yer (Mac'teki SubtitleOutput ile aynı). <see cref="Obs"/>: yalnız OBS katmanı (<c>/obs</c>, yayın);
/// TV aranmaz ve açılmaz, bilgisayar ekranında altyazı penceresi açılmaz. OBS katmanı her seçimde altyazıyı alır.
/// </summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<SubtitleOutput>))]
public enum SubtitleOutput { Tv, Computer, Both, Obs }

public static class SubtitleOutputs
{
    public static bool ShowsOnTv(this SubtitleOutput output) => output is SubtitleOutput.Tv or SubtitleOutput.Both;
    public static bool ShowsOnComputer(this SubtitleOutput output) => output is SubtitleOutput.Computer or SubtitleOutput.Both;
    /// <summary>Altyazının gideceği bir yer var mı: TV seçiliyse TV eşleşmiş olmalı; bilgisayar ekranı ve OBS TV istemez.</summary>
    public static bool HasDestination(this SubtitleOutput output, bool hasTv) => output.ShowsOnComputer() || output == SubtitleOutput.Obs || hasTv;
}

/// <summary>Uygulama pencerelerinin görünümü (Mac'teki AppAppearance ile aynı). Onaylı tasarım koyudur; varsayılan da odur.</summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<AppAppearance>))]
public enum AppAppearance { Dark, Light, System }

/// <summary>Bilgisayar ekranındaki altyazı penceresinin yeri ve genişliği (WPF birimiyle; tüm ekranları kapsayan düzlemde).</summary>
public sealed record OverlayBounds(double Left, double Top, double Width)
{
    /// <summary>Yüksekliğin yazı boyundan hesaplanan yüksekliğe oranı ("Altyazıyı konumlandır"da üst ya da alt kenardan
    /// değişir; yazı boyu değişince pencere aynı oranda kalır). Eski kayıtlarda 1.</summary>
    public double HeightScale { get; init; } = 1;
    /// <summary>Pencerenin kaydedildiği ekranın aygıt adı (ör. <c>\\.\DISPLAY2</c>); eski kayıtlarda null.</summary>
    public string? Screen { get; init; }
    /// <summary>O ekranın sol üst köşesine göre yer: ekranların dizilişi değişse de pencere aynı ekranda açılır.</summary>
    public double? ScreenLeft { get; init; }
    public double? ScreenTop { get; init; }
}

/// <summary>Bağlı bir ekran: aygıt adı ve tüm ekranları kapsayan düzlemdeki alanı (WPF birimiyle).</summary>
public readonly record struct DisplayArea(string Name, ScreenArea Area);

/// <summary>
/// Ayarlardaki çeviri motoru seçimi. Ücretsiz olan cihaz üstü modeldir; bulut motorları kullanıcının kendi anahtarıyla
/// çalışır; yerel model (Ollama, LM Studio) kullanıcının bilgisayarında çalışır, anahtarı isteğe bağlıdır (Mac'teki
/// TranslationEngine ile aynı).
/// </summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<TranslationEngine>))]
public enum TranslationEngine { Free, DeepL, Gemini, OpenAi, Claude, DeepSeek, Local }

/// <summary>Windows'taki ücretsiz OPUS-MT çevirisinin çalışacağı aygıt.</summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<TranslationDevice>))]
public enum TranslationDevice { Cpu, Gpu }

/// <summary>Altyazıyı okuyan yazı tanıma: Windows'unki ya da gelişmiş (PP-OCRv6, model indirilir).</summary>
[System.Text.Json.Serialization.JsonConverter(typeof(System.Text.Json.Serialization.JsonStringEnumConverter<OcrEngine>))]
public enum OcrEngine { Windows, Advanced }

/// <summary>Gelişmiş yazı tanımanın modeli: kurulu mu, indir.</summary>
public interface IOcrModel
{
    bool IsInstalled { get; }
    long DownloadBytes { get; }
    Task DownloadAsync(IProgress<double> progress, CancellationToken cancellationToken);
}

public static class TranslationEngines
{
    public static AiProvider? Provider(this TranslationEngine engine) => engine switch
    {
        TranslationEngine.Gemini => AiProvider.Gemini,
        TranslationEngine.OpenAi => AiProvider.OpenAi,
        TranslationEngine.Claude => AiProvider.Claude,
        TranslationEngine.DeepSeek => AiProvider.DeepSeek,
        TranslationEngine.Local => AiProvider.Local,
        _ => null,
    };

    public static TranslationEngine Engine(this AiProvider provider) => provider switch
    {
        AiProvider.Gemini => TranslationEngine.Gemini,
        AiProvider.OpenAi => TranslationEngine.OpenAi,
        AiProvider.Claude => TranslationEngine.Claude,
        AiProvider.DeepSeek => TranslationEngine.DeepSeek,
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
        if (state == OnlineKeyState.KeychainWriteFailed) return text["The API key could not be saved to this computer's secure storage."];
        if (engine == TranslationEngine.Local) return state.DescribeLocal(server, text);
        var name = engine.DisplayName();
        return state switch
        {
            OnlineKeyState.Valid => text["It works."],
            OnlineKeyState.Invalid => text.Format("%@ did not accept this key. Copy it again from your account page.", name),
            OnlineKeyState.QuotaExceeded => text.Format("Your %@ account has no credit left or has reached its limit.", name),
            OnlineKeyState.ModelRejected => text.Format("%@ did not accept the request. Choose the other model or try again later.", name),
            OnlineKeyState.Busy => text.Format("%@ is busy or did not answer in time. Try again in a moment, or choose the faster model.", name),
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
        TranslationEngine.DeepSeek => StoreKeys.DeepSeekKey,
        TranslationEngine.Local => StoreKeys.LocalAiKey,
        _ => null,
    };
}

/// <summary>
/// Görüntünün nereden okunduğu. <c>Ps5</c>: CouchSubs PS5'e kendisi bağlanır (ikinci hesap). <c>RemotePlayWindow</c>:
/// oyun bu bilgisayardaki PS Remote Play'de ya da chiaki-ng'de oynanır, CouchSubs yalnız o pencereyi okur; PS5'e ikinci
/// oturum açılmadığı için ikinci hesap gerekmez (Mac'teki FrameSource ile aynı). Eski ayar dosyaları PS5 ile açılır.
/// </summary>
public enum FrameSource { Ps5, RemotePlayWindow, CaptureWindow }

/// <summary>
/// Xbox seçiliyken görüntünün nereden okunduğu (#853; Mac'teki XboxFrameSource ile aynı). <c>Xbox</c>: CouchSubs Xbox'a
/// kendisi bağlanır (Microsoft girişi ve seçilmiş Xbox). <c>CaptureWindow</c>: oyun bu bilgisayardaki Xbox uygulamasında,
/// play.xbox.com'da ya da capture card ile OBS'te oynanır; CouchSubs Xbox'a hiç bağlanmaz, yalnız seçilen pencereyi
/// (<see cref="UserSettings.CaptureWindow"/>) okur. Xbox aynı anda tek uzaktan oynatma bağlantısına izin verdiği için
/// CouchSubs bağlanırsa kullanıcının oturumu düşerdi. Eski ayar dosyaları Xbox bağlantısıyla açılır.
/// </summary>
public enum XboxFrameSource { Xbox, CaptureWindow }

/// <summary>
/// Kullanıcının açıkça seçtiği OBS projektörü veya oyun penceresi. PID/handle saklanmaz (yeniden açılışta değişir);
/// hem süreç adı hem pencere başlığı eşleşmelidir. Pencere bulunmazsa başka kaynağa geçilmez.
/// </summary>
public sealed record WindowCaptureTarget(string ProcessName, string Title);

/// <summary>
/// Seçilen pencere OBS'in ve Kaynak projektörü değil (Program/Önizleme projektörü ya da OBS'in ana penceresi): bu
/// görüntüde CouchSubs'ın OBS katmanı (tarayıcı kaynağı) da vardır, kendi altyazısını okur (bkz. <c>OwnSubtitles</c>).
/// Ayarlar Kaynak projektörünü önerir. Kaynak projektörünün başlığı "Projector - Source: &lt;ad&gt;" (Türkçe OBS'te
/// "Projektör - Kaynak: &lt;ad&gt;"), eski OBS'te "Windowed Projector (Source) - &lt;ad&gt;". Mac: CaptureWindows.needsSourceProjectorHint.
/// </summary>
public static class ObsProjector
{
    public static bool NeedsSourceProjectorHint(WindowCaptureTarget? target)
    {
        if (target is null) return false;
        var process = target.ProcessName.ToLowerInvariant();
        if (!(process == "obs" || process.StartsWith("obs ") || process.StartsWith("obs64") || process.StartsWith("obs32")
              || process.Contains("obs studio") || process == "obs-studio")) return false;
        var title = target.Title.ToLowerInvariant();
        return !new[] { "source:", "kaynak:", "(source)", "(kaynak)" }.Any(title.Contains);
    }
}

/// <summary>Pencereden okunurken hangi Remote Play uygulaması: hangisi açıksa, yalnız Sony'ninki ya da yalnız chiaki-ng.</summary>
public enum RemotePlayApp { Automatic, Sony, Chiaki }

/// <summary>Kalıcı ayarlar (şifreli depo değil, sıradan ayar dosyası).</summary>
/// <summary>
/// "Ekran yazılarını otomatik çevir" bir kerelik göçü (Mac/iPhone AutoScreenTextMigration, Android aynı kural):
/// işareti olmayan ayar dosyasında ayar kapatılır ve işaret konur. Ayar açıksa (beta.63 varsayılanı) kullanıcıya bir
/// kez "kapatıldı; Ayarlar › Gelişmiş › Ekran yazıları'ndan açabilirsiniz" bilgisi gösterilir.
/// </summary>
public static class AutoScreenTextMigration
{
    public static (UserSettings Settings, bool Notice) Apply(UserSettings settings) => settings.AutoScreenTextReset
        ? (settings, false)
        : (settings with { AutoScreenText = false, AutoScreenTextReset = true }, settings.AutoScreenText);
}

/// <summary>
/// "Bilinen oyunlarda hazır alanları kullan" bir kerelik göçü (Mac/iPhone migratingScreenTextExtras, Android aynı kural);
/// <see cref="AutoScreenTextMigration"/>'dan sonra uygulanır. Hazır alanlar beta.63–68'de varsayılan açık geliyordu ve
/// otomatik ekran yazısı kapalıyken de GTA 6'da menüyü ve bildirimleri çeviriyordu. İşaret yoksa: otomatik ekran yazısı
/// kapalıysa hazır alanlar kapatılır; kullanıcı onu açmışsa dokunulmaz. Sonra işaret konur. GTA 6 telefonuna artık
/// dokunulmaz (<see cref="GamePhoneMigration"/>): bu göç telefonu da kapatıyordu, telefon hiç okunmuyordu (#1202).
/// </summary>
public static class ScreenTextExtrasMigration
{
    public static UserSettings Apply(UserSettings settings) => settings.ScreenTextExtrasReset ? settings
        : settings.AutoScreenText ? settings with { ScreenTextExtrasReset = true }
        : settings with { GameAreaPresets = false, ScreenTextExtrasReset = true };
}

/// <summary>
/// "GTA 6 telefonunu otomatik çevir" bir kerelik açılışı (Mac/iPhone migratingGamePhone, Android aynı kural);
/// <see cref="ScreenTextExtrasMigration"/>'dan sonra uygulanır. Eski göç otomatik ekran yazısı kapalıyken telefonu da
/// kapatıyordu; GTA 6 oyuncularının telefonu hiç çevrilmiyordu (GitHub #1202, #1197, #1193, #1170). İşaret yoksa telefon
/// açılır, işaret konur; kullanıcı sonra bilerek kapatabilir. Telefon izleyicisi yalnız GTA 6 seçiliyken çalışır.
/// </summary>
public static class GamePhoneMigration
{
    public static UserSettings Apply(UserSettings settings) => settings.GamePhoneReenabled ? settings
        : settings with { TranslatesGamePhone = true, GamePhoneReenabled = true };
}

/// <summary>
/// Eski iki telefon anahtarı ("GTA 6 telefonunu otomatik çevir" ve otomatik ekran yazısında "Telefon" türü) tek
/// "GTA 6 Telefonunu Çevir"de birleşir (Mac/iPhone mergingGamePhoneSwitches, Android aynı kural). İkisi farklıysa telefonun o
/// an gerçekten okunup okunmadığı (<see cref="UserSettings.ReadsGamePhone"/>) ikisine de yazılır; kullanıcının açık seçimi
/// korunur. Her açılışta güvenle uygulanır; kayıt anahtarları değişmez.
/// </summary>
public static class GamePhoneSwitchMerge
{
    public static UserSettings Apply(UserSettings settings) => settings.AutoReadGamePhone == settings.ScreenTextPhone ? settings
        : settings with { TranslatesGamePhone = settings.ReadsGamePhone };
}

/// <summary>"oturum başladı" günlük satırının ekran yazısı kısmı (Mac/iPhone SubtitleLog.areaSummary'nin sonu).</summary>
public static class SessionSummary
{
    public static string ScreenText(UserSettings settings) =>
        $"otomatik ekran yazısı: {(settings.AutoScreenText ? "açık" : "kapalı")}, telefon: {(settings.ReadsGamePhone ? "açık" : "kapalı")}";
}

public sealed record UserSettings
{
    public CropRegion Region { get; init; } = new();
    private readonly AreaPreset? areaPreset;
    /// <summary>
    /// Altyazı bölgesinin hazır seçimi (alt, üst, tam ekran ya da özel). Eski ayar dosyalarında yoktur; o zaman
    /// <see cref="Region"/>'dan çıkarılır.
    /// </summary>
    public AreaPreset AreaPreset { get => areaPreset ?? AreaPresets.Matching(Region); init => areaPreset = value; }
    /// <summary>
    /// "Ortada tut": altyazı alanının çerçevesi kenarından boyutlandırılırken karşı kenar da aynı kadar oynar, alan ortalı
    /// kalır (oyunların çoğu altyazıyı ortalar). Kapalıysa yalnız tutulan kenar oynar (sola yaslı ya da köşedeki altyazı).
    /// Eski ayar dosyalarında yoktur; açık başlar. Mac/iPhone: keepAreaCentered, Android: keepAreaCentered.
    /// </summary>
    public bool KeepAreaCentered { get; init; } = true;
    /// <summary>
    /// Ek alanlar (en çok <see cref="ExtraArea.MaxCount"/>; görev paneli, telefon mesajı, bildirim). Sıra kısayolu
    /// belirler: 1. alan "1. alanı çevir" (Num 1), 2. alan Num 2 … Mac, iPhone ve Android'deki extraAreas ile aynı model.
    /// Eski ayar dosyalarındaki üç sabit yuva (ExtraRegion1-3, ExtraLive1-3, ExtraTarget1-3) açılışta bu listeye
    /// dönüştürülür (bkz. <see cref="ExtraAreaMigration"/>).
    /// </summary>
    public IReadOnlyList<ExtraArea> ExtraAreas { get; init => field = ExtraArea.Sanitize(value); } = [];
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
    /// <summary>Eski ayar dosyalarında bulunmaz; varsayılan CPU'dur. GPU yalnız NVIDIA CUDA içindir.</summary>
    public TranslationDevice TranslationDevice { get; init; } = TranslationDevice.Cpu;
    /// <summary>Windows CTranslate2 CPU iç işlemlerinin iş parçacığı sayısı; eski ayarlarda 2.</summary>
    public int CpuTranslationThreads { get; init; } = CpuThreadOptions.Default;
    /// <summary>Değişmeyen altyazı bölgesinde tam OCR okumasını en fazla iki kare yeniden kullan.</summary>
    public bool FastSubtitleDetection { get; init; }
    /// <summary>
    /// GTA 6'da ekrandaki telefon açılınca yazılarını otomatik çevirir. Varsayılan açık (yalnız GTA 6 seçiliyken çalışır;
    /// kapalı gelince telefon hiç çevrilmiyordu, #1202).
    /// </summary>
    public bool AutoReadGamePhone { get; init; } = true;
    /// <summary>
    /// "GTA 6 Telefon Mesajları": açıkken (Yanda Panel, varsayılan) telefonun mesajları telefonun yanındaki sohbet panelinde
    /// (karşı taraf solda, oyuncu sağda), kapalıyken (Balonların Üstünde) her mesajın çevirisi kendi balonunun üstünde
    /// gösterilir. Otomatik telefon okuması ve "Ekranı çevir" aynı ayarı kullanır. Eski PhoneChatCard kaydı (varsayılanı
    /// kapalıydı) okunmaz; herkes panelle başlar (Mac: phoneMessagesPanel).
    /// </summary>
    public bool PhoneMessagesPanel { get; init; } = true;
    /// <summary>Eski adı (<see cref="PhoneMessagesPanel"/>); kayda yazılmaz, kayıttan okunmaz.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool PhoneChatCard { get => PhoneMessagesPanel; init => PhoneMessagesPanel = value; }
    /// <summary>
    /// Ekran yazıları kendiliğinden bulunup yerinde çevrilir (görev, yardım, mesaj; bütün oyunlarda, bkz.
    /// <see cref="ScreenTextDetector"/>). Altyazı alanı Tam ekranken çalışmaz. Varsayılan kapalı (beta.63'te açık
    /// geliyordu; oyun dünyasındaki poster ve plakaları da çeviriyordu). Kullanıcı Ayarlar'dan açar.
    /// </summary>
    public bool AutoScreenText { get; init; }
    /// <summary>
    /// Bir kerelik göç yapıldı: beta.63'te varsayılan açık gelen <see cref="AutoScreenText"/> kapatıldı. Eski dosyalarda
    /// yoktur (false); açılışta ayar kapatılır, bu işaret konur (<see cref="AutoScreenTextMigration"/>).
    /// </summary>
    public bool AutoScreenTextReset { get; init; }
    /// <summary>
    /// Hazır alanlar ve GTA 6 telefonu bir kerelik göçü yapıldı (<see cref="ScreenTextExtrasMigration"/>). Eski dosyalarda
    /// yoktur (false).
    /// </summary>
    public bool ScreenTextExtrasReset { get; init; }
    /// <summary>GTA 6 telefonu bir kerelik açıldı (<see cref="GamePhoneMigration"/>). Eski dosyalarda yoktur (false).</summary>
    public bool GamePhoneReenabled { get; init; }
    /// <summary>
    /// Otomatik ekran yazısında hangi türler çevrilir (bkz. <see cref="ScreenTextKind"/>); yalnız <see cref="AutoScreenText"/>
    /// açıkken geçerli. Eski ayar dosyalarında yoktur; varsayılanla gelir: telefon, görev, yardım/eylemler açık; menüler ve
    /// diğerleri kapalı (kullanıcı isteği: "menülerde olmasını istemiyorum").
    /// </summary>
    public bool ScreenTextPhone { get; init; } = true;
    public bool ScreenTextMission { get; init; } = true;
    public bool ScreenTextHelp { get; init; } = true;
    public bool ScreenTextMenus { get; init; }
    public bool ScreenTextOther { get; init; }

    /// <summary>
    /// Bu tür ekran yazısı çevrilir mi. "Ekran yazılarını otomatik çevir" kapalıyken türler uygulanmaz (hazır alanlar ve
    /// telefon kendi ayarlarıyla eskisi gibi çalışır).
    /// </summary>
    public bool ScreenTextAllows(ScreenTextKind kind) => !AutoScreenText || kind switch
    {
        ScreenTextKind.Phone => ScreenTextPhone,
        ScreenTextKind.Mission => ScreenTextMission,
        ScreenTextKind.Help => ScreenTextHelp,
        ScreenTextKind.Menu => ScreenTextMenus,
        _ => ScreenTextOther,
    };

    /// <summary>
    /// GTA 6 telefonu okunur mu: kendi ayarı ("GTA 6 telefonunu otomatik çevir") ya da otomatik ekran yazısında Telefon
    /// türü açık.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool ReadsGamePhone => AutoReadGamePhone || (AutoScreenText && ScreenTextPhone);
    /// <summary>
    /// Ayarlardaki tek "GTA 6 Telefonunu Çevir" anahtarı (dört platformda aynı): iki eski alan birlikte yazılır, kayıt
    /// anahtarları değişmez. Okunan değer <see cref="ReadsGamePhone"/>'dur (iki alan eşitken onların değeri).
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool TranslatesGamePhone
    {
        get => ReadsGamePhone;
        init
        {
            AutoReadGamePhone = value;
            ScreenTextPhone = value;
        }
    }
    /// <summary>
    /// "Ekran yazılarını altyazıdan ayır": ek alan ve otomatik ekran yazısı kutuları özgün rengini ve zeminini korur,
    /// altyazı kutusuna benzemez (zemin yoksa zeminsiz, koyu gölgeli). Eski ayar dosyalarında yoktur; açık başlar.
    /// </summary>
    public bool SetTextApart { get; init; } = true;
    /// <summary>
    /// Bilinen oyunlarda hazır ek alanlar (<see cref="Core.GameAreaPresets"/>; ör. GTA 6'nın yardım kutusu ve mesajları)
    /// kendiliğinden okunur. Kullanıcının kendi ek alanı varsa onunki kullanılır. Varsayılan kapalı (beta.63–68'de açık
    /// geliyordu: otomatik ekran yazısı kapalıyken de GTA 6'da menüyü ve bildirimleri çeviriyordu); kullanıcı açmadıkça
    /// altyazı alanı dışında hiçbir şey çevrilmez.
    /// </summary>
    public bool GameAreaPresets { get; init; }
    /// <summary>Altyazı okuyucusu. Gelişmiş seçili ama modeli inmemişse Windows'unki kullanılır.</summary>
    public OcrEngine OcrEngine { get; init; } = OcrEngine.Windows;
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
    /// <summary>Explicit opt-in: bypass the free-tier client-side Gemini RPM for a billed key.</summary>
    public bool GeminiPaidTier { get; init; }
    public string OpenAiModel { get; init; } = AiProvider.OpenAi.DefaultModel().Id;
    public string ClaudeModel { get; init; } = AiProvider.Claude.DefaultModel().Id;
    public string DeepSeekModel { get; init; } = AiProvider.DeepSeek.DefaultModel().Id;
    /// <summary>
    /// Yerel model sunucusunun adresi (Ollama: http://127.0.0.1:11434/v1, LM Studio: http://localhost:1234/v1) ve
    /// kullanıcının yazdığı model adı.
    /// </summary>
    public string LocalAiBaseUrl { get; init; } = LocalAiServer.OllamaUrl;
    public string LocalAiModel { get; init; } = LocalAiServer.DefaultModel;
    /// <summary>
    /// Ayarlardaki "Ek talimat" (#306): yapay zekâ çevirmeninin (Gemini, OpenAI, Claude, yerel model) sistem talimatının
    /// sonuna eklenir; boşsa hiçbir şey değişmez. Eski ayar dosyalarında yoktur, boş açılır.
    /// </summary>
    public string AiInstruction { get; init; } = "";
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
    /// <summary>Oynanan oyun paketle tanınmazsa çeviri başladıktan iki dakika sonra bir kez sorulur (bkz. <see cref="GameSense"/>).</summary>
    public bool AskGame { get; init; } = true;
    /// <summary>Kullanım verisi: telefonlardaki gibi kimliğe bağlanmayan kullanım istatistikleri gönderilir (bkz. <see cref="UsageStats"/>).</summary>
    public bool UsageData { get; init; } = UsageStats.EnabledByDefault;
    /// <summary>Kullanım verisi bilgi notu gösterildi (ilk açılışta bir kez). Eski ayar dosyalarında yoktur (false).</summary>
    public bool UsageNoticeSeen { get; init; }
    /// <summary>Altyazıdaki konuşan adı ("ARTHUR: …") çeviride gösterilir; kapalıysa yalnız Türkçe cümle görünür.</summary>
    public bool ShowSpeakerNames { get; init; } = true;
    /// <summary>
    /// Konuşan adını renklendir: "Mattia: …" satırında yalnız ad o konuşana özgü renkte, cümle yazı renginde (TV, bilgisayar ekranındaki
    /// pencere ve yayın penceresi; bkz. <see cref="Core.SpeakerColors"/>). Eski ayar dosyalarında yoktur; açık başlar.
    /// </summary>
    public bool SpeakerColors { get; init; } = true;
    /// <summary>Koyu, açık ya da sistemle aynı. Eski ayar dosyalarında yoktur; onlar da koyu açılır.</summary>
    public AppAppearance Appearance { get; init; } = AppAppearance.Dark;
    /// <summary>Ayarlar › Temel › Açılış Sesi: ilk kurulumun açılış adımındaki marka sesi (design/yeni-arayuz/METINLER.md). Eski ayar dosyalarında yoktur; açık.</summary>
    public bool StartupSound { get; init; } = true;
    /// <summary>Ayarlar › Temel › Geçiş Animasyonları: kapalıyken yeni arayüzde yalnız kısa solma. Eski ayar dosyalarında yoktur; açık.</summary>
    public bool TransitionAnimations { get; init; } = true;
    /// <summary>Görüntü PS5 bağlantısından mı, bu bilgisayardaki Remote Play penceresinden mi okunur.</summary>
    public FrameSource FrameSource { get; init; } = FrameSource.Ps5;
    /// <summary>Xbox seçiliyken görüntü Xbox bağlantısından mı, seçilen pencereden mi okunur (bkz. <see cref="Shell.XboxFrameSource"/>).</summary>
    public XboxFrameSource XboxFrameSource { get; init; } = XboxFrameSource.Xbox;
    /// <summary>Xbox karelerini #244 öncesindeki 200 ms aralıkla al; varsayılan 66 ms.</summary>
    public bool XboxLegacyFrameRate { get; init; }
    /// <summary>Xbox Remote Play oyun sesini bu bilgisayarda çal; eski ayarlarda açıktır.</summary>
    public bool XboxAudioOnComputer { get; init; } = true;
    /// <summary>OBS veya başka bir açık pencere seçildiyse yalnız bu pencere yakalanır (varsayılan null).</summary>
    public WindowCaptureTarget? CaptureWindow { get; init; }
    /// <summary>Pencereden okunurken hangi Remote Play uygulaması (bkz. <see cref="Shell.RemotePlayApp"/>).</summary>
    public RemotePlayApp RemotePlayApp { get; init; } = RemotePlayApp.Automatic;
    /// <summary>
    /// Kullanıcının değiştirdiği kısayollar (yalnız varsayılandan farklı olanlar; bkz. <see cref="HotkeyTable.Assign"/>).
    /// Eski ayar dosyalarında yoktur; o zaman bütün kısayollar varsayılandır.
    /// </summary>
    public IReadOnlyList<HotkeyChoice> Hotkeys { get; init; } = [];

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
        AiProvider.Claude => ClaudeModel,
        AiProvider.DeepSeek => DeepSeekModel,
        _ => LocalAiModel,
    };

    public UserSettings WithModel(AiProvider provider, string id) => provider switch
    {
        AiProvider.Gemini => this with { GeminiModel = id },
        AiProvider.OpenAi => this with { OpenAiModel = id },
        AiProvider.Claude => this with { ClaudeModel = id },
        AiProvider.DeepSeek => this with { DeepSeekModel = id },
        _ => this with { LocalAiModel = id },
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

    /// <summary>Kısayolun okuduğu ek alan: 1, 2 ya da 3. sıradaki; yoksa null.</summary>
    public ExtraArea? ExtraAreaAt(int number) => number >= 1 && number <= ExtraAreas.Count ? ExtraAreas[number - 1] : null;

    /// <summary>Ek alan eklenebilir mi (Mac: canAddExtraArea).</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool CanAddExtraArea => ExtraAreas.Count < ExtraArea.MaxCount;

    /// <summary>Yeni ek alan sona eklenir; sınır dolduysa ayar değişmez (Mac: addExtraArea).</summary>
    public UserSettings WithAddedExtraArea(ExtraArea area) =>
        CanAddExtraArea ? this with { ExtraAreas = [.. ExtraAreas, area] } : this;

    /// <summary>Kimliği verilen ek alan değişir; yoksa ayar değişmez (Mac: updateExtraArea).</summary>
    public UserSettings WithExtraArea(string id, Func<ExtraArea, ExtraArea> change) =>
        ExtraAreas.Any(area => area.Id == id)
            ? this with { ExtraAreas = [.. ExtraAreas.Select(area => area.Id == id ? change(area) with { Id = id } : area)] }
            : this;

    /// <summary>Ek alan silinir; arkasındakiler bir sıra öne gelir (Mac: removeExtraArea).</summary>
    public UserSettings WithoutExtraArea(string id) => this with { ExtraAreas = [.. ExtraAreas.Where(area => area.Id != id)] };

    /// <summary>
    /// Altyazı alanı Tam ekran: sürekli okunan ek bölgeler okunmaz (ekranın tamamı zaten okunuyor, aynı yazı ikinci kez
    /// çevrilirdi). Bölgelerin ayarı değişmez; başka bir alan seçilince eskisi gibi okunurlar. Tuşla tek seferlik okuma
    /// etkilenmez.
    /// </summary>
    public bool ExtraAreasPausedByFullScreen => AreaPreset == AreaPreset.Full;

    /// <summary>Sürekli okunan ek bölgeler (açık ve "Sürekli oku" seçili olanlar); Tam ekranda hiçbiri (Mac: activeExtraAreas).</summary>
    public IReadOnlyList<WatchedArea> WatchedAreas() => ExtraAreasPausedByFullScreen ? [] :
        [.. ExtraAreas.Select((area, index) => (area, index))
            .Where(item => item.area.Enabled)
            .Select(item => new WatchedArea(item.area.Id, item.area.DisplayName(item.index + 1), item.area.Region))];

    /// <summary>
    /// Oynanan oyunun hazır ek alanları (çalışma anında; ayarlara yazılmaz): ayar açık, altyazı alanı Tam ekran değil,
    /// kullanıcının sürekli okunan kendi ek alanı ve etkin alan profili yok. GTA 6 telefonu açıkken mesaj alanı çıkar.
    /// </summary>
    public IReadOnlyList<WatchedArea> PresetAreas(string? game, bool phoneOpen) =>
        !GameAreaPresets || ExtraAreasPausedByFullScreen || ActiveAreaProfile is not null || WatchedAreas().Count > 0 ? []
            : [.. Core.GameAreaPresets.Areas(game).Where(area => !phoneOpen || area.Id != Core.GameAreaPresets.PhoneId)];

    /// <summary>
    /// Oyuna göre kaydedilmiş alanlar (son kullanılan sonda, en çok <see cref="Core.AreaProfiles.MaxCount"/>). Eski ayar
    /// dosyalarında yoktur: profil kaydedilmedikçe davranış değişmez.
    /// </summary>
    public IReadOnlyList<AreaProfile> AreaProfiles { get; init; } = [];
    /// <summary>Şu an uygulanan profilin anahtarı; genel alanlar kullanılıyorsa null.</summary>
    public string? ActiveAreaProfile { get; init; }
    /// <summary>
    /// Profil uygulanırken kenara alınan genel alanlar; profil bırakılınca (oyun değişti, "Geri al", oturum bitti) geri
    /// gelir. Uygulama oturum sürerken kapanırsa açılışta geri yüklenir.
    /// </summary>
    public AreaSet? GeneralAreas { get; init; }

    /// <summary>Alanların ölçüldüğü görüntü: PS5/Xbox akışı ya da yakalanan pencere.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public AreaSource AreaSource => FrameSource == FrameSource.Ps5 ? AreaSource.Stream : AreaSource.Window;

    /// <summary>Şu an okunan alanlar (altyazı alanı ve ek alanlar).</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public AreaSet Areas => new(Region, AreaPreset, ExtraAreas);

    /// <summary>Okunan alanlar <paramref name="areas"/> olur; diğer ayarlara dokunulmaz.</summary>
    public UserSettings WithAreas(AreaSet areas) => this with
    {
        Region = areas.Region, AreaPreset = areas.AreaPreset, ExtraAreas = areas.ExtraAreas,
    };

    public AreaProfile? FindAreaProfile(string? key) => key is null ? null : AreaProfiles.FirstOrDefault(profile => profile.Key == key);

    /// <summary>Profil uygulanır: genel alanlar (henüz kenarda değilse) saklanır, okunan alanlar profilinki olur.</summary>
    public UserSettings WithAreaProfile(AreaProfile profile) => WithAreas(profile.Areas) with
    {
        GeneralAreas = GeneralAreas ?? Areas,
        ActiveAreaProfile = profile.Key,
        AreaProfiles = Core.AreaProfiles.Saved(AreaProfiles, profile, item => item.Key),
    };

    /// <summary>Profil bırakılır, genel alanlar geri gelir (profilde kaydedilmemiş değişiklikler bırakılır).</summary>
    public UserSettings WithGeneralAreas() => (GeneralAreas is { } general ? WithAreas(general) : this) with
    {
        GeneralAreas = null,
        ActiveAreaProfile = null,
    };

    /// <summary>
    /// Okunan alanlar <paramref name="game"/> için kaydedilir ve o profil etkin olur. Genel alanlar bu andaki alanlar
    /// olarak kenara alınır (profil yokken yapılan değişiklik zaten genel ayardı).
    /// </summary>
    public UserSettings WithSavedAreaProfile(string game)
    {
        if (Core.AreaProfiles.Key(game, AreaSource) is not { } key) return this;
        var profile = new AreaProfile(key, game, Areas);
        return this with
        {
            AreaProfiles = Core.AreaProfiles.Saved(AreaProfiles, profile, item => item.Key),
            ActiveAreaProfile = key,
            GeneralAreas = GeneralAreas ?? Areas,
        };
    }

    /// <summary>
    /// Okunan alanlar adı yazılan oyunun yeni profili olur ve etkinleşir (listede olmayan oyun da). O adın profili varsa
    /// değişmez (<see cref="Core.AreaProfiles.Edit.Exists"/>): başka oyunun alanlarının üzerine yazılmaz.
    /// </summary>
    public (UserSettings Settings, Core.AreaProfiles.Edit Edit) WithNewAreaProfile(string game)
    {
        var name = game.Trim();
        if (Core.AreaProfiles.Key(name, AreaSource) is not { } key) return (this, Core.AreaProfiles.Edit.Empty);
        if (FindAreaProfile(key) is not null) return (this, Core.AreaProfiles.Edit.Exists);
        return (WithSavedAreaProfile(name), Core.AreaProfiles.Edit.Done);
    }

    /// <summary>Profilin adı değişir (aynı kaynakta); etkinse etkin kalır. Yeni ad başka bir profilinse değişmez.</summary>
    public (UserSettings Settings, Core.AreaProfiles.Edit Edit) WithRenamedAreaProfile(string key, string game)
    {
        var name = game.Trim();
        var index = AreaProfiles.ToList().FindIndex(profile => profile.Key == key);
        if (index < 0) return (this, Core.AreaProfiles.Edit.Missing);
        if (Core.AreaProfiles.Key(name, Core.AreaProfiles.SourceOfKey(key)) is not { } next) return (this, Core.AreaProfiles.Edit.Empty);
        if (next != key && FindAreaProfile(next) is not null) return (this, Core.AreaProfiles.Edit.Exists);
        var list = AreaProfiles.ToList();
        list[index] = list[index] with { Key = next, Game = name };
        return (this with { AreaProfiles = list, ActiveAreaProfile = ActiveAreaProfile == key ? next : ActiveAreaProfile },
                Core.AreaProfiles.Edit.Done);
    }

    /// <summary>Profilin alanları başka bir oyun adıyla kopyalanır (aynı kaynakta); etkin profil değişmez.</summary>
    public (UserSettings Settings, Core.AreaProfiles.Edit Edit) WithDuplicatedAreaProfile(string key, string game)
    {
        var name = game.Trim();
        if (FindAreaProfile(key) is not { } profile) return (this, Core.AreaProfiles.Edit.Missing);
        if (Core.AreaProfiles.Key(name, Core.AreaProfiles.SourceOfKey(key)) is not { } next) return (this, Core.AreaProfiles.Edit.Empty);
        if (FindAreaProfile(next) is not null) return (this, Core.AreaProfiles.Edit.Exists);
        var copy = new AreaProfile(next, name, profile.Areas);
        return (this with { AreaProfiles = Core.AreaProfiles.Saved(AreaProfiles, copy, item => item.Key) }, Core.AreaProfiles.Edit.Done);
    }

    /// <summary>Şu anki görüntü kaynağının profilleri, ada göre sıralı (Ayarlar'daki oyun profilleri listesi).</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public IReadOnlyList<AreaProfile> GameProfiles =>
        [.. AreaProfiles.Where(profile => Core.AreaProfiles.SourceOfKey(profile.Key) == AreaSource)
                        .OrderBy(profile => profile.Game, StringComparer.CurrentCultureIgnoreCase)];

    /// <summary>Profil silinir; etkinse genel alanlara dönülür.</summary>
    public UserSettings WithoutAreaProfile(string key)
    {
        var next = ActiveAreaProfile == key ? WithGeneralAreas() : this;
        return next with { AreaProfiles = [.. AreaProfiles.Where(profile => profile.Key != key)] };
    }

    /// <summary>Etkin profil var ve okunan alanlar ondan farklı: "Profile kaydet" gösterilir.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool AreasDifferFromProfile => FindAreaProfile(ActiveAreaProfile) is { } profile && profile.Areas != Areas;
}

/// <summary>Bir oyunun alanları: altyazı alanı ve ek alanlar (Mac/iPhone/Android AreaSet ile aynı).</summary>
public sealed record AreaSet(CropRegion Region, AreaPreset AreaPreset, IReadOnlyList<ExtraArea> ExtraAreas)
{
    public IReadOnlyList<ExtraArea> ExtraAreas { get; init => field = ExtraArea.Sanitize(value); } = ExtraArea.Sanitize(ExtraAreas);

    /// <summary>Ek alanlar sırayla karşılaştırılır (liste başvurusu değil): "Profile kaydet" yalnız gerçek değişiklikte çıkar.</summary>
    public bool Equals(AreaSet? other) =>
        other is not null && Region == other.Region && AreaPreset == other.AreaPreset && ExtraAreas.SequenceEqual(other.ExtraAreas);

    public override int GetHashCode() => HashCode.Combine(Region, AreaPreset, ExtraAreas.Count);
}

/// <summary>
/// Altyazı alanının yanındaki ek alan (görev yazısı, telefon mesajı, bildirim). Mac/iPhone ExtraArea.swift ve Android
/// Areas.kt ile aynı model: adlı liste, en çok <see cref="MaxCount"/>.
/// </summary>
/// <param name="Id">TV'deki kutunun kimliği; değişmez.</param>
/// <param name="Name">Kullanıcının verdiği ad ("Görev"); boşsa "Alan 1" gibi sırasıyla gösterilir.</param>
/// <param name="Enabled">"Bu alanı sürekli oku": çeviri sürerken saniyede bir okunur. Kapalıysa yalnız kısayolla bir kez okunur.</param>
/// <param name="Target">Kısayolla bir kez okununca sonucun gösterildiği yer.</param>
public sealed record ExtraArea(string Id, string Name, CropRegion Region, bool Enabled = true, ResultTarget Target = ResultTarget.Tv)
{
    /// <summary>
    /// En çok 50 ek alan (yeni arayüz, METINLER.md; eskiden 3): her alan saniyede bir okunur. Yalnız ilk
    /// <see cref="ShortcutCount"/> alanın kısayolu vardır (Num 1-3 / Ctrl+Shift+1-3); sonrakiler kısayolsuzdur.
    /// </summary>
    public const int MaxCount = 50;

    /// <summary>Kısayolu olan ilk ek alanların sayısı.</summary>
    public const int ShortcutCount = 3;

    /// <summary>Hazır seçimle yeni alan (yeni kimlik).</summary>
    public static ExtraArea Create(string name, CropRegion region) => new(Guid.NewGuid().ToString(), name, region);

    /// <summary>Ekranda ve günlükte görünen ad: verilen ad, yoksa "Alan 1".</summary>
    public string DisplayName(int number) => string.IsNullOrWhiteSpace(Name) ? Localizer.Current.Format("Area %lld", number) : Name;

    /// <summary>Elle değiştirilmiş ya da bozuk kayıt: eksik kimlik/ad/bölge tamamlanır, yinelenen kimlik ve fazlası atılır.</summary>
    internal static IReadOnlyList<ExtraArea> Sanitize(IReadOnlyList<ExtraArea>? areas)
    {
        if (areas is null) return [];
        var seen = new HashSet<string>();
        var result = new List<ExtraArea>();
        foreach (var area in areas)
        {
            if (area is null || result.Count == MaxCount) continue;
            var fixedArea = area with
            {
                Id = string.IsNullOrEmpty(area.Id) ? Guid.NewGuid().ToString() : area.Id,
                Name = area.Name ?? "",
                Region = area.Region ?? ExtraAreaPreset.Quest.Region(),
            };
            if (seen.Add(fixedArea.Id)) result.Add(fixedArea);
        }
        return result.Count == areas.Count && result.SequenceEqual(areas) ? areas : result;
    }

    public bool Equals(ExtraArea? other) =>
        other is not null && Id == other.Id && Name == other.Name && Region == other.Region && Enabled == other.Enabled && Target == other.Target;

    public override int GetHashCode() => HashCode.Combine(Id, Name, Region, Enabled, Target);
}

/// <summary>Oyuna göre kaydedilmiş alanlar. <see cref="Key"/>: <see cref="Core.AreaProfiles.Key"/>; <see cref="Game"/>: gösterilen ad.</summary>
public sealed record AreaProfile(string Key, string Game, AreaSet Areas);

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
    /// <param name="keepDisplayOn">
    /// Ekran da kapanmasın: görüntü bu bilgisayardaki bir pencereden okunuyor ya da altyazı bu ekranda gösteriliyor.
    /// Ekran kapanınca pencere yakalama kare vermez; kullanıcı TV'de oynadığı için bilgisayar ekranı birkaç dakikada
    /// (Windows ve macOS'ta prizdeyken çoğu zaman 10 dakika) kapanır ve altyazı kesilirdi. Çeviri sürerken yeniden çağrılabilir.
    /// </param>
    void Begin(bool keepDisplayOn);
    void End();
}

/// <summary>TV uygulamasını açık tutan görevli (gerçekte TvKeeper).</summary>
public interface IKeeper
{
    void Start(TimeSpan interval);
    void Stop();
    void Reconnect();
    /// <summary>LG: uygulama kapatıldı (kurulumdan sonra); bağlı görünse de bir kez açılır (TvKeeper.ReopenApp).</summary>
    void ReopenApp() => Reconnect();
}

public enum GameConsoleKind { PlayStation, Xbox }

public sealed record XboxConsole(string Id, string Name, string Model, bool StreamingEnabled);
public sealed record XboxLoginChallenge(string Code, Uri Url, int ExpiresIn);

/// <summary>Windows Xbox home streaming backend. Other platforms can supply their own implementation.</summary>
public interface IXboxService
{
    event Action<string>? TokenUpdated;
    void Clear();
    Task<XboxLoginChallenge> BeginLoginAsync();
    Task<string> CompleteLoginAsync();
    Task<IReadOnlyList<XboxConsole>> DiscoverAsync(string token);
    IStreamSession MakeStream(XboxConsole console, string token, bool legacyFrameRate, bool playAudio);
}

/// <summary>Cihaz üstü çeviri modeli: kurulu mu, indir, çevirmen oluştur.</summary>
public interface ITranslationModel
{
    bool IsSupported(string source, string target);
    bool IsInstalled(string source, string target);
    Task DownloadAsync(string source, string target, IProgress<double> progress, CancellationToken cancellationToken);
    ITextTranslator Create(string source, string target);

    /// <summary>İstenen GPU kullanılamayınca CPU'ya geçildiğinde bildirilir.</summary>
    event Action? GpuFallback { add { } remove { } }

    /// <summary>Yeni çevirmen oluşturulurken kullanılacak aygıt.</summary>
    void SelectDevice(TranslationDevice device) { }
    void SelectCpuThreads(int threads) { }

    /// <summary>Model kurulu ama çeviri motoru bu bilgisayarda açılamadı (ör. CTranslate2 çalışma zamanı eksik).</summary>
    bool EngineFailed => false;

    /// <summary><see cref="EngineFailed"/> true olunca bir kez, herhangi bir iş parçacığından çağrılır.</summary>
    event Action? EngineFailure { add { } remove { } }
}

/// <summary>Dış dünyayla (PS5, PSN, TV, OCR, çeviri) konuşan her şey; testlerde sahtesi kullanılır.</summary>
public interface IAppServices
{
    IXboxService? Xbox => null;
    Task<IReadOnlyList<ConsoleInfo>> DiscoverConsolesAsync();
    Task<byte[]> AccountIdFromRedirectAsync(Uri redirect);
    Task<RegisteredConsole> RegisterAsync(string host, byte[] accountId, uint pin);
    Task<IReadOnlyList<LgTv>> DiscoverTvsAsync();
    /// <summary>TV ile eşleşir ve TV uygulamasını sunucu adresiyle başlatmayı dener.</summary>
    Task<TvPairing> PairTvAsync(LgTv tv, string? key, string server, string accessKey);
    /// <summary>Eşleşme isteği gönderen TV: marka ve ad adresten yoklanır (bkz. <see cref="PairedTv.IdentifyAsync"/>); tanınmazsa null.</summary>
    Task<LgTv?> IdentifyTvAsync(string host) => PairedTv.IdentifyAsync(host);
    /// <param name="loginPasscode">PS5 bu hesap için giriş şifresi isterse gönderilecek 4 hane (Ayarlar'da kayıtlıysa).</param>
    IStreamSession MakeStream(RegisteredConsole console, byte[] accountId, string? loginPasscode);
    /// <summary>Görüntüyü bu bilgisayardaki Remote Play penceresinden (PS Remote Play ya da chiaki-ng) alan kaynak.</summary>
    IStreamSession MakeWindowStream(RemotePlayApp app) => throw new NotSupportedException();
    /// <summary>Açıkça seçilen pencereyi okumak için aynı Windows Graphics Capture hattını kullanır.</summary>
    IStreamSession MakeCaptureWindowStream(WindowCaptureTarget target) => throw new NotSupportedException();
    /// <summary>
    /// Deneme modunun "konsolu": uygulamadaki örnek kareleri akış gibi verir, ağ kullanmaz. Uygulama katmanı kareleri
    /// çizer (WPF); varsayılanı yazısız düz karedir.
    /// </summary>
    IStreamSession MakeDemoStream() => new DemoStream(DemoFrames.Plain);
    /// <summary>Kullanıcının seçebileceği görünür pencereler. PSN veya ekran paylaşım izni gerekmez.</summary>
    IReadOnlyList<WindowCaptureTarget> CaptureWindows() => [];
    /// <summary>Seçilen Remote Play uygulaması (PS Remote Play ya da chiaki-ng) bu bilgisayarda kurulu mu.</summary>
    bool RemotePlayInstalled(RemotePlayApp app) => true;
    /// <param name="appConnected">TV uygulaması bilgisayara bağlı mı (Samsung'da bağlıyken TV'ye dokunulmaz).</param>
    /// <param name="onMoved">TV ağda yeni bir adreste bulununca çağrılır.</param>
    /// <param name="onKey">TV bağlantıda yeni jeton verdi (Samsung); saklanır.</param>
    /// <param name="consolePort">TV uygulamasının gösterdiği HDMI girişi (LG bekçisi PS tuşunu buna göre tanır).</param>
    /// <param name="onOpenResult">Her açma denemesinin sonucu (ana ekrandaki satır): açıldıysa null.</param>
    IKeeper MakeKeeper(LgTv tv, string? key, IReadOnlyDictionary<string, string> parameters, Func<bool> appConnected, Action<LgTv> onMoved,
                       Action<string> onKey, Func<int?>? consolePort = null,
                       Action<TvOpenProblem?>? onOpenResult = null);
    /// <summary>Uygulamayla gelen TV paketinin sürümü (geliştirici derlemesinde paket olmayabilir).</summary>
    string? BundledTvAppVersion { get; }
    /// <summary>TV kurulum günlüğüne (tvinstall.log) bir satır; kurulum başlamadıysa nedeni buraya yazılır.</summary>
    void WriteTvInstallLog(string line) { }
    Task<bool> IsDevModeOnAsync(string host);
    /// <summary>
    /// Kayıtlı TV adresinde bir şey yanıt veriyor mu (TvReach.RespondsAsync: kapılardan biri bağlanır ya da reddeder). Hayırsa
    /// TV ağda yeniden aranır; adresi değişmiş TV'de "geliştirici modu kapalı" ya da "Key Server kapalı" denmez.
    /// </summary>
    Task<bool> TvRespondsAsync(string host, TvBrand brand) => Task.FromResult(true);
    Task<string> FetchDevKeyAsync(string host, string passphrase);
    /// <summary>TV'deki sürüm; TV'de CouchSubs'ın kimliğiyle başka bir uygulama varsa DevModeError.ForeignApp fırlatır.</summary>
    Task<string?> InstalledTvAppVersionAsync(string host, string devKey);
    Task InstallTvAppAsync(string host, string devKey);
    /// <summary>
    /// <paramref name="replaceForeign"/>: kullanıcı "Kaldırıp Kur" dedi; TV'de CouchSubs'ın kimliğini kullanan başka uygulama
    /// önce kaldırılır. Üç markada da (bu ve aşağıdaki iki yük) onay yoksa hiçbir şey silinmez, ForeignApp fırlatılır.
    /// </summary>
    Task InstallTvAppAsync(string host, string devKey, bool replaceForeign) => InstallTvAppAsync(host, devKey);
    /// <summary>LG: TV'de açık CouchSubs'ı kapatır (eski sürümde çalışıyorsa; kurulum bunu kendisi de yapar).</summary>
    Task CloseTvAppAsync(string host, string devKey) => Task.CompletedTask;
    /// <summary>LG geliştirici modunun süresini baştan başlatır; kalan saati döner (bilinmiyorsa null).</summary>
    Task<int?> RenewDevSessionAsync(string host, string devKey);
    /// <summary>Samsung ve Android TV için uygulamayla gelen paket (geliştirici derlemesinde olmayabilir).</summary>
    BundledTvApp? BundledApp(TvBrand brand);
    Task<bool> IsSamsungDevModeOnAsync(string host);
    /// <summary>
    /// Kurulumdan önce TV'nin geliştirici modu bilgisi (8001) ve TV'ye giden yolun bu bilgisayardaki adresi. TV yanıt
    /// vermezse Info null olur; kurulum yine denenir.
    /// </summary>
    Task<SamsungPreflight> CheckSamsungAsync(string host) => Task.FromResult(new SamsungPreflight(null, null));
    /// <summary>
    /// Eksikse ya da eskiyse imzalayıp kurar; TV'deki sürümü ve kurup kurmadığını döner. <paramref name="openIfInstalled"/>:
    /// uygulama güncelse de TV'de açılır ("TV uygulamasını yeniden kur").
    /// </summary>
    Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent);
    /// <summary><paramref name="replaceForeign"/>: bkz. <see cref="InstallTvAppAsync(string, string, bool)"/>.</summary>
    Task<(string Version, bool Installed)> InstallSamsungAppAsync(string host, BundledTvApp app, bool openIfInstalled, bool replaceForeign,
        Action<TvInstallEvent> onEvent) => InstallSamsungAppAsync(host, app, openIfInstalled, onEvent);
    Task<bool> IsAndroidDebugOnAsync(string host);
    /// <summary>Ağda ADB'si açık cihazlar.</summary>
    Task<IReadOnlyList<string>> ScanAndroidTvsAsync();
    /// <summary>
    /// Eksikse ya da eskiyse kurar; TV'deki sürümü döner. <paramref name="openIfInstalled"/>: uygulama güncelse de TV'de
    /// açılır ("TV uygulamasını yeniden kur").
    /// </summary>
    Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, Action<TvInstallEvent> onEvent);
    /// <summary>
    /// <see cref="InstallAndroidAppAsync(string, BundledTvApp, bool, Action{TvInstallEvent})"/>; uygulama açılırken
    /// <paramref name="launchParams"/> (JSON, ör. altyazı sunucusunun adresi) TV uygulamasına verilir. Altyazı sunucusu 8787
    /// dışındaki bir portta olsa da TV uygulaması onu bulur (#617). Desteklemeyen derlemede parametresiz açılır.
    /// </summary>
    Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, string? launchParams,
                                        Action<TvInstallEvent> onEvent) => InstallAndroidAppAsync(host, app, openIfInstalled, onEvent);
    /// <summary><paramref name="replaceForeign"/>: bkz. <see cref="InstallTvAppAsync(string, string, bool)"/>.</summary>
    Task<string> InstallAndroidAppAsync(string host, BundledTvApp app, bool openIfInstalled, string? launchParams, bool replaceForeign,
                                        Action<TvInstallEvent> onEvent) => InstallAndroidAppAsync(host, app, openIfInstalled, launchParams, onEvent);
    /// <summary>
    /// Altyazı sunucusunun dinleyeceği port; null ise 8787 (doluysa boş bir port). Linux sunucusunda
    /// COUCHSUBS_SERVER_PORT ile seçilir (#617).
    /// </summary>
    int? PreferredServerPort => null;
    /// <summary>Oyun dili için yazı tanıyıcı; bilgisayarda hiç OCR dili yoksa null.</summary>
    ITextReader? MakeReader(string language);
    /// <summary>
    /// Altyazı okuyucusu: <paramref name="engine"/> gelişmişse ve modeli kuruluysa PP-OCRv6, değilse
    /// <see cref="MakeReader(string)"/>.
    /// </summary>
    ITextReader? MakeReader(string language, OcrEngine engine) => MakeReader(language);
    /// <summary>Gelişmiş yazı tanımanın modeli; bu derlemede yoksa null.</summary>
    IOcrModel? AdvancedOcr => null;
    /// <summary>
    /// Oyun dilinin kendi yazı tanıma paketi yüklü mü. Değilse okuyucu sistemin diliyle (ör. Türkçe) okur ve İngilizce
    /// altyazı "thıs.messs" gibi bozulur; kullanıcıya paketi yüklemesi söylenir.
    /// </summary>
    bool HasOcrLanguage(string language) => true;
    ITranslationModel Translation { get; }
    /// <summary>DeepL çevirmeni; <paramref name="fallback"/> DeepL'e ulaşılamayan satırları çevirir. Bu derlemede yoksa null.</summary>
    ITextTranslator? MakeOnlineTranslator(string key, ITextTranslator? fallback) => null;
    Task<OnlineKeyCheck> CheckOnlineKeyAsync(string key) => Task.FromResult(new OnlineKeyCheck(OnlineKeyState.Unreachable));
    /// <summary>
    /// Yapay zekâ çevirmeni; <paramref name="fallback"/> hizmete ulaşılamayan satırları çevirir, <paramref name="game"/>
    /// oynanan oyunun adını verir (istem ve önbellek anahtarı; bilinmiyorsa null). Bu derlemede yoksa null.
    /// </summary>
    /// <paramref name="instruction"/>: Ayarlardaki "Ek talimat"; boşsa sistem talimatı değişmez.
    ITextTranslator? MakeAiTranslator(AiProvider provider, string key, string model, ITextTranslator? fallback, Func<string?>? game,
                                      string? instruction = null, bool paidTier = false) => null;
    /// <summary>Yapay zekâ anahtarını örnek bir satırı çevirerek dener.</summary>
    Task<AiTestResult> TestAiKeyAsync(AiProvider provider, string key, string model) => Task.FromResult(new AiTestResult(OnlineKeyState.Unreachable));
    /// <summary>Yerel model (Ollama, LM Studio) çevirmeni; anahtar boş olabilir. Bu derlemede yoksa null.</summary>
    ITextTranslator? MakeLocalAiTranslator(LocalAiServer server, string key, ITextTranslator? fallback, Func<string?>? game,
                                           string? instruction = null) => null;
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
    /// <summary>Çok satırlı okumanın yalnız bir satırı pakette yoksa satır satır sonuç (CouchSubs.Translation.PackLookup.MatchPartial).</summary>
    PackPartial? FindPartialInPacks(string text) => null;
    /// <summary>Ortak havuz; testlerde null (hiçbir şey gönderilmez).</summary>
    LinePool? Pool => null;
    /// <summary>Kullanım verisi (GA4 Measurement Protocol); derlemede kimlik yoksa ve testlerde null (hiçbir şey gönderilmez).</summary>
    UsageStats? Usage => null;
    /// <summary>PS5'te o an çalışan oyun (kayıtlı PS5'e keşif sorusu; adresi değiştiyse ağda kimliğiyle aranır ve kayıt
    /// <see cref="ConsoleFinder.Changed"/> ile güncellenir); bilinmiyorsa ve testlerde null.</summary>
    Task<RunningGame?> RunningGameAsync(ConsoleFinder finder) => Task.FromResult<RunningGame?>(null);
    /// <summary>Paket sunucusundan yeni paketler; adres yapılandırılmadıysa ve testlerde null.</summary>
    PackUpdater? PackUpdates => null;
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
/// <summary><c>PressInstallOnTv</c>: Android TV'de Google Play sayfası açıldı, kullanıcı TV'de Yükle'ye basmalı.
/// <c>ChooseAndroidTv</c>: ağda hata ayıklaması açık birden çok Android TV var; kurulumun gideceği TV kullanıcıya sorulur (#425).</summary>
public enum TvAppKind { Unknown, Working, UpToDate, DevModeOff, NeedsPassphrase, Failed, SignIn, ApproveOnTv, PressInstallOnTv, ChooseAndroidTv }

/// <summary>TV uygulamasının kurulum durumu.</summary>
/// <param name="HostPcIp">HostPcMismatch'te TV'deki "Host PC IP".</param>
/// <param name="ComputerAddress">HostPcMismatch'te TV'nin göreceği bu bilgisayar adresi.</param>
/// <param name="Hosts">ChooseAndroidTv'de bulunan TV'lerin adresleri.</param>
/// <summary>TV'ye bağlı uygulama bu cihazdaki TV paketinden eski (#884, #891).</summary>
public sealed record TvAppOutdated(string Installed, string Bundled)
{
    /// <summary>0.9.69'den eski TV uygulamaları sürüm bildirmez; ekranda böyle görünür.</summary>
    public const string Unreported = "< 0.9.69";
}

public sealed record TvAppState(TvAppKind Kind, string? Version = null, DevModeError? Error = null, Uri? Url = null, string? Reason = null,
    string? HostPcIp = null, string? ComputerAddress = null, IReadOnlyList<string>? Hosts = null)
{
    public static readonly TvAppState Unknown = new(TvAppKind.Unknown);
}

/// <summary>Samsung kurulumundan önceki denetim: TV'nin 8001 yanıtı ve TV'ye giden yolun bu bilgisayardaki adresi.</summary>
public sealed record SamsungPreflight(SamsungDeveloperInfo? Info, string? ComputerAddress);

/// <summary>Durum noktasının rengi: bağlı (yeşil), sorun var (turuncu), boşta (gri).</summary>
public enum StatusTone { Idle, Warning, Good }

/// <summary>
/// <c>BetterTranslation</c>: isteğe bağlı ücretsiz Gemini anahtarı; atlanabilir (Mac'teki betterTranslation).
/// <c>Hdmi</c>: TV Girişi (yalnız TV eşleştiyse ve Android TV değilse); seçilen giriş <c>style.hdmiInput</c> ile TV'ye gider.
/// Sıra Mac'teki yeni kurulumla aynı: deneme en sonda, Daha İyi Çeviri'den sonra.
/// </summary>
public enum OnboardingStep { Welcome, SecondAccount, PsnLogin, Console, Tv, Hdmi, Translation, BetterTranslation, Test, Done }

public enum AppError
{
    InvalidPin, InvalidLogin, MissingAccount, WrongAccount, RegistrationFailed, ConsoleNoAnswer, ConsoleInUse, ConsoleCrashed, ConsoleVersion,
    /// <summary>PS5 seçilmedi ve IP adresi yazılmadı.</summary>
    MissingConsole,
    WrongCode, ConsoleNoReply, BadAddress,
    /// <summary>PS5 ağda ama eşleştirme ekranı kapalı; PS5 bulundu ama bağlantı açılamadı; boş port kalmadı (GitHub #590).</summary>
    ConsolePairingClosed, ConsoleConnectFailed, NoFreePort,
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
        AppError.ConsolePairingClosed => "The PS5 is on the network but is not waiting for a code. On the PS5 open Settings › System › Remote Play › Pair Device and enter the new code it shows. If the PS5 is in rest mode, turn it on first.",
        AppError.ConsoleConnectFailed => "The PS5 answered, but the pairing connection to it could not be opened. Turn off any VPN or firewall app that blocks the home network, then open Pair Device again on the PS5 and enter the new code.",
        AppError.NoFreePort => "This computer has no free network ports left, so it cannot connect to the PS5. Restart the computer, then open Pair Device again on the PS5 and enter the new code.",
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
