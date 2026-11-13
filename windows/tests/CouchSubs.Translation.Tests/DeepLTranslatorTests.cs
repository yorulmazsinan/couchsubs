// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Text;
using System.Text.Json;
using CouchSubs.Core;
using CouchSubs.Translation;
using Xunit;

namespace CouchSubs.Translation.Tests;

public class DeepLTranslatorTests
{
    /// <summary>DeepL yerine geçen sahte sunucu: gelen istekleri saklar, verilen yanıtı döner.</summary>
    private sealed class FakeDeepL(Func<HttpRequestMessage, string, HttpResponseMessage> reply) : HttpMessageHandler
    {
        public List<(HttpRequestMessage Request, string Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add((request, body));
            return reply(request, body);
        }
    }

    private sealed class FakeLocal : ITextTranslator
    {
        public List<string> Calls { get; } = [];
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
        {
            Calls.Add(text);
            return Task.FromResult("yerel: " + text);
        }
    }

    private static HttpResponseMessage Json(string json, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(json, Encoding.UTF8, "application/json") };

    /// <summary>Her cümleyi "[tr] cümle" diye çevirir.</summary>
    private static HttpResponseMessage Echo(HttpRequestMessage request, string body)
    {
        var texts = JsonDocument.Parse(body).RootElement.GetProperty("text").EnumerateArray().Select(t => t.GetString());
        return Json(JsonSerializer.Serialize(new { translations = texts.Select(t => new { text = "[tr] " + t }) }));
    }

