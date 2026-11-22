// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.Sockets;
using System.Text;

namespace CouchSubs.Core.LgTv;

public enum TvBrand
{
    Lg,
    Samsung,
    /// <summary>Android TV: bilgisayar TV'yi denetlemez, TV uygulaması bilgisayarı kendisi bulur.</summary>
    AndroidTv,
}

/// <param name="Brand">Eski kayıtlarda marka yoktur; hepsi LG'dir.</param>
public sealed record LgTv(string Name, string Host, TvBrand Brand = TvBrand.Lg);

/// <summary>Elle yazılan adresteki TV. <c>Recognised</c>: türünü TV kendisi söyledi; değilse LG sayıldı ve kullanıcıya söylenir.</summary>
public sealed record ManualTv(LgTv Tv, bool Recognised);

/// <summary>Yerel ağdaki LG webOS TV'leri SSDP ile bulur.</summary>
public static class LgDiscovery
{
    internal const string SearchTarget = "urn:lge-com:service:webos-second-screen:1";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(2) };

    /// <summary>Yedek arama: webOS 3.x (2017) TV'ler ikinci ekran hedefine cevap vermiyor, "ssdp:all"a veriyor (#498).</summary>
    internal const string AllTarget = "ssdp:all";

    public static async Task<IReadOnlyList<LgTv>> SearchAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        var wait = timeout ?? TimeSpan.FromSeconds(3);
        var hits = await CollectHits(SearchTarget, wait, cancellationToken);
        // Cevap yoksa eski webOS için "ssdp:all": hem çok noktaya yayınla hem ağdaki her adrese tek tek (o TV yalnız
        // doğrudan gönderilen aramaya cevap verdi).
        if (hits.Count == 0)
            hits = await CollectHits(AllTarget, wait, cancellationToken,
                LocalNetwork.ScanTargets(LocalNetwork.PrivateAddresses()).ToList());
        var tvs = new List<LgTv>();
        foreach (var group in hits.GroupBy(hit => hit.Host).OrderBy(group => group.Key, StringComparer.Ordinal))
        {
            var host = group.Key;
            if (group.Any(hit => hit.Confirmed))
            {
                tvs.Add(new LgTv(await FriendlyName(host) ?? "LG TV", host));
                continue;
            }
            var description = DescriptionAsync(host);
            var greeting = GreetingAsync(host);
            var android = Task.WhenAll(AndroidPorts.Select(port => IsPortOpenAsync(host, port)));
            var xml = await description;
            if (ClassifyUnconfirmed(host, LgNameIn(xml),
                    IsSsapGreeting(await greeting), (await android).Any(open => open)) is { } tv)
                tvs.Add(tv);
        }
        return tvs;
    }

    /// <summary>
    /// LG olduğunu SSDP yanıtında söylemeyen adres (yalnız sorulan hedefi geri söyledi; bkz. <see cref="SsdpHit"/>): LG
    /// cihaz tanımı ya da ikinci ekran sunucusu tanırsa LG, Android TV portu açıksa Android TV, hiçbiri değilse listelenmez.
    /// Önceden böyle bir adres (Mac'te görülen: Android TV) "LG TV" diye listeleniyor, Bağlan LG eşleştirmesi deneyip
    /// "TV yanıt vermedi" diyordu; LG bekçisinin taraması da onu kapalı LG'nin "yeni adresi" sanabiliyordu (TvLocator).
    /// </summary>
    public static LgTv? ClassifyUnconfirmed(string host, string? lgName, bool ssapGreeting, bool androidPortOpen)
    {
        if (lgName is not null) return new LgTv(lgName, host);
        if (ssapGreeting) return new LgTv("LG TV", host);
        return androidPortOpen ? new LgTv("Android TV", host, TvBrand.AndroidTv) : null;
    }

    /// <summary>webOS cihaz tanımı mı (üretici LG ya da model webOS; Mac: LGDiscovery.isLGDescription).</summary>
    internal static bool IsLgDescription(string xml) =>
        xml.Contains("<device", StringComparison.OrdinalIgnoreCase) &&
        (xml.Contains("lg electronics", StringComparison.OrdinalIgnoreCase) || xml.Contains("webos", StringComparison.OrdinalIgnoreCase));

    /// <summary>webOS'un ikinci ekran (SSAP) sunucusu düz HTTP isteğine "Hello world" der.</summary>
    internal static bool IsSsapGreeting(string? reply) =>
        string.Equals(reply?.Trim(), "hello world", StringComparison.OrdinalIgnoreCase);

    private static async Task<string?> DescriptionAsync(string host)
    {
        try { return await Http.GetStringAsync($"http://{host}:1990/"); }
        catch { return null; }
    }

    private static async Task<string?> GreetingAsync(string host)
    {
        try { return await Http.GetStringAsync($"http://{host}:3000/"); }
        catch { return null; }
    }

    /// <summary>Elle yazılan adresteki TV (türü TV'ye sorulur; bkz. <see cref="ManualTvAsync"/>).</summary>
    public static async Task<LgTv> TvAtAsync(string host, CancellationToken cancellationToken = default) =>
        (await ManualTvAsync(host, cancellationToken)).Tv;

    /// <summary>
    /// Android TV / Google TV'nin açık tuttuğu portlar: ADB (5555, hata ayıklama açıksa), Google Cast (8008, 8009) ve
    /// Android TV uzaktan kumanda hizmeti (6466). Yeni LG'lerde de Google Cast olabildiği için LG'ye önce bakılır.
    /// </summary>
    public static readonly int[] AndroidPorts = [5555, 6466, 8009, 8008];

    /// <summary>
    /// Elle yazılan adresteki TV'nin türü TV'ye sorulur (Mac'teki <c>ManualTV</c> ile aynı kural). Önceden Samsung değilse
    /// LG sayılıyordu: adresini yazan Android TV kullanıcısında LG eşleştirmesi deneniyor, "TV yanıt vermedi" çıkıyordu.
    /// </summary>
    public static async Task<ManualTv> ManualTvAsync(string host, CancellationToken cancellationToken = default)
    {
        var samsung = SamsungDiscovery.DeviceNameAsync(host, cancellationToken);
        var description = DescriptionAsync(host);
        var greeting = GreetingAsync(host);
        var android = Task.WhenAll(AndroidPorts.Select(port => IsPortOpenAsync(host, port)));
        return ClassifyManual(host, await samsung, LgNameIn(await description), IsSsapGreeting(await greeting),
            (await android).Any(open => open));
    }

    /// <summary>
    /// Cihaz tanımı (1990) LG webOS'unsa adı (yoksa "LG TV"), değilse null. Önceden 1990'da adını veren her cihaz ve 3000
    /// portu açık her cihaz LG sayılıyordu (Mac'teki kural cihaz tanımına ve "Hello world" yanıtına bakıyordu): elle
    /// adresi yazılan Android TV (X, Toshiba, Windows) LG diye eklenip LG eşleştirmesinde uzun uzun bekliyordu.
    /// </summary>
    internal static string? LgNameIn(string? xml) =>
        xml is not null && IsLgDescription(xml) ? FriendlyNameIn(xml)?.Trim() is { Length: > 0 } name ? name : "LG TV" : null;

    /// <summary>
    /// Yoklama sonuçlarından TV: Samsung 8001'de kendini tanıtırsa Samsung; LG cihaz tanımı (1990) ya da ikinci ekran
    /// sunucusu (3000) yanıt verirse LG; Android TV portlarından biri açıksa Android TV; hiçbiri değilse (tanınmadan) LG
    /// (webOS 3 cihaz tanımını her zaman vermiyor).
    /// </summary>
    public static ManualTv ClassifyManual(string host, string? samsungName, string? lgName, bool lgPortOpen, bool androidPortOpen)
    {
        if (samsungName is not null) return new ManualTv(new LgTv(samsungName, host, TvBrand.Samsung), true);
        if (lgName is not null || lgPortOpen) return new ManualTv(new LgTv(lgName ?? "LG TV", host), true);
        if (androidPortOpen) return new ManualTv(new LgTv("Android TV", host, TvBrand.AndroidTv), true);
        return new ManualTv(new LgTv("LG TV", host), false);
    }

    private static async Task<bool> IsPortOpenAsync(string host, int port)
    {
        using var client = new TcpClient();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(1500));
        try
        {
            await client.ConnectAsync(host, port, cancellation.Token);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Elle yazılan TV adresi (Mac/telefon: ManualAddress): boşluk, "http://", port ve yol atılır, virgül noktaya döner.
    /// Yalnız IPv4 kabul edilir; değilse null.
    /// </summary>
    public static string? NormalizeHost(string? input)
    {
        var text = (input ?? "").Trim().Replace(',', '.');
        var scheme = text.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) text = text[(scheme + 3)..];
        var end = text.IndexOfAny(['/', '?', '#', ':']);
        if (end >= 0) text = text[..end];
        text = text.TrimEnd('.');
        var parts = text.Split('.');
        if (parts.Length != 4) return null;
        var values = new List<string>();
        foreach (var part in parts)
        {
            if (part.Length is < 1 or > 3 || !part.All(char.IsAsciiDigit)) return null;
            var value = int.Parse(part, System.Globalization.CultureInfo.InvariantCulture);
            if (value > 255) return null;
            values.Add(value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        return string.Join('.', values);
    }

    /// <summary>
    /// SSDP yanıtından TV'nin adresini çıkarır; aranan hedef değilse null. "ssdp:all" aramasında her cihaz cevap verir:
    /// yalnız kendini LG webOS TV olarak tanıtan yanıt (bkz. IsLgHeader) alınır.
    /// </summary>
    public static string? HostFromSsdpResponse(string response, string searchTarget = SearchTarget) =>
        HitFromSsdpResponse(response, searchTarget)?.Host;

    /// <summary>
    /// SSDP yanıtındaki aday adres. <c>Confirmed</c>: yanıt kendini LG webOS olarak tanıtıyor: sorulan hedefin adı dışında
    /// bir başlıkta webOS/LGTV geçiyor (webOS: "SERVER: WebOS/4.4.0 UPnP/1.0") ya da cihaz tanımı webOS'un 1990 portunda.
    /// Hedefin adında ("...webos-second-screen...") "webos" geçtiği için yalnız onu geri söyleyen yanıt doğrulanmış sayılmaz.
    /// </summary>
    public sealed record SsdpHit(string Host, bool Confirmed);

    public static SsdpHit? HitFromSsdpResponse(string response, string searchTarget = SearchTarget)
    {
        string? location = null;
        var isLg = false;
        var lgHeader = false;
        foreach (var line in response.Split("\r\n"))
        {
            var colon = line.IndexOf(':');
            if (colon < 0) continue;
            var name = line[..colon].Trim().ToUpperInvariant();
            var value = line[(colon + 1)..].Trim();
            if (name == "LOCATION") { location = value; continue; }
            if (name is not ("ST" or "NT" or "USN" or "SERVER")) continue;
            if (name is "ST" or "NT" && value == searchTarget) isLg = true;
            if (searchTarget == AllTarget && IsLgHeader(value)) isLg = true;
            if (IsLgHeader(value.Replace(searchTarget, "", StringComparison.Ordinal))) lgHeader = true;
        }
        if (!isLg || !Uri.TryCreate(location, UriKind.Absolute, out var url)) return null;
        return new SsdpHit(url.Host, lgHeader || url.Port == 1990);
    }

    /// <summary>
    /// LG webOS TV'nin SSDP başlığı mı: sunucu adında "webOS" (webOS 3: "... LGE WebOS TV ...") ya da cihaz kimliğinde
    /// "LGTV" (webOS 3: "uuid:LGTV2017..."). LG'nin TV olmayan cihazları sayılmaz.
    /// </summary>
    internal static bool IsLgHeader(string value) =>
        value.Contains("webos", StringComparison.OrdinalIgnoreCase) || value.Contains("lgtv", StringComparison.OrdinalIgnoreCase);

    /// <param name="unicast">Verilirse istek ayrıca bu adreslerin her birine tek tek gönderilir.</param>
    internal static async Task<List<string>> CollectResponses(string searchTarget, TimeSpan timeout, CancellationToken cancellationToken,
        IReadOnlyList<string>? unicast = null) =>
        (await CollectHits(searchTarget, timeout, cancellationToken, unicast)).Select(hit => hit.Host).ToList();

    internal static async Task<List<SsdpHit>> CollectHits(string searchTarget, TimeSpan timeout, CancellationToken cancellationToken,
        IReadOnlyList<string>? unicast = null)
    {
        using var udp = new UdpClient(AddressFamily.InterNetwork);
        IgnoreUnreachableReplies(udp.Client);
        var request = Encoding.ASCII.GetBytes(
            $"M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {searchTarget}\r\n\r\n");
        var target = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
        // İstek her ağ bağdaştırıcısından ayrı gönderilir: varsayılan bağdaştırıcı VPN ya da sanal ağ (Hyper-V, WSL)
        // olabilir ve TV o ağda değildir. Yanıtlar bu soketin portuna tek tek gelir.
        var interfaces = LocalNetwork.PrivateAddresses();
        for (var i = 0; i < 2; i++)
        {
            if (interfaces.Count == 0) await udp.SendAsync(request, target, cancellationToken);
            foreach (var local in interfaces)
            {
                try
                {
                    udp.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, local.GetAddressBytes());
                    await udp.SendAsync(request, target, cancellationToken);
                }
                catch (SocketException) { /* bu bağdaştırıcıdan gönderilemedi; diğerleri denenir */ }
            }
        }
        foreach (var host in unicast ?? [])
        {
            var direct = Encoding.ASCII.GetBytes(
                $"M-SEARCH * HTTP/1.1\r\nHOST: {host}:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: {searchTarget}\r\n\r\n");
            try { await udp.SendAsync(direct, new IPEndPoint(IPAddress.Parse(host), 1900), cancellationToken); }
            catch (SocketException) { /* bu adrese gönderilemedi */ }
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        return await ReceiveHits(token => udp.ReceiveAsync(token), searchTarget, deadline.Token);
    }

    internal static async Task<List<string>> ReceiveHosts(Func<CancellationToken, ValueTask<UdpReceiveResult>> receive,
        string searchTarget, CancellationToken deadline) =>
        (await ReceiveHits(receive, searchTarget, deadline)).Select(hit => hit.Host).ToList();

    /// <summary>
    /// Süre dolana kadar SSDP yanıtlarını toplar. Windows'ta UDP soketi, daha önce gönderilen bir paket için gelen "port
    /// kapalı" (ICMP) yanıtını sonraki okumada "bağlantı zorla kapatıldı" (10054) hatası olarak verir: tek tek aranan
    /// adreslerde 1900 portu kapalı cihazlar bunu tetikler. Bu hata atlanır, okuma sürer; önceden uygulama çöküyordu (#556).
    /// Başka bir soket hatasında o ana dek bulunanlar döner.
    /// </summary>
    internal static async Task<List<SsdpHit>> ReceiveHits(Func<CancellationToken, ValueTask<UdpReceiveResult>> receive,
        string searchTarget, CancellationToken deadline)
    {
        var hosts = new List<SsdpHit>();
        while (true)
        {
            UdpReceiveResult result;
            try { result = await receive(deadline); }
            catch (OperationCanceledException) { break; }
            catch (SocketException error) when (error.SocketErrorCode == SocketError.ConnectionReset && !deadline.IsCancellationRequested) { continue; }
            catch (SocketException) { break; }
            catch (ObjectDisposedException) { break; }
            if (HitFromSsdpResponse(Encoding.UTF8.GetString(result.Buffer), searchTarget) is { } hit) hosts.Add(hit);
        }
        return hosts;
    }

    /// <summary>
    /// Windows'ta UDP soketinin ICMP "port kapalı" yanıtlarını okuma hatasına çevirmesini kapatır (SIO_UDP_CONNRESET).
    /// Başka sistemlerde bu davranış yoktur.
    /// </summary>
    private static void IgnoreUnreachableReplies(Socket socket)
    {
        if (!OperatingSystem.IsWindows()) return;
        const int SioUdpConnReset = unchecked((int)0x9800000C);
        try { socket.IOControl(SioUdpConnReset, [0, 0, 0, 0], null); }
        catch (Exception error) when (error is SocketException or PlatformNotSupportedException or NotSupportedException) { }
    }

    /// <summary>TV'nin ağdaki adını (ör. "[LG] webOS TV UK7550") cihaz tanımından okur.</summary>
    private static async Task<string?> FriendlyName(string host)
    {
        // webOS cihaz tanımı 1990 numaralı portta yayınlanır; okunamazsa genel ad kullanılır.
        var xml = await DescriptionAsync(host);
        return xml is null ? null : FriendlyNameIn(xml);
    }

    private static string? FriendlyNameIn(string xml)
    {
        var start = xml.IndexOf("<friendlyName>", StringComparison.Ordinal);
        var end = start < 0 ? -1 : xml.IndexOf("</friendlyName>", start, StringComparison.Ordinal);
        return end < 0 ? null : xml[(start + "<friendlyName>".Length)..end];
    }
}
