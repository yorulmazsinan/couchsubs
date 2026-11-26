// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace CouchSubs.Shell.Tests;

/// <summary>
/// Windows arayüzünün kaynak denetimi (uygulama açılmadan, yalnız dosyalar okunarak):
/// <list type="bullet">
/// <item>Boşluk: ekran dosyalarında Margin / Padding ham sayıyla yazılmaz, tasarim.json › space belirteci kullanılır
/// (<c>{t:Sp '0,unitTitle,0,0'}</c>, kodda <c>Sp.T(...)</c>). Mac'teki SpacingLintTests'in karşılığı.</item>
/// <item>Kaynak sözlükleri: aynı sözlükte yinelenen anahtar (#988'deki "Pill" çökmesi) ve tanımsız StaticResource /
/// FindResource anahtarı yok.</item>
/// </list>
/// </summary>
public class UiLintTests
{
    private static readonly string App = FindApp();

    /// <summary>Bileşen tanımları (Theme, Controls) kendi geometrisini içerir, taranmaz. Altyazı ve oyun yüzeyleri
    /// boşluğu yazı boyuna oranlı hesaplar (ölçekli), ritim değil.</summary>
    private static readonly HashSet<string> Skipped =
        ["StreamWindow.cs", "SubtitleOverlayWindow.cs", "StyledRegionBox.cs", "PhonePanelView.cs", "FreeAreaWindow.cs"];

    /// <summary>"Dosya: satırın içeriği" → gerekçe.</summary>
    private static readonly Dictionary<string, string> Allowed = new()
    {
    };

    private static readonly Regex XamlSpacing = new(@"\b(Margin|Padding)=""[^""{]*[1-9]|Property=""(Margin|Padding)""\s+Value=""[^""{]*[1-9]");
    private static readonly Regex CodeSpacing = new(@"(Margin|Padding)\s*=\s*new Thickness\([^;]*?[(,]\s*-?[1-9][0-9.]*\s*(?=[,)])");

    [Fact]
    public void ScreensUseSpacingTokensOnly()
    {
        var files = ScreenFiles().ToList();
        Assert.NotEmpty(files);
        var violations = new List<string>();
        foreach (var file in files)
        {
            var name = Path.GetFileName(file);
            var lines = File.ReadAllLines(file);
            for (var i = 0; i < lines.Length; i++)
            {
                var line = lines[i].Trim();
                if (line.StartsWith("//") || line.StartsWith("<!--")) continue;
                var pattern = file.EndsWith(".xaml") ? XamlSpacing : CodeSpacing;
                if (!pattern.IsMatch(line)) continue;
                if (!Allowed.ContainsKey($"{name}: {line}")) violations.Add($"{name}:{i + 1}: {line}");
            }
        }
        Console.WriteLine($"SPACING_LINT violations={violations.Count}");
        Assert.True(violations.Count == 0,
            "Ham boşluk sayısı yerine {t:Sp ...} / Sp.T(...) belirteci kullanın ya da gerekçesiyle izin listesine ekleyin:\n" + string.Join("\n", violations));
    }

    [Fact]
    public void SpacingTokensExistInDesignFile()
    {
        var names = JsonDocument.Parse(File.ReadAllText(DesignFile())).RootElement.GetProperty("space").EnumerateObject().Select(p => p.Name).ToHashSet();
        names.UnionWith(["inline", "gap", "tile", "screen", "card"]);
        var missing = new List<string>();
        var xaml = new Regex(@"\{t:Sp '([^']*)'\}");
        var code = new Regex(@"Sp\.(?:T|V)\(([^)]*)\)");
        foreach (var file in Directory.EnumerateFiles(App, "*.*", SearchOption.AllDirectories).Where(IsSource))
        {
            var text = File.ReadAllText(file);
            var used = xaml.Matches(text).SelectMany(m => m.Groups[1].Value.Split(','))
                .Concat(code.Matches(text).SelectMany(m => Regex.Matches(m.Groups[1].Value, "\"([^\"]*)\"").Select(q => q.Groups[1].Value)));
            foreach (var token in used.Select(t => t.Trim().TrimStart('-')))
                if (token != "0" && token.Length > 0 && !names.Contains(token)) missing.Add($"{Path.GetFileName(file)}: {token}");
        }
        Assert.True(missing.Count == 0, "tasarim.json › space'te olmayan belirteç:\n" + string.Join("\n", missing.Distinct()));
    }

