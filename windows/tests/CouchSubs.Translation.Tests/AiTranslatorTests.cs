// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CouchSubs.Core;
using CouchSubs.Translation;
using Xunit;

namespace CouchSubs.Translation.Tests;

/// <summary>Mac'teki AITranslationTests ile aynı durumlar. Gerçek hizmetlere hiç gidilmez.</summary>
public class AiTranslatorTests
{
    private const string Secret = "sk-SECRET-123";

    /// <summary>Yapay zekâ hizmetlerinin yerine geçen sahte sunucu: istekleri saklar, cümleleri "[tr] cümle" diye çevirir.</summary>
    private sealed class FakeAi(Func<HttpRequestMessage, string, HttpResponseMessage>? reply = null) : HttpMessageHandler
    {
        public List<(HttpRequestMessage Request, string Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken);
            Requests.Add((request, body));
            return (reply ?? Echo)(request, body);
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

    internal static string UserText(HttpRequestMessage request, string body)
    {
        var root = JsonNode.Parse(body)!;
        return request.RequestUri!.Host == "generativelanguage.googleapis.com"
            ? root["contents"]![0]!["parts"]![0]!["text"]!.GetValue<string>()
            : root["messages"]!.AsArray()[^1]!["content"]!.GetValue<string>();
    }

    /// <summary>İletinin son satırındaki JSON dizisini "[tr] …" diye çevirir.</summary>
    private static string EchoText(string user)
    {
        var sentences = JsonNode.Parse(user.Split('\n')[^1])!.AsArray().Select(n => "[tr] " + n!.GetValue<string>());
        return new JsonArray([.. sentences.Select(s => (JsonNode?)JsonValue.Create(s))]).ToJsonString();
    }

    /// <summary>Hizmetin kendi yanıt biçimi.</summary>
    private static HttpResponseMessage Wrap(HttpRequestMessage request, string text)
    {
        JsonNode reply = request.RequestUri!.Host switch
        {
            "generativelanguage.googleapis.com" => new JsonObject
            {
                ["candidates"] = new JsonArray(new JsonObject
                {
                    ["content"] = new JsonObject
                    {
                        ["role"] = "model",
                        ["parts"] = new JsonArray(new JsonObject { ["text"] = "thinking…", ["thought"] = true }, new JsonObject { ["text"] = text }),
                    },
                }),
            },
            // Yerel model sunucuları (Ollama, LM Studio) OpenAI biçimiyle yanıt verir.
            "api.openai.com" or "localhost" or "127.0.0.1" or "192.168.1.20" => new JsonObject
            {
                ["choices"] = new JsonArray(new JsonObject
                {
                    ["message"] = new JsonObject { ["role"] = "assistant", ["content"] = text },
                    ["finish_reason"] = "stop",
                }),
            },
            _ => new JsonObject
            {
                ["content"] = new JsonArray(new JsonObject { ["type"] = "thinking", ["thinking"] = "…" }, new JsonObject { ["type"] = "text", ["text"] = text }),
                ["stop_reason"] = "end_turn",
            },
        };
        return Json(reply.ToJsonString());
    }

    private static HttpResponseMessage Echo(HttpRequestMessage request, string body) => Wrap(request, EchoText(UserText(request, body)));

    /// <summary>Her çevirmen kendi dakikalık hakkıyla kurulur; testler uygulamanın ortak hakkını tüketmesin.</summary>
    private static AiTranslator Make(AiProvider provider, FakeAi fake, ITextTranslator? local = null, TranslationCache? cache = null, string? model = null,
                                     RequestBudget? budget = null) =>
        new(provider, $"  {Secret} ", model, local ?? new FakeLocal(), new HttpClient(fake), cache, budget ?? new RequestBudget(1000));

    /// <summary>Gemini'nin dakikalık sınır yanıtı (error.details içinde QuotaFailure ve RetryInfo).</summary>
    private static string RateLimitBody(string quotaId, string value = "5", string delay = "3s") =>
        $$$"""{"error":{"code":429,"message":"You exceeded your current quota.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"{{{quotaId}}}","quotaValue":"{{{value}}}"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"{{{delay}}}"}]}}""";

    private const string PerMinute = "GenerateRequestsPerMinutePerProjectPerModel-FreeTier";

    private static string User(FakeAi fake, int index) => UserText(fake.Requests[index].Request, fake.Requests[index].Body);

    // --- İstek ---

