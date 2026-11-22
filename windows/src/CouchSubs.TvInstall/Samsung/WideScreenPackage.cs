// SPDX-License-Identifier: AGPL-3.0-only
// Android'deki WideScreenPackage.kt ve iPhone'daki WideScreenPackage.swift ile aynı.

using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CouchSubs.TvInstall.Samsung;

/// <summary>
/// 21:9 / 32:9 Samsung akıllı monitörler (Odyssey G9 49", #886) için paket, 0.9.27–0.9.54'teki gibi geniş uygulama
/// yüzeyiyle kurulur: config.xml'e <c>base_screen_resolution=fullscreen</c>, index.html'e <c>width=device-width</c>
/// görünümü. Samsung yüzeyi ancak ikisi birlikteyken ekranın tamamı yapar; platform.js geniş yüzeyi görünce HDMI
/// görüntüsünü 16:9 sığdırır, Sarı ile ekranı doldurur. 0.9.55'te ayar her TV'den kaldırılmıştı (4K/8K TV'de yüzeyi
/// panel pikselinde açıp PS5 görüntüsünü sol üst köşede bırakıyordu, #799); o günden beri G9'da uygulama 16:9 kutuda,
/// TVWindow da 3840x1080'i NotSupportedError ile reddediyor. TV'lere (16:9) paket değişmeden gider.
/// </summary>
internal static partial class WideScreenPackage
{
    /// <summary>16:9'dan (1,78) belirgin geniş (21:9 = 2,33; 32:9 = 3,56); platform.js'teki WIDE_RATIO.</summary>
    private const double WideRatio = 1.9;

    internal const string Metadata =
        "<tizen:metadata key=\"http://tizen.org/metadata/app_ui_type/base_screen_resolution\" value=\"fullscreen\"/>";

    /// <summary>
    /// TV'nin 8001 yanıtındaki model adı (<c>LS49…</c> 32:9, <c>LS34…</c> 21:9, <c>LS57…</c> 32:9 Samsung monitör) ya da
    /// çözünürlüğü (<c>5120x1440</c>) ultra geniş bir ekran mı söylüyor?
    /// </summary>
    public static bool Applies(string? modelName, string? resolution)
    {
        if (modelName is { Length: > 0 } && MonitorModel().IsMatch(modelName.Trim())) return true;
        var size = Resolution().Match(resolution ?? "");
        return size.Success && double.Parse(size.Groups[2].Value) > 0 &&
               double.Parse(size.Groups[1].Value) / double.Parse(size.Groups[2].Value) >= WideRatio;
    }

    /// <summary>8001 yanıtındaki <c>device.modelName</c> ve <c>device.resolution</c>; yoksa null.</summary>
    internal static (string? Model, string? Resolution) ScreenInfo(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            if (!document.RootElement.TryGetProperty("device", out var device) || device.ValueKind != JsonValueKind.Object)
                return (null, null);
            string? Field(string name) => device.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
                ? value.GetString()?.Trim() is { Length: > 0 } text ? text : null
                : null;
            return (Field("modelName"), Field("resolution"));
        }
        catch (JsonException)
        {
            return (null, null);
        }
    }

    internal static string AdaptConfig(string config)
    {
        if (config.Contains("app_ui_type/base_screen_resolution\"")) return config;
        var end = config.LastIndexOf("</widget>", StringComparison.Ordinal);
        return end < 0 ? config : config[..end] + "    " + Metadata + "\n" + config[end..];
    }

    internal static string AdaptPage(string html) =>
        html.Replace("<meta name=\"viewport\" content=\"width=1920\">", "<meta name=\"viewport\" content=\"width=device-width\">");

    /// <summary>İmzalanmadan önceki geçici kopyada config.xml ve index.html geniş yüzeye göre yazılır. Değiştiyse true.</summary>
    public static bool Adapt(string wgtPath)
    {
        var changed = new Dictionary<string, string>();
        using (var read = ZipFile.OpenRead(wgtPath))
        {
            foreach (var (name, adapt) in new (string, Func<string, string>)[] { ("config.xml", AdaptConfig), ("index.html", AdaptPage) })
            {
                if (read.GetEntry(name) is not { } entry) continue;
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                var original = reader.ReadToEnd();
                var adapted = adapt(original);
                if (adapted != original) changed[name] = adapted;
            }
        }
        if (changed.Count == 0) return false;
        using var zip = ZipFile.Open(wgtPath, ZipArchiveMode.Update);
        foreach (var (name, text) in changed)
        {
            using var stream = zip.GetEntry(name)!.Open();
            var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(text);
            stream.SetLength(0);
            stream.Write(bytes);
        }
        return true;
    }

    [GeneratedRegex("""^L?[SC](34|49|57)[A-Z]""", RegexOptions.IgnoreCase)]
    private static partial Regex MonitorModel();

    [GeneratedRegex("""^\s*(\d+)\s*[xX*]\s*(\d+)\s*$""")]
    private static partial Regex Resolution();
}
