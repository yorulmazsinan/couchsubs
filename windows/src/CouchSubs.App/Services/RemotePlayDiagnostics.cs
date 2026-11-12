// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.IO;
using CouchSubs.Core;
using CouchSubs.RemotePlay;

namespace CouchSubs.App.Services;

/// <summary>
/// PS5 bağlantısının (libchiaki) günlüğünü %LOCALAPPDATA%\CouchSubs\remoteplay.log dosyasına yazar. PS5 "Yeniden
/// bağlanıyor…"da kalınca sebep buradan görülür. Satırlar yerel kütüphanenin iş parçacığını bekletmeden arka planda
/// yazılır; dosya 1 MB'yi geçince eski yarısı silinir.
/// </summary>
internal static class RemotePlayDiagnostics
{
    private const long MaxBytes = 1 << 20;
    private static readonly BlockingCollection<string> Lines = new(boundedCapacity: 2000);

    internal static string LogPath => RemotePlayLog.FilePath;

    public static void Start()
    {
        RemotePlayLog.MessageLogged += line => Lines.TryAdd($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}");
        new Thread(WriteLoop) { IsBackground = true, Name = "remoteplay.log" }.Start();
        // Altyazı günlüğü (aynı klasörde altyazi.log): okunan satırlar ve akıbetleri, görüntü duraklamaları.
        SubtitleLog.Enable();
        var stalls = new VideoStallTracker();
        RemotePlayLog.MessageLogged += line =>
        {
            if (stalls.Note(line) is { } note) SubtitleLog.Write(note);
        };
    }

    public static void Note(string line) => Lines.TryAdd($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {line}");

    private static void WriteLoop()
    {
        foreach (var line in Lines.GetConsumingEnumerable())
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
                var info = new FileInfo(LogPath);
                if (info.Exists && info.Length > MaxBytes)
                {
                    var text = File.ReadAllText(LogPath);
                    File.WriteAllText(LogPath, text[(text.Length / 2)..]);
                }
                File.AppendAllText(LogPath, line + Environment.NewLine);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                // Günlük yazılamasa da uygulama sürer.
            }
        }
    }
}
