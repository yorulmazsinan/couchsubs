// SPDX-License-Identifier: AGPL-3.0-only
// Mac/iPhone'daki LgHdPackage.swift (core) ve Android'deki LgHdPackage.kt ile aynı.

using System.IO.Compression;
using System.Text;
using System.Text.RegularExpressions;

namespace CouchSubs.Core.LgTv;

/// <summary>
/// LG Full HD webOS 3.x TV'lere (2016-2017; 43LH590V, #1098) 1280x720 paket.
/// LG: Full HD modellerin grafik çözünürlüğü en çok 1280x720; uygulamanın çözünürlüğü appinfo.json'daki
/// <c>resolution</c> ile belirlenir (varsayılan 1920x1080) ve LG, Full HD modeller için ayrı bir 1280x720 paket önerir
/// (webostv.developer.lge.com, "Supported App Resolution"). 43LH590V'de 1920x1080 paket sayfayı 1920x1080 CSS pikselinde
/// düzenliyor ama yalnız sol üst 1280x720'sini çiziyordu; görünüm etiketi (0.9.113) de sayfa açılırken alınan görünüm
/// (0.9.117) de bunu değiştirmedi. Kurulumdan önce TV'nin modeli, UHD olup olmadığı ve webOS sürümü sorulur; Full HD
/// webOS 3.x TV'de paketteki appinfo.json'un <c>resolution</c> değeri 1280x720 yapılır. Sayfa 1280x720 görünümde açılır,
/// tv-webos/platform.js onu CSS zoom ile 1920x1080 uzayına sığdırır. Diğer bütün LG'lere paket değişmeden gider.
/// </summary>
public static partial class LgHdPackage
{
    public const string Resolution = "1280x720";

    /// <summary>TV'nin modeli, UHD olup olmadığı ve SDK (webOS) sürümü.</summary>
    public const string SystemInfoCommand =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.service.tv.systemproperty/getSystemInfo' " +
        "'{\"keys\":[\"modelName\",\"UHD\",\"sdkVersion\"]}'";

    public sealed record Screen(string? Model, bool? Uhd, string? SdkVersion, bool Hd)
    {
        /// <summary>Günlük satırı: "43LH590V-ZE, UHD false, sdk 03.70.50 → 1280x720".</summary>
        public string Summary =>
            $"{Model ?? "?"}, UHD {(Uhd is { } uhd ? (uhd ? "true" : "false") : "?")}, sdk {SdkVersion ?? "?"} → {(Hd ? Resolution : "1920x1080")}";
    }

    /// <summary>
    /// getSystemInfo yanıtı → karar. 2016 (LH) ve 2017 (LJ) Full HD serisi ya da UHD olmayan webOS 3.x TV 1280x720 alır;
    /// TV UHD diyorsa ya da yanıt okunamazsa paket değişmez.
    /// </summary>
    public static Screen ScreenOf(string reply)
    {
        var model = Field(reply, "modelName") is { Length: > 0 } m ? m : null;
        bool? uhd = Field(reply, "UHD")?.ToLowerInvariant() switch { "true" => true, "false" => false, _ => null };
        var sdk = Field(reply, "sdkVersion") is { Length: > 0 } s ? s : null;
        var digits = sdk is null ? "" : new string(sdk.TakeWhile(char.IsAsciiDigit).ToArray());
        int? major = int.TryParse(digits, out var value) ? value : null;
        var fhdLine = model is not null && FhdLine().IsMatch(model);
        var hd = uhd != true && (fhdLine || (uhd == false && major == 3));
        return new Screen(model, uhd, sdk, hd);
    }

    internal static string? Field(string text, string key)
    {
        var match = Regex.Match(text ?? "", $"\"{Regex.Escape(key)}\"\\s*:\\s*(?:\"([^\"]*)\"|([A-Za-z0-9.]+))");
        if (!match.Success) return null;
        return (match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value).Trim();
    }

    [GeneratedRegex(@"^\d{2,3}L[HJ]\d", RegexOptions.IgnoreCase)]
    private static partial Regex FhdLine();

    // --- Paket ---

