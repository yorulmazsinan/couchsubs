// SPDX-License-Identifier: AGPL-3.0-only

using System.Diagnostics;
using System.Runtime.InteropServices;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// Qt'nin Windows'ta OpenGL tam ekran pencereler için belgelediği DWM sorununu giderir. Tam ekran chiaki-ng
/// penceresine WS_BORDER eklemek diğer üst düzey pencerelerin (altyazının) çizilmesini sağlar. Normal pencereye
/// dokunulmaz; altyazı kapanınca yalnız bizim eklediğimiz bit geri alınır.
/// </summary>
internal sealed partial class ChiakiFullscreenOverlay : IDisposable
{
    private const int GwlStyle = -16;
    private const long WsBorder = 0x00800000;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private IntPtr changed;

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect { public int Left, Top, Right, Bottom; }

    [LibraryImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    private static partial IntPtr GetWindowLongPtr(IntPtr window, int index);

    [LibraryImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static partial IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetWindowRect(IntPtr window, out Rect rect);

    [LibraryImport("user32.dll")]
    private static partial uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

    public void Refresh(RemotePlayApp selected)
    {
        var target = RemotePlayWindowStream.OverlayTarget(selected);
        if (target != changed) Restore();
        if (target == IntPtr.Zero || !IsChiaki(target) || !IsFullScreen(target)) return;
        var style = (long)GetWindowLongPtr(target, GwlStyle);
        if ((style & WsBorder) != 0) return;
        Marshal.SetLastPInvokeError(0);
        SetWindowLongPtr(target, GwlStyle, (IntPtr)(style | WsBorder));
        if (Marshal.GetLastPInvokeError() != 0) return;
        changed = target;
        SetWindowPos(target, IntPtr.Zero, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
    }

    public void Restore()
    {
        var target = changed;
        changed = IntPtr.Zero;
        if (target == IntPtr.Zero || !IsChiaki(target) || !IsFullScreen(target)) return;
        var style = (long)GetWindowLongPtr(target, GwlStyle);
        if ((style & WsBorder) == 0) return;
        SetWindowLongPtr(target, GwlStyle, (IntPtr)(style & ~WsBorder));
        SetWindowPos(target, IntPtr.Zero, 0, 0, 0, 0, SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged);
    }

    public void Dispose() => Restore();

    private static bool IsChiaki(IntPtr target)
    {
        GetWindowThreadProcessId(target, out var id);
        if (id == 0) return false;
        try
        {
            using var process = Process.GetProcessById((int)id);
            return string.Equals(process.ProcessName, "chiaki", StringComparison.OrdinalIgnoreCase)
                || string.Equals(process.ProcessName, "chiaki-ng", StringComparison.OrdinalIgnoreCase);
        }
        catch (ArgumentException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    private static bool IsFullScreen(IntPtr target)
    {
        if (!GetWindowRect(target, out var rect)) return false;
        var screen = System.Windows.Forms.Screen.FromHandle(target).Bounds;
        // Görünmez DWM yeniden boyutlandırma kenarları GetWindowRect'e birkaç piksel ekleyebilir.
        const int tolerance = 12;
        return Math.Abs(rect.Left - screen.Left) <= tolerance && Math.Abs(rect.Top - screen.Top) <= tolerance
            && Math.Abs(rect.Right - screen.Right) <= tolerance && Math.Abs(rect.Bottom - screen.Bottom) <= tolerance;
    }
}
