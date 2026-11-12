// SPDX-License-Identifier: AGPL-3.0-only

using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CouchSubs.Core;

/// <summary>
/// Ortak havuz (varsayılan açık, ayarlardan kapatılabilir; ayarlarda ve kurulumun son adımında açıkça söylenir): hiçbir pakette bulunmayan İngilizce oyun satırları biriktirilir ve
/// beş dakikada bir (ve uygulama kapanırken) sunucuya gönderilir; yeni paketler bunlardan hazırlanır. Yalnız satırın
/// metni, anahtarı ve ilk görüldüğü an gider; kimlik olarak kuruluma özgü rastgele bir UUID kullanılır (IP, kullanıcı adı,
/// PSN bilgisi yok). Sunucuya ulaşılamazsa kuyruk diskte bekler, sonra sessizce yeniden denenir.
/// Mac'teki CouchSubsCore/LinePool.swift ile aynı kurallar.
/// </summary>
public sealed class LinePool : IDisposable
{
    /// <summary>Açık; ayarlarda kullanıcı kapatabilir (kapatınca kuyruk da silinir).</summary>
    public const bool EnabledByDefault = true;
    /// <summary>Sunucu adresi; denemede <c>COUCHSUBS_POOL_URL</c> ortam değişkeniyle değiştirilir.</summary>
    public static readonly Uri DefaultEndpoint = new("https://couchsubs-pool.enmera.workers.dev/v1/lines");
    public const int BatchSize = 200;
    public const int MaxQueue = 5000;
    public const int MaxLength = 300;
    public const int MinWords = 2;
    public static readonly TimeSpan FlushInterval = TimeSpan.FromMinutes(5);
    /// <summary>Gönderilen anahtarlardan bu kadarı hatırlanır (aynı satır her oturumda yeniden gitmesin).</summary>
    internal const int RememberedSent = 20000;
    /// <summary>Kuyruk en geç bu aralıkla diske yazılır (her satırda yazılmaz).</summary>
    internal static readonly TimeSpan SaveInterval = TimeSpan.FromSeconds(30);

    public sealed record Line(
        [property: JsonPropertyName("text")] string Text,
        [property: JsonPropertyName("key")] string Key,
        [property: JsonPropertyName("firstSeen")] string FirstSeen);

    private sealed class State
    {
        [JsonPropertyName("install")] public string Install { get; set; } = Guid.NewGuid().ToString();
        [JsonPropertyName("queue")] public List<Line> Queue { get; set; } = [];
        [JsonPropertyName("sent")] public List<string> Sent { get; set; } = [];
        /// <summary>Unix saniyesi; sunucu 429 ile beklemeyi istediyse.</summary>
        [JsonPropertyName("retryAfter")] public double? RetryAfter { get; set; }
    }

    private sealed record Payload(
        [property: JsonPropertyName("install")] string Install,
        [property: JsonPropertyName("app")] string App,
        [property: JsonPropertyName("platform")] string Platform,
        [property: JsonPropertyName("lines")] IReadOnlyList<Line> Lines);

    public static Uri Endpoint =>
        Environment.GetEnvironmentVariable("COUCHSUBS_POOL_URL") is { Length: > 0 } value && Uri.TryCreate(value, UriKind.Absolute, out var url)
            ? url : DefaultEndpoint;

    private readonly object gate = new();
    private readonly SemaphoreSlim sending = new(1, 1);
    private readonly string file;
    private readonly Uri url;
    private readonly string app;
    private readonly string platform;
    private readonly HttpClient http;
    private readonly Func<DateTimeOffset> clock;
    private readonly State state;
    private readonly HashSet<string> queuedKeys;
    private readonly HashSet<string> sentKeys;
    private DateTimeOffset lastSave = DateTimeOffset.MinValue;
    private bool dirty;
    private bool enabled;

    /// <param name="handler">HTTP katmanı; testlerde sahtesi verilir.</param>
    public LinePool(string file, string app, Uri? endpoint = null, string platform = "windows", bool enabled = EnabledByDefault,
        HttpMessageHandler? handler = null, Func<DateTimeOffset>? clock = null)
    {
        this.file = file;
        this.app = app;
        this.platform = platform;
        this.enabled = enabled;
        url = endpoint ?? Endpoint;
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = TimeSpan.FromSeconds(20);
        this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        state = Load(file) ?? new State();
        state.Install = state.Install.ToLowerInvariant();
        queuedKeys = [.. state.Queue.Select(line => line.Key)];
        sentKeys = [.. state.Sent];
    }

    public IReadOnlyList<Line> Queued { get { lock (gate) return [.. state.Queue]; } }
    public string InstallId => state.Install;
    public bool IsEnabled { get { lock (gate) return enabled; } }

    /// <summary>Kapatılınca bekleyen satırlar da silinir: kullanıcı vazgeçtiyse hiçbir şey gitmez.</summary>
    public void SetEnabled(bool value)
    {
        lock (gate)
        {
            enabled = value;
            if (value || state.Queue.Count == 0) return;
            state.Queue.Clear();
            queuedKeys.Clear();
            dirty = true;
            SaveLocked();
        }
    }

