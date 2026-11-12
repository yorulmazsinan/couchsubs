// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;

namespace CouchSubs.Shell.Tests;

/// <summary>Ayarlardaki görünüm: varsayılan koyu, kaydedilip geri okunur (Mac ile aynı testler).</summary>
public class AppearanceTests
{
    [Fact]
    public void NewSettingsAreDark() => Assert.Equal(AppAppearance.Dark, new UserSettings().Appearance);

    [Fact]
    public void ExistingSettingsOpenDark()
    {
        var old = JsonSerializer.Deserialize<UserSettings>("""{"SourceLanguage":"en","Style":{"FontSize":58},"GamePacks":false}""")!;
        Assert.Equal(AppAppearance.Dark, old.Appearance);
        Assert.Equal(58, old.Style.FontSize);
        Assert.False(old.GamePacks);
    }

    [Theory]
    [InlineData(AppAppearance.Dark, "Dark")]
    [InlineData(AppAppearance.Light, "Light")]
    [InlineData(AppAppearance.System, "System")]
    public void AppearanceIsSavedAsText(AppAppearance appearance, string text)
    {
        var json = JsonSerializer.Serialize(new UserSettings { Appearance = appearance });
        Assert.Contains($"\"Appearance\":\"{text}\"", json);
        Assert.Equal(appearance, JsonSerializer.Deserialize<UserSettings>(json)!.Appearance);
    }

    [Fact]
    public void ChangedAppearanceIsSavedAndAnnounced()
    {
        var settings = new MemorySettings();
        var controller = AppControllerTests.Make(settings: settings);
        var changed = new List<string?>();
        controller.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        controller.Settings = controller.Settings with { Appearance = AppAppearance.Light };
        Assert.Equal(AppAppearance.Light, settings.Saved?.Appearance);
        Assert.Contains(nameof(AppController.Settings), changed);
        Assert.Equal(AppAppearance.Light, AppControllerTests.Make(settings: settings).Settings.Appearance);
    }
}
