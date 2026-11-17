// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.InteropServices;
using System.Windows.Interop;
using CouchSubs.Shell;

namespace CouchSubs.App.Services;

/// <summary>
/// Genel kısayollar (varsayılan Num 0, 1, 2, 3, 5, 7, 8, 9 ve aynı işler için Ctrl+Shift+rakam; kullanıcı Ayarlar ›
/// Kısayollar'da değiştirebilir, bkz. <see cref="HotkeyTable"/>): kullanıcı kumandayla oynarken bilgisayardaki pencere
/// arka planda olsa da çalışır. Kısayollar yalnız <see cref="Enabled"/> iken tutulur; böylece çeviri kapalıyken sayı
/// tuşları diğer uygulamalarda (Excel gibi) normal çalışır. Tuş başka bir uygulamada kullanılıyorsa sessizce atlanır.
/// </summary>
public sealed partial class GlobalHotkeys : IDisposable
{
    private const int WmHotkey = 0x0312;
    private const uint ModNoRepeat = 0x4000;
    private const int FirstId = 0x4353;
    /// <summary>Ayarlar'da tuşun boş olup olmadığını denemek için kısa süre alınan kimlik.</summary>
    private const int ProbeId = 0x43FF;

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint virtualKey);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool UnregisterHotKey(IntPtr window, int id);

    private readonly IntPtr window;
    private readonly HwndSource? source;
    private readonly Action<HotkeyAction> pressed;
    private readonly Dictionary<int, HotkeyAction> registered = [];
    private IReadOnlyList<HotkeyBinding> keys = HotkeyTable.Bindings;
    private bool enabled;
    /// <summary>Alınamayan kısayollar bir kez günlüğe yazıldı (her çeviri başlangıcında yinelenmesin).</summary>
    private string? loggedFailure;

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

    /// <summary>Tutulacak kısayollar (<see cref="HotkeyTable.Resolve"/>). Kısayollar tutuluyorsa hemen yenilenir.</summary>
    public IReadOnlyList<HotkeyBinding> Bindings
    {
        get => keys;
        set
        {
            if (keys.SequenceEqual(value)) return;
            if (enabled) Unregister();
            keys = value;
            if (enabled) Register();
        }
    }

    /// <summary>
    /// Tuş şu an başka bir uygulamada kullanılmıyor mu. Ayarlar yeni tuşu beklerken CouchSubs kendi kısayollarını bırakır
    /// (<see cref="AppController.HotkeysPaused"/>), bu yüzden alınamayan tuşu başka bir uygulama tutuyordur.
    /// </summary>
    public static bool IsAvailable(IntPtr window, HotkeyKey key)
    {
        if (!RegisterHotKey(window, ProbeId, ModNoRepeat | (uint)key.Modifiers, key.VirtualKey)) return false;
        UnregisterHotKey(window, ProbeId);
        return true;
    }

    private void Register()
    {
        var failed = new List<string>();
        for (var index = 0; index < keys.Count; index++)
        {
            var id = FirstId + index;
            var key = keys[index];
            if (RegisterHotKey(window, id, ModNoRepeat | (uint)key.Modifiers, key.VirtualKey)) registered[id] = key.Action;
            else failed.Add(key.Label);
        }
        // Tuşu başka bir uygulama (ör. Windows'un dil kısayolu) tutuyorsa işin diğer tuşu yine çalışır.
        var failure = string.Join(", ", failed);
        if (failed.Count > 0 && failure != loggedFailure)
        {
            loggedFailure = failure;
            StartupGuard.Log($"Kısayol alınamadı, başka bir uygulama kullanıyor: {failure}", null);
        }
    }

    private void Unregister()
    {
        foreach (var id in registered.Keys) UnregisterHotKey(window, id);
        registered.Clear();
    }

    private IntPtr Hook(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmHotkey) return IntPtr.Zero;
        if (!registered.TryGetValue(wParam.ToInt32(), out var action)) return IntPtr.Zero;
        handled = true;
        pressed(action);
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        source?.RemoveHook(Hook);
        Unregister();
        enabled = false;
    }
}