    [Fact]
    public void ResourceDictionariesHaveNoDuplicateKeys()
    {
        var duplicates = new List<string>();
        foreach (var file in Directory.EnumerateFiles(App, "*.xaml", SearchOption.AllDirectories).Where(IsSource))
        {
            var document = XDocument.Load(file);
            foreach (var dictionary in document.Descendants().Where(IsDictionary))
            {
                var keys = new HashSet<string>();
                foreach (var entry in Entries(dictionary))
                {
                    var key = KeyOf(entry);
                    if (key is not null && !keys.Add(key)) duplicates.Add($"{Path.GetFileName(file)}: {key}");
                }
            }
        }
        Assert.True(duplicates.Count == 0, "Aynı kaynak sözlüğünde yinelenen anahtar (açılışta XamlParseException):\n" + string.Join("\n", duplicates));
    }

    [Fact]
    public void StaticResourcesAreDefined()
    {
        var known = KnownKeys();
        var missing = new List<string>();
        var xamlRef = new Regex(@"\{StaticResource\s+([A-Za-z0-9_.]+)\}");
        var codeRef = new Regex(@"(?:Try)?FindResource\(""([^""]+)""\)");
        foreach (var file in Directory.EnumerateFiles(App, "*.*", SearchOption.AllDirectories).Where(IsSource))
        {
            var text = File.ReadAllText(file);
            var refs = file.EndsWith(".xaml") ? xamlRef.Matches(text) : codeRef.Matches(text);
            foreach (Match match in refs)
                if (!IsKnown(match.Groups[1].Value, known)) missing.Add($"{Path.GetFileName(file)}: {match.Groups[1].Value}");
        }
        Assert.True(missing.Count == 0, "Tanımsız kaynak anahtarı:\n" + string.Join("\n", missing.Distinct()));
    }

    /// <summary>
    /// Aynı XAML dosyasında tanımlanan bir anahtar, tanımından ÖNCE StaticResource ile kullanılmaz: WPF sözlüğü sırayla
    /// yükler, ileriye başvuru açılışta XamlParseException verir ve bütün sözlük (dolayısıyla bütün ekranlar) düşer. Derleme
    /// bunu yakalamaz (Perde'de SliderValueText ekran görüntüsü aracında böyle düştü).
    /// </summary>
    [Fact]
    public void StaticResourcesAreDefinedBeforeUse()
    {
        var problems = new List<string>();
        var use = new Regex(@"\{StaticResource\s+([A-Za-z0-9_.]+)\}");
        var definition = new Regex(@"x:Key=""([^""]+)""");
        foreach (var file in Directory.EnumerateFiles(App, "*.xaml", SearchOption.AllDirectories).Where(IsSource))
        {
            var text = File.ReadAllText(file);
            var first = new Dictionary<string, int>();
            foreach (Match match in definition.Matches(text))
                first.TryAdd(match.Groups[1].Value, match.Index);
            foreach (Match match in use.Matches(text))
                if (first.TryGetValue(match.Groups[1].Value, out var at) && at > match.Index)
                    problems.Add($"{Path.GetFileName(file)}: {match.Groups[1].Value} (satır {text[..match.Index].Count(c => c == '\n') + 1})");
        }
        Assert.True(problems.Count == 0, "Tanımından önce kullanılan StaticResource (açılışta XamlParseException):\n" + string.Join("\n", problems.Distinct()));
    }

    /// <summary>Okunacak yazının renkleri (gövde, açıklama, durum yazıları) ve üstünde durdukları zeminler.</summary>
    private static readonly string[] TextColors = ["text", "muted", "amberText", "liveText", "successText", "infoText"];
    private static readonly string[] TextBackgrounds = ["background", "surface", "surfaceRaised", "surfaceHigh", "field"];

