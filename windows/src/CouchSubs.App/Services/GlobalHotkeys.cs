// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.InteropServices;
using System.Windows.Interop;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// Genel kısayollar (Num 0, 1, 2, 3, 5, 7, 8, 9 ve aynı işler için Ctrl+Shift+rakam, bkz. <see cref="HotkeyTable"/>):
/// kullanıcı kumandayla oynarken bilgisayardaki pencere arka planda olsa da çalışır.
/// Kısayollar yalnız <see cref="Enabled"/> iken tutulur; böylece çeviri kapalıyken sayı tuşları diğer uygulamalarda
/// (Excel gibi) normal çalışır. Tuş başka bir uygulamada kullanılıyorsa sessizce atlanır.
/// </summary>
public sealed partial class GlobalHotkeys : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const uint ModNoRepeat = 0x4000;
    private const int FirstId = 0x4353;

    private static readonly IReadOnlyList<HotkeyBinding> Keys = HotkeyTable.Bindings;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(IntPtr window, int id);

    private readonly IntPtr window;
    private readonly HwndSource? source;
    private readonly Action<HotkeyAction> pressed;
    private readonly List<int> registered = [];
    private bool enabled;
    /// <summary>Alınamayan Ctrl+Shift kısayolları bir kez günlüğe yazıldı (her çeviri başlangıcında yinelenmesin).</summary>
    private bool comboFailureLogged;

    /// <param name="window">Pencerenin tutamağı (HWND).</param>
    /// <param name="pressed">Kısayola basılınca çağrılır.</param>
    public GlobalHotkeys(IntPtr window, Action<HotkeyAction> pressed)
    {
        this.window = window;
        this.pressed = pressed;
        source = HwndSource.FromHwnd(window);
        source?.AddHook(Hook);
    }

    /// <summary>Kısayollar tutuluyor mu.</summary>
    public bool Enabled
    {
        get => enabled;
        set
        {
            if (value == enabled || source is null) return;
            enabled = value;
            if (value) Register();
            else Unregister();
        }
    }

    private void Register()
    {
        var failed = new List<string>();
        for (var index = 0; index < Keys.Count; index++)
        {
            var id = FirstId + index;
            var key = Keys[index];
            if (RegisterHotKey(window, id, ModNoRepeat | (uint)key.Modifiers, key.VirtualKey)) registered.Add(id);
            else if (key.Modifiers != HotkeyModifiers.None) failed.Add(key.Label);
        }
        // Ctrl+Shift+rakamı başka bir uygulama (ör. Windows'un dil kısayolu) tutuyorsa Num tuşları yine çalışır.
        if (failed.Count > 0 && !comboFailureLogged)
        {
            comboFailureLogged = true;
            StartupGuard.Log($"Kısayol alınamadı, başka bir uygulama kullanıyor: {string.Join(", ", failed)} (Num tuşları çalışır)", null);
        }
    }

    private void Unregister()
    {
        foreach (var id in registered) UnregisterHotKey(window, id);
        registered.Clear();
    }

    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmHotkey) return IntPtr.Zero;
        var id = wParam.ToInt32();
        if (!registered.Contains(id)) return IntPtr.Zero;
        handled = true;
        pressed(Keys[id - FirstId].Action);
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        source?.RemoveHook(Hook);
        Unregister();
        enabled = false;
    }
}