    [Fact]
    public async Task SpeakerLabelStaysAndPreviousSubtitleIsContext()
    {
        var deepL = new FakeDeepL(Echo);
        var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL));

        Assert.Equal("KRATOS: [tr] We move on.", await translator.TranslateAsync("KRATOS: We move on."));
        await translator.TranslateAsync("Stay close.");

        var (first, firstBody) = deepL.Requests[0];
        Assert.Equal("https://api-free.deepl.com/v2/translate", first.RequestUri!.AbsoluteUri);
        Assert.Equal("DeepL-Auth-Key abc:fx", first.Headers.Authorization!.ToString());
        var json = JsonDocument.Parse(firstBody).RootElement;
        Assert.Equal("We move on.", json.GetProperty("text")[0].GetString());
        Assert.Equal("TR", json.GetProperty("target_lang").GetString());
        Assert.False(json.TryGetProperty("context", out _));
        Assert.Equal("KRATOS: We move on.", JsonDocument.Parse(deepL.Requests[1].Body).RootElement.GetProperty("context").GetString());
    }

    // Phantom Blade Zero: "Soul" adı DeepL'e etiketle korunarak gider; "began" "Pegan" olmuyordu (2026-11-13).
    [Fact]
    public async Task GlossaryNamesAreSentInIgnoredTags()
    {
        var deepL = new FakeDeepL(Echo);
        var glossary = new GlossaryStore(null);
        var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL), glossary: glossary);

        var result = await translator.TranslateAsync("Soul began to fight. Sell your soul & run.");

        var json = JsonDocument.Parse(deepL.Requests[0].Body).RootElement;
        Assert.Equal("xml", json.GetProperty("tag_handling").GetString());
        Assert.Equal("x", json.GetProperty("ignore_tags")[0].GetString());
        var texts = json.GetProperty("text").EnumerateArray().Select(t => t.GetString()).ToList();
        Assert.Contains("<x>Soul</x> began to fight.", texts);
        Assert.Contains("Sell your soul &amp; run.", texts);
        Assert.DoesNotContain("<x>", result);
        Assert.Contains("[tr] Soul began to fight.", result);
        Assert.Contains("& run.", result);
    }

    [Fact]
    public async Task WithoutGlossaryTermsTheRequestIsPlainText()
    {
        var deepL = new FakeDeepL(Echo);
        var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL), glossary: new GlossaryStore(null));
        await translator.TranslateAsync("Stay close & quiet.");
        var json = JsonDocument.Parse(deepL.Requests[0].Body).RootElement;
        Assert.False(json.TryGetProperty("tag_handling", out _));
        Assert.Equal("Stay close & quiet.", json.GetProperty("text")[0].GetString());
    }

    [Fact]
    public async Task SameSubtitleIsNotSentTwice()
    {
        var deepL = new FakeDeepL(Echo);
        var translator = new DeepLTranslator("abc", new FakeLocal(), new HttpClient(deepL));
        await translator.TranslateAsync("Who are you?");
        await translator.TranslateAsync("Who are you?");
        Assert.Single(deepL.Requests);
        Assert.StartsWith("https://api.deepl.com/", deepL.Requests[0].Request.RequestUri!.AbsoluteUri);
    }

    private static string? ContextOf(string body) =>
        JsonDocument.Parse(body).RootElement.TryGetProperty("context", out var context) ? context.GetString() : null;

    private static string[] TextsOf(string body) =>
        [.. JsonDocument.Parse(body).RootElement.GetProperty("text").EnumerateArray().Select(t => t.GetString()!)];

    /// <summary>Bağlam son gösterilen 3 satırdır (eskiden yeniye); satırın kendisi ve tekrar okunan satır girmez.</summary>
    [Fact]
    public async Task ContextIsTheLastThreeShownLines()
    {
        var deepL = new FakeDeepL(Echo);
        var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL));
        foreach (var line in new[] { "One.", "Two.", "Two.", "Three.", "Four.", "Five." })
            await translator.TranslateAsync(line);

        Assert.Equal(5, deepL.Requests.Count);
        Assert.Null(ContextOf(deepL.Requests[0].Body));
        Assert.Equal("One.", ContextOf(deepL.Requests[1].Body));
        Assert.Equal("One.\nTwo.", ContextOf(deepL.Requests[2].Body));
        Assert.Equal("Two.\nThree.\nFour.", ContextOf(deepL.Requests[4].Body));
    }

    /// <summary>Önbellekten dönen satır da gösterilmiştir; sonraki satırın bağlamına girer.</summary>
    [Fact]
    public async Task CachedLinesCountAsContext()
    {
        var deepL = new FakeDeepL(Echo);
        var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL));
        await translator.TranslateAsync("Where is he?");
        await translator.TranslateAsync("Upstairs.");
        await translator.TranslateAsync("Where is he?");
        await translator.TranslateAsync("Go get him.");
        Assert.Equal(3, deepL.Requests.Count);
        Assert.Equal("Where is he?\nUpstairs.\nWhere is he?", ContextOf(deepL.Requests[2].Body));
    }

    /// <summary>Önceki oturumda çevrilen satır ve cümleler DeepL'e hiç gitmez; yalnız yeni cümle gönderilir.</summary>
    [Fact]
    public async Task PersistentCacheSavesQuotaAcrossSessions()
    {
        var file = Path.Combine(Path.GetTempPath(), "couchsubs-deepl-" + Guid.NewGuid().ToString("N"), "cache.jsonl");
        try
        {
            var first = new FakeDeepL(Echo);
            await new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(first), new TranslationCache(file))
                .TranslateAsync("KRATOS: We go now. Stay close.");

            var deepL = new FakeDeepL(Echo);
            var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL), new TranslationCache(file));
            Assert.Equal("KRATOS: [tr] We go now. [tr] Stay close.", await translator.TranslateAsync("KRATOS: We go now. Stay close."));
            Assert.Empty(deepL.Requests);
            Assert.Equal("[tr] Stay close. [tr] Run!", await translator.TranslateAsync("Stay close. Run!"));
            Assert.Equal(["Run!"], TextsOf(Assert.Single(deepL.Requests).Body));
            Assert.Equal("KRATOS", translator.SpokenLines("KRATOS: We go now. Stay close.")[1].Speaker);
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(file)!, recursive: true);
        }
    }

    /// <summary>DeepL düşünce yerel modelin çevirisi DeepL önbelleğine yazılmaz; DeepL dönünce satır DeepL ile çevrilir.</summary>
    [Fact]
    public async Task FallbackResultsAreNotCachedAsDeepL()
    {
        var fail = true;
        var deepL = new FakeDeepL((request, body) => fail ? new HttpResponseMessage(HttpStatusCode.BadGateway) : Echo(request, body));
        var cache = new TranslationCache();
        var translator = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL), cache);
        Assert.Equal("yerel: Run!", await translator.TranslateAsync("Run!"));
        Assert.False(cache.TryGet("Run!", out _));

        fail = false;
        var fresh = new DeepLTranslator("abc:fx", new FakeLocal(), new HttpClient(deepL), cache);
        Assert.Equal("[tr] Run!", await fresh.TranslateAsync("Run!"));
    }

    /// <summary>Kota biterse ya da DeepL'e ulaşılamazsa oyun altyazısız kalmaz; bir süre DeepL hiç denenmez.</summary>
    [Fact]
    public async Task FallsBackToLocalModelWhenDeepLFails()
    {
        var deepL = new FakeDeepL((_, _) => new HttpResponseMessage((HttpStatusCode)456));
        var local = new FakeLocal();
        var translator = new DeepLTranslator("abc:fx", local, new HttpClient(deepL));

        Assert.Equal("yerel: Run!", await translator.TranslateAsync("Run!"));
        Assert.Equal(OnlineKeyState.QuotaExceeded, translator.LastError);
        Assert.Equal("yerel: Hide!", await translator.TranslateAsync("Hide!"));
        Assert.Single(deepL.Requests);
        Assert.Equal(["Run!", "Hide!"], local.Calls);
    }

    [Fact]
    public async Task KeyCheckReportsUsageAndRejectedKeys()
    {
        var usage = new FakeDeepL((_, _) => Json("""{"character_count":1200,"character_limit":500000}"""));
        Assert.Equal(new OnlineKeyCheck(OnlineKeyState.Valid, 1200, 500000), await DeepLTranslator.CheckAsync("k:fx", new HttpClient(usage)));
        Assert.EndsWith("/v2/usage", usage.Requests[0].Request.RequestUri!.AbsoluteUri);

        var rejected = new FakeDeepL((_, _) => new HttpResponseMessage(HttpStatusCode.Forbidden));
        Assert.Equal(OnlineKeyState.Invalid, (await DeepLTranslator.CheckAsync("k", new HttpClient(rejected))).State);

        var full = new FakeDeepL((_, _) => Json("""{"character_count":500000,"character_limit":500000}"""));
        Assert.Equal(OnlineKeyState.QuotaExceeded, (await DeepLTranslator.CheckAsync("k", new HttpClient(full))).State);

        Assert.Equal(OnlineKeyState.Invalid, (await DeepLTranslator.CheckAsync("  ")).State);
    }
}
