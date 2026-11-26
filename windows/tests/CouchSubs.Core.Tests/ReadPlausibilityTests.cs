// SPDX-License-Identifier: AGPL-3.0-only
using System.Text.Json;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>Yazı tanımanın bozduğu satır çeviri motoruna gitmez (GitHub #1293). Mac/iPhone: ReadPlausibilityTests.swift,
/// Android: ReadPlausibilityTest.kt; üçü de read-plausibility.json'u okur.</summary>
public class ReadPlausibilityTests
{
    private static readonly Frame Image = Frame.Blank(64, 64);

    [Fact]
    public void SharedVectors()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path("read-plausibility.json")));
        foreach (var text in fixture.RootElement.GetProperty("garbled").EnumerateArray().Select(item => item.GetString()!))
            Assert.True(ReadPlausibility.Reason(text) is not null, text);
        foreach (var text in fixture.RootElement.GetProperty("kept").EnumerateArray().Select(item => item.GetString()!))
            Assert.True(ReadPlausibility.Reason(text) is null, $"{text}: {ReadPlausibility.Reason(text)}");
    }

    /// <summary>Var olan sahne yazısı, altyazı ve telefon fixture'larındaki satırların hiçbiri bozuk sayılmaz.</summary>
    [Theory]
    [InlineData("scene-text.json")]
    [InlineData("growing-lines.json")]
    [InlineData("settled-text.json")]
    [InlineData("phone-chat.json")]
    public void ExistingSubtitleFixturesAreKept(string name)
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(PackFixtures.Path(name)));
        var texts = new List<string>();
        void Walk(JsonElement element, string? key)
        {
            switch (element.ValueKind)
            {
                case JsonValueKind.String when key == "text": texts.Add(element.GetString()!); break;
                case JsonValueKind.Array: foreach (var item in element.EnumerateArray()) Walk(item, key); break;
                case JsonValueKind.Object: foreach (var property in element.EnumerateObject()) Walk(property.Value, property.Name); break;
            }
        }
        Walk(fixture.RootElement, null);
        Assert.NotEmpty(texts);
        foreach (var text in texts) Assert.True(ReadPlausibility.Reason(text) is null, $"{name}: {text}: {ReadPlausibility.Reason(text)}");
    }

    [Fact]
    public void LogIsRateLimited()
    {
        long time = 0;
        var log = new ReadPlausibility.Log(() => time);
        Assert.Equal("okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea / arter» (r)", log.Line("es aepressea\narter", "r"));
        Assert.Null(log.Line("es aepressea\narter", "r"));
        for (var i = 0; i < ReadPlausibility.Log.PerMinute - 1; i++) Assert.NotNull(log.Line($"satır {i}", "r"));
        Assert.Null(log.Line("bir satır daha", "r"));
        time += ReadPlausibility.Log.RepeatMs;
        Assert.Equal("okuma bozuk görünüyor, çeviriye gönderilmedi: «es aepressea / arter» (r) (+1 satır sınır yüzünden yazılmadı)",
            log.Line("es aepressea\narter", "r"));
    }

    private static async Task Run(SubtitlePipeline pipeline, int frames, Action advance)
    {
        for (var i = 0; i < frames; i++)
        {
            await pipeline.ProcessAsync(Image, new CropRegion());
            await pipeline.WaitForTranslationsAsync();
            advance();
        }
    }

    /// <summary>Bozuk okuma motora gitmez, önceki altyazı ekranda kalır; aynı satır düzgün okununca çevrilir. Günlüğe bir kez yazılır.</summary>
    [Fact]
    public async Task GarbledReadIsNotTranslatedAndThePreviousSubtitleStays()
    {
        const string clean = "Get in the car, now.", garbled = "es aepressea arter Donnıas aeatIT", fixedRead = "He's depressed after Donna's death.";
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var reader = new FakeReader([.. Enumerable.Repeat(clean, 4), .. Enumerable.Repeat(garbled, 16), .. Enumerable.Repeat(fixedRead, 4)]);
        var pipeline = new SubtitlePipeline(reader, translator, sender, clock: () => clock);
        var logs = new List<string>();
        pipeline.Log = logs.Add;
        await Run(pipeline, 4, () => clock += 250);
        Assert.Equal([clean], translator.Requested);
        await Run(pipeline, 16, () => clock += 250);
        Assert.Equal([clean], translator.Requested);
        Assert.Equal(0, sender.Clears);
        Assert.Single(logs, line => line.StartsWith($"okuma bozuk görünüyor, çeviriye gönderilmedi: «{garbled}»"));
        await Run(pipeline, 4, () => clock += 250);
        Assert.Equal([clean, fixedRead], translator.Requested);
    }

    /// <summary>Paketteki satır bozuk görünse de paketten gösterilir (süzgeç yalnız motora gidecek satıra bakar).</summary>
    [Fact]
    public async Task PackedLineIsShownEvenIfItLooksGarbled()
    {
        const string garbled = "es aepressea arter Donnıas aeatIT";
        var sender = new FakeSender();
        var translator = new FakeTranslator();
        long clock = 0;
        var pipeline = new SubtitlePipeline(new FakeReader([.. Enumerable.Repeat(garbled, 8)]), translator, sender, clock: () => clock)
        {
            PackLookup = text => text == garbled ? new PackMatch("Donna öldüğünden beri bunalımda.", []) : null,
        };
        // Çöp gibi okunan satır kararlayıcıda `GarbledStableMs` kadar bekler.
        await Run(pipeline, 8, () => clock += 250);
        Assert.Empty(translator.Requested);
        Assert.Equal(["Donna öldüğünden beri bunalımda."], sender.Sent);
    }
}
