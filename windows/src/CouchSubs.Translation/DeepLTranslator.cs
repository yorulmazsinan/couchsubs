// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json.Serialization;
using CouchSubs.Core;
using CouchSubs.Core.Dubbing;

namespace CouchSubs.Translation;

/// <summary>
/// İsteğe bağlı çevrimiçi çeviri: kullanıcının kendi DeepL anahtarıyla. Altyazı cümle cümle, konuşmacı adları
/// çevrilmeden gönderilir. Son gösterilen 3 satır bağlam olarak eklenir: DeepL'in <c>context</c> alanı (tek metin)
/// çeviriyi etkiler ama çevrilmez ve ücretlendirilmez ("Characters included in the context parameter will not be
/// counted toward billing", developers.deepl.com/docs/api-reference/translate, Kasım 2026). Önbellekteki çeviri
/// bağlamsız eski haliyle döner; anahtar yalnız satırın kendisidir.
/// DeepL'e ulaşılamazsa ya da kota biterse o satır cihaz üstü modelle çevrilir; oyun hiç altyazısız kalmaz.
/// </summary>
public sealed class DeepLTranslator : ITextTranslator, IOnlineTranslator
{
    /// <summary>Kalıcı önbellek dosyasındaki motor adı.</summary>
    public const string EngineId = "deepl";
    /// <summary>Bağlama giden önceki satır sayısı.</summary>
    internal const int ContextLines = 3;
    /// <summary>Hata sonrası bu süre DeepL denenmez; her satırda bağlantı zaman aşımını beklemeyelim. 1 dk oyunda çok uzundu.</summary>
    private static readonly TimeSpan RetryAfter = TimeSpan.FromSeconds(15);

    /// <summary>
    /// Ortak bağlantı uzun süre açık kalır: boşta kalan bağlantı varsayılan olarak bir dakikada kapanıyor, sessizlikten
    /// sonraki ilk satır yeni TLS el sıkışmasını bekliyordu (~0,3 sn fazladan).
    /// </summary>
    private static readonly Lazy<HttpClient> SharedClient = new(() => new HttpClient(new SocketsHttpHandler
    {
        PooledConnectionIdleTimeout = TimeSpan.FromMinutes(15),
        PooledConnectionLifetime = TimeSpan.FromMinutes(30),
        KeepAlivePingDelay = TimeSpan.FromSeconds(30),
        KeepAlivePingTimeout = TimeSpan.FromSeconds(10),
        KeepAlivePingPolicy = HttpKeepAlivePingPolicy.Always,
    }) { Timeout = TimeSpan.FromSeconds(4) });

    /// <summary>Bağlantıyı sıcak tutan istekler arası süre; sunucu tarafı boşta bağlantıyı genelde 60 sn'de kapatır.</summary>
    internal static readonly TimeSpan KeepWarmEvery = TimeSpan.FromSeconds(40);
    /// <summary>Son çeviriden bu kadar sonra bağlantı sıcak tutulmaz (oyun bitti, uygulama boşta).</summary>
    internal static readonly TimeSpan KeepWarmFor = TimeSpan.FromMinutes(10);
    private static Timer? _warmTimer;
    private static string _warmKey = "";
    private static long _lastUsedTicks;

    /// <summary>
    /// Ortak bağlantıyı sıcak tutar: oturum başında ve son çeviriden sonraki <see cref="KeepWarmFor"/> boyunca her
    /// <see cref="KeepWarmEvery"/>'de bir kullanım sorgusu (<c>/v2/usage</c>; karakter kotasından yemez) gönderir.
    /// Böylece uzun sessizlikten sonraki ilk replik de açık bağlantıdan gider.
    /// </summary>
    private static void KeepWarm(string key)
    {
        Volatile.Write(ref _warmKey, key);
        Interlocked.Exchange(ref _lastUsedTicks, DateTimeOffset.UtcNow.UtcTicks);
        if (_warmTimer is not null) return;
        var timer = new Timer(_ =>
        {
            var idle = DateTimeOffset.UtcNow.UtcTicks - Interlocked.Read(ref _lastUsedTicks);
            if (idle > KeepWarmFor.Ticks || Volatile.Read(ref _warmKey) is not { Length: > 0 } warm) return;
            _ = CheckAsync(warm);
        }, null, TimeSpan.Zero, KeepWarmEvery);
        if (Interlocked.CompareExchange(ref _warmTimer, timer, null) is not null) timer.Dispose();
    }

