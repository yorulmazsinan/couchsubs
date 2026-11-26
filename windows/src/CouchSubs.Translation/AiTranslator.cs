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
    /// <summary>"Ekranı çevir"in tek isteğinde çıktı sınırı: ekrandaki bütün yazılar birlikte döner.</summary>
    public const int ScreenOutputTokens = 8192;

    public const string SystemPrompt =
        "You translate English video game subtitles into natural, spoken Turkish, the way people really talk. " +
        "Characters address each other informally (use \"sen\", not \"siz\") unless the line is clearly formal. " +
        "Keep character names, place names and speaker labels such as \"ATREUS:\" exactly as they are. " +
        "Keep line breaks. Keep the meaning and tone; do not add or leave out anything. " +
        // #296: OCR kaçan/yanlış harfler ve önceki altyazının devamı olan satırlar.
        "The text is read from the screen by OCR and may have misread or missing letters (\"Y u ave to ask?\", " +
        "\"Doesn't 00k good.\"); translate the line the speaker clearly meant. " +
        "A subtitle may continue the previous one (it starts in lowercase or with a word like \"and\"); " +
        "translate it so that it reads as that continuation. " +
        // #827: menü ve görev etiketi kısa, tekil emir kipi ("Para Kazan", "Para Kazanın" değil).
        "Short menu items, objectives and button labels without a subject (\"Make Money\", \"Find Donnie's Package\") " +
        "are commands to the player: translate them as short singular informal imperatives (\"Para Kazan\", " +
        "\"Donnie'nin Paketini Bul\"), never polite or plural forms such as \"Para Kazanın\". " +
        "Reply with only the translation, no explanations, notes or quotes.";

    /// <summary>Kullanıcının ek talimatında en çok bu kadar karakter gider (fazlası kesilir).</summary>
    public const int MaxInstructionLength = 1000;

    /// <summary>Ayarlardaki "Ek talimat": baştaki/sondaki boşluk atılır, sınırdan uzunsa kesilir; boşsa null.</summary>
    public static string? Instruction(string? text)
    {
        var trimmed = text?.Trim() ?? "";
        if (trimmed.Length > MaxInstructionLength) trimmed = trimmed[..MaxInstructionLength].TrimEnd();
        return trimmed.Length == 0 ? null : trimmed;
    }

    /// <summary>
    /// Sistem talimatı: kullanıcının ek talimatı varsa sona eklenir (#306; ör. küfrü yumuşatmadan çevir). Boşsa
    /// <see cref="SystemPrompt"/> olduğu gibi gider.
    /// </summary>
    public static string SystemPromptWith(string? instruction) =>
        Instruction(instruction) is { } extra ? SystemPrompt + "\n\n" + extra : SystemPrompt;

    /// <summary>
    /// Ek talimatın önbellek etiketi: talimat değişince eski çeviriler dönmesin diye anahtarın başına girer. Talimat
    /// yoksa null; o zaman anahtar eskisi gibidir ve önceki çeviriler geçerli kalır (Mac ve telefonla aynı).
    /// </summary>
    public static string? InstructionTag(string? instruction) => Instruction(instruction) is { } extra
        ? Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(extra)))[..16].ToLowerInvariant()
        : null;

    private static readonly JsonSerializerOptions Compact = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>
    /// Kullanıcı iletisi: önceki satırlar (yalnız bağlam) ve çevrilecek cümleler. <paramref name="names"/>: konuşan
    /// etiketlerinden öğrenilip cümlelerde geçen adlar; model "Price"ı "Fiyat" diye çevirmesin diye adıyla söylenir (#287).
    /// </summary>
    /// <summary>
    /// Ekran çevirisinde her yazının en çok karakter sayısı: özgün uzunluğun %15 fazlası (en az 4); çeviri özgün yazının
    /// yerine, aynı boyda sığsın diye kısa söyleyiş istenir (Mac ve Android ile aynı).
    /// </summary>
    public static IReadOnlyList<int> ScreenLimits(IReadOnlyList<string> sentences) =>
        [.. sentences.Select(s => Math.Max(4, (int)Math.Ceiling(s.Length * 1.15)))];

    /// <summary>
    /// Ekran çevirisinin günlüğe yazılacak sorunu (<see cref="DropLog"/>): boş döndü, aslıyla aynı döndü (İngilizce kaldı)
    /// ya da <see cref="ScreenLimits"/> sınırını aştı. Sorun yoksa null. Mac/iPhone (AIRequest.screenIssue) ve Android
    /// (AiRequest.screenIssue) aynı.
    /// </summary>
    public static string? ScreenIssue(string source, string translation, int limit)
    {
        var trimmed = translation.Trim();
        if (trimmed.Length == 0) return "motor boş çeviri döndü";
        if (string.Equals(trimmed, source.Trim(), StringComparison.CurrentCultureIgnoreCase) && source.Any(char.IsLetter))
            return "çeviri aslıyla aynı döndü, İngilizce kaldı";
        if (trimmed.Length > limit) return $"%115 sınırını aştı ({trimmed.Length}/{limit})";
        return null;
    }

    /// <summary>Karakter sınırlarının istemdeki açıklaması (küfür kuralı: sansür ve yumuşatma yok).</summary>
    public const string LimitsNote = "On-screen texts (menus, objectives, labels): each Turkish translation must fit in the place of the English text. Use at most the number of characters given for it in this JSON array, in the same order; choose shorter Turkish wording, but keep the meaning and never censor or soften profanity.";

    public static string UserMessage(IReadOnlyList<string> sentences, IReadOnlyList<AiContextLine> context, string? game = null,
                                     IReadOnlyList<string>? names = null, IReadOnlyList<int>? limits = null)
    {
        var parts = new List<string>();
        if (!string.IsNullOrEmpty(game)) parts.Add($"Game: {game}");
        if (names is { Count: > 0 })
            parts.Add($"Character names (keep them exactly as written, do not translate them): {string.Join(", ", names)}");
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
        if (limits is not null && limits.Count == sentences.Count)
            parts.Add(LimitsNote + "\n[" + string.Join(",", limits) + "]");
        var list = new JsonArray([.. sentences.Select(s => (JsonNode?)JsonValue.Create(s))]).ToJsonString(Compact);
        parts.Add($"Translate each string in this JSON array into Turkish. Reply with only a JSON array of {sentences.Count} " +
                  $"Turkish strings in the same order.\n{list}");
        return string.Join("\n\n", parts);
    }

    /// <summary>Yerel modelin sıcaklığı: 0, aynı satır her seferinde aynı çevrilir (#306).</summary>
    public const double LocalTemperature = 0;

    /// <summary>
    /// Ollama modeli son istekten sonra bu kadar bellekte tutar (varsayılan 5 dk). Oyunda uzun süre altyazı çıkmayınca
    /// model bellekten atılıyor, ilk satır modelin diskten yeniden yüklenmesini bekliyordu (#306).
    /// </summary>
    public const string OllamaKeepAlive = "24h";

    /// <summary>
    /// Hizmete giden HTTP isteği. <paramref name="server"/>: yerel modelin sunucusu (verilmezse Ollama'nın varsayılan adresi).
    /// <paramref name="thinkingOff"/>: Ollama'da düşünmeyi kapatan alanlar gitsin mi (bu alanları reddeden eski sürümde false).
    /// <paramref name="instruction"/>: Ayarlardaki "Ek talimat"; sistem talimatının sonuna eklenir, boşsa hiçbir şey değişmez.
    /// </summary>
    public static HttpRequestMessage Build(AiProvider provider, string key, AiModel model, IReadOnlyList<string> sentences,
                                           IReadOnlyList<AiContextLine> context, string? game = null, LocalAiServer? server = null,
                                           int maxOutputTokens = MaxOutputTokens, bool thinkingOff = true,
                                           IReadOnlyList<string>? names = null, string? instruction = null,
                                           IReadOnlyList<int>? limits = null)
    {
        key = key.Trim();
        var user = UserMessage(sentences, context, game, names, limits);
        var system = SystemPromptWith(instruction);
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
                    ["systemInstruction"] = new JsonObject { ["parts"] = new JsonArray(new JsonObject { ["text"] = system }) },
                    ["contents"] = new JsonArray(new JsonObject
                    {
                        ["role"] = "user",
                        ["parts"] = new JsonArray(new JsonObject { ["text"] = user }),
                    }),
                    ["generationConfig"] = new JsonObject { ["maxOutputTokens"] = maxOutputTokens },
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
                        new JsonObject { ["role"] = "developer", ["content"] = system },
                        new JsonObject { ["role"] = "user", ["content"] = user }),
                    ["max_completion_tokens"] = maxOutputTokens,
                };
                if (model.Effort is { } effort) body["reasoning_effort"] = effort;
                break;
            case AiProvider.DeepSeek:
                // https://api-docs.deepseek.com/api/create-chat-completion (OpenAI uyumlu): POST /chat/completions,
                // "Authorization: Bearer", "system" rolü ve "max_tokens". Düşünme varsayılan olarak açıktır; altyazı için
                // hız önemli olduğundan listedeki modelle kapatılır ("thinking": {"type": "disabled"}).
                request = new HttpRequestMessage(HttpMethod.Post, "https://api.deepseek.com/chat/completions");
                request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {key}");
                body = new JsonObject
                {
                    ["model"] = model.Id,
                    ["messages"] = new JsonArray(
                        new JsonObject { ["role"] = "system", ["content"] = system },
                        new JsonObject { ["role"] = "user", ["content"] = user }),
                    ["max_tokens"] = maxOutputTokens,
                    ["stream"] = false,
                };
                if (model.Thinking is { } deepSeekThinking) body["thinking"] = new JsonObject { ["type"] = deepSeekThinking };
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
                        new JsonObject { ["role"] = "system", ["content"] = system },
                        new JsonObject { ["role"] = "user", ["content"] = user }),
                    ["temperature"] = LocalTemperature,
                    ["max_tokens"] = maxOutputTokens,
                    ["stream"] = false,
                };
                // Ollama'da düşünme kapalı (#295): yerel API "think": false okur, OpenAI uyumlu adres ise
                // reasoning_effort "none" (github.com/ollama/ollama openai/openai.go). Eski sürüm 400 verirse çevirmen
                // alanlarsız yeniden dener ve bunu oturum boyunca hatırlar.
                if (thinkingOff && local.DisablesThinking)
                {
                    body["think"] = false;
                    body["reasoning_effort"] = "none";
                }
                // Ollama'nın OpenAI uyumlu adresi keep_alive'ı okur ("Ollama extension", github.com/ollama/ollama
                // openai/openai.go ChatCompletionRequest.KeepAlive); bu alanı bilmeyen eski sürüm bilinmeyen alanı yok
                // sayar. Yalnız Ollama'ya gider: LM Studio ve başka sunucular bu alanı tanımaz (#306).
                if (local.Kind == LocalAiServerKind.Ollama) body["keep_alive"] = OllamaKeepAlive;
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
                    ["max_tokens"] = maxOutputTokens,
                    ["system"] = system,
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
                case AiProvider.OpenAi or AiProvider.DeepSeek or AiProvider.Local:
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
        trimmed = StripControlTokens(trimmed);
        // ```json … ``` çitini at.
        if (trimmed.StartsWith("```", StringComparison.Ordinal))
            trimmed = string.Join("\n", trimmed.Split('\n').Skip(1).Where(l => !l.StartsWith("```", StringComparison.Ordinal))).Trim();
        int start = trimmed.IndexOf('['), end = trimmed.LastIndexOf(']');
        if (start >= 0 && end > start)
        {
            try
            {
                if (JsonNode.Parse(WithoutTrailingComma(trimmed[start..(end + 1)])) is JsonArray array && array.All(n => n?.GetValueKind() == JsonValueKind.String))
                {
                    if (array.Count != count) throw new AiException(OnlineKeyState.Unreachable);
                    return [.. array.Select(n => n!.GetValue<string>().Trim())];
                }
            }
            catch (JsonException) { /* dizi değil; düz metin olabilir */ }
        }
        if (UnquotedList(trimmed, count) is { } list) return list;
        if (count != 1) throw new AiException(OnlineKeyState.Unreachable);
        return [trimmed.Trim('"', '“', '”')];
    }

    /// <summary>
    /// Yerel modellerin metne sızan bitiş/rol işaretleri (<c>&lt;/s&gt;</c>, <c>&lt;|im_end|&gt;</c>, <c>&lt;|eot_id|&gt;</c>,
    /// <c>&lt;end_of_turn&gt;</c> …) ekranda görünmesin; yalnız bu kalıplar silinir, altyazıdaki başka yazılara dokunulmaz.
    /// </summary>
    internal static string StripControlTokens(string text) =>
        System.Text.RegularExpressions.Regex.Replace(text,
            @"</?s>|<\|[A-Za-z0-9_]{1,32}\|>|</?(?:start|end)_of_turn>|</?(?:eos|bos|pad)>", "").Trim();

    /// <summary><c>["Bir.", "İki.",]</c> gibi sondaki fazla virgül JSON'u bozmasın.</summary>
    internal static string WithoutTrailingComma(string text) =>
        System.Text.RegularExpressions.Regex.Replace(text, @",\s*\]$", "]");

    /// <summary>
    /// Tırnaksız dizi: bazı yerel modeller JSON istense de <c>[Hareket etmemiz lazım.]</c> ya da
    /// <c>[Satır bir., Satır iki.]</c> döndürür. Yalnız bütün yanıt köşeli parantez içindeyse ve öğe sayısı tam tutuyorsa
    /// alınır; tutmazsa null (hat her zamanki geri dönüşe gider). Cümle içi virgülde yanlış bölmemek için sıra: satır sonu,
    /// cümle sonu işaretinden (. ! ? … ") sonra gelen virgül, en son düz virgül.
    /// </summary>
    internal static string[]? UnquotedList(string text, int count)
    {
        if (count < 1 || text.Length < 2 || !text.StartsWith('[') || !text.EndsWith(']')) return null;
        var inner = text[1..^1];
        IEnumerable<string[]> candidates = count == 1 ? [[inner]] :
        [
            [.. inner.Split('\n').Where(line => line.Trim().Length > 0)],
            SentenceSplit(inner),
            inner.Split(','),
        ];
        foreach (var parts in candidates)
        {
            var items = parts.Select(CleanItem).ToArray();
            if (items.Length == count && items.All(item => item.Length > 0)) return items;
        }
        return null;
    }

    private static string CleanItem(string item)
    {
        var value = item.Trim();
        if (value.EndsWith(',')) value = value[..^1];
        return value.Trim().Trim('"', '“', '”').Trim();
    }

    /// <summary>Cümle sonu işaretinden (. ! ? … " ”) hemen sonra gelen virgüllerden böler; işaret öğede kalır.</summary>
    private static string[] SentenceSplit(string text)
    {
        var parts = new List<string>();
        var start = 0;
        var last = '\0';
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c == ',' && last is '.' or '!' or '?' or '…' or '"' or '”')
            {
                parts.Add(text[start..i]);
                start = i + 1;
            }
            if (!char.IsWhiteSpace(c)) last = c;
        }
        parts.Add(text[start..]);
        return [.. parts];
    }

    /// <summary>Başarısız HTTP yanıtının anlamı. Gövde yalnız tanınan hata kodları için okunur, hiçbir yere yazılmaz.</summary>
    private static bool IsTemporaryProviderRateLimit(string body)
    {
        JsonObject? error;
        try { error = JsonNode.Parse(body)?["error"] as JsonObject; }
        catch (JsonException) { return false; }
        if (error is null) return false;

        string? Field(string name)
        {
            var value = error[name];
            return value?.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;
        }

        var code = Field("code")?.ToLowerInvariant();
        var details = error["details"] as JsonObject;
        var detailCode = details?["error_code"] is JsonValue detailValue && detailValue.GetValueKind() == JsonValueKind.String
            ? detailValue.GetValue<string>().ToLowerInvariant()
            : null;
        var type = Field("type")?.ToLowerInvariant();
        if (code is "insufficient_quota" or "billing_hard_limit_reached" or "credit_balance_exhausted" or "organization_spend_limit_exceeded"
            or "project_spend_limit_exceeded" or "organization_usage_limit_exceeded" or "enforced_spend_limit_reached"
            || detailCode is "insufficient_quota" or "billing_hard_limit_reached" or "credit_balance_exhausted" or "organization_spend_limit_exceeded"
                or "project_spend_limit_exceeded" or "organization_usage_limit_exceeded" or "enforced_spend_limit_reached") return false;
        // DeepSeek 429'u "rate_limit_reached" türüyle döner; bakiye bitmesi 402'dir (api-docs.deepseek.com/quick_start/error_codes).
        return type == "rate_limit_error" || type?.Contains("rate_limit") == true
            || code is "slow_down" or "rate_limit_exceeded" || code?.Contains("rate_limit") == true;
    }

    public static OnlineKeyState Failure(HttpStatusCode status, string body)
    {
        var message = body.ToLowerInvariant();
        return (int)status switch
        {
            401 or 403 => OnlineKeyState.Invalid,
            429 when IsTemporaryProviderRateLimit(body) => OnlineKeyState.Busy,
            402 or 429 => OnlineKeyState.QuotaExceeded,
            400 when message.Contains("api_key_invalid") || message.Contains("api key not valid") => OnlineKeyState.Invalid,
            400 when message.Contains("credit balance") || message.Contains("insufficient_quota") => OnlineKeyState.QuotaExceeded,
            400 or 404 or 422 => OnlineKeyState.ModelRejected,
            // Hizmete ulaşıldı ama şu an yoğun ya da arızalı (Gemini 503 "overloaded", Claude 529); internet çalışıyor.
            408 or (>= 500 and <= 599) => OnlineKeyState.Busy,
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
        if (IsTemporaryProviderRateLimit(body)) return new AiRateLimit();
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
    /// <summary>Hata sonrası bu süre hizmet denenmez (bulut hizmetlerinin kotası için).</summary>
    private static readonly TimeSpan RetryAfter = TimeSpan.FromMinutes(1);
    /// <summary>
    /// Yerel modelde hata sonrası bekleme. Kota yoktur, sunucu çoğunlukla hemen düzelir (zaman aşımı, bozuk JSON, an
    /// meşgul): tek bir hata bir dakika boyunca bütün satırları yedek çeviriye düşürmesin, yalnız birkaç satırı etkilesin.
    /// Askıda kalan sunucuda da bekleme sürer: her satır <see cref="LocalTimeout"/> kadar beklemez, sıra dolmaz.
    /// </summary>
    internal static readonly TimeSpan LocalRetryAfter = TimeSpan.FromSeconds(5);
    /// <summary>Hata sonrası hizmetin denenmediği süre: yerel modelde <see cref="LocalRetryAfter"/>, bulutta bir dakika (testler kısaltır).</summary>
    internal TimeSpan ErrorPause { get; init; }
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
    /// <summary>
    /// Ayarlardaki "Kaydet ve dene"de bulut hizmeti için beklenen en uzun süre: deneme tek istektir, ilk bağlantı
    /// altyazıdaki 5 saniyeyi aşabilir; yine de sınırlıdır, düğme takılı kalmaz (Mac ile aynı, 15 sn).
    /// </summary>
    public static readonly TimeSpan CloudKeyTestTimeout = TimeSpan.FromSeconds(15);
    private static readonly Lazy<HttpClient> CloudTestClient = new(() => new HttpClient { Timeout = CloudKeyTestTimeout });

    /// <summary>Hizmete uygun zaman aşımıyla paylaşılan istemci.</summary>
    public static HttpClient ClientFor(AiProvider provider) => provider.IsLocal() ? LocalClient.Value : SharedClient.Value;

    /// <summary>"Ekranı çevir"de bulut hizmetinde beklenen en uzun süre: bütün ekranın çevirisi tek yanıtta gelir.</summary>
    public static readonly TimeSpan ScreenTimeout = TimeSpan.FromSeconds(30);
    /// <summary>Bir istekte giden en çok parça; kalabalık ekran birkaç isteğe bölünür.</summary>
    public const int ScreenBatch = 40;
    private static readonly Lazy<HttpClient> ScreenClient = new(() => new HttpClient { Timeout = ScreenTimeout });

    private readonly string _key;
    private readonly ITextTranslator? _fallback;
    private readonly HttpClient _http;
    /// <summary>"Ekranı çevir"in uzun yanıtlı tek isteği için daha uzun bekleyen istemci.</summary>
    private readonly HttpClient _screenHttp;
    private readonly TranslationCache _cache;
    /// <summary>Ekran çevirisinin boş, aslıyla aynı ya da sınırı aşan yanıtı altyazı günlüğüne (<see cref="DropLog"/>).</summary>
    private readonly DropLog _drops = new();
    private readonly RequestBudget? _budget;
    private readonly ConcurrentDictionary<string, IReadOnlyList<SpokenLine>> _speech = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> _names = new(StringComparer.Ordinal);
    private readonly SpeakerNameGuard _speakers = new();
    private readonly List<AiContextLine> _recent = [];
    private string? _recentGame;
    private readonly Func<string?>? _game;
    /// <summary>Ayarlardaki "Ek talimat" (sınırlanmış); yoksa null.</summary>
    private readonly string? _instruction;
    /// <summary>Ek talimatın önbellek etiketi; talimat yoksa null (anahtar eskisi gibi).</summary>
    private readonly string? _instructionTag;
    private DateTimeOffset _pausedUntil = DateTimeOffset.MinValue;
    /// <summary>Bekleme hizmetin 429 yanıtından mı (dakikalık sınır); öyleyse yerel yedek olmasa da istek gönderilmez.</summary>
    private bool _pauseRateLimited;
    private OnlineKeyState? _failure;

    /// <param name="model">Kayıtlı model kimliği; listede yoksa varsayılan model.</param>
    /// <param name="cache">Kalıcı önbellek; verilmezse yalnız bellekte tutulur.</param>
    /// <param name="budget">
    /// Dakikalık istek hakkı; null ise modelin uygulama genelindeki ortak hakkı (Google sınırı proje ve model başına sayar;
    /// çeviri hattı yeniden kurulsa da hak sıfırlanmaz). Modelin sınırı yoksa hak da yoktur.
    /// </param>
    /// <param name="server">Yerel modelin sunucusu (yalnız <see cref="AiProvider.Local"/>; verilmezse Ollama'nın varsayılan adresi).</param>
    /// <param name="http">Verilmezse hizmete uygun zaman aşımıyla paylaşılan istemci (yerel model daha uzun bekler).</param>
    /// <param name="game">
    /// Oynanan oyunun adı (ör. eşleşen oyun paketinin başlığı); her istekte sorulur, null ya da boşsa istemde oyun satırı olmaz.
    /// </param>
    /// <param name="instruction">Ayarlardaki "Ek talimat": sistem talimatının sonuna eklenir; boşsa hiçbir şey değişmez.</param>
    public AiTranslator(AiProvider provider, string key, string? model, ITextTranslator? fallback, HttpClient? http = null,
                        TranslationCache? cache = null, RequestBudget? budget = null, LocalAiServer? server = null,
                        Func<string?>? game = null, string? instruction = null, bool paidTier = false)
    {
        _game = game;
        _instruction = AiRequest.Instruction(instruction);
        _instructionTag = AiRequest.InstructionTag(_instruction);
        Provider = provider;
        ErrorPause = provider.IsLocal() ? LocalRetryAfter : RetryAfter;
        Model = provider.Model(model);
        Server = provider.IsLocal() ? server ?? LocalAiServer.Create(LocalAiServer.OllamaUrl, Model.Id) : null;
        _key = key.Trim();
        _fallback = fallback;
        _http = http ?? ClientFor(provider);
        _screenHttp = http ?? (provider.IsLocal() ? LocalTestClient.Value : ScreenClient.Value);
        _cache = cache ?? new TranslationCache();
        _budget = budget ?? RequestBudget.Shared(provider, Model, _key, paidTier);
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

    // Oyun bilinmiyorsa eski kayıtlar geçerlidir; biliniyorsa yalnız o oyunun sonucu kullanılır. Ek talimat varsa
    // anahtar onun etiketiyle başlar: talimat değişince eski çeviriler dönmez, talimat yoksa anahtar eskisi gibidir.
    private string CacheKey(string text, string? game)
    {
        var key = string.IsNullOrEmpty(game) ? text : game + "\u001f" + text;
        return _instructionTag is null ? key : "i:" + _instructionTag + "\u001f" + key;
    }

    /// <summary>Konuşan adını öğrenir ("OLD MAN" → "old", "man"); korunacak adlar ayrıca (#287).</summary>
    public void NoteSpeaker(string name)
    {
        foreach (var word in name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length >= 2))
            _names[word.ToLowerInvariant()] = 0;
        _speakers.Learn(name);
        _fallback?.NoteSpeaker(name);
    }

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        // Arama, HTTP isteği ve kayıt aynı oyunla yapılmalı; callback işlem sırasında değişebilir.
        var game = _game?.Invoke()?.Trim();
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        var context = ContextBeforeShowing(text, game);
        if (_cache.TryGet(CacheKey(text, game), out var cached)) return Remember(cached, text, game);

        var pieces = SubtitleSegmenter.Split(text);
        foreach (var name in pieces.Select(SubtitleSegmenter.LabelName).OfType<string>()) NoteSpeaker(name);
        var names = _names.Keys.ToHashSet(StringComparer.Ordinal);
        // Önbellekte duran cümleler yeniden gönderilmez.
        var translations = pieces.Select(p => p.Translate && _cache.TryGet(CacheKey(p.Text, game), out var known) ? known : null).ToList();
        var missing = Enumerable.Range(0, pieces.Count).Where(i => pieces[i].Translate && translations[i] is null).ToList();
        var sources = missing.Select(i => SubtitleSegmenter.NormalizeCase(pieces[i].Text, names)).ToList();
        // Hizmetin beklemesi yalnız eksik çeviriler içindir; önbellekteki parçalar yerel motor istemez. Hata sonrası
        // beklemede yerel çeviri yoksa (inmemiş, açılamadı) satır düşmesin: hizmet yine denenir. 429 beklemesi kalır.
        if (sources.Count > 0 && DateTimeOffset.UtcNow < _pausedUntil)
        {
            if (_pauseRateLimited)
            {
                NoteFallback("dakikalık hizmet sınırı");
                return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text, game);
            }
            if (await TryFallbackAsync(text, cancellationToken).ConfigureAwait(false) is { } offline)
            {
                NoteFallback($"yeniden deneme beklemesi ({_failure?.ToString() ?? "bekleme"})");
                return Remember(offline, text, game);
            }
        }
        // Dakikalık hak bittiyse satır sessizce yerel çeviriyle çevrilir (hata değildir). Hak uygulamanın temkinli
        // tahminidir; yerel çeviri yoksa satır denenmeden düşmesin, istek yine gönderilir.
        LastLineWasRateLimited = sources.Count > 0 && _budget is { } budget && !budget.TryTake();
        if (LastLineWasRateLimited)
        {
            if (await TryFallbackAsync(text, cancellationToken).ConfigureAwait(false) is { } offline)
            {
                NoteFallback("uygulama dakikalık sınırı");
                return Remember(offline, text, game);
            }
            LastLineWasRateLimited = false;
        }

        string[] translated;
        try
        {
            var present = SpeakerNameGuard.Occurring(_speakers.Protected, string.Join("\n", sources), exact: true);
            translated = sources.Count == 0 ? [] : await RequestAsync(sources, context, game, present, cancellationToken).ConfigureAwait(false);
            if (sources.Count > 0) Report(null);
        }
        catch (AiRateLimitedException limited) when (!cancellationToken.IsCancellationRequested)
        {
            // Dakikalık sınır: kısa beklenir, ana ekranda uyarı çıkmaz; hizmet daha düşük sınır bildirdiyse ona inilir.
            if (limited.Limit.RequestsPerMinute is { } perMinute) _budget?.Lower(perMinute);
            var pause = limited.Limit.RetryAfter is { } retry && retry < RateLimitPause ? retry : RateLimitPause;
            if (pause < TimeSpan.FromSeconds(1)) pause = TimeSpan.FromSeconds(1);
            LastLineWasRateLimited = true;
            _pausedUntil = DateTimeOffset.UtcNow + pause;
            _pauseRateLimited = true;
            NoteFallback("dakikalık hizmet sınırı");
            return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text, game);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or AiException
                                      && !cancellationToken.IsCancellationRequested)
        {
            var state = StateOf(error);
            Report(state);
            _pausedUntil = DateTimeOffset.UtcNow + ErrorPause;
            _pauseRateLimited = false;
            NoteFallback($"hizmet durumu: {state}");
            return Remember(await FallbackAsync(text, cancellationToken).ConfigureAwait(false), text, game);
        }
        var local = false;
        for (var i = 0; i < missing.Count; i++)
        {
            var piece = pieces[missing[i]].Text;
            // Model dizide bu cümleyi boş bıraktıysa (bozuk OCR okumasında olabiliyor, #296) yanıt yok sayılır.
            var empty = string.IsNullOrWhiteSpace(translated[i]);
            if ((empty || IsEcho(piece, translated[i])) && await TryFallbackAsync(piece, cancellationToken).ConfigureAwait(false) is { } retried
                && !string.IsNullOrWhiteSpace(retried) && !IsEcho(piece, retried))
            {
                // Yerel çeviri bu motorun önbelleğine yazılmaz.
                NoteFallback("boş veya değişmemiş yanıt");
                translations[missing[i]] = retried;
                local = true;
                continue;
            }
            if (empty)
            {
                // Yerel çeviri de yoksa cümle olduğu gibi kalır; boş satır gösterilmez, sonuç önbelleğe yazılmaz.
                local = true;
                continue;
            }
            translations[missing[i]] = translated[i];
            _cache.Store(CacheKey(piece, game), translated[i]);
        }

        var builder = new StringBuilder();
        for (var i = 0; i < pieces.Count; i++) builder.Append(translations[i] ?? pieces[i].Text);
        if (_speech.Count >= 512) _speech.Clear();
        _speech[CacheKey(text, game)] = SpeechScript.Lines(pieces, translations);
        var result = builder.ToString();
        if (!local) _cache.Store(CacheKey(text, game), result);
        return Remember(result, text, game);
    }

    /// <summary>
    /// Model cümleyi çevirmeden geri verdi mi (hattın "zaten hedef dilde" eşiğiyle aynı). Küçük yerel modeller İngilizce
    /// cümleyi sık sık olduğu gibi döndürüyor ("You think I'm on the run?"); hat bunu Türkçe sanıp hiç göstermiyor,
    /// önbellek de öyle saklıyordu (#245).
    /// </summary>
    internal static bool IsEcho(string source, string translation) =>
        TextMatch.IsSimilar(TextMatch.Normalize(source), TextMatch.Normalize(translation), 0.90);

    /// <summary>
    /// Cümle cihaz üstü çeviriyle denenir; yerel çeviri yoksa ya da hata verirse null. Geri verilen cümlede o da aynı
    /// kalırsa (ad, konsolun Türkçe menüsü) çevrilecek bir şey yoktur ve modelin yanıtı önbelleğe yazılır; hizmet
    /// beklerken null dönerse istek yine gönderilir.
    /// </summary>
    /// <summary>Satırın ücretsiz yedeğe düşme nedeni altyazı günlüğüne gider (Mac'teki <c>noteFallback</c> ile aynı).</summary>
    private void NoteFallback(string reason) =>
        TranslationProbe.Current?.NoteFallback($"{Provider.ToString().ToLowerInvariant()} {reason}");

    private async Task<string?> TryFallbackAsync(string text, CancellationToken cancellationToken)
    {
        if (_fallback is null) return null;
        try { return await _fallback.TranslateAsync(text, cancellationToken).ConfigureAwait(false); }
        catch (Exception error) when (error is not OperationCanceledException) { return null; }
    }

    public bool TranslatesTogether => true;

    /// <summary>Önbellekteki çevirisi (<see cref="TranslateAllAsync"/> ile aynı anahtar: oynanan oyunla); istek göndermez.</summary>
    public string? CachedTranslation(string text) =>
        _cache.TryGet(CacheKey(text, _game?.Invoke()?.Trim()), out var known) ? known : null;

    /// <summary>
    /// "Ekranı çevir": birbirinden bağımsız parçalar (menü satırı, görev yazısı...) tek istekte, aynı sırada çevrilir.
    /// Parça başına istek gitseydi kalabalık bir ekran Gemini'nin dakikalık hakkını (15) ilk saniyelerde bitirir, kalan
    /// parçalar yerel çeviriye düşerdi; yerel model kurulu değilse ekranın hiçbir yazısı çevrilmezdi. Bu tek istek
    /// kullanıcının tuşa basmasıyla gider: ortak hak o an bitmiş olsa da gönderilir (hakkı sayılır). Hata ya da dakikalık
    /// sınırda parçalar yerel çeviriyle çevrilir; o da yoksa hata yukarı çıkar ve ekranda gösterilir (Mac ile aynı).
    /// </summary>
    public async Task<IReadOnlyList<string>> TranslateAllAsync(IReadOnlyList<string> texts, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(texts);
        var game = _game?.Invoke()?.Trim();
        var results = texts.Select(text => _cache.TryGet(CacheKey(text, game), out var known) ? known : null).ToArray();
        var missing = Enumerable.Range(0, texts.Count).Where(i => results[i] is null).ToList();
        var failed = DateTimeOffset.UtcNow < _pausedUntil;
        for (var start = 0; start < missing.Count && !failed; start += ScreenBatch)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var chunk = missing.Skip(start).Take(ScreenBatch).ToList();
            _budget?.TryTake();
            LastLineWasRateLimited = false;
            try
            {
                var sentences = chunk.Select(i => texts[i]).ToList();
                var translated = await PerformAsync(thinkingOff => AiRequest.Build(Provider, _key, Model, sentences, [], game, Server,
                    maxOutputTokens: AiRequest.ScreenOutputTokens, thinkingOff: thinkingOff, instruction: _instruction,
                    limits: AiRequest.ScreenLimits(sentences)), _screenHttp, sentences.Count, cancellationToken).ConfigureAwait(false);
                Report(null);
                var limits = AiRequest.ScreenLimits(sentences);
                for (var i = 0; i < chunk.Count; i++)
                {
                    if (AiRequest.ScreenIssue(texts[chunk[i]], translated[i], limits[i]) is { } issue)
                        _drops.Note("translateAll", issue, texts[chunk[i]]);
                    results[chunk[i]] = translated[i];
                    _cache.Store(CacheKey(texts[chunk[i]], game), translated[i]);
                }
            }
            catch (AiRateLimitedException limited) when (!cancellationToken.IsCancellationRequested)
            {
                if (limited.Limit.RequestsPerMinute is { } perMinute) _budget?.Lower(perMinute);
                var pause = limited.Limit.RetryAfter is { } retry && retry < RateLimitPause ? retry : RateLimitPause;
                if (pause < TimeSpan.FromSeconds(1)) pause = TimeSpan.FromSeconds(1);
                LastLineWasRateLimited = true;
                _pausedUntil = DateTimeOffset.UtcNow + pause;
                _pauseRateLimited = true;
                failed = true;
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException or AiException
                                          && !cancellationToken.IsCancellationRequested)
            {
                Report(StateOf(error));
                _pausedUntil = DateTimeOffset.UtcNow + ErrorPause;
                _pauseRateLimited = false;
                failed = true;
            }
        }
        for (var i = 0; i < texts.Count; i++)
        {
            if (results[i] is not null) continue;
            cancellationToken.ThrowIfCancellationRequested();
            results[i] = await FallbackAsync(texts[i], cancellationToken).ConfigureAwait(false);
        }
        return [.. results.Select(result => result ?? "")];
    }

    public IReadOnlyList<SpokenLine> SpokenLines(string text)
    {
        var game = _game?.Invoke()?.Trim();
        return _speech.TryGetValue(CacheKey(text, game), out var lines) ? lines
            : SpeechScript.FromCache(text, _cache, part => CacheKey(part, game)) is { Count: > 0 } cached ? cached
            : _fallback?.SpokenLines(text) ?? [];
    }

    private List<AiContextLine> ContextBeforeShowing(string text, string? game)
    {
        lock (_recent)
        {
            if (!string.Equals(_recentGame, game, StringComparison.Ordinal))
            {
                _recent.Clear();
                _recentGame = game;
            }
            var context = new List<AiContextLine>(_recent);
            // Aynı satır yeniden okunduysa bağlam tekrarla dolmasın.
            if (_recent.Count == 0 || _recent[^1].Source != text)
            {
                _recent.Add(new AiContextLine(text));
                if (_recent.Count > ContextLines) _recent.RemoveAt(0);
            }
            return context;
        }
    }

    /// <summary>Gösterilen satırın çevirisi sonraki satırların bağlamına girer.</summary>
    private string Remember(string translation, string text, string? game)
    {
        lock (_recent)
        {
            if (!string.Equals(_recentGame, game, StringComparison.Ordinal)) return translation;
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

    private Task<string[]> RequestAsync(List<string> sentences, List<AiContextLine> context, string? game,
                                        IReadOnlyList<string> names, CancellationToken cancellationToken) =>
        PerformAsync(thinkingOff => AiRequest.Build(Provider, _key, Model, sentences, context, game, Server, thinkingOff: thinkingOff, names: names,
                                                       instruction: _instruction),
                     _http, sentences.Count, cancellationToken);

    /// <summary>Düşünmeyi kapatan alanları reddeden Ollama sunucuları; uygulama açık kaldıkça hatırlanır.</summary>
    private static readonly ConcurrentDictionary<string, byte> ThinkingRejected = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Testler için: hatırlanan sunucuları unutur.</summary>
    internal static void ResetThinkingRejected() => ThinkingRejected.Clear();

    /// <summary>
    /// İsteği gönderir. Ollama düşünmeyi kapatan alanları 400 ile reddederse (eski sürüm) alanlarsız bir kez yeniden
    /// dener; işe yararsa bu sunucuya oturum boyunca alanlar gönderilmez.
    /// </summary>
    private async Task<string[]> PerformAsync(Func<bool, HttpRequestMessage> build, HttpClient http, int count, CancellationToken cancellationToken)
    {
        var thinkingOff = Server is { DisablesThinking: true } server && !ThinkingRejected.ContainsKey(server.Address);
        if (thinkingOff)
        {
            using var request = build(true);
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.BadRequest) return Read(response, body, count);
        }
        using (var request = build(false))
        {
            using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
            var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            var result = Read(response, body, count);
            if (thinkingOff) ThinkingRejected[Server!.Address] = 0;
            return result;
        }
    }

    /// <summary>
    /// İstek hatasının kullanıcıya gösterilen türü. Zaman aşımı (HttpClient'ın <see cref="TaskCanceledException"/>'ı;
    /// kullanıcının iptali buraya gelmez) yoğunluk sayılır: hizmete ulaşıldı ama yanıt zamanında gelmedi.
    /// </summary>
    internal static OnlineKeyState StateOf(Exception error) => error switch
    {
        AiException ai => ai.State,
        TaskCanceledException => OnlineKeyState.Busy,
        _ => OnlineKeyState.Unreachable,
    };

    private string[] Read(HttpResponseMessage response, string body, int count)
    {
        if (!response.IsSuccessStatusCode)
        {
            if (AiRequest.RateLimit(response.StatusCode, body) is { } limit) throw new AiRateLimitedException(limit);
            throw new AiException(AiRequest.Failure(response.StatusCode, body));
        }
        return AiRequest.Translations(AiRequest.Text(Provider, body), count);
    }

    /// <summary>
    /// Ayarlardaki "Dene" ve "Bağlantıyı dene": örnek satırı çevirir; çeviri ya da hatanın türü döner. Yerel modelde
    /// anahtar isteğe bağlıdır ve model belleğe yüklenirken uzun beklenir.
    /// </summary>
    public static async Task<AiTestResult> TestAsync(AiProvider provider, string key, string? model, HttpClient? http = null,
                                                     CancellationToken cancellationToken = default, LocalAiServer? server = null,
                                                     string? instruction = null)
    {
        key = key.Trim();
        if (key.Length == 0 && !provider.IsLocal()) return new(OnlineKeyState.Invalid);
        http ??= provider.IsLocal() ? LocalTestClient.Value : CloudTestClient.Value;
        // Deneme tek istektir; çeviri hattının dakikalık hakkından yemez.
        var translator = new AiTranslator(provider, key, model, new FailingTranslator(), http, budget: new RequestBudget(int.MaxValue),
                                          server: server, instruction: instruction);
        try
        {
            return new(OnlineKeyState.Valid, await translator.TranslateAsync(Sample, cancellationToken).ConfigureAwait(false));
        }
        catch (FailedException)
        {
            // Dakikalık sınıra takıldıysa anahtar geçerlidir ama şu an sınırdadır.
            return new(translator.LastError ?? (translator.LastLineWasRateLimited ? OnlineKeyState.Busy : OnlineKeyState.Unreachable));
        }
    }

    /// <summary>Denemede yerel çeviriye düşülmez; hata olduğu gibi gösterilir.</summary>
    private sealed class FailingTranslator : ITextTranslator
    {
        public Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default) => throw new FailedException();
    }

    private sealed class FailedException : Exception;
}
