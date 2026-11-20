// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Konuşana göre renk v2: dört platformun ortak vektörü (docs/speaker-colors-vectors.json) birebir.</summary>
public class SpeakerColorBookTests
{
    private static string Vectors()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var path = Path.Combine(dir.FullName, "docs", "speaker-colors-vectors.json");
            if (File.Exists(path)) return path;
        }
        throw new FileNotFoundException("docs/speaker-colors-vectors.json bulunamadı");
    }

    [Fact]
    public void SharedSequenceGivesTheSameColours()
    {
        using var json = JsonDocument.Parse(File.ReadAllText(Vectors()));
        Assert.Equal(SpeakerColors.Palette, json.RootElement.GetProperty("palette").EnumerateArray().Select(item => item.GetString()!));
        foreach (var family in json.RootElement.GetProperty("families").EnumerateObject())
            Assert.Equal(family.Value.GetString()![0], SpeakerColorBook.Families[family.Name]);
        var book = new SpeakerColorBook();
        foreach (var item in json.RootElement.GetProperty("sequence").EnumerateArray())
            Assert.Equal(item.GetProperty("color").GetString(), book.Color(item.GetProperty("name").GetString()!));
    }

    [Fact]
    public void ResetStartsANewSession()
    {
        var book = new SpeakerColorBook();
        Assert.Equal("#90CAF9", book.Color("Mattia"));
        Assert.Equal("#FFD54F", book.Color("Boobie"));
        book.Reset();
        Assert.Equal("#90CAF9", book.Color("Boobie"));
        Assert.Null(book.Color(" ... "));
    }

    [Theory]
    [InlineData("Hedef: Arabaya bin.")]
    [InlineData("Görev: Lucia'yı bul.")]
    [InlineData("İpucu: Haritayı aç.")]
    [InlineData("Not: Kaydet.")]
    [InlineData("12:30")]
    [InlineData("3:1 oranla kazandın")]
    public void TitlesAndTimesAreNotSpeakers(string line) => Assert.Null(SpeakerPrefix.Parse(line));

    [Fact]
    public void ServerSendsTheSessionColours()
    {
        var server = new SubtitleServer(0) { SpeakerColors = true };
        Assert.Equal("#90CAF9", server.SpeakerBook.Color("Mattia"));
        Assert.Equal("#FFD54F", server.SpeakerBook.Color("Boobie"));
    }
}
