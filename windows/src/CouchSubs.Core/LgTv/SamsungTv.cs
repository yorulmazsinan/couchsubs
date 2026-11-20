// SPDX-License-Identifier: AGPL-3.0-only

using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace CouchSubs.Core.LgTv;

/// <summary>Samsung uzaktan kumanda WebSocket'inin iletileri. Samsung bunu belgelemez; alanlar topluluk kaynaklarından.</summary>
public static class SamsungMessages
{
    public static Uri Url(string host, string? token)
    {
        var name = Convert.ToBase64String(Encoding.UTF8.GetBytes("CouchSubs"));
        var text = $"wss://{host}:8002/api/v2/channels/samsung.remote.control?name={name}";
        if (!string.IsNullOrEmpty(token)) text += $"&token={token}";
        return new Uri(text);
    }

    /// <summary>
    /// TV uygulaması parametreleri <c>PAYLOAD</c> içinde alır (bkz. tv-tizen/platform.js). <paramref name="actionType"/>
    /// TV'nin uygulama listesinde bildirdiği türe göre seçilir (<see cref="ActionType"/>); bilinmiyorsa DEEP_LINK.
    /// </summary>
    public static string Launch(string appId, IReadOnlyDictionary<string, string> parameters, string actionType = "DEEP_LINK") => new JsonObject
    {
        ["method"] = "ms.channel.emit",
        ["params"] = new JsonObject
        {
            ["event"] = "ed.apps.launch",
            ["to"] = "host",
            ["data"] = new JsonObject
            {
                ["appId"] = appId,
                ["action_type"] = actionType,
                ["metaTag"] = JsonSerializer.Serialize(parameters),
            },
        },
    }.ToJsonString();

    /// <summary>
    /// TV'de kurulu uygulamaların listesini ister. Yanıt aynı olay adıyla gelir; listede geliştirici modunda kurulan
    /// (mağazada olmayan) uygulamalar da bulunur.
    /// </summary>
    public const string InstalledAppsRequest =
        "{\"method\":\"ms.channel.emit\",\"params\":{\"event\":\"ed.installedApp.get\",\"to\":\"host\"}}";

    /// <summary>
    /// Kurulu uygulama listesi yanıtında <paramref name="appId"/> var mı. Yanıt bu değilse null; uygulama listede yoksa
    /// <see cref="SamsungAppPresence.Missing"/>, varsa TV'nin bildirdiği <c>app_type</c> ile <see cref="SamsungAppPresence.Installed"/>.
    /// </summary>
    public static SamsungAppPresence? InstalledApp(string text, string appId)
    {
        try
        {
            var node = JsonNode.Parse(text);
            if (node?["event"]?.GetValue<string>() != "ed.installedApp.get") return null;
            if (node["data"]?["data"] is not JsonArray apps) return null;
            foreach (var app in apps)
            {
                if (app?["appId"] is not JsonValue id || !id.TryGetValue<string>(out var value) || value != appId) continue;
                var type = app["app_type"] is JsonValue raw && raw.TryGetValue<int>(out var number) ? number : (int?)null;
                return SamsungAppPresence.Installed(type);
            }
            return SamsungAppPresence.Missing;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException) { return null; }
    }

    /// <summary>
    /// <c>ed.apps.launch</c> açılış türü: TV'nin listesinde <c>app_type</c> 4 (yerel Tizen uygulaması) NATIVE_LAUNCH,
    /// 2 (web uygulaması; CouchSubs .wgt paketi) ve bilinmeyen DEEP_LINK. Yanlış tür verilince Smart Hub uygulamayı
    /// mağazada aramaya kalkıyor.
    /// </summary>
    public static string ActionType(int? appType) => appType == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK";

    /// <summary>
    /// Bağlantı sonucu: onaylandıysa jeton (TV vermediyse boş), başka iletiyse null. Reddedildiyse ya da TV'deki izin
    /// sorusu yanıtsız kaldıysa (<c>ms.channel.timeOut</c>; 60 saniye boşuna beklenmez) hata.
    /// </summary>
    public static string? ConnectResult(string text)
    {
        JsonNode? node;
        try { node = JsonNode.Parse(text); } catch (JsonException) { return null; }
        return node?["event"]?.GetValue<string>() switch
        {
            "ms.channel.connect" => node["data"]?["token"]?.GetValue<string>() ?? "",
            "ms.channel.unauthorized" => throw new SsapException("rejected"),
            "ms.channel.timeOut" => throw new SsapException("cannot connect"),
            _ => null,
        };
    }

