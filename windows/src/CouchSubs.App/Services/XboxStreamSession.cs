// SPDX-License-Identifier: AGPL-3.0-only

using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CouchSubs.Core;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace CouchSubs.App.Services;

/// <summary>Receives Xbox WebRTC video in an off-screen WebView2 and passes decoded frames to the normal OCR pipeline.</summary>
internal sealed class XboxStreamSession(XboxBridge bridge, XboxConsole console, string token, Action<string> tokenUpdated, bool legacyFrameRate, bool playAudio) : IStreamSession
{
    // Oynatıcı sayfası yalnız WebRTC el sıkışma komutlarını çağırabilir; giriş ve token dönen komutlar ona kapalı.
    // Canlı tutma isteğini artık uygulama gönderir (bkz. StartKeepalive).
    private static readonly HashSet<string> PlayerCommands = ["sdp", "chatSdp", "ice"];
    private readonly CancellationTokenSource cancel = new();
    private string currentToken = token;
    private Window? window;
    private WebView2? browser;
    private TaskCompletionSource<bool>? browserEnded;
    private bool started;
    private int frameBusy;
    /// <summary>İlk kare gelene kadar anahtar kare isteği ve tanı satırı (bkz. <see cref="XboxFirstFrameWatch"/>).</summary>
    private XboxFirstFrameWatch? watch;
    private DispatcherTimer? watchTimer;
    private long connectedAt;
    private bool keyframeReady;
    /// <summary>Bu WebRTC bağlantısında okumaya giden kare sayısı ve ilk karenin anı (bağlantı bitince özet satırı).</summary>
    private long connectionFrames;
    private long firstFrameAt;
    private CancellationTokenSource? keepaliveCancel;
    /// <summary>
    /// İlk kareden sonra görüntü kesilirse uyarı ve yeniden kurma (bkz. <see cref="XboxPictureWatch"/>). Oynatıcı saniyede
    /// bir video öğesinin yeni kare sayısını (requestVideoFrameCallback) bildirir; donmuş video öğesi kare sayılmaz.
    /// </summary>
    private XboxPictureWatch? pictureWatch;
    private DispatcherTimer? pictureTimer;
    private long pictureCallbacks;

    public event Action<Frame>? FrameReceived;
    public event Action<SessionState>? StateChanged;
    public event Action<RegisteredConsole>? ConsoleMoved { add { } remove { } }

    public void Start()
    {
        if (started) return;
        started = true;
        // Köprü tektir: "Yeniden bağlan" ile kapatılan eski oturumun kapanışı (köprüye "stop") yeni oturumun "start"ından
        // sonra gidip onu kesmesin; yeni oturum eskisinin döngüsü bitince başlar (arayüz iş parçacığında, sırayla).
        var previous = lastRun;
        lastRun = RunAfterAsync(previous);
    }

    /// <summary>Son açılan oturumun döngüsü (bkz. <see cref="Start"/>).</summary>
    private static Task lastRun = Task.CompletedTask;

    private async Task RunAfterAsync(Task previous)
    {
        // Eski döngü köprüden yanıt beklerken takılırsa yeni oturum sonsuza dek beklemez.
        try { await previous.WaitAsync(TimeSpan.FromSeconds(10)); } catch { /* Eski oturumun hatası ya da gecikmesi yenisini durdurmaz. */ }
        if (cancel.IsCancellationRequested) return;
        await RunAsync();
    }

    /// <summary>Yeniden denemeler bitti ya da konsol yayını reddetti; yayın kendiliğinden durdu (kullanıcı durdurmadı).
    /// <see cref="ReconnectNow"/> bundan sonra bir şey yapmaz, uygulama yeni oturum açar (Mac/iPhone XboxStreamSession ile aynı).</summary>
    public bool HasGivenUp => Volatile.Read(ref gaveUp);
    private bool gaveUp;

