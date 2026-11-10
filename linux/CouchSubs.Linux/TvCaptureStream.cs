// SPDX-License-Identifier: AGPL-3.0-only

using System.Net.Sockets;
using System.Text;
using CouchSubs.Core;
using CouchSubs.Core.LgTv;
using CouchSubs.RemotePlay;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace CouchSubs.Linux;

/// <summary>LG'nin geliştirici oturumunda sunduğu tek kare testini görüntü kaynağı olarak kullanır.</summary>
internal sealed class TvCaptureStream(string host, string devKey) : IStreamSession
{
    internal const int Width = 960;
    internal const int Height = 540;
    private const int FrameBytes = Width * Height;
    private static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(2);
    /// <summary>Bu sürede kare gelmezse bağlantı kapatılıp yeniden kurulur (TV kapandı, ağ koptu…).</summary>
    private static readonly TimeSpan FrameTimeout = TimeSpan.FromSeconds(8);
    /// <summary>Art arda bu kadar boş deneme olursa (TV kare vermiyor) kullanıcıya söylenir.</summary>
    private const int MaxMisses = 10;
    // Araç aynı dosyayı her seferinde kullanır. Yeni oturum, öncekinin SSH kanalını kapatmasını bekler.
    private static readonly SemaphoreSlim CaptureSlot = new(1);
    private readonly CancellationTokenSource stop = new();
    private Task? worker;
    private Task? stopping;
    private bool disposed;

    /// <summary>
    /// TV'de çalışan döngü. Araç her kare için yeniden açılırsa saniyede ~1 kare çıkıyordu; açık tutulup isteğe
    /// "1" (tek kare) yazılınca saniyede ~4 kare çıkıyor (10.11.2026 ölçümü). Araç çıktısını dosyaya tamponlayarak
    /// yazdığı için "complete" satırı geç gelir; kare hazır olduğu, kare dosyasının yeniden tam boyda oluşmasından
    /// anlaşılır. Her kare "F\n" + Y düzlemi (960×540), boş deneme "M\n" olarak akar. Bağlantı kapanınca yazma
    /// hatası (SIGPIPE) döngüyü bitirir ve araç kapatılır.
    /// </summary>
    internal static string CaptureScript(TimeSpan gap) => $$"""
        test -x /usr/bin/vtCaptureTestSuite || exit 127
        killall vtCaptureTestSuite 2>/dev/null
        dir=/tmp/couchsubs-capture
        in=$dir/in
        shot=/tmp/vtCaptureTestIamge.yuv
        mkdir -p $dir
        rm -f $in $shot
        mkfifo $in
        /usr/bin/vtCaptureTestSuite < $in > /dev/null 2>&1 &
        tool=$!
        exec 3>$in
        cleanup() { echo ff >&3 2>/dev/null; exec 3>&-; sleep 1; kill $tool 2>/dev/null; rm -rf $dir $shot; exit 0; }
        trap cleanup INT TERM HUP PIPE
        while kill -0 $tool 2>/dev/null; do
          rm -f $shot
          echo 1 >&3
          tries=0
          got=
          while [ $tries -lt 100 ]; do
            if [ -f $shot ] && [ "$(wc -c < $shot)" -ge 777600 ]; then got=1; break; fi
            tries=$((tries + 1))
            usleep 10000
          done
          if [ -n "$got" ]; then
            printf "F\n" || cleanup
            dd if=$shot bs=960 count=540 2>/dev/null || cleanup
          else
            printf "M\n" || cleanup
          fi
          usleep {{(int)gap.TotalMicroseconds}}
        done
        cleanup
        """.ReplaceLineEndings("\n");

    /// <summary>
    /// Kareler arası bekleme: saniyede ~3,5 kare. Altyazının belirmesiyle ilk karenin gelmesi arasındaki ortalama
    /// bekleme yarım kare süresidir; okuma hattı meşgulken gelen kareleri zaten atlar.
    /// </summary>
    private static readonly TimeSpan CaptureGap = TimeSpan.FromMilliseconds(50);

    public event Action<Frame>? FrameReceived;
    public event Action<SessionState>? StateChanged;
    public event Action<RegisteredConsole>? ConsoleMoved { add { } remove { } }

    public void Start()
    {
        if (worker is null && stopping is null) worker = Task.Run(() => RunAsync(stop.Token));
    }

    public void Stop() => stopping ??= stop.CancelAsync();

