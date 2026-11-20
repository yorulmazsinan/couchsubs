// SPDX-License-Identifier: AGPL-3.0-only

using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace CouchSubs.RemotePlay;

/// <summary>couchsubs_native.dll (windows/native/couchsubs_native.h) çağrıları. Geri çağrılar
/// <c>UnmanagedCallersOnly</c> durağan işlevlerdir; nesneye <c>GCHandle</c> ile ulaşılır.</summary>
internal static unsafe partial class NativeMethods
{
    internal const string Library = "couchsubs_native";

    internal const int EventConnected = 0;
    internal const int EventQuit = 1;
    internal const int EventLoginPin = 2;

    internal const int QuitStopped = 0;
    internal const int QuitInUse = 1;
    internal const int QuitRefused = 2;
    internal const int QuitNetwork = 3;
    internal const int QuitOther = 4;
    /// <summary>PS5'teki Uzaktan Oynatma çöktü (CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH).</summary>
    internal const int QuitRpCrashed = 5;
    /// <summary>PSN üzerinden eşleme reddedildi (CHIAKI_QUIT_REASON_PSN_REGIST_FAILED); QuitRefused yalnız TCP reddidir.</summary>
    internal const int QuitPsnRegistFailed = 6;

    [StructLayout(LayoutKind.Sequential)]
    internal struct RegisteredConsoleNative
    {
        public fixed byte Nickname[0x20];
        public fixed byte RegistKey[0x10];
        public fixed byte Morning[0x10];
    }

    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    private static partial int cs_init();

    /// <param name="callback">void (*)(const char *host, const char *name, int awake, void *user)</param>
    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int cs_discover(nint* targets, int targetCount, int timeoutMs, nint callback, nint user);

    /// <param name="callback">void (*)(const char *host, const char *name, int awake, const char *running_app_titleid,
    /// const char *running_app_name, void *user)</param>
    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int cs_discover_ex(nint* targets, int targetCount, int timeoutMs, nint callback, nint user);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int cs_wake(string host, ulong credential);

    /// <param name="log">void (*)(int level, const char *message, void *user)</param>
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int cs_register(string host, byte* accountId, uint pin, RegisteredConsoleNative* output,
                                            uint* reason, nint log, nint user);

    /// <param name="frame">void (*)(const uint8_t *bgra, int width, int height, int stride, void *user)</param>
    /// <param name="eventCallback">void (*)(int event, int quit_reason, const char *reason_text, void *user)</param>
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    /// <param name="videoHeight">1080 ya da 720 (bağlantı sık koparsa daha az bant genişliği).</param>
    internal static partial nint cs_session_start_ex(string host, byte* registKey, byte* morning, byte* accountId, int maxFps,
                                                     int videoHeight, nint frame, nint eventCallback, nint log, nint user);

    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void cs_session_stop(nint session);

    /// <summary>PS5'in istediği giriş şifresi (ASCII rakamlar). Olay geri çağrısından çağrılmamalı.</summary>
    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial int cs_session_set_login_pin(nint session, byte* pin, nuint pinSize);

    private static readonly Lock InitLock = new();
    private static bool initialized;

    /// <summary>Ağ yığını ilk kullanımda bir kez hazırlanır. Kütüphane yoksa DllNotFoundException.</summary>
    internal static void EnsureInitialized()
    {
        lock (InitLock)
        {
            if (initialized) return;
            var result = cs_init();
            if (result != 0) throw new InvalidOperationException($"couchsubs_native could not be initialized ({result})");
            initialized = true;
        }
    }

    /// <summary>Kütüphane bu makinede yüklenebiliyor mu (Mac'te ve DLL'siz derlemelerde hayır).</summary>
    internal static bool IsAvailable
    {
        get
        {
            if (!NativeLibrary.TryLoad(Library, typeof(NativeMethods).Assembly, null, out var handle)) return false;
            NativeLibrary.Free(handle);
            return true;
        }
    }

    internal static string? Utf8(byte* text) => text == null ? null : Marshal.PtrToStringUTF8((nint)text);

    /// <summary>C dizisini sıfırdan önceki kısmıyla dizgeye çevirir.</summary>
    internal static string FixedString(byte* bytes, int length)
    {
        var end = 0;
        while (end < length && bytes[end] != 0) end++;
        return System.Text.Encoding.UTF8.GetString(bytes, end);
    }

    /// <summary>Baytları sabit uzunlukta, sıfırla doldurulmuş diziye kopyalar (fazlası kesilir).</summary>
    internal static byte[] Padded(byte[] data, int length)
    {
        var result = new byte[length];
        Array.Copy(data, result, Math.Min(data.Length, length));
        return result;
    }

    internal static string LevelName(int level) => level switch { 0 => "error", 1 => "warning", _ => "info" };
}

/// <summary>libchiaki'nin günlük satırları (hata, uyarı, bilgi). Tanı için; kayıt ve oturum sırasında gelir.</summary>
public static class RemotePlayLog
{
    /// <summary>Günlüğün yazıldığı dosya (uygulamadaki RemotePlayDiagnostics yazar).</summary>
    public static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CouchSubs", "remoteplay.log");

    /// <summary>Kullanıcıya hata iletisinde gösterilen yol (Dosya Gezgini'nin adres çubuğuna yazılabilir).</summary>
    public const string DisplayPath = @"%LOCALAPPDATA%\CouchSubs\remoteplay.log";

    /// <summary>Yerel kütüphanenin iş parçacığında çağrılır; hızlı dönmeli.</summary>
    public static event Action<string>? MessageLogged;

    /// <summary>Uygulamanın kendi satırı (eşleştirme sonucu, arama sonucu).</summary>
    public static void Note(string message)
    {
        try { MessageLogged?.Invoke($"[couchsubs] {message}"); }
        catch { /* günlük dinleyicisinin hatası çağıranı düşürmemeli */ }
    }

    internal static void Write(int level, string? message)
    {
        if (message is null) return;
        try { MessageLogged?.Invoke($"[chiaki {NativeMethods.LevelName(level)}] {message}"); }
        catch { /* günlük dinleyicisinin hatası yerel iş parçacığını düşürmemeli */ }
    }
}
