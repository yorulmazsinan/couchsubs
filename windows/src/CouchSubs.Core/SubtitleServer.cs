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
public sealed record SubtitleStyle(
    int FontSize = 46,
    int BottomPercent = 7,
    SubtitlePlacement Placement = SubtitlePlacement.Cover,
    int Background = 90,
    bool Bold = false,
    SubtitleTextColor TextColor = SubtitleTextColor.White,
    TvDisplayMode DisplayMode = TvDisplayMode.InApp,
    bool StackPrevious = true,
    SubtitleBackgroundShape BackgroundShape = SubtitleBackgroundShape.Fit);

/// <summary>
/// Android TV'de PS5 görüntüsünün nasıl gösterildiği. Yalnız Android TV uygulaması kullanır; diğer TV'ler ve OBS
/// katmanı alanı tanımaz.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<TvDisplayMode>))]
public enum TvDisplayMode
{
    /// <summary>HDMI CouchSubs'ın içinde; görüntü hiç gelmezse TV uygulaması kendiliğinden katmana geçer.</summary>
    InApp,
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
}

/// <summary>
/// <c>Screen</c>: "ekranı çevir" sonuçları (metin: grupların çevirisi, yukarıdan aşağı, her biri ayrı satırda);
/// <c>ScreenClear</c>: onların kaldırılması. Bilgisayardaki altyazı penceresi bunları da gösterir.
/// </summary>
public enum SubtitleEventKind { Subtitle, Clear, Screen, ScreenClear, Region, RegionClear }