    private readonly string _key;
    private readonly ITextTranslator? _fallback;
    private readonly HttpClient _http;
    private readonly TranslationCache _cache;
    private readonly ConcurrentDictionary<string, IReadOnlyList<SpokenLine>> _speech = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, byte> _names = new(StringComparer.Ordinal);
    private readonly List<string> _recent = [];
    /// <summary>Çevrilmeyecek adlar ve terimler (ücretsiz çeviriyle aynı sözlük); DeepL'e etiketle korunarak gider.</summary>
    private readonly GlossaryStore _glossary;
    private DateTimeOffset _pausedUntil = DateTimeOffset.MinValue;
    /// <summary>Bekleme DeepL'in 429 yanıtından mı; öyleyse yerel yedek olmasa da istek gönderilmez.</summary>
    private bool _pauseRateLimited;

    /// <param name="cache">Kalıcı önbellek; verilmezse yalnız bellekte tutulur.</param>
    /// <param name="glossary">Verilmezse kullanıcının sözlük klasörü (ücretsiz çeviriyle aynı).</param>
    public DeepLTranslator(string key, ITextTranslator? fallback, HttpClient? http = null, TranslationCache? cache = null,
        GlossaryStore? glossary = null)
    {
        _key = DeepLKey.Clean(key);
        _fallback = fallback;
        _http = http ?? SharedClient.Value;
        _cache = cache ?? new TranslationCache();
        _glossary = glossary ?? new GlossaryStore(GlossaryStore.UserDirectory);
        // Gerçek bağlantıyla (testlerin sahte istemcisi değil) çalışırken oturum başında ısınır, oyun boyunca sıcak kalır.
        if (http is null && _key.Length > 0) KeepWarm(_key);
    }

    /// <summary>Son DeepL hatası; çeviri düzgün gidiyorsa null.</summary>
    public OnlineKeyState? LastError { get; private set; }

    public event Action<OnlineKeyState?>? FailureChanged;

    private void Report(OnlineKeyState? state)
    {
        if (LastError == state) return;
        LastError = state;
        FailureChanged?.Invoke(state);
    }

    /// <summary>Ücretsiz anahtarlar ":fx" ile biter ve ayrı adrese gider.</summary>
    internal static Uri BaseUri(string key) =>
        new(DeepLKey.Clean(key).EndsWith(":fx", StringComparison.Ordinal) ? "https://api-free.deepl.com/v2/" : "https://api.deepl.com/v2/");