    /// <summary>Okunan (pakette bulunmayan) satırı kuyruğa ekler; kapalıysa, filtreye takılırsa ya da zaten varsa bir şey yapmaz.</summary>
    public void Offer(string text)
    {
        text = text.Trim();
        if (!Accepts(text) || PackKey.Key(text) is not { } key) return;
        lock (gate)
        {
            if (!enabled || queuedKeys.Contains(key) || sentKeys.Contains(key)) return;
            state.Queue.Add(new Line(text, key, Timestamp(clock())));
            queuedKeys.Add(key);
            // Sınır aşılırsa en eski satırlar düşer.
            if (state.Queue.Count > MaxQueue)
            {
                var dropped = state.Queue.Count - MaxQueue;
                foreach (var line in state.Queue.Take(dropped)) queuedKeys.Remove(line.Key);
                state.Queue.RemoveRange(0, dropped);
            }
            dirty = true;
            if (clock() - lastSave >= SaveInterval) SaveLocked();
        }
    }

    /// <summary>Kuyruğu 200'lük parçalar hâlinde gönderir. 429'da sunucunun istediği kadar bekler; ulaşılamazsa kuyruk kalır.</summary>
    public async Task FlushAsync(CancellationToken cancellationToken = default)
    {
        await sending.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            while (true)
            {
                List<Line> batch;
                string body;
                lock (gate)
                {
                    if (!enabled || state.Queue.Count == 0) return;
                    if (state.RetryAfter is { } retry && clock().ToUnixTimeMilliseconds() / 1000.0 < retry) return;
                    batch = [.. state.Queue.Take(BatchSize)];
                    body = JsonSerializer.Serialize(new Payload(state.Install, app, platform, batch));
                }
                HttpResponseMessage response;
                try
                {
                    using var content = new StringContent(body, Encoding.UTF8, "application/json");
                    response = await http.PostAsync(url, content, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception error) when (error is HttpRequestException or TaskCanceledException or OperationCanceledException)
                {
                    return;
                }
                using (response)
                {
                    var status = (int)response.StatusCode;
                    lock (gate)
                    {
                        if (status is >= 200 and < 300)
                        {
                            state.RetryAfter = null;
                            Remove(batch, sent: true);
                        }
                        else if (status == (int)HttpStatusCode.TooManyRequests)
                        {
                            var now = clock();
                            state.RetryAfter = (now + RetryDelay(response.Headers.RetryAfter, now)).ToUnixTimeMilliseconds() / 1000.0;
                            dirty = true;
                            return;
                        }
                        else if (status is >= 400 and < 500)
                        {
                            // Sunucu bu parçayı kabul etmiyor; yeniden göndermek düzeltmez.
                            Remove(batch, sent: false);
                        }
                        else
                        {
                            return;
                        }
                    }
                }
            }
        }
        finally
        {
            Save();
            sending.Release();
        }
    }

    /// <summary>Kuyruğu diske yazar (uygulama kapanırken de çağrılır).</summary>
    public void Save()
    {
        lock (gate) SaveLocked();
    }

    private void SaveLocked()
    {
        if (!dirty) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            var temporary = file + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(state));
            File.Move(temporary, file, overwrite: true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        dirty = false;
        lastSave = clock();
    }

    private void Remove(List<Line> batch, bool sent)
    {
        var keys = batch.Select(line => line.Key).ToHashSet();
        state.Queue.RemoveAll(line => keys.Contains(line.Key));
        queuedKeys.ExceptWith(keys);
        if (sent)
        {
            state.Sent.AddRange(batch.Select(line => line.Key));
            sentKeys.UnionWith(keys);
            if (state.Sent.Count > RememberedSent)
            {
                var dropped = state.Sent.Count - RememberedSent;
                sentKeys.ExceptWith(state.Sent.Take(dropped));
                state.Sent.RemoveRange(0, dropped);
            }
        }
        dirty = true;
    }

    private static State? Load(string file)
    {
        try { return JsonSerializer.Deserialize<State>(File.ReadAllText(file)); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or NotSupportedException) { return null; }
    }

    /// <summary>
    /// Havuza uygun satır: en az iki sözcük, en çok 300 karakter, arayüz ya da yazı tanıma çöpü gibi görünmüyor; Türkçe,
    /// PS5'in sistem yazısı ya da yarım okuma değil (<see cref="PoolFilter"/>).
    /// </summary>
    public static bool Accepts(string text)
    {
        text = text.Trim();
        if (text.Length == 0 || text.Length > MaxLength) return false;
        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Count(word => word.EnumerateRunes().Any(Rune.IsLetter));
        return words >= MinWords && !LooksLikeNoise(text) && PoolFilter.Accepts(text);
    }

    /// <summary>Yazı tanıma çöpü içeren ("ou$3e") ya da harften çok rakam ve simge taşıyan ("100/100 HP 25%") satır.</summary>
    public static bool LooksLikeNoise(string text)
    {
        if (PackKey.Canon(OcrNoise.Clean(text)) != PackKey.Canon(text)) return true;
        var visible = text.EnumerateRunes().Where(rune => !Rune.IsWhiteSpace(rune)).ToList();
        var letters = visible.Count(Rune.IsLetter);
        return letters * 2 < visible.Count;
    }

    /// <summary><c>Retry-After</c>: saniye ya da HTTP tarihi; yoksa bir dakika, en çok bir gün.</summary>
    public static TimeSpan RetryDelay(RetryConditionHeaderValue? header, DateTimeOffset now)
    {
        var delay = header switch
        {
            { Delta: { } delta } => delta,
            { Date: { } date } => date - now,
            _ => TimeSpan.FromSeconds(60),
        };
        return TimeSpan.FromSeconds(Math.Clamp(delay.TotalSeconds, 1, 86400));
    }

    /// <summary>"2026-11-11T03:17:00Z" (UTC, saniye hassasiyeti).</summary>
    public static string Timestamp(DateTimeOffset time) =>
        time.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

    public void Dispose()
    {
        http.Dispose();
        sending.Dispose();
    }
}
