// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text;
using System.Text.Json;

namespace CouchSubs.Shell;

/// <summary>Bir saat adımında yapılacaklar: Xbox'tan anahtar kare istenir mi, tanı satırı yazılır mı, ilk kare sınırı doldu mu.</summary>
public readonly record struct XboxWatchStep(bool RequestKeyframe, bool LogStats, bool NoPicture = false);

/// <summary>
/// Xbox görüntüsü başlayana kadar yapılanlar (#403, #530). Xbox kare onayı alamazsa oturumu ~60 sn sonra kapatır;
/// onay yalnız gösterilen karede gider, kare hiç gelmezse onay da gitmez. İlk kare gelene kadar kontrol kanalından
/// anahtar kare istenir (xbox-xcloud-player Channel/Control.ts <c>requestKeyframeRequest</c>; XStreaming de ister)
/// ve bağlantıdan 10 sn sonra, sonra 10 sn'de bir tanı satırı yazılır. <see cref="FirstFrameLimit"/> dolunca bir kez
/// <see cref="XboxWatchStep.NoPicture"/> döner: oturum Xbox'ın kendisi kapatmasını (~60 sn) beklemeden "görüntü gelmedi"
/// nedeniyle kapatılır (bkz. <see cref="XboxRetryPlan"/>). Android'deki XboxFirstFrameWatch'un aynısı.
/// </summary>
public sealed class XboxFirstFrameWatch
{
    /// <summary>Bağlantıdan sonra ilk kare için beklenen en uzun süre (Android, iPhone ve Mac'te de 30 sn).</summary>
    public static readonly TimeSpan FirstFrameLimit = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan KeyframeInterval = TimeSpan.FromMilliseconds(2500);
    /// <summary>Bu süreden sonra anahtar kare istenmez; tanı satırları sürer.</summary>
    public static readonly TimeSpan KeyframeWindow = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan StatsDelay = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan StatsInterval = TimeSpan.FromSeconds(10);

    private TimeSpan? lastKeyframe;
    private TimeSpan nextStats = StatsDelay;

    /// <summary>İlk kare geldi; bundan sonra hiçbir şey yapılmaz.</summary>
    public bool FrameSeen { get; private set; }
    public int KeyframesRequested { get; private set; }

    public void FrameArrived() => FrameSeen = true;

    /// <param name="sinceConnected">Bağlantıdan (input kanalı açıldı) bu yana geçen süre.</param>
    /// <param name="keyframeReady">Görüntü parçası geldi ve kontrol kanalı açık.</param>
    public XboxWatchStep Tick(TimeSpan sinceConnected, bool keyframeReady)
    {
        if (FrameSeen) return default;
        var keyframe = keyframeReady && sinceConnected <= KeyframeWindow
            && (lastKeyframe is not { } last || sinceConnected - last >= KeyframeInterval);
        if (keyframe)
        {
            lastKeyframe = sinceConnected;
            KeyframesRequested++;
        }
        var stats = sinceConnected >= nextStats;
        if (stats)
        {
            // Saat takıldıysa kaçan satırlar art arda yazılmaz.
            while (nextStats <= sinceConnected) nextStats += StatsInterval;
        }
        var noPicture = !limitReached && sinceConnected >= FirstFrameLimit;
        if (noPicture) limitReached = true;
        return new XboxWatchStep(keyframe, stats, noPicture);
    }

    private bool limitReached;
}

/// <summary>WebRTC getStats özetini tek günlük satırına çevirir. Android'deki XboxStreamStats ile aynı biçim.</summary>
public static class XboxStreamStats
{
    /// <summary>Oynatıcı sayfasındaki video öğesinin durumu.</summary>
    public static string Picture(int readyState, int width, int height, string? visibility, long frameCallbacks) =>
        string.Create(CultureInfo.InvariantCulture,
            $"görüntü readyState {readyState}, {width}x{height}, görünürlük {visibility ?? "?"}, kare geri çağrısı {frameCallbacks}");

    /// <summary>Görüntü verisi hiç gelmediyse (bayt 0) tarayıcı çözücüyü kurmaz; "çözücü" alanı bunu söyler (#1252).</summary>
    public const string DecoderNotStarted = "kurulmadı, görüntü verisi gelmedi";