    /// <summary>Konuşan adını öğrenir ("OLD MAN" → "old", "man"); yerel yedek de öğrenir, orada cümle içinde korunur (#287).</summary>
    public void NoteSpeaker(string name)
    {
        foreach (var word in name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length >= 2))
            _names[word.ToLowerInvariant()] = 0;
        _fallback?.NoteSpeaker(name);
    }

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        // Bağlam, bu satırdan önce gösterilenlerdir; satırın kendisi bağlama girmez.
        var context = Context();
        Shown(text);
        if (_http == SharedClient.Value && _key.Length > 0) Interlocked.Exchange(ref _lastUsedTicks, DateTimeOffset.UtcNow.UtcTicks);
        var glossary = _glossary.Current;
        if (_cache.TryGet(DeepLMarkup.CacheKey(text, glossary), out var cached)) return cached;
        // Hata sonrası beklemede yerel çeviri yoksa (inmemiş, açılamadı) satır düşmesin: DeepL yine denenir. 429 beklemesi kalır.
        if (DateTimeOffset.UtcNow < _pausedUntil)
        {
            if (_pauseRateLimited) return await FallbackAsync(text, cancellationToken).ConfigureAwait(false);
            if (await TryFallbackAsync(text, cancellationToken).ConfigureAwait(false) is { } local) return local;
        }

        var pieces = SubtitleSegmenter.Split(text);
        foreach (var name in pieces.Select(SubtitleSegmenter.LabelName).OfType<string>()) NoteSpeaker(name);
        var names = _names.Keys.ToHashSet(StringComparer.Ordinal);
        names.UnionWith(glossary.CapitalWords);
        // Önbellekte duran cümleler yeniden gönderilmez; kota yalnız yeni cümlelere gider.
        var translations = pieces.Select(p => p.Translate && _cache.TryGet(DeepLMarkup.CacheKey(p.Text, glossary), out var known) ? known : null).ToList();
        var missing = Enumerable.Range(0, pieces.Count).Where(i => pieces[i].Translate && translations[i] is null).ToList();
        var plain = missing.Select(i => SubtitleSegmenter.NormalizeCase(pieces[i].Text, names)).ToList();
        // Sözlükteki adlar etiketle korunur; etiket varsa istek XML olarak gider, diğer cümleler de kaçırılır.
        var wrapped = plain.Select(p => DeepLMarkup.Wrap(p, glossary)).ToList();
        var tagged = wrapped.Any(w => w is not null);
        var sources = tagged ? plain.Select((p, i) => wrapped[i] ?? DeepLMarkup.Escape(p)).ToList() : plain;

        string[] translated;
        try
        {
            string[] reply;
            try
            {
                reply = sources.Count == 0 ? [] : await RequestAsync(sources, context, tagged, cancellationToken).ConfigureAwait(false);
            }
            catch (HttpRequestException) when (!cancellationToken.IsCancellationRequested)
            {
                // Açık tutulan bağlantıyı sunucu sessizce kapatmış olabilir: yeni bağlantıyla hemen bir kez daha denenir,
                // yedek çeviriye (ve DeepL'in beklemesine) ancak ikinci hata düşürür.
                reply = await RequestAsync(sources, context, tagged, cancellationToken).ConfigureAwait(false);
            }
            translated = tagged ? [.. reply.Select(DeepLMarkup.Unwrap)] : reply;
            Report(null);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or DeepLException
                                      && !cancellationToken.IsCancellationRequested)
        {
            Report(error is DeepLException deepL ? deepL.State : OnlineKeyState.Unreachable);
            _pausedUntil = DateTimeOffset.UtcNow + RetryAfter;
            _pauseRateLimited = error is DeepLException { RateLimited: true };
            return await FallbackAsync(text, cancellationToken).ConfigureAwait(false);
        }
        for (var i = 0; i < missing.Count; i++)
        {
            translations[missing[i]] = translated[i];
            _cache.Store(DeepLMarkup.CacheKey(pieces[missing[i]].Text, glossary), translated[i]);
        }

        var builder = new StringBuilder();
        for (var i = 0; i < pieces.Count; i++) builder.Append(translations[i] ?? pieces[i].Text);
        if (_speech.Count >= 512) _speech.Clear();
        _speech[text] = SpeechScript.Lines(pieces, translations);
        var result = builder.ToString();
        _cache.Store(DeepLMarkup.CacheKey(text, glossary), result);
        return result;
    }

    /// <summary>Son gösterilen satırlar, eskiden yeniye; DeepL'e bağlam olarak gider.</summary>
    private string? Context()
    {
        lock (_recent) return _recent.Count == 0 ? null : string.Join("\n", _recent);
    }

    private void Shown(string text)
    {
        lock (_recent)
        {
            // Aynı satır yeniden okunduysa bağlam tekrarla dolmasın.
            if (_recent.Count > 0 && _recent[^1] == text) return;
            _recent.Add(text);
            if (_recent.Count > ContextLines) _recent.RemoveAt(0);
        }
    }

    public IReadOnlyList<SpokenLine> SpokenLines(string text)
    {
        if (_speech.TryGetValue(text, out var lines)) return lines;
        // Önbellek, çeviride kullanılan anahtarla okunur: sözlük açıkken sözlükteki adı içeren cümle sözlük parmak
        // iziyle saklanır; çıplak cümleyle aranırsa bulunmaz ve dublaj önbellekten gelen satırda kaybolurdu.
        var glossary = _glossary.Current;
        var cached = SpeechScript.FromCache(text, _cache, part => DeepLMarkup.CacheKey(part, glossary));
        return cached.Count > 0 ? cached : _fallback?.SpokenLines(text) ?? [];
    }

    /// <summary>Cihaz üstü çeviri; yoksa ya da hata verirse null.</summary>
    private async Task<string?> TryFallbackAsync(string text, CancellationToken cancellationToken)
    {
        if (_fallback is null) return null;
        try { return await _fallback.TranslateAsync(text, cancellationToken).ConfigureAwait(false); }
        catch (Exception error) when (error is not OperationCanceledException) { return null; }
    }

    private async Task<string> FallbackAsync(string text, CancellationToken cancellationToken) =>
        _fallback is null ? throw new TranslatorException(TranslatorStatus.NeedsDownload)
            : await _fallback.TranslateAsync(text, cancellationToken).ConfigureAwait(false);

    private async Task<string[]> RequestAsync(List<string> sentences, string? context, bool tagged, CancellationToken cancellationToken)
    {
        // Oyun konuşması: "siz" değil "sen" (DeepL Türkçede desteklemiyorsa yok sayar).
        var body = new TranslateRequest(sentences, "EN", "TR", context, "prefer_less", true,
            tagged ? "xml" : null, tagged ? [DeepLMarkup.Tag] : null);
        using var request = new HttpRequestMessage(HttpMethod.Post, new Uri(BaseUri(_key), "translate"))
        {
            Content = JsonContent.Create(body, DeepLJson.Default.TranslateRequest),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("DeepL-Auth-Key", _key);
        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(response);
        var reply = await response.Content.ReadFromJsonAsync(DeepLJson.Default.TranslateResponse, cancellationToken).ConfigureAwait(false);
        if (reply?.Translations is not { } list || list.Count != sentences.Count) throw new DeepLException(OnlineKeyState.Unreachable);
        return [.. list.Select(t => t.Text)];
    }

    /// <summary>
    /// Ayarlardaki "Dene" düğmesi: anahtar geçerli mi, bu ay ne kadar kullanıldı (Mac/iPhone: DeepLTranslator.check, Android:
    /// KeyCheck.deepLUsage; aynı kurallar). Her hata kendi nedeniyle döner: 401/403 geçersiz, 456 sınır doldu, 429 çok sık
    /// istek (Busy: anahtar reddedilmedi, kaydedilir), diğer HTTP kodları sunucu hatası, istek hiç ulaşmadıysa ağ hatası.
    /// 200 yanıtında kullanım alanları eksik ya da beklenmedik biçimdeyse anahtar yine geçerlidir (sınır 0 görünür).
    /// </summary>
    public static async Task<OnlineKeyCheck> CheckAsync(string key, HttpClient? http = null, CancellationToken cancellationToken = default)
    {
        key = DeepLKey.Clean(key);
        if (key.Length == 0) return new(OnlineKeyState.Invalid);
        if (!DeepLKey.IsWellFormed(key)) return new(OnlineKeyState.Invalid, Reason: OnlineKeyReason.MalformedKey);
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(BaseUri(key), "usage"));
            request.Headers.Authorization = new AuthenticationHeaderValue("DeepL-Auth-Key", key);
            using var response = await (http ?? SharedClient.Value).SendAsync(request, cancellationToken).ConfigureAwait(false);
            var status = (int)response.StatusCode;
            switch (status)
            {
                case >= 200 and < 300: break;
                case 401 or 403: return new(OnlineKeyState.Invalid, Reason: OnlineKeyReason.HttpStatus, Code: status);
                case 456: return new(OnlineKeyState.QuotaExceeded, Reason: OnlineKeyReason.HttpStatus, Code: status);
                case 429: return new(OnlineKeyState.Busy, Reason: OnlineKeyReason.RateLimited, Code: status);
                default: return new(OnlineKeyState.Unreachable, Reason: OnlineKeyReason.HttpStatus, Code: status);
            }
            // JSON olmayan 200 yanıtı (otel/kafe ağının giriş sayfası gibi) DeepL'den gelmemiştir: ağ hatası.
            if (ParseUsage(await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false)) is not { } usage)
                return new(OnlineKeyState.Unreachable, Reason: OnlineKeyReason.Network);
            var (count, limit) = usage;
            return new(limit > 0 && count >= limit ? OnlineKeyState.QuotaExceeded : OnlineKeyState.Valid, count, limit);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException && !cancellationToken.IsCancellationRequested)
        {
            return new(OnlineKeyState.Unreachable, Reason: OnlineKeyReason.Network);
        }
    }

    /// <summary>
    /// <c>/v2/usage</c> yanıtı (Mac ve Android'deki çözümlemeyle aynı): alan eksik ya da sayı değilse 0; ondalıklı değer tam
    /// sayıya, long'a sığmayan değer long.MaxValue'ya indirilir. Gövde JSON nesnesi değilse null.
    /// </summary>
    internal static (long Count, long Limit)? ParseUsage(string body)
    {
        try
        {
            using var document = System.Text.Json.JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != System.Text.Json.JsonValueKind.Object) return null;
            return (Number(document.RootElement, "character_count"), Number(document.RootElement, "character_limit"));
        }
        catch (System.Text.Json.JsonException) { return null; }

        static long Number(System.Text.Json.JsonElement root, string name)
        {
            if (!root.TryGetProperty(name, out var value)) return 0;
            string text;
            if (value.ValueKind == System.Text.Json.JsonValueKind.Number) text = value.GetRawText();
            else if (value.ValueKind == System.Text.Json.JsonValueKind.String) text = value.GetString() ?? "";
            else return 0;
            var invariant = System.Globalization.CultureInfo.InvariantCulture;
            if (long.TryParse(text, System.Globalization.NumberStyles.Integer, invariant, out var exact)) return Math.Max(0, exact);
            if (!double.TryParse(text, System.Globalization.NumberStyles.Float, invariant, out var number) || double.IsNaN(number) || number <= 0) return 0;
            return number >= 9.2e18 ? long.MaxValue : (long)number;
        }
    }

    private static void ThrowIfFailed(HttpResponseMessage response)
    {
        if (response.IsSuccessStatusCode) return;
        throw new DeepLException(response.StatusCode switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => OnlineKeyState.Invalid,
            (HttpStatusCode)456 => OnlineKeyState.QuotaExceeded,
            _ => OnlineKeyState.Unreachable,
        }) { RateLimited = response.StatusCode == HttpStatusCode.TooManyRequests };
    }
}