    /// <summary>
    /// Yazı renkleri koyu ve açık temada her zeminde WCAG AA (en az 4,5:1). tasarim.json Mac ile ortak; Windows'ta "Sistemle
    /// aynı" seçiliyse Windows'un açık / koyu teması bu iki takımdan birini seçer, başka renk takımı yoktur.
    /// </summary>
    [Fact]
    public void TextColorsMeetContrastInBothThemes()
    {
        var colors = JsonDocument.Parse(File.ReadAllText(DesignFile())).RootElement.GetProperty("color");
        var failures = new List<string>();
        foreach (var theme in new[] { "light", "dark" })
            foreach (var text in TextColors)
                foreach (var background in TextBackgrounds)
                {
                    var ratio = Contrast(colors.GetProperty(text).GetProperty(theme).GetString()!, colors.GetProperty(background).GetProperty(theme).GetString()!);
                    if (ratio < 4.5) failures.Add($"{theme}: {text} / {background} = {ratio:0.00}");
                }
        Assert.True(failures.Count == 0, "4,5:1'in altında kalan yazı rengi:\n" + string.Join("\n", failures));
    }

    /// <summary>
    /// Ayarlar sayfalarının içeriği TabItem'ın mantıksal çocuğudur ve yazı rengini ondan alır. Windows'un TabItem stili
    /// Foreground=Black verir; sekme stili tema rengini vermezse renksiz satırlar (kısayol adları, profil satırı) koyu
    /// temada siyaha yakın çizilir.
    /// </summary>
    [Fact]
    public void SettingsPagesGiveTabContentTheThemeTextColor()
    {
        var styles = XDocument.Load(Path.Combine(App, "Theme", "Styles.xaml"));
        foreach (var key in new[] { "SettingsPageTabs", "PageTabs" })
        {
            var style = styles.Descendants().Single(e => e.Name.LocalName == "Style" && (string?)e.Attribute(X + "Key") == key);
            var container = style.Elements().Single(e => (string?)e.Attribute("Property") == "ItemContainerStyle");
            var tabItem = container.Descendants().Single(e => e.Name.LocalName == "Style" && (string?)e.Attribute("TargetType") == "TabItem");
            var foreground = tabItem.Elements().SingleOrDefault(e => (string?)e.Attribute("Property") == "Foreground")?.Attribute("Value")?.Value;
            Assert.True(foreground == "{DynamicResource textPrimaryBrush}", $"{key}: sekme öğesi Foreground tema rengi değil ({foreground ?? "yok"})");
        }
    }

    /// <summary>
    /// beta.104: ItemContainerStyle'daki renk gizli sekme panelinde güvenilir uygulanmıyor; sekme stilleri TabItem'a örtük
    /// stille (Style.Resources) de tema rengini verir. Ayarlar'da koddan kurulan oyun profili adı ve "Bu oyunun alanları"
    /// satırı rengi açıkça alır.
    /// </summary>
    [Fact]
    public void SettingsTabItemsGetTheThemeTextColorWithoutContainerGeneration()
    {
        var styles = XDocument.Load(Path.Combine(App, "Theme", "Styles.xaml"));
        foreach (var key in new[] { "SettingsPageTabs", "PageTabs" })
        {
            var style = styles.Descendants().Single(e => e.Name.LocalName == "Style" && (string?)e.Attribute(X + "Key") == key);
            var resources = style.Elements().SingleOrDefault(e => e.Name.LocalName == "Style.Resources");
            Assert.True(resources is not null, $"{key}: Style.Resources yok");
            var implicitTab = resources!.Elements().SingleOrDefault(e => e.Name.LocalName == "Style"
                && (string?)e.Attribute("TargetType") == "TabItem" && e.Attribute(X + "Key") is null);
            Assert.True(implicitTab is not null, $"{key}: TabItem için örtük stil yok");
            var foreground = implicitTab!.Elements().SingleOrDefault(e => (string?)e.Attribute("Property") == "Foreground")?.Attribute("Value")?.Value;
            Assert.Equal("{DynamicResource textPrimaryBrush}", foreground);
        }
        var settings = XDocument.Load(Path.Combine(App, "Views", "SettingsView.xaml"));
        var areaText = settings.Descendants().Single(e => (string?)e.Attribute(X + "Name") == "AreaProfileText");
        Assert.Equal("{DynamicResource textPrimaryBrush}", (string?)areaText.Attribute("Foreground"));
        var code = File.ReadAllText(Path.Combine(App, "Views", "SettingsView.xaml.cs"));
        var profileRow = code.IndexOf("game + \" · \" + text[\"In use\"]", StringComparison.Ordinal);
        Assert.True(profileRow > 0, "oyun profili satırı bulunamadı");
        var next = code.IndexOf("GameProfileList.Children.Add", profileRow, StringComparison.Ordinal);
        Assert.Contains("SetResourceReference(TextBlock.ForegroundProperty, \"textPrimaryBrush\")", code[profileRow..next]);
    }

