// SPDX-License-Identifier: AGPL-3.0-only
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace CouchSubs.Core;

/// <summary>TV, OBS ve telefonun ortak erişim kuralları. Anahtarlar hiçbir zaman günlüklenmez.</summary>
public static class SubtitleAccess
{
    // Yalnız geçiş sürümü: sonraki sürümde false yapılmalı.
    public const bool AllowLegacyClients = true;
    public static string CreateKey() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(16)).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static bool IsLocalPeer(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        var b = address.GetAddressBytes();
        if (IPAddress.IsLoopback(address)) return true;
        if (b.Length == 16) return (b[0] & 0xfe) == 0xfc || b[0] == 0xfe && (b[1] & 0xc0) == 0x80;
        return b[0] == 10 || b[0] == 172 && b[1] >= 16 && b[1] <= 31 || b[0] == 192 && b[1] == 168
            || b[0] == 169 && b[1] == 254 || b[0] == 100 && b[1] >= 64 && b[1] <= 127;
    }

    /// <summary>
    /// Eşleştirme isteği gönderen TV'nin geri bağlanılacak adresi: IPv4'e eşlenmiş IPv6 düz IPv4 olur, bağlantı arayüzü
    /// atılır. Bu cihazın kendisi (loopback; ikinci ekran sayfası) ve yerel olmayan adres TV sayılmaz: boş döner
    /// (Mac/iPhone <c>SubtitleAccess.tvHost</c>, Android ile aynı kural).
    /// </summary>
    public static string TvHost(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || !IsLocalPeer(address)) return "";
        if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 && address.ScopeId != 0) address = new IPAddress(address.GetAddressBytes());
        return address.ToString();
    }

    public sealed record Request(string Method, string Target, string? Origin, string Host)
    {
        public string Path => Target.Split('?')[0];
        public string? Parameter(string name)
        {
            var query = Target.IndexOf('?');
            if (query < 0) return null;
            string? result = null;
            foreach (var pair in Target[(query + 1)..].Split('&'))
            {
                var parts = pair.Split('=', 2);
                if (Uri.UnescapeDataString(parts[0]) != name) continue;
                if (result is not null) return ""; // Çift anahtarlı belirsiz istek reddedilir.
                result = parts.Length == 2 ? Uri.UnescapeDataString(parts[1]) : "";
            }
            return result;
        }
    }

    public static Request? Parse(string head)
    {
        var lines = head.Split("\r\n");
        var first = lines[0].Split(' ');
        if (first.Length != 3 || !first[1].StartsWith('/')) return null;
        string? origin = null;
        string? host = null;
        foreach (var line in lines.Skip(1).TakeWhile(l => l.Length > 0))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0 || char.IsWhiteSpace(line[0])) return null;
            var name = line[..colon];
            var value = line[(colon + 1)..].Trim();
            if (value.Any(c => c < 32 || c > 126)) return null;
            if (name.Equals("Origin", StringComparison.OrdinalIgnoreCase))
            {
                if (origin is not null) return null;
                origin = value;
            }
            if (name.Equals("Host", StringComparison.OrdinalIgnoreCase))
            {
                if (host is not null) return null;
                host = value;
            }
        }
        return new(first[0], first[1], origin, host ?? "");
    }

    // Paketli TV uygulamaları: webOS/Android TV "null", Samsung Tizen ise (en az 5.0'da, POST isteklerinde) "file://" gönderir.
    // Eski webOS (4.x) "file:///" ya da yol ekli "file:///..." gönderebilir (GitHub #1132): ana makinesi boş, sorgu/parça/kullanıcı
    // içermeyen her file: değeri kabul edilir. Web sayfaları file: Origin'i üretemez; "file://evil.example" gibi ana makineli değerler reddedilir.
    private static bool PackagedOrigin(string origin) => origin is "null" || IsFileOrigin(origin) ||
        Uri.TryCreate(origin, UriKind.Absolute, out var url) && url.Scheme == "app" && url.Host.Length > 0
        && url.UserInfo.Length == 0 && url.Query.Length == 0 && url.Fragment.Length == 0 && url.AbsolutePath is "" or "/";

    /// <summary>Ana makinesiz file: Origin'i: "file://", "file:///" ya da "file:///yol". Sorgu, parça, kullanıcı ve ters bölü yok.</summary>
    public static bool IsFileOrigin(string origin)
    {
        if (!origin.StartsWith("file://", StringComparison.Ordinal)) return false;
        var rest = origin[7..];
        return rest.Length == 0 || rest.StartsWith('/') && rest.IndexOfAny(['?', '#', '@', '\\']) < 0;
    }

    /// <summary>403 alan isteğin günlük satırı (GitHub #1132): reddedilen Origin değeri olduğu gibi (en çok 120 karakter) yazılır.</summary>
    public static string RejectedOriginLine(Request request)
    {
        var origin = request.Origin ?? "";
        var host = request.Host;
        return $"altyazı sunucusu isteği reddetti (403): Origin \"{origin[..Math.Min(origin.Length, 120)]}\" kabul edilmedi (yol {request.Path}, Host {host[..Math.Min(host.Length, 80)]})";
    }

    /// <summary>Reddedilen Origin değerlerini günlüğe bir kez yazdırır: aynı değer tekrar yazılmaz, en çok 16 farklı değer.</summary>
    public sealed class RejectedOrigins
    {
        private readonly HashSet<string> seen = [];
        /// <summary>Yazılacak satır; bu Origin daha önce yazıldıysa ya da sınır dolduysa null.</summary>
        public string? Line(Request request)
        {
            bool fresh;
            lock (seen) fresh = seen.Count < 16 && seen.Add(request.Origin ?? "");
            return fresh ? RejectedOriginLine(request) : null;
        }
    }

    public static bool OriginAllowed(Request request)
    {
        if (request.Origin is null || PackagedOrigin(request.Origin)) return true;
        if (!Uri.TryCreate(request.Origin, UriKind.Absolute, out var origin) || origin.Scheme != "http"
            || origin.UserInfo.Length != 0 || origin.AbsolutePath != "/" || origin.Query.Length != 0 || origin.Fragment.Length != 0) return false;
        return Uri.TryCreate("http://" + request.Host, UriKind.Absolute, out var local)
            && local.UserInfo.Length == 0 && local.AbsolutePath == "/" && local.Query.Length == 0 && local.Fragment.Length == 0
            && origin.Host.Equals(local.Host, StringComparison.OrdinalIgnoreCase) && origin.Port == local.Port;
    }

    public static string Cors(Request request) => request.Origin is { } origin && PackagedOrigin(origin)
        ? $"Access-Control-Allow-Origin: {origin}\r\nVary: Origin\r\n" : "";

    public static int Authorize(Request request, string key, bool allowLegacy, out bool legacy)
    {
        legacy = false;
        if (!OriginAllowed(request)) return 403;
        if (request.Path is "/hello" or "/obs" or "/pair") return 200;
        var supplied = request.Parameter("k");
        // İkinci ekran (sayfası ve akışı) eski TV'lere tanınan anahtarsız geçişten yararlanmaz: aynı ağdaki herkes açamaz.
        if (supplied is null && allowLegacy && !IsSecondScreen(request) && (request.Origin is null || PackagedOrigin(request.Origin)))
        {
            legacy = true;
            return 200;
        }
        return supplied is not null && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(key), Encoding.UTF8.GetBytes(supplied)) ? 200 : 401;
    }

    /// <summary>Başka bir cihazın tarayıcısında açılan altyazı sayfası (<c>/view</c>) ya da onun akışı (<c>/events?viewer=second</c>).</summary>
    public static bool IsSecondScreen(Request request) =>
        request.Path == SecondScreen.Path || request.Path == "/events" && request.Parameter("viewer") == SecondScreen.Viewer;
}
