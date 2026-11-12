// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Text;

namespace CouchSubs.Core;

/// <summary>
/// Altyazı günlüğü: her oturumda okunan altyazı satırlarının ve akıbetlerinin kısa kaydı
/// (%LOCALAPPDATA%\CouchSubs\altyazi.log, remoteplay.log'un yanı; Mac'te ~/Library/Logs/CouchSubs/altyazi.log).
/// "İlk satırlar görünmedi" gibi bildirimlerde ne okunduğu ve her satıra ne olduğu (paket, önbellek, çeviri, geç kaldı,
/// atıldı, çöp) buradan görülür. Altyazı metni dışında kişisel bilgi yazılmaz. Uygulama açılışta <see cref="Enable"/>
/// çağırır; çağrılmazsa (testler) hiçbir şey yazılmaz. Satırlar arka planda yazılır; dosya 1 MB'yi geçince
/// altyazi.log.1'e taşınır (en çok ~2 MB). Mac'teki CouchSubsCore/SubtitleLog.swift ile aynı biçim.
/// </summary>
public static class SubtitleLog
{
    /// <summary>Kullanıcıya gösterilen yol (Dosya Gezgini'nin adres çubuğuna yazılabilir).</summary>
    public const string DisplayPath = @"%LOCALAPPDATA%\CouchSubs\altyazi.log";
    /// <summary>Bir dosyanın en büyük boyutu; aşılınca eskisi <c>.1</c> olur.</summary>
    internal const long MaxBytes = 1 << 20;
    /// <summary>Günlükteki altyazı alıntısının en uzun hâli.</summary>
    public const int ExcerptLength = 120;

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "altyazi.log");

    private static readonly BlockingCollection<(string? Path, string? Line, ManualResetEventSlim? Done)> Queue = new(boundedCapacity: 2000);
    private static readonly object Gate = new();
    private static string? file;
    private static bool writerStarted;
    private static readonly UTF8Encoding NoBom = new(false);

    public static bool IsEnabled { get { lock (Gate) return file is not null; } }

    public static void Enable(string? path = null)
    {
        lock (Gate)
        {
            file = path ?? DefaultPath;
            if (writerStarted) return;
            writerStarted = true;
            new Thread(WriteLoop) { IsBackground = true, Name = "altyazi.log" }.Start();
        }
    }

    public static void Disable()
    {
        Flush();
        lock (Gate) file = null;
    }

    /// <summary>Bekleyen satırlar yazılana kadar bekler (testler ve kapanış için; en çok iki saniye).</summary>
    public static void Flush()
    {
        lock (Gate) if (!writerStarted) return;
        using var done = new ManualResetEventSlim();
        if (Queue.TryAdd((null, null, done))) done.Wait(TimeSpan.FromSeconds(2));
    }

    public static void Write(string line)
    {
        string? path;
        lock (Gate) path = file;
        if (path is null) return;
        Queue.TryAdd((path, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {line}\n", null));
    }

    /// <summary>Günlükteki tırnaklı, tek satırlık, en çok <paramref name="limit"/> karakterlik alıntı.</summary>
    public static string Excerpt(string text, int limit = ExcerptLength)
    {
        var flat = string.Join(" / ", text.Split('\n', '\r').Select(part => part.Trim()).Where(part => part.Length > 0));
        var runes = flat.EnumerateRunes().ToList();
        var shortText = runes.Count > limit ? string.Concat(runes.Take(limit - 1).Select(r => r.ToString())) + "…" : flat;
        return $"\"{shortText}\"";
    }

    internal static void RotateIfNeeded(string path, long incoming)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length + incoming <= MaxBytes) return;
        File.Move(path, path + ".1", overwrite: true);
    }

    private static void WriteLoop()
    {
        foreach (var (path, line, done) in Queue.GetConsumingEnumerable())
        {
            if (done is not null)
            {
                done.Set();
                continue;
            }
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path!)!);
                var bytes = NoBom.GetBytes(line!);
                RotateIfNeeded(path!, bytes.Length);
                using var stream = new FileStream(path!, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                stream.Write(bytes);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Günlük yazılamasa da altyazı sürer.
            }
        }
    }
}

/// <summary>
/// libchiaki'nin günlük satırlarından görüntü duraklamalarını çıkarır: "FEC failed, waiting for IDR frame" ile görüntü
/// donar, "Received IDR frame, resuming decode" ile sürer. Bu arada kare gelmez; altyazı da okunamaz. Altyazı günlüğüne
/// duraklamanın başı ve süresi yazılır (satırlar libchiaki'nin iş parçacığından gelir).
/// </summary>
public sealed class VideoStallTracker(Func<long>? clock = null)
{
    private readonly Func<long> now = clock ?? (() => Environment.TickCount64);
    private readonly object gate = new();
    private long? stalledAt;

    /// <summary>Satır bir duraklamayı başlatıyor ya da bitiriyorsa günlük satırı; yoksa null.</summary>
    public string? Note(string line)
    {
        lock (gate)
        {
            if (line.Contains("FEC failed", StringComparison.Ordinal) || line.Contains("Video FEC failure", StringComparison.Ordinal))
            {
                if (stalledAt is not null) return null;
                stalledAt = now();
                return "görüntü durdu: FEC hatası, IDR karesi bekleniyor";
            }
            if (line.Contains("Received IDR frame", StringComparison.Ordinal))
            {
                if (stalledAt is not { } since) return null;
                stalledAt = null;
                return $"görüntü sürdü: IDR karesi geldi ({now() - since} ms boşluk)";
            }
            return null;
        }
    }
}
