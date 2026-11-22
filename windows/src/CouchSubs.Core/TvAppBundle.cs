// SPDX-License-Identifier: AGPL-3.0-only

using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CouchSubs.Core;

/// <summary>
/// TV uygulamasının sayfa kodu (ince kabuk, docs/tv-ince-kabuk.md). TV'de kurulu kabuk bağlandığı bilgisayardan bu
/// dosyaları <c>GET /tv/app/manifest</c> ve <c>GET /tv/app/&lt;sürüm&gt;/&lt;dosya&gt;</c> ile alır; TV uygulaması
/// CouchSubs güncellenince yeniden kurulmadan güncellenir. Mac/iPhone <c>TVAppBundle.swift</c>, Android
/// <c>TvAppBundle.kt</c> ile aynı. Liste eşleşme anahtarıyla HMAC-SHA256 imzalıdır, her dosyanın SHA-256 özeti listededir.
/// </summary>
public sealed partial class TvAppBundle
{
    /// <summary>Sunulan dosyalar ve sırası (index.html'den yalnız <c>&lt;body&gt;</c> işaretlemesi kullanılır).</summary>
    public static readonly IReadOnlyList<string> Paths = ["index.html", "style.css", "i18n.js", "app.js"];
    public const int Format = 1;
    public const string Prefix = "/tv/app/";
    public const string ManifestPath = "/tv/app/manifest";
    /// <summary>Sürümlü adresteki dosya değişmez: TV tarayıcısı önbellekte tutabilir (kabuk yine de özeti doğrular).</summary>
    public const string FileCache = "private, max-age=31536000, immutable";

    public sealed record File(string Path, byte[] Data, string Sha256);

    public string Version { get; }
    public int ShellApi { get; }
    public IReadOnlyList<File> Files { get; }

    private TvAppBundle(string version, int shellApi, IReadOnlyList<File> files)
    {
        Version = version;
        ShellApi = shellApi;
        Files = files;
    }

    [GeneratedRegex(@"var APP_VERSION = '([0-9]+(?:\.[0-9]+){1,3})';")]
    private static partial Regex VersionPattern();

    [GeneratedRegex(@"var SHELL_API = ([0-9]{1,3});")]
    private static partial Regex ShellApiPattern();

    /// <summary>Dört dosyanın hepsi varsa ve app.js sürümü ile kabuk arayüzü sürümünü bildiriyorsa paket kurulur.</summary>
    public static TvAppBundle? Create(IReadOnlyDictionary<string, byte[]> files)
    {
        var list = new List<File>();
        foreach (var path in Paths)
        {
            if (!files.TryGetValue(path, out var data) || data.Length == 0) return null;
            list.Add(new File(path, data, Convert.ToHexStringLower(SHA256.HashData(data))));
        }
        var app = Encoding.UTF8.GetString(files["app.js"]);
        var version = VersionPattern().Match(app);
        var shell = ShellApiPattern().Match(app);
        if (!version.Success || !shell.Success || !int.TryParse(shell.Groups[1].Value, out var api) || api < 1) return null;
        return new TvAppBundle(version.Groups[1].Value, api, list);
    }

    /// <summary>Uygulamaya gömülü TV sayfası (CouchSubs.Core.csproj: tv-webos'tan). Yoksa <c>/tv/app</c> 404 döner.</summary>
    public static TvAppBundle? Bundled { get; } = LoadEmbedded();

    private static TvAppBundle? LoadEmbedded()
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        foreach (var path in Paths)
        {
            using var stream = typeof(TvAppBundle).Assembly.GetManifestResourceStream("tv-webos/" + path);
            if (stream is null) return null;
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            files[path] = memory.ToArray();
        }
        return Create(files);
    }

    public static bool IsPath(string path) => path.StartsWith(Prefix, StringComparison.Ordinal);

    /// <summary>İmzalanan metin: biçim, sürüm, kabuk arayüzü ve her dosya için "ad boyut özet" satırı.</summary>
    public string Canonical
    {
        get
        {
            var text = new StringBuilder($"couchsubs-tv-app/{Format}\n{Version}\n{ShellApi}\n");
            foreach (var file in Files) text.Append(file.Path).Append(' ').Append(file.Data.Length).Append(' ').Append(file.Sha256).Append('\n');
            return text.ToString();
        }
    }

    public static string Signature(string canonical, string key) =>
        Convert.ToHexStringLower(HMACSHA256.HashData(Encoding.UTF8.GetBytes(key), Encoding.UTF8.GetBytes(canonical)));

    /// <summary><c>GET /tv/app/manifest</c> yanıtı.</summary>
    public string Manifest(string key) => JsonSerializer.Serialize(new
    {
        files = Files.Select(f => new { path = f.Path, sha256 = f.Sha256, size = f.Data.Length }),
        format = Format,
        hmac = Signature(Canonical, key),
        shellApi = ShellApi,
        version = Version,
    });

    /// <summary><c>/tv/app/&lt;sürüm&gt;/&lt;dosya&gt;</c>: yalnız bu paketin sürümü ve listedeki dosyalar.</summary>
    public File? FileAt(string path)
    {
        if (!IsPath(path)) return null;
        var rest = path[Prefix.Length..].Split('/');
        if (rest.Length != 2 || rest[0] != Version) return null;
        return Files.FirstOrDefault(f => f.Path == rest[1]);
    }

    public static string ContentType(string path) =>
        path.EndsWith(".html", StringComparison.Ordinal) ? "text/html; charset=utf-8"
        : path.EndsWith(".css", StringComparison.Ordinal) ? "text/css; charset=utf-8"
        : "application/javascript; charset=utf-8";
}
