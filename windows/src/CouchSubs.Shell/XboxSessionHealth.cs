// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text.RegularExpressions;
using CouchSubs.Core;

namespace CouchSubs.Shell;

/// <summary>
/// Xbox oturumunun canlı tutma isteği (30 sn'de bir). Eskiden oynatıcı sayfası tek bir başarısız isteği bağlantı hatası
/// sayıyor ve görüntü sorunsuz akarken oturumu kapatıyordu ("uzaktan oynatma başlıyor ama duruyor"). Artık yalnız
/// <see cref="MaxFailures"/> ardışık hata (yaklaşık 90 sn yanıt yok) oturumu bitirir; arada başarılı bir istek sayacı sıfırlar.
/// </summary>
public sealed class XboxKeepalive
{
    public static readonly TimeSpan Interval = TimeSpan.FromSeconds(30);
    public const int MaxFailures = 3;

    public int Failures { get; private set; }

    public void Succeeded() => Failures = 0;

    /// <returns>Oturum bitirilmeli mi.</returns>
    public bool Failed() => ++Failures >= MaxFailures;

    /// <summary>Yanıt oturumun Xbox hizmetinde artık olmadığını söylüyor (HTTP 404/410): beklenmez, oturum biter.</summary>
    public static bool SessionGone(string? message) =>
        message is not null && (message.Contains("HTTP 404", StringComparison.Ordinal) || message.Contains("HTTP 410", StringComparison.Ordinal));

    /// <summary>
    /// Başarısız canlı tutma isteğinden sonra yayın bitirilmeli mi. Görüntü akarken (<paramref name="pictureFlowing"/>)
    /// hayır: Xbox yayını sürdürüyor, canlı tutma yanıtı (404 dahil) yanıltıcı olabiliyor. Android beta.85'te 404 ya da üç
    /// hata görüntü akarken de yayını kapatıyordu; ilk istek bağlantıdan 30 sn sonra gittiği için Xbox'ta "uzaktan yürütme
    /// başlatıldı / durduruldu" döngüsü oluyordu. Görüntü durmuşsa eskisi gibi: oturum Xbox hizmetinde yoksa
    /// (<paramref name="gone"/>) ya da hatalar <see cref="MaxFailures"/>'a vardıysa (<paramref name="exhausted"/>) biter.
    /// CouchSubsCore ve Android'deki XboxKeepalive.shouldEnd ile aynı.
    /// </summary>
    public static bool ShouldEnd(bool gone, bool exhausted, bool pictureFlowing) => !pictureFlowing && (gone || exhausted);
}

/// <summary>
/// Bir bağlantının neden bittiği: günlükte açıkça yazılır, yeniden bağlanırken ekrandaki kısa metni seçer. CouchSubsCore
/// XboxEndCause (iPhone, Mac) ve Android'deki XboxEndCause ile aynı kurallar.
/// </summary>
public enum XboxEndCause
{
    /// <summary>Xbox (ya da Xbox hizmeti) yayını kapattı: görüntü kanalı karşı taraftan kapandı, oturum bulunamadı, yayın reddedildi.</summary>
    Server,
    /// <summary>Beklenen yanıt ya da görüntü süresinde gelmedi.</summary>
    Timeout,
    /// <summary>Ağ bağlantısı koptu ya da kurulamadı (ICE, Wi-Fi, internet).</summary>
    Network,
}

public static class XboxEndCauses
{
    public static string Text(this XboxEndCause cause) => cause switch
    {
        XboxEndCause.Server => "sunucu kapattı",
        XboxEndCause.Timeout => "zaman aşımı",
        _ => "ağ",
    };

    /// <summary>Olay belli değilse iletiden: süre dolması zaman aşımı, Xbox hizmetinin hata yanıtı sunucu, gerisi ağ.</summary>
    public static XboxEndCause FromMessage(string? message) =>
        message is null ? XboxEndCause.Network
        : message.Contains("timed out", StringComparison.OrdinalIgnoreCase) || message.Contains("zaman aşımı", StringComparison.OrdinalIgnoreCase) ? XboxEndCause.Timeout
        : message.Contains("Xbox service HTTP", StringComparison.Ordinal) ? XboxEndCause.Server
        : XboxEndCause.Network;

