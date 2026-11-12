// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Text;
using CouchSubs.Core;
using CouchSubs.Core.Dubbing;

namespace CouchSubs.Translation;

/// <summary>
/// Cihaz üstü İngilizce→Türkçe çeviri (OPUS-MT, ONNX Runtime). Model ilk çeviride yüklenir; aynı cümle oyunda
/// defalarca okunduğu için sonuçlar önbelleklenir (Mac'teki gibi). Uygulama kalıcı önbelleği verir: önceki
/// oturumlarda çevrilmiş cümleler modeli hiç çalıştırmadan döner. Metin hattı (terim sözlüğü, kısa satır bağlamı,
/// Türkçe düzeltmeler) <see cref="FreeTranslation"/>'dadır, Mac'teki Apple çevirisiyle ortaktır.
/// </summary>
public sealed class MarianTranslator : ITextTranslator, IDisposable
{
    /// <summary>
    /// Kalıcı önbellek dosyasındaki motor adı; model ya da metin hattı (<see cref="FreeTranslation.PipelineVersion"/>)
    /// değişirse bu da değişir, eski kurallarla çevrilmiş satırlar gösterilmez.
    /// </summary>
    public static readonly string EngineId = "opus-mt-p" + FreeTranslation.PipelineVersion;

    private readonly Func<ISentenceEngine> _engineFactory;
    private readonly Func<bool> _isInstalled;
    private readonly TranslationCache _cache;
    private readonly GlossaryStore _glossary;
    private readonly RecentLines _recent;
    /// <summary>Konuşmacı etiketlerinden öğrenilen adlar (küçük harfle); cümle içinde de büyük harfle kalırlar.</summary>
    private readonly ConcurrentDictionary<string, byte> _names = new(StringComparer.Ordinal);
    /// <summary>Altyazı → seslendirilecek cümleler (dublaj).</summary>
    private readonly ConcurrentDictionary<string, IReadOnlyList<SpokenLine>> _speech = new(StringComparer.Ordinal);
    // Model tek seferde bir cümle çevirir: paralel çalıştırmak çekirdekleri paylaştırıp her satırı yavaşlatır.
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ISentenceEngine? _engine;
    /// <summary>Motor bir kez açılamadıysa nedeni; yeniden denenmez (yerel DLL süreç içinde sonradan yüklenmez).</summary>
    private Exception? _engineFailure;
    private bool _disposed;

    /// <summary>
    /// Motor açılamadı (ör. onnxruntime.dll ya da bağımlılığı yüklenemedi). Bir kez, arka plan iş parçacığından çağrılır;
    /// uygulama günlüğe yazar ve kullanıcıya gösterir. Çeviriler bundan sonra <see cref="TranslatorStatus.EngineFailed"/> fırlatır.
    /// </summary>
    public event Action<Exception>? EngineFailed;

    /// <param name="cache">Kalıcı önbellek; verilmezse yalnız bellekte tutulur.</param>
    /// <param name="glossary">Terim sözlüğü; verilmezse genel sözlük ve %LOCALAPPDATA%\CouchSubs\glossary\*.json.</param>
    public MarianTranslator(string modelDirectory, int maxOutputTokens = 128, int beams = OnnxMarianEngine.DefaultBeams,
        TranslationCache? cache = null, GlossaryStore? glossary = null)
        : this(() => new OnnxMarianEngine(modelDirectory, maxOutputTokens, beams), () => IsInstalledIn(modelDirectory), cache,
            glossary ?? new GlossaryStore(GlossaryStore.UserDirectory)) { }

    internal MarianTranslator(Func<ISentenceEngine> engineFactory, Func<bool> isInstalled, TranslationCache? cache = null,
        GlossaryStore? glossary = null, Func<DateTimeOffset>? clock = null)
    {
        _engineFactory = engineFactory;
        _isInstalled = isInstalled;
        _cache = cache ?? new TranslationCache();
        _glossary = glossary ?? GlossaryStore.BuiltInOnly();
        _recent = new RecentLines(clock);
    }

    public TranslatorStatus Status =>
        Volatile.Read(ref _engineFailure) is not null ? TranslatorStatus.EngineFailed
        : _engine is not null || _isInstalled() ? TranslatorStatus.Ready
        : TranslatorStatus.NeedsDownload;

    /// <summary>Çeviri için gereken dosyalar yerinde mi (ModelStore yalnızca doğrulanmış dosyayı asıl adına taşır).</summary>
    public static bool IsInstalledIn(string modelDirectory) =>
        OnnxMarianEngine.RequiredFiles.All(name => File.Exists(Path.Combine(modelDirectory, name)));

