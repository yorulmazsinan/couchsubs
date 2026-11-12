// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.Json.Serialization;

namespace CouchSubs.Core;

/// <summary>
/// Kullanıcının kendi anahtarıyla çalışan yapay zekâ çeviri hizmetleri (Mac'teki AIProvider ile aynı).
/// <c>Local</c>: kullanıcının bilgisayarında çalışan model (Ollama, LM Studio); OpenAI uyumlu Chat Completions adresine
/// gider, anahtar isteğe bağlıdır, model adını kullanıcı yazar.
/// </summary>
[JsonConverter(typeof(JsonStringEnumConverter<AiProvider>))]
public enum AiProvider { Gemini, OpenAi, Claude, Local }

public static class AiProviders
{
    /// <summary>Bulut hizmetleri: model listesi <c>ai-models.json</c>'dan gelir, anahtar gerekir.</summary>
    public static IReadOnlyList<AiProvider> Cloud { get; } = [.. Enum.GetValues<AiProvider>().Where(p => !p.IsLocal())];

    /// <summary>Kullanıcının bilgisayarındaki model (Ollama, LM Studio).</summary>
    public static bool IsLocal(this AiProvider provider) => provider == AiProvider.Local;

    /// <summary>
    /// Seçilebilen modeller; ilki varsayılandır (hızlı ve ucuz). Liste Mac ile ortak <c>ai-models.json</c> dosyasından
    /// gelir (core/Sources/CouchSubsCore/Resources, gömülü kaynak). Yerel modelde liste yoktur; model adını kullanıcı yazar.
    /// </summary>
    public static IReadOnlyList<AiModel> Models(this AiProvider provider) =>
        AiModel.Catalog.TryGetValue(provider.Id(), out var models) ? models : [];

    /// <summary>Hızlı ve ucuz varsayılan model.</summary>
    public static AiModel DefaultModel(this AiProvider provider) => provider.IsLocal()
        ? new AiModel(LocalAiServer.DefaultModel, LocalAiServer.DefaultModel)
        : provider.Models()[0];

    /// <summary>Marka adı; çevrilmez. Yerel modelin arayüzdeki adı uygulamada çevrilir.</summary>
    public static string DisplayName(this AiProvider provider) => provider switch
    {
        AiProvider.Gemini => "Gemini",
        AiProvider.OpenAi => "OpenAI",
        AiProvider.Local => "Local model",
        _ => "Claude",
    };

    /// <summary>Anahtarın alındığı resmî sayfa (yerel modelde Ollama'nın indirme sayfası).</summary>
    public static Uri KeyPage(this AiProvider provider) => new(provider switch
    {
        AiProvider.Gemini => "https://aistudio.google.com/apikey",
        AiProvider.OpenAi => "https://platform.openai.com/api-keys",
        AiProvider.Local => "https://ollama.com/download",
        _ => "https://platform.claude.com/settings/keys",
    });

    /// <summary>Kalıcı önbellek dosyasındaki ve Mac'teki ad: "gemini", "openai", "claude", "local".</summary>
    public static string Id(this AiProvider provider) => provider switch
    {
        AiProvider.Gemini => "gemini",
        AiProvider.OpenAi => "openai",
        AiProvider.Local => "local",
        _ => "claude",
    };

    /// <summary>
    /// Önbellekteki motor adı: model değişince eski modelin çevirileri karışmaz ("gemini:gemini-3.5-flash-lite"). Yerel
    /// modelde sunucu adresi de girer (bkz. <see cref="LocalAiServer.EngineId"/>).
    /// </summary>
    public static string EngineId(this AiProvider provider, string model) => $"{provider.Id()}:{model}";

    /// <summary>
    /// Kayıtlı model listede yoksa (eski ayar ya da listeden çıkarılan model) varsayılan model. Yerel modelde kullanıcının
    /// yazdığı ad olduğu gibi kullanılır (boşsa varsayılan).
    /// </summary>
    public static AiModel Model(this AiProvider provider, string? id)
    {
        if (provider.IsLocal())
            return string.IsNullOrWhiteSpace(id) ? provider.DefaultModel() : new AiModel(id.Trim(), id.Trim());
        return provider.Models().FirstOrDefault(m => m.Id == id) ?? provider.DefaultModel();
    }