    [Fact]
    public async Task GeminiRequest()
    {
        var fake = new FakeAi();
        Assert.Equal("KRATOS: [tr] We go now.", await Make(AiProvider.Gemini, fake).TranslateAsync("KRATOS: We go now."));
        var (request, body) = fake.Requests[0];
        Assert.Equal("https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent", request.RequestUri!.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(Secret, Assert.Single(request.Headers.GetValues("x-goog-api-key")));
        Assert.Null(request.Headers.Authorization);
        var json = JsonNode.Parse(body)!;
        Assert.Equal(AiRequest.SystemPrompt, json["systemInstruction"]!["parts"]![0]!["text"]!.GetValue<string>());
        Assert.Equal(AiRequest.MaxOutputTokens, json["generationConfig"]!["maxOutputTokens"]!.GetValue<int>());
        // Flash-Lite zaten en az düşünmeyle çalışır; düşünme ayarı gönderilmez.
        Assert.Null(json["generationConfig"]!["thinkingConfig"]);
        // Konuşmacı etiketi gönderilmez; yalnız cümle gider.
        Assert.EndsWith("[\"We go now.\"]", User(fake, 0));
        Assert.DoesNotContain("KRATOS", User(fake, 0));
    }

    [Fact]
    public async Task OpenAiRequest()
    {
        var fake = new FakeAi();
        await Make(AiProvider.OpenAi, fake).TranslateAsync("Run!");
        var (request, body) = fake.Requests[0];
        Assert.Equal("https://api.openai.com/v1/chat/completions", request.RequestUri!.AbsoluteUri);
        Assert.Equal($"Bearer {Secret}", Assert.Single(request.Headers.GetValues("Authorization")));
        var json = JsonNode.Parse(body)!;
        Assert.Equal("gpt-6-luna", json["model"]!.GetValue<string>());
        Assert.Equal("none", json["reasoning_effort"]!.GetValue<string>());
        Assert.Equal(AiRequest.MaxOutputTokens, json["max_completion_tokens"]!.GetValue<int>());
        var messages = json["messages"]!.AsArray();
        Assert.Equal(["developer", "user"], messages.Select(m => m!["role"]!.GetValue<string>()));
        Assert.Equal(AiRequest.SystemPrompt, messages[0]!["content"]!.GetValue<string>());
    }

    [Fact]
    public async Task ClaudeRequest()
    {
        var fake = new FakeAi();
        await Make(AiProvider.Claude, fake).TranslateAsync("Run!");
        var (request, body) = fake.Requests[0];
        Assert.Equal("https://api.anthropic.com/v1/messages", request.RequestUri!.AbsoluteUri);
        Assert.Equal(Secret, Assert.Single(request.Headers.GetValues("x-api-key")));
        Assert.Equal("2023-06-01", Assert.Single(request.Headers.GetValues("anthropic-version")));
        var json = JsonNode.Parse(body)!;
        Assert.Equal("claude-haiku-5-5", json["model"]!.GetValue<string>());
        Assert.Equal(AiRequest.MaxOutputTokens, json["max_tokens"]!.GetValue<int>());
        Assert.Equal(AiRequest.SystemPrompt, json["system"]!.GetValue<string>());
        Assert.Null(json["temperature"]);
        Assert.Equal("low", json["output_config"]!["effort"]!.GetValue<string>());
        Assert.Equal("disabled", json["thinking"]!["type"]!.GetValue<string>());
    }

    /// <summary>Effort ve düşünme ayarı listedeki modelden gelir, adından tahmin edilmez.</summary>
    [Fact]
    public async Task PerModelParametersAreSent()
    {
        var fake = new FakeAi();
        await Make(AiProvider.OpenAi, fake, model: "gpt-6.1-terra").TranslateAsync("Run!");
        var openAi = JsonNode.Parse(fake.Requests[0].Body)!;
        Assert.Equal("gpt-6.1-terra", openAi["model"]!.GetValue<string>());
        Assert.Equal("none", openAi["reasoning_effort"]!.GetValue<string>());

        await Make(AiProvider.Claude, fake, model: "claude-sonnet-5-5").TranslateAsync("Run!");
        var claude = JsonNode.Parse(fake.Requests[1].Body)!;
        Assert.Equal("claude-sonnet-5-5", claude["model"]!.GetValue<string>());
        Assert.Equal("low", claude["output_config"]!["effort"]!.GetValue<string>());
        Assert.Equal("between_tools", claude["thinking"]!["type"]!.GetValue<string>());

        await Make(AiProvider.Gemini, fake, model: "gemini-3.6-flash").TranslateAsync("Run!");
        Assert.Contains("/models/gemini-3.6-flash:generateContent", fake.Requests[2].Request.RequestUri!.AbsoluteUri);
        Assert.Equal("LOW", JsonNode.Parse(fake.Requests[2].Body)!["generationConfig"]!["thinkingConfig"]!["thinkingLevel"]!.GetValue<string>());
    }

    /// <summary>Listede olmayan kayıtlı model (eski ayar, elle yazılmış ad, listeden çıkarılan model) varsayılana döner.</summary>
    [Fact]
    public async Task UnknownModelFallsBackToDefault()
    {
        var fake = new FakeAi();
        await Make(AiProvider.OpenAi, fake, model: "gpt-4o").TranslateAsync("Run!");
        Assert.Equal("gpt-6-luna", JsonNode.Parse(fake.Requests[0].Body)!["model"]!.GetValue<string>());
        Assert.Equal("gemini-3.5-flash-lite", AiProvider.Gemini.Model("").Id);
        Assert.Equal("claude-haiku-5-5", AiProvider.Claude.Model(null).Id);
        Assert.Equal("gemini:gemini-3.5-flash-lite", AiProvider.Gemini.EngineId("gemini-3.5-flash-lite"));
        Assert.Equal("openai:gpt-6-luna", AiProvider.OpenAi.EngineId(AiProvider.OpenAi.DefaultModel().Id));
    }

    /// <summary>
    /// Liste Mac ile ortak dosyadan (core/Sources/CouchSubsCore/Resources/ai-models.json) gömülür; her hizmette önerilen
    /// hızlı model ilk sıradadır.
    /// </summary>
    [Fact]
    public void CatalogIsTheSharedFile()
    {
        var file = Path.Combine(RepoRoot(), "core", "Sources", "CouchSubsCore", "Resources", "ai-models.json");
        var parsed = AiModel.Parse(File.ReadAllText(file));
        Assert.Equal(["claude", "gemini", "openai"], parsed.Keys.Order());
        Assert.Equal(parsed.Keys.Order(), AiProviders.Cloud.Select(p => p.Id()).Order());
        // Yerel modelin listesi yoktur; model adını kullanıcı yazar.
        Assert.Empty(AiProvider.Local.Models());
        Assert.Equal("qwen2.5:7b", AiProvider.Local.DefaultModel().Id);
        foreach (var provider in AiProviders.Cloud)
        {
            Assert.Equal(parsed[provider.Id()], provider.Models());
            Assert.True(provider.Models().Count >= 2);
            Assert.Equal("Fast and cheap (recommended)", provider.DefaultModel().Label);
            Assert.Equal(provider.Models().Count, provider.Models().Select(m => m.Id).Distinct().Count());
            // Etiketler ortak metin dosyasında çevrilmiş olmalı.
            Assert.NotEqual(provider.DefaultModel().Label, Localizer.ForLanguage("tr")[provider.DefaultModel().Label]);
        }
        Assert.Equal(new AiModel("gemini-3.5-flash-lite", "Fast and cheap (recommended)", FreeTier: true, RequestsPerMinute: 15),
                     AiProvider.Gemini.DefaultModel());
        Assert.Equal("disabled", AiProvider.Claude.DefaultModel().Thinking);
    }

    private static string RepoRoot([System.Runtime.CompilerServices.CallerFilePath] string path = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(path)!, "..", "..", ".."));