    /// <summary>
    /// Boş kart yok (beta.104, Ayarlar › Çıkış Ekranları: "Hızlı konuşmada…" ile "Yayın penceresi" arasında boş kart): her
    /// c:Card'ın içeriği vardır ve kart, yapacak işi yokken kendini gizleyen bir bileşeni (kök öğesi Visibility="Collapsed"
    /// olan UserControl, ör. TvAppCard) tek başına sarmaz; o bileşen gizlenince kartın çerçevesi boş kalır.
    /// </summary>
    [Fact]
    public void NoSettingsCardIsEmpty()
    {
        var files = Directory.EnumerateFiles(Path.Combine(App, "Views"), "*.xaml", SearchOption.AllDirectories).Where(IsSource).ToList();
        var selfHiding = files.Select(f => XDocument.Load(f).Root!)
            .Where(root => root.Name.LocalName == "UserControl" && (string?)root.Attribute("Visibility") == "Collapsed")
            .Select(root => ((string?)root.Attribute(X + "Class") ?? "").Split('.').Last())
            .Where(name => name.Length > 0)
            .ToHashSet();
        Assert.Contains("TvAppCard", selfHiding);
        var problems = new List<string>();
        foreach (var file in files)
        {
            var name = Path.GetFileName(file);
            foreach (var card in XDocument.Load(file, LoadOptions.SetLineInfo).Descendants().Where(e => e.Name.LocalName == "Card"))
            {
                var line = ((System.Xml.IXmlLineInfo)card).LineNumber;
                // Özellik öğeleri (c:Card.Trailing) içerik sayılmaz.
                var content = card.Elements().Where(e => !e.Name.LocalName.Contains('.')).ToList();
                if (content.Count == 0)
                    problems.Add($"{name}:{line}: içeriği olmayan kart");
                else if (content.Count == 1 && selfHiding.Contains(content[0].Name.LocalName))
                    problems.Add($"{name}:{line}: kart yalnız kendini gizleyen {content[0].Name.LocalName}'ı sarıyor (gizlenince boş kart kalır)");
            }
        }
        Assert.True(problems.Count == 0, "Boş kalabilen kart:\n" + string.Join("\n", problems));
        var settings = File.ReadAllText(Path.Combine(App, "Views", "SettingsView.xaml"));
        Assert.Contains("<s:TvAppCard Shown=\"{Binding ShowsOnTv}\" />", settings);
    }

    /// <summary>"Dosya: öğe adı" → gerekçe. Soluk (faint) renk okunacak yazıda kullanılmaz; yalnız bunlar.</summary>
    private static readonly Dictionary<string, string> FaintAllowed = new()
    {
        ["MainView.xaml: GameSearchHint"] = "arama kutusunun yer tutucusu (WCAG yer tutucuyu saymaz)",
        ["HistoryView.xaml: SearchHint"] = "arama kutusunun yer tutucusu",
        ["Styles.xaml: AppStoreSoon"] = "reklam bandındaki devre dışı mağaza düğmesinin \"Yakında\" yazısı (devre dışı)",
        ["Styles.xaml: GooglePlaySoon"] = "reklam bandındaki devre dışı mağaza düğmesinin \"Yakında\" yazısı (devre dışı)",
        ["Styles.xaml: {theme:T 'AD'}"] = "reklam bandının köşesindeki küçük \"Reklam\" damgası (süs; Mac DSAdBand ile aynı)",
    };