    /// <summary>Ücretsiz anahtarla kullanılabilen bir modeli var mı (bugün yalnız Gemini).</summary>
    public static bool HasFreeTier(this AiProvider provider) => provider.Models().Any(m => m.FreeTier);
}

/// <summary>
/// Listedeki bir model ve onunla gönderilen ayarlar (Mac'teki AIModel ile aynı). Kullanıcı model adı yazamaz; yalnız bu
/// listeden seçer.
/// </summary>
/// <param name="Label">Ayarlarda görünen ad (Localizable.xcstrings anahtarı).</param>
/// <param name="Effort">OpenAI'da <c>reasoning_effort</c>, Claude'da <c>output_config.effort</c>; null ise gönderilmez.</param>
/// <param name="Thinking">Gemini'de <c>thinkingConfig.thinkingLevel</c>, Claude'da <c>thinking.type</c>; null ise gönderilmez.</param>
/// <param name="FreeTier">
/// Ücretsiz anahtarla (faturası bağlanmamış Google projesi) kullanılabilir mi: Kasım 2026'da
/// aistudio.google.com/docs/pricing sayfasında "Free Tier: Free of charge" yazan modeller.
/// </param>
/// <param name="RequestsPerMinute">
/// Dakikada en çok bu kadar istek gönderilir; hak bitince o satır yerel çeviriyle çevrilir. null ise sınır yok. Google
/// ücretsiz katmanın model başına sayılarını belgelerde yazmıyor (aistudio.google.com/docs/rate-limits: "Rate limits are
/// applied per project, not per API key"; sayılar yalnız aistudio.google.com/rate-limit'te). Değer temkinli seçildi;
/// hizmet 429 ile daha düşük sınır bildirirse o sınıra inilir.
/// </param>
public sealed record AiModel(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("label")] string Label,
    [property: JsonPropertyName("effort")] string? Effort = null,
    [property: JsonPropertyName("thinking")] string? Thinking = null,
    [property: JsonPropertyName("freeTier")] bool FreeTier = false,
    [property: JsonPropertyName("requestsPerMinute")] int? RequestsPerMinute = null)
{
    /// <summary><c>ai-models.json</c>: hizmet adı → modeller.</summary>
    internal static readonly IReadOnlyDictionary<string, IReadOnlyList<AiModel>> Catalog = Load();

    private static IReadOnlyDictionary<string, IReadOnlyList<AiModel>> Load()
    {
        using var stream = typeof(AiModel).Assembly.GetManifestResourceStream("ai-models.json")
            ?? throw new InvalidOperationException("ai-models.json uygulamaya gömülmemiş");
        using var reader = new StreamReader(stream);
        return Parse(reader.ReadToEnd());
    }

    /// <summary>"_comment" gibi dizi olmayan alanlar atlanır.</summary>
    public static IReadOnlyDictionary<string, IReadOnlyList<AiModel>> Parse(string json)
    {
        var result = new Dictionary<string, IReadOnlyList<AiModel>>(StringComparer.Ordinal);
        using var document = System.Text.Json.JsonDocument.Parse(json);
        foreach (var property in document.RootElement.EnumerateObject())
        {
            if (property.Value.ValueKind != System.Text.Json.JsonValueKind.Array) continue;
            var models = property.Value.EnumerateArray().Select(item => new AiModel(
                item.GetProperty("id").GetString()!, item.GetProperty("label").GetString()!,
                item.TryGetProperty("effort", out var effort) ? effort.GetString() : null,
                item.TryGetProperty("thinking", out var thinking) ? thinking.GetString() : null,
                // Yeni alanlar eksikse varsayılanla okunur.
                item.TryGetProperty("freeTier", out var free) && free.ValueKind == System.Text.Json.JsonValueKind.True,
                item.TryGetProperty("requestsPerMinute", out var rpm) && rpm.TryGetInt32(out var perMinute) ? perMinute : null)).ToList();
            if (models.Count > 0) result[property.Name] = models;
        }
        return result;
    }
}