    /// <summary><c>http://TV:8001/api/v2/</c> yanıtındaki TV adı.</summary>
    public static string? DeviceName(string json)
    {
        try { return JsonNode.Parse(json)?["device"]?["name"]?.GetValue<string>()?.Replace("&quot;", "\""); }
        catch (JsonException) { return null; }
    }

    /// <summary>
    /// <c>http://TV:8001/api/v2/</c> yanıtında geliştirici modu açık mı (<c>device.developerMode</c>: "1" ya da "0");
    /// alan yoksa ya da yanıt okunamazsa null (eski TV'ler bildirmez, kurulum yine denenir).
    /// </summary>
    public static bool? DeveloperMode(string json)
    {
        var value = DeviceField(json, "developerMode");
        if (value is null) return null;
        return value == "1" || value.Equals("true", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// TV'nin geliştirici modunda girilen "Host PC IP" (<c>device.developerIP</c>); TV yalnız bu adresten gelen sdb
    /// bağlantısını kabul eder. Boşsa ya da "0.0.0.0" ise null.
    /// </summary>
    public static string? DeveloperIp(string json) => DeviceField(json, "developerIP") is { } ip && ip != "0.0.0.0" ? ip : null;

    /// <summary>
    /// TV'deki Host PC IP bu bilgisayarın adresinden farklı mı? İkisinden biri bilinmiyorsa farklı sayılmaz (kurulum
    /// denenir). Farklıysa TV 26101'deki sdb el sıkışmasında bağlantıyı keser (#343).
    /// </summary>
    public static bool HostPcIpMismatch(string? developerIp, string? computerAddress) =>
        !string.IsNullOrWhiteSpace(developerIp) && !string.IsNullOrWhiteSpace(computerAddress) &&
        !string.Equals(developerIp.Trim(), computerAddress.Trim(), StringComparison.Ordinal);

    private static string? DeviceField(string json, string name)
    {
        try
        {
            if (JsonNode.Parse(json)?["device"]?[name] is not JsonValue value) return null;
            var text = (value.TryGetValue<string>(out var s) ? s : value.ToJsonString()).Trim();
            return text.Length > 0 ? text : null;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException) { return null; }
    }
}

/// <summary>
/// CouchSubs TV uygulamasının kurulu olduğu bilinen Samsung TV'ler: uygulama o TV'den daha önce bağlandı ya da bu cihaz
/// oraya kurdu. Böyle bir TV'de açma komutundan önce TV'nin kurulu uygulama listesine bakılmaz (bkz.
/// <see cref="SamsungClient.LaunchAsync"/>): listenin geliştirici moduyla kurulan uygulamayı içerdiği gerçek TV'de
/// doğrulanmadı; içermiyorsa bekçi uygulamayı hiç açmıyor, TV kendi girişine geçince (Anynet+) altyazı geri gelmiyordu.
/// Uygulama katmanı bilgiyi yükler (<see cref="Mark"/>) ve değişince saklar (<see cref="Changed"/>).
/// </summary>
public static class SamsungAppKnowledge
{
    private static readonly HashSet<string> hosts = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Yeni bir TV "kurulu" olarak işaretlendi (saklamak için).</summary>
    public static Action<string>? Changed { get; set; }
    /// <summary>Sahadan öğrenmek için günlük satırı (ör. liste "yok" diyor ama uygulama daha önce bağlandı).</summary>
    public static Action<string>? Log { get; set; }

    public static bool IsKnown(string? host)
    {
        if (string.IsNullOrWhiteSpace(host)) return false;
        lock (hosts) return hosts.Contains(host.Trim());
    }

    /// <summary>TV uygulaması bu TV'de kurulu: bağlandı ya da kuruldu. Yeni bilgiyse <see cref="Changed"/> çağrılır.</summary>
    public static void Mark(string? host, bool notify = true)
    {
        if (string.IsNullOrWhiteSpace(host)) return;
        bool added;
        lock (hosts) added = hosts.Add(host.Trim());
        if (added && notify) Changed?.Invoke(host.Trim());
    }

    public static void Forget(string? host)
    {
        if (string.IsNullOrWhiteSpace(host)) return;
        lock (hosts) hosts.Remove(host.Trim());
    }

    /// <summary>Açma komutundan önce TV'nin kurulu uygulama listesine bakılsın mı: yalnız kurulu olduğu bilinmeyen TV'de.</summary>
    public static bool ChecksList(bool knownInstalled) => !knownInstalled;

    /// <summary>
    /// Açma kararı. Kurulu olduğu bilinen TV'de liste ne derse desin eski yol (DEEP_LINK) gönderilir; bilinmeyen TV'de
    /// listede yoksa gönderilmez (#637), liste yanıtsızsa DEEP_LINK. Dönen değer gönderilecek tür, gönderilmeyecekse null.
    /// </summary>
    public static string? ActionFor(bool knownInstalled, SamsungAppPresence? presence)
    {
        if (knownInstalled) return "DEEP_LINK";
        if (presence is { IsInstalled: false }) return null;
        return SamsungMessages.ActionType(presence?.AppType);
    }
}

/// <summary>TV'nin kurulu uygulama listesine göre CouchSubs TV uygulamasının durumu.</summary>
public sealed record SamsungAppPresence(bool IsInstalled, int? AppType)
{
    public static readonly SamsungAppPresence Missing = new(false, null);
    public static SamsungAppPresence Installed(int? appType) => new(true, appType);
}

/// <summary>Samsung TV'nin 8001 yanıtındaki geliştirici modu bilgisi.</summary>
/// <param name="DeveloperMode">Geliştirici modu açık mı; TV bildirmezse null.</param>
/// <param name="DeveloperIp">TV'deki "Host PC IP"; boşsa null.</param>
public sealed record SamsungDeveloperInfo(bool? DeveloperMode, string? DeveloperIp);

/// <summary>
/// Bekçinin (TvKeeper) Samsung bağlantılarında kullandığı jeton. TV yeni jeton verirse bir sonraki bağlantı onu kullanır
/// ve <paramref name="onChange"/> ile saklanır; önceden yalnız eşleşmedeki jeton kullanılıyor, sonradan gelen atılıyordu.
/// </summary>
public sealed class SamsungTokenHolder(string? token, Action<string> onChange)
{
    private readonly Lock gate = new();
    private string? token = token;

    public string? Current { get { lock (gate) return token; } }

    /// <summary>Bağlantıda TV'nin döndüğü jeton; boşsa ya da aynıysa bir şey değişmez.</summary>
    public void Received(string value)
    {
        lock (gate)
        {
            var kept = KeptToken(token, value);
            if (kept == (token ?? "")) return;
            token = kept;
        }
        onChange(value);
    }

    /// <summary>
    /// Saklanacak jeton. TV yeni jeton verdiyse o; vermediyse (boş döndü, bazı TV'ler jetonla gelen bağlantıda yeniden
    /// göndermez) eldeki korunur. Boş jeton eldekinin üstüne yazılınca sonraki her bağlantıda TV yeniden izin soruyordu (#40).
    /// </summary>
    public static string KeptToken(string? stored, string received) => received.Length == 0 ? stored ?? "" : received;
}

/// <summary>Samsung TV ile uzaktan kumanda WebSocket'i üzerinden konuşur. İlk bağlantıda TV izin sorar.</summary>
public sealed class SamsungClient(Uri url, TimeSpan? approvalTimeout = null) : ITvControl
{
    public const string AppId = "CouchSubsT.CouchSubs";

    private ClientWebSocket? socket;
    private readonly string? host;
    /// <summary>Liste "yok" dediği hâlde bağlanmış uygulama günlüğe çalışma boyunca bir kez yazılır.</summary>
    private static int probed;

    public SamsungClient(LgTv tv, string? token) : this(SamsungMessages.Url(tv.Host, token)) { host = tv.Host; }

    /// <summary>
    /// TV uygulamasının bu TV'de kurulu olduğu biliniyor mu; verilmezse <see cref="SamsungAppKnowledge"/>'a sorulur.
    /// </summary>
    public bool? KnownInstalled { get; init; }

    /// <summary>Bağlanır ve jetonu döner. Kullanıcı TV'de onay verene kadar bekler.</summary>
    public async Task<string> ConnectAsync(CancellationToken cancellationToken = default)
    {
        var candidate = new ClientWebSocket();
        // TV'nin 8002 portundaki sertifikası kendinden imzalıdır; bu bağlantı yalnız TV'nin adresine gider.
        candidate.Options.RemoteCertificateValidationCallback = (_, _, _, _) => true;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(approvalTimeout ?? TimeSpan.FromSeconds(60));
        try
        {
            await candidate.ConnectAsync(url, timeout.Token);
            var buffer = new byte[8192];
            while (true)
            {
                var text = new StringBuilder();
                WebSocketReceiveResult result;
                do
                {
                    result = await candidate.ReceiveAsync(buffer, timeout.Token);
                    if (result.MessageType == WebSocketMessageType.Close) throw new SsapException("cannot connect");
                    text.Append(Encoding.UTF8.GetString(buffer, 0, result.Count));
                } while (!result.EndOfMessage);
                if (SamsungMessages.ConnectResult(text.ToString()) is { } token)
                {
                    socket = candidate;
                    return token;
                }
            }
        }
        catch
        {
            candidate.Dispose();
            throw;
        }
    }

    /// <summary>
    /// TV uygulamasını uzaktan kumanda bağlantısıyla açar. Açma yolları (bekçide geliştirici bağlantısı önce denenir):
    /// <list type="number">
    /// <item>sdb <c>0 was_execute</c> (SamsungTvInstaller.OpenAsync): Tizen 2.4 ve sonrası (2016 K serisinden bu yana),
    /// geliştirici modu açık ve Host PC IP bu cihazsa. Smart Hub'dan geçmez, mağaza denetimi yok; PAYLOAD taşımaz, TV
    /// uygulaması bilgisayarı kendisi bulur.</item>
    /// <item>Bu yöntem: önce <c>ed.installedApp.get</c> ile uygulamanın kurulu olduğuna bakılır, sonra
    /// <c>ed.apps.launch</c> TV'nin bildirdiği türle (web uygulamasında DEEP_LINK) gönderilir. 2016 ve sonrası Tizen
    /// TV'lerde çalışır. Uygulama kurulu değilken DEEP_LINK gönderilirse Smart Hub appId'yi mağazada arıyor ve mağazada
    /// olmayan CouchSubs için TV'de "Sunucu bakım altında (1544007)" çıkıyordu (#402'de kurulum 118 hatasıyla düşmüştü;
    /// #511, #637). Bu yüzden listede yoksa hiçbir şey gönderilmez. Liste 3 saniyede gelmezse (bazı yazılımlar
    /// yanıtlamıyor) eski yol, DEEP_LINK denenir.</item>
    /// </list>
    /// REST <c>POST http://TV:8001/api/v2/applications/&lt;id&gt;</c> kullanılmaz: PAYLOAD taşımaz ve 2019 sonrası
    /// yazılımlarda izinsiz istekleri reddediyor.
    /// </summary>
    public async Task LaunchAsync(string appId, IReadOnlyDictionary<string, string> parameters, CancellationToken cancellationToken = default)
    {
        if (socket is null) throw new SsapException("cannot connect");
        // Uygulama bu TV'den daha önce bağlandıysa ya da bu cihaz kurduysa listeye bakılmaz, eskisi gibi doğrudan açılır:
        // listenin geliştirici moduyla kurulan uygulamayı içerdiği gerçek TV'de doğrulanmadı (beta.63'te içermeyen TV'de
        // bekçi uygulamayı hiç açmıyordu).
        var known = KnownInstalled ?? SamsungAppKnowledge.IsKnown(host);
        if (!SamsungAppKnowledge.ChecksList(known))
        {
            var direct = Encoding.UTF8.GetBytes(SamsungMessages.Launch(appId, parameters, SamsungAppKnowledge.ActionFor(true, null)!));
            await socket.SendAsync(direct, WebSocketMessageType.Text, true, cancellationToken);
            await ProbeListAsync(socket, appId, cancellationToken);
            return;
        }
        var presence = await InstalledAppAsync(socket, appId, cancellationToken);
        if (SamsungAppKnowledge.ActionFor(false, presence) is null) throw new SsapException("not installed");
        if (socket.State != WebSocketState.Open)
        {
            // Zaman aşımında iptal edilen okuma ClientWebSocket'i kapatır; DEEP_LINK yeni bağlantıyla gider (jeton aynı,
            // TV yeniden sormaz).
            socket.Dispose();
            socket = null;
            await ConnectAsync(cancellationToken);
            if (socket is null) throw new SsapException("cannot connect");
        }
        var data = Encoding.UTF8.GetBytes(SamsungMessages.Launch(appId, parameters, SamsungMessages.ActionType(presence?.AppType)));
        await socket.SendAsync(data, WebSocketMessageType.Text, true, cancellationToken);
    }

    /// <summary>
    /// Sahadan öğrenmek için: kurulu olduğu bilinen TV'de açma komutu gittikten sonra listeye bir kez bakılır; liste
    /// uygulamayı içermiyorsa günlüğe yazılır. Sonucu açmayı etkilemez, hata vermez.
    /// </summary>
    private async Task ProbeListAsync(ClientWebSocket open, string appId, CancellationToken cancellationToken)
    {
        if (SamsungAppKnowledge.Log is not { } log || Interlocked.Exchange(ref probed, 1) != 0) return;
        try
        {
            var presence = await InstalledAppAsync(open, appId, cancellationToken);
            log(presence switch
            {
                null => $"Samsung {host}: kurulu uygulama listesi yanıtsız; uygulama daha önce bağlandığı için doğrudan açıldı.",
                { IsInstalled: false } => $"Samsung {host}: kurulu uygulama listesinde CouchSubs YOK ama uygulama daha önce bağlandı/kuruldu; doğrudan açıldı.",
                _ => $"Samsung {host}: kurulu uygulama listesinde CouchSubs var (app_type {presence.AppType?.ToString() ?? "?"}).",
            });
        }
        catch (Exception) { /* yalnız günlük içindir */ }
    }

    /// <summary>TV'nin kurulu uygulama listesine göre durum; TV <paramref name="timeout"/> içinde yanıtlamazsa null.</summary>
    private static async Task<SamsungAppPresence?> InstalledAppAsync(ClientWebSocket socket, string appId, CancellationToken cancellationToken,
                                                                    TimeSpan? timeout = null)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(timeout ?? TimeSpan.FromSeconds(3));
        try
        {
            await socket.SendAsync(Encoding.UTF8.GetBytes(SamsungMessages.InstalledAppsRequest), WebSocketMessageType.Text, true, limit.Token);
            var buffer = new byte[65536];
            while (true)
            {
                using var text = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(buffer, limit.Token);
                    if (result.MessageType == WebSocketMessageType.Close) return null;
                    text.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);
                if (SamsungMessages.InstalledApp(Encoding.UTF8.GetString(text.ToArray()), appId) is { } presence) return presence;
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return null; }
        catch (WebSocketException) { return null; }
    }

    /// <summary>Samsung önplandaki uygulamayı söylemez; bağlantı ayakta mı diye bakılır, boş döner.</summary>
    public Task<string> ForegroundAppIdAsync(CancellationToken cancellationToken = default) =>
        socket is { State: WebSocketState.Open } ? Task.FromResult("") : throw new SsapException("cannot connect");

    public void Dispose()
    {
        socket?.Abort();
        socket?.Dispose();
        socket = null;
    }
}

/// <summary>Yerel ağdaki Samsung TV'leri SSDP ile bulur.</summary>
public static class SamsungDiscovery
{
    internal const string SearchTarget = "urn:samsung.com:device:RemoteControlReceiver:1";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(2) };