    // --- Yerel model (Ollama, LM Studio) ---

    private static AiTranslator MakeLocal(FakeAi fake, string baseUrl = LocalAiServer.OllamaUrl, string model = "qwen2.5:7b", string key = "",
                                          ITextTranslator? local = null) =>
        new(AiProvider.Local, key, model, local ?? new FakeLocal(), new HttpClient(fake), budget: new RequestBudget(1000),
            server: LocalAiServer.Create(baseUrl, model));

    /// <summary>OpenAI uyumlu en sade istek: system + user, temperature, max_tokens, stream false; bulut hizmetine özel alan gitmez.</summary>
    [Fact]
    public async Task LocalRequest()
    {
        var fake = new FakeAi();
        Assert.Equal("KRATOS: [tr] We go now.", await MakeLocal(fake).TranslateAsync("KRATOS: We go now."));
        var (request, body) = fake.Requests[0];
        Assert.Equal("http://localhost:11434/v1/chat/completions", request.RequestUri!.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal("application/json", request.Content!.Headers.ContentType!.MediaType);
        // Anahtar boşsa Authorization başlığı hiç gitmez.
        Assert.Null(request.Headers.Authorization);
        var json = JsonNode.Parse(body)!.AsObject();
        Assert.Equal(["max_tokens", "messages", "model", "stream", "temperature"], json.Select(p => p.Key).Order());
        Assert.Equal("qwen2.5:7b", json["model"]!.GetValue<string>());
        Assert.Equal(AiRequest.LocalTemperature, json["temperature"]!.GetValue<double>());
        Assert.Equal(AiRequest.MaxOutputTokens, json["max_tokens"]!.GetValue<int>());
        Assert.False(json["stream"]!.GetValue<bool>());
        var messages = json["messages"]!.AsArray();
        Assert.Equal(["system", "user"], messages.Select(m => m!["role"]!.GetValue<string>()));
        Assert.Equal(AiRequest.SystemPrompt, messages[0]!["content"]!.GetValue<string>());
        Assert.EndsWith("[\"We go now.\"]", User(fake, 0));
    }

    /// <summary>LM Studio adresi ve isteğe bağlı anahtar (yalnız doluysa Bearer olarak gider).</summary>
    [Fact]
    public async Task LocalRequestWithKeyAndLmStudio()
    {
        var fake = new FakeAi();
        await MakeLocal(fake, LocalAiServer.LmStudioUrl, "qwen2.5-7b-instruct", " lm-key ").TranslateAsync("Run!");
        var (request, body) = fake.Requests[0];
        Assert.Equal("http://localhost:1234/v1/chat/completions", request.RequestUri!.AbsoluteUri);
        Assert.Equal("Bearer lm-key", Assert.Single(request.Headers.GetValues("Authorization")));
        Assert.Equal("qwen2.5-7b-instruct", JsonNode.Parse(body)!["model"]!.GetValue<string>());
    }

    /// <summary>Kullanıcının yazdığı adres düzeltilir: şema, "/v1", sondaki "/" ve yapıştırılmış "/chat/completions".</summary>
    [Theory]
    [InlineData("http://localhost:11434/v1", "http://localhost:11434/v1")]
    [InlineData("  http://localhost:11434/v1/  ", "http://localhost:11434/v1")]
    [InlineData("localhost:11434", "http://localhost:11434/v1")]
    [InlineData("http://127.0.0.1:1234", "http://127.0.0.1:1234/v1")]
    [InlineData("http://localhost:1234/v1/chat/completions", "http://localhost:1234/v1")]
    [InlineData("https://ai.example.com/openai/v1", "https://ai.example.com/openai/v1")]
    [InlineData("", null)]
    [InlineData("ftp://localhost:11434", null)]
    [InlineData("http://", null)]
    [InlineData("local host", null)]
    public void LocalServerAddress(string text, string? expected) =>
        Assert.Equal(expected, LocalAiServer.Normalize(text)?.AbsoluteUri);

    [Fact]
    public void LocalServerDetails()
    {
        Assert.Null(LocalAiServer.Create(LocalAiServer.OllamaUrl, "  "));
        var server = LocalAiServer.Create("localhost:11434", " qwen2.5:7b ")!;
        Assert.Equal("qwen2.5:7b", server.Model);
        Assert.Equal("http://localhost:11434", server.Address);
        Assert.Equal(LocalAiServerKind.Ollama, server.Kind);
        Assert.Equal(LocalAiServerKind.LmStudio, LocalAiServer.Create(LocalAiServer.LmStudioUrl, "m")!.Kind);
        Assert.Equal(LocalAiServerKind.Other, LocalAiServer.Create("http://192.168.1.20:8080/v1", "m")!.Kind);
        // Yazılan model adı listeye bakılmadan kullanılır; boşsa varsayılan.
        Assert.Equal("llama3.1:8b", AiProvider.Local.Model("llama3.1:8b").Id);
        Assert.Equal("qwen2.5:7b", AiProvider.Local.Model(" ").Id);
        Assert.Null(RequestBudget.Shared(AiProvider.Local, AiProvider.Local.DefaultModel()));
    }

    /// <summary>Önbellekteki motor adında sunucu ve model vardır; farklı yerel modellerin çevirileri karışmaz (Mac ile aynı ad).</summary>
    [Fact]
    public void LocalEngineIdIncludesServerAndModel()
    {
        var ollama = LocalAiServer.Create(LocalAiServer.OllamaUrl, "qwen2.5:7b")!;
        Assert.Equal("local:localhost:11434/qwen2.5:7b", ollama.EngineId);
        Assert.Equal(ollama.EngineId, LocalAiServer.Create("http://LOCALHOST:11434/v1/", "qwen2.5:7b")!.EngineId);
        Assert.NotEqual(ollama.EngineId, LocalAiServer.Create(LocalAiServer.OllamaUrl, "qwen2.5:14b")!.EngineId);
        Assert.NotEqual(ollama.EngineId, LocalAiServer.Create(LocalAiServer.LmStudioUrl, "qwen2.5:7b")!.EngineId);
        Assert.NotEqual(ollama.EngineId, LocalAiServer.Create("http://192.168.1.20:11434/v1", "qwen2.5:7b")!.EngineId);
        // Bulut hizmetlerinin adları değişmez.
        Assert.DoesNotContain(ollama.EngineId, AiProviders.Cloud.Select(p => p.EngineId(p.DefaultModel().Id)));
    }

    /// <summary>Düşünen yerel modeller yanıtın başına &lt;think&gt;…&lt;/think&gt; koyar; yalnız sonrası okunur.</summary>
    [Fact]
    public async Task LocalThinkingIsSkipped()
    {
        var fake = new FakeAi((request, _) => Wrap(request, "<think>\nThe user wants [\"x\"] translated…\n</think>\n\n[\"Koş!\"]"));
        Assert.Equal("Koş!", await MakeLocal(fake).TranslateAsync("Run!"));
        Assert.Equal(["Gidelim."], AiRequest.Translations("<think>…</think>Gidelim.", 1));
    }

    /// <summary>Sunucu kapalıysa ya da model indirilmemişse o satır ücretsiz çeviriyle gelir, durum bildirilir.</summary>
    [Fact]
    public async Task LocalFailuresFallBack()
    {
        var down = MakeLocal(new FakeAi((_, _) => throw new HttpRequestException("Connection refused")));
        Assert.Equal("yerel: Run!", await down.TranslateAsync("Run!"));
        Assert.Equal(OnlineKeyState.Unreachable, down.LastError);

        // Ollama'nın indirilmemiş model yanıtı.
        var missing = MakeLocal(new FakeAi((_, _) => Json("""{"error":{"message":"model \"qwen2.5:7b\" not found, try pulling it first","type":"api_error"}}""", HttpStatusCode.NotFound)));
        Assert.Equal("yerel: Run!", await missing.TranslateAsync("Run!"));
        Assert.Equal(OnlineKeyState.ModelRejected, missing.LastError);
    }

    /// <summary>"Bağlantıyı dene": anahtarsız çalışır; sunucunun hatası olduğu gibi döner.</summary>
    [Fact]
    public async Task LocalTestWorksWithoutKey()
    {
        var fake = new FakeAi();
        var server = LocalAiServer.Create(LocalAiServer.OllamaUrl, "qwen2.5:7b");
        var result = await AiTranslator.TestAsync(AiProvider.Local, "", "qwen2.5:7b", new HttpClient(fake), server: server);
        Assert.Equal(new AiTestResult(OnlineKeyState.Valid, "KRATOS: [tr] We go now. [tr] Stay close, boy."), result);
        Assert.Null(fake.Requests[0].Request.Headers.Authorization);

        var down = new FakeAi((_, _) => throw new TaskCanceledException("timeout"));
        Assert.Equal(OnlineKeyState.Unreachable,
                     (await AiTranslator.TestAsync(AiProvider.Local, "", "qwen2.5:7b", new HttpClient(down), server: server)).State);
    }

    /// <summary>Yerel modelde buluttan uzun beklenir; deneme modeli belleğe yükleyeceği için daha da uzun.</summary>
    [Fact]
    public void LocalTimeouts()
    {
        Assert.Equal(AiTranslator.Timeout, AiTranslator.ClientFor(AiProvider.Gemini).Timeout);
        Assert.Equal(AiTranslator.LocalTimeout, AiTranslator.ClientFor(AiProvider.Local).Timeout);
        Assert.True(AiTranslator.LocalTimeout > AiTranslator.Timeout);
        Assert.True(AiTranslator.LocalTestTimeout > AiTranslator.LocalTimeout);
    }

    /// <summary>Son gösterilen 3 satır ve çevirileri bağlam olarak gider; satırın kendisi ve tekrar okunan satır girmez.</summary>
    [Fact]
    public async Task ContextIsTheLastThreeShownLinesWithTranslations()
    {
        var fake = new FakeAi();
        var translator = Make(AiProvider.Claude, fake);
        foreach (var line in new[] { "One.", "Two.", "Two.", "Three.", "Four.", "Five." }) await translator.TranslateAsync(line);
        Assert.Equal(5, fake.Requests.Count);
        Assert.DoesNotContain("Previous subtitles", User(fake, 0));
        Assert.Contains("English: One.\nTurkish: [tr] One.", User(fake, 1));
        Assert.Contains("English: Two.\nTurkish: [tr] Two.\nEnglish: Three.\nTurkish: [tr] Three.\nEnglish: Four.\nTurkish: [tr] Four.", User(fake, 4));
        Assert.DoesNotContain("English: One.", User(fake, 4));
        Assert.DoesNotContain("English: Five.", User(fake, 4));
    }

    [Fact]
    public async Task SeveralSentencesGoAsOneArray()
    {
        var fake = new FakeAi();
        var translator = Make(AiProvider.Gemini, fake);
        const string line = "We go now. Stay close.\nATREUS: Yes, father.";
        Assert.Equal("[tr] We go now. [tr] Stay close.\nATREUS: [tr] Yes, father.", await translator.TranslateAsync(line));
        Assert.Single(fake.Requests);
        Assert.EndsWith("[\"We go now.\",\"Stay close.\",\"Yes, father.\"]", User(fake, 0));
        Assert.Equal("ATREUS", translator.SpokenLines(line)[^1].Speaker);
    }

    // --- Yanıt ---

    [Fact]
    public void ReplyParsing()
    {
        Assert.Equal(["Gidelim.", "Yakın dur."], AiRequest.Translations("```json\n[\"Gidelim.\", \"Yakın dur.\"]\n```", 2));
        Assert.Equal(["Gidelim."], AiRequest.Translations("“Gidelim.”", 1));
        Assert.Throws<AiException>(() => AiRequest.Translations("[\"Tek\"]", 2));
        Assert.Throws<AiException>(() => AiRequest.Translations("Gidelim. Yakın dur.", 2));
        Assert.Throws<AiException>(() => AiRequest.Text(AiProvider.Gemini, """{"promptFeedback":{"blockReason":"OTHER"}}"""));
        Assert.Equal("Koş!", AiRequest.Text(AiProvider.OpenAi, """{"choices":[{"message":{"content":"Koş!"}}]}"""));
    }

    [Fact]
    public async Task PlainTextReplyForOneSentence()
    {
        var fake = new FakeAi((request, _) => Wrap(request, "Koş!"));
        Assert.Equal("Koş!", await Make(AiProvider.OpenAi, fake).TranslateAsync("Run!"));
    }

    [Fact]
    public void FailureMapping()
    {
        Assert.Equal(OnlineKeyState.Invalid, AiRequest.Failure(HttpStatusCode.Unauthorized, ""));
        Assert.Equal(OnlineKeyState.Invalid, AiRequest.Failure(HttpStatusCode.Forbidden, ""));
        Assert.Equal(OnlineKeyState.Invalid, AiRequest.Failure(HttpStatusCode.BadRequest,
            """{"error":{"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"reason":"API_KEY_INVALID"}]}}"""));
        Assert.Equal(OnlineKeyState.QuotaExceeded, AiRequest.Failure(HttpStatusCode.TooManyRequests, """{"error":{"code":"insufficient_quota"}}"""));
        Assert.Equal(OnlineKeyState.QuotaExceeded, AiRequest.Failure(HttpStatusCode.BadRequest,
            """{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low"}}"""));
        Assert.Equal(OnlineKeyState.ModelRejected, AiRequest.Failure(HttpStatusCode.NotFound, ""));
        Assert.Equal(OnlineKeyState.ModelRejected, AiRequest.Failure(HttpStatusCode.BadRequest, "unknown model"));
        Assert.Equal(OnlineKeyState.Unreachable, AiRequest.Failure((HttpStatusCode)529, ""));
        Assert.Equal(OnlineKeyState.Unreachable, AiRequest.Failure(HttpStatusCode.InternalServerError, ""));
    }

    // --- Hata ve yerel çeviri ---

    /// <summary>Kota biterse o satır yerel modelle çevrilir, bir süre hizmet denenmez, hata durumu bildirilir.</summary>
    [Fact]
    public async Task FallsBackAndPausesOnError()
    {
        var fake = new FakeAi((_, _) => Json("""{"error":{"message":"quota"}}""", HttpStatusCode.TooManyRequests));
        var local = new FakeLocal();
        var cache = new TranslationCache();
        var translator = Make(AiProvider.Gemini, fake, local, cache);
        var reported = new List<OnlineKeyState?>();
        translator.FailureChanged += reported.Add;
        Assert.Equal("yerel: Run!", await translator.TranslateAsync("Run!"));
        Assert.Equal("yerel: Hide!", await translator.TranslateAsync("Hide!"));
        Assert.Single(fake.Requests);
        Assert.Equal(["Run!", "Hide!"], local.Calls);
        Assert.Equal(OnlineKeyState.QuotaExceeded, translator.LastError);
        Assert.Equal([OnlineKeyState.QuotaExceeded], reported);
        // Yerel çeviri bu motorun önbelleğine yazılmaz.
        Assert.False(cache.TryGet("Run!", out _));
    }

    [Fact]
    public async Task TimeoutFallsBack()
    {
        var fake = new FakeAi((_, _) => throw new TaskCanceledException("timeout"));
        var translator = Make(AiProvider.Claude, fake);
        Assert.Equal("yerel: Run!", await translator.TranslateAsync("Run!"));
        Assert.Equal(OnlineKeyState.Unreachable, translator.LastError);
    }

    // --- Ücretsiz katman ---

    /// <summary>Varsayılan Gemini modeli ücretsiz anahtarla çalışır ve dakikalık hakkı vardır; ücretli hizmetlerde hak yoktur.</summary>
    [Fact]
    public void DefaultGeminiModelIsFreeTier()
    {
        var model = AiProvider.Gemini.DefaultModel();
        Assert.True(model.FreeTier);
        Assert.NotNull(model.RequestsPerMinute);
        Assert.All(AiProvider.Gemini.Models(), m => Assert.True(m.FreeTier && m.RequestsPerMinute > 0));
        Assert.True(AiProvider.Gemini.HasFreeTier());
        Assert.False(AiProvider.OpenAi.HasFreeTier());
        Assert.False(AiProvider.Claude.HasFreeTier());
        Assert.Null(RequestBudget.Shared(AiProvider.Claude, AiProvider.Claude.DefaultModel()));
        var shared = RequestBudget.Shared(AiProvider.Gemini, model);
        Assert.Equal(model.RequestsPerMinute, shared?.PerMinute);
        // Hat yeniden kurulsa da aynı hak kullanılır.
        Assert.Same(shared, RequestBudget.Shared(AiProvider.Gemini, model));
        // Eski listede yeni alanlar olmayabilir.
        var old = AiModel.Parse("""{"gemini":[{"id":"g","label":"L"}]}""")["gemini"][0];
        Assert.Equal(new AiModel("g", "L"), old);
        Assert.False(old.FreeTier);
    }

    /// <summary>Kayan bir dakikalık pencere: hak bitince istek verilmez, en eski istek pencereden çıkınca yeniden verilir.</summary>
    [Fact]
    public void RequestBudgetSlidingWindow()
    {
        var time = new DateTimeOffset(2026, 11, 11, 12, 0, 0, TimeSpan.Zero);
        var budget = new RequestBudget(3, () => time);
        Assert.True(budget.TryTake());
        time += TimeSpan.FromSeconds(20);
        Assert.True(budget.TryTake());
        Assert.True(budget.TryTake());
        Assert.False(budget.TryTake());
        time += TimeSpan.FromSeconds(39);
        Assert.False(budget.TryTake());
        time += TimeSpan.FromSeconds(1); // ilk istek 60 sn önceydi
        Assert.True(budget.TryTake());
        Assert.False(budget.TryTake());
        budget.Lower(1);
        Assert.Equal(1, budget.PerMinute);
        budget.Lower(50); // yükseltmez
        Assert.Equal(1, budget.PerMinute);
        budget.Lower(0);
        Assert.Equal(1, budget.PerMinute);
    }

    /// <summary>Hak bitince istek gönderilmez, satır yerel çeviriyle gelir; hata bildirilmez, önbellekteki satır yine gelir.</summary>
    [Fact]
    public async Task OverBudgetFallsBackSilently()
    {
        var fake = new FakeAi();
        var translator = Make(AiProvider.Gemini, fake, budget: new RequestBudget(1));
        var reported = new List<OnlineKeyState?>();
        translator.FailureChanged += reported.Add;
        Assert.Equal("[tr] Run!", await translator.TranslateAsync("Run!"));
        Assert.False(translator.LastLineWasRateLimited);
        Assert.Equal("yerel: Hide!", await translator.TranslateAsync("Hide!"));
        Assert.True(translator.LastLineWasRateLimited);
        Assert.Single(fake.Requests);
        Assert.Null(translator.LastError);
        Assert.Empty(reported);
        // Önbellekteki satır hak harcamadan gelir.
        Assert.Equal("[tr] Run!", await translator.TranslateAsync("Run!"));
        Assert.Single(fake.Requests);
    }

    /// <summary>Bir altyazının bütün cümleleri tek istekle gider; hak cümle başına değil istek başına sayılır.</summary>
    [Fact]
    public async Task WholeSubtitleUsesOneRequestOfTheBudget()
    {
        var fake = new FakeAi();
        var translator = Make(AiProvider.Gemini, fake, budget: new RequestBudget(1));
        Assert.Equal("[tr] We go now. [tr] Stay close. [tr] Run!", await translator.TranslateAsync("We go now. Stay close. Run!"));
        Assert.Single(fake.Requests);
    }

    /// <summary>Dakikalık 429: uyarı çıkmaz, kısa beklenir, bildirilen daha düşük sınıra inilir.</summary>
    [Fact]
    public async Task PerMinuteRateLimitIsSilentAndLowersTheBudget()
    {
        var fake = new FakeAi((_, _) => Json(RateLimitBody(PerMinute), HttpStatusCode.TooManyRequests));
        var budget = new RequestBudget(15);
        var translator = Make(AiProvider.Gemini, fake, budget: budget);
        var reported = new List<OnlineKeyState?>();
        translator.FailureChanged += reported.Add;
        Assert.Equal("yerel: Run!", await translator.TranslateAsync("Run!"));
        Assert.Equal("yerel: Hide!", await translator.TranslateAsync("Hide!"));
        Assert.Single(fake.Requests);
        Assert.Null(translator.LastError);
        Assert.Empty(reported);
        Assert.True(translator.LastLineWasRateLimited);
        Assert.Equal(5, budget.PerMinute);
    }

    /// <summary>Günlük sınır dolunca kullanıcıya söylenir (dakikalık beklemeyle geçmez).</summary>
    [Fact]
    public async Task PerDayLimitIsReported()
    {
        var fake = new FakeAi((_, _) => Json(RateLimitBody("GenerateRequestsPerDayPerProjectPerModel-FreeTier", "1000"), HttpStatusCode.TooManyRequests));
        var translator = Make(AiProvider.Gemini, fake);
        var reported = new List<OnlineKeyState?>();
        translator.FailureChanged += reported.Add;
        await translator.TranslateAsync("Run!");
        Assert.Equal([OnlineKeyState.QuotaExceeded], reported);
    }

    [Fact]
    public void RateLimitParsing()
    {
        Assert.Equal(new AiRateLimit(TimeSpan.FromSeconds(37.5), 10),
                     AiRequest.RateLimit(HttpStatusCode.TooManyRequests, RateLimitBody(PerMinute, "10", "37.5s")));
        // Token sınırı da dakikalıktır ama istek sınırını bildirmez.
        Assert.Equal(new AiRateLimit(TimeSpan.FromSeconds(3), null),
                     AiRequest.RateLimit(HttpStatusCode.TooManyRequests, RateLimitBody("GenerateContentInputTokensPerModelPerMinute-FreeTier", "250000")));
        Assert.Null(AiRequest.RateLimit(HttpStatusCode.TooManyRequests, RateLimitBody("GenerateRequestsPerDayPerProjectPerModel-FreeTier")));
        Assert.Null(AiRequest.RateLimit(HttpStatusCode.TooManyRequests, """{"error":{"message":"quota"}}"""));
        Assert.Null(AiRequest.RateLimit(HttpStatusCode.BadRequest, RateLimitBody(PerMinute)));
        Assert.Null(AiRequest.RateLimit(HttpStatusCode.TooManyRequests, ""));
        // Ayrıntısız 429 eskisi gibi kota hatasıdır.
        Assert.Equal(OnlineKeyState.QuotaExceeded, AiRequest.Failure(HttpStatusCode.TooManyRequests, ""));
    }

    /// <summary>"Kaydet ve dene" dakikalık sınıra takılırsa anahtar geçerlidir ama sınırdadır (kaydedilir).</summary>
    [Fact]
    public async Task TestReportsRateLimitAsQuota()
    {
        var fake = new FakeAi((_, _) => Json(RateLimitBody(PerMinute), HttpStatusCode.TooManyRequests));
        var result = await AiTranslator.TestAsync(AiProvider.Gemini, Secret, null, new HttpClient(fake));
        Assert.Equal(OnlineKeyState.QuotaExceeded, result.State);
    }

    // --- Önbellek ---

    /// <summary>Önceki oturumda çevrilen satır ve cümleler hizmete hiç gitmez; yalnız yeni cümle gönderilir.</summary>
    [Fact]
    public async Task PersistentCacheAcrossSessions()
    {
        var file = Path.Combine(Path.GetTempPath(), "couchsubs-ai-" + Guid.NewGuid().ToString("N"), "cache.jsonl");
        try
        {
            await Make(AiProvider.OpenAi, new FakeAi(), cache: new TranslationCache(file)).TranslateAsync("KRATOS: We go now. Stay close.");

            var fake = new FakeAi();
            var translator = Make(AiProvider.OpenAi, fake, cache: new TranslationCache(file));
            Assert.Equal("KRATOS: [tr] We go now. [tr] Stay close.", await translator.TranslateAsync("KRATOS: We go now. Stay close."));
            Assert.Empty(fake.Requests);
            Assert.Equal("[tr] Stay close. [tr] Run!", await translator.TranslateAsync("Stay close. Run!"));
            Assert.Single(fake.Requests);
            Assert.EndsWith("[\"Run!\"]", User(fake, 0));
        }
        finally
        {
            Directory.Delete(Path.GetDirectoryName(file)!, recursive: true);
        }
    }

    // --- Deneme ve anahtarın gizliliği ---

    [Fact]
    public async Task TestTranslatesTheSample()
    {
        var result = await AiTranslator.TestAsync(AiProvider.Gemini, Secret, null, new HttpClient(new FakeAi()));
        Assert.Equal(new AiTestResult(OnlineKeyState.Valid, "KRATOS: [tr] We go now. [tr] Stay close, boy."), result);
    }

    /// <summary>Anahtar hiçbir hata metninde ya da durumda görünmez.</summary>
    [Fact]
    public async Task KeyNeverAppearsInErrors()
    {
        var rejecting = new FakeAi((_, _) => Json($$$"""{"error":{"message":"Incorrect API key provided: {{{Secret}}}"}}""",HttpStatusCode.Unauthorized));
        foreach (var provider in Enum.GetValues<AiProvider>())
        {
            var result = await AiTranslator.TestAsync(provider, Secret, null, new HttpClient(rejecting));
            Assert.Equal(new AiTestResult(OnlineKeyState.Invalid), result);
            Assert.DoesNotContain(Secret, result.ToString());
        }
        Assert.DoesNotContain(Secret, new AiException(OnlineKeyState.Invalid).ToString());

        var timeout = new FakeAi((_, _) => throw new TaskCanceledException("timeout"));
        Assert.Equal(OnlineKeyState.Unreachable, (await AiTranslator.TestAsync(AiProvider.OpenAi, Secret, null, new HttpClient(timeout))).State);
        Assert.Equal(OnlineKeyState.Invalid, (await AiTranslator.TestAsync(AiProvider.Claude, "  ", null)).State);
    }
}