    // Bağlantı ve kare hataları kısa aralıklarla kendiliğinden yeniden denenir.
    public void ReconnectNow() { }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Stop();
        _ = DisposeAfterStopAsync();
    }

    private async Task DisposeAfterStopAsync()
    {
        try
        {
            await stopping!;
            if (worker is not null) await worker;
        }
        finally { stop.Dispose(); }
    }

    private async Task RunAsync(CancellationToken token)
    {
        try
        {
            await CaptureSlot.WaitAsync(token);
            try { await CaptureLoopAsync(token); }
            finally { CaptureSlot.Release(); }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    private async Task CaptureLoopAsync(CancellationToken token)
    {
        string? lastError = null;
        while (!token.IsCancellationRequested)
        {
            if (lastError is null) StateChanged?.Invoke(SessionState.Connecting);
            try
            {
                using var keyBytes = new MemoryStream(Encoding.UTF8.GetBytes(devKey));
                using var key = new PrivateKeyFile(keyBytes);
                const string user = "prisoner";
                using var client = new SshClient(new Renci.SshNet.ConnectionInfo(host, DevModeInstaller.Port, user,
                    new PrivateKeyAuthenticationMethod(user, key)) { Timeout = TimeSpan.FromSeconds(6) });
                await client.ConnectAsync(token);
                await StreamFramesAsync(client, token, () => lastError = null);
            }
            catch (Exception error) when (error is IOException or SocketException or SshException or ArgumentException or TimeoutException)
            {
                token.ThrowIfCancellationRequested();
                var detail = error is SshAuthenticationException
                    ? Message("TV geliştirici anahtarını reddetti. Panelden anahtarı yeniden alın.",
                        "The TV refused the developer key. Fetch the key again in the panel.")
                    : error.Message;
                if (detail != lastError)
                {
                    lastError = detail;
                    Log.Write("tv-capture", detail);
                    StateChanged?.Invoke(SessionState.Disconnected(DisconnectKind.Other, detail));
                }
                await Task.Delay(RetryDelay, token);
            }
        }
    }

    /// <summary>
    /// TV'deki döngüyü tek komut olarak başlatır ve akan kareleri okur. Kare gelmezse bekçi komutu iptal eder; kanal
    /// kapanınca okuma biter ve dış döngü yeniden bağlanır.
    /// </summary>
    private async Task StreamFramesAsync(SshClient client, CancellationToken token, Action onFrame)
    {
        using var watchdog = CancellationTokenSource.CreateLinkedTokenSource(token);
        using var command = client.CreateCommand($"sh -s <<'COUCHSUBS'\n{CaptureScript(CaptureGap)}\nCOUCHSUBS\n");
        var running = command.ExecuteAsync(watchdog.Token);
        var output = command.OutputStream;
        var header = new byte[2];
        var connected = false;
        var misses = 0;
        try
        {
            while (!token.IsCancellationRequested)
            {
                watchdog.CancelAfter(FrameTimeout);
                if (!await TryReadExactlyAsync(output, header, watchdog.Token)) break;
                if (header is [(byte)'M', (byte)'\n'])
                {
                    if (++misses >= MaxMisses)
                        throw new IOException(Message("TV test aracı kare vermedi. Oyun görüntüsünün TV'de açık olduğunu kontrol edin.",
                            "The TV test tool produced no frame. Check that the game is visible on the TV."));
                    continue;
                }
                if (header is not [(byte)'F', (byte)'\n']) throw new IOException("Unexpected LG capture stream.");

                var luma = new byte[FrameBytes];
                if (!await TryReadExactlyAsync(output, luma, watchdog.Token)) break;
                misses = 0;
                onFrame();
                if (!connected) StateChanged?.Invoke(SessionState.Streaming);
                connected = true;
                FrameReceived?.Invoke(DecodeLuma(luma));
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            // Bekçi: kare gelmedi; aşağıda zaman aşımı olarak bildirilir.
        }
        finally
        {
            if (!running.IsCompleted) await watchdog.CancelAsync();
            try { await running; } catch (OperationCanceledException) { }
        }
        token.ThrowIfCancellationRequested();
        if (command.ExitStatus == 127)
            throw new IOException(Message("Bu TV yazılımında LG yakalama aracı bulunamadı.", "The LG capture tool is unavailable on this TV firmware."));
        if (watchdog.IsCancellationRequested)
            throw new TimeoutException(Message("TV'den kare gelmiyor; bağlantı yenileniyor.", "No frames from the TV; reconnecting."));
        throw new IOException(Message("TV'deki yakalama döngüsü kapandı; yeniden başlatılıyor.", "The capture loop on the TV stopped; restarting."));
    }

    /// <summary>Akış kapanırsa false (yarım kalan kare atılır).</summary>
    private static async Task<bool> TryReadExactlyAsync(Stream stream, byte[] buffer, CancellationToken token)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(read), token);
            if (count == 0) return false;
            read += count;
        }
        return true;
    }

    /// <summary>Okuma hattının eşikleri 1920×1080'e göre; 960×540 kare 2 kat büyütülür.</summary>
    internal const int Scale = 2;

    /// <summary>TV'nin video aralığı (Y 16–235) tam aralığa (0–255) açılır; beyaz altyazı 235'te kalmaz.</summary>
    private static readonly byte[] FullRange = [.. Enumerable.Range(0, 256).Select(v => (byte)Math.Clamp((int)Math.Round((v - 16) * 255.0 / 219), 0, 255))];

    /// <summary>
    /// NV12'nin Y düzlemini gri BGRA kareye çevirir ve 2 kat büyütür. Gerçek oyunda (10.11.2026) 960×540'ta altyazıların
    /// neredeyse hiçbiri okunmadı; büyütülünce çoğu harfi harfine okundu.
    /// </summary>
    internal static Frame DecodeLuma(ReadOnlySpan<byte> luma)
    {
        if (luma.Length != Width * Height) throw new ArgumentException("Invalid LG capture frame length.", nameof(luma));
        var frame = Frame.Blank(Width * Scale, Height * Scale);
        var pixels = frame.Pixels;
        for (var y = 0; y < Height; y++)
        {
            var row = y * Scale * frame.Stride;
            for (var x = 0; x < Width; x++)
            {
                var value = FullRange[luma[y * Width + x]];
                var offset = row + x * Scale * 4;
                for (var dx = 0; dx < Scale * 4; dx += 4)
                {
                    pixels[offset + dx] = pixels[offset + dx + 1] = pixels[offset + dx + 2] = value;
                    pixels[offset + dx + 3] = 255;
                }
            }
            for (var dy = 1; dy < Scale; dy++) Array.Copy(pixels, row, pixels, row + dy * frame.Stride, frame.Stride);
        }
        return frame;
    }

    private static string Message(string tr, string en) => Program.Text.Language == "tr" ? tr : en;
}