    private static readonly Regex LiteralColor = new(@"^(#[0-9A-Fa-f]{3,8}|Black|Gray|Grey|DarkGray|DimGray|LightGray|Silver|SlateGray)$");

    /// <summary>
    /// Yazılar tema kaynağıyla boyanır (DynamicResource): XAML'deki TextBlock'larda ve TextBlock stillerinde sabit koyu /
    /// gri renk yok (temayla değişmez, koyu temada kaybolur) ve soluk faint / textTertiary okunacak yazıda yok (her iki
    /// temada 4,5:1'in altında). Simge yazıları (GlyphText) ve gerekçeli istisnalar hariç.
    /// </summary>
    [Fact]
    public void TextUsesThemeColorsWithEnoughContrast()
    {
        var problems = new List<string>();
        var files = Directory.EnumerateFiles(Path.Combine(App, "Views"), "*.xaml", SearchOption.AllDirectories)
            .Append(Path.Combine(App, "ShellWindow.xaml")).Append(Path.Combine(App, "Theme", "Styles.xaml")).Where(IsSource);
        foreach (var file in files)
        {
            var name = Path.GetFileName(file);
            foreach (var element in XDocument.Load(file).Descendants())
            {
                string? value = null;
                string label;
                if (element.Name.LocalName == "TextBlock")
                {
                    if (((string?)element.Attribute("Style"))?.Contains("GlyphText") == true) continue;
                    value = (string?)element.Attribute("Foreground");
                    label = (string?)element.Attribute(X + "Name") ?? (string?)element.Attribute("Text") ?? "TextBlock";
                }
                else if (element.Name.LocalName == "Setter" && (string?)element.Attribute("Property") == "Foreground"
                         && element.Parent is { } style && style.Name.LocalName == "Style" && (string?)style.Attribute("TargetType") == "TextBlock")
                {
                    value = (string?)element.Attribute("Value");
                    label = (string?)style.Attribute(X + "Key") ?? "TextBlock (örtük stil)";
                }
                else continue;
                if (value is null) continue;
                var line = ((System.Xml.IXmlLineInfo)element).LineNumber;
                if (LiteralColor.IsMatch(value.Trim()))
                    problems.Add($"{name}:{line}: {label} sabit renk {value} (tema kaynağı kullanın)");
                else if ((value.Contains("faintBrush") || value.Contains("textTertiaryBrush")) && !FaintAllowed.ContainsKey($"{name}: {label}"))
                    problems.Add($"{name}:{line}: {label} soluk {value} (okunacak yazı için mutedBrush / textSecondaryBrush)");
            }
        }
        Assert.True(problems.Count == 0, "Tema dışı ya da düşük kontrastlı yazı rengi:\n" + string.Join("\n", problems));
    }

    /// <summary>WCAG 2 bağıl parlaklık oranı; #RRGGBB(AA) — saydam renkler bu denetimde kullanılmaz.</summary>
    private static double Contrast(string a, string b)
    {
        static double Luminance(string hex)
        {
            var text = hex.TrimStart('#');
            double Channel(int index)
            {
                var c = Convert.ToInt32(text.Substring(index, 2), 16) / 255.0;
                return c <= 0.03928 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
            }
            return 0.2126 * Channel(0) + 0.7152 * Channel(2) + 0.0722 * Channel(4);
        }
        var (la, lb) = (Luminance(a), Luminance(b));
        return (Math.Max(la, lb) + 0.05) / (Math.Min(la, lb) + 0.05);
    }

