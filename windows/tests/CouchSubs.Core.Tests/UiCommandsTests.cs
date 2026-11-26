// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Arayüz sözlüğü: tuş çubuğu komutu sözlükteki biçimiyle ("Hedef belirle"), menü etiketi özgünün biçimiyle Türkçe
/// kurallarıyla ("İSTATİSTİKLER", "KIYAFETLER"). Ortak vakalar core/Tests/CouchSubsCoreTests/Fixtures/ui-commands.json
/// (Mac UiCommandsTests.swift ve Android UiCommandsTest.kt aynı dosyayı okur).
/// </summary>
public class UiCommandsTests
{
    [Fact]
    public void SharedCasesMatchMacAndAndroid()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("ui-commands.json")));
        var checks = new (string Name, Func<string, string?> Function)[]
        {
            ("translate", UiCommands.Translate),
            ("translateLabel", UiCommands.TranslateLabel),
            ("translateLabelLoosely", UiCommands.TranslateLabelLoosely),
            ("withoutKeyGlyph", text => UiCommands.WithoutKeyGlyph(text)),
        };
        foreach (var (name, function) in checks)
        {
            var cases = fixture.RootElement.GetProperty(name).EnumerateArray().ToList();
            Assert.True(cases.Count >= 5, name);
            foreach (var item in cases)
            {
                var text = item.GetProperty("text").GetString()!;
                var expected = item.GetProperty("expected").ValueKind == JsonValueKind.Null ? null : item.GetProperty("expected").GetString();
                Assert.True(expected == function(text), $"{name}(\"{text}\"): {function(text) ?? "null"} ≠ {expected ?? "null"}");
            }
        }
    }

    /// <summary>
    /// Yazı tanımanın tek harfini yanlış okuduğu uzun etiket ("SET DESTINATI0N") sözlükte bulunur; kısa anahtarda (yedi
    /// harften az) ya da birden çok anahtara yakın okumada tahmin yapılmaz. Baş harfleri büyük etiketin Türkçesi de öyle.
    /// </summary>
    [Fact]
    public void TekHarfHatasiVeBasHarfBuyukEtiket()
    {
        Assert.Equal("HEDEF BELİRLE", UiCommands.TranslateLabel("SET DESTINATI0N"));
        Assert.Equal("AYARLAR", UiCommands.TranslateLabel("SETTINQS"));
        Assert.Null(UiCommands.TranslateLabel("EXIF"));
        Assert.Equal("SET DESTINATION", UiCommands.NearKey("SET DESTINATON"));
        Assert.True(UiCommands.OneEdit("RECENTER", "RECENTRE") == false);
        Assert.Equal("İşaret Ekle", UiCommands.TranslateLabel("Add Waypoint"));
        Assert.Equal("Görevden Çık", UiCommands.TranslateLabel("Quit Mission"));
        Assert.Equal("Çık", UiCommands.Translate("EXIT"));
    }
}