/// <summary>
/// Kullanıcının bilgisayarındaki (ya da ağındaki) OpenAI uyumlu model sunucusu: Ollama, LM Studio (Mac'teki
/// LocalAIServer ile aynı). Adres "http://localhost:11434/v1" gibi <c>/v1</c> ile biten temel adrestir.
/// </summary>
public sealed record LocalAiServer
{
    /// <summary>Ollama'nın OpenAI uyumlu adresi (docs.ollama.com/api/openai-compatibility).</summary>
    public const string OllamaUrl = "http://localhost:11434/v1";
    /// <summary>LM Studio'nun yerel sunucusu (lmstudio.ai/docs/app/api/endpoints/openai).</summary>
    public const string LmStudioUrl = "http://localhost:1234/v1";
    /// <summary>Türkçeyi iyi bilen, sıradan bir bilgisayarda çalışan model.</summary>
    public const string DefaultModel = "qwen2.5:7b";

    private LocalAiServer(Uri baseUrl, string model)
    {
        BaseUrl = baseUrl;
        Model = model;
    }

    /// <summary>Sondaki "/" atılmış temel adres.</summary>
    public Uri BaseUrl { get; }
    public string Model { get; }

    /// <summary>
    /// Adres ya da model geçersizse null. "localhost:11434" gibi şemasız adrese "http://" eklenir; yolsuz adrese "/v1"
    /// eklenir; sona yapıştırılmış "/chat/completions" atılır.
    /// </summary>
    public static LocalAiServer? Create(string? baseUrl, string? model)
    {
        model = model?.Trim() ?? "";
        return model.Length > 0 && Normalize(baseUrl) is { } url ? new LocalAiServer(url, model) : null;
    }

    /// <summary>Kullanıcının yazdığı adresin düzeltilmiş hali; geçersizse null.</summary>
    public static Uri? Normalize(string? text)
    {
        text = text?.Trim() ?? "";
        if (text.Length == 0 || text.Contains(' ')) return null;
        if (!text.Contains("://", StringComparison.Ordinal)) text = "http://" + text;
        text = text.TrimEnd('/');
        if (text.EndsWith("/chat/completions", StringComparison.OrdinalIgnoreCase)) text = text[..^"/chat/completions".Length].TrimEnd('/');
        if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.Host.Length == 0) return null;
        var builder = new UriBuilder(uri) { Query = "", Fragment = "" };
        if (builder.Path is "" or "/") builder.Path = "/v1";
        return new Uri(builder.Uri.GetLeftPart(UriPartial.Path).TrimEnd('/'));
    }

    /// <summary>İsteğin gittiği adres.</summary>
    public Uri ChatUrl => new(BaseUrl.AbsoluteUri.TrimEnd('/') + "/chat/completions");

    /// <summary>Kullanıcıya gösterilen kısa adres: "http://localhost:11434".</summary>
    public string Address => BaseUrl.GetLeftPart(UriPartial.Authority);

    /// <summary>Sunucunun türü; adresin kapısından tahmin edilir (hata iletisinde doğru yönerge için).</summary>
    public LocalAiServerKind Kind => BaseUrl.Port switch
    {
        11434 => LocalAiServerKind.Ollama,
        1234 => LocalAiServerKind.LmStudio,
        _ => LocalAiServerKind.Other,
    };

    /// <summary>
    /// Önbellekteki motor adı: sunucu (makine ve kapı) ve model girer; farklı yerel modellerin çevirileri karışmaz.
    /// Ör. "local:localhost:11434/qwen2.5:7b" (Mac ile aynı).
    /// </summary>
    public string EngineId => $"{AiProvider.Local.Id()}:{BaseUrl.Host.ToLowerInvariant()}{(BaseUrl.IsDefaultPort ? "" : $":{BaseUrl.Port}")}/{Model}";
}

public enum LocalAiServerKind { Ollama, LmStudio, Other }

/// <summary>Çevrimiçi çevirmen hatasını bildirir; ana ekran "şu an çevirmiyor" uyarısını bundan gösterir.</summary>
public interface IOnlineTranslator
{
    /// <summary>Hata başlayınca durumla, düzelince null ile çağrılır (yalnız değişince).</summary>
    event Action<OnlineKeyState?>? FailureChanged;
}

/// <summary>Ayarlardaki "Dene": örnek satırın çevirisi ya da hatanın türü.</summary>
public sealed record AiTestResult(OnlineKeyState State, string? Sample = null);
