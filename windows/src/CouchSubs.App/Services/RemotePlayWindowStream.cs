// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using CouchSubs.Core;
using CouchSubs.RemotePlay;
using CouchSubs.Shell;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;

namespace CouchSubs.App.Services;

/// <summary>
/// Görüntüyü PS5'e bağlanmadan, bu bilgisayarda açık olan Remote Play penceresinden alır (Windows.Graphics.Capture):
/// Sony'nin PS Remote Play'i ya da açık kaynak chiaki-ng (bkz. <see cref="RemotePlayApp"/>). Oyun o uygulamada oynanır
/// ya da izlenir; CouchSubs PS5'e ikinci bir Remote Play oturumu açmadığı için ikinci hesap gerekmez. Yalnız o pencere
/// yakalanır: üstündeki altyazı penceremiz okunmaz. Kareler <see cref="StreamSession"/>'ınkiler gibi
/// <see cref="FrameReceived"/> ile gelir; okuma hattının geri kalanı aynıdır (Mac'teki RemotePlayWindowStream'in karşılığı).
/// </summary>
public sealed class RemotePlayWindowStream : IStreamSession, IWindowCaptureSession
{
    /// <summary>En çok saniyedeki kare (<see cref="FrameCadence"/>; işlemci doluysa ve okuma yavaşsa daha az).</summary>
    private const int FramesPerSecond = FrameCadence.MaxFramesPerSecond;
    /// <summary>Remote Play'in küçük pencereleri (giriş, denetim) oyun penceresi sanılmasın.</summary>
    private const int MinimumWidth = 400, MinimumHeight = 250;
    private static readonly TimeSpan SearchInterval = TimeSpan.FromSeconds(2);
    /// <summary>Bu kadar ardışık kare simsiyah gelirse uygulama ekran yakalamayı engelliyor olabilir; bir kez uyarılır.</summary>
    private const int BlackFramesBeforeWarning = FramesPerSecond * 4;

    private static readonly string[] SonyProcesses = ["RemotePlay"];
    private static readonly string[] ChiakiProcesses = ["chiaki", "chiaki-ng"];

    public event Action<Frame>? FrameReceived;
    public event Action<SessionState>? StateChanged;
    /// <summary>Bu kaynakta PS5'in adresi bilinmez; hiç çağrılmaz.</summary>
    public event Action<RegisteredConsole>? ConsoleMoved { add { } remove { } }

    private readonly RemotePlayApp app;
    private readonly WindowCaptureTarget? selectedWindow;
    private readonly string[] processNames;
    private readonly object gate = new();
    private int generation;
    private bool running;
    private CancellationTokenSource? search;
    private Capture? capture;
    public IntPtr CapturedWindowHandle { get { lock (gate) return capture?.Window ?? IntPtr.Zero; } }
    private SessionState? reported;
    /// <summary>Karelerin kopyalanma sıklığı; okuma hattı kendi örneğini verir (<see cref="UseCadence"/>).</summary>
    private FrameCadence cadence = new();
    private readonly SystemCpuLoad cpu = new();

    public void UseCadence(FrameCadence value) => cadence = value;

    public RemotePlayWindowStream(RemotePlayApp app)
    {
        this.app = app;
        processNames = app switch
        {
            RemotePlayApp.Sony => SonyProcesses,
            RemotePlayApp.Chiaki => ChiakiProcesses,
            _ => [.. SonyProcesses, .. ChiakiProcesses],
        };
    }

    /// <summary>OBS veya oyun penceresi kullanıcı tarafından seçildi: uygulama açılmaz, tam ekran yakalanmaz.</summary>
    public RemotePlayWindowStream(WindowCaptureTarget target)
    {
        if (string.IsNullOrWhiteSpace(target.ProcessName) || string.IsNullOrWhiteSpace(target.Title))
            throw new ArgumentException("A process and window title must be selected.", nameof(target));
        app = RemotePlayApp.Automatic;
        selectedWindow = target;
        processNames = [target.ProcessName];
    }

    public void Start()
    {
        int current;
        lock (gate)
        {
            running = true;
            current = ++generation;
            reported = null;
        }
        Report(SessionState.Connecting);
        if (selectedWindow is null) OpenIfNeeded();
        StartSearch(current);
    }

    public void Stop()
    {
        lock (gate)
        {
            running = false;
            generation++;
        }
        TearDown();
        Report(SessionState.Disconnected(DisconnectKind.Stopped));
    }

    /// <summary>Uykudan uyanınca ya da ağ değişince yakalama baştan kurulur.</summary>
    public void ReconnectNow()
    {
        int current;
        lock (gate)
        {
            if (!running) return;
            current = ++generation;
        }
        TearDown();
        Report(SessionState.Connecting);
        StartSearch(current);
    }

