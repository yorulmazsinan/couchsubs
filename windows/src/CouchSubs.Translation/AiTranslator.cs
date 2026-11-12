// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CouchSubs.Core;
using CouchSubs.Core.Dubbing;

namespace CouchSubs.Translation;

/// <summary>Bağlam olarak giden, daha önce gösterilmiş satır ve (biliniyorsa) çevirisi.</summary>
public sealed record AiContextLine(string Source, string? Translation = null);

/// <summary>Yapay zekâ hizmeti çeviremedi; yalnız durum taşır, anahtar ve hizmetin yanıt metni hiçbir yere yazılmaz.</summary>
public sealed class AiException(OnlineKeyState state) : Exception($"AI translation failed: {state}")
{
    public OnlineKeyState State { get; } = state;
}

/// <summary>
/// Üç hizmet için istek kurma ve yanıt okuma (Mac'teki CouchSubsCore/AITranslation.swift ile aynı). Cümleler bir JSON
/// dizisi olarak gider, aynı sırada JSON dizisi beklenir; böylece cümle cümle önbelleğe yazılır ve dublaj konuşmacıyı
/// bilir (DeepL ile aynı düzen).
/// </summary>
public static class AiRequest
{
    /// <summary>Bir altyazı satırına yeten çıktı sınırı; düşünen modellere de pay bırakır.</summary>
    public const int MaxOutputTokens = 1024;

    public const string SystemPrompt =
        "You translate English video game subtitles into natural, spoken Turkish, the way people really talk. " +
        "Characters address each other informally (use \"sen\", not \"siz\") unless the line is clearly formal. " +
        "Keep character names, place names and speaker labels such as \"ATREUS:\" exactly as they are. " +
        "Keep line breaks. Keep the meaning and tone; do not add or leave out anything. " +
        "Reply with only the translation, no explanations, notes or quotes.";

