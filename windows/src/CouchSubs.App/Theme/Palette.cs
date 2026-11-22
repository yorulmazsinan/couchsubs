// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Text.Json;
using System.Windows.Media;

namespace CouchSubs.App.Theme;

/// <summary>
/// Yeni arayüzün renk, yazı, ölçü ve hareket değerleri. Tek kaynak <c>design/yeni-arayuz/tasarim.json</c> (Mac ile ortak;
/// uygulamaya gömülüdür). ThemeManager bu değerleri tokens.json'dan sonra uygular: dosyadaki adlar (<c>amberBrush</c>,
/// <c>fieldBrush</c> …) ve eski ekranların kullandığı eski adlar (<c>accentBrush</c>, <c>surface2Brush</c> …) aynı
/// renge bağlanır, böylece eski ekranlar da yeni dile geçer.
/// Renk anlamları: amber = ana eylem / anahtar açık; yeşil = başarı; kırmızı (#D9542F) = canlı-durdur ve uyarı.
/// </summary>
public static class Palette
{
    private static readonly JsonElement Root = Load();

    /// <summary>Eski ad → tasarim.json'daki ad (eski ekranlar ve Styles.xaml eski adları kullanır).</summary>
    private static readonly (string Old, string New)[] Aliases =
    [
        ("surface2", "field"), ("textPrimary", "text"), ("textSecondary", "muted"), ("textTertiary", "faint"),
        ("accent", "amber"), ("accentHi", "amberHover"), ("accentDeep", "amberLine"), ("onAccent", "onAmber"),
        ("accentText", "amberText"), ("accentSoft", "amberSoft"), ("device", "screenFrame"),
        ("successBorder", "successRing"), ("liveBorder", "liveRing"),
        ("warning", "liveText"), ("danger", "liveText"), ("dangerSoft", "liveSoft"), ("dangerBorder", "liveRing"),
    ];

    /// <summary>Dosyada olmayan, yalnız Windows çiziminde gereken renkler (tasarım tuvalindeki değerler).</summary>
    private static readonly Dictionary<string, (string Light, string Dark)> Extras = new()
    {
        ["divider"] = ("#EFEAE2", "#26292F"),
        ["tileTop"] = ("#F1EDE6", "#23262C"),
        ["tileBottom"] = ("#F6F2EA", "#202328"),
        ["knob"] = ("#FFFFFF", "#FFFFFF"),
        ["scene"] = ("#6D6A5D", "#6D6A5D"),
        ["onDanger"] = ("#FFFFFF", "#17181B"),
        // Ayarlar menüsü seçim hapının halkası: amber %45 (Mac dsAmber.opacity(0.45)).
        ["amberRing"] = ("#F5B83D73", "#F5B83D73"),
    };

    /// <summary>Ad → (açık, koyu) renk; kaynaklarda <c>{ad}Color</c> ve <c>{ad}Brush</c>.</summary>
    public static readonly IReadOnlyDictionary<string, (Color Light, Color Dark)> Colors = BuildColors();

    /// <summary>Yazı boyları: dosyadaki adlar (h1, h2, h3, body, small …) ve eski adlar (display, title, headline, callout …).</summary>
    public static readonly IReadOnlyDictionary<string, (double Size, string Weight)> Fonts = BuildFonts();

    /// <summary>8 px ızgara (dosyadaki space) ve eski adlar.</summary>
    public static readonly IReadOnlyDictionary<string, double> Space = BuildSpace();

    public static readonly IReadOnlyDictionary<string, double> Radius = BuildRadius();

    /// <summary>Ölçüler: düğme 48, sekme 40, çip 32, satır 56, en küçük pencere 1200 × 760 …</summary>
    public static readonly IReadOnlyDictionary<string, double> Size = BuildSize();

    /// <summary>Hareket süresi (ms): short, medium, page, reduced, adRotate.</summary>
    public static double MotionMs(string name, double fallback) =>
        Root.TryGetProperty("motion", out var motion) && motion.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number
            ? value.GetDouble() : fallback;

    /// <summary>Hareket eğrisi (enter / exit): cubic-bezier'in dört değeri.</summary>
    public static double[] MotionCurve(string name, double[] fallback) =>
        Root.TryGetProperty("motion", out var motion) && motion.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Array
            ? [.. value.EnumerateArray().Select(v => v.GetDouble())] : fallback;