    /// <summary>TV'nin geliştirici modu bilgisi (<c>http://TV:8001/api/v2/</c>); TV yanıt vermezse null.</summary>
    public static async Task<SamsungDeveloperInfo?> DeveloperInfoAsync(string host, CancellationToken cancellationToken = default)
    {
        try
        {
            var json = await Http.GetStringAsync($"http://{host}:8001/api/v2/", cancellationToken);
            return new SamsungDeveloperInfo(SamsungMessages.DeveloperMode(json), SamsungMessages.DeveloperIp(json));
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or InvalidOperationException or UriFormatException)
        {
            return null;
        }
    }

    /// <summary>Adresteki Samsung TV'nin adı (8001'de kendini tanıtırsa); değilse null.</summary>
    public static async Task<string?> DeviceNameAsync(string host, CancellationToken cancellationToken = default)
    {
        try { return SamsungMessages.DeviceName(await Http.GetStringAsync($"http://{host}:8001/api/v2/", cancellationToken)); }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or InvalidOperationException or UriFormatException)
        {
            return null;
        }
    }

    public static async Task<IReadOnlyList<LgTv>> SearchAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        var hosts = await LgDiscovery.CollectResponses(SearchTarget, timeout ?? TimeSpan.FromSeconds(3), cancellationToken);
        var tvs = new List<LgTv>();
        foreach (var host in hosts.Distinct().Order(StringComparer.Ordinal))
        {
            string? name = null;
            try { name = SamsungMessages.DeviceName(await Http.GetStringAsync($"http://{host}:8001/api/v2/", cancellationToken)); }
            catch (Exception) { /* ad okunamazsa genel ad kullanılır */ }
            tvs.Add(new LgTv(name ?? "Samsung TV", host, TvBrand.Samsung));
        }
        if (tvs.Count > 0) return tvs;

        // SSDP yanıtı gelmediyse (bazı modemler ve TV'ler çok noktaya yayını geçirmez) ağdaki adresler tek tek denenir:
        // Samsung TV 8001 portunda kendi adını veren bir arayüz sunar.
        foreach (var host in await LocalNetwork.HostsWithOpenPortAsync(8001, TimeSpan.FromMilliseconds(700), cancellationToken))
        {
            try
            {
                if (SamsungMessages.DeviceName(await Http.GetStringAsync($"http://{host}:8001/api/v2/", cancellationToken)) is { } name)
                    tvs.Add(new LgTv(name, host, TvBrand.Samsung));
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException) { }
        }
        return tvs;
    }
}