    public void Dispose() => Stop();

    private bool IsCurrent(int number)
    {
        lock (gate) return running && generation == number;
    }

    /// <summary>Aynı durum yeniden bildirilmez (her "bağlantı yok" bildirimi okuma hattını sıfırlıyor).</summary>
    private void Report(SessionState state)
    {
        lock (gate)
        {
            if (reported == state) return;
            reported = state;
        }
        StateChanged?.Invoke(state);
    }

    private void TearDown()
    {
        CancellationTokenSource? oldSearch;
        Capture? oldCapture;
        lock (gate)
        {
            oldSearch = search;
            oldCapture = capture;
            search = null;
            capture = null;
        }
        oldSearch?.Cancel();
        oldCapture?.Dispose();
    }

    // --- Pencereyi bulma ---

    private void StartSearch(int number)
    {
        var token = new CancellationTokenSource();
        CancellationTokenSource? old;
        lock (gate)
        {
            old = search;
            search = token;
        }
        old?.Cancel();
        _ = Task.Run(async () =>
        {
            var noted = false;
            while (!token.IsCancellationRequested && IsCurrent(number))
            {
                var window = FindGameWindow(processNames, selectedWindow?.Title);
                if (window != IntPtr.Zero)
                {
                    try
                    {
                        var started = new Capture(window, this, number);
                        bool kept;
                        lock (gate)
                        {
                            kept = running && generation == number;
                            if (kept) capture = started;
                        }
                        if (!kept)
                        {
                            started.Dispose();
                            return;
                        }
                        RemotePlayLog.Note($"{started.Name} penceresi okunuyor: {started.Width}x{started.Height}");
                        Report(SessionState.Streaming);
                        return;
                    }
                    catch (Exception error)
                    {
                        RemotePlayLog.Note($"Remote Play penceresi yakalanamadı: {error.GetType().Name}: {error.Message}");
                        Report(SessionState.Disconnected(DisconnectKind.Other, error.Message));
                    }
                }
                else
                {
                    if (!noted)
                    {
                        RemotePlayLog.Note(selectedWindow is { } target
                            ? $"Seçilen pencere bekleniyor: {target.ProcessName} / {target.Title}"
                            : "Remote Play penceresi bekleniyor (PS Remote Play ya da chiaki-ng)");
                        noted = true;
                    }
                    Report(SessionState.Connecting);
                }
                try { await Task.Delay(SearchInterval, token.Token); } catch (TaskCanceledException) { return; }
            }
        });
    }

    /// <summary>Pencere kapandı ya da yakalama düştü: pencere yeniden aranır (çeviri durmaz).</summary>
    private void CaptureEnded(Capture ended, int number, string why)
    {
        int current;
        lock (gate)
        {
            if (!running || generation != number || capture != ended) return;
            capture = null;
            current = ++generation;
        }
        ended.Dispose();
        RemotePlayLog.Note($"Remote Play penceresi kapandı: {why}");
        Report(SessionState.Connecting);
        StartSearch(current);
    }

    private void Deliver(Frame frame) => FrameReceived?.Invoke(frame);

    private void BlackWarning(bool black)
    {
        if (black)
            Report(SessionState.Disconnected(DisconnectKind.Other,
                selectedWindow is not null
                    ? Localizer.Current["The selected window is black. Check the OBS projector or game window."]
                    : Localizer.Current["The Remote Play window comes through black: this app may block screen capture. Try chiaki-ng."]));
        else
            Report(SessionState.Streaming);
    }