internal sealed class DeepLException(OnlineKeyState state) : Exception($"DeepL: {state}")
{
    public OnlineKeyState State { get; } = state;
    /// <summary>DeepL 429 döndü (çok sık istek): bekleme süresince istek gönderilmez.</summary>
    public bool RateLimited { get; init; }
}

internal sealed record TranslateRequest(
    [property: JsonPropertyName("text")] IReadOnlyList<string> Text,
    [property: JsonPropertyName("source_lang")] string SourceLang,
    [property: JsonPropertyName("target_lang")] string TargetLang,
    [property: JsonPropertyName("context"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Context,
    [property: JsonPropertyName("formality")] string Formality,
    [property: JsonPropertyName("preserve_formatting")] bool PreserveFormatting,
    [property: JsonPropertyName("tag_handling"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? TagHandling = null,
    [property: JsonPropertyName("ignore_tags"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<string>? IgnoreTags = null);

internal sealed record TranslateResponse([property: JsonPropertyName("translations")] IReadOnlyList<TranslatedText>? Translations);

internal sealed record TranslatedText([property: JsonPropertyName("text")] string Text);

[JsonSerializable(typeof(TranslateRequest))]
[JsonSerializable(typeof(TranslateResponse))]
internal sealed partial class DeepLJson : JsonSerializerContext;
