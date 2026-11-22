// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>
/// "Günlüğü Kopyala" (üst çubuk ve hata kutuları): %LOCALAPPDATA%\CouchSubs içindeki güncel günlükler (altyazi.log,
/// remoteplay.log, tvinstall.log, hata.log ve diğer .log dosyaları, varsa .1 yedekleri) maskelenerek tek zip'e konur.
/// Maskeleme kuralları Mac (core/LogShare.swift) ve Android (LogShare.kt) ile aynıdır ve ortak deneme dosyası
/// core/Tests/CouchSubsCoreTests/Fixtures/log-redaction.json ile sınanır: hesap kimliği, e-posta, jeton, eşleştirme
/// anahtarı, parola, passphrase, API anahtarı ve uzun kimlik dizileri <c>***</c> olur; yerel IP, saat ve hata kodu kalır.
/// </summary>
public static class LogShare
{
    /// <summary>Her günlükten alınan en çok bayt (dosyanın sonu).</summary>
    public const int MaxBytesPerLog = 2_000_000;

    /// <summary>Bu kadar günden eski günlük alınmaz.</summary>
    public static readonly TimeSpan MaxAge = TimeSpan.FromDays(14);

    private static readonly string[] SecretKeys =
    [
        "hesap kimliği", "account ?id", "account_id", "accountid", "psn ?id", "online ?id", "user ?id", "user_id",
        "rp-?regist-?key", "regist_?key", "registkey", "rp_?key", "rp-key", "rpkey", "morning", "rp-auth", "rp-did",
        "session ?id", "sessionid", "host-?id", "npsso", "access_token", "refresh_token", "id_token", "token",
        "authorization", "password", "passcode", "client_secret", "xuid", "gamertag", "uhs", "userhash", "email", "e-posta",
        "passphrase", "api[ _-]?key", "apikey", "client[ _-]?secret", "secret",
    ];

    private static readonly (Regex Pattern, string Template)[] Rules = BuildRules();

    private static (Regex, string)[] BuildRules()
    {
        static (Regex, string) Rule(string pattern, string template) =>
            (new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant), template);
        var keys = string.Join("|", SecretKeys);
        return
        [
            Rule(@"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", "***@***"),
            Rule(@"\b(Bearer|XBL3\.0)\s+[^\s""',]+", "$1 ***"),
            Rule(@"(\b(?:" + keys + @")[""']?\s*[:=]\s*[""']?)[^\s""',;&}\])]+", "$1***"),
            Rule(@"(\b(?:hesap kimliği|session ?id)\s+[""']?)[^\s""',;&}\])]+", "$1***"),
            Rule(@"([?&](?:code|state)=)[^\s&""']+", "$1***"),
            Rule(@"(?<![A-Z0-9+_-])[A-Z0-9+_-]{32,}={0,2}", "***"),
        ];
    }

    /// <summary>Metindeki kişisel verileri maskeler; IP adresleri, saatler ve hata kodları kalır.</summary>
    public static string Redact(string text)
    {
        foreach (var (pattern, template) in Rules) text = pattern.Replace(text, template);
        return text;
    }

    /// <summary>"CouchSubs-gunluk-20261122-1830.zip" (Mac ile aynı ad).</summary>
    public static string ZipName(DateTime now) => $"CouchSubs-gunluk-{now.ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture)}.zip";

    /// <summary>Güncel günlük dosyaları (.log ve .log.1), ada göre sıralı.</summary>
    public static IReadOnlyList<string> Logs(string folder, DateTime now)
    {
        if (!Directory.Exists(folder)) return [];
        return
        [
            .. Directory.EnumerateFiles(folder)
                .Where(f => f.EndsWith(".log", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".log.1", StringComparison.OrdinalIgnoreCase))
                .Where(f => now - File.GetLastWriteTime(f) <= MaxAge)
                .OrderBy(f => Path.GetFileName(f), StringComparer.Ordinal),
        ];
    }

    /// <summary>Günlükleri maskeleyip <paramref name="targetFolder"/> içine zip olarak yazar; zip'in yolunu döner.</summary>
    public static string MakeZip(string sourceFolder, string targetFolder, string header, DateTime now)
    {
        Directory.CreateDirectory(targetFolder);
        var target = Path.Combine(targetFolder, ZipName(now));
        if (File.Exists(target)) File.Delete(target);
        using var zip = ZipFile.Open(target, ZipArchiveMode.Create);
        Write(zip, "CouchSubs-gunluk/bilgi.txt", header + "\n");
        foreach (var file in Logs(sourceFolder, now))
            if (Tail(file) is { } text) Write(zip, $"CouchSubs-gunluk/{Path.GetFileName(file)}", Redact(text));
        return target;
    }

    private static void Write(ZipArchive zip, string name, string text)
    {
        using var stream = zip.CreateEntry(name, CompressionLevel.Optimal).Open();
        var bytes = Encoding.UTF8.GetBytes(text);
        stream.Write(bytes);
    }

    /// <summary>Dosyanın son <see cref="MaxBytesPerLog"/> baytı; kesilen ilk satır atılır. Uygulama yazarken de okunur.</summary>
    public static string? Tail(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var start = Math.Max(0, stream.Length - MaxBytesPerLog);
            stream.Seek(start, SeekOrigin.Begin);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var text = reader.ReadToEnd();
            if (text.Length == 0) return null;
            if (start > 0 && text.IndexOf('\n') is var newline and >= 0) text = text[(newline + 1)..];
            return text;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
