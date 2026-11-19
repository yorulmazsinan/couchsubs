// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// Metinler Mac uygulamasının Localizable.xcstrings dosyasından gelir; iki uygulama aynı çevirileri kullanır.
public class LocalizerTests
{
    [Fact]
    public void TurkishTextComesFromSharedCatalog()
    {
        var tr = Localizer.ForLanguage("tr");
        Assert.Equal("Çeviriyi başlat", tr["Start translating"]);
        Assert.Equal("Start translating", Localizer.ForLanguage("en")["Start translating"]);
    }

    [Fact]
    public void UnknownLanguageFallsBackToEnglish() =>
        Assert.Equal("Start translating", Localizer.ForLanguage("de")["Start translating"]);

    [Fact]
    public void MissingKeyShowsTheKey() =>
        Assert.Equal("No such text", Localizer.ForLanguage("tr")["No such text"]);

    [Fact]
    public void PositionalFormatArgumentsAreFilled()
    {
        var tr = Localizer.ForLanguage("tr");
        Assert.Equal("Adım 2 / 6", tr.Format("Step %lld of %lld", 2, 6));
        Assert.Contains("İngilizce", tr.Format("The %@–%@ language pack is not downloaded yet.", "İngilizce", "Türkçe"));
    }

    /// Görüntü modu ipucu (SettingsWindow.xaml ile aynı anahtar): uygulama içinde oyun modu ya da HDR kaybolursa
    /// Katman önerilir (Sony Bravia, LG). Anahtar XAML'da değişip katalogda kalmazsa ipucu İngilizce görünürdü.
    [Fact]
    public void PictureModeHintSuggestsOverlayForLostGameModeAndHdr()
    {
        const string key = "If the PS5 picture stays black inside the CouchSubs TV app, choose Overlay: the TV shows the PS5 on its own HDMI input and the subtitles appear on top. If the picture never arrives, the TV app switches to Overlay by itself. Overlay also helps if the TV changes its picture mode or drops Game mode or HDR while the TV app is open: inside the app the TV handles the PS5 picture as an app, not as its HDMI input.";
        var tr = Localizer.ForLanguage("tr")[key];
        Assert.NotEqual(key, tr);
        Assert.Contains("oyun modu ya da HDR", tr);
        var xaml = File.ReadAllText(Path.Combine(RepoRoot(), "windows", "src", "CouchSubs.App", "Views", "SettingsWindow.xaml"));
        Assert.Contains(key, xaml);
    }

    private static string RepoRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !Directory.Exists(Path.Combine(dir.FullName, "mac", "CouchSubs"))) dir = dir.Parent;
        return dir?.FullName ?? throw new DirectoryNotFoundException("depo kökü bulunamadı");
    }

    [Fact]
    public void EveryEntryHasTurkish()
    {
        var missing = Localizer.MissingTranslations("tr");
        Assert.True(missing.Count == 0, string.Join(", ", missing));
    }
}
