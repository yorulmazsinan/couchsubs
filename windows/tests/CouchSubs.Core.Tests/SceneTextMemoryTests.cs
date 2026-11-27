// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json;
using CouchSubs.Core;
using Xunit;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Az önce sahne yazısı sayılıp atılan satırın (plaka, tabela, telefon mesajı) başka okunuşu altyazı olmaz (#1411).
/// Örnekler ortak deneme dosyasından (core/Tests/CouchSubsCoreTests/Fixtures/scene-text-memory.json; Mac
/// SceneTextMemoryTests.swift ve Android SceneTextMemoryTest.kt aynı dosyayı okur).
/// </summary>
public class SceneTextMemoryTests
{
    private static List<string> Texts(JsonElement element) =>
        [.. element.EnumerateArray().Select(value => value.GetString()!)];

    [Fact]
    public void SharedVectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("scene-text-memory.json")));
        var cases = fixture.RootElement.GetProperty("cases").EnumerateArray().ToList();
        Assert.NotEmpty(cases);
        foreach (var vector in cases)
        {
            var name = vector.GetProperty("name").GetString();
            var memory = new SceneTextMemory();
            var band = new SubtitleBand();
            foreach (var step in vector.GetProperty("steps").EnumerateArray())
            {
                var at = step.GetProperty("at").GetInt64();
                TextBox? area = step.TryGetProperty("area", out var place) ? Box(place) : null;
                if (step.TryGetProperty("band", out var subtitle)) band.Record(Boxed(subtitle), area!.Value);
                if (step.TryGetProperty("dropped", out var dropped))
                    memory.Remember(Texts(dropped), step.GetProperty("reason").GetString()!, at);
                if (step.TryGetProperty("forget", out var forget)) memory.Forget(forget.GetString()!);
                Reading? reading = step.TryGetProperty("read", out var read)
                    ? new Reading(Texts(read).Select(text => new TextLine(text)))
                    : step.TryGetProperty("lines", out var lines) ? Boxed(lines) : null;
                if (reading is null) continue;
                var kept = memory.Filter(reading, at, area, band);
                var expected = Texts(step.GetProperty("kept"));
                Assert.True(expected.SequenceEqual(kept.Lines.Select(line => line.Text)),
                    $"{name}: {string.Join(" / ", kept.Lines.Select(line => line.Text))}");
                if (step.TryGetProperty("leftovers", out var leftovers))
                    Assert.True(Texts(leftovers).SequenceEqual(memory.Leftovers.Select(left => left.Line.Text)),
                        $"{name} (kalan): {string.Join(" / ", memory.Leftovers.Select(left => left.Line.Text))}");
            }
        }
    }

    private static TextBox Box(JsonElement element)
    {
        var values = element.EnumerateArray().Select(value => value.GetDouble()).ToArray();
        return new TextBox(values[0], values[1], values[2], values[3]);
    }

    private static Reading Boxed(JsonElement lines) => new(lines.EnumerateArray().Select(line =>
        new TextLine(line.GetProperty("text").GetString()!, Box(line.GetProperty("box")), 1)));

    /// <summary>Ortak dosyadaki nedenler çekirdeğin nedenleriyle aynı yazılır (biri değişirse dosya da değişmeli).</summary>
    [Fact]
    public void RememberedReasonsMatchTheGate()
    {
        foreach (var reason in new[] { SceneText.SignReason, SceneText.NumberReason, SceneText.PlateNumberReason,
                     SceneText.MenuItemReason, SceneText.TiltedReason, InkTone.Reason, Reading.OffBandReason,
                     SceneTextMemory.PhoneReason })
            Assert.True(SceneTextMemory.Remembers(reason), reason);
        foreach (var reason in new[] { SceneMotion.Reason, PackageText.Reason, Reading.ListReason, "karenin ortasında kısa satır" })
            Assert.False(SceneTextMemory.Remembers(reason), reason);
    }

    private sealed class SwitchReader : ITextReader
    {
        public Reading Reading { get; set; } = Reading.Empty;
        public string Read(Frame image) => Reading.Text;
        public Reading ReadLines(Frame image, bool deep) => Reading;
    }

    /// <summary>Okumaları sırayla (her biri 12 kare) tam ekran alanda hattan geçirir; çevirmene gidenler ve günlük.</summary>
    private static async Task<(List<string> Requested, List<string> Log)> Run(params Reading[] readings)
    {
        long clock = 1_000_000;
        var reader = new SwitchReader();
        var translator = new FakeTranslator();
        var log = new List<string>();
        var pipeline = new SubtitlePipeline(reader, translator, new FakeSender(), clock: () => clock) { Log = log.Add };
        foreach (var reading in readings)
        {
            reader.Reading = reading;
            for (var i = 0; i < 12; i++)
            {
                var frame = new Frame(Enumerable.Repeat((byte)(reading.Text.Length % 7 * 36), 64 * 64 * 4).ToArray(), 64, 64, 256);
                await pipeline.ProcessAsync(frame, new CropRegion());
                await pipeline.WaitForTranslationsAsync();
                clock += 100;
            }
        }
        return (translator.Requested, log);
    }

    /// <summary>
    /// #1411 (GTA 6, beta-105): plakanın "GOOD TIME STATE" yazısı bir karede plaka sayılıp atılıyor, bir sonraki karede tek
    /// satır ve noktalı ("&amp; COCOTIME STATE O.") okununca altyazı sanılıp çevriliyordu. Aynı okuma önceden plaka görülmeden
    /// gelirse altyazı kuralı onu geçirir (denemenin kendisi bunu da doğrular).
    /// </summary>
    [Fact]
    public async Task PlateRereadAfterBeingDroppedIsNotTranslated()
    {
        var plate = new Reading([
            new TextLine("NIC", new TextBox(0.47, 0.82, 0.53, 0.85), 1),
            new TextLine("COCOTIME STATE A", new TextBox(0.42, 0.86, 0.58, 0.89), 1),
        ]);
        var reread = new Reading([new TextLine("& COCOTIME STATE O.", new TextBox(0.42, 0.86, 0.58, 0.89), 1)]);
        var alone = await Run(reread);
        Assert.True(alone.Requested.Count == 1, string.Join("\n", alone.Log));
        var after = await Run(plate, reread);
        Assert.True(after.Requested.Count == 0, string.Join("\n", after.Log));
        Assert.Contains(after.Log, line => line.Contains(SceneTextMemory.Reason) && line.Contains("plaka/tabela"));
    }

    /// <summary>Gerçek karenin kayıtlı okuması (testdata/frames/ocr; Mac'te Apple Vision ile kaydedildi).</summary>
    private static Reading Recorded(string id, [System.Runtime.CompilerServices.CallerFilePath] string source = "")
    {
        var path = System.IO.Path.GetFullPath(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(source)!, "..", "..", "..",
            "testdata", "frames", "ocr", id + ".json"));
        using var fixture = JsonDocument.Parse(File.ReadAllText(path));
        return Boxed(fixture.RootElement.GetProperty("lines"));
    }

    /// <summary>
    /// #1414'ün yan etkisi (gerçek kare gta6-n1-kitap): kitap kapağının "[TOM E / DESIGN" satırları tabela sayılıp atılıyor,
    /// alt satır ("A LIBERTY CITY MEMOIR") belirince DESIGN hatırlanıp çıkarılıyor, kapağın tek kalan satırı altyazı sanılıp
    /// çevriliyordu. Bloğun çoğu sahne yazısıysa kalanı da çevrilmez; günlükte nedeniyle yazılır.
    /// </summary>
    [Fact]
    public async Task LeftoverLineOfASceneBlockIsNotTranslated()
    {
        var cover = Recorded("gta6-n1-kitap");
        var top = new Reading(cover.Lines.Where(line => line.Text != "A LIBERTY CITY MEMOIR"));
        var run = await Run(top, cover);
        Assert.True(run.Requested.Count == 0, string.Join("\n", run.Requested.Concat(run.Log)));
        Assert.Contains(run.Log, line => line.Contains(SceneTextMemory.BlockReason) && line.Contains("A LIBERTY CITY MEMOIR"));
    }

    /// <summary>
    /// Telefon sohbeti (gerçek kare gta6-telefon-sohbet-1): altyazının yüksekliği konuşmadan (gta6-01-lucia) öğrenildikten
    /// sonra üç satırı menü açıklaması sayılıp atılan mesajın son satırı ("bring it 2 me •") tek başına çevrilmez.
    /// </summary>
    [Fact]
    public async Task LeftoverLineOfAPhoneChatIsNotTranslated()
    {
        var chat = Recorded("gta6-telefon-sohbet-1");
        var top = new Reading(chat.Lines.Where(line => !line.Text.StartsWith("bring", StringComparison.Ordinal)));
        var run = await Run(Recorded("gta6-01-lucia"), top, chat);
        Assert.True(run.Requested.SequenceEqual(["Could I have another ice water, please?"]),
            string.Join("\n", run.Requested.Concat(run.Log)));
    }

    [Fact]
    public void ResetForgetsEverything()
    {
        var memory = new SceneTextMemory();
        memory.Remember(["ALL GUN SALES ARE FINAL"], SceneText.SignReason, 0);
        memory.Reset();
        var kept = memory.Filter(new Reading([new TextLine("ALL GUN SALES ARE FINAL")]), 10);
        Assert.Equal(["ALL GUN SALES ARE FINAL"], kept.Lines.Select(line => line.Text));
        Assert.Empty(memory.Removed);
    }
}