    /// <summary>Günlük satırı, ör. <c>kapanma nedeni: ağ (Xbox ICE bağlantısı koptu (failed))</c>.</summary>
    public static string Line(XboxEndCause cause, string? detail) => $"kapanma nedeni: {cause.Text()} ({XboxStop.Shorten(detail)})";

    /// <summary>Sessiz yeniden bağlanma satırı, ör. <c>sessiz yeniden bağlanma 2/3: 15 sn sonra</c> (CouchSubsCore ve
    /// Android'de aynı biçim). Deneme sınırı aşıldıysa (kopmadan sonraki ret için tanınan ek deneme) "ek deneme" yazılır.</summary>
    public static string RetryLine(int attempt, int max, int delayMs) =>
        $"sessiz yeniden bağlanma {(attempt <= max ? $"{attempt}/{max}" : "ek deneme")}: {delayMs / 1000} sn sonra";

    /// <summary>Sessiz yeniden bağlanma sınırı doldu (CouchSubsCore ve Android'de aynı biçim).</summary>
    public static readonly string LimitLine =
        $"sessiz yeniden bağlanma sınırı doldu ({XboxRetryPlan.DropRetryWindowMs / 60_000} dk içinde en çok {XboxRetryPlan.MaxDropRetries}): yeniden denenmiyor, yayın durdu";

    /// <summary>Yeniden bağlanırken ana ekranda gösterilen kısa metin (Mac/iPhone XboxText.session, Android xbox_error_*).</summary>
    public static string RetryMessage(XboxEndCause cause) => cause switch
    {
        XboxEndCause.Server => "The Xbox closed the stream. Reconnecting…",
        XboxEndCause.Timeout => "Your Xbox didn't answer. Retrying…",
        _ => "The Xbox connection dropped. Reconnecting…",
    };
}

/// <summary>
/// ICE adayları değişildikten sonra görüntü kanalı (input) bu sürede açılmazsa bağlantı zaman aşımıyla kapatılır; ilk
/// kare sınırı kanal açılınca başlar. Eskiden Windows'ta ICE hiç kurulamazsa sınır yoktu: oturum Xbox kendisi kapatana
/// kadar "bağlanıyor"da kalıyordu.
/// </summary>
public static class XboxConnectWatch
{
    public static readonly TimeSpan ConnectLimit = TimeSpan.FromSeconds(30);
}