    /// <summary>
    /// Paketteki appinfo.json'un <c>"resolution": "1920x1080"</c> değeri <c>"1280x720" </c> olur (aynı uzunlukta; tar başlığı
    /// ve sağlaması değişmez). data.tar.gz yeniden sıkıştırılır, ar başlığındaki boyut yazılır; başka hiçbir bayt değişmez.
    /// Paket beklenen biçimde değilse ya da değer zaten değiştiyse null.
    /// </summary>
    public static byte[]? Adapt(byte[] ipk)
    {
        var members = ReadAr(ipk);
        var index = members?.FindIndex(m => m.Name == "data.tar.gz") ?? -1;
        if (members is null || index < 0) return null;
        byte[] tar;
        try
        {
            using var input = new GZipStream(new MemoryStream(members[index].Body), CompressionMode.Decompress);
            using var output = new MemoryStream();
            input.CopyTo(output);
            tar = output.ToArray();
        }
        catch (InvalidDataException)
        {
            return null;
        }
        if (!AdaptTar(tar)) return null;
        using (var compressed = new MemoryStream())
        {
            using (var gzip = new GZipStream(compressed, CompressionLevel.Optimal, leaveOpen: true)) gzip.Write(tar);
            members[index] = members[index] with { Body = compressed.ToArray() };
        }
        return WriteAr(members);
    }

    internal sealed record ArMember(byte[] Header, byte[] Body)
    {
        public string Name => Encoding.ASCII.GetString(Header, 0, 16).Trim().Trim('/');
    }

    private static readonly byte[] ArMagic = "!<arch>\n"u8.ToArray();

    internal static List<ArMember>? ReadAr(byte[] data)
    {
        if (data.Length < ArMagic.Length || !data.AsSpan(0, ArMagic.Length).SequenceEqual(ArMagic)) return null;
        var members = new List<ArMember>();
        var offset = ArMagic.Length;
        while (offset < data.Length)
        {
            if (offset + 60 > data.Length || data[offset + 58] != 0x60 || data[offset + 59] != 0x0A) return null;
            var header = data.AsSpan(offset, 60).ToArray();
            if (!int.TryParse(Encoding.ASCII.GetString(header, 48, 10).Trim(), out var size) || size < 0 ||
                offset + 60 + size > data.Length) return null;
            members.Add(new ArMember(header, data.AsSpan(offset + 60, size).ToArray()));
            offset += 60 + size + (size & 1);
        }
        return members;
    }

    internal static byte[] WriteAr(List<ArMember> members)
    {
        using var output = new MemoryStream();
        output.Write(ArMagic);
        foreach (var member in members)
        {
            var header = (byte[])member.Header.Clone();
            var size = Encoding.ASCII.GetBytes(member.Body.Length.ToString(System.Globalization.CultureInfo.InvariantCulture));
            for (var i = 0; i < 10; i++) header[48 + i] = i < size.Length ? size[i] : (byte)' ';
            output.Write(header);
            output.Write(member.Body);
            if ((member.Body.Length & 1) == 1) output.WriteByte(0x0A);
        }
        return output.ToArray();
    }

    /// <summary>tar'daki uygulama appinfo.json'unu bulur ve çözünürlüğü yazar. Değiştiyse true.</summary>
    internal static bool AdaptTar(byte[] tar)
    {
        var offset = 0;
        while (offset + 512 <= tar.Length)
        {
            if (tar.AsSpan(offset, 512).IndexOfAnyExcept((byte)0) < 0) return false;
            string Text(int from, int count)
            {
                var span = tar.AsSpan(offset + from, count);
                var end = span.IndexOf((byte)0);
                return Encoding.UTF8.GetString(end < 0 ? span : span[..end]);
            }
            var prefix = Text(345, 155);
            var name = (prefix.Length == 0 ? "" : prefix + "/") + Text(0, 100);
            var octal = Text(124, 12).Trim();
            int size;
            try { size = octal.Length == 0 ? 0 : Convert.ToInt32(octal, 8); }
            catch (FormatException) { return false; }
            var start = offset + 512;
            if (size < 0 || start + size > tar.Length) return false;
            if (IsAppInfo(name))
            {
                if (AdaptAppInfo(Encoding.UTF8.GetString(tar, start, size)) is not { } adapted) return false;
                var bytes = Encoding.UTF8.GetBytes(adapted);
                if (bytes.Length != size) return false;
                bytes.CopyTo(tar, start);
                return true;
            }
            offset = start + (size + 511) / 512 * 512;
        }
        return false;
    }

    internal static bool IsAppInfo(string name) => name.EndsWith("/appinfo.json", StringComparison.Ordinal) && name.Contains("palm/applications/");

    /// <summary><c>"resolution": "1920x1080"</c> → <c>"resolution": "1280x720" </c> (uzunluk aynı); değer yoksa null.</summary>
    public static string? AdaptAppInfo(string text)
    {
        var match = Regex.Match(text, "\"resolution\"\\s*:\\s*\"1920x1080\"");
        if (!match.Success) return null;
        var value = match.Value.Replace("\"1920x1080\"", $"\"{Resolution}\" ");
        return text[..match.Index] + value + text[(match.Index + match.Length)..];
    }
}
