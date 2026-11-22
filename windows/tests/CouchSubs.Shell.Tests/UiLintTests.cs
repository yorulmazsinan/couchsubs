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

    private static (HashSet<string> Keys, HashSet<string> Colors, HashSet<string> Fonts) KnownKeys()
    {
        var keys = new HashSet<string>();
        foreach (var file in Directory.EnumerateFiles(App, "*.xaml", SearchOption.AllDirectories).Where(IsSource))
            foreach (var element in XDocument.Load(file).Descendants())
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