/// <summary>
/// Kopmadan sonra yeniden denenir mi, ne kadar sonra (Android/CouchSubsCore XboxSessionMachine.fail ile aynı kurallar).
/// Görüntü gelmeden biten bağlantıda bir kez, 5 sn sonra baştan denenir (eskiden 5, 15, 45 sn aralarla üç deneme her
/// seferinde Xbox'ta "uzaktan yürütme başlatıldı / durduruldu" bildirimi çıkarıyordu). Görüntü gelmiş (oynanan) yayın
/// beklenmedik koparsa kullanıcıya sormadan en çok <see cref="DropDelaysMs"/> kadar (5, 15 sn) yeniden bağlanılır: tek
/// deneme tutmayınca kullanıcı birkaç dakikada bir "Yeniden bağlan"a basmak zorunda kalıyordu (#1185, #1190). Yayın <see cref="HealthyStreamMs"/> (10 dk)
/// ayakta kaldıysa sayaç sıfırlanır. Sessiz yeniden bağlanma oturum boyunca <see cref="DropRetryWindowMs"/> (10 dk) içinde en
/// çok <see cref="MaxDropRetries"/> (iki) kez yapılır; sınır dolunca durulur (<see cref="DropLimitReached"/>, ekranda "Xbox
/// bağlantısı koptu" ve "Yeniden bağlan"). beta.94'te (#1216) üç deneme ve 60 sn'de sıfırlanan sayaç birlikte, birkaç dakikada
/// bir kopan yayında Xbox'ta bitmeyen "uzaktan yürütme durdu / başladı" bildirimi döngüsü yaratıyordu (#1252). Xbox'tan hiç görüntü gelmeyen bağlantılar ayrıca sayılır: <see cref="MaxNoPictureAttempts"/> ardışık
/// bağlantıda ilk kare gelmezse yeniden denenmez. Eskiden her biri Xbox'ta "uzaktan oynatma başlatıldı / durduruldu"
/// bildirimiyle dört kez (yaklaşık beş dakika) açılıp kapanıyor, ekranda yalnız "WebRTC bağlantısı kesildi" görünüyordu (#403).
/// </summary>
public sealed class XboxRetryPlan
{
    public static readonly int[] DelaysMs = [5000];
    /// <summary>Görüntü gelmiş yayın koptuktan sonraki sessiz yeniden bağlanma aralıkları (CouchSubsCore
    /// <c>dropRetryDelaysMs</c>, Android <c>dropRetryDelaysMs</c> ile aynı).</summary>
    public static readonly int[] DropDelaysMs = [5000, 15_000];
    /// <summary>Yayın bu kadar sağlıklı sürdüyse kopma yeni bir dizinin ilkidir (eskiden 60 sn: birkaç dakikada bir kopan
    /// yayın döngüye giriyordu, #1252).</summary>
    public const long HealthyStreamMs = 600_000;
    /// <summary>Sessiz yeniden bağlanma oturum sınırı: bu süre içinde en çok <see cref="MaxDropRetries"/> deneme.</summary>
    public const long DropRetryWindowMs = 600_000;
    public const int MaxDropRetries = 2;
    public const int MaxNoPictureAttempts = 2;

    /// <summary>Kopmadan sonra Xbox yeni oturumu reddederse (eski oturum Xbox'ta henüz kapanmadı) beklenen süre.</summary>
    public const int ReconnectGraceMs = 15_000;

    private int noPicture;
    private bool hadPicture;
    private bool graceUsed;
    private readonly Func<long> clock;
    /// <summary>Görüntü gelmiş yayından sonraki sessiz yeniden bağlanmaların anları (son <see cref="DropRetryWindowMs"/> içindekiler).</summary>
    private readonly Queue<long> dropRetries = new();

    /// <param name="clock">Milisaniye saati (testlerde sahte saat); verilmezse <see cref="Environment.TickCount64"/>.</param>
    public XboxRetryPlan(Func<long>? clock = null) => this.clock = clock ?? (() => Environment.TickCount64);

    /// <summary>
    /// Son kopmada sessiz yeniden bağlanma sınırı doldu (görüntü gelmiş yayın <see cref="DropDelaysMs"/> kadar ya da
    /// <see cref="DropRetryWindowMs"/> içinde <see cref="MaxDropRetries"/> kez yeniden bağlandı ve yine koptu): yeniden
    /// denenmez, kullanıcıya "Xbox bağlantısı koptu" gösterilir.
    /// </summary>
    public bool DropLimitReached { get; private set; }

    private int[] Delays => hadPicture ? DropDelaysMs : DelaysMs;

    /// <summary>Sessiz yeniden bağlanmanın en çok deneme sayısı (günlükte "deneme 2/3").</summary>
    public int MaxRetries => Delays.Length;

    /// <summary>Ardışık başarısız deneme (1; kopmadan sonraki retten sonra 2).</summary>
    public int Failures { get; private set; }

    /// <summary>İlk kare geldi: görüntüsüz bağlantı dizisi biter; sonraki kopmada gelen ret bir kez denenebilir.</summary>
    public void PictureArrived()
    {
        noPicture = 0;
        hadPicture = true;
        graceUsed = false;
    }