    private static JsonElement Load()
    {
        using var stream = typeof(Palette).Assembly.GetManifestResourceStream("tasarim.json")
            ?? throw new InvalidOperationException("design/yeni-arayuz/tasarim.json uygulamaya gömülmemiş");
        using var document = JsonDocument.Parse(stream);
        return document.RootElement.Clone();
    }

    private static Dictionary<string, (Color, Color)> BuildColors()
    {
        var colors = new Dictionary<string, (Color, Color)>();
        foreach (var entry in Root.GetProperty("color").EnumerateObject())
            colors[entry.Name] = (Parse(entry.Value.GetProperty("light").GetString()!), Parse(entry.Value.GetProperty("dark").GetString()!));
        foreach (var (old, name) in Aliases)
            if (colors.TryGetValue(name, out var pair)) colors[old] = pair;
        foreach (var (name, (light, dark)) in Extras) colors.TryAdd(name, (Parse(light), Parse(dark)));
        return colors;
    }

    private static Dictionary<string, (double, string)> BuildFonts()
    {
        var fonts = new Dictionary<string, (double, string)>();
        foreach (var entry in Root.GetProperty("font").EnumerateObject())
            fonts[entry.Name] = (entry.Value.GetProperty("size").GetDouble(), entry.Value.GetProperty("weight").GetString() ?? "regular");
        // Eski adlar; dosyada aynı adla değer varsa (label 13 orta kalın) dosyadaki kalır.
        foreach (var (old, name) in new[] { ("display", "h1"), ("title", "h2"), ("headline", "h3"), ("callout", "small"), ("label", "mono"), ("code", "h2") })
            if (!fonts.ContainsKey(old) && fonts.TryGetValue(name, out var font)) fonts[old] = font;
        return fonts;
    }

    private static Dictionary<string, double> BuildSpace()
    {
        // Adlar ve değerler tasarim.json › space ile birebir (Mac DS.space(...) aynı adları kullanır):
        // line 2, xxs 4, titleBody 6, unitHint 6, unitTitle 8, xs 8, related 12, s 12, m 16, unitGap 24, l 24, section 32, xl 32, xxl 40.
        var space = Numbers("space");
        // Eski adlar (yalnız dosyada olmayanlar): kart içi ve arası 24, öğe arası 16.
        foreach (var (old, value) in new[] { ("inline", 8.0), ("gap", 16.0), ("tile", 24.0), ("screen", 24.0), ("card", 24.0) })
            space.TryAdd(old, value);
        return space;
    }

    private static Dictionary<string, double> BuildRadius()
    {
        var radius = Numbers("radius");
        // Eski adlar: denetim 16, iç 12, etiket ve hap tam yuvarlak, büyük 32.
        radius["control"] = radius.GetValueOrDefault("tile", 16);
        radius["inner"] = radius.GetValueOrDefault("control", 12);
        radius["tag"] = 999;
        radius["large"] = radius.GetValueOrDefault("hero", 32);
        return radius;
    }

    private static Dictionary<string, double> BuildSize()
    {
        var size = Numbers("size");
        foreach (var (old, name) in new[] { ("buttonHeight", "button"), ("buttonLarge", "button"), ("primaryActionHeight", "button"), ("tabHeight", "tab"),
                     ("chipHeight", "chip"), ("rowHeight", "row"), ("sidebarWidth", "settingsNav"), ("titleBarHeight", "header"),
                     ("adBandHeight", "adBand"), ("contentMaxWidth", "contentMax") })
            if (size.TryGetValue(name, out var value)) size[old] = value;
        size.TryAdd("keycap", 28);
        size.TryAdd("mainColumn", 380);
        return size;
    }

    private static Dictionary<string, double> Numbers(string section)
    {
        var values = new Dictionary<string, double>();
        if (Root.TryGetProperty(section, out var element))
            foreach (var entry in element.EnumerateObject())
                if (entry.Value.ValueKind == JsonValueKind.Number) values[entry.Name] = entry.Value.GetDouble();
        return values;
    }

    /// <summary>#RRGGBB ya da #RRGGBBAA (CSS sırası: saydamlık sonda).</summary>
    public static Color Parse(string hex)
    {
        var text = hex.TrimStart('#');
        byte Part(int index) => byte.Parse(text.AsSpan(index, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
        var alpha = text.Length == 8 ? Part(6) : (byte)255;
        return Color.FromArgb(alpha, Part(0), Part(2), Part(4));
    }
}
