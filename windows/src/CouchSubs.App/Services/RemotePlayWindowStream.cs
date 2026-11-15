// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
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
public sealed class RemotePlayWindowStream : IStreamSession
{
    /// <summary>Saniyedeki kare. Okuma bir önceki kare bitmeden yenisini zaten almaz; fazlası yalnız işlemciyi yorar.</summary>
    private const int FramesPerSecond = 10;
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
    private readonly string[] processNames;
    private readonly object gate = new();
    private int generation;
    private bool running;
    private CancellationTokenSource? search;
    private Capture? capture;
    private SessionState? reported;

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
        OpenIfNeeded();
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
                var window = FindGameWindow(processNames);
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
                        RemotePlayLog.Note("Remote Play penceresi bekleniyor (PS Remote Play ya da chiaki-ng)");
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
                Localizer.Current["The Remote Play window comes through black: this app may block screen capture. Try chiaki-ng."]));
        else
            Report(SessionState.Streaming);
    }

    /// <summary>Seçilen uygulamaların en büyük, görünür, simge durumunda olmayan üst düzey penceresi.</summary>
    private static IntPtr FindGameWindow(string[] names)
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
            if (!wanted || !Native.GetWindowRect(hwnd, out var rect)) return true;
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

    /// <summary>Seçilen uygulamalardan hiçbiri açık değilse kurulu olan ilki açılır.</summary>
    private void OpenIfNeeded()
    {
        if (processNames.Any(name => Process.GetProcessesByName(name).Length > 0)) return;
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
        var path = candidates.FirstOrDefault(File.Exists);
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

    /// <summary>Bir pencerenin yakalanması: Direct3D aygıtı, kare havuzu ve oturum. Kareler saniyede en çok
    /// <see cref="FramesPerSecond"/> kez işlemciye kopyalanıp BGRA <see cref="Frame"/> olarak verilir.</summary>
    private sealed class Capture : IDisposable
    {
        private readonly RemotePlayWindowStream owner;
        private readonly int number;
        private readonly IDirect3DDevice device;
        private readonly GraphicsCaptureItem item;
        private readonly Direct3D11CaptureFramePool pool;
        private readonly GraphicsCaptureSession session;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private long lastFrameMs = -1000;
        private int busy;
        private int blackFrames;
        private bool warnedBlack;
        private Windows.Graphics.SizeInt32 size;
        private bool disposed;

        public string Name { get; }
        public int Width => size.Width;
        public int Height => size.Height;

        public Capture(IntPtr window, RemotePlayWindowStream owner, int number)
        {
            this.owner = owner;
            this.number = number;
            Native.GetWindowThreadProcessId(window, out var pid);
            try
            {
                using var process = Process.GetProcessById((int)pid);
                Name = process.ProcessName;
            }
            catch (Exception) { Name = "Remote Play"; }
            device = Direct3D.CreateDevice();
            item = CaptureInterop.CreateItemForWindow(window);
            size = item.Size;
            pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
            session = pool.CreateCaptureSession(item);
            session.IsCursorCaptureEnabled = false;
            item.Closed += (_, _) => owner.CaptureEnded(this, number, "pencere kapandı");
            pool.FrameArrived += OnFrameArrived;
            session.StartCapture();
        }

        private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
        {
            using var frame = sender.TryGetNextFrame();
            if (frame is null || disposed) return;
            if (frame.ContentSize.Width != size.Width || frame.ContentSize.Height != size.Height)
            {
                // Pencere büyütüldü ya da tam ekrana geçti: havuz yeni boya kurulur, bu kare atlanır.
                size = frame.ContentSize;
                if (size.Width > 0 && size.Height > 0) pool.Recreate(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);
                return;
            }
            var now = clock.ElapsedMilliseconds;
            if (now - lastFrameMs < 1000 / FramesPerSecond) return;
            // Önceki kare hâlâ kopyalanıyorsa bu kare atlanır.
            if (Interlocked.Exchange(ref busy, 1) == 1) return;
            lastFrameMs = now;
            try
            {
                using var bitmap = SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface, BitmapAlphaMode.Premultiplied).AsTask().GetAwaiter().GetResult();
                var (width, height) = (bitmap.PixelWidth, bitmap.PixelHeight);
                if (width < 2 || height < 2) return;
                var pixels = new byte[width * height * 4];
                bitmap.CopyToBuffer(pixels.AsBuffer());
                CheckBlack(pixels);
                owner.Deliver(new Frame(pixels, width, height, width * 4));
            }
            catch (Exception error)
            {
                RemotePlayLog.Note($"Remote Play karesi kopyalanamadı: {error.GetType().Name}: {error.Message}");
            }
            finally
            {
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
            try { session.Dispose(); } catch (Exception) { }
            try { pool.Dispose(); } catch (Exception) { }
            try { device.Dispose(); } catch (Exception) { }
        }
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
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr window, uint command);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    }
}
