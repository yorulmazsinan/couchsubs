// SPDX-License-Identifier: AGPL-3.0-only

using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using CouchSubs.App.Controls;
using CouchSubs.Core;

namespace CouchSubs.App.Services;

/// <summary>
/// Enmera'nın kendi uygulamalarının reklamları (Mac AdCatalog ile aynı). Üçüncü taraf reklam ağı, izleme ve kişisel
/// veri yok: liste uygulamanın içinde (design/yeni-arayuz/reklamlar.json ve reklam/*.png; Mac aynı dosyayı okur),
/// tıklanınca yalnız mağaza bağlantısı tarayıcıda açılır. Dosya yoksa ya da bozuksa reklam bandı görünmez.
/// </summary>
public static class AdCatalog
{
    public const string Home = "https://enmera.com.tr";

    private static IReadOnlyList<BannerAd> banners = Load();

    /// <summary>Bantta sırayla dönen reklamlar (Cebbin, Gramla, Bakkal).</summary>
    public static IReadOnlyList<BannerAd> Banners
    {
        get => banners;
        set
        {
            banners = value;
            Changed?.Invoke();
        }
    }

    public static event Action? Changed;

    /// <summary>reklamlar.json'u uygulamanın diline göre okur (Türkçe değilse İngilizce).</summary>
    public static IReadOnlyList<BannerAd> Load()
    {
        try
        {
            using var stream = typeof(AdCatalog).Assembly.GetManifestResourceStream("reklamlar.json");
            if (stream is null) return [];
            using var document = JsonDocument.Parse(stream);
            var language = Localizer.Current.Language == "tr" ? "tr" : "en";
            var list = new List<BannerAd>();
            foreach (var ad in document.RootElement.GetProperty("ads").EnumerateArray())
            {
                string Text(string name) =>
                    ad.GetProperty(name).TryGetProperty(language, out var value) ? value.GetString() ?? "" : ad.GetProperty(name).GetProperty("en").GetString() ?? "";
                string? Link(string name) => ad.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
                list.Add(new BannerAd(ad.GetProperty("id").GetString() ?? "", Text("title"), Text("text"), Icon(ad.GetProperty("icon").GetString()),
                    Link("appStore"), Link("googlePlay")));
            }
            return list;
        }
        catch (Exception error) when (error is JsonException or KeyNotFoundException or InvalidOperationException or IOException)
        {
            return [];
        }
    }

    /// <summary>Uygulama simgesi (reklam/*.png, uygulamaya Resource olarak gömülü).</summary>
    private static ImageSource? Icon(string? file)
    {
        if (string.IsNullOrEmpty(file)) return null;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.UriSource = new Uri($"pack://application:,,,/CouchSubs;component/Assets/reklam/{file}", UriKind.Absolute);
            image.DecodePixelWidth = 96;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception error) when (error is IOException or UriFormatException or NotSupportedException or InvalidOperationException)
        {
            return null;
        }
    }
}
