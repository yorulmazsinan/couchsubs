// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using Anthropic;
using Anthropic.Exceptions;
using Anthropic.Models.Messages;
using CouchSubs.Core;

namespace CouchSubs.Linux;

/// <summary>
/// İsteğe bağlı çevrimiçi çeviri: kullanıcının kendi Claude API anahtarıyla, Claude Haiku. Yerel modelden hem daha
/// doğal çevirir hem de yazı tanımanın küçük hatalarını ("**:", "| think") bağlamdan düzeltir. Son birkaç satır bağlam
/// olarak gider ("o"nun kim olduğunu bilir). Yanıt gecikirse ya da Claude'a ulaşılamazsa o satır cihaz üstü modelle
/// çevrilir; oyun hiç altyazısız kalmaz.
/// </summary>
internal sealed class ClaudeTranslator : ITextTranslator, IDisposable
{
    internal const string Model = "claude-haiku-5-5";
    /// <summary>Anahtarlar bu önekle başlar; panelde aynı alana DeepL anahtarı da girilebilir.</summary>
    internal const string KeyPrefix = "sk-ant-";
    private const int CacheLimit = 4096;
    private const int ContextLines = 3;
    /// <summary>Altyazı bundan geç gelirse anlamını yitirir; yerel model devralır.</summary>
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(3);
    /// <summary>Hata sonrası bu süre Claude denenmez; her satırda zaman aşımını beklemeyelim.</summary>
    private static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(30);

    internal const string Instructions = """
        You translate English video game subtitles into Turkish for display on a TV while the game is played.
        Reply with the Turkish translation of the line only: no quotes, notes, or alternatives.
        - Keep a leading speaker label such as "Peter:" or "Spider-Man:" exactly as written and untranslated.
        - The text comes from OCR. Silently fix obvious OCR errors: drop stray symbols such as "**" or "*«" after a
          speaker name, read "|" as "I", and repair split or merged words.
        - Keep names of characters, places, brands, and apps unchanged.
        - Characters talk casually: use "sen", not "siz", and natural spoken Turkish rather than word-for-word phrasing.
        - Keep the translation about as short as the original; viewers read it in a few seconds.
        - Game UI messages are translated the same way.
        - If the line is unreadable noise, reply with it unchanged.
        Earlier lines are context only; never translate or repeat them.
        """;

    private readonly AnthropicClient client;
    private readonly ITextTranslator? fallback;
    private readonly ConcurrentDictionary<string, string> cache = new(StringComparer.Ordinal);
    private readonly Queue<string> recent = new();
    private readonly object gate = new();
    private DateTimeOffset pausedUntil = DateTimeOffset.MinValue;

    public ClaudeTranslator(string key, ITextTranslator? fallback)
    {
        // Yeniden deneme yok: geç gelen altyazı işe yaramaz, hatada yerel model hemen devralır.
        client = new AnthropicClient { ApiKey = key.Trim(), MaxRetries = 0, Timeout = Timeout };
        this.fallback = fallback;
    }

    public static bool IsClaudeKey(string key) => key.Trim().StartsWith(KeyPrefix, StringComparison.Ordinal);

    public bool Prefetches => true;

    /// <summary>Aynı anda en çok bu kadar önceden çeviri; gürültülü okumalar istek yağmuruna dönmesin.</summary>
    private const int MaxPending = 3;
    private readonly ConcurrentDictionary<string, Task<Result>> pending = new(StringComparer.Ordinal);

    /// <summary>Çevirinin sonucu: metin ya da yerel modele düşme sebebi.</summary>
    private readonly record struct Result(string? Text, string? FailReason);

    public void Prefetch(string text)
    {
        if (cache.ContainsKey(text) || pending.ContainsKey(text) || pending.Count >= MaxPending || DateTimeOffset.UtcNow < pausedUntil) return;
        Start(text);
    }

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (cache.TryGetValue(text, out var cached)) return Remember(text, cached);
        if (DateTimeOffset.UtcNow < pausedUntil && !pending.ContainsKey(text)) return await FallbackAsync(text, "duraklatıldı", cancellationToken);