    private static (HashSet<string> Keys, HashSet<string> Colors, HashSet<string> Fonts) KnownKeys()
    {
        var keys = new HashSet<string>();
        foreach (var file in Directory.EnumerateFiles(App, "*.xaml", SearchOption.AllDirectories).Where(IsSource))
            foreach (var element in XDocument.Load(file, LoadOptions.SetLineInfo).Descendants())
                if (element.Attribute(X + "Key") is { } key) keys.Add(key.Value);
        var colors = new HashSet<string>();
        var fonts = new HashSet<string>();
        foreach (var json in new[] { DesignFile(), Path.Combine(Root(), "design", "tokens.json") })
        {
            var root = JsonDocument.Parse(File.ReadAllText(json)).RootElement;
            if (root.TryGetProperty("color", out var c)) colors.UnionWith(c.EnumerateObject().Select(p => p.Name));
            if (root.TryGetProperty("font", out var f)) fonts.UnionWith(f.EnumerateObject().Select(p => p.Name));
        }
        // Palette.cs'teki eski adlar ve ek renkler ("surface2", "divider" …).
        var palette = File.ReadAllText(Path.Combine(App, "Theme", "Palette.cs"));
        foreach (Match match in Regex.Matches(palette, @"""([a-zA-Z0-9]+)"""))
        {
            colors.Add(match.Groups[1].Value);
            fonts.Add(match.Groups[1].Value);
        }
        colors.Add("tile");
        colors.Add("windowBackground");
        return (keys, colors, fonts);
    }

    private static bool IsKnown(string key, (HashSet<string> Keys, HashSet<string> Colors, HashSet<string> Fonts) known)
    {
        if (known.Keys.Contains(key)) return true;
        foreach (var prefix in new[] { "space.", "pad.", "radius.", "size." })
            if (key.StartsWith(prefix)) return true;
        foreach (var suffix in new[] { "Brush", "Color" })
            if (key.EndsWith(suffix) && known.Colors.Contains(key[..^suffix.Length])) return true;
        foreach (var suffix in new[] { "FontSize", "FontWeight" })
            if (key.EndsWith(suffix) && known.Fonts.Contains(key[..^suffix.Length])) return true;
        return false;
    }

    private static readonly XNamespace X = "http://schemas.microsoft.com/winfx/2006/xaml";

    private static bool IsDictionary(XElement element) =>
        element.Name.LocalName == "ResourceDictionary" || element.Name.LocalName.EndsWith(".Resources");

    /// <summary>Sözlüğün doğrudan girdileri; ".Resources" içindeki ResourceDictionary ayrıca taranır.</summary>
    private static IEnumerable<XElement> Entries(XElement dictionary) =>
        dictionary.Elements().Where(e => !e.Name.LocalName.Contains('.') && e.Name.LocalName != "ResourceDictionary");

    private static string? KeyOf(XElement entry)
    {
        if (entry.Attribute(X + "Key") is { } key) return key.Value;
        // Anahtarsız Style / şablon: anahtarı hedef türüdür (aynı türe iki örtük stil de yinelenen anahtardır).
        var type = entry.Attribute("TargetType")?.Value ?? entry.Attribute("DataType")?.Value;
        return type is null ? null : $"{entry.Name.LocalName}:{type}";
    }

    private static IEnumerable<string> ScreenFiles()
    {
        yield return Path.Combine(App, "ShellWindow.xaml");
        yield return Path.Combine(App, "ShellWindow.xaml.cs");
        foreach (var file in Directory.EnumerateFiles(Path.Combine(App, "Views"), "*.*", SearchOption.AllDirectories))
            if (IsSource(file) && !Skipped.Contains(Path.GetFileName(file))) yield return file;
    }

    private static bool IsSource(string file) =>
        (file.EndsWith(".xaml") || file.EndsWith(".cs")) && !file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
        && !file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}");

    private static string DesignFile() => Path.Combine(Root(), "design", "yeni-arayuz", "tasarim.json");

    private static string Root() => Path.GetFullPath(Path.Combine(App, "..", "..", ".."));

    private static string FindApp()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "windows", "src", "CouchSubs.App");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("windows/src/CouchSubs.App bulunamadı");
    }
}