    /// <summary>
    /// Modeli önceden yükler ve bir kez çalıştırır; ilk altyazı beklemesin. Arka planda başlatılıp beklenmediği için
    /// hata fırlatmaz (gözlenmemiş görev hatası bırakmaz): motor açılamadıysa <see cref="EngineFailed"/> bildirir,
    /// çeviriler de durumu <see cref="TranslatorException"/> ile söyler.
    /// </summary>
    public async Task WarmUpAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await TranslateSentenceAsync("Hello.", null, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            // Motor açılamadıysa EngineFailed zaten çağrıldı; model eksikse ya da çeviri hata verdiyse ilk altyazı söyler.
        }
    }

    public async Task<string> TranslateAsync(string text, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(text);
        // Kısa cümlenin bağlamı: aynı satırdaki önceki cümle, yoksa bu satırdan önce gösterilen satırın son cümlesi.
        var previousLine = _recent.Shown(text);
        var pieces = SubtitleSegmenter.Split(text);
        // "OLD MAN: " → "old", "man": çok sözcüklü adın her sözcüğü ayrıca tanınır.
        foreach (var name in pieces.Select(SubtitleSegmenter.LabelName).OfType<string>())
            foreach (var word in name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Where(w => w.Length >= 2))
                _names[word.ToLowerInvariant()] = 0;
        var previous = previousLine is null ? null : LastSentence(previousLine);
        var translations = new List<string?>(pieces.Count);
        foreach (var piece in pieces)
        {
            if (!piece.Translate)
            {
                translations.Add(null);
                continue;
            }
            var context = FreeTranslation.IsShort(piece.Text) ? previous : null;
            translations.Add(await TranslateSentenceAsync(piece.Text, context, cancellationToken).ConfigureAwait(false));
            previous = piece.Text;
        }
        // Hitap satırın bütününe bakar ("Sana söyledim. Bekleyin!"); önbellekteki cümle çevirileri değişmez.
        var final = TurkishPostEdit.Register(translations);
        var builder = new StringBuilder();
        for (var i = 0; i < pieces.Count; i++) builder.Append(final[i] ?? pieces[i].Text);
        if (_speech.Count >= 512) _speech.Clear();
        _speech[text] = SpeechScript.Lines(pieces, final);
        return builder.ToString();
    }

    private static string? LastSentence(string line)
    {
        string? last = null;
        foreach (var piece in SubtitleSegmenter.Split(line))
            if (piece.Translate) last = piece.Text;
        return last;
    }

    public IReadOnlyList<SpokenLine> SpokenLines(string text) =>
        _speech.TryGetValue(text, out var lines) ? lines : SpeechScript.FromCache(text, _cache);

    private async Task<string> TranslateSentenceAsync(string sentence, string? context, CancellationToken cancellationToken)
    {
        var glossary = _glossary.Current;
        var key = FreeTranslation.CacheKey(sentence, context, glossary);
        if (_cache.TryGet(key, out var known)) return known;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            // Beklerken başka bir çağrı aynı cümleyi çevirmiş olabilir.
            if (_cache.TryGet(key, out var cached)) return cached;
            var engine = _engine ??= CreateEngine();
            var names = _names.Keys.ToHashSet(StringComparer.Ordinal);
            names.UnionWith(glossary.CapitalWords);
            // Çıkarım CPU'yu saniyenin onda biri kadar tutar; çağıranın (arayüz) iş parçacığını bloklamasın.
            var translation = await Task.Run(() => FreeTranslation.Translate(sentence, context, glossary,
                text => SubtitleSegmenter.NormalizeCase(text, names),
                input => engine.Translate(input, cancellationToken)), cancellationToken).ConfigureAwait(false);
            // Sıra bırakılmadan önce önbelleğe yazılır; sırada bekleyen aynı cümle yeniden çevrilmez.
            _cache.Store(key, translation);
            return translation;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Yalnız <see cref="_gate"/> tutulurken çağrılır.</summary>
    private ISentenceEngine CreateEngine()
    {
        if (_engineFailure is { } failed) throw new TranslatorException(TranslatorStatus.EngineFailed, failed);
        if (!_isInstalled()) throw new TranslatorException(TranslatorStatus.NeedsDownload);
        try
        {
            return _engineFactory();
        }
        catch (Exception error) when (error is not (OperationCanceledException or TranslatorException))
        {
            // ONNX Runtime'ın yerel DLL'i yüklenemeyince TypeInitializationException (içinde DllNotFoundException) gelir;
            // .NET bu hatayı süreç boyunca saklar, yeniden denemek işe yaramaz.
            Volatile.Write(ref _engineFailure, error);
            EngineFailed?.Invoke(error);
            throw new TranslatorException(TranslatorStatus.EngineFailed, error);
        }
    }

    public void Dispose()
    {
        _gate.Wait();
        try
        {
            if (_disposed) return;
            _disposed = true;
            _engine?.Dispose();
            _engine = null;
        }
        finally
        {
            _gate.Release();
        }
    }
}

/// <summary>Tek cümleyi çeviren çekirdek; testlerde sahtesi kullanılır.</summary>
internal interface ISentenceEngine : IDisposable
{
    string Translate(string sentence, CancellationToken cancellationToken);
}
