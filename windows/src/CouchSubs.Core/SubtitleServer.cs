// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CouchSubs.Core;

/// <summary>TV'de çevirinin oyundaki İngilizce altyazıya göre yeri.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<SubtitlePlacement>))]
public enum SubtitlePlacement
{
    /// <summary>İngilizce altyazının üstüne, onu örterek.</summary>
    Cover,
    /// <summary>İngilizce altyazının hemen üstünde.</summary>
    Above,
    /// <summary>İngilizce altyazının hemen altında.</summary>
    Below,
    /// <summary>Ekranda sabit bir yükseklikte (<see cref="SubtitleStyle.BottomPercent"/>).</summary>
    Fixed,
}

/// <summary>Altyazı kutusunun kapladığı alan.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<SubtitleBackgroundShape>))]
public enum SubtitleBackgroundShape
{
    /// <summary>Kutu yazı kadar (örtüyse okunan altyazı bölgesi kadar) yer kaplar.</summary>
    Fit,
    /// <summary>Kutu tam genişlikte bir bant: oyundaki İngilizce altyazı yan yana taşsa da görünmez.</summary>
    Band,
}

/// <summary>TV'de altyazının görünümü. Eski sürümün kaydettiği ayarlarda olmayan alanlar varsayılanla dolar.</summary>
/// <param name="FontSize">36 (küçük), 46 (orta), 58 (büyük), 72 (çok büyük)</param>
/// <param name="BottomPercent">Sabit yerleşimde altyazının ekranın altından uzaklığı, yüzde.</param>
/// <param name="Background">Yazının arkasındaki siyah zeminin koyuluğu, yüzde (0: zemin yok).</param>
/// <param name="BackgroundShape">Zeminin kapladığı alan; eski TV uygulamaları alanı tanımaz, yazı kadar gibi davranır.</param>
/// <param name="StackPrevious">
/// Hızlı konuşmada önceki satır(lar) yeni satırın üstünde kısa süre soluk kalsın mı; kapalıysa yeni satır eskisinin
/// yerine geçer. TV uygulaması 0.9.16 ve sonrası tanır.
/// </param>
/// <param name="BackgroundColor">Zeminin rengi ("#RRGGBB"); koyuluğu <paramref name="Background"/>. TV'ye <c>backgroundColor</c>.</param>
/// <param name="TextHex">Yazının rengi ("#RRGGBB"); yoksa <paramref name="TextColor"/>. TV'ye <c>textHex</c>.</param>
/// <param name="NameColorMode">Karakter adının rengi: yazıyla aynı / tek renk / karaktere göre (TV'ye gitmez; sunucu uygular).</param>
/// <param name="NameHex">"Tek Renk"te adların rengi.</param>
/// <param name="CharacterColors">"Karaktere Göre"de seçilen renkler (küçük harfli ad → "#RRGGBB").</param>
/// <param name="NameOnly">Konuşan rengi yalnız adı boyar (yeni arayüz). TV'ye <c>nameOnly</c>.</param>
/// <param name="HdmiInput">Kurulumda seçilen TV girişi (1–4); yoksa null. TV'ye <c>hdmiInput</c>.</param>
public sealed record SubtitleStyle(
    int FontSize = 46,
    int BottomPercent = 7,
    SubtitlePlacement Placement = SubtitlePlacement.Cover,
    int Background = 90,
    bool Bold = false,
    SubtitleTextColor TextColor = SubtitleTextColor.White,
    TvDisplayMode DisplayMode = TvDisplayMode.Auto,
    bool StackPrevious = true,
    SubtitleBackgroundShape BackgroundShape = SubtitleBackgroundShape.Fit,
    string BackgroundColor = SubtitleStyle.DefaultBackgroundColor,
    string? TextHex = null,
    NameColorMode NameColorMode = NameColorMode.Speaker,
    string? NameHex = null,
    IReadOnlyDictionary<string, string>? CharacterColors = null,
    bool NameOnly = false,
    int? HdmiInput = null)
{
    public const string DefaultBackgroundColor = "#101014";

    /// <summary>Geçerli "#RRGGBB" ise büyük harfle; değilse null (Mac SubtitleStyle.hex ile aynı).</summary>
    public static string? Hex(string? value) =>
        value is { Length: 7 } && value[0] == '#' && value.Skip(1).All(char.IsAsciiHexDigit) ? value.ToUpperInvariant() : null;

    /// <summary>Yazının gerçek rengi ("#RRGGBB"): seçilen renk, yoksa beyaz / sarı.</summary>
    public string TextRgb => Hex(TextHex) ?? (TextColor == SubtitleTextColor.Yellow ? "#FFE135" : "#FFFFFF");

    /// <summary>Zeminin rengi ("#RRGGBB"); bozuk kayıtta varsayılan.</summary>
    public string BackgroundRgb => Hex(BackgroundColor) ?? DefaultBackgroundColor;
}

/// <summary>Altyazı Görünümü › Karakter Adı (Mac NameColorMode ile aynı değerler).</summary>
[JsonConverter(typeof(JsonStringEnumConverter<NameColorMode>))]
public enum NameColorMode
{
    [JsonStringEnumMemberName("text")] Text,
    [JsonStringEnumMemberName("single")] Single,
    [JsonStringEnumMemberName("speaker")] Speaker,
    /// <summary>"Tüm Satır": karaktere göre renk; ad ve cümle o karakterin renginde (TV'ye <c>style.wholeLine</c>).</summary>
    [JsonStringEnumMemberName("line")] Line,
}

/// <summary>
/// Android TV'de PS5 görüntüsünün nasıl gösterildiği. Yalnız Android TV uygulaması kullanır; diğer TV'ler ve OBS
/// katmanı alanı tanımaz.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<TvDisplayMode>))]
public enum TvDisplayMode
{
    /// <summary>
    /// Varsayılan: TV uygulaması katmana izin veriyorsa katman, yoksa uygulama içi. Eski kayıtlardaki "InApp" (eski
    /// varsayılan) budur; TV'ye "inApp" gider (Mac/iPhone TVDisplayMode.auto, Android TvDisplayMode.AUTO ile aynı).
    /// </summary>
    [JsonStringEnumMemberName("InApp")]
    Auto,
    /// <summary>Bilerek seçilmiş uygulama içi; TV uygulaması (0.9.84+) hiçbir durumda kendiliğinden katmana geçmez. TV'ye "inAppOnly".</summary>
    InAppOnly,
    /// <summary>TV HDMI'yı kendi ekranında gösterir, altyazı üstteki şeffaf katmanda (bazı TV'lerde uygulama içi görüntü siyah kalıyor).</summary>
    Overlay,
}

/// <summary>TV'de altyazı yazısının rengi.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<SubtitleTextColor>))]
public enum SubtitleTextColor
{
    White,
    Yellow,
}

/// <summary>Altyazıları TV'ye ileten taraf (gerçekte <see cref="SubtitleServer"/>).</summary>
public interface ISubtitleSender
{
    /// <param name="box">Oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir.</param>
    /// <param name="paragraphs">true ise metin satır satır, sola yaslı gösterilir (görev paneli gibi başlık ve maddeli yazılar).</param>
    /// <param name="replaces">Satır az önce gösterilenin uzamış ya da düzelmiş okumasıdır (<see cref="TextMatch.IsRevision"/>); TV onu öncekinin üstüne yığmaz.</param>
    void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false);
    void Clear();

    /// <summary>Ekrandaki görev satırının karedeki yeri (yoksa null): altyazı kutusu onu örtmez, üstüne kayar (<see cref="MissionLine.Clearance"/>).</summary>
    void SendObjective(TextBox? box) { }
}

/// <summary>
/// <c>Screen</c>: "ekranı çevir" sonuçları (metin: grupların çevirisi, yukarıdan aşağı, her biri ayrı satırda);
/// <c>ScreenClear</c>: onların kaldırılması. Bilgisayardaki altyazı penceresi bunları da gösterir.
/// </summary>
public enum SubtitleEventKind { Subtitle, Clear, Screen, ScreenClear, Region, RegionClear }

/// <summary>Sunucudan geçen ve bilgisayar ekranındaki altyazı penceresinin de gösterdiği olay.</summary>
/// <param name="Replaces">Satır öncekinin uzamış ya da düzelmiş okumasıdır; öncekinin üstüne yığılmaz, yerine geçer.</param>
/// <param name="Id">Ek alan olayında alanın kimliği (<see cref="SubtitleEventKind.Region"/>; metin boşsa kutu kalkar).</param>
/// <param name="Box">Ek alan olayında yazının karedeki yeri; altyazı olayında oyundaki altyazının karedeki yeri (bilgisayardaki
/// pencere "Yazı kadar" kutuyu onu örtecek kadar büyütür).</param>
/// <param name="Blocks">Ek alan olayında ayrı yazı gruplarının çevirileri (otomatik ekran yazısında stilleriyle).</param>
public sealed record SubtitleEvent(SubtitleEventKind Kind, string Text = "", int DurationMs = 0, bool Paragraphs = false, bool Replaces = false,
                                   string? Id = null, TextBox? Box = null, IReadOnlyList<ScreenTranslation.Item>? Blocks = null)
{
    public static readonly SubtitleEvent Cleared = new(SubtitleEventKind.Clear);
}