    private static readonly JsonSerializerOptions Compact = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>Kullanıcı iletisi: önceki satırlar (yalnız bağlam) ve çevrilecek cümleler.</summary>
    public static string UserMessage(IReadOnlyList<string> sentences, IReadOnlyList<AiContextLine> context, string? game = null)
    {
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(game)) parts.Add($"Game: {game}");
        if (context.Count > 0)
        {
            var lines = new List<string> { "Previous subtitles, for context only (do not translate them again):" };
            foreach (var line in context)
            {
                lines.Add($"English: {line.Source}");
                if (line.Translation is { } translation) lines.Add($"Turkish: {translation}");
            }
            parts.Add(string.Join("\n", lines));
        }
        var list = new JsonArray([.. sentences.Select(s => (JsonNode?)JsonValue.Create(s))]).ToJsonString(Compact);
        parts.Add($"Translate each string in this JSON array into Turkish. Reply with only a JSON array of {sentences.Count} " +
                  $"Turkish strings in the same order.\n{list}");
        return string.Join("\n\n", parts);
    }

    /// <summary>Yerel modelin sıcaklığı: çeviri tutarlı olsun, yine de doğal kalsın.</summary>
    public const double LocalTemperature = 0.2;

    /// <summary>Hizmete giden HTTP isteği. <paramref name="server"/>: yerel modelin sunucusu (verilmezse Ollama'nın varsayılan adresi).</summary>
    public static HttpRequestMessage Build(AiProvider provider, string key, AiModel model, IReadOnlyList<string> sentences,
                                           IReadOnlyList<AiContextLine> context, string? game = null, LocalAiServer? server = null)
    {
        key = key.Trim();
        var user = UserMessage(sentences, context, game);
        HttpRequestMessage request;
        JsonObject body;
        switch (provider)
        {
            case AiProvider.Gemini:
                // https://ai.google.dev/api/generate-content (aistudio.google.com/api-reference/generate-content):
                // POST /v1beta/models/{model}:generateContent, anahtar "x-goog-api-key" başlığında.
                // Gemini 3.6 Flash ve sonrası temperature'ı yok sayıyor; düşünme düzeyi listedeki modelle gelir.
                request = new HttpRequestMessage(HttpMethod.Post,
                    $"https://generativelanguage.googleapis.com/v1beta/models/{Uri.EscapeDataString(model.Id)}:generateContent");
                request.Headers.Add("x-goog-api-key", key);
                body = new JsonObject
                {
                    ["systemInstruction"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = SystemPrompt }) },
                    ["contents"] = new JsonArray(new JsonObject
                    {
                        ["role"] = "user",
                        ["parts"] = new JsonArray(new JsonObject { ["text"] = user }),
                    }),
                    ["generationConfig"] = new JsonObject { ["maxOutputTokens"] = MaxOutputTokens },
                };
                if (model.Thinking is { } level) body["generationConfig"]!["thinkingConfig"] = new JsonObject { ["thinkingLevel"] = level };
                break;
            case AiProvider.OpenAi:
                // https://platform.openai.com/docs/api-reference/chat/create (developers.openai.com/api/reference):
                // POST /v1/chat/completions, "Authorization: Bearer"; "developer" iletisi yönergedir.
                request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/chat/completions");
                request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {key}");
                body = new JsonObject
                {
                    ["model"] = model.Id,
                    ["messages"] = new JsonArray(
                        new JsonObject { ["role"] = "developer", ["content"] = SystemPrompt },
                        new JsonObject { ["role"] = "user", ["content"] = user }),
                    ["max_completion_tokens"] = MaxOutputTokens,
                };
                if (model.Effort is { } effort) body["reasoning_effort"] = effort;
                break;
            case AiProvider.Local:
                // Ollama ve LM Studio'nun OpenAI uyumlu Chat Completions'ı: POST {adres}/chat/completions. Yalnız iki
                // sunucunun da tanıdığı alanlar gider ("developer" rolü, reasoning_effort, max_completion_tokens gitmez).
                // Anahtar isteğe bağlıdır; boşsa Authorization başlığı hiç eklenmez.
                var local = server ?? LocalAiServer.Create(LocalAiServer.OllamaUrl, model.Id)!;
                request = new HttpRequestMessage(HttpMethod.Post, local.ChatUrl);
                if (key.Length > 0) request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {key}");
                body = new JsonObject
                {
                    ["model"] = model.Id,
                    ["messages"] = new JsonArray(
                        new JsonObject { ["role"] = "system", ["content"] = SystemPrompt },
                        new JsonObject { ["role"] = "user", ["content"] = user }),
                    ["temperature"] = LocalTemperature,
                    ["max_tokens"] = MaxOutputTokens,
                    ["stream"] = false,
                };
                break;
            default:
                // https://docs.anthropic.com/en/api/messages (platform.claude.com/docs/en/api/messages): POST /v1/messages,
                // "x-api-key" ve "anthropic-version". Yeni modellerde temperature gönderilmez; effort ve düşünme listedeki
                // modelle gelir (platform.claude.com/docs/en/build-with-claude/effort).
                request = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
                request.Headers.Add("x-api-key", key);
                request.Headers.Add("anthropic-version", "2023-06-01");
                body = new JsonObject
                {
                    ["model"] = model.Id,
                    ["max_tokens"] = MaxOutputTokens,
                    ["system"] = SystemPrompt,
                    ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = user }),
                };
                if (model.Effort is { } claudeEffort) body["output_config"] = new JsonObject { ["effort"] = claudeEffort };
                if (model.Thinking is { } thinking) body["thinking"] = new JsonObject { ["type"] = thinking };
                break;
        }
        request.Content = new StringContent(body.ToJsonString(Compact), Encoding.UTF8, "application/json");
        return request;
    }

    /// <summary>Yanıttaki düz metin (düşünme bölümleri atlanır).</summary>
    public static string Text(AiProvider provider, string json)
    {
        JsonNode? root;
        try { root = JsonNode.Parse(json); }
        catch (JsonException) { throw new AiException(OnlineKeyState.Unreachable); }
        string? text = null;
        try
        {
            switch (provider)
            {
                case AiProvider.Gemini:
                    // candidates[0].content.parts[].text; "thought": true olan parçalar düşünmedir.
                    var parts = root?["candidates"]?.AsArray().FirstOrDefault()?["content"]?["parts"]?.AsArray();
                    text = parts is null ? null : string.Concat(parts
                        .Where(p => p?["thought"]?.GetValueKind() is not JsonValueKind.True)
                        .Select(p => p?["text"]?.GetValue<string>() ?? ""));
                    break;
                case AiProvider.OpenAi or AiProvider.Local:
                    text = root?["choices"]?.AsArray().FirstOrDefault()?["message"]?["content"]?.GetValue<string>();
                    break;
                default:
                    var blocks = root?["content"]?.AsArray();
                    text = blocks is null ? null : string.Concat(blocks
                        .Where(b => b?["type"]?.GetValue<string>() == "text")
                        .Select(b => b?["text"]?.GetValue<string>() ?? ""));
                    break;
            }
        }
        catch (Exception error) when (error is InvalidOperationException or FormatException)
        {
            throw new AiException(OnlineKeyState.Unreachable);
        }
        if (string.IsNullOrWhiteSpace(text)) throw new AiException(OnlineKeyState.Unreachable);
        return text;
    }

    /// <summary>Yanıttaki JSON dizisi; tek cümlede model diziyi unutup düz metin dönerse o metin alınır.</summary>
    public static string[] Translations(string text, int count)
    {
        var trimmed = text.Trim();
        // Düşünen yerel modeller (ör. Qwen3, DeepSeek-R1) yanıtın başına <think>…</think> koyar; yalnız sonrası alınır.
        var thought = trimmed.LastIndexOf("</think>", StringComparison.Ordinal);
        if (thought >= 0) trimmed = trimmed[(thought + "</think>".Length)..].Trim();
        // ```json … ``` çitini at.
        if (trimmed.StartsWith("```", StringComparison.Ordinal))
            trimmed = string.Join("\n", trimmed.Split('\n').Skip(1).Where(l => !l.StartsWith("```", StringComparison.Ordinal))).Trim();
        int start = trimmed.IndexOf('['), end = trimmed.LastIndexOf(']');
        if (start >= 0 && end > start)
        {
            try
            {
                if (JsonNode.Parse(trimmed[start..(end + 1)]) is JsonArray array && array.All(n => n?.GetValueKind() == JsonValueKind.String))
                {
                    if (array.Count != count) throw new AiException(OnlineKeyState.Unreachable);
                    return [.. array.Select(n => n!.GetValue<string>().Trim())];
                }
            }
            catch (JsonException) { /* dizi değil; düz metin olabilir */ }
        }
        if (count != 1) throw new AiException(OnlineKeyState.Unreachable);
        return [trimmed.Trim('"', '“', '”')];
    }

    /// <summary>Başarısız HTTP yanıtının anlamı. Gövde yalnız tanınan hata kodları için okunur, hiçbir yere yazılmaz.</summary>
    public static OnlineKeyState Failure(HttpStatusCode status, string body)
    {
        var message = body.ToLowerInvariant();
        return (int)status switch
        {
            401 or 403 => OnlineKeyState.Invalid,
            402 or 429 => OnlineKeyState.QuotaExceeded,
            400 when message.Contains("api_key_invalid") || message.Contains("api key not valid") => OnlineKeyState.Invalid,
            400 when message.Contains("credit balance") || message.Contains("insufficient_quota") => OnlineKeyState.QuotaExceeded,
            400 or 404 => OnlineKeyState.ModelRejected,
            _ => OnlineKeyState.Unreachable,
        };
    }

    /// <summary>
    /// 429 yalnız dakikalık sınırdan geldiyse onun ayrıntısı; gün sınırı, bakiye ya da tanınmayan 429 için null (bunlar
    /// <see cref="OnlineKeyState.QuotaExceeded"/> olarak kullanıcıya gösterilir). Gemini'nin hata gövdesinde error.details[]
    /// içinde google.rpc.QuotaFailure (violations[].quotaId, ör. "GenerateRequestsPerMinutePerProjectPerModel-FreeTier",
    /// quotaValue "15") ve google.rpc.RetryInfo (retryDelay "37s") bulunur.
    /// </summary>
    public static AiRateLimit? RateLimit(HttpStatusCode status, string body)
    {
        if ((int)status != 429) return null;
        JsonArray? details;
        try { details = JsonNode.Parse(body)?["error"]?["details"] as JsonArray; }
        catch (JsonException) { return null; }
        if (details is null) return null;
        try
        {
            var violations = details.SelectMany(d => d?["violations"] as IEnumerable<JsonNode?> ?? []).OfType<JsonNode>().ToList();
            var ids = violations.Select(v => v["quotaId"]?.GetValueKind() == JsonValueKind.String ? v["quotaId"]!.GetValue<string>() : null)
                .OfType<string>().ToList();
            // Günlük sınır doldu: dakikalık beklemeyle geçmez, kullanıcı bilmeli.
            if (ids.Any(id => id.Contains("PerDay", StringComparison.Ordinal)) || !ids.Any(id => id.Contains("PerMinute", StringComparison.Ordinal)))
                return null;
            TimeSpan? retry = null;
            var delay = details.Select(d => d?["retryDelay"]).FirstOrDefault(n => n?.GetValueKind() == JsonValueKind.String)?.GetValue<string>();
            if (delay is not null && double.TryParse(delay.TrimEnd('s'), System.Globalization.NumberStyles.Float,
                                                     System.Globalization.CultureInfo.InvariantCulture, out var seconds))
                retry = TimeSpan.FromSeconds(seconds);
            // İstek sınırı (token sınırı değil).
            int? perMinute = null;
            var requests = violations.FirstOrDefault(v => v["quotaId"]?.GetValueKind() == JsonValueKind.String
                                                          && v["quotaId"]!.GetValue<string>().Contains("Requests", StringComparison.Ordinal));
            var value = requests?["quotaValue"];
            if (value?.GetValueKind() == JsonValueKind.String && int.TryParse(value.GetValue<string>(), out var parsed) && parsed > 0) perMinute = parsed;
            else if (value?.GetValueKind() == JsonValueKind.Number && value.GetValue<int>() > 0) perMinute = value.GetValue<int>();
            return new AiRateLimit(retry, perMinute);
        }
        catch (Exception error) when (error is InvalidOperationException or FormatException)
        {
            return null;
        }
    }
}

