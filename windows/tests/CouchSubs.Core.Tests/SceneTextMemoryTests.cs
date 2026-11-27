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
            foreach (var step in vector.GetProperty("steps").EnumerateArray())
            {
                var at = step.GetProperty("at").GetInt64();
                if (step.TryGetProperty("dropped", out var dropped))
                    memory.Remember(Texts(dropped), step.GetProperty("reason").GetString()!, at);
                if (step.TryGetProperty("forget", out var forget)) memory.Forget(forget.GetString()!);
                if (step.TryGetProperty("read", out var read))
                {
                    var kept = memory.Filter(new Reading(Texts(read).Select(text => new TextLine(text))), at);
                    var expected = Texts(step.GetProperty("kept"));
                    Assert.True(expected.SequenceEqual(kept.Lines.Select(line => line.Text)),
                        $"{name}: {string.Join(" / ", kept.Lines.Select(line => line.Text))}");
                }
            }
        }
    }

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
