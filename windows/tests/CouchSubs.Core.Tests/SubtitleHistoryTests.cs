// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Altyazı geçmişi: ekleme, yeniden okuma, sınır, düz metin ve dosya (Mac: SubtitleHistoryTests).</summary>
public sealed class SubtitleHistoryTests : IDisposable
{
    private static readonly DateTime Ten = new(2026, 11, 12, 10, 0, 0, DateTimeKind.Utc);
    private readonly string folder = Path.Combine(Path.GetTempPath(), "couchsubs-history-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
    }

    [Fact]
    public void NewestComesFirst()
    {
        var history = new SubtitleHistory();
        history.Add("Hold the gate.", "Kapıyı tut.", LineOrigin.Engine, Ten);
        history.Add("Get down!", "Yere yat!", LineOrigin.Pack, Ten.AddSeconds(5));
        Assert.Equal(["Yere yat!", "Kapıyı tut."], history.Entries.Select(e => e.Translation));
        Assert.Equal(LineOrigin.Pack, history.Entries[0].Origin);
        Assert.Equal([1, 0], history.Entries.Select(e => e.Id));
    }

    [Fact]
    public void RereadOfTheSameLineUpdatesTheFirstEntry()
    {
        var history = new SubtitleHistory();
        history.Add("Hold the gate", "Kapıyı tut", LineOrigin.Engine, Ten);
        history.Add("Hold the gate.", "Kapıyı tut.", LineOrigin.Pack, Ten.AddSeconds(1));
        var entry = Assert.Single(history.Entries);
        Assert.Equal(0, entry.Id);
        Assert.Equal("Kapıyı tut.", entry.Translation);
        Assert.Equal(LineOrigin.Pack, entry.Origin);
        Assert.Equal(Ten.AddSeconds(1), entry.Date);
    }

    [Fact]
    public void EmptyTranslationIsIgnored()
    {
        var history = new SubtitleHistory();
        Assert.False(history.Add("Hold the gate", "   "));
        Assert.Empty(history.Entries);
    }

    [Fact]
    public void KeepsOnlyTheLimit()
    {
        var history = new SubtitleHistory(limit: 3);
        string[] lines = ["Alpha line one", "Bravo second words", "Charlie third thing", "Delta fourth text", "Echo fifth sentence"];
        foreach (var line in lines) history.Add(line, "TR " + line, LineOrigin.Engine, Ten);
        Assert.Equal(["TR Echo fifth sentence", "TR Delta fourth text", "TR Charlie third thing"], history.Entries.Select(e => e.Translation));
        Assert.Equal(200, new SubtitleHistory().Limit);
    }

    [Fact]
    public void LongTextIsClipped()
    {
        var history = new SubtitleHistory();
        history.Add(new string('a', 900), new string('b', 700));
        Assert.Equal(500, history.Entries[0].Source.Length);
        Assert.Equal(500, history.Entries[0].Translation.Length);
    }

    [Fact]
    public void ClearRemovesEverything()
    {
        var history = new SubtitleHistory();
        history.Add("Hold the gate", "Kapıyı tut");
        history.Clear();
        Assert.Empty(history.Entries);
    }

    [Fact]
    public void EntriesSinceADate()
    {
        var history = new SubtitleHistory();
        history.Add("Hold the gate", "Kapıyı tut", LineOrigin.Engine, Ten);
        history.Add("Get down!", "Yere yat!", LineOrigin.Engine, Ten.AddMinutes(10));
        Assert.Equal(["Yere yat!"], history.EntriesSince(Ten.AddMinutes(1)).Select(e => e.Translation));
        Assert.Equal(2, history.EntriesSince(Ten).Count);
    }

    [Fact]
    public void PlainTextHasLocalTimeTranslationAndSource()
    {
        var history = new SubtitleHistory();
        history.Add("Hold the gate", "Kapıyı tut", LineOrigin.Engine, Ten);
        history.Add("Get down!", "Yere yat!", LineOrigin.Pack, Ten.AddSeconds(65));
        var istanbul = TimeZoneInfo.CreateCustomTimeZone("UTC+3", TimeSpan.FromHours(3), "UTC+3", "UTC+3");
        Assert.Equal("[13:01:05] Yere yat!\nGet down!\n\n[13:00:00] Kapıyı tut\nHold the gate",
            SubtitleHistory.PlainText(history.Entries, istanbul));
    }

    [Fact]
    public void SavedHistoryLoadsBack()
    {
        var path = Path.Combine(folder, "nested", "history.json");
        var history = new SubtitleHistory();
        history.Add("Hold the gate", "Kapıyı tut", LineOrigin.Engine, Ten);
        history.Add("Get down!", "Yere yat!", LineOrigin.Pack, Ten.AddSeconds(5));
        history.Save(path);
        var loaded = SubtitleHistory.Load(path);
        Assert.Equal(history.Entries, loaded.Entries);
        Assert.False(File.Exists(path + ".tmp"));
        // Sonraki kayıt numarası kaldığı yerden sürer.
        loaded.Add("Run!", "Koş!", LineOrigin.Engine, Ten.AddSeconds(9));
        Assert.Equal(2, loaded.Entries[0].Id);
    }

    [Fact]
    public void FileMatchesTheMacFormat()
    {
        var path = Path.Combine(folder, "history.json");
        var history = new SubtitleHistory();
        history.Add("Get down!", "Yere yat!", LineOrigin.Pack, Ten.AddTicks(1234567));
        history.Save(path);
        Assert.Equal("""{"version":1,"entries":[{"id":0,"date":"2026-11-12T10:00:00Z","source":"Get down!","translation":"Yere yat!","origin":"pack"}]}""",
            File.ReadAllText(path));
    }

    [Fact]
    public void ReadsTheMacFile()
    {
        var path = Path.Combine(folder, "history.json");
        Directory.CreateDirectory(folder);
        File.WriteAllText(path, """
            {"version":1,"entries":[
              {"id":4,"date":"2026-11-12T10:00:05Z","source":"Run!","translation":"Koş!","origin":"engine"},
              {"id":3,"date":"2026-11-12T10:00:00Z","source":"Get down!","translation":"Yere yat!","origin":"pack"}]}
            """);
        var loaded = SubtitleHistory.Load(path, limit: 1);
        var entry = Assert.Single(loaded.Entries);
        Assert.Equal(new SubtitleHistory.Entry(4, Ten.AddSeconds(5), "Run!", "Koş!", LineOrigin.Engine), entry);
        Assert.Equal(DateTimeKind.Utc, entry.Date.Kind);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("""{"version":1,"entries":[{"id":0,"date":"yesterday","source":"a","translation":"b","origin":"pack"}]}""")]
    [InlineData("""{"version":1,"entries":[{"id":0,"date":"2026-11-12T10:00:00Z","source":"a","translation":"b","origin":"radio"}]}""")]
    public void CorruptFileGivesEmptyHistory(string content)
    {
        var path = Path.Combine(folder, "history.json");
        Directory.CreateDirectory(folder);
        File.WriteAllText(path, content);
        Assert.Empty(SubtitleHistory.Load(path).Entries);
    }

    [Fact]
    public void MissingFileGivesEmptyHistory() => Assert.Empty(SubtitleHistory.Load(Path.Combine(folder, "none.json")).Entries);
}