    /// <param name="stats">getStats raporunun girdileri (inbound-rtp, candidate-pair, local/remote-candidate, transport).</param>
    /// <param name="negotiatedCodec">Xbox'ın SDP yanıtında seçtiği görüntü kodeği (getStats kodeği ilk kareye kadar boştur).</param>
    /// <param name="decoder">Uygulamanın bildiği çözücü durumu; getStats'ta yoksa kullanılır.</param>
    public static string Describe(TimeSpan sinceConnected, bool frameSeen, int keyframes, JsonElement stats, string picture,
        string? negotiatedCodec = null, string? decoder = null)
    {
        var entries = stats.ValueKind == JsonValueKind.Array ? stats.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Object).ToList() : [];
        var line = new StringBuilder();
        line.Append(CultureInfo.InvariantCulture, $"tanı ({(long)sinceConnected.TotalSeconds} sn, {(frameSeen ? "ilk kare geldi" : "ilk kare yok")}): keyframe isteği {keyframes}; ");
        var video = entries.FirstOrDefault(e => Text(e, "type") == "inbound-rtp" && (Text(e, "kind") ?? Text(e, "mediaType")) == "video");
        if (video.ValueKind == JsonValueKind.Object)
        {
            line.Append(CultureInfo.InvariantCulture,
                $"video paket {Number(video, "packetsReceived")}, bayt {Number(video, "bytesReceived")}, kayıp {Number(video, "packetsLost")}, " +
                $"çözülen {Number(video, "framesDecoded")}, düşen {Number(video, "framesDropped")}, anahtar kare {Number(video, "keyFramesDecoded")}, " +
                $"PLI {Number(video, "pliCount")}, çözücü {Text(video, "decoderImplementation") ?? decoder ?? (Number(video, "bytesReceived") == "0" ? DecoderNotStarted : "?")}");
            // Anlaşılan kodek (Xbox'ın SDP yanıtının seçtiği): "görüntü hiç gelmedi" kodekten mi, ayrılsın.
            var codec = ById(entries, Text(video, "codecId"));
            if (codec.ValueKind == JsonValueKind.Object)
                line.Append((", kodek " + (Text(codec, "mimeType") ?? "?") + " " + Text(codec, "sdpFmtpLine")).TrimEnd());
            else if (negotiatedCodec is not null)
                line.Append(", kodek ").Append(negotiatedCodec).Append(" (SDP yanıtı)");
            line.Append("; ");
        }
        else line.Append("video yok; ");
        // Ses de geliyor mu (#1416): video yalnız dolgu paketiyken (bayt 0) ses akıyorsa Xbox yayını başlatmış, yalnız
        // görüntüyü kodlamıyor; ses de yoksa Xbox'ın yayın hizmeti hiç başlamamış.
        var audio = entries.FirstOrDefault(e => Text(e, "type") == "inbound-rtp" && (Text(e, "kind") ?? Text(e, "mediaType")) == "audio");
        if (audio.ValueKind == JsonValueKind.Object)
            line.Append(CultureInfo.InvariantCulture, $"ses paket {Number(audio, "packetsReceived")}, bayt {Number(audio, "bytesReceived")}; ");
        else line.Append("ses yok; ");
        var pair = SelectedPair(entries);
        if (pair.ValueKind == JsonValueKind.Object)
        {
            var local = ById(entries, Text(pair, "localCandidateId"));
            var remote = ById(entries, Text(pair, "remoteCandidateId"));
            line.Append(CultureInfo.InvariantCulture,
                $"aday yerel {Field(local, "candidateType")}/{Field(local, "protocol")} ağ {Field(local, "networkType")}, uzak {Field(remote, "candidateType")}, durum {Text(pair, "state") ?? "?"}; ");
        }
        else line.Append("aday seçilmedi; ");
        line.Append(picture);
        return line.ToString();
    }

    private static JsonElement SelectedPair(List<JsonElement> entries)
    {
        foreach (var transport in entries.Where(e => Text(e, "type") == "transport"))
        {
            var pair = ById(entries, Text(transport, "selectedCandidatePairId"));
            if (pair.ValueKind == JsonValueKind.Object) return pair;
        }
        var pairs = entries.Where(e => Text(e, "type") == "candidate-pair").ToList();
        return pairs.FirstOrDefault(p => p.TryGetProperty("selected", out var s) && s.ValueKind == JsonValueKind.True) is { ValueKind: JsonValueKind.Object } selected
            ? selected
            : pairs.FirstOrDefault(p => p.TryGetProperty("nominated", out var n) && n.ValueKind == JsonValueKind.True && Text(p, "state") == "succeeded");
    }

    private static JsonElement ById(List<JsonElement> entries, string? id) =>
        id is null ? default : entries.FirstOrDefault(e => Text(e, "id") == id);

    private static string Field(JsonElement entry, string name) => entry.ValueKind == JsonValueKind.Object ? Text(entry, name) ?? "?" : "?";

    private static string? Text(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static string Number(JsonElement entry, string name) =>
        entry.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? ((long)value.GetDouble()).ToString(CultureInfo.InvariantCulture)
            : "?";
}

/// <summary>
/// <c>input</c> kanalından gelen ikili iletinin günlük metni (#1416): tür, uzunluk ve ilk <see cref="HexBytes"/> bayt
/// onaltılı. Xbox el sıkışmadan sonra 16 (ServerMetadata) gönderir; içeriği Xbox'ın görüntü ayarını gösterebilir (görüntü
/// hiç gelmeyen oturumu çalışan oturumla karşılaştırmak için). 128 (titreşim) her an gelir, yazılmaz (null). Mac/iPhone
/// ve Android'deki <c>XboxChannels.describeInput</c> ile aynı biçim; oynatıcı sayfası yalnız ilk baytları gönderir.
/// </summary>
public static class XboxInputMessage
{
    public const int HexBytes = 32;

    /// <param name="head">İletinin ilk baytları (en çok <see cref="HexBytes"/>; fazlası yazılmaz).</param>
    /// <param name="length">İletinin tam uzunluğu.</param>
    public static string? Describe(IReadOnlyList<byte> head, int length)
    {
        var type = head.Count == 0 ? -1 : head[0];
        if (type == 128) return null;
        var name = type == 16 ? " (ServerMetadata)" : "";
        var hex = string.Join(" ", head.Take(HexBytes).Select(b => b.ToString("x2", CultureInfo.InvariantCulture)));
        return string.Create(CultureInfo.InvariantCulture, $"ikili ileti, tür {type}{name}, {length} bayt")
            + (hex.Length == 0 ? "" : ": " + hex) + (length > HexBytes ? " …" : "");
    }
}
