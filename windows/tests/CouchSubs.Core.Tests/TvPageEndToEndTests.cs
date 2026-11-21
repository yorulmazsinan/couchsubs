// SPDX-License-Identifier: AGPL-3.0-only

using System.Collections.Concurrent;
using System.Diagnostics;
using CouchSubs.Core;

namespace CouchSubs.Core.Tests;

/// <summary>
/// Uçtan uca: gerçek <see cref="SubtitleServer"/> ile Android TV uygulamasının sayfası (tv-webos/app.js +
/// tv-android/platform.js, Node'da, Android 8 WebView'ine göre kısıtlı; scripts/tv-live-page.js). Sayfa eşleşmiş anahtarla
/// bağlanır, bilgisayarın gönderdiği altyazıyı sayar ("sub 1") ve çizer. Node yoksa test bir şey yapmadan geçer.
/// </summary>
public class TvPageEndToEndTests
{
    [Fact]
    public async Task AndroidTvPageCountsAndShowsSubtitleFromServer()
    {
        using var page = TvPage.Start(out var server);
        if (page is null) return;
        await page.WaitFor("status bağlı");
        await WaitUntil(() => server.ConnectedClients == 1);

        server.SendSubtitle("Merhaba dünya, bu bir deneme.", 4000);
        await page.WaitFor("shown Merhaba dünya, bu bir deneme.");
        var diag = await page.WaitFor("diag sub 1 ");
        Assert.DoesNotContain(" err ", diag);
        server.Dispose();
    }

    /// "TV'de bağlı, panelde sub 0" belirtisinin sunucu tarafındaki tek koşulu: altyazı hedefi TV değilken (Bilgisayar ekranı,
    /// Yalnız OBS) altyazı olayları TV'ye gitmez, ping ve bağlantı sürer. Hedef TV olunca hemen gelir.
    [Fact]
    public async Task TvStaysConnectedWithZeroSubtitlesOnlyWhileOutputIsNotTv()
    {
        using var page = TvPage.Start(out var server);
        if (page is null) return;
        await page.WaitFor("status bağlı");
        await WaitUntil(() => server.ConnectedClients == 1);

        server.SendsToTv = false;
        server.SendSubtitle("Gitmemeli", 4000);
        await Task.Delay(500);
        Assert.DoesNotContain(page.Lines, line => line.StartsWith("diag sub 1", StringComparison.Ordinal));
        Assert.Equal(1, server.ConnectedClients);

        server.SendsToTv = true;
        server.SendSubtitle("Şimdi gelmeli", 4000);
        await page.WaitFor("shown Şimdi gelmeli");
        await page.WaitFor("diag sub 1 ");
        server.Dispose();
    }

    private static async Task WaitUntil(Func<bool> condition, int timeoutMs = 5000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "Koşul zamanında sağlanmadı");
            await Task.Delay(20);
        }
    }

    /// <summary>scripts/tv-live-page.js alt süreci; çıktısı satır satır toplanır.</summary>
    private sealed class TvPage : IDisposable
    {
        private readonly Process process;
        private readonly ConcurrentQueue<string> lines = new();
        public IReadOnlyCollection<string> Lines => lines;

        private TvPage(Process process)
        {
            this.process = process;
            process.OutputDataReceived += (_, e) => { if (e.Data is { } line) lines.Enqueue(line); };
            process.BeginOutputReadLine();
        }

        public static TvPage? Start(out SubtitleServer server)
        {
            server = new SubtitleServer(0);
            var port = server.StartAsync().GetAwaiter().GetResult();
            var script = FindScript();
            var node = FindNode();
            // CI'da Node her zaman vardır: bulunamazsa test sessizce geçmez.
            if (script is null || node is null)
                return Environment.GetEnvironmentVariable("CI") == "true" ? throw new InvalidOperationException("Node ya da scripts/tv-live-page.js bulunamadı") : null;
            var info = new ProcessStartInfo(node)
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                UseShellExecute = false,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
            };
            info.ArgumentList.Add(script);
            info.ArgumentList.Add($"http://127.0.0.1:{port}");
            info.ArgumentList.Add(server.AccessKey);
            return new TvPage(Process.Start(info)!);
        }

        public async Task<string> WaitFor(string prefix, int timeoutMs = 10000)
        {
            var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (true)
            {
                var found = lines.FirstOrDefault(line => line.StartsWith(prefix, StringComparison.Ordinal));
                if (found is not null) return found;
                Assert.True(DateTime.UtcNow < deadline, $"TV sayfası \"{prefix}\" yazmadı. Çıktı:\n{string.Join('\n', lines)}");
                await Task.Delay(25);
            }
        }

        public void Dispose()
        {
            try { process.StandardInput.Close(); } catch (IOException) { }
            if (!process.WaitForExit(3000)) process.Kill();
            process.Dispose();
        }

        private static string? FindScript()
        {
            for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
            {
                var path = Path.Combine(dir.FullName, "scripts", "tv-live-page.js");
                if (File.Exists(path)) return path;
            }
            return null;
        }

        private static string? FindNode()
        {
            var names = OperatingSystem.IsWindows() ? new[] { "node.exe" } : ["node"];
            var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
                .Concat(["/opt/homebrew/bin", "/usr/local/bin"]);
            foreach (var dir in dirs)
            {
                foreach (var name in names)
                {
                    var path = Path.Combine(dir, name);
                    if (File.Exists(path)) return path;
                }
            }
            return null;
        }
    }
}
