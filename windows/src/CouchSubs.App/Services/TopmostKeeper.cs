// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// "Her zaman üstte" pencereyi gerçekten üstte tutar. WPF'in <c>Topmost</c>'u pencereyi yalnız bir kez üst katmana koyar;
/// sonra öne gelen başka bir üst katman penceresi (Xbox uygulaması, kenarsız tam ekran oyun) onu örter. Bu yardımcı
/// başka bir sürecin penceresi ön plana geçince (SetWinEventHook, EVENT_SYSTEM_FOREGROUND) ve
/// <see cref="RaiseThrottled"/> çağrıldıkça pencereyi odağı almadan (SWP_NOACTIVATE) yeniden en üste koyar.
/// Yalnız pencere görünürken çalışır. Store/immersive (UWP) tam ekranın üstüne imzasız bir uygulama çıkamaz; orada
/// büyütülmüş pencere ya da tarayıcıda F11 önerilir.
/// </summary>
internal sealed partial class TopmostKeeper : IDisposable
{
    private static readonly IntPtr HwndTopmost = new(-1);
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private const uint EventSystemForeground = 0x0003;
    private const uint WinEventOutOfContext = 0x0000;
    private const uint WinEventSkipOwnProcess = 0x0002;
    /// <summary>Bazı uygulamalar ön plana geçtikten biraz sonra kendini üste alır; bir kez daha denenir.</summary>
    private static readonly TimeSpan SecondTry = TimeSpan.FromMilliseconds(400);

    private delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint threadId, uint time);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr window, IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [LibraryImport("user32.dll")]
    private static partial IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, IntPtr callback, uint processId, uint threadId, uint flags);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnhookWinEvent(IntPtr hook);

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    private static readonly uint OwnProcessId = (uint)Environment.ProcessId;

    private readonly Window window;
    private readonly TopmostThrottle throttle = new();
    private readonly DispatcherTimer secondTry;
    /// <summary>Yerel koda verilen geri çağırma; çöp toplayıcı kancanın ömrü boyunca toplamasın diye alanda tutulur.</summary>
    private readonly WinEventProc callback;
    private IntPtr handle;
    private IntPtr hook;
    private bool disposed;
    /// <summary>Öne alma hatası bir kez günlüğe yazılır (çizimde sık çağrılır).</summary>
    private bool loggedFailure;

    /// <summary>Pencereye bağlanır: tutamak oluşunca kanca kurulur, pencere görününce öne alınır, kapanınca kanca kaldırılır.</summary>
    public TopmostKeeper(Window window)
    {
        this.window = window;
        callback = OnWinEvent;
        secondTry = new DispatcherTimer(DispatcherPriority.Normal, window.Dispatcher) { Interval = SecondTry };
        secondTry.Tick += (_, _) =>
        {
            secondTry.Stop();
            Raise();
        };
        window.SourceInitialized += (_, _) => Install();
        window.IsVisibleChanged += (_, e) =>
        {
            if (e.NewValue is true) Raise();
        };
        window.Closed += (_, _) => Dispose();
        if (new WindowInteropHelper(window).Handle != IntPtr.Zero) Install();
    }

    /// <summary>Çizimde çağrılır: görünürse ve son öne almadan bu yana 250 ms geçtiyse pencereyi yeniden üste koyar.</summary>
    public void RaiseThrottled()
    {
        if (disposed || handle == IntPtr.Zero || !window.IsVisible) return;
        if (throttle.TryRaise(Now)) Place();
    }

    /// <summary>Pencere görünürse hemen üste koyar.</summary>
    public void Raise()
    {
        if (disposed || handle == IntPtr.Zero || !window.IsVisible) return;
        throttle.Raised(Now);
        Place();
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        secondTry.Stop();
        if (hook != IntPtr.Zero)
        {
            UnhookWinEvent(hook);
            hook = IntPtr.Zero;
        }
    }

    private static TimeSpan Now => TimeSpan.FromMilliseconds(Environment.TickCount64);

    private void Install()
    {
        if (disposed || hook != IntPtr.Zero) return;
        handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;
        // Kapsam dışı kanca, kuran iş parçacığının (arayüz) ileti döngüsünden çağrılır; kendi sürecimizin olayları gelmez.
        hook = SetWinEventHook(EventSystemForeground, EventSystemForeground, IntPtr.Zero,
            Marshal.GetFunctionPointerForDelegate(callback), 0, 0, WinEventOutOfContext | WinEventSkipOwnProcess);
        if (hook == IntPtr.Zero) StartupGuard.Log("Ön plan kancası kurulamadı", new InvalidOperationException("SetWinEventHook"));
    }

    private void OnWinEvent(IntPtr hookHandle, uint eventType, IntPtr foreground, int objectId, int childId, uint threadId, uint time)
    {
        // Yerel koddan çağrılır: buradan istisna dışarı çıkmamalı.
        try
        {
            if (disposed || eventType != EventSystemForeground || foreground == IntPtr.Zero || foreground == handle) return;
            GetWindowThreadProcessId(foreground, out var processId);
            if (!TopmostThrottle.ShouldRaiseFor(processId, OwnProcessId)) return;
            window.Dispatcher.BeginInvoke(() =>
            {
                if (disposed || !window.IsVisible) return;
                Raise();
                secondTry.Stop();
                secondTry.Start();
            });
        }
        catch (Exception error)
        {
            StartupGuard.Log("Ön plan olayı", error);
        }
    }

    private void Place()
    {
        if (SetWindowPos(handle, HwndTopmost, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoActivate | SwpShowWindow) || loggedFailure) return;
        loggedFailure = true;
        StartupGuard.Log("Pencere öne alınamadı", new System.ComponentModel.Win32Exception(Marshal.GetLastPInvokeError()));
    }
}