/// <summary>
/// TV uygulamasının bağlandığı yerel Server-Sent Events sunucusu.
/// <c>GET /events</c> akışında <c>subtitle</c>, <c>clear</c> ve <c>style</c> olaylarını yayınlar.
/// </summary>
public sealed class SubtitleServer(int port = 8787, TimeSpan? pingInterval = null, string? key = null,
    bool allowLegacy = SubtitleAccess.AllowLegacyClients, SubtitlePairing? pairing = null) : ISubtitleSender, IRegionSender, IDisposable
{
    private string accessKey = key ?? SubtitleAccess.CreateKey();
    /// <summary>Eşleştirme durumu. Sunucu yeni örnekle yeniden kurulunca (port değişti) eskisininki verilir: onay bekleyen
    /// istek, "TV eşleştir" süresi ve onaylanmış istek taşınır (Mac/iPhone ve Android ile aynı).</summary>
    public SubtitlePairing Pairing { get; } = pairing ?? new();
    public event Action<SubtitlePairing.Ticket>? PairingRequested;
    private int legacySeen;
    public event Action? LegacyClientConnected;
    public string AccessKey { get { lock (gate) return accessKey; } }
    public bool HasLegacyClient => Volatile.Read(ref legacySeen) != 0;
    /// <summary>403 alan Origin değerleri günlüğe bir kez yazılır (GitHub #1132).</summary>
    private readonly SubtitleAccess.RejectedOrigins rejectedOrigins = new();
    private readonly SubtitleAccess.TvEventLog tvEvents = new();

    /// <summary>Anahtar değişince mevcut akışlar da kapanır; eski anahtar yeniden bağlanamaz.</summary>
    public void RotateKey(string key)
    {
        List<Client> closing;
        lock (gate)
        {
            accessKey = key;
            Pairing.Reset();
            closing = [.. clients];
            clients.Clear();
        }
        foreach (var client in closing) client.Tcp.Dispose();
        ClientsChanged?.Invoke(0);
    }
    private sealed class Client(TcpClient tcp, bool viewer = false, bool legacy = false)
    {
        public TcpClient Tcp { get; } = tcp;
        /// <summary>OBS katmanı gibi TV olmayan izleyici: olayları alır ama "TV bağlı" sayısına katılmaz.</summary>
        public bool Viewer { get; } = viewer;
        /// <summary>Sürüm bildirmeyen (0.9.69'den eski) TV uygulaması: <c>clear</c> ona geciktirilerek gider.</summary>
        public bool Legacy { get; } = legacy;
        public Stream Stream { get; } = tcp.GetStream();
        /// <summary>Aynı bağlantıya iki yazma iç içe geçmesin.</summary>
        public SemaphoreSlim WriteLock { get; } = new(1, 1);
        /// <summary>TV akışının <c>link</c> olayıyla bildirilen kimliği (izleyicilerde null; bkz. <see cref="AckTimeout"/>).</summary>
        public string? LinkId { get; init; }
        /// <summary>Son alındıdan beri geçen ping turu (<c>gate</c> altında); hiç alındı göndermemiş (eski) TV'de null.</summary>
        public int? AckMisses { get; set; }
        /// <summary>TV'nin adresi (<see cref="SubtitleAccess.TvHost"/>; bilinmiyorsa boş), akışın açıldığı ve son alındının
        /// geldiği an (<see cref="Environment.TickCount64"/>): kopma satırı için (<see cref="TvClosedLine"/>).</summary>
        public string Host { get; init; } = "";
        public long OpenedAt { get; } = Environment.TickCount64;
        public long? AckAt { get; set; }
    }

    /// <summary>
    /// TV akışı bizim dışımızda (TV kapattı, okuma/yazma hatası) kapandı: günlük satırı. Beta-106/107'de "bağlantı birkaç
    /// dakikada bir kopuyor" bildirimlerinde kopmanın hangi taraftan ve ne kadar açık kaldıktan sonra olduğu günlükte
    /// yoktu. Mac/iPhone ve Android ile aynı metin.
    /// </summary>
    public static string TvClosedLine(string why, string host, long openSeconds, long? ackSecondsAgo) =>
        $"TV bağlantısı koptu ({why}): {(host.Length == 0 ? "?" : host)}, {Math.Max(openSeconds, 0)} sn açıktı, son alındı "
        + (ackSecondsAgo is { } ack ? $"{Math.Max(ack, 0)} sn önce" : "yok") + "; TV yeniden bağlanacak";

    /// <summary>Bu kurulumun kalıcı kimliği (<c>/hello</c> yanıtında). Aynı ağda iki CouchSubs varken TV uygulaması kendi
    /// bilgisayarını ya da telefonunu adres değişse de bununla tanır; eskiden ağda ilk bulduğuna bağlanıyordu (GitHub #425).</summary>
    public string InstanceId { get; init; } = InstallationId.Value;

    private static readonly Lazy<string> InstallationId = new(LoadInstallationId);

    /// <summary>Kimlik ilk istekte rastgele üretilir ve %LOCALAPPDATA%\CouchSubs\server-id dosyasında saklanır (Linux:
    /// ~/.local/share/CouchSubs). Dosya yazılamazsa kimlik bu çalışmalık kalır.</summary>
    private static string LoadInstallationId()
    {
        var path = Path.Combine(AppDataPaths.Root, "server-id");
        try
        {
            if (File.Exists(path) && HelloId(File.ReadAllText(path)) is { Length: > 0 } saved) return saved;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        var made = Guid.NewGuid().ToString("D");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, made);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return made;
    }

    private static string HelloId(string id) => new([.. id.Where(c => char.IsAsciiLetterOrDigit(c) || c == '-')]);

    /// <summary><c>/hello</c> yanıtı: uygulama, eşleştirme gerektiği (<c>auth</c>), kurulum kimliği ve bağlı TV sayısı (Mac ve
    /// Android ile aynı biçim). Erişim anahtarını içermez. TV ağda birden çok CouchSubs bulursa kayıtlı kimliği, yoksa TV'si
    /// bağlı olmayanı seçer; onayladığı anahtarı da bu kimlikle eşler (adres değişse de yeniden eşleşme gerekmez).</summary>
    /// <param name="live">Bu CouchSubs çeviriyor ve altyazıyı TV'ye gönderiyor (1) ya da boşta (0). Aynı ağda iki CouchSubs
    /// varken (bilgisayar açık bırakılmış, çeviri telefondan) TV kayıtlı ama boştaki CouchSubs'a bağlı kalıyor, "bağlı"
    /// görünüp altyazı hiç gelmiyordu; TV çeviren CouchSubs'ı bununla seçer (Mac: helloBody). Eski TV alanı yok sayar.</param>
    internal static string HelloBody(string id, int tvs, bool live = false) =>
        $"{{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"{HelloId(id)}\",\"tvs\":{Math.Max(0, tvs)},\"live\":{(live ? 1 : 0)}}}";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        // Türkçe harfler ı gibi kaçışlarla değil olduğu gibi gönderilir.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    /// <summary>
    /// Bağlantı canlı tutma çerçevesi: yorum satırını EventSource görmez; adlı "ping" olayını TV görür ve
    /// bir süre gelmezse yarı açık kalmış bağlantıyı kapatıp yeniden bağlanır (Mac ile aynı).
    /// </summary>
    internal const string PingFrame = ": ping\n\nevent: ping\ndata: {}\n\n";

    /// <summary>
    /// TV'nin alındısı (bağlantı denetimi): ping yalnız bilgisayardan TV'ye gidiyordu; TV'nin onu gerçekten aldığı
    /// bilinmiyordu. LG uygulaması arka plana düşüp askıya alınınca (ya da Android TV uygulamayı dondurunca) TV'nin ağ
    /// katmanı soketi açık tutuyor, TCP canlılık denetimi ve gönderim hatası hiç gelmiyordu: bilgisayar saatlerce "Bağlı"
    /// gösteriyor, altyazı TV'ye ulaşmıyordu. Akış açılınca <c>link</c> olayı bağlantının kimliğini (<c>id</c>) taşır;
    /// 0.9.76+ TV her ping'de (ve <c>link</c>'te) <c>GET /ack?c=&lt;id&gt;</c> gönderir. Bir kez alındı gönderen
    /// bağlantıdan bu süre boyunca alındı gelmezse bağlantı kopmuş sayılır ve kapatılır (TV sayısı düşer), <see cref="TvStale"/>
    /// tetiklenir; TV kendi tarafında yeniden bağlanır, bekçi uygulamayı yeniden açar. Hiç alındı göndermeyen eski TV
    /// uygulaması eskisi gibi kalır. Bilinmeyen kimliğe 404 döner: TV hemen yeniden bağlanır. Mac/iPhone ve Android ile aynı.
    /// </summary>
    internal TimeSpan AckTimeout => (pingInterval ?? TimeSpan.FromSeconds(15)) * 3;

    /// <summary>Alındısı kesilen TV bağlantısı kapatıldı (iş parçacığı havuzunda). Çağıran "Yeniden bağlanılıyor" gösterip
    /// TV bekçisini yeniler.</summary>
    public event Action? TvStale;

    private readonly object gate = new();
    private readonly List<Client> clients = [];
    private TcpListener? listener;
    private Timer? pingTimer;
    private SubtitleStyle? lastStyle;
    /// <summary>
    /// Gösterilen ek alanların son <c>region</c> olayları (<c>gate</c> altında). TV yeniden bağlanınca bunlar yeniden
    /// gönderilir, gösterilmeyenler kaldırılır (<c>region-sync</c>); her <see cref="RegionRefreshInterval"/>'da telefon kartı
    /// dışındakiler <c>keep</c> bayrağıyla yenilenir. TV, yenilenmeyen alanı 15 sn sonra kendisi kaldırır (#1198;
    /// tv-webos/app.js REGION_LIFE_MS). Mac: SubtitleServer.liveRegions.
    /// </summary>
    private readonly SortedDictionary<string, SortedDictionary<string, object>> liveRegions = new(StringComparer.Ordinal);
    private Timer? regionTimer;
    /// <summary>Gösterilen ek alanların TV'de yenilenme aralığı (TV'deki 15 sn'lik ömrün üçte biri).</summary>
    internal TimeSpan RegionRefreshInterval { get; set; } = TimeSpan.FromSeconds(5);
    /// <summary>Ek alanların okuma turunun en son döndüğü an (<see cref="RegionsAlive"/>; Environment.TickCount64).</summary>
    private long regionAliveAt = -1;

    /// <summary>
    /// Okuma turu bu kadar süredir dönmüyorsa (uygulama donmuş, tur takılmış) gösterilen alanlar TV'de yenilenmez ve yeni
    /// bağlanan TV'ye yinelenmez: TV onları 15 sn'lik ömrü dolunca kendisi kaldırır. Yenileme kendi zamanlayıcısıyla döndüğü
    /// için uygulama donsa da sürüyor, son çeviri TV'de sonsuza dek kalıyordu (#1271). Mac ve Android ile aynı.
    /// </summary>
    public const int RegionAliveMs = 20_000;

    /// <summary>Ek alanların okuma turu döndü (<see cref="IRegionSender.RegionsAlive"/>).</summary>
    public void RegionsAlive() => Interlocked.Exchange(ref regionAliveAt, Environment.TickCount64);

    /// <summary>Gösterilen alanlar yenilenir mi: tur hiç bildirilmediyse (eski akış) ya da en son <see cref="RegionAliveMs"/> içinde döndüyse.</summary>
    internal static bool KeepsRegions(long aliveAt, long now) => aliveAt < 0 || now - aliveAt <= RegionAliveMs;

    private bool RegionsFresh() => KeepsRegions(Interlocked.Read(ref regionAliveAt), Environment.TickCount64);
    /// <summary>GET ile verilen dosyalar: dublaj sesleri ve seslendirme modelinin ses örnekleri.</summary>
    private readonly Dictionary<string, (byte[] Data, string Type)> files = new(StringComparer.Ordinal);
    private readonly Queue<string> speechPaths = new();
    private int speechNumber;

    /// <summary>Bağlı TV sayısı değişince çağrılır (iş parçacığı havuzunda).</summary>
    public event Action<int>? ClientsChanged;

    /// <summary>
    /// Altyazı ve temizleme olayları gönderildiği anda buraya da verilir (çağıranın iş parçacığında). Bilgisayar
    /// ekranındaki pencere TV'ye gidenin aynısını gösterir; sunucu başlamamış olsa da çalışır.
    /// </summary>
    public event Action<SubtitleEvent>? EventSent;

    /// <summary>false ise altyazı olayları TV'lere gitmez (altyazı yalnız bilgisayar ekranında); OBS katmanı almaya devam eder.</summary>
    public bool SendsToTv { get; set; } = true;

    /// <summary>
    /// Konuşan adını renklendir: açıkken <c>subtitle</c> olayı satır başındaki konuşan adlarını ve renklerini
    /// <c>speakerNames</c> alanında taşır (<see cref="Core.SpeakerColors"/>; TV yalnız adı boyar); kapalıyken ya da metinde
    /// ad yoksa alan yazılmaz. Eski <c>speakers</c> alanı gönderilmez: 0.9.79'dan eski TV uygulamaları onunla bütün satırı
    /// boyuyordu; yeni alanı tanımaz, tek renk gösterir.
    /// </summary>
    public bool SpeakerColors { get; set; }

    /// <summary>Oturumun konuşan renkleri (v2; çeviri başlayınca sıfırlanır). Bilgisayar ekranındaki pencereler de buradan boyar.</summary>
    public SpeakerColorBook SpeakerBook { get; } = new();

    public int ConnectedClients
    {
        get { lock (gate) return TvCount(); }
    }

    private int TvCount() => clients.Count(c => !c.Viewer);

    private int? consolePort;

    /// <summary>
    /// TV uygulamasının gösterdiği HDMI girişi (1-4): altyazı akışına bağlanırken <c>/events?hdmi=2</c> ile bildirir.
    /// Bağlantı kopsa da son bildirilen akılda kalır. Bekçi (TvKeeper) PS tuşunun TV'yi konsol girişine geçirmesini
    /// kullanıcının başka girişe geçmesinden bununla ayırır. Eski TV uygulaması bildirmez: null.
    /// </summary>
    public int? ConsolePort
    {
        get { lock (gate) return consolePort; }
    }

    private string? tvAppVersion;

    /// <summary>
    /// Bağlanan TV uygulamasının altyazı akışıyla bildirdiği sürüm (<c>/events?v=0.9.69</c>). null: bu çalışmada henüz TV
    /// bağlanmadı. Boş: bağlanan TV sürüm bildirmedi, yani 0.9.69'den eski bir TV uygulaması. LG'de geliştirici modu
    /// kapalıyken ya da anahtar bu bilgisayarda değilken TV'deki sürüm başka yoldan okunamıyor, TV uygulaması eski kalıyor
    /// ve hiç "TV uygulamasını güncelle" çıkmıyordu (GitHub #884, #891). Mac ve Android ile aynı.
    /// </summary>
    public string? TvAppVersion
    {
        get { lock (gate) return tvAppVersion; }
    }

    /// <summary>
    /// Bu bilgisayarın paketindeki TV uygulamasının sürümü: <c>link</c> olayının <c>latest</c> alanıyla TV'ye bildirilir.
    /// TV'deki uygulama bundan eskiyse TV'nin paneli "TV uygulaması eski" der (GitHub #1199: LG'de 0.9.71 kalmıştı,
    /// düzeltme 0.9.94'teydi). Null ya da boş: alan gönderilmez. Mac ve Android ile aynı.
    /// </summary>
    public string? LatestTvAppVersion { get; set; }

    /// <summary>TV uygulaması altyazı akışına her bağlandığında bildirdiği sürümle (boş: eski TV uygulaması) ve bağlanan
    /// TV'nin adresiyle (bilinmiyorsa boş; bkz. <see cref="SubtitleAccess.TvHost"/>) çağrılır (iş parçacığı havuzunda).</summary>
    public event Action<string, string>? TvAppVersionReported;

    /// <summary>
    /// Sürümü bildiren TV kayıtlı (seçilen) TV mi? Adreslerden biri bilinmiyorsa evet sayılır (Android TV adressiz
    /// eşlenebilir). Aynı ağda iki TV varken (LG ve Android TV) öbür TV'nin uygulaması bağlanıp sürümünü bildirince bu
    /// sürüm kayıtlı TV'ninki sanılıyor, kayıtlı TV için güncelleme ya da kurulum öneriliyordu. Mac/iPhone ve Android ile aynı.
    /// </summary>
    public static bool IsFromSavedTv(string reporter, string? saved)
    {
        reporter = reporter.Trim();
        saved = saved?.Trim();
        if (reporter.Length == 0 || string.IsNullOrEmpty(saved)) return true;
        if (string.Equals(reporter, saved, StringComparison.OrdinalIgnoreCase)) return true;
        return System.Net.IPAddress.TryParse(saved.Trim('[', ']'), out var address)
            && string.Equals(SubtitleAccess.TvHost(address), reporter, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Kayıtlı olmayan TV'nin uygulaması bağlandı: günlük satırı (Mac/iPhone ve Android ile aynı metin).</summary>
    public static string OtherTvReportLine(string reporter, string saved, string version) =>
        $"TV uygulaması kayıtlı TV'den ({saved}) değil, başka bir TV'den ({reporter}) bağlandı, sürüm "
        + $"{(version.Length == 0 ? "< 0.9.69" : version)}; kayıtlı TV için güncelleme ya da kurulum önerilmiyor.";

    /// <summary><c>v</c> parametresi: yalnız rakam ve nokta, en çok 20 karakter; yoksa ya da bozuksa boş (eski TV sayılır).</summary>
    public static string ParseTvAppVersion(string? value) =>
        value is { Length: > 0 and <= 20 } && value.All(c => c is (>= '0' and <= '9') or '.') ? value : "";

    /// <summary>TV'nin bildirdiği sürüm (boş: sürüm bildirmeyen eski TV uygulaması) bu cihazdaki TV paketinden eski mi?</summary>
    public static bool IsTvAppOutdated(string reported, string bundled) =>
        bundled.Length > 0 && (reported.Length == 0 || global::CouchSubs.Core.LgTv.DevModeInstaller.IsNewer(bundled, reported));

    /// <summary><c>hdmi</c> parametresi: 1-4 arası tek rakam, değilse null.</summary>
    public static int? ParseHdmiPort(string? value) =>
        value is { Length: 1 } && value[0] is >= '1' and <= '4' ? value[0] - '0' : null;

    /// <summary>OBS'de "Tarayıcı kaynağı" olarak eklenen altyazı katmanı (<c>GET /obs</c>; Mac ile aynı dosya).</summary>
    public static byte[] ObsOverlay { get; } = LoadObsOverlay();

    private static byte[] LoadObsOverlay()
    {
        using var stream = typeof(SubtitleServer).Assembly.GetManifestResourceStream("obs-overlay.html");
        if (stream is null) return [];
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        return memory.ToArray();
    }

    /// <summary>Sunucuyu başlatır ve dinlenen portu döner (<c>port: 0</c> ise rastgele seçilen port).</summary>
    public Task<int> StartAsync()
    {
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Start();
        this.listener = listener;
        _ = AcceptLoop(listener);
        var every = pingInterval ?? TimeSpan.FromSeconds(15);
        pingTimer = new Timer(_ =>
        {
            DropSilentTvs();
            Broadcast(PingFrame);
        }, null, every, every);
        regionTimer = new Timer(_ => RefreshRegions(), null, RegionRefreshInterval, RegionRefreshInterval);
        return Task.FromResult(((IPEndPoint)listener.LocalEndpoint).Port);
    }

    /// <summary>
    /// <paramref name="keepPairing"/>: sunucu hemen yeniden açılacaksa (port değişiyor) eşleştirme durumu korunur. Sıradan
    /// kapanış (çeviri durdu) onay bekleyen isteği ve "TV eşleştir" süresini siler.
    /// </summary>
    public void Stop(bool keepPairing = false)
    {
        if (!keepPairing) Pairing.SetSession(false);
        pingTimer?.Dispose();
        pingTimer = null;
        regionTimer?.Dispose();
        regionTimer = null;
        listener?.Stop();
        listener = null;
        List<Client> closing;
        lock (gate)
        {
            closing = [.. clients];
            clients.Clear();
            // Port değişip hemen yeniden açılıyorsa gösterilenler yeni akışa yeniden gönderilsin.
            if (!keepPairing) liveRegions.Clear();
        }
        foreach (var client in closing) client.Tcp.Dispose();
    }

    public void Dispose() => Stop();

    /// <param name="paragraphs">true ise metin satır satır, sola yaslı gösterilir (görev paneli gibi başlık ve maddeli yazılar).</param>
    /// <param name="replaces">TV satırı öncekinin üstüne yığmaz, yerine koyar (<c>replace</c> alanı; eski TV uygulamaları yok sayar).</param>
    public void SendSubtitle(string text, int durationMs = 15000, TextBox? box = null, bool paragraphs = false, bool replaces = false)
    {
        var json = new SortedDictionary<string, object>
        {
            ["at"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            ["duration"] = durationMs,
            ["text"] = text,
        };
        if (paragraphs) json["paragraphs"] = true;
        if (replaces) json["replace"] = true;
        if (box is { } b) json["box"] = BoxJson(b);
        // Ekrandaki görev satırının yeri: TV/OBS altyazı kutusunu onun üstüne taşır (eski TV yok sayar).
        TextBox? keep;
        lock (gate) keep = objective;
        if (!paragraphs && keep is { } k) json["keep"] = BoxJson(k);
        if (SpeakerColors && Core.SpeakerColors.Speakers(text) is { Count: > 0 } speakers)
            json["speakerNames"] = speakers.Select(name => new SortedDictionary<string, object> { ["name"] = name, ["color"] = SpeakerBook.Color(name)! }).ToList();
        lock (gate)
        {
            legacyHoldGeneration++;
            legacyHoldUntil = DateTime.UtcNow + LegacyClearHold(text.Length);
        }
        Broadcast(Frame("subtitle", json), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.Subtitle, text, durationMs, paragraphs, replaces, Box: box));
    }

    /// <summary>Dört basamağa yuvarlanır (decimal: JSON'da 0.8 olarak yazılsın).</summary>
    /// Bölme sondaki sıfırları atar (0.8750 → 0.875). NaN 0 olur: <c>Math.Clamp</c> NaN'ı olduğu gibi döndürüyor, decimal'e
    /// çevirirken OverflowException ile çöküyordu (Mac/iPhone ve Android ile aynı).
    internal static decimal Round(double value) =>
        Math.Round((decimal)Math.Clamp(double.IsNaN(value) ? 0 : value, 0, 1), 4) / 1.000000000000000000000000000000000m;

    private TextBox? objective;

    /// <summary>
    /// Ekrandaki görev satırının karedeki yeri (yoksa null; <see cref="MissionLine.Clearance"/>). Değişince <c>objective</c>
    /// olayı gider ve sonraki her altyazı <c>keep</c> alanında taşır (sonradan bağlanan TV de alır). TV ve OBS sayfası
    /// altyazıyı (örtüsüyle) görev satırının üstüne taşır; eski TV uygulamaları yok sayar. Mac/iPhone ve Android aynı.
    /// </summary>
    public void SendObjective(TextBox? box)
    {
        lock (gate)
        {
            if (objective == box) return;
            objective = box;
        }
        var json = new SortedDictionary<string, object>();
        if (box is { } b) json["box"] = BoxJson(b);
        Broadcast(Frame("objective", json), subtitle: true);
    }

    public void Clear()
    {
        var frame = Frame("clear", new SortedDictionary<string, object>());
        TimeSpan wait;
        int generation;
        lock (gate)
        {
            wait = legacyHoldUntil - DateTime.UtcNow;
            generation = legacyHoldGeneration;
        }
        if (wait <= TimeSpan.Zero || !SendsToTv)
        {
            Broadcast(frame, subtitle: true);
        }
        else
        {
            // Eski TV'ler satırı kendileri tutmaz: `clear` onlara satırın en az görünme süresi dolunca gider.
            Broadcast(frame, subtitle: true, legacy: false);
            _ = Task.Delay(wait).ContinueWith(_ =>
            {
                lock (gate) if (generation != legacyHoldGeneration) return;
                Broadcast(frame, subtitle: true, legacy: true);
            }, TaskScheduler.Default);
        }
        EventSent?.Invoke(SubtitleEvent.Cleared);
    }

    private DateTime legacyHoldUntil = DateTime.MinValue;
    private int legacyHoldGeneration;

    /// <summary>
    /// Eski TV uygulamaları (0.9.7'den önce) <c>clear</c> gelir gelmez satırı kaldırır. Oyundaki satır ekrandan ~1 sn'de
    /// kalkınca çevirisi TV'de yalnız bir an görünüyordu: "TV'de test et" yazısı (8 sn, <c>clear</c> yok) görünüyor, oyun
    /// altyazıları hiç görünmüyordu. Yeni TV uygulaması satırı kendisi <c>min(5000, 2000 + 60 × harf)</c> ms tutar
    /// (tv-webos/app.js <c>holdUntil</c>); sürüm bildirmeyen bağlantılara <c>clear</c> bu süre dolunca gider, arada yeni
    /// satır gelirse hiç gitmez (Mac ve Android ile aynı kural).
    /// </summary>
    public static TimeSpan LegacyClearHold(int textLength) =>
        TimeSpan.FromMilliseconds(Math.Min(5000, 2000 + 60 * Math.Max(0, textLength)));

    /// <summary>
    /// TV uygulamasını kapatır; çeviri durduğunda TV kendi girişine (HDMI) döner. Yalnız TV'lere gider, OBS gibi
    /// izleyicilere gitmez. Dönen görev mesaj bütün TV'lere yazılınca (ya da yazılamayınca) biter; kapanışta sunucu
    /// durdurulmadan önce kısa süre beklenebilir.
    /// </summary>
    public Task ExitTvApp()
    {
        var frame = Frame("exit", new SortedDictionary<string, object>());
        List<Client> targets;
        lock (gate) targets = [.. clients.Where(c => !c.Viewer)];
        if (targets.Count == 0) return Task.CompletedTask;
        // Çağıranın eşzamanlama bağlamına dönülmez: kapanışta arayüz iş parçacığı bu görevi bekleyebilir.
        return Task.Run(() => Task.WhenAll(targets.Select(async client =>
        {
            try { await Write(client, frame); }
            catch { Remove(client); }
        })));
    }

    /// <summary>
    /// "Ekranı çevir" sonuçları: <c>screen</c> olayı her çeviriyi yazının yeri (<c>box</c>), tipik satır yüksekliği
    /// (<c>line</c>, ekrana oranla) ve çok parçalıysa <c>paragraphs</c> ile taşır. TV öncekinin yerine bunları koyar.
    /// </summary>
    public void SendScreen(IReadOnlyList<ScreenTranslation.Item> items, int durationMs)
    {
        items = Steadied([.. items.Where(item => Area(item.Box) <= MaxBoxArea)]);
        IReadOnlyList<ScreenTranslation.Item> shown;
        lock (screenStyle)
        {
            screenEpoch++;
            screenShown = (items, Environment.TickCount64 + durationMs);
            screenVisible = [.. items.Select(item => !presence.Hidden(item))];
            shown = [.. items.Where(item => !presence.Hidden(item))];
        }
        EmitScreen(shown, durationMs);
    }

    private void EmitScreen(IReadOnlyList<ScreenTranslation.Item> items, int durationMs)
    {
        var list = items.Select(item => ItemJson(item, phone: false)).ToList();
        Broadcast(Frame("screen", new SortedDictionary<string, object> { ["duration"] = durationMs, ["items"] = list }), subtitle: true);
        // Altyazı yalnız bilgisayardaysa (TV yok) çeviriler başka hiçbir yere gitmiyordu: tuşa basınca yalnız
        // "Ekran çevriliyor…" görünüyordu.
        // Telefon kartının zemini (ScreenPhoneCard.BackdropText) düz metne girmez; öğeler yerleri ve stilleriyle de gider.
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.Screen,
                                            string.Join('\n', items.Where(item => !ScreenPhoneCard.IsBackdrop(item)).Select(item => item.Translation)),
                                            durationMs, Paragraphs: true, Blocks: items));
    }

    /// <summary>
    /// Ek alanın çevirisi: <c>region</c> olayı alanın kimliğini (<c>id</c>), çeviriyi (<c>text</c>; boşsa kutu kalkar),
    /// yazının karedeki yerini (<c>box</c>) ve satır yüksekliğini (<c>line</c>) taşır. TV çeviriyi o yerde küçük bir kutuda
    /// gösterir; ana altyazıya dokunmaz. Olayı tanımayan eski TV uygulamaları yok sayar (Mac ile aynı).
    /// </summary>
    public void SendRegion(string id, string text, TextBox? box, double? lineHeight = null) =>
        SendRegion(id, text, box, lineHeight, null);

    /// <summary>
    /// <paramref name="icons"/>: çevirinin içindeki kumanda simgeleri; <c>icons</c> alanı her simgenin düz metindeki
    /// yerini (<c>at</c>) ve PNG'sini (<c>src</c>) taşır. Eski TV uygulamaları alanı yok sayıp düz metni gösterir.
    /// </summary>
    public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons) =>
        SendRegion(id, text, box, lineHeight, icons, null);

    /// <summary>
    /// <paramref name="blocks"/>: alanda ayrı duran yazı gruplarının çevirileri kendi yerleriyle (<c>blocks</c>; her biri
    /// <c>screen</c> olayındaki öğe gibi <c>box</c>, <c>line</c>, <c>text</c>). TV her birini kendi İngilizce yazısının
    /// üstüne koyar. Telefon bloklarının isteğe bağlı <c>surface</c> alanı opak zemin ve yazı rengini taşır.
    /// Alanı tanımayan eski TV uygulamaları birleşik <c>text</c>'i tek kutuda gösterir.
    /// </summary>
    public void SendRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                           IReadOnlyList<ScreenTranslation.Item>? blocks)
    {
        (text, blocks) = Guard(text, box, blocks);
        if (id != "game-phone" && blocks is not null) blocks = Steadied(blocks);
        if (id != "game-phone")
        {
            IReadOnlyList<ScreenTranslation.Item>? visible;
            lock (screenStyle)
            {
                if (text.Length == 0 || blocks is not { Count: > 0 })
                {
                    regionShown.Remove(id);
                    regionVisible.Remove(id);
                }
                else
                {
                    regionShown[id] = new RegionSent(text, box, lineHeight, icons, blocks);
                    regionVisible[id] = [.. blocks.Select(item => !presence.Hidden(item))];
                }
                visible = blocks is null ? null : [.. blocks.Where(item => !presence.Hidden(item))];
            }
            if (blocks is not null && visible is not null && visible.Count != blocks.Count)
            {
                EmitRegion(id, visible.Count == 0 ? "" : text, box, lineHeight, icons, visible);
                return;
            }
        }
        EmitRegion(id, text, box, lineHeight, icons, blocks);
    }

    private void EmitRegion(string id, string text, TextBox? box, double? lineHeight, IReadOnlyList<IconPlacement>? icons,
                            IReadOnlyList<ScreenTranslation.Item>? blocks)
    {
        var data = RegionData(id, text, box, lineHeight, icons, blocks);
        lock (gate)
        {
            if (text.Length == 0) liveRegions.Remove(id);
            else liveRegions[id] = data;
        }
        Broadcast(Frame("region", data), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.Region, text, Id: id, Box: box,
                                            Blocks: blocks is { Count: > 0 } && text.Length > 0 ? blocks : null));
    }

    /// <summary>
    /// Ekranın bu oranından büyük çeviri kutusu gönderilmez. TV ve OBS kutuyu opak zeminle çizer; yanlış bir algılamanın
    /// (oyun telefonu, otomatik ekran yazısı) ekranın büyük kısmını kaplayan kutusu oyun görüntüsünü kapatıyordu
    /// (LG'de "siyah ekran, ses var").
    /// </summary>
    internal const double MaxBoxArea = 0.4;

    /// <summary>
    /// Ekran yazısı çevirilerinin görünüşü oturum boyunca kilitli (<see cref="ScreenStyleLock"/>); "Ekranı çevir" ve otomatik
    /// ekran yazısı aynı kilidi paylaşır (Mac: SubtitleServer.steadied, Android: SubtitleServer.steadied).
    /// </summary>
    private readonly ScreenStyleLock screenStyle = new();
    /// <summary>Ekrandaki çeviriler ve özgün yazılarının takibi (<see cref="ScreenPresence"/>).</summary>
    private readonly ScreenPresence presence = new();
    /// <summary><see cref="ScreenPresence"/>'ın kaldırma ve geri getirme kararları altyazı günlüğüne (<see cref="DropLog"/>; sınırlı, tekrarsız).</summary>
    private readonly DropLog presenceDrops = new();
    private (IReadOnlyList<ScreenTranslation.Item> Items, long Until)? screenShown;
    /// <summary>
    /// Her <see cref="SendScreen"/> ve <see cref="ClearScreen"/> bir üst numara verir. <c>Observe</c> değişikliği kilidin
    /// dışında gönderir; arada çeviri kaldırıldıysa eski öğeler yeniden gönderilmez (kaldırılan çeviri TV'de geri
    /// çiziliyordu, #1182).
    /// </summary>
    private long screenEpoch;
    private List<bool> screenVisible = [];
    private sealed record RegionSent(string Text, TextBox? Box, double? LineHeight, IReadOnlyList<IconPlacement>? Icons,
                                     IReadOnlyList<ScreenTranslation.Item> Blocks);
    private readonly SortedDictionary<string, RegionSent> regionShown = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<bool>> regionVisible = [];

    /// <summary>
    /// Her karede çağrılır: çevirisi gösterilen yazılar hâlâ yerinde mi (<see cref="ScreenPresence"/>). Özgün yazısı kalkan öğe
    /// TV'den ve masaüstünden aynı karede kalkar; geri gelirse yeniden gösterilir (Mac: SubtitleServer.observe).
    /// </summary>
    public void Observe(Frame frame) => Observe(box => ScreenPresence.Patch(frame, box));

    internal void Observe(Func<TextBox, IReadOnlyList<int>?> patch)
    {
        var now = Environment.TickCount64;
        List<ScreenTranslation.Item>? screenChange = null;
        var regionChanges = new List<(string Id, RegionSent Sent, List<ScreenTranslation.Item> Kept)>();
        long until;
        var flips = new List<(string Source, bool Visible)>();
        long epoch;
        lock (screenStyle)
        {
            epoch = screenEpoch;
            if (screenShown is { } expired && expired.Until <= now) screenShown = null;
            var screen = screenShown?.Items ?? [];
            var regions = regionShown.ToList();
            var all = screen.Concat(regions.SelectMany(r => r.Value.Blocks)).ToList();
            if (!all.Any(ScreenPresence.Tracks) && screenVisible.Count == 0 && regionVisible.Count == 0) return;
            var visible = presence.Visible(all, patch);
            var flags = visible.Take(screen.Count).ToList();
            var before = screenVisible.Count == 0 ? [.. screen.Select(_ => true)] : screenVisible;
            if (screen.Count > 0 && !flags.SequenceEqual(before)) screenChange = [.. screen.Where((_, i) => flags[i])];
            // Kaldırma ya da geri getirme kararı günlüğe (DropLog): periyodik kopmalarda hangi yazının izinin kaçtığı görünsün.
            for (var i = 0; i < screen.Count && i < before.Count; i++) if (before[i] != flags[i]) flips.Add((screen[i].Source, flags[i]));
            screenVisible = screen.Count == 0 ? [] : flags;
            var offset = screen.Count;
            var previous = new Dictionary<string, List<bool>>(regionVisible);
            regionVisible.Clear();
            foreach (var (id, sent) in regions)
            {
                var part = visible.Skip(offset).Take(sent.Blocks.Count).ToList();
                offset += sent.Blocks.Count;
                var old = previous.TryGetValue(id, out var seen) ? seen : [.. sent.Blocks.Select(_ => true)];
                regionVisible[id] = part;
                for (var i = 0; i < sent.Blocks.Count && i < old.Count; i++) if (old[i] != part[i]) flips.Add((sent.Blocks[i].Source, part[i]));
                if (!part.SequenceEqual(old)) regionChanges.Add((id, sent, [.. sent.Blocks.Where((_, i) => part[i])]));
            }
            until = screenShown?.Until ?? now;
        }
        foreach (var (source, shown) in flips)
            presenceDrops.Note("ScreenPresence",
                shown ? "özgün yazı geri geldi, çeviri yeniden gösterildi" : "özgün yazının izi kaçtı, çeviri kaldırıldı", source);
        if (screenChange is not null)
        {
            bool current;
            lock (screenStyle) current = screenEpoch == epoch;
            if (current) EmitScreen(screenChange, (int)Math.Max(1, until - now));
        }
        foreach (var (id, sent, kept) in regionChanges)
            EmitRegion(id, kept.Count == 0 ? "" : sent.Text, sent.Box, sent.LineHeight, sent.Icons, kept.Count == 0 ? null : kept);
    }

    internal IReadOnlyList<ScreenTranslation.Item> Steadied(IReadOnlyList<ScreenTranslation.Item> items)
    {
        lock (screenStyle) return screenStyle.Steady(items, Environment.TickCount64);
    }

    /// <summary>Ekran yazısının görünüşü yeniden ölçülsün (oturum yeniden başladı).</summary>
    public void ResetScreenStyle()
    {
        lock (screenStyle)
        {
            screenStyle.Reset();
            presence.Reset();
        }
    }

    internal static double Area(TextBox box) => Math.Max(0, box.Right - box.Left) * Math.Max(0, box.Bottom - box.Top);

    /// <summary>
    /// Büyük kutu koruması: alanı <see cref="MaxBoxArea"/>'dan büyük bloklar atılır; blokların toplamı da sınırı aşıyorsa
    /// ya da bloksuz alanın kutusu sınırdan büyükse alan boş gönderilir (TV kutuyu kaldırır).
    /// </summary>
    internal static (string Text, IReadOnlyList<ScreenTranslation.Item>? Blocks) Guard(string text, TextBox? box,
        IReadOnlyList<ScreenTranslation.Item>? blocks)
    {
        if (text.Length == 0) return (text, blocks);
        if (blocks is { Count: > 0 })
        {
            var kept = blocks.Where(item => Area(item.Box) <= MaxBoxArea).ToList();
            // Sohbet panelinin balonları panelin zemininin içindedir: toplam alana bir kez (zemin olarak) girer (Mac ile aynı).
            if (kept.Where(item => item.Panel is null or ScreenPhoneCard.PanelPart.Card).Sum(item => Area(item.Box)) > MaxBoxArea)
                return ("", null);
            if (kept.Count > 0) return (text, kept.Count == blocks.Count ? blocks : kept);
            blocks = null;
        }
        return box is { } b && Area(b) > MaxBoxArea ? ("", null) : (text, blocks);
    }

    /// <summary><c>region</c> olayının verisi (TV'ye gidenin aynısı; gerçek kare doğrulaması da bunu döker).</summary>
    internal static SortedDictionary<string, object> RegionData(string id, string text, TextBox? box, double? lineHeight,
        IReadOnlyList<IconPlacement>? icons, IReadOnlyList<ScreenTranslation.Item>? blocks)
    {
        var json = new SortedDictionary<string, object> { ["id"] = id, ["text"] = text };
        if (icons is { Count: > 0 }) json["icons"] = IconsJson(icons);
        if (blocks is { Count: > 0 } && text.Length > 0) json["blocks"] = blocks.Select(item => ItemJson(item, id == "game-phone")).ToList();
        if (box is { } b) json["box"] = BoxJson(b);
        if (lineHeight is { } line) json["line"] = Round(line);
        return json;
    }

    /// <summary>Olay verisini TV'ye giden JSON'a çevirir.</summary>
    internal static string Json(SortedDictionary<string, object> data) => JsonSerializer.Serialize(data, JsonOptions);

    /// <summary>Bütün ek alan kutularını kaldırır.</summary>
    public void ClearRegions()
    {
        lock (screenStyle)
        {
            regionShown.Clear();
            regionVisible.Clear();
        }
        lock (gate) liveRegions.Clear();
        Broadcast(Frame("region-clear", new SortedDictionary<string, object>()), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.RegionClear));
    }

    /// <summary>TV'deki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz).</summary>
    public void ClearScreen()
    {
        lock (screenStyle)
        {
            screenEpoch++;
            screenShown = null;
            screenVisible = [];
        }
        Broadcast(Frame("screen-clear", new SortedDictionary<string, object>()), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.ScreenClear));
    }

    /// <summary>Yeriyle bir çeviri ("Ekranı çevir" öğesi ya da ek alan bloğu).</summary>
    internal static SortedDictionary<string, object> ItemJson(ScreenTranslation.Item item, bool phone)
    {
        var json = new SortedDictionary<string, object>
        {
            ["box"] = BoxJson(item.Box),
            ["line"] = Round(item.LineHeight),
            ["text"] = item.Translation,
        };
        if (item.Paragraphs) json["paragraphs"] = true;
        // Yerleşim (ScreenFit): kutunun genişleyebileceği alan ve özgün satır sayısı (eski TV yok sayar).
        if (item.Room is { } room) json["room"] = BoxJson(room);
        if (item.Rows > 1) json["rows"] = item.Rows;
        if (item.Icons is { Count: > 0 } icons) json["icons"] = IconsJson(icons);
        if ((phone || item.Look is not null) && item.Style is { } style && IsRgb(style.Background) && IsRgb(style.Foreground))
        {
            json["surface"] = item.Look is { } flat
                ? new SortedDictionary<string, object> { ["background"] = style.Background, ["foreground"] = style.Foreground, ["flat"] = flat.Flat }
                : new SortedDictionary<string, object> { ["background"] = style.Background, ["foreground"] = style.Foreground };
        }
        // Otomatik ekran yazısı: özgün yazının görünüşü (eski TV yok sayar).
        if (item.Look is { } look)
            json["style"] = new SortedDictionary<string, object>
            {
                ["align"] = look.Align, ["bold"] = look.Bold, ["condensed"] = look.Condensed, ["upper"] = look.Upper,
            };
        // Yerinde birebir çizim (TextPaint; eski TV yok sayar): opak kutu tam örtü sınırında, ölçülen zeminle (degrade
        // dahil), yazı özgün renk, kalınlık, büyük harf, hiza ve satır aralığıyla; grup aynı boyda, boş alana uzayabilir.
        if (item.Paint is { } paint && item.Look is { } painted && item.Style is { } colors && IsRgb(paint.Background)
            && IsRgb(colors.Foreground))
        {
            json["bg"] = paint.Background;
            if (paint.Background2 is { } second && IsRgb(second) && paint.Direction is { } direction)
            {
                json["bg2"] = second;
                json["bgDir"] = direction;
            }
            if (paint.Patterned) json["bgPat"] = true;
            json["fg"] = colors.Foreground;
            json["weight"] = painted.Bold ? 700 : 400;
            json["upper"] = painted.Upper;
            json["align"] = painted.Align;
            json["lineH"] = Round(paint.Pitch);
            json["cover"] = BoxJson(paint.Cover);
            if (paint.Grow is { } grow) json["grow"] = BoxJson(grow);
            if (paint.Group is { } group) json["group"] = group;
            // Çizim kipi (TextPaint.Mode; TV uygulaması 0.9.108): yanına yazma ya da ikiz panel. Eski TV alanları yok sayıp
            // yukarıdaki örtüyle çizer.
            if (paint.Mode != PaintMode.Cover && paint.Spot is { } spot && paint.SpotRoom is { } spotRoom)
            {
                json["mode"] = paint.Mode;
                json["spot"] = BoxJson(spot);
                json["spotRoom"] = BoxJson(spotRoom);
                if (paint.Mode == PaintMode.Twin && paint.Twin is { } twin)
                {
                    json["twinBox"] = BoxJson(twin);
                    json["radius"] = Round(paint.Radius);
                    json["scale"] = Round(paint.Scale);
                    if (paint.Tail is { } tail) json["tail"] = tail;
                    // Kenar çizgisi (TV uygulaması 0.9.109; eski TV yok sayar).
                    if (paint.Edge is { } edge && IsRgb(edge.Color))
                        json["edge"] = new SortedDictionary<string, object>
                        {
                            ["color"] = edge.Color, ["top"] = Round(edge.Top), ["right"] = Round(edge.Right),
                            ["bottom"] = Round(edge.Bottom), ["left"] = Round(edge.Left),
                        };
                    if (paint.PortraitImage is { } image && paint.PortraitTwin is { } at)
                        json["icon"] = new SortedDictionary<string, object> { ["src"] = image, ["box"] = BoxJson(at) };
                }
            }
        }
        // Telefon mesajı kendi balonunda: TV çeviriyi balona sığdırır (eski TV yok sayar, özgün stilde çizer).
        if (item.Bubble) json["bubble"] = true;
        // OCR kutusu balonun dış kenarını içermez. Köşe, oyun görünüşündeki gibi satır yüksekliğinin 0,6'sı kadar
        // (kare yüksekliğine oranla, TextPaint.Radius ile aynı birimde); ölçülmemiş kuyruk gönderilmez.
        if (item.Phone?.Role.IsBubble() == true && !json.ContainsKey("radius") && item.LineHeight > 0)
            json["radius"] = Round(ScreenPhoneCard.BubbleRadius * item.LineHeight);
        // Telefonun yanındaki sohbet panelinin parçası: yeni TV paneli akışla çizer; eski TV alanı yok sayar.
        if (item.Panel is { } panel) json["panel"] = panel.Json();
        // Hizalı panel (TV uygulaması 0.9.106): parçalar kutularının yerinde, zeminsiz; eski TV akışla çizer (Mac ile aynı).
        if (item.Aligned) json["aligned"] = true;
        // Liste kartı (TV uygulaması 0.9.110): avatar, kalın ad, önizleme, rozet, seçim çerçevesi. Eski TV yok sayar,
        // `text`'i (ad ve önizleme iki satır) yerinde çizer (Mac ile aynı).
        if (item.ListRow is { } row) json["row"] = RowJson(row);
        return json;
    }

    internal static SortedDictionary<string, object> RowJson(ScreenPhoneCard.ListRow row)
    {
        var json = new SortedDictionary<string, object> { ["name"] = row.Name, ["preview"] = row.Preview };
        if (row.Avatar is { } avatar) json["avatar"] = avatar;
        if (row.Badge is { } badge) json["badge"] = badge;
        if (row.Selected is { } selected && IsRgb(selected)) json["selected"] = selected;
        if (row.Widget) json["widget"] = true;
        return json;
    }

    private static bool IsRgb(string color) => color is { Length: 7 } && color[0] == '#' && color.Skip(1).All(char.IsAsciiHexDigit);

    private static List<SortedDictionary<string, object>> IconsJson(IReadOnlyList<IconPlacement> icons) =>
        [.. icons.Select(icon => new SortedDictionary<string, object> { ["at"] = icon.At, ["src"] = icon.Image })];

    private static SortedDictionary<string, object> BoxJson(TextBox b) => new()
    {
        ["bottom"] = Round(b.Bottom), ["left"] = Round(b.Left), ["right"] = Round(b.Right), ["top"] = Round(b.Top),
    };

    /// <summary>Dosyayı <paramref name="path"/> adresinden verir ("/voices/male_1.wav").</summary>
    public void Publish(byte[] data, string path, string type = "audio/wav")
    {
        lock (gate) files[path] = (data, type);
    }

    /// <summary>
    /// Dublaj sesini TV'ye gönderir: ses <c>/speech/&lt;n&gt;.wav</c> adresinden verilir, <c>speech</c> olayı adresi
    /// bildirir. Son 16 ses tutulur.
    /// </summary>
    public void SendSpeech(byte[] wav, int durationMs)
    {
        string path;
        lock (gate)
        {
            path = $"/speech/{++speechNumber}.wav";
            files[path] = (wav, "audio/wav");
            speechPaths.Enqueue(path);
            while (speechPaths.Count > 16) files.Remove(speechPaths.Dequeue());
        }
        Broadcast(Frame("speech", new SortedDictionary<string, object> { ["duration"] = durationMs, ["url"] = path }));
    }

    /// <summary>TV'de çalan dublajı durdurur.</summary>
    public void StopSpeech() => Broadcast(Frame("speech-stop", new SortedDictionary<string, object>()));

    public void SendStyle(SubtitleStyle style)
    {
        lock (gate) lastStyle = style;
        // Karakter adı rengi: "Tek Renk"te herkes aynı renk, "Karaktere Göre"de seçilen renkler (Mac ile aynı).
        SpeakerBook.Configure(style.NameColorMode == NameColorMode.Single ? SubtitleStyle.Hex(style.NameHex) : null,
            style.NameColorMode is NameColorMode.Speaker or NameColorMode.Line ? style.CharacterColors ?? new Dictionary<string, string>() : new Dictionary<string, string>());
        Broadcast(StyleFrame(style, SetApart), subtitle: true);
    }

    /// <summary>
    /// "Ekran yazılarını altyazıdan ayır": TV ek alan kutularını özgün renginde ve kendi yerinde, altyazı kutusundan
    /// farklı zeminde çizer (<c>style</c> olayının <c>setApart</c> alanı; yoksa açık sayılır). Değişince
    /// <see cref="SendStyle"/> yeniden gönderilmeli.
    /// </summary>
    public bool SetApart { get; set; } = true;

    // --- Bağlantılar ---

    private async Task AcceptLoop(TcpListener listener)
    {
        while (true)
        {
            TcpClient tcp;
            try { tcp = await listener.AcceptTcpClientAsync(); }
            catch { return; }
            if (tcp.Client.RemoteEndPoint is not IPEndPoint remote || !SubtitleAccess.IsLocalPeer(remote.Address))
            {
                tcp.Dispose();
                continue;
            }
            _ = Serve(tcp);
        }
    }

    private async Task Serve(TcpClient tcp)
    {
        try
        {
            EnableKeepAlive(tcp.Client);
            // Altyazı çerçeveleri küçüktür; Nagle beklemesi her satırı TV'ye geç ulaştırmasın.
            tcp.NoDelay = true;
            var stream = tcp.GetStream();
            var head = await ReadRequestLine(stream);
            var request = head is null ? null : SubtitleAccess.Parse(head);
            if (request is null) { await RespondAndClose(tcp, "400 Bad Request"); return; }
            var checkedKey = AccessKey;
            var status = SubtitleAccess.Authorize(request, checkedKey, allowLegacy, out var legacy);
            var cors = SubtitleAccess.Cors(request);
            if (status == 403 && rejectedOrigins.Line(request) is { } rejected) SubtitleLog.Write(rejected);
            if (status != 200) { await RespondAndClose(tcp, status == 403 ? "403 Forbidden" : "401 Unauthorized", cors: status == 403 ? "" : cors); return; }
            var method = request.Method;
            var path = request.Path;
            if (path == "/pair")
            {
                if (method == "POST")
                {
                    var ticket = Pairing.Begin(tcp.Client.RemoteEndPoint is IPEndPoint peer ? SubtitleAccess.TvHost(peer.Address) : "");
                    if (ticket is null) { await RespondAndClose(tcp, "409 Conflict", cors: cors); return; }
                    PairingRequested?.Invoke(ticket);
                    await RespondAndClose(tcp, "200 OK", JsonSerializer.Serialize(new { id = ticket.Id, code = ticket.Code }), cors);
                }
                else if (method == "GET")
                {
                    string body;
                    lock (gate)
                    {
                        var valid = request.Parameter("validate") == "1";
                        var state = valid ? (SubtitleAccess.Authorize(request with { Target = "/events?k=" + Uri.EscapeDataString(request.Parameter("k") ?? "") }, accessKey, false, out _) == 200 ? "valid" : "expired") : Pairing.Poll(request.Parameter("id") ?? "");
                        // Eski TV uygulamaları "rejected"ı tanımaz: "expired" görüp durur. Yenisi rejected ile Tamam bekler, yalnız
                        // "expired"da kendisi yeniden ister (GitHub #737).
                        body = state == "rejected" ? JsonSerializer.Serialize(new { state = "expired", rejected = true })
                            : JsonSerializer.Serialize(new { state, key = state == "approved" ? accessKey : null });
                    }
                    await RespondAndClose(tcp, "200 OK", body, cors);
                }
                else await RespondAndClose(tcp, "405 Method Not Allowed", cors: cors);
                return;
            }
            if (method == "OPTIONS") await RespondAndClose(tcp, "204 No Content", cors: cors + PreflightHeaders);
            else if (method == "GET" && path == "/events")
            {
                // OBS katmanı ve ikinci ekran sayfası izleyicidir: TV sayılmaz, altyazı hedefi TV değilken de olayları alır.
                var obs = request.Parameter("viewer") is "obs" or SecondScreen.Viewer;
                // Anahtarsız OBS sayfası eski bir OBS adresidir; TV uygulamasının eski olduğu anlamına gelmez.
                if (legacy && !obs && Interlocked.Exchange(ref legacySeen, 1) == 0) LegacyClientConnected?.Invoke();
                var unreported = false;
                if (!obs)
                {
                    var version = ParseTvAppVersion(request.Parameter("v"));
                    lock (gate) tvAppVersion = version;
                    unreported = version.Length == 0;
                    TvAppVersionReported?.Invoke(version, tcp.Client.RemoteEndPoint is System.Net.IPEndPoint reporter ? SubtitleAccess.TvHost(reporter.Address) : "");
                }
                await OpenStream(tcp, obs, cors, checkedKey, obs ? null : ParseHdmiPort(request.Parameter("hdmi")), unreported);
            }
            else if (method == "GET" && path == "/ack")
            {
                // TV'nin alındısı (bkz. AckTimeout). Bilinmeyen kimlik: sunucuda bu bağlantı yok, TV yeniden bağlanmalı.
                var link = request.Parameter("c") ?? "";
                bool known;
                lock (gate)
                {
                    var client = link.Length == 0 ? null : clients.FirstOrDefault(c => c.LinkId == link);
                    if (client is not null)
                    {
                        client.AckMisses = 0;
                        client.AckAt = Environment.TickCount64;
                    }
                    known = client is not null;
                }
                await RespondAndClose(tcp, known ? "204 No Content" : "404 Not Found", cors: cors);
            }
            else if (method == "GET" && path == "/tvlog")
            {
                // TV uygulamasının olay satırı (TV 0.9.116; bkz. SubtitleAccess.TvEventLog): HDMI'nin yeniden kurulması,
                // sayfanın yenilenmesi, uygulamanın yeniden açılması nedeniyle günlüğe.
                if (tvEvents.Line(request.Parameter("m"), request.Parameter("a"), DateTime.UtcNow) is { } line) SubtitleLog.Write(line);
                await RespondAndClose(tcp, "204 No Content", cors: cors);
            }
            else if (method == "GET" && path == "/obs") await RespondAndClose(tcp, ObsOverlay, "text/html; charset=utf-8", cors);
            // Anahtar Authorize'da denetlendi (anahtarsız istek 401 aldı).
            else if (method == "GET" && path == SecondScreen.Path) await RespondAndClose(tcp, SecondScreen.Page, "text/html; charset=utf-8", cors);
            // TV uygulaması ağdaki bilgisayarı bu yanıtla tanır.
            else if (method == "GET" && path == "/hello") await RespondAndClose(tcp, "200 OK", HelloBody(InstanceId, ConnectedClients, SendsToTv && Pairing.InSession), cors);
            else if (method == "GET" && FindFile(path) is { } file) await RespondAndClose(tcp, file.Data, file.Type, cors);
            else await RespondAndClose(tcp, "404 Not Found", cors: cors);
        }
        catch
        {
            tcp.Dispose();
        }
    }

    /// <summary>Başlıkların sonuna (boş satır) kadar okur, ilk satırı döner. 64 KB'yi aşan istek kapatılır.</summary>
    private static async Task<string?> ReadRequestLine(Stream stream)
    {
        var buffer = new byte[8192];
        using var head = new MemoryStream();
        while (head.Length < 65536)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var count = await stream.ReadAsync(buffer, timeout.Token);
            if (count == 0) return null;
            head.Write(buffer, 0, count);
            var text = Encoding.ASCII.GetString(head.GetBuffer(), 0, (int)head.Length);
            var end = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
            if (end >= 0) return text[..end];
        }
        return null;
    }

    private (byte[] Data, string Type)? FindFile(string path)
    {
        lock (gate) return files.TryGetValue(path, out var file) ? file : null;
    }

    private static async Task RespondAndClose(TcpClient tcp, byte[] data, string type, string cors = "")
    {
        var head = $"HTTP/1.1 200 OK\r\n{cors}Content-Type: {type}\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n" +
                   $"Content-Length: {data.Length}\r\nConnection: close\r\n\r\n";
        var stream = tcp.GetStream();
        await stream.WriteAsync(Encoding.ASCII.GetBytes(head));
        await stream.WriteAsync(data);
        tcp.Dispose();
    }

    /// <summary>
    /// Ön istek (CORS preflight) yanıtı. Chromium'un yerel ağ erişimi denetimi (Private Network Access) yerel ağdaki
    /// sunucudan <c>Access-Control-Allow-Private-Network</c> ister; yeni tarayıcılı TV'ler (Tizen 9.0 ve sonrası) bu
    /// başlık olmadan bilgisayara bağlanmayabilir. Başlık eski TV'lerde yok sayılır.
    /// </summary>
    internal const string PreflightHeaders = "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n" +
                                             "Access-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 600\r\n";

    private static async Task RespondAndClose(TcpClient tcp, string status, string body = "", string cors = "")
    {
        var head = $"HTTP/1.1 {status}\r\n{cors}Cache-Control: no-store\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n{body}";
        await tcp.GetStream().WriteAsync(Encoding.ASCII.GetBytes(head));
        tcp.Dispose();
    }

    private async Task OpenStream(TcpClient tcp, bool viewer, string cors, string checkedKey, int? hdmi = null, bool legacy = false)
    {
        var head = new StringBuilder()
            .Append("HTTP/1.1 200 OK\r\n")
            .Append("Content-Type: text/event-stream; charset=utf-8\r\n")
            .Append("Cache-Control: no-cache\r\n")
            .Append("Connection: keep-alive\r\n")
            .Append(cors).Append("\r\n")
            .Append("retry: 2000\n\n");
        var client = new Client(tcp, viewer, legacy)
        {
            LinkId = viewer ? null : MakeLinkId(),
            Host = !viewer && tcp.Client.RemoteEndPoint is IPEndPoint peer ? SubtitleAccess.TvHost(peer.Address) : "",
        };
        int count;
        lock (gate)
        {
            // Yetki denetimi ile istemci kaydı arasındaki yenileme yarışını kapatır.
            if (accessKey != checkedKey) { tcp.Dispose(); return; }
            if (lastStyle is { } style) head.Append(StyleFrame(style, SetApart));
            // Kimlik stilden sonra: TV'ye ilk giden veri eskisi gibi stil olsun (olay sırası protokolü etkilemez).
            if (client.LinkId is { } link)
            {
                var json = new SortedDictionary<string, object> { ["id"] = link };
                if (ParseTvAppVersion(LatestTvAppVersion) is { Length: > 0 } latest) json["latest"] = latest;
                head.Append(Frame("link", json));
            }
            head.Append(RegionReplay(viewer || SendsToTv));
            clients.Add(client);
            if (hdmi is not null) consolePort = hdmi;
            count = TvCount();
        }
        await Write(client, head.ToString());
        ClientsChanged?.Invoke(count);
        await WatchForClose(client);
    }

    /// <summary>
    /// Yeni bağlanan TV'ye (ya da OBS'e) gösterilen ek alanlar: önce <c>region-sync</c> (listede olmayan alanları TV kaldırır;
    /// kopukken kaçan temizleme komutları), sonra her alanın son <c>region</c> olayı <c>keep</c> bayrağıyla (TV'de duran aynı
    /// alan yeniden çizilmez). <c>gate</c> altında çağrılır.
    /// </summary>
    private string RegionReplay(bool tv)
    {
        var live = tv && RegionsFresh() ? liveRegions.ToList() : [];
        var frames = new StringBuilder(Frame("region-sync", new SortedDictionary<string, object> { ["ids"] = live.Select(r => r.Key).ToList() }));
        foreach (var (_, data) in live) frames.Append(Frame("region", Kept(data)));
        return frames.ToString();
    }

    private static SortedDictionary<string, object> Kept(SortedDictionary<string, object> data) =>
        new(data) { ["keep"] = true };

    /// <summary>
    /// Gösterilen ek alanları (telefon kartı hariç) <c>keep</c> bayrağıyla yeniden gönderir: TV'de sahnede kalan yazının
    /// çevirisi 15 sn'lik ömrü dolup kalkmasın. Telefon kartı kendi takibiyle yenilenir.
    /// </summary>
    internal void RefreshRegions()
    {
        if (!RegionsFresh()) return;
        List<SortedDictionary<string, object>> live;
        lock (gate) live = [.. liveRegions.Where(r => r.Key != "game-phone").Select(r => Kept(r.Value))];
        foreach (var data in live) Broadcast(Frame("region", data), subtitle: true);
    }

    /// <summary><c>link</c> olayındaki bağlantı kimliği: tahmin edilemez, URL'de kaçışsız gider.</summary>
    internal static string MakeLinkId()
    {
        const string letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        return new string([.. Enumerable.Range(0, 16).Select(_ => letters[System.Security.Cryptography.RandomNumberGenerator.GetInt32(letters.Length)])]);
    }

    /// <summary>Bu kadar ping turu alındısız geçerse bağlantı kopmuş sayılır.</summary>
    internal const int AckMissLimit = 3;

    /// <summary>
    /// Bir ping turu (ping gönderilmeden hemen önce): son alındıdan beri <see cref="AckMissLimit"/> turdan fazla geçmiş TV
    /// bağlantılarını kapatır; kapattıysa true. #1055 (beta.86): süre saatle ölçülüyordu; zamanlayıcı gecikince (bilgisayar
    /// uykudan döndü, iş parçacığı havuzu tıkandı) ping gitmediği halde sağlam TV "susmuş" sayılıyordu. Artık alındısız
    /// geçen ping turları sayılır. <see cref="TvStale"/> da yalnız TV'den hiç bağlantı kalmadıysa tetiklenir: TV yeni akışını
    /// açmışken eski, yarı açık bağlantısının susması bekçiyi yenilemez (yenilenen bekçi LG'de açık uygulamayı yeniden
    /// başlatıyor, ekran kararıyordu). Mac/iPhone ve Android ile aynı.
    /// </summary>
    internal bool DropSilentTvs()
    {
        List<Client> silent = [];
        int remaining;
        lock (gate)
        {
            foreach (var client in clients)
            {
                if (client.AckMisses is not { } misses) continue;
                if (misses + 1 > AckMissLimit) silent.Add(client);
                else client.AckMisses = misses + 1;
            }
            remaining = clients.Count(c => !c.Viewer && !silent.Contains(c));
        }
        if (silent.Count == 0) return false;
        foreach (var client in silent) Remove(client);
        SubtitleLog.Write($"TV {AckMissLimit} ping turu alındı göndermedi: bağlantı kopmuş sayıldı, kapatıldı"
                          + (remaining > 0 ? " (TV'nin başka bağlantısı açık, bekçiye dokunulmadı)" : ""));
        if (remaining == 0) TvStale?.Invoke();
        return true;
    }

    /// <summary>İstemci bağlantıyı kapattığında listeden çıkarır.</summary>
    private async Task WatchForClose(Client client)
    {
        var buffer = new byte[1024];
        var why = "TV kapattı";
        try
        {
            while (await client.Stream.ReadAsync(buffer) > 0) { }
        }
        catch (Exception e) { why = "okuma hatası: " + e.GetBaseException().Message; }
        Remove(client, why);
    }

    /// <summary>Bağlantıyı listeden çıkarıp kapatır. <paramref name="why"/>: TV ya da ağ kapattıysa nedeni; TV akışıysa günlüğe
    /// yazılır (<see cref="TvClosedLine"/>). Kendi kapattığımız (alındısız, çıkış) bağlantılar kendi satırını yazar.</summary>
    private void Remove(Client client, string? why = null)
    {
        int count;
        lock (gate)
        {
            if (!clients.Remove(client)) return;
            count = TvCount();
        }
        if (why is not null && !client.Viewer)
        {
            var now = Environment.TickCount64;
            SubtitleLog.Write(TvClosedLine(why, client.Host, (now - client.OpenedAt) / 1000, client.AckAt is { } ack ? (now - ack) / 1000 : null));
        }
        client.Tcp.Dispose();
        ClientsChanged?.Invoke(count);
    }

    /// <summary>
    /// Gönderim hatası alan bağlantı kopmuş sayılır ve listeden çıkarılır. <paramref name="subtitle"/>: altyazı olayı;
    /// altyazı TV'ye gitmiyorsa yalnız izleyiciler (OBS) alır. Dublaj sesi ve ping her zaman herkese gider.
    /// </summary>
    /// <param name="legacy">null: herkes; false: sürüm bildirmeyen TV'ler dışındakiler; true: yalnız onlar.</param>
    private void Broadcast(string frame, bool subtitle = false, bool? legacy = null)
    {
        List<Client> targets;
        var toTvs = !subtitle || SendsToTv;
        lock (gate) targets = [.. clients.Where(c => (toTvs || c.Viewer) && (legacy is null || c.Legacy == legacy))];
        foreach (var client in targets)
            _ = Write(client, frame).ContinueWith(t => Remove(client, "yazma hatası: " + t.Exception?.GetBaseException().Message),
                                                  TaskContinuationOptions.OnlyOnFaulted);
    }

    private static async Task Write(Client client, string text)
    {
        await client.WriteLock.WaitAsync();
        try
        {
            await client.Stream.WriteAsync(Encoding.UTF8.GetBytes(text));
            await client.Stream.FlushAsync();
        }
        finally
        {
            client.WriteLock.Release();
        }
    }

    /// <summary>Sessizce kaybolan TV'ler (fişten çekme, Wi-Fi kopması) TCP canlılık denetimiyle fark edilir.</summary>
    private static void EnableKeepAlive(Socket socket)
    {
        try
        {
            socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveTime, 10);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveInterval, 5);
            socket.SetSocketOption(SocketOptionLevel.Tcp, SocketOptionName.TcpKeepAliveRetryCount, 3);
        }
        catch (SocketException) { }
    }

    private static string StyleFrame(SubtitleStyle style, bool setApart)
    {
        var json = new SortedDictionary<string, object>
        {
            ["background"] = Math.Clamp(style.Background, 0, 100),
            ["backgroundColor"] = style.BackgroundRgb,
            ["nameOnly"] = style.NameOnly,
            ["wholeLine"] = style.NameColorMode == NameColorMode.Line,
            ["backgroundShape"] = style.BackgroundShape.ToString().ToLowerInvariant(),
            ["bold"] = style.Bold,
            ["bottomPercent"] = style.BottomPercent,
            ["displayMode"] = style.DisplayMode switch
            {
                TvDisplayMode.Overlay => "overlay",
                TvDisplayMode.InAppOnly => "inAppOnly",
                _ => "inApp",
            },
            ["fontSize"] = style.FontSize,
            ["placement"] = style.Placement.ToString().ToLowerInvariant(),
            ["setApart"] = setApart,
            ["stackPrevious"] = style.StackPrevious,
            ["textColor"] = style.TextColor.ToString().ToLowerInvariant(),
        };
        // Yeni alanlar (TV 0.9.77+); eski TV tanımaz, eskisi gibi çizer.
        if (SubtitleStyle.Hex(style.TextHex) is { } text) json["textHex"] = text;
        if (style.HdmiInput is >= 1 and <= 4) json["hdmiInput"] = style.HdmiInput.Value;
        return Frame("style", json);
    }

    private static string Frame(string name, SortedDictionary<string, object> json) =>
        $"event: {name}\ndata: {JsonSerializer.Serialize(json, JsonOptions)}\n\n";
}
