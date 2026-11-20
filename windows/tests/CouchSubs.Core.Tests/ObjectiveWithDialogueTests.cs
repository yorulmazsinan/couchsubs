// SPDX-License-Identifier: AGPL-3.0-only
namespace CouchSubs.Core.Tests;

/// <summary>Sırayla farklı okumalar döndüren, satırları yerleriyle veren okuyucu.</summary>
internal sealed class SequenceReader(IEnumerable<Reading> readings) : ITextReader
{
    private readonly Queue<Reading> readings = new(readings);
    public string Read(Frame image) => ReadLines(image, false).Text;
    public Reading ReadLines(Frame image, bool deep)
    {
        lock (readings) return readings.Count == 0 ? Reading.Empty : readings.Dequeue();
    }
}

/// <summary>
/// Kullanıcı bildirimi (GTA 6): oyun altta "x yere git" gibi bir görev yazısı gösterirken o sırada gelen altyazıların hiçbiri
/// çevrilmiyordu. Görev satırı sabit dururken üstünde ya da altında değişen altyazıların hepsi çevrilmeli, görev hiçbir
/// altyazıya karışmamalı (Mac: ObjectiveWithDialogueTests.swift, Android: ObjectiveWithDialogueTest.kt).
/// </summary>
public class ObjectiveWithDialogueTests
{
    private const string Objective = "Go to the bank.";

    internal static readonly string[][] Dialogue =
    [
        ["We have to move before the cops show up."],
        ["I told you this was a bad idea,", "but you never listen to me."],
        ["Lucia: Just drive the car and stay calm."],
        ["Where did they take all the money?"],
        ["Nobody saw us leave the place.", "Keep your head down for a while."],
    ];

    /// <summary>Satır yüksekliği (alana oranla) ve satırların dikey yeri; altyazı ortada, görev ortalı.</summary>
    private const double Line = 0.08;

    private static TextLine Row(string text, double top, double width = 0.6) =>
        new(text, new TextBox(0.5 - width / 2, top, 0.5 + width / 2, top + Line), 0.95);

    /// <summary>
    /// Kareler: görev önce tek başına (<paramref name="objectiveFirstFrames"/> kare), sonra her altyazı 4 kare (2 sn) görevle
    /// birlikte. <paramref name="objectiveGap"/>: görev ile altyazı arasındaki boşluk (satır yüksekliğine oranla);
    /// <paramref name="below"/>: görev altyazının altında mı.
    /// </summary>
    internal static List<Reading> Frames(bool below, double objectiveGap, int objectiveFirstFrames, int framesEach = 4)
    {
        var frames = new List<Reading>();
        for (var i = 0; i < objectiveFirstFrames; i++) frames.Add(new Reading([Row(Objective, below ? 0.8 : 0.2, 0.3)]));
        foreach (var lines in Dialogue)
        {
            var height = lines.Length * Line;
            var rows = new List<TextLine>();
            double top;
            if (below)
            {
                // Görev 0.80'de; altyazı onun üstünde, aralarında objectiveGap satır boşluk.
                top = 0.8 - objectiveGap * Line - height;
                rows.AddRange(lines.Select((text, i) => Row(text, top + i * Line)));
                rows.Add(Row(Objective, 0.8, 0.3));
            }
            else
            {
                rows.Add(Row(Objective, 0.2, 0.3));
                top = 0.2 + Line + objectiveGap * Line;
                rows.AddRange(lines.Select((text, i) => Row(text, top + i * Line)));
            }
            for (var i = 0; i < framesEach; i++) frames.Add(new Reading(rows));
        }
        // Konuşma bitti, görev kaldı.
        for (var i = 0; i < 4; i++) frames.Add(new Reading([Row(Objective, below ? 0.8 : 0.2, 0.3)]));
        return frames;
    }

    [Theory]
    [InlineData(true, 0.1, 4)]   // görev altta, bitişik; altyazıdan 2 sn önce belirdi
    [InlineData(true, 1.5, 4)]   // görev altta, ayrı blok
    [InlineData(false, 0.1, 4)]  // görev üstte, bitişik
    [InlineData(false, 1.5, 4)]  // görev üstte, ayrı blok
    [InlineData(true, 0.1, 20)]  // görev 10 sn önceden ekranda
    [InlineData(true, 1.5, 20)]
    [InlineData(false, 0.1, 20)]
    [InlineData(true, 0.1, 0)]   // görev ilk altyazıyla aynı anda belirdi: ilki ayırt edilemez, sonrakiler çevrilir
    [InlineData(true, 1.5, 0)]
    public async Task EveryDialogueIsTranslatedWhileObjectiveStays(bool below, double gap, int objectiveFirst)
    {
        var frames = Frames(below, gap, objectiveFirst);
        long clock = 0;
        var translator = new FakeTranslator();
        var sender = new FakeSender();
        var pipeline = new SubtitlePipeline(new SequenceReader(frames), translator, sender, clock: () => clock)
        { PackWait = 0, CleanWait = 0 };
        for (var i = 0; i < frames.Count; i++)
        {
            await pipeline.ProcessAsync(Frame.Blank(64, 64), new CropRegion(0, 1, 0, 1));
            await pipeline.WaitForTranslationsAsync();
            clock += 500;
        }
        var requested = string.Join(" | ", translator.Requested);
        // Görev ile aynı anda beliren ilk altyazı hangisinin görev olduğu bilinemediği için şart değil.
        var expected = objectiveFirst == 0 ? Dialogue.Skip(1) : Dialogue;
        var missing = expected.SelectMany(lines => lines).Select(line => line.Replace("Lucia: ", ""))
            .Where(line => !translator.Requested.Any(text => text.Contains(line))).ToList();
        Assert.True(missing.Count == 0, $"çevrilmedi: {string.Join(" / ", missing)} — istekler: {requested}");
        // Görev satırı hiçbir altyazı isteğine karışmaz (yalnız görev tek başınayken kendisi çevrilebilir).
        var mixed = translator.Requested.Where(text => text.Contains(Objective.TrimEnd('.')) && text.Trim() != Objective)
            .Where(text => objectiveFirst != 0 || !text.Contains(Dialogue[0][0])).ToList();
        Assert.True(mixed.Count == 0, $"görev karıştı: {string.Join(" | ", mixed)}");
    }
}
