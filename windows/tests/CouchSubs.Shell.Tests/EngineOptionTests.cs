// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using System.Xml.Linq;

namespace CouchSubs.Shell.Tests;

/// <summary>
/// Ayarlar › Gelişmiş › Çeviri motoru kartları (#1298): kaydedilen motor ayar dosyasından geri okununca tam bir kart
/// işaretlenir ve kartların radyo grubu başka bir ekranın düğmeleriyle paylaşılmaz. Uygulama açılmaz; XAML dosyaları okunur,
/// ayar dosyası yerine bellekteki JSON kullanılır (gerçek settings.json'a yazılmaz).
/// </summary>
public class EngineOptionTests
{
    private static readonly XNamespace Presentation = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace Xaml = "http://schemas.microsoft.com/winfx/2006/xaml";

    private static string App()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "windows", "src", "CouchSubs.App");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("windows/src/CouchSubs.App bulunamadı");
    }

    private static XElement EngineOptions()
    {
        var document = XDocument.Load(Path.Combine(App(), "Views", "SettingsView.xaml"));
        return document.Descendants().Single(e => (string?)e.Attribute(Xaml + "Name") == "EngineOptions");
    }

    private static List<string> CardTags() =>
        EngineOptions().Elements().Where(e => e.Name.LocalName == "OptionCard").Select(e => (string)e.Attribute("Tag")!).ToList();

    /// Her motor için: seçim (WithEngine) → settings.json metni → yeniden yükleme → görünümün işaretlediği kart (Engine adı)
    /// tam bir karttır ve seçilen motordur.
    [Theory]
    [InlineData(TranslationEngine.Free)]
    [InlineData(TranslationEngine.DeepL)]
    [InlineData(TranslationEngine.Gemini)]
    [InlineData(TranslationEngine.OpenAi)]
    [InlineData(TranslationEngine.Claude)]
    [InlineData(TranslationEngine.DeepSeek)]
    [InlineData(TranslationEngine.Local)]
    public void SavedEngineChecksExactlyItsCard(TranslationEngine engine)
    {
        var json = JsonSerializer.Serialize(new UserSettings().WithEngine(engine));
        var reloaded = ExtraAreaMigration.Load(json);
        Assert.Equal(engine, reloaded.Engine);
        var checkedCards = CardTags().Where(tag => tag == reloaded.Engine.ToString()).ToList();
        Assert.Single(checkedCards);
    }

    /// Kartlar ve gizli Engine kutusu bütün motorları birer kez içerir.
    [Fact]
    public void CardsCoverEveryEngineOnce()
    {
        var engines = Enum.GetNames<TranslationEngine>().Order().ToList();
        Assert.Equal(engines, CardTags().Order().ToList());
        var document = XDocument.Load(Path.Combine(App(), "Views", "SettingsView.xaml"));
        var box = document.Descendants(Presentation + "ComboBox").Single(e => (string?)e.Attribute(Xaml + "Name") == "Engine");
        Assert.Equal(engines, box.Elements(Presentation + "ComboBoxItem").Select(e => (string)e.Attribute("Tag")!).Order().ToList());
    }

    /// Motor kartları GroupName ile değil aynı panelde gruplanır: WPF aynı adlı grubu görsel kökü olmayan (seçili olmayan
    /// sekmedeki) bütün düğmeler arasında paylaşır; Dublaj kartının "engine" grubu buradaki işareti siliyordu.
    [Fact]
    public void EngineCardsHaveNoGroupName()
    {
        var named = EngineOptions().Elements().Where(e => e.Attribute("GroupName") is not null).Select(e => (string)e.Attribute("Tag")!).ToList();
        Assert.True(named.Count == 0, "GroupName'li motor kartı: " + string.Join(", ", named));
    }

    /// Bir radyo grubu adı yalnız bir XAML dosyasında kullanılır; iki ekran (ya da bir ekran ve içine gömülü kart) aynı adı
    /// kullanırsa düğmeleri birbirinin işaretini kaldırır.
    [Fact]
    public void RadioGroupNamesAreNotSharedAcrossFiles()
    {
        var owners = new Dictionary<string, HashSet<string>>();
        foreach (var file in Directory.EnumerateFiles(App(), "*.xaml", SearchOption.AllDirectories)
                     .Where(f => !f.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                                 && !f.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")))
        {
            foreach (var element in XDocument.Load(file).Descendants())
                if ((string?)element.Attribute("GroupName") is { Length: > 0 } group)
                {
                    if (!owners.TryGetValue(group, out var files)) owners[group] = files = [];
                    files.Add(Path.GetFileName(file));
                }
        }
        var shared = owners.Where(o => o.Value.Count > 1).Select(o => $"{o.Key}: {string.Join(", ", o.Value)}").ToList();
        Assert.True(shared.Count == 0, "Birden çok dosyada aynı GroupName:\n" + string.Join("\n", shared));
    }
}
