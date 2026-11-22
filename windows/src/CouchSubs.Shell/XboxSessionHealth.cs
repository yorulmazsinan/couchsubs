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
}

/// <summary>
/// Kopmadan sonra yeniden denenir mi, ne kadar sonra (Android/CouchSubsCore XboxSessionMachine.fail ile aynı kurallar).
/// Hata ya da kopmada 5, 15, 45 sn sonra baştan denenir; yayın <see cref="HealthyStreamMs"/> ayakta kaldıysa sayaç
/// sıfırlanır. Xbox'tan hiç görüntü gelmeyen bağlantılar ayrıca sayılır: <see cref="MaxNoPictureAttempts"/> ardışık
/// bağlantıda ilk kare gelmezse yeniden denenmez. Eskiden her biri Xbox'ta "uzaktan oynatma başlatıldı / durduruldu"
/// bildirimiyle dört kez (yaklaşık beş dakika) açılıp kapanıyor, ekranda yalnız "WebRTC bağlantısı kesildi" görünüyordu (#403).
/// </summary>
public sealed class XboxRetryPlan
{
    public static readonly int[] DelaysMs = [5000, 15000, 45000];
    public const long HealthyStreamMs = 60_000;
    public const int MaxNoPictureAttempts = 2;

    private int noPicture;

    /// <summary>Ardışık başarısız deneme (1…3).</summary>
    public int Failures { get; private set; }

    /// <summary>İlk kare geldi: görüntüsüz bağlantı dizisi biter.</summary>
    public void PictureArrived() => noPicture = 0;

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
        if (permanent || XboxStop.IsPermanent(reason) || Failures > DelaysMs.Length || noPicture >= MaxNoPictureAttempts) return null;
        return DelaysMs[Failures - 1];
    }
}

/// <summary>Yayının neden durduğu (kullanıcıya gösterilen metni seçer).</summary>
/// <remarks>
/// <c>ServiceNotReady</c>: Xbox uzaktan oynatma hizmetini başlatamadı ("Timed out waiting for Cloud Streaming Service to be
/// ready", 0x8007139F); <c>StartFailed</c>: Xbox bilinmeyen bir hata koduyla yayını reddetti (#871).
/// </remarks>
public enum XboxStopKind { Busy, ConsoleUnavailable, NoPicture, ServiceNotReady, StartFailed, Other }

/// <summary>Xbox yayını durunca günlük satırı ve kullanıcıya gösterilen metin. Android'deki XboxSessionMachine.classifyFailure ile aynı kurallar.</summary>
public static partial class XboxStop
{
    /// <summary>Kullanıcı metninde gösterilen ham nedenin en çok uzunluğu (Xbox hizmeti 500 karakterlik JSON dönebilir).</summary>
    public const int ReasonLimit = 120;

    /// <param name="noFirstFrame">Son bağlantı Xbox'tan tek kare gelmeden bitti.</param>
    public static XboxStopKind Classify(string? reason, bool noFirstFrame = false)
    {
        if (noFirstFrame) return XboxStopKind.NoPicture;
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
    public static string Message(Localizer text, string? reason, bool noFirstFrame = false)
    {
        var kind = Classify(reason, noFirstFrame);
        return kind switch
        {
            XboxStopKind.NoPicture => text[NoPictureStopped],
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
    public static string Summary(string? reason, long frames, TimeSpan? sinceFirstFrame) =>
        string.Create(CultureInfo.InvariantCulture,
            $"bağlantı bitti: {(string.IsNullOrWhiteSpace(reason) ? "durduruldu" : reason)}; kare {frames}, ilk kareden sonra {(sinceFirstFrame is { } lived ? $"{(long)lived.TotalSeconds} sn" : "ilk kare yok")}");

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