/// <summary>
/// Hizmetin bildirdiği dakikalık istek sınırı aşımı (429). Gün sınırından farklı olarak kısa sürer; kullanıcıya hata
/// gösterilmez, birkaç saniye o satırlar yerel çeviriyle çevrilir.
/// </summary>
/// <param name="RetryAfter">Hizmetin önerdiği bekleme ("retryDelay"); yoksa null.</param>
/// <param name="RequestsPerMinute">Hizmetin bildirdiği dakikalık istek sınırı ("quotaValue"); yoksa null.</param>
public sealed record AiRateLimit(TimeSpan? RetryAfter = null, int? RequestsPerMinute = null);

/// <summary>Hizmet dakikalık sınırın aşıldığını bildirdi; kullanıcıya hata olarak gösterilmez.</summary>
internal sealed class AiRateLimitedException(AiRateLimit limit) : Exception("AI translation rate limited")
{
    public AiRateLimit Limit { get; } = limit;
}

/// <summary>
/// İsteğe bağlı yapay zekâ çevirisi: kullanıcının kendi Gemini, OpenAI ya da Claude anahtarıyla (Mac'teki
/// AITranslationCore ile aynı). Altyazı cümle cümle, konuşmacı adları çevrilmeden gönderilir; son gösterilen 3 satır ve
/// çevirileri bağlam olarak eklenir. Hizmete ulaşılamazsa, kota biterse ya da zaman aşımı olursa o satır cihaz üstü
/// modelle çevrilir ve bir dakika hizmet denenmez. Yerel çeviriler bu motorun önbelleğine yazılmaz.
/// Bir altyazının çevrilmemiş bütün cümleleri tek istekte gider. Ücretsiz katmanın dakikalık sınırı için model listesindeki
/// <c>requestsPerMinute</c> kadar istek hakkı vardır; hak bitince o satır sessizce (hata göstermeden) yerel çeviriyle çevrilir.
/// </summary>
public sealed class AiTranslator : ITextTranslator, IOnlineTranslator
{
    /// <summary>Bağlama giden önceki satır sayısı.</summary>
    internal const int ContextLines = 3;
    /// <summary>Hata sonrası bu süre hizmet denenmez.</summary>
    private static readonly TimeSpan RetryAfter = TimeSpan.FromMinutes(1);
    /// <summary>Dakikalık sınır aşılınca en çok bu kadar beklenir (hizmet bekleme önermezse de bu kadar).</summary>
    public static readonly TimeSpan RateLimitPause = TimeSpan.FromSeconds(20);
    /// <summary>Denemede çevrilen örnek satır.</summary>
    public const string Sample = "KRATOS: We go now. Stay close, boy.";