        var request = pending.TryGetValue(text, out var early) ? early : Start(text);
        var result = await request.WaitAsync(cancellationToken);
        return result.Text is { } translated ? Remember(text, translated) : await FallbackAsync(text, result.FailReason!, cancellationToken);
    }

    /// <summary>Gösterilen satır sonraki satırların bağlamı olur (önceden çevrilip gösterilmeyen okumalar olmaz).</summary>
    private string Remember(string text, string translated)
    {
        lock (gate)
        {
            if (!recent.Contains(text)) recent.Enqueue(text);
            while (recent.Count > ContextLines) recent.Dequeue();
        }
        return translated;
    }

    private Task<Result> Start(string text)
    {
        string context;
        lock (gate) context = string.Join('\n', recent);
        var request = RequestAsync(text, context);
        pending[text] = request;
        _ = request.ContinueWith(_ => pending.TryRemove(text, out var _), TaskScheduler.Default);
        return request;
    }

    private async Task<Result> RequestAsync(string text, string context)
    {
        var started = Environment.TickCount64;
        try
        {
            using var timeout = new CancellationTokenSource(Timeout);
            var response = await client.Messages.Create(Request(text, context), timeout.Token);
            if (response.StopReason == "refusal") return new(null, "Claude reddetti");
            var translated = string.Concat(response.Content.Select(block => block.Value).OfType<TextBlock>().Select(block => block.Text)).Trim();
            if (translated.Length == 0) return new(null, "boş yanıt");

            Log.Write("çeviri", $"Claude {Environment.TickCount64 - started} ms");
            if (cache.Count >= CacheLimit) cache.Clear();
            cache[text] = translated;
            return new(translated, null);
        }
        catch (Exception error) when (error is AnthropicApiException or AnthropicIOException or HttpRequestException or OperationCanceledException)
        {
            // Anahtar geçersizse ya da kota bittiyse her satırda denemeyelim; ağ hatasında da kısa bir ara verelim.
            pausedUntil = DateTimeOffset.UtcNow + RetryAfter;
            return new(null, error switch
            {
                AnthropicUnauthorizedException or AnthropicForbiddenException => "anahtar geçersiz",
                AnthropicRateLimitException => "kota/hız sınırı",
                OperationCanceledException => $"{Timeout.TotalSeconds:0} sn içinde yanıt yok",
                _ => error.GetType().Name,
            });
        }
    }

    internal static MessageCreateParams Request(string text, string context) => new()
    {
        Model = Model,
        // Tek bir altyazı satırının çevirisi; düşünme kapalı ve düşük çaba gecikmeyi en aza indirir.
        MaxTokens = 300,
        Thinking = new ThinkingConfigDisabled(),
        OutputConfig = new OutputConfig { Effort = Effort.Low },
        System = Instructions,
        Messages =
        [
            new UserMessageParam
            {
                Content = context.Length == 0 ? $"<line>{text}</line>" : $"<earlier>\n{context}\n</earlier>\n<line>{text}</line>",
            },
        ],
    };

    private async Task<string> FallbackAsync(string text, string reason, CancellationToken cancellationToken)
    {
        Log.Write("çeviri", $"Claude kullanılamadı ({reason}); yerel model çeviriyor");
        return fallback is null ? throw new TranslatorException(TranslatorStatus.NeedsDownload)
            : await fallback.TranslateAsync(text, cancellationToken);
    }

    /// <summary>Paneldeki anahtar denemesi: modeli sorgular (ücretsiz), çeviri yapmaz.</summary>
    public static async Task<OnlineKeyCheck> CheckAsync(string key)
    {
        try
        {
            using var check = new AnthropicClient { ApiKey = key.Trim(), MaxRetries = 0, Timeout = TimeSpan.FromSeconds(8) };
            await check.Models.Retrieve(Model);
            return new(OnlineKeyState.Valid);
        }
        catch (Exception error) when (error is AnthropicUnauthorizedException or AnthropicForbiddenException)
        {
            return new(OnlineKeyState.Invalid);
        }
        catch (AnthropicRateLimitException)
        {
            return new(OnlineKeyState.QuotaExceeded);
        }
        catch (Exception error) when (error is AnthropicApiException or AnthropicIOException or HttpRequestException or OperationCanceledException)
        {
            return new(OnlineKeyState.Unreachable);
        }
    }

    public void Dispose() => client.Dispose();
}