/// <summary>Sunucudan geçen ve bilgisayar ekranındaki altyazı penceresinin de gösterdiği olay.</summary>
/// <param name="Replaces">Satır öncekinin uzamış ya da düzelmiş okumasıdır; öncekinin üstüne yığılmaz, yerine geçer.</param>
/// <param name="Id">Ek alan olayında alanın kimliği (<see cref="SubtitleEventKind.Region"/>; metin boşsa kutu kalkar).</param>
/// <param name="Box">Ek alan olayında yazının karedeki yeri.</param>
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
    bool allowLegacy = SubtitleAccess.AllowLegacyClients) : ISubtitleSender, IRegionSender, IDisposable
{
    private string accessKey = key ?? SubtitleAccess.CreateKey();
    public SubtitlePairing Pairing { get; } = new();
    public event Action<SubtitlePairing.Ticket>? PairingRequested;
    private int legacySeen;
    public event Action? LegacyClientConnected;
    public string AccessKey { get { lock (gate) return accessKey; } }
    public bool HasLegacyClient => Volatile.Read(ref legacySeen) != 0;

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
    private sealed class Client(TcpClient tcp, bool viewer = false)
    {
        public TcpClient Tcp { get; } = tcp;
        /// <summary>OBS katmanı gibi TV olmayan izleyici: olayları alır ama "TV bağlı" sayısına katılmaz.</summary>
        public bool Viewer { get; } = viewer;
        public Stream Stream { get; } = tcp.GetStream();
        /// <summary>Aynı bağlantıya iki yazma iç içe geçmesin.</summary>
        public SemaphoreSlim WriteLock { get; } = new(1, 1);
    }

    /// <summary>Bu kurulumun kalıcı kimliği (<c>/hello</c> yanıtında). Aynı ağda iki CouchSubs varken TV uygulaması kendi
    /// bilgisayarını ya da telefonunu adres değişse de bununla tanır; eskiden ağda ilk bulduğuna bağlanıyordu (GitHub #425).</summary>
    public string InstanceId { get; init; } = InstallationId.Value;

    private static readonly Lazy<string> InstallationId = new(LoadInstallationId);

    /// <summary>Kimlik ilk istekte rastgele üretilir ve %LOCALAPPDATA%\CouchSubs\server-id dosyasında saklanır (Linux:
    /// ~/.local/share/CouchSubs). Dosya yazılamazsa kimlik bu çalışmalık kalır.</summary>
    private static string LoadInstallationId()
    {
        var path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "server-id");
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
    internal static string HelloBody(string id, int tvs) => $"{{\"app\":\"couchsubs\",\"auth\":1,\"id\":\"{HelloId(id)}\",\"tvs\":{Math.Max(0, tvs)}}}";

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

    private readonly object gate = new();
    private readonly List<Client> clients = [];
    private TcpListener? listener;
    private Timer? pingTimer;
    private SubtitleStyle? lastStyle;
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
    /// Konuşana göre renk: açıkken <c>subtitle</c> olayı satır başındaki konuşan adlarını ve renklerini <c>speakers</c>
    /// alanında taşır (<see cref="Core.SpeakerColors"/>); kapalıyken ya da metinde ad yoksa alan yazılmaz. Eski TV
    /// uygulamaları alanı yok sayar.
    /// </summary>
    public bool SpeakerColors { get; set; }

    public int ConnectedClients
    {
        get { lock (gate) return TvCount(); }
    }

    private int TvCount() => clients.Count(c => !c.Viewer);

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
        pingTimer = new Timer(_ => Broadcast(PingFrame), null, every, every);
        return Task.FromResult(((IPEndPoint)listener.LocalEndpoint).Port);
    }

    public void Stop()
    {
        Pairing.SetSession(false);
        pingTimer?.Dispose();
        pingTimer = null;
        listener?.Stop();
        listener = null;
        List<Client> closing;
        lock (gate)
        {
            closing = [.. clients];
            clients.Clear();
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
        if (SpeakerColors && Core.SpeakerColors.Speakers(text) is { Count: > 0 } speakers)
            json["speakers"] = speakers.Select(name => new SortedDictionary<string, object> { ["name"] = name, ["color"] = Core.SpeakerColors.Color(name) }).ToList();
        Broadcast(Frame("subtitle", json), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.Subtitle, text, durationMs, paragraphs, replaces));
    }

    /// <summary>Dört basamağa yuvarlanır (decimal: JSON'da 0.8 olarak yazılsın).</summary>
    /// Bölme sondaki sıfırları atar (0.8750 → 0.875).
    private static decimal Round(double value) =>
        Math.Round((decimal)Math.Clamp(value, 0, 1), 4) / 1.000000000000000000000000000000000m;

    public void Clear()
    {
        Broadcast(Frame("clear", new SortedDictionary<string, object>()), subtitle: true);
        EventSent?.Invoke(SubtitleEvent.Cleared);
    }

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
        var list = items.Select(item => ItemJson(item, phone: false)).ToList();
        Broadcast(Frame("screen", new SortedDictionary<string, object> { ["duration"] = durationMs, ["items"] = list }), subtitle: true);
        // Altyazı yalnız bilgisayardaysa (TV yok) çeviriler başka hiçbir yere gitmiyordu: tuşa basınca yalnız
        // "Ekran çevriliyor…" görünüyordu.
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.Screen, string.Join('\n', items.Select(item => item.Translation)), durationMs,
                                            Paragraphs: true));
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
        Broadcast(Frame("region", RegionData(id, text, box, lineHeight, icons, blocks)), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.Region, text, Id: id, Box: box,
                                            Blocks: blocks is { Count: > 0 } && text.Length > 0 ? blocks : null));
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
        Broadcast(Frame("region-clear", new SortedDictionary<string, object>()), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.RegionClear));
    }

    /// <summary>TV'deki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz).</summary>
    public void ClearScreen()
    {
        Broadcast(Frame("screen-clear", new SortedDictionary<string, object>()), subtitle: true);
        EventSent?.Invoke(new SubtitleEvent(SubtitleEventKind.ScreenClear));
    }

    /// <summary>Yeriyle bir çeviri ("Ekranı çevir" öğesi ya da ek alan bloğu).</summary>
    private static SortedDictionary<string, object> ItemJson(ScreenTranslation.Item item, bool phone)
    {
        var json = new SortedDictionary<string, object>
        {
            ["box"] = BoxJson(item.Box),
            ["line"] = Round(item.LineHeight),
            ["text"] = item.Translation,
        };
        if (item.Paragraphs) json["paragraphs"] = true;
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
        Broadcast(StyleFrame(style), subtitle: true);
    }

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
            if (status != 200) { await RespondAndClose(tcp, status == 403 ? "403 Forbidden" : "401 Unauthorized", cors: status == 403 ? "" : cors); return; }
            var method = request.Method;
            var path = request.Path;
            if (path == "/pair")
            {
                if (method == "POST")
                {
                    var ticket = Pairing.Begin();
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
                        body = JsonSerializer.Serialize(new { state, key = state == "approved" ? accessKey : null });
                    }
                    await RespondAndClose(tcp, "200 OK", body, cors);
                }
                else await RespondAndClose(tcp, "405 Method Not Allowed", cors: cors);
                return;
            }
            if (method == "OPTIONS") await RespondAndClose(tcp, "204 No Content", cors: cors + PreflightHeaders);
            else if (method == "GET" && path == "/events")
            {
                var obs = request.Parameter("viewer") == "obs";
                // Anahtarsız OBS sayfası eski bir OBS adresidir; TV uygulamasının eski olduğu anlamına gelmez.
                if (legacy && !obs && Interlocked.Exchange(ref legacySeen, 1) == 0) LegacyClientConnected?.Invoke();
                await OpenStream(tcp, obs, cors, checkedKey);
            }
            else if (method == "GET" && path == "/obs") await RespondAndClose(tcp, ObsOverlay, "text/html; charset=utf-8", cors);
            // TV uygulaması ağdaki bilgisayarı bu yanıtla tanır.
            else if (method == "GET" && path == "/hello") await RespondAndClose(tcp, "200 OK", HelloBody(InstanceId, ConnectedClients), cors);
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

    private async Task OpenStream(TcpClient tcp, bool viewer, string cors, string checkedKey)
    {
        var head = new StringBuilder()
            .Append("HTTP/1.1 200 OK\r\n")
            .Append("Content-Type: text/event-stream; charset=utf-8\r\n")
            .Append("Cache-Control: no-cache\r\n")
            .Append("Connection: keep-alive\r\n")
            .Append(cors).Append("\r\n")
            .Append("retry: 2000\n\n");
        var client = new Client(tcp, viewer);
        int count;
        lock (gate)
        {
            // Yetki denetimi ile istemci kaydı arasındaki yenileme yarışını kapatır.
            if (accessKey != checkedKey) { tcp.Dispose(); return; }
            if (lastStyle is { } style) head.Append(StyleFrame(style));
            clients.Add(client);
            count = TvCount();
        }
        await Write(client, head.ToString());
        ClientsChanged?.Invoke(count);
        await WatchForClose(client);
    }

    /// <summary>İstemci bağlantıyı kapattığında listeden çıkarır.</summary>
    private async Task WatchForClose(Client client)
    {
        var buffer = new byte[1024];
        try
        {
            while (await client.Stream.ReadAsync(buffer) > 0) { }
        }
        catch { }
        Remove(client);
    }

    private void Remove(Client client)
    {
        int count;
        lock (gate)
        {
            if (!clients.Remove(client)) return;
            count = TvCount();
        }
        client.Tcp.Dispose();
        ClientsChanged?.Invoke(count);
    }

    /// <summary>
    /// Gönderim hatası alan bağlantı kopmuş sayılır ve listeden çıkarılır. <paramref name="subtitle"/>: altyazı olayı;
    /// altyazı TV'ye gitmiyorsa yalnız izleyiciler (OBS) alır. Dublaj sesi ve ping her zaman herkese gider.
    /// </summary>
    private void Broadcast(string frame, bool subtitle = false)
    {
        List<Client> targets;
        var toTvs = !subtitle || SendsToTv;
        lock (gate) targets = [.. clients.Where(c => toTvs || c.Viewer)];
        foreach (var client in targets)
            _ = Write(client, frame).ContinueWith(t => Remove(client), TaskContinuationOptions.OnlyOnFaulted);
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

    private static string StyleFrame(SubtitleStyle style) =>
        Frame("style", new SortedDictionary<string, object>
        {
            ["background"] = Math.Clamp(style.Background, 0, 100),
            ["backgroundShape"] = style.BackgroundShape.ToString().ToLowerInvariant(),
            ["bold"] = style.Bold,
            ["bottomPercent"] = style.BottomPercent,
            ["displayMode"] = style.DisplayMode == TvDisplayMode.Overlay ? "overlay" : "inApp",
            ["fontSize"] = style.FontSize,
            ["placement"] = style.Placement.ToString().ToLowerInvariant(),
            ["stackPrevious"] = style.StackPrevious,
            ["textColor"] = style.TextColor.ToString().ToLowerInvariant(),
        });

    private static string Frame(string name, SortedDictionary<string, object> json) =>
        $"event: {name}\ndata: {JsonSerializer.Serialize(json, JsonOptions)}\n\n";
}
