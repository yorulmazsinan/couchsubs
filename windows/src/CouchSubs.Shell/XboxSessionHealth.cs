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

/// <summary>Yayının neden durduğu (kullanıcıya gösterilen metni seçer).</summary>
public enum XboxStopKind { Busy, ConsoleUnavailable, Other }

/// <summary>Xbox yayını durunca günlük satırı ve kullanıcıya gösterilen metin. Android'deki XboxSessionMachine.classifyFailure ile aynı kurallar.</summary>
public static partial class XboxStop
{
    /// <summary>Kullanıcı metninde gösterilen ham nedenin en çok uzunluğu (Xbox hizmeti 500 karakterlik JSON dönebilir).</summary>
    public const int ReasonLimit = 120;

    public static XboxStopKind Classify(string? reason)
    {
        var text = reason ?? "";
        bool Has(string word) => text.Contains(word, StringComparison.OrdinalIgnoreCase);
        if (Has("InUse") || Has("Busy") || Has("AlreadyStreaming")) return XboxStopKind.Busy;
        if (Has("Offline") || Has("NotFound") || Has("Unavailable") || Has("PowerOff") || Has("StreamingDisabled"))
            return XboxStopKind.ConsoleUnavailable;
        return XboxStopKind.Other;
    }

    /// <summary>Denemeler bitince ya da konsol yayını reddedince gösterilen metin.</summary>
    public static string Message(Localizer text, string? reason) => Classify(reason) switch
    {
        XboxStopKind.Busy => text["Your Xbox is streaming to another device (the Xbox app, a phone or a PC). Close that session, then start translation again."],
        XboxStopKind.ConsoleUnavailable => text["Can't reach your Xbox. Make sure it's on and remote play is enabled in Settings › Devices & connections › Remote features, then start translation again."],
        _ => text.Format("The Xbox stream stopped (%@). Start translation again; if it keeps stopping, restart the Xbox.", Shorten(reason)),
    };

    public static string Shorten(string? reason, int limit = ReasonLimit)
    {
        var line = string.IsNullOrWhiteSpace(reason) ? "?" : Whitespace().Replace(reason.Trim(), " ");
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

    [GeneratedRegex(@"[A-Za-z0-9_\-\.=+/]{40,}")]
    private static partial Regex TokenLike();
}