    /// <summary>Bulut hizmetinde beklenen en uzun süre.</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);
    /// <summary>
    /// Yerel modelde beklenen en uzun süre: bilgisayardaki model buluttan yavaştır ve bir süre boşta kalınca belleğe
    /// yeniden yüklenir. Yine de sınırlıdır: çeviriler sırayla gider, bir satır bütün sırayı bekletmesin; ekrandan çoktan
    /// kalkmış satırın geç gelen çevirisini hat zaten göstermez.
    /// </summary>
    public static readonly TimeSpan LocalTimeout = TimeSpan.FromSeconds(15);
    /// <summary>"Bağlantıyı dene"de yerel model için beklenen süre: ilk istek modeli belleğe yükler, uzun sürebilir.</summary>
    public static readonly TimeSpan LocalTestTimeout = TimeSpan.FromSeconds(90);

    // Kısa zaman aşımı: altyazı birkaç saniye ekranda kalır, geç gelen çeviri işe yaramaz.
    private static readonly Lazy<HttpClient> SharedClient = new(() => new HttpClient { Timeout = AiTranslator.Timeout });
    private static readonly Lazy<HttpClient> LocalClient = new(() => new HttpClient { Timeout = LocalTimeout });
    private static readonly Lazy<HttpClient> LocalTestClient = new(() => new HttpClient { Timeout = LocalTestTimeout });