    /// <param name="permanent">Konsol yayını reddetti (Failed ya da errorDetails).</param>
    /// <param name="noFirstFrame">Bağlantı kuruldu ama Xbox'tan tek kare gelmeden bitti.</param>
    /// <param name="streamedMs">İlk kareden bu yana geçen süre (görüntü hiç gelmediyse null).</param>
    /// <returns>Bekleme süresi; null ise yeniden denenmez.</returns>
    /// <param name="reason">Ham neden; Xbox uzaktan oynatma hizmetini başlatamadıysa (HTTP hatası olarak gelse de) yeniden denenmez (#871).</param>
    public int? Failed(bool permanent, bool noFirstFrame, long? streamedMs, string? reason = null)
    {
        if (streamedMs >= HealthyStreamMs) Failures = 0;
        Failures++;
        if (noFirstFrame) noPicture++;
        // Xbox ses gönderip görüntü göndermediyse (#1432) yeniden denemek aynı sonucu verir; her deneme Xbox'ta bildirim çıkarır.
        if (noFirstFrame && XboxStop.IsAudioOnly(reason)) noPicture = Math.Max(noPicture, MaxNoPictureAttempts);
        var refused = permanent || XboxStop.IsPermanent(reason);
        // Görüntü gelmiş yayın koptuktan hemen sonra Xbox eski oturumu bırakmadan yenisini reddedebiliyor ("bir kez
        // kopunca Xbox yeniden başlatılmadan bağlanmıyor"): bu ret bir kez, eski oturum kapansın diye uzun beklenip denenir.
        var grace = refused && hadPicture && !graceUsed;
        // Kopma dizisinde görüntü gelmiş yayından sonra en çok DropDelaysMs kadar (üç), görüntü hiç gelmediyse DelaysMs
        // kadar (bir) yeniden bağlanma; kopmadan sonraki ret için tanınan tek deneme bu sınırın dışındadır (reddedilen
        // oturumda Xbox yayın açmaz).
        var delays = Delays;
        var retry = ((!refused && Failures <= delays.Length) || grace) && noPicture < MaxNoPictureAttempts;
        // Oturum sınırı: görüntü gelmiş yayından sonra DropRetryWindowMs içinde en çok MaxDropRetries sessiz yeniden
        // bağlanma (kopmadan sonraki ret için tanınan deneme de sayılır; her biri Xbox'ta bildirim çıkarır).
        var now = clock();
        while (dropRetries.Count > 0 && now - dropRetries.Peek() >= DropRetryWindowMs) dropRetries.Dequeue();
        var limited = hadPicture && noPicture < MaxNoPictureAttempts && (!refused || grace)
            && (!retry || dropRetries.Count >= MaxDropRetries);
        DropLimitReached = limited;
        if (!retry || limited) return null;
        if (hadPicture) dropRetries.Enqueue(now);
        if (grace) graceUsed = true;
        var backoff = delays[Math.Min(Failures, delays.Length) - 1];
        return grace ? Math.Max(ReconnectGraceMs, backoff) : backoff;
    }
}

/// <summary>Yayının neden durduğu (kullanıcıya gösterilen metni seçer).</summary>
/// <remarks>
/// <c>ServiceNotReady</c>: Xbox uzaktan oynatma hizmetini başlatamadı ("Timed out waiting for Cloud Streaming Service to be
/// ready", 0x8007139F); <c>StartFailed</c>: Xbox bilinmeyen bir hata koduyla yayını reddetti (#871).
/// </remarks>
/// <c>Dropped</c>: oynanan yayın koptu ve sessiz yeniden bağlanma sınırı doldu (<see cref="XboxRetryPlan.DropLimitReached"/>, #1252).
/// <c>StuckPicture</c>: Xbox'tan görüntü gelmedi ama ses geldi; Xbox'ın görüntü yayını takılı (#1432, #1416).
public enum XboxStopKind { Busy, ConsoleUnavailable, NoPicture, StuckPicture, ServiceNotReady, StartFailed, Dropped, Other }

/// <summary>Xbox yayını durunca günlük satırı ve kullanıcıya gösterilen metin. Android'deki XboxSessionMachine.classifyFailure ile aynı kurallar.</summary>
public static partial class XboxStop
{
    /// <summary>Kullanıcı metninde gösterilen ham nedenin en çok uzunluğu (Xbox hizmeti 500 karakterlik JSON dönebilir).</summary>
    public const int ReasonLimit = 120;