    /// <summary>
    /// Yeniden deneme kuralları (bkz. <see cref="XboxRetryPlan"/>). Konsol "oyun başka yerde açıldı" deyip yayını keserse
    /// eskiden her 5 sn'de bir yeniden açılıyor, konsol uyarıyı yeniden veriyor ve oyun düşüyordu; üç denemeden sonra
    /// durulur. Xbox'tan hiç görüntü gelmezse iki bağlantıdan sonra durulur.
    /// </summary>
    private readonly XboxRetryPlan retries = new();
    /// <summary>İlk karenin anı (yayın ne kadar sağlıklı sürdü).</summary>
    private long streamingSince;
    private string? endReason;

    private static void Log(string line) => SubtitleLog.Write("[Xbox] " + line);

    /// <summary>Oturum kimliğinin yalnız başı günlüğe yazılır.</summary>
    private static string Mask(string? value) => string.IsNullOrEmpty(value) ? "?" : value.Length <= 8 ? value : value[..8] + "…";

    /// <summary>Konsolun bildirdiği hata ayrıntısı; alan yoksa ya da tüm değerleri boşsa null.</summary>
    private static string? ErrorDetails(JsonElement status)
    {
        if (!status.TryGetProperty("errorDetails", out var details)) return null;
        return details.ValueKind switch
        {
            JsonValueKind.String => string.IsNullOrWhiteSpace(details.GetString()) ? null : details.GetString(),
            JsonValueKind.Object when details.EnumerateObject().Any(p => p.Value.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)
                && !(p.Value.ValueKind == JsonValueKind.String && string.IsNullOrWhiteSpace(p.Value.GetString()))) => details.GetRawText(),
            _ => null,
        };
    }

    private async Task RunAsync()
    {
        Log($"konsol: id {console.Id}, ad {console.Name}, model {console.Model}");
        while (!cancel.IsCancellationRequested)
        {
            string? reason = null;
            var permanent = false;
            // WebRTC bağlandı ama Xbox'tan tek kare gelmeden bitti (Xbox kapattı ya da ilk kare sınırı doldu).
            var noFirstFrame = false;
            try
            {
                StateChanged?.Invoke(SessionState.Connecting);
                await bridge.RestoreAsync(currentToken);
                var startedSession = await bridge.CallAsync("start", new { consoleId = console.Id });
                RememberToken(startedSession);
                Log($"play yanıtı: oturum {Mask(startedSession.TryGetProperty("sessionId", out var sid) ? sid.GetString() : null)}");
                string? lastState = null;
                for (var attempt = 0; attempt < 90 && !cancel.IsCancellationRequested; attempt++)
                {
                    var status = await bridge.CallAsync("status");
                    RememberToken(status);
                    var state = status.TryGetProperty("state", out var value) ? value.GetString() : null;
                    if (state != lastState) Log($"state: {lastState ?? "-"} → {state ?? "?"}");
                    lastState = state;
                    if (status.TryGetProperty("connected", out _)) Log("connect: başarılı");
                    var details = ErrorDetails(status);
                    if (details is not null) Log($"errorDetails: {details}");
                    if (state == "Provisioned") break;
                    if (state == "Failed" || details is not null)
                    {
                        // Konsol yayını kendisi reddetti: yeniden denemek konsolu yeniden tetikler.
                        permanent = true;
                        throw new InvalidOperationException(details ?? Localizer.Current["Couldn't start the Xbox stream"]);
                    }
                    if (attempt == 89) throw new TimeoutException(Localizer.Current["Timed out waiting for the Xbox stream to be ready."]);
                    await Task.Delay(1000, cancel.Token);
                }
                if (cancel.IsCancellationRequested) break;
                await OpenPlayerAsync();
                if (browserEnded is not null) await browserEnded.Task.WaitAsync(cancel.Token);
                if (!cancel.IsCancellationRequested) throw new IOException(endReason ?? Localizer.Current["The Xbox picture connection closed."]);
            }
            catch (OperationCanceledException) when (cancel.IsCancellationRequested) { break; }
            catch (Exception error)
            {
                reason = error.Message;
                Log($"kopma: {reason}");
            }
            finally
            {
                if (browserEnded is not null)
                {
                    var first = Interlocked.Exchange(ref firstFrameAt, 0);
                    noFirstFrame = connectedAt != 0 && first == 0 && !cancel.IsCancellationRequested;
                    Log(XboxStop.Summary(cancel.IsCancellationRequested ? null : reason ?? endReason, Interlocked.Exchange(ref connectionFrames, 0),
                        first == 0 ? null : TimeSpan.FromMilliseconds(Environment.TickCount64 - first)));
                }
                ClosePlayer();
                try { await bridge.CallAsync("stop"); } catch { /* A lost connection has no session to stop. */ }
            }
            if (cancel.IsCancellationRequested) break;
            var since = Interlocked.Exchange(ref streamingSince, 0);
            endReason = null;
            var delay = retries.Failed(permanent, noFirstFrame, since == 0 ? null : Environment.TickCount64 - since, reason);
            if (noFirstFrame)
                Log($"Xbox görüntü göndermedi: bağlantı kuruldu ama tek kare gelmedi ({retries.Failures}. bağlantı; neden: {XboxStop.Shorten(reason)}). " +
                    "Xbox'ta Ayarlar › Cihazlar ve bağlantılar › Uzak özellikler açık mı, Xbox kablolu mu? Tanı satırlarında video bayt 0 ise Xbox hiç görüntü kodlamıyor");
            if (delay is null)
            {
                Log(permanent ? "kalıcı hata: yeniden denenmiyor, yayın durdu"
                    : noFirstFrame ? $"{XboxRetryPlan.MaxNoPictureAttempts} bağlantıda da görüntü gelmedi: yeniden denenmiyor, yayın durdu"
                    : $"{XboxRetryPlan.DelaysMs.Length} deneme bitti: yeniden denenmiyor, yayın durdu");
                Volatile.Write(ref gaveUp, true);
                StateChanged?.Invoke(SessionState.Disconnected(DisconnectKind.Refused, XboxStop.Message(Localizer.Current, reason, noFirstFrame)));
                break;
            }
            Log($"yeniden deneme {retries.Failures}/{XboxRetryPlan.DelaysMs.Length}: {delay / 1000} sn sonra");
            StateChanged?.Invoke(SessionState.Disconnected(DisconnectKind.Other, noFirstFrame ? Localizer.Current[XboxStop.NoPictureRetrying] : reason));
            try { await Task.Delay(delay.Value, cancel.Token); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task OpenPlayerAsync()
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "xbox-bridge");
        if (!File.Exists(Path.Combine(folder, "player.html"))) throw new FileNotFoundException(Localizer.Current["The Xbox player is missing."]);
        browser = new WebView2();
        window = new Window
        {
            Content = browser, Width = 1280, Height = 720, Left = -10000, Top = -10000,
            WindowStartupLocation = WindowStartupLocation.Manual, WindowStyle = WindowStyle.None,
            ShowInTaskbar = false, ShowActivated = false, ResizeMode = ResizeMode.NoResize,
            Title = "CouchSubs Xbox reader",
        };
        browserEnded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        window.Closed += (_, _) => browserEnded?.TrySetResult(true);
        window.Show();
        var profile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "xbox-webview");
        var options = new CoreWebView2EnvironmentOptions("--disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows");
        var environment = await CoreWebView2Environment.CreateAsync(null, profile, options);
        await browser.EnsureCoreWebView2Async(environment);
        browser.CoreWebView2.Settings.IsStatusBarEnabled = false;
        browser.CoreWebView2.Settings.AreDevToolsEnabled = false;
        browser.CoreWebView2.SetVirtualHostNameToFolderMapping("couchsubs-xbox.local", folder, CoreWebView2HostResourceAccessKind.DenyCors);
        try
        {
            await browser.CoreWebView2.Profile.SetPermissionStateAsync(
                CoreWebView2PermissionKind.Autoplay, "https://couchsubs-xbox.local",
                // Her zaman izinli: ses kapalı başlayıp çeviri sürerken açılınca da çalabilsin (susturma sayfadaki ses
                // öğesinde, #871).
                CoreWebView2PermissionState.Allow);
        }
        catch (Exception error)
        {
            // Eski WebView2 çalışma zamanları bu izin türünü desteklemeyebilir; sesi engellemek akışı durdurmamalı.
            Log($"otomatik ses izni ayarlanamadı: {error.Message}");
        }
        browser.CoreWebView2.WebMessageReceived += OnMessage;
        browser.CoreWebView2.NavigationCompleted += (_, result) =>
        {
            try
            {
                if (result.IsSuccess) browser?.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(new { kind = "start", legacyFrameRate, playAudio = playAudioNow }));
                else browserEnded?.TrySetResult(true);
            }
            catch { browserEnded?.TrySetResult(true); }
        };
        browser.CoreWebView2.Navigate("https://couchsubs-xbox.local/player.html");
    }

    private async void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs eventArgs)
    {
        try
        {
            using var document = JsonDocument.Parse(eventArgs.WebMessageAsJson);
            var message = document.RootElement;
            switch (message.GetProperty("kind").GetString())
            {
                case "frame":
                    if (Interlocked.Exchange(ref frameBusy, 1) != 0) return;
                    OfferFrame(message.GetProperty("image").GetString()!);
                    break;
                case "state":
                    var state = message.GetProperty("state").GetString();
                    pictureWatch?.IceChanged(XboxPictureWatch.IceFrom(state), Environment.TickCount64);
                    if (state == "connected" && connectedAt != 0)
                    {
                        // Takılan bağlantı toparlandı: ilk kare saati ve canlı tutma baştan başlatılmaz.
                        Log("WebRTC yeniden bağlandı");
                    }
                    else if (state == "connected")
                    {
                        // Ana ekran "bağlı" demez: görüntü gelene kadar "bağlanıyor" kalır (Android, iPhone ve Mac'teki gibi
                        // ilk karede). Eskiden burada "bağlandı" deniyor, Xbox görüntü göndermeyince ekran bir dakika
                        // "bağlı" görünüp altyazı hiç gelmiyordu.
                        Log("WebRTC bağlandı; ilk kare bekleniyor");
                        StartWatch();
                        StartKeepalive();
                    }
                    else if (state is "disconnected")
                    {
                        // Geçici olabilir (Wi-Fi takılması): oturum bitmez; oynatıcı o anki ağ tanısını da gönderir.
                        Log("WebRTC disconnected: bağlantı takıldı, toparlanması bekleniyor");
                    }
                    else if (state is "closed" or "failed" or "error")
                    {
                        var detail = message.TryGetProperty("detail", out var value) ? value.GetString() : Localizer.Current["The Xbox WebRTC connection was lost"];
                        Log($"WebRTC {state}: {detail}");
                        endReason ??= detail;
                        browserEnded?.TrySetResult(true);
                    }
                    break;
                case "keyframeReady":
                    keyframeReady = true;
                    break;
                case "log":
                    // Oynatıcı sayfasındaki yakalanmamış hata ya da video.play reddi: yayını bitirmez, yalnız yazılır.
                    Log("oynatıcı: " + XboxStop.Shorten(message.TryGetProperty("text", out var logText) ? logText.GetString() : null, 300));
                    break;
                case "firstFrame":
                    if (Interlocked.CompareExchange(ref firstFrameAt, Environment.TickCount64, 0) == 0)
                    {
                        Interlocked.CompareExchange(ref streamingSince, Environment.TickCount64, 0);
                        retries.PictureArrived();
                        StateChanged?.Invoke(SessionState.Streaming);
                    }
                    if (watch is { FrameSeen: false } seen)
                    {
                        seen.FrameArrived();
                        Log(string.Create(System.Globalization.CultureInfo.InvariantCulture,
                            $"ilk kare {message.GetProperty("width").GetInt32()}x{message.GetProperty("height").GetInt32()}, bağlantıdan {(Environment.TickCount64 - connectedAt) / 1000.0:0.0} sn sonra, keyframe isteği {seen.KeyframesRequested}"));
                    }
                    StopWatch();
                    StartPictureWatch();
                    break;
                case "picture":
                    // Oynatıcının saniyelik bildirimi: video öğesine yeni kare geldiyse görüntü akıyor.
                    var callbacks = message.GetProperty("callbacks").GetInt64();
                    if (callbacks > pictureCallbacks) pictureWatch?.FrameArrived(Environment.TickCount64);
                    pictureCallbacks = callbacks;
                    break;
                case "stats":
                    // İlk kare beklenirken saat sorar; görüntü geldikten sonra bağlantı takılınca oynatıcı kendisi gönderir.
                    if (connectedAt == 0) break;
                    var video = message.GetProperty("video");
                    var picture = XboxStreamStats.Picture(video.GetProperty("readyState").GetInt32(), video.GetProperty("width").GetInt32(),
                        video.GetProperty("height").GetInt32(), video.TryGetProperty("visibility", out var visibility) ? visibility.GetString() : null,
                        video.GetProperty("callbacks").GetInt64());
                    Log(XboxStreamStats.Describe(TimeSpan.FromMilliseconds(Environment.TickCount64 - connectedAt),
                        watch?.FrameSeen ?? Interlocked.Read(ref firstFrameAt) != 0, watch?.KeyframesRequested ?? 0, message.GetProperty("stats"), picture));
                    break;
                case "rpc":
                    var id = message.GetProperty("id").GetInt32();
                    var command = message.GetProperty("command").GetString()!;
                    if (!PlayerCommands.Contains(command))
                    {
                        browser?.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(new { kind = "reply", id, error = Localizer.Current["This command isn't allowed."] }));
                        break;
                    }
                    var args = message.TryGetProperty("args", out var parameters) ? (object)parameters.Clone() : null;
                    try
                    {
                        var result = await bridge.CallAsync(command, args);
                        browser?.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(new { kind = "reply", id, value = result }));
                    }
                    catch (Exception error)
                    {
                        browser?.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(new { kind = "reply", id, error = error.Message }));
                    }
                    break;
            }
        }
        catch (Exception error)
        {
            StateChanged?.Invoke(SessionState.Disconnected(DisconnectKind.Other, error.Message));
            browserEnded?.TrySetResult(true);
        }
    }

    /// <summary>
    /// Bağlantıdan sonra 500 ms'de bir: görüntü gelene kadar oynatıcıya anahtar kare isteği ve getStats tanısı sorulur.
    /// Arayüz iş parçacığında çalışır (OnMessage ve WebView2 gibi).
    /// </summary>
    private void StartWatch()
    {
        StopWatch();
        watch = new XboxFirstFrameWatch();
        connectedAt = Environment.TickCount64;
        var view = browser;
        watchTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        watchTimer.Tick += (_, _) =>
        {
            if (watch is null || browser != view || view?.CoreWebView2 is null) { StopWatch(); return; }
            var step = watch.Tick(TimeSpan.FromMilliseconds(Environment.TickCount64 - connectedAt), keyframeReady);
            try
            {
                if (step.RequestKeyframe)
                {
                    if (watch.KeyframesRequested == 1) Log("ilk kare bekleniyor: Xbox'tan anahtar kare isteniyor");
                    view.CoreWebView2.PostWebMessageAsJson("{\"kind\":\"keyframe\"}");
                }
                if (step.LogStats) view.CoreWebView2.PostWebMessageAsJson("{\"kind\":\"stats\"}");
            }
            catch { /* Oynatıcı bu arada kapandı. */ }
            if (step.NoPicture)
            {
                // Xbox ~60 sn sonra kendisi kapatır; beklemeden kapatılır, neden günlükte ve ekranda net olur.
                // Gerekçe yalnız günlüğe girer; ekranda XboxStop.NoPictureRetrying / NoPictureStopped görünür.
                var limit = $"Xbox'tan {(long)XboxFirstFrameWatch.FirstFrameLimit.TotalSeconds} sn içinde görüntü gelmedi";
                Log($"ilk kare sınırı: {limit}; bağlantı kapatılıyor");
                endReason ??= limit;
                StopWatch();
                browserEnded?.TrySetResult(true);
                return;
            }
            if (watch.FrameSeen) StopWatch();
        };
        watchTimer.Start();
    }

    private void StopWatch()
    {
        watchTimer?.Stop();
        watchTimer = null;
    }

    /// <summary>
    /// İlk kareden sonra saniyede bir: görüntü kesildiyse ana ekranda uyarı (TV'deki altyazı temizlenir), uzun sürdüyse
    /// oynatıcı kapatılır ve oturum yeniden denenir. Arayüz iş parçacığında çalışır.
    /// </summary>
    private void StartPictureWatch()
    {
        StopPictureWatch();
        var current = pictureWatch = new XboxPictureWatch();
        current.FrameArrived(Environment.TickCount64);
        var ended = browserEnded;
        pictureTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        pictureTimer.Tick += (_, _) =>
        {
            if (pictureWatch != current || browserEnded != ended) { StopPictureWatch(); return; }
            var verdict = current.Tick(Environment.TickCount64);
            switch (verdict.Kind)
            {
                case XboxPictureVerdictKind.Warn:
                    Log($"görüntü kesildi ({XboxPictureWatch.WarnAfterMs / 1000} sn kare yok ya da bağlantı takıldı); toparlanması bekleniyor");
                    StateChanged?.Invoke(SessionState.Disconnected(DisconnectKind.Other, Localizer.Current["No picture from the Xbox. Reconnecting…"]));
                    break;
                case XboxPictureVerdictKind.Recovered:
                    Log("görüntü yeniden geliyor");
                    StateChanged?.Invoke(SessionState.Streaming);
                    break;
                case XboxPictureVerdictKind.Stalled:
                    Log($"{verdict.Reason}; oturum yeniden kuruluyor");
                    endReason ??= Localizer.Current["No picture from the Xbox. Reconnecting…"];
                    StopPictureWatch();
                    ended?.TrySetResult(true);
                    break;
            }
        };
        pictureTimer.Start();
    }

    private void StopPictureWatch()
    {
        pictureTimer?.Stop();
        pictureTimer = null;
    }

    /// <summary>
    /// Kare arayüz iş parçacığında değil, PS5'teki gibi kare iş parçacığında çözülür ve okuma hattına verilir. Önceden
    /// çözme ve okuma hattına giriş arayüz iş parçacığındaydı: <c>frameBusy</c> hiç dolu görünmüyordu, arayüz
    /// yavaşlayınca kareler WebView2 ileti kuyruğunda birikiyor, saniyeler önceki kare okunuyordu. Bitince oynatıcıya
    /// haber verilir; oynatıcı ancak o zaman yeni kare gönderir.
    /// </summary>
    private void OfferFrame(string data)
    {
        var view = browser;
        _ = Task.Run(() =>
        {
            try
            {
                var comma = data.IndexOf(',');
                if (comma >= 0)
                {
                    var frame = DecodeJpeg(Convert.FromBase64String(data[(comma + 1)..]));
                    Interlocked.Increment(ref connectionFrames);
                    FrameReceived?.Invoke(frame);
                }
            }
            catch
            {
                // Tek bir karenin çözülememesi akışı durdurmaz; sonraki kare okunur.
            }
            finally
            {
                Volatile.Write(ref frameBusy, 0);
                view?.Dispatcher.InvokeAsync(() =>
                {
                    try { if (browser == view) view.CoreWebView2?.PostWebMessageAsJson("{\"kind\":\"frameDone\"}"); }
                    catch { /* Oynatıcı bu arada kapandı. */ }
                });
            }
        });
    }

    private static Frame DecodeJpeg(byte[] bytes)
    {
        using var input = new MemoryStream(bytes);
        var source = new JpegBitmapDecoder(input, BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];
        var converted = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
        var stride = converted.PixelWidth * 4;
        var pixels = new byte[stride * converted.PixelHeight];
        converted.CopyPixels(pixels, stride, 0);
        return new Frame(pixels, converted.PixelWidth, converted.PixelHeight, stride);
    }

    /// <summary>
    /// WebRTC bağlandıktan sonra 30 sn'de bir Xbox oturumunu canlı tutar. Tek başarısız istek yayını kesmez (eskiden
    /// oynatıcıdaki <c>rpc('keepalive').catch(fail)</c> keserdi); ardışık <see cref="XboxKeepalive.MaxFailures"/> hata keser.
    /// </summary>
    private void StartKeepalive()
    {
        keepaliveCancel?.Cancel();
        var stop = keepaliveCancel = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token);
        var ended = browserEnded;
        _ = Task.Run(async () =>
        {
            var keepalive = new XboxKeepalive();
            try
            {
                while (true)
                {
                    await Task.Delay(XboxKeepalive.Interval, stop.Token);
                    try
                    {
                        await bridge.CallAsync("keepalive");
                        if (keepalive.Failures > 0) Log("canlı tutma yeniden yanıt verdi");
                        keepalive.Succeeded();
                    }
                    catch (Exception error) when (!stop.IsCancellationRequested)
                    {
                        var end = keepalive.Failed();
                        Log($"canlı tutma başarısız ({keepalive.Failures}/{XboxKeepalive.MaxFailures}): {XboxStop.Shorten(error.Message)}");
                        if (!end) continue;
                        endReason ??= Localizer.Current["The Xbox stopped answering keep-alive requests."];
                        ended?.TrySetResult(true);
                        return;
                    }
                }
            }
            catch (OperationCanceledException) { /* Bağlantı kapandı. */ }
        });
    }

    private void RememberToken(JsonElement result)
    {
        if (!result.TryGetProperty("userToken", out var refreshed)) return;
        currentToken = refreshed.GetRawText();
        tokenUpdated(currentToken);
    }

    private void ClosePlayer()
    {
        keepaliveCancel?.Cancel();
        keepaliveCancel = null;
        connectedAt = 0;
        StopWatch();
        watch = null;
        StopPictureWatch();
        pictureWatch = null;
        pictureCallbacks = 0;
        keyframeReady = false;
        browserEnded?.TrySetResult(true);
        browserEnded = null;
        window?.Close();
        browser?.Dispose();
        window = null;
        browser = null;
    }

    public void Stop()
    {
        if (cancel.IsCancellationRequested) return;
        cancel.Cancel();
        ClosePlayer();
        StateChanged?.Invoke(SessionState.Disconnected(DisconnectKind.Stopped));
    }

    public void ReconnectNow()
    {
        if (!cancel.IsCancellationRequested) browserEnded?.TrySetResult(true);
    }

    /// <summary>Oyun sesi bu bilgisayarda çalınır; çeviri sürerken <see cref="SetPlayAudio"/> ile değişir.</summary>
    private volatile bool playAudioNow = playAudio;

    /// <summary>
    /// "Xbox sesini bu bilgisayarda çal" çeviri sürerken değişti: oynatıcı sayfasındaki ses öğesi yalnız açılır ya da
    /// kısılır, Xbox'a yeni oturum açılmaz. Eskiden ayar değişince akış kapatılıp hemen yeniden açılıyordu; Xbox eski
    /// oturumu bırakmadan gelen yeni istekte uzaktan oynatma hizmetini başlatamıyor, bağlantı geri gelmiyordu (#871).
    /// </summary>
    public void SetPlayAudio(bool enabled)
    {
        if (playAudioNow == enabled) return;
        playAudioNow = enabled;
        Log(enabled ? "oyun sesi açıldı (ayar, oturum sürüyor)" : "oyun sesi kapatıldı (ayar, oturum sürüyor)");
        var view = browser;
        view?.Dispatcher.InvokeAsync(() =>
        {
            try { if (browser == view) view.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(new { kind = "audio", playAudio = enabled })); }
            catch (Exception error) { Log($"ses ayarı oynatıcıya iletilemedi: {error.Message}"); }
        });
    }

    public void Dispose()
    {
        Stop();
    }
}