    /// <summary>Hizmete uygun zaman aşımıyla paylaşılan istemci.</summary>
    public static HttpClient ClientFor(AiProvider provider) => provider.IsLocal() ? LocalClient.Value : SharedClient.Value;

    private readonly string _key;
    private readonly ITextTranslator? _fallback;
    private readonly HttpClient _http;
    private readonly TranslationCache _cache;
    private readonly RequestBudget? _budget;
    private readonly ConcurrentDictionary<string, IReadOnlyList<SpokenLine>> _speech = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> _names = new(StringComparer.Ordinal);
    private readonly List<AiContextLine> _recent = [];
    private DateTimeOffset _pausedUntil = DateTimeOffset.MinValue;
    private OnlineKeyState? _failure;

    /// <param name="model">Kayıtlı model kimliği; listede yoksa varsayılan model.</param>
    /// <param name="cache">Kalıcı önbellek; verilmezse yalnız bellekte tutulur.</param>
    /// <param name="budget">
    /// Dakikalık istek hakkı; null ise modelin uygulama genelindeki ortak hakkı (Google sınırı proje ve model başına sayar;
    /// çeviri hattı yeniden kurulsa da hak sıfırlanmaz). Modelin sınırı yoksa hak da yoktur.
    /// </param>
    /// <param name="server">Yerel modelin sunucusu (yalnız <see cref="AiProvider.Local"/>; verilmezse Ollama'nın varsayılan adresi).</param>
    /// <param name="http">Verilmezse hizmete uygun zaman aşımıyla paylaşılan istemci (yerel model daha uzun bekler).</param>
    public AiTranslator(AiProvider provider, string key, string? model, ITextTranslator? fallback, HttpClient? http = null,
                        TranslationCache? cache = null, RequestBudget? budget = null, LocalAiServer? server = null)
    {
        Provider = provider;
        Model = provider.Model(model);
        Server = provider.IsLocal() ? server ?? LocalAiServer.Create(LocalAiServer.OllamaUrl, Model.Id) : null;
        _key = key.Trim();
        _fallback = fallback;
        _http = http ?? ClientFor(provider);
        _cache = cache ?? new TranslationCache();
        _budget = budget ?? RequestBudget.Shared(provider, Model);
    }