    /// <param name="noFirstFrame">Son bağlantı Xbox'tan tek kare gelmeden bitti.</param>
    public static XboxStopKind Classify(string? reason, bool noFirstFrame = false)
    {
        if (noFirstFrame) return IsAudioOnly(reason) ? XboxStopKind.StuckPicture : XboxStopKind.NoPicture;
        var text = reason ?? "";
        bool Has(string word) => text.Contains(word, StringComparison.OrdinalIgnoreCase);
        if (Has("InUse") || Has("Busy") || Has("AlreadyStreaming")) return XboxStopKind.Busy;
        var code = ErrorCode(text);
        if (Has("Cloud Streaming Service") || code == ServiceNotReadyCode) return XboxStopKind.ServiceNotReady;
        if (Has("Offline") || Has("NotFound") || Has("Unavailable") || Has("PowerOff") || Has("StreamingDisabled"))
            return XboxStopKind.ConsoleUnavailable;
        return code is null ? XboxStopKind.Other : XboxStopKind.StartFailed;
    }

    /// <summary>
    /// "Timed out waiting for Cloud Streaming Service to be ready" hatasının kodu: Xbox'ın verdiği -2147019873, HRESULT
    /// 0x8007139F (Win32 5023, ERROR_INVALID_STATE).
    /// </summary>
    public const string ServiceNotReadyCode = "0x8007139F";

    /// <summary>
    /// Bu neden yeniden denenmez: Xbox kendi hizmetini başlatamıyor, yeniden denemek yalnız Xbox'ta "uzaktan oynatma
    /// başlatıldı / durduruldu" bildirimini tekrarlar; Xbox'ı kullanıcının yeniden başlatması gerekir.
    /// </summary>
    public static bool IsPermanent(string? reason) => Classify(reason) == XboxStopKind.ServiceNotReady;

    /// <summary>İlk kare sınırı nedenine eklenen not: son tanıda ses geliyordu, görüntü 0 bayttı (bkz. <see cref="XboxStreamStats.AudioOnly"/>).</summary>
    public const string AudioOnlyNote = "ses geliyor, görüntü 0 bayt";

    /// <summary>Bağlantı Xbox'ın yalnız ses gönderdiği bir bağlantıydı: yeniden denemek işe yaramaz, Xbox tam kapatılıp açılmalı.</summary>
    public static bool IsAudioOnly(string? reason) => reason?.Contains(AudioOnlyNote, StringComparison.Ordinal) == true;

    /// <summary>Ses gelip görüntü gelmeyen bağlantıdan sonra günlüğe yazılan açıklama (Mac/iPhone ve Android'de aynı metin).</summary>
    public const string AudioOnlyLine = "Xbox ses gönderiyor ama görüntü kodlamıyor (görüntü paketleri boş): Xbox'ın görüntü yayını takılı kalmış; " +
        "kodek, çözünürlük ya da ağ değil. Xbox güç düğmesine 10 sn basılı tutularak tam kapatılıp açılmalı; yeniden denenmiyor";

    /// <summary>
    /// Xbox hizmetinin hata nesnesindeki (errorDetails ya da HTTP gövdesi) kod. <c>Agent : -2147019873 : …</c> ve 0x… biçimi
    /// HRESULT olarak (0x8007139F), yoksa <c>"code"</c> alanı olduğu gibi; bulunamazsa null.
    /// </summary>
    public static string? ErrorCode(string? reason)
    {
        if (string.IsNullOrEmpty(reason)) return null;
        var agent = AgentCode().Match(reason);
        if (agent.Success) return Hresult(agent.Groups[1].Value);
        var hex = HexCode().Match(reason);
        if (hex.Success) return "0x" + hex.Groups[1].Value.ToUpperInvariant();
        var field = CodeField().Match(reason);
        if (field.Success && field.Groups[1].Value != "null") return Hresult(field.Groups[1].Value);
        return null;
    }