    /// <summary>Seçilen uygulamaların en büyük, görünür, simge durumunda olmayan üst düzey penceresi.</summary>
    private static IntPtr FindGameWindow(string[] names, string? selectedTitle = null)
    {
        var processes = new Dictionary<uint, bool>();
        var best = IntPtr.Zero;
        long bestArea = 0;
        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd) || Native.GetWindow(hwnd, Native.GwOwner) != IntPtr.Zero) return true;
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (!processes.TryGetValue(pid, out var wanted))
            {
                try
                {
                    using var process = Process.GetProcessById((int)pid);
                    wanted = names.Any(name => string.Equals(process.ProcessName, name, StringComparison.OrdinalIgnoreCase));
                }
                catch (Exception) { wanted = false; }
                processes[pid] = wanted;
            }
            if (!wanted || (selectedTitle is not null && (pid == Environment.ProcessId || WindowTitle(hwnd) != selectedTitle))
                || !Native.GetWindowRect(hwnd, out var rect)) return true;
            var (width, height) = (rect.Right - rect.Left, rect.Bottom - rect.Top);
            if (width < MinimumWidth || height < MinimumHeight) return true;
            var area = (long)width * height;
            if (area > bestArea)
            {
                bestArea = area;
                best = hwnd;
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    internal static (int Left, int Top, int Right, int Bottom)? OverlayTargetBounds(IntPtr window)
    {
        return window != IntPtr.Zero && Native.GetWindowRect(window, out var rect)
            ? (rect.Left, rect.Top, rect.Right, rect.Bottom) : null;
    }

    /// <summary>Yalnız kullanıcıya görünür ve uygulamanın kendisine ait olmayan pencereler seçilebilir.</summary>
    public static IReadOnlyList<WindowCaptureTarget> ListCaptureWindows()
    {
        var windows = new List<WindowCaptureTarget>();
        Native.EnumWindows((hwnd, _) =>
        {
            if (!Native.IsWindowVisible(hwnd) || Native.IsIconic(hwnd) || Native.GetWindow(hwnd, Native.GwOwner) != IntPtr.Zero
                || !Native.GetWindowRect(hwnd, out var rect)
                || rect.Right - rect.Left < MinimumWidth || rect.Bottom - rect.Top < MinimumHeight) return true;
            Native.GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == Environment.ProcessId) return true; // CouchSubs altyazı penceresini seçip geri besleme oluşturma.
            var title = WindowTitle(hwnd);
            if (title.Length == 0) return true;
            try
            {
                using var process = Process.GetProcessById((int)pid);
                windows.Add(new WindowCaptureTarget(process.ProcessName, title));
            }
            catch (Exception) { /* Süreç arama sırasında kapanmış olabilir. */ }
            return true;
        }, IntPtr.Zero);
        return [.. windows.Distinct().OrderBy(w => w.ProcessName).ThenBy(w => w.Title)];
    }

    private static string WindowTitle(IntPtr window)
    {
        var length = Native.GetWindowTextLength(window);
        if (length <= 0) return "";
        var buffer = new StringBuilder(Math.Min(length + 1, 1025));
        Native.GetWindowText(window, buffer, buffer.Capacity);
        return buffer.ToString().Trim();
    }

    /// <summary>Seçilen uygulamalardan hiçbiri açık değilse kurulu olan ilki açılır.</summary>
    private void OpenIfNeeded()
    {
        if (processNames.Any(name => Process.GetProcessesByName(name).Length > 0)) return;
        var path = InstalledPath(app);
        if (path is null) return;
        try
        {
            RemotePlayLog.Note($"{Path.GetFileNameWithoutExtension(path)} açılıyor");
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(path) })?.Dispose();
        }
        catch (Exception error)
        {
            RemotePlayLog.Note($"Remote Play açılamadı: {error.Message}");
        }
    }

    /// <summary>Seçilen Remote Play uygulaması bu bilgisayarda kurulu mu ("hangisi açıksa"da ikisinden biri yeter).</summary>
    public static bool IsInstalled(RemotePlayApp app) => InstalledPath(app) is not null;

    /// <summary>Seçilen uygulamanın kurulu yolu ("hangisi açıksa"da Sony önce); kurulu değilse null.</summary>
    internal static string? InstalledPath(RemotePlayApp app)
    {
        var candidates = new List<string>();
        var x86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var x64 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (app != RemotePlayApp.Chiaki)
        {
            candidates.Add(Path.Combine(x86, "Sony", "PS Remote Play", "RemotePlay.exe"));
            candidates.Add(Path.Combine(x64, "Sony", "PS Remote Play", "RemotePlay.exe"));
        }
        if (app != RemotePlayApp.Sony)
        {
            foreach (var root in new[] { x64, x86, Path.Combine(local, "Programs") })
            {
                candidates.Add(Path.Combine(root, "chiaki-ng", "chiaki.exe"));
                candidates.Add(Path.Combine(root, "chiaki-ng", "chiaki-ng.exe"));
            }
        }
        return candidates.FirstOrDefault(File.Exists);
    }

    /// <summary>Bir pencerenin yakalanması: Direct3D aygıtı, kare havuzu ve oturum. Kareler saniyede en çok
    /// <see cref="FramesPerSecond"/> kez (işlemci doluysa ve okuma yavaşsa daha seyrek, bkz. <see cref="FrameCadence"/>)
    /// işlemciye kopyalanıp BGRA <see cref="Frame"/> olarak verilir.</summary>
    private sealed class Capture : IDisposable
    {
        private readonly RemotePlayWindowStream owner;
        private readonly int number;
        private readonly IDirect3DDevice device;
        private readonly GraphicsCaptureItem item;
        private readonly Direct3D11CaptureFramePool pool;
        private readonly GraphicsCaptureSession session;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private int busy;
        /// <summary>
        /// Sıklık sınırına takılan son kare (havuzdan bir tampon). Görüntü durunca Windows yeni kare göndermez: altyazı
        /// belirirken gelen son kare atılsaydı yeni satır kamera oynayana dek okunmazdı (#1019). Sınır dolunca o okunur.
        /// </summary>
        private Direct3D11CaptureFrame? held;
        private readonly object heldGate = new();
        private readonly System.Threading.Timer trailingTimer;
        private int blackFrames;
        private bool warnedBlack;
        private Windows.Graphics.SizeInt32 size;
        /// <summary>Kare ve zamanlayıcı iş parçacıklarından okunur.</summary>
        private volatile bool disposed;
        /// <summary>Bu iş parçacığı şu an bir kareyi kopyalıyor ya da dağıtıyor (kapatma kendi kendini beklemesin).</summary>
        [ThreadStatic] private static bool deliveringFrame;
        /// <summary>Kapatma sırasında PrintWindow çağrısı hâlâ sürüyordu: DIB'i çağrı bitince o bırakır.</summary>
        private PrintWindowGrabber? abandonedGrabber;
        /// <summary>Kare gelmiyor ya da kopyalanamıyorsa nedeni altyazi.log'a yazılır (GitHub #566).</summary>
        private readonly WindowCaptureWatch watch = new();
        private readonly System.Threading.Timer watchTimer;
        /// <summary>Dakikada bir "pencere kareleri: N/dk" yazılır: kare aralığı günlükte görünsün (GitHub #822, Mac ile aynı).</summary>
        private readonly WindowFrameCounts counts = new();
        private readonly System.Threading.Timer minuteTimer;
        private readonly IntPtr window;
        /// <summary>Windows'un yakalaması kare vermedi; pencere PrintWindow ile okunuyor (GitHub #566).</summary>
        private volatile bool fallback;
        private System.Threading.Timer? fallbackTimer;
        private PrintWindowGrabber? grabber;
        private int fallbackBusy;
        private bool fallbackFailureNoted;

        public string Name { get; }
        public IntPtr Window => window;
        public int Width => size.Width;
        public int Height => size.Height;

        public Capture(IntPtr window, RemotePlayWindowStream owner, int number)
        {
            this.owner = owner;
            this.number = number;
            this.window = window;
            Native.GetWindowThreadProcessId(window, out var pid);
            try
            {
                using var process = Process.GetProcessById((int)pid);
                Name = process.ProcessName;
            }
            catch (Exception) { Name = "Remote Play"; }
            trailingTimer = new System.Threading.Timer(_ => DeliverHeld(), null, Timeout.Infinite, Timeout.Infinite);
            device = Direct3D.CreateDevice();
            item = CaptureInterop.CreateItemForWindow(window);
            size = item.Size;
            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, PoolFrames, size);
            session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = false;
            HideCaptureBorder(session);
            item.Closed += (_, _) => owner.CaptureEnded(this, number, "pencere kapandı");
            pool.FrameArrived += OnFrameArrived;
            session.StartCapture();
            SubtitleLog.Write($"pencere yakalanıyor: {Name}, {size.Width}x{size.Height}");
            watchTimer = new System.Threading.Timer(_ => CheckFrames(), null, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(1));
            minuteTimer = new System.Threading.Timer(_ => { if (!disposed) SubtitleLog.Write(counts.MinuteLine()); },
                null, TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));
        }

        /// <summary>Yakalama başladı ama okumaya kare gitmiyorsa nedeni iki günlüğe de yazılır.</summary>
        private void CheckFrames()
        {
            if (disposed || watch.Delivered)
            {
                watchTimer.Change(Timeout.Infinite, Timeout.Infinite);
                return;
            }
            if (watch.Tick(clock.Elapsed) is { } note)
            {
                RemotePlayLog.Note($"{Name}: {note}");
                SubtitleLog.Write(note);
            }
            if (!fallback && watch.ShouldFallBack(clock.Elapsed)) StartFallback();
        }

        /// <summary>
        /// Windows.Graphics.Capture okumaya kare vermedi (bazı Windows 10 bilgisayarlarda hiç kare gelmiyor, #566): pencere
        /// saniyede beş kez PrintWindow (PW_RENDERFULLCONTENT) ile okunur. Üstteki altyazı penceremiz bu yolla da okunmaz.
        /// </summary>
        private void StartFallback()
        {
            lock (this)
            {
                if (fallback || disposed) return;
                fallback = true;
                grabber = new PrintWindowGrabber();
                fallbackTimer = new System.Threading.Timer(_ => GrabFallback(), null, TimeSpan.Zero, TimeSpan.FromMilliseconds(1000 / FallbackFramesPerSecond));
            }
            const string text = "Windows pencereden kare vermiyor; pencere yedek yolla (PrintWindow) okunuyor";
            RemotePlayLog.Note($"{Name}: {text}");
            SubtitleLog.Write(text);
        }

        private const int FallbackFramesPerSecond = 5;

        private void GrabFallback()
        {
            if (disposed || Interlocked.Exchange(ref fallbackBusy, 1) == 1) return;
            deliveringFrame = true;
            try
            {
                if (!Native.IsWindow(window))
                {
                    // Bu iş parçacığı bırakılınca kapatılır (Dispose süren çağrının bitmesini bekler).
                    _ = Task.Run(() => owner.CaptureEnded(this, number, "pencere kapandı"));
                    return;
                }
                // Simge durumundaki pencere çizilemez; açılınca okuma kendiliğinden sürer.
                if (Native.IsIconic(window) || grabber is not { } current) return;
                if (current.Grab(window) is not { } frame)
                {
                    if (!fallbackFailureNoted)
                    {
                        fallbackFailureNoted = true;
                        RemotePlayLog.Note($"{Name}: PrintWindow pencereyi çizemedi");
                        SubtitleLog.Write("yedek yakalama: PrintWindow pencereyi çizemedi");
                    }
                    return;
                }
                CheckBlack(frame.Pixels);
                if (watch.FrameDelivered()) SubtitleLog.Write($"pencereden ilk kare (PrintWindow): {frame.Width}x{frame.Height}");
                counts.Fallback();
                owner.Deliver(frame);
            }
            catch (Exception error)
            {
                if (!fallbackFailureNoted)
                {
                    fallbackFailureNoted = true;
                    RemotePlayLog.Note($"{Name}: yedek yakalama hatası: {error.GetType().Name}: {error.Message}");
                    SubtitleLog.Write($"yedek yakalama hatası: {error.GetType().Name}: {error.Message}");
                }
            }
            finally
            {
                deliveringFrame = false;
                Volatile.Write(ref fallbackBusy, 0);
                // Kapatma bu çağrıyı bekleyemediyse DIB burada, artık kimse kullanmazken bırakılır.
                Interlocked.Exchange(ref abandonedGrabber, null)?.Dispose();
            }
        }

        /// <summary>Windows yakalanan pencerenin çevresine sarı bir çerçeve çizer. Destekleyen sürümlerde (Windows 11;
        /// Windows 10'da yalnız Server 2022, 20348+) çerçevesiz yakalama izni istenip çerçeve kapatılır. Windows 10'un ev
        /// sürümlerinde (22H2 dahil, 19045) Windows çerçeveyi kapatmaya izin vermez; yakalama yine sürer. Çerçeve neden
        /// kaldıysa günlüğe bir kez yazılır (GitHub #224).</summary>
        private static void HideCaptureBorder(GraphicsCaptureSession session)
        {
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348) ||
                !Windows.Foundation.Metadata.ApiInformation.IsPropertyPresent("Windows.Graphics.Capture.GraphicsCaptureSession", "IsBorderRequired"))
            {
                NoteBorderOnce($"sarı yakalama çerçevesi kapatılamıyor: Windows {Environment.OSVersion.Version} bunu desteklemiyor (Windows 11 gerekir)");
                return;
            }
            try
            {
                var access = GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless).AsTask().GetAwaiter().GetResult();
                if (access != Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus.Allowed)
                {
                    // Windows 11'de "Ayarlar › Gizlilik ve güvenlik › Ekran görüntüsü kenarlıkları" kapalıysa izin gelmez.
                    NoteBorderOnce($"sarı yakalama çerçevesi kapatılamadı: Windows çerçevesiz yakalamaya izin vermedi ({access})");
                    return;
                }
                session.IsBorderRequired = false;
            }
            catch (Exception error)
            {
                // İzin verilmezse çerçeve kalır; yakalama sürer.
                NoteBorderOnce($"sarı yakalama çerçevesi kapatılamadı: {error.GetType().Name}: {error.Message}");
            }
        }

        private static int borderNoted;

        private static void NoteBorderOnce(string text)
        {
            if (Interlocked.Exchange(ref borderNoted, 1) == 0) RemotePlayLog.Note(text);
        }

        /// <summary>Havuzdaki kare tamponu: biri sıklık sınırında tutulurken Windows öbürlerine çizer.</summary>
        private const int PoolFrames = 3;

        private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
        {
            if (disposed) return;
            var frame = sender.TryGetNextFrame();
            if (frame is null) return;
            // Yedek yakalamaya geçildiyse aynı kare iki yoldan verilmez.
            if (disposed || fallback)
            {
                frame.Dispose();
                return;
            }
            watch.Arrived();
            if (frame.ContentSize.Width != size.Width || frame.ContentSize.Height != size.Height)
            {
                // Pencere büyütüldü ya da tam ekrana geçti: havuz yeni boya kurulur, bu kare atlanır.
                size = frame.ContentSize;
                frame.Dispose();
                Release(TakeHeld());
                if (size.Width > 0 && size.Height > 0) pool.Recreate(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, PoolFrames, size);
                return;
            }
            owner.cpu.Report(owner.cadence);
            // Önceki kare hâlâ kopyalanıyorsa ya da sıklık sınırı dolmadıysa kare kopyalanmaz; son kare tutulur, sınır
            // dolunca okunur (görüntü durduysa yeni kare gelmez).
            if (Volatile.Read(ref busy) == 1 || !owner.cadence.Admit(Environment.TickCount64))
            {
                counts.Idle();
                Hold(frame);
                return;
            }
            Release(TakeHeld());
            Copy(frame);
        }

        /// <summary>Kareyi tutar (öncekini havuza bırakır) ve sıklık sınırı dolunca okunmasını zamanlar.</summary>
        private void Hold(Direct3D11CaptureFrame frame)
        {
            Direct3D11CaptureFrame? previous;
            lock (heldGate)
            {
                if (disposed)
                {
                    frame.Dispose();
                    return;
                }
                previous = held;
                held = frame;
            }
            Release(previous);
            try { trailingTimer.Change(owner.cadence.IntervalMs, Timeout.Infinite); } catch (ObjectDisposedException) { }
        }

        private Direct3D11CaptureFrame? TakeHeld()
        {
            lock (heldGate)
            {
                var frame = held;
                held = null;
                return frame;
            }
        }

        private static void Release(Direct3D11CaptureFrame? frame)
        {
            try { frame?.Dispose(); } catch (Exception) { }
        }

        /// <summary>Sıklık sınırı doldu ve bu arada yeni kare kopyalanmadı: tutulan son kare okunur.</summary>
        private void DeliverHeld()
        {
            if (disposed || fallback) return;
            if (Volatile.Read(ref busy) == 1 || !owner.cadence.Admit(Environment.TickCount64))
            {
                // Kopya sürüyor ya da sınır henüz dolmadı: biraz sonra yeniden denenir.
                lock (heldGate) if (held is null) return;
                try { trailingTimer.Change(owner.cadence.IntervalMs, Timeout.Infinite); } catch (ObjectDisposedException) { }
                return;
            }
            if (TakeHeld() is { } frame) Copy(frame);
        }

        /// <summary>Kareyi işlemciye kopyalayıp okumaya verir; kare havuza bırakılır.</summary>
        private void Copy(Direct3D11CaptureFrame frame)
        {
            // Önceki kare hâlâ kopyalanıyorsa bu kare atlanır.
            if (Interlocked.Exchange(ref busy, 1) == 1)
            {
                Release(frame);
                counts.Idle();
                return;
            }
            watch.CopyStarted(clock.Elapsed);
            deliveringFrame = true;
            try
            {
                Frame captured;
                using (frame)
                {
                    if (disposed) return;
                    using var bitmap = SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Premultiplied).AsTask().GetAwaiter().GetResult();
                    var (width, height) = (bitmap.PixelWidth, bitmap.PixelHeight);
                    if (width < 2 || height < 2) return;
                    captured = BitmapPixels.Read(bitmap);
                }
                watch.CopyEnded();
                CheckBlack(captured.Pixels);
                if (watch.FrameDelivered()) SubtitleLog.Write($"pencereden ilk kare: {captured.Width}x{captured.Height}");
                counts.Delivered();
                owner.Deliver(captured);
            }
            catch (Exception error)
            {
                var text = $"{error.GetType().Name}: {error.Message}";
                RemotePlayLog.Note($"Remote Play karesi kopyalanamadı: {text}");
                if (watch.Failed(text)) SubtitleLog.Write($"pencere karesi kopyalanamadı: {text}");
            }
            finally
            {
                watch.CopyEnded();
                deliveringFrame = false;
                Volatile.Write(ref busy, 0);
            }
        }

        /// <summary>Bazı uygulamalar penceresinin yakalanmasını engeller; o zaman kareler simsiyah gelir.</summary>
        private void CheckBlack(byte[] pixels)
        {
            var black = true;
            for (var i = 0; i < pixels.Length && black; i += 4 * 997)
                black = pixels[i] < 10 && pixels[i + 1] < 10 && pixels[i + 2] < 10;
            if (black)
            {
                if (++blackFrames == BlackFramesBeforeWarning && !warnedBlack)
                {
                    warnedBlack = true;
                    RemotePlayLog.Note($"{Name} penceresi siyah geliyor: ekran yakalama engelleniyor olabilir");
                    owner.BlackWarning(true);
                }
            }
            else
            {
                blackFrames = 0;
                if (warnedBlack)
                {
                    warnedBlack = false;
                    owner.BlackWarning(false);
                }
            }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { watchTimer.Dispose(); } catch (Exception) { }
            try { minuteTimer.Dispose(); } catch (Exception) { }
            try { trailingTimer.Dispose(); } catch (Exception) { }
            lock (this)
            {
                try { fallbackTimer?.Dispose(); } catch (Exception) { }
                fallbackTimer = null;
            }
            // Süren PrintWindow çağrısı bitince DIB bırakılır (GrabFallback aynı anda onu kullanıyor olabilir). Hedef pencere
            // yanıt vermiyorsa çağrı bir saniyeden uzun sürebilir: eskiden DIB yine de bırakılıyordu, biten çağrı
            // bırakılmış belleği kopyalayabiliyordu (erişim ihlali). Şimdi DIB'i süren çağrı kendi bitince bırakır.
            var lastGrabber = Interlocked.Exchange(ref grabber, null);
            if (lastGrabber is not null)
            {
                if (WaitWhile(ref fallbackBusy)) lastGrabber.Dispose();
                else
                {
                    Volatile.Write(ref abandonedGrabber, lastGrabber);
                    if (Volatile.Read(ref fallbackBusy) == 0) Interlocked.Exchange(ref abandonedGrabber, null)?.Dispose();
                }
            }
            // Süren kare kopyası Direct3D aygıtını ve kare havuzunu kullanır; onlar kopya bitmeden kapatılmaz.
            try { pool.FrameArrived -= OnFrameArrived; } catch (Exception) { }
            WaitWhile(ref busy);
            Release(TakeHeld());
            try { session.Dispose(); } catch (Exception) { }
            try { pool.Dispose(); } catch (Exception) { }
            try { device.Dispose(); } catch (Exception) { }
        }

        /// <summary>Süren kare işi bitene kadar (en çok bir saniye) bekler; bittiyse true. Kapatma kare işinin kendi iş
        /// parçacığından geldiyse (okuma hattı kareyi alırken oturumu durdurdu) beklenmez.</summary>
        private static bool WaitWhile(ref int flag)
        {
            if (deliveringFrame) return Volatile.Read(ref flag) == 0;
            var spins = 0;
            while (Volatile.Read(ref flag) == 1 && spins++ < 100) Thread.Sleep(10);
            return Volatile.Read(ref flag) == 0;
        }
    }

    /// <summary>
    /// Yedek yakalama: pencere PrintWindow(PW_RENDERFULLCONTENT) ile bellekteki bir DIB'e çizdirilir. Direct3D/OpenGL ile
    /// çizen pencereler (OBS projektörü, Remote Play) de bu bayrakla çizilir; çizilemezse kare simsiyah gelir ve siyah kare
    /// uyarısı çıkar. DIB boyut değişmedikçe yeniden kullanılır. Tek iş parçacığından çağrılır.
    /// </summary>
    private sealed class PrintWindowGrabber : IDisposable
    {
        private const uint RenderFullContent = 2; // PW_RENDERFULLCONTENT (Windows 8.1+)
        private IntPtr memoryDc;
        private IntPtr bitmap;
        private IntPtr oldBitmap;
        private IntPtr bits;
        private int width, height;

        /// <summary>Pencerenin (çerçevesiyle, Windows.Graphics.Capture'daki gibi) BGRA karesi; çizilemezse null.</summary>
        public Frame? Grab(IntPtr window)
        {
            if (!Native.GetWindowRect(window, out var rect)) return null;
            var (w, h) = (rect.Right - rect.Left, rect.Bottom - rect.Top);
            if (w < 2 || h < 2) return null;
            if (w != width || h != height || bitmap == IntPtr.Zero)
            {
                Release();
                if (!Allocate(w, h)) return null;
            }
            if (!Gdi.PrintWindow(window, memoryDc, RenderFullContent)) return null;
            var pixels = new byte[w * h * 4];
            Marshal.Copy(bits, pixels, 0, pixels.Length);
            // GDI alfa kanalını doldurmaz (0 kalır); okuma opak kare bekler.
            for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
            return new Frame(pixels, w, h, w * 4);
        }

        private bool Allocate(int w, int h)
        {
            var screen = Gdi.GetDC(IntPtr.Zero);
            try
            {
                memoryDc = Gdi.CreateCompatibleDC(screen);
                if (memoryDc == IntPtr.Zero) return false;
                var info = new Gdi.BitmapInfoHeader
                {
                    Size = (uint)Marshal.SizeOf<Gdi.BitmapInfoHeader>(),
                    Width = w,
                    Height = -h, // üstten alta
                    Planes = 1,
                    BitCount = 32,
                    Compression = 0, // BI_RGB
                };
                bitmap = Gdi.CreateDIBSection(screen, ref info, 0, out bits, IntPtr.Zero, 0);
                if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
                {
                    Release();
                    return false;
                }
                oldBitmap = Gdi.SelectObject(memoryDc, bitmap);
                (width, height) = (w, h);
                return true;
            }
            finally
            {
                Gdi.ReleaseDC(IntPtr.Zero, screen);
            }
        }

        private void Release()
        {
            if (memoryDc != IntPtr.Zero && oldBitmap != IntPtr.Zero) Gdi.SelectObject(memoryDc, oldBitmap);
            if (bitmap != IntPtr.Zero) Gdi.DeleteObject(bitmap);
            if (memoryDc != IntPtr.Zero) Gdi.DeleteDC(memoryDc);
            memoryDc = bitmap = oldBitmap = bits = IntPtr.Zero;
            width = height = 0;
        }

        public void Dispose() => Release();
    }

    private static class Gdi
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct BitmapInfoHeader
        {
            public uint Size;
            public int Width, Height;
            public ushort Planes, BitCount;
            public uint Compression, SizeImage;
            public int XPelsPerMeter, YPelsPerMeter;
            public uint ClrUsed, ClrImportant;
        }

        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr window);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr window, IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr dc);
        [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapInfoHeader info, uint usage, out IntPtr bits, IntPtr section, uint offset);
        [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr dc, IntPtr gdiObject);
        [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr gdiObject);
        [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr dc);
    }

    /// <summary>Pencereden yakalama öğesi (IGraphicsCaptureItemInterop).</summary>
    private static class CaptureInterop
    {
        private static readonly Guid GraphicsCaptureItemIid = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

        [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IGraphicsCaptureItemInterop
        {
            IntPtr CreateForWindow([In] IntPtr window, [In] ref Guid iid);
            IntPtr CreateForMonitor([In] IntPtr monitor, [In] ref Guid iid);
        }

        public static GraphicsCaptureItem CreateItemForWindow(IntPtr window)
        {
            var factory = WinRT.ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
            var interop = factory.AsInterface<IGraphicsCaptureItemInterop>();
            var iid = GraphicsCaptureItemIid;
            var pointer = interop.CreateForWindow(window, ref iid);
            try { return GraphicsCaptureItem.FromAbi(pointer); }
            finally { Marshal.Release(pointer); }
        }
    }

    /// <summary>Yakalama için Direct3D 11 aygıtı (WinRT IDirect3DDevice).</summary>
    private static class Direct3D
    {
        private static readonly Guid DxgiDeviceIid = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
        private static readonly Guid MultithreadIid = new("9B7E4E00-342C-4106-A19F-4F2704F689F0"); // ID3D11Multithread

        /// <summary>
        /// Serbest iş parçacıklı kare havuzunda kareler Windows'un iş parçacığından gelir ve kopyalama aygıtın bağlamını
        /// oradan kullanır; aygıt çok iş parçacıklı korumaya alınır (Microsoft'un yakalama örneklerindeki gibi). Desteklenmezse
        /// sessizce geçilir.
        /// </summary>
        private static unsafe void ProtectMultithread(IntPtr device)
        {
            var iid = MultithreadIid;
            if (Marshal.QueryInterface(device, in iid, out var multithread) != 0 || multithread == IntPtr.Zero) return;
            try
            {
                // IUnknown (3) + Enter, Leave, SetMultithreadProtected: 5. yuva.
                var table = *(IntPtr**)multithread;
                var set = (delegate* unmanaged[Stdcall]<IntPtr, int, int>)table[5];
                set(multithread, 1);
            }
            finally { Marshal.Release(multithread); }
        }

        [DllImport("d3d11.dll", ExactSpelling = true)]
        private static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags, IntPtr featureLevels,
                                                    uint featureLevelCount, uint sdkVersion, out IntPtr device, out int featureLevel,
                                                    out IntPtr immediateContext);

        [DllImport("d3d11.dll", ExactSpelling = true)]
        private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

        public static IDirect3DDevice CreateDevice()
        {
            // D3D_DRIVER_TYPE_HARDWARE = 1, D3D11_CREATE_DEVICE_BGRA_SUPPORT = 0x20, D3D11_SDK_VERSION = 7
            Marshal.ThrowExceptionForHR(D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out var device, out _, out var context));
            try
            {
                ProtectMultithread(device);
                var iid = DxgiDeviceIid;
                Marshal.ThrowExceptionForHR(Marshal.QueryInterface(device, in iid, out var dxgi));
                try
                {
                    Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out var inspectable));
                    try { return WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(inspectable); }
                    finally { Marshal.Release(inspectable); }
                }
                finally { Marshal.Release(dxgi); }
            }
            finally
            {
                if (context != IntPtr.Zero) Marshal.Release(context);
                Marshal.Release(device);
            }
        }
    }

    private static class Native
    {
        public const uint GwOwner = 4;

        public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

        [StructLayout(LayoutKind.Sequential)]
        public struct Rect { public int Left, Top, Right, Bottom; }

        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLength(IntPtr window);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder text, int maxCount);
    }
}