    public AiProvider Provider { get; }
    public AiModel Model { get; }
    /// <summary>Yerel modelin sunucusu; bulut hizmetlerinde null.</summary>
    public LocalAiServer? Server { get; }

    /// <summary>Son hata; çeviri düzgün gidiyorsa null.</summary>
    public OnlineKeyState? LastError => _failure;

    /// <summary>Son satır dakikalık sınır yüzünden yerel çeviriyle çevrildi (hata sayılmaz, bildirilmez).</summary>
    public bool LastLineWasRateLimited { get; private set; }

    public event Action<OnlineKeyState?>? FailureChanged;

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        var context = Context();
        Shown(text);
        if (_cache.TryGet(text, out var cached)) return Remember(cached, text);
        if (DateTimeOffset.UtcNow < _pausedUntil) return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text);

        var pieces = SubtitleSegmenter.Split(text);
        foreach (var name in pieces.Select(SubtitleSegmenter.LabelName).OfType<string>())
            foreach (var word in name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length >= 2))
                _names[word.ToLowerInvariant()] = 0;
        var names = _names.Keys.ToHashSet(StringComparer.Ordinal);
        // Önbellekte duran cümleler yeniden gönderilmez.
        var translations = pieces.Select(p => p.Translate && _cache.TryGet(p.Text, out var known) ? known : null).ToList();
        var missing = Enumerable.Range(0, pieces.Count).Where(i => pieces[i].Translate && translations[i] is null).ToList();
        var sources = missing.Select(i => SubtitleSegmenter.NormalizeCase(pieces[i].Text, names)).ToList();
        // Dakikalık hak bittiyse istek gönderilmez; satır sessizce yerel çeviriyle çevrilir (hata değildir).
        LastLineWasRateLimited = sources.Count > 0 && _budget is { } budget && !budget.TryTake();
        if (LastLineWasRateLimited) return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text);

        string[] translated;
        try
        {
            translated = sources.Count == 0 ? [] : await RequestAsync(sources, context, cancellationToken).ConfigureAwait(false);
            Report(null);
        }
        catch (AiRateLimitedException limited) when (!cancellationToken.IsCancellationRequested)
        {
            // Dakikalık sınır: kısa beklenir, ana ekranda uyarı çıkmaz; hizmet daha düşük sınır bildirdiyse ona inilir.
            if (limited.Limit.RequestsPerMinute is { } perMinute) _budget?.Lower(perMinute);
            var pause = limited.Limit.RetryAfter is { } retry && retry < RateLimitPause ? retry : RateLimitPause;
            if (pause < TimeSpan.FromSeconds(1)) pause = TimeSpan.FromSeconds(1);
            LastLineWasRateLimited = true;
            _pausedUntil = DateTimeOffset.UtcNow + pause;
            return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or AiException
                                      && !cancellationToken.IsCancellationRequested)
        {
            Report(error is AiException ai ? ai.State : OnlineKeyState.Unreachable);
            _pausedUntil = DateTimeOffset.UtcNow + RetryAfter;
            return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text);
        }
        for (var i = 0; i < missing.Count; i++)
        {
            translations[missing[i]] = translated[i];
            _cache.Store(pieces[missing[i]].Text, translated[i]);
        }

        var builder = new StringBuilder();
        for (var i = 0; i < pieces.Count; i++) builder.Append(translations[i] ?? pieces[i].Text);
        if (_speech.Count >= 512) _speech.Clear();
        _speech[text] = SpeechScript.Lines(pieces, translations);
        var result = builder.ToString();
        _cache.Store(text, result);
        return Remember(result, text);
    }

    public IReadOnlyList<SpokenLine> SpokenLines(string text) =>
        _speech.TryGetValue(text, out var lines) ? lines
        : SpeechScript.FromCache(text, _cache) is { Count: > 0 } cached ? cached
        : _fallback?.SpokenLines(text) ?? [];

    private List<AiContextLine> Context()
    {
        lock (_recent) return [.. _recent];
    }

    private void Shown(string text)
    {
        lock (_recent)
        {
            // Aynı satır yeniden okunduysa bağlam tekrarla dolmasın.
            if (_recent.Count > 0 && _recent[^1].Source == text) return;
            _recent.Add(new AiContextLine(text));
            if (_recent.Count > ContextLines) _recent.RemoveAt(0);
        }
    }

    /// <summary>Gösterilen satırın çevirisi sonraki satırların bağlamına girer.</summary>
    private string Remember(string translation, string text)
    {
        lock (_recent)
        {
            var index = _recent.FindLastIndex(line => line.Source == text);
            if (index >= 0) _recent[index] = _recent[index] with { Translation = translation };
        }
        return translation;
    }

    private void Report(OnlineKeyState? state)
    {
        if (_failure == state) return;
        _failure = state;
        FailureChanged?.Invoke(state);
    }

    private async Task<string> FallbackAsync(string text, CancellationToken cancellationToken) =>
        _fallback is null ? throw new TranslatorException(TranslatorStatus.NeedsDownload)
            : await _fallback.TranslateAsync(text, cancellationToken).ConfigureAwait(false);

    private async Task<string[]> RequestAsync(List<string> sentences, List<AiContextLine> context, CancellationToken cancellationToken)
    {
        using var request = AiRequest.Build(Provider, _key, Model, sentences, context, server: Server);
        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            if (AiRequest.RateLimit(response.StatusCode, body) is { } limit) throw new AiRateLimitedException(limit);
            throw new AiException(AiRequest.Failure(response.StatusCode, body));
        }
        return AiRequest.Translations(AiRequest.Text(Provider, body), sentences.Count);
    }

    /// <summary>
    /// Ayarlardaki "Dene" ve "Bağlantıyı dene": örnek satırı çevirir; çeviri ya da hatanın türü döner. Yerel modelde
    /// anahtar isteğe bağlıdır ve model belleğe yüklenirken uzun beklenir.
    /// </summary>
    public static async Task<AiTestResult> TestAsync(AiProvider provider, string key, string? model, HttpClient? http = null,
                                                     CancellationToken cancellationToken = default, LocalAiServer? server = null)
    {
        key = key.Trim();
        if (key.Length == 0 && !provider.IsLocal()) return new(OnlineKeyState.Invalid);
        http ??= provider.IsLocal() ? LocalTestClient.Value : SharedClient.Value;
        // Deneme tek istektir; çeviri hattının dakikalık hakkından yemez.
        var translator = new AiTranslator(provider, key, model, new FailingTranslator(), http, budget: new RequestBudget(int.MaxValue),
                                          server: server);
        try
        {
            return new(OnlineKeyState.Valid, await translator.TranslateAsync(Sample, cancellationToken).ConfigureAwait(false));
        }
        catch (FailedException)
        {
            // Dakikalık sınıra takıldıysa anahtar geçerlidir ama şu an sınırdadır.
            return new(translator.LastError ?? (translator.LastLineWasRateLimited ? OnlineKeyState.QuotaExceeded : OnlineKeyState.Unreachable));
        }
    }

    /// <summary>Denemede yerel çeviriye düşülmez; hata olduğu gibi gösterilir.</summary>
    private sealed class FailingTranslator : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) => throw new FailedException();
    }

    private sealed class FailedException : Exception;
}