    /// <summary>Hata nesnesindeki <c>"message"</c> metni (JSON kaçışları açılmış); yoksa null.</summary>
    public static string? ErrorMessage(string? reason)
    {
        if (reason is null) return null;
        var match = MessageField().Match(reason);
        if (!match.Success) return null;
        var message = JsonEscape().Replace(match.Groups[1].Value, "$1");
        return string.IsNullOrWhiteSpace(message) ? null : message;
    }

    /// <summary>Ekrandaki metne giren neden: StartFailed'da yalnız kod, Other'da JSON'suz kısa metin; ham neden yalnız günlüğe yazılır.</summary>
    public static string DisplayReason(string? reason, XboxStopKind kind, string fallback = "?")
    {
        switch (kind)
        {
            case XboxStopKind.StartFailed: return ErrorCode(reason) ?? fallback;
            case XboxStopKind.Other:
                var brace = reason?.IndexOf('{') ?? -1;
                if (brace < 0) return Shorten(reason, fallback: fallback);
                if (ErrorMessage(reason) is { } message) return Shorten(message, fallback: fallback);
                return Shorten(reason![..brace].Trim(' ', ':'), fallback: fallback);
            default: return Shorten(reason, fallback: fallback);
        }
    }

    /// <summary>Ondalık HRESULT (-2147019873 ya da 2147947423) 0x8007139F biçimine çevrilir; başka değer olduğu gibi kalır.</summary>
    internal static string Hresult(string value)
    {
        if (!long.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var number)) return value;
        if (number < 0 && number >= int.MinValue) return string.Create(CultureInfo.InvariantCulture, $"0x{unchecked((uint)(int)number):X8}");
        if (number >= 0x8000_0000 && number <= 0xFFFF_FFFF) return string.Create(CultureInfo.InvariantCulture, $"0x{(uint)number:X8}");
        return value;
    }

    /// <summary>Denemeler bitince ya da konsol yayını reddedince gösterilen metin; Xbox'ın JSON hata nesnesi ekranda gösterilmez (#871).</summary>
    /// <param name="dropped">Sessiz yeniden bağlanma sınırı doldu (<see cref="XboxRetryPlan.DropLimitReached"/>).</param>
    public static string Message(Localizer text, string? reason, bool noFirstFrame = false, bool dropped = false)
    {
        var kind = dropped ? XboxStopKind.Dropped : Classify(reason, noFirstFrame);
        return kind switch
        {
            XboxStopKind.NoPicture => text[NoPictureStopped],
            XboxStopKind.StuckPicture => text[StuckPictureStopped],
            XboxStopKind.Dropped => text[DroppedStopped],
            XboxStopKind.Busy => text["Your Xbox is streaming to another device (the Xbox app, a phone or a PC). Close that session, then start translation again."],
            XboxStopKind.ConsoleUnavailable => text["Can't reach your Xbox. Make sure it's on and remote play is enabled in Settings › Devices & connections › Remote features, then start translation again."],
            XboxStopKind.ServiceNotReady => text[ServiceNotReadyStopped],
            XboxStopKind.StartFailed => text.Format(StartFailedStopped, DisplayReason(reason, kind)),
            _ => text.Format("The Xbox stream stopped (%@). Start translation again; if it keeps stopping, restart the Xbox.", DisplayReason(reason, kind)),
        };
    }

    /// <summary>Xbox uzaktan oynatma hizmetini başlatamadı (Mac/iPhone XboxText.stopped, Android xbox_stopped_service).</summary>
    public const string ServiceNotReadyStopped = "Your Xbox couldn't start its remote play service. Turn the Xbox fully off by holding the power button for 10 seconds, turn it back on, check that Remote features are on, then try again.";

    /// <summary>Xbox bilinmeyen kodla yayını reddetti (Android xbox_stopped_code).</summary>
    public const string StartFailedStopped = "Your Xbox couldn't start the stream (code %@). Turn the Xbox fully off by holding the power button for 10 seconds, turn it back on, check that Remote features are on, then try again.";

    /// <summary>Xbox'tan görüntü hiç gelmedi, denemeler bitti (Mac/iPhone XboxText.stopped, Android xbox_stopped_no_picture).</summary>
    public const string NoPictureStopped = "No picture came from the Xbox, so translation stopped. On the Xbox, check that remote play is on in Settings › Devices & connections › Remote features, connect the Xbox with a network cable if you can (or restart it), then start translation again.";

    /// <summary>Xbox ses gönderdi, görüntü göndermedi (Mac/iPhone XboxText.stopped, Android xbox_stopped_stuck_picture).</summary>
    public const string StuckPictureStopped = "The Xbox sent sound but no picture: its picture stream is stuck. Turn the Xbox fully off by holding the power button for 10 seconds (waking it from sleep isn't enough), turn it back on, then start translation again.";

    /// <summary>Oynanan yayın koptu, sessiz yeniden bağlanma sınırı doldu (Mac/iPhone XboxText.stopped, Android xbox_stopped_dropped).</summary>
    public const string DroppedStopped = "The Xbox connection dropped. Press Reconnect; if it keeps dropping, connect the Xbox with a network cable or restart it.";

    /// <summary>Bağlantıda görüntü gelmedi, bir kez daha deneniyor (Android xbox_error_no_first_frame).</summary>
    public const string NoPictureRetrying = "No picture came from the Xbox. Trying once more…";

    public static string Shorten(string? reason, int limit = ReasonLimit, string fallback = "?")
    {
        var line = string.IsNullOrWhiteSpace(reason) ? fallback : Whitespace().Replace(reason.Trim(), " ");
        return line.Length <= limit ? line : line[..(limit - 1)] + "…";
    }

    /// <summary>
    /// Bağlantı bitince yazılan özet (Android'deki <c>summarize</c> ile aynı biçim): neden, okumaya giden kare sayısı ve
    /// ilk kareden sonra kaç saniye sürdüğü. "Görüntü hiç gelmedi" ile "görüntü geldi, sonra kesildi" bu satırla ayrılır.
    /// </summary>
    public static string Summary(string? reason, long frames, TimeSpan? sinceFirstFrame, XboxEndCause? cause = null) =>
        string.Create(CultureInfo.InvariantCulture,
            $"bağlantı bitti{(cause is { } c ? $" ({c.Text()})" : "")}: {(string.IsNullOrWhiteSpace(reason) ? "durduruldu" : reason)}; kare {frames}, ilk kareden sonra {(sinceFirstFrame is { } lived ? $"{(long)lived.TotalSeconds} sn" : "ilk kare yok")}");

    /// <summary>Xbox köprüsünün (node) hata çıktısındaki uzun belirteç benzeri dizileri gizler; satırı kısaltır.</summary>
    public static string RedactBridgeOutput(string? output, int limit = 300)
    {
        if (string.IsNullOrWhiteSpace(output)) return "";
        var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        var tail = string.Join(" | ", lines.TakeLast(3));
        tail = TokenLike().Replace(tail, "[gizlendi]");
        return tail.Length <= limit ? tail : "…" + tail[^(limit - 1)..];
    }

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    [GeneratedRegex(@"Agent\s*:\s*(-?\d+)")]
    private static partial Regex AgentCode();

    [GeneratedRegex(@"\b0[xX]([0-9A-Fa-f]{8})\b")]
    private static partial Regex HexCode();

    [GeneratedRegex(@"""(?:code|errorCode|hresult)""\s*:\s*""?(-?[A-Za-z0-9_.]+)")]
    private static partial Regex CodeField();

    [GeneratedRegex(@"""(?:message|errorMessage)""\s*:\s*""((?:[^""\\]|\\.)*)""")]
    private static partial Regex MessageField();

    [GeneratedRegex(@"\\(.)")]
    private static partial Regex JsonEscape();

    [GeneratedRegex(@"[A-Za-z0-9_\-\.=+/]{40,}")]
    private static partial Regex TokenLike();
}
