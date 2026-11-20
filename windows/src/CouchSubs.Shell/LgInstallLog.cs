// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core.LgTv;

namespace CouchSubs.Shell;

/// <summary>
/// LG kurulumunun adımlarını kurulum günlüğüne (tvinstall.log) telefonlardaki satırlarla yazar: "--- LG kurulumu …
/// başlıyor", "Key Server'dan anahtar alındı.", "TV'deki CouchSubs: …", "Kurulum tamam.", "HATA …". Önceden masaüstünde
/// yalnız Samsung ve Android TV kurulumu günlük tutuyordu; LG hatasında gönderilecek bir şey yoktu.
/// </summary>
public sealed class LgInstallLog(Action<string> write)
{
    /// <summary>Key Server'dan anahtar alma (TV ekranındaki parolayla).</summary>
    public Task<string> KeyAsync(string host, Func<Task<string>> fetch) =>
        LoggedAsync(async () =>
        {
            write($"--- LG kurulumu başlıyor: TV {host}, Key Server'dan anahtar isteniyor");
            var key = await fetch();
            write("Key Server'dan anahtar alındı.");
            return key;
        });

    /// <summary>TV'deki sürüme bakma; kurulum bununla başlar.</summary>
    public Task<string?> InstalledVersionAsync(string host, string? bundled, Func<Task<string?>> read) =>
        LoggedAsync(async () =>
        {
            write($"--- LG kurulumu başlıyor: TV {host}, paket {bundled ?? "?"}");
            var onTv = await read();
            write($"TV'deki CouchSubs: {onTv ?? "yok"}");
            return onTv;
        });

    public Task InstallAsync(Func<Task> install) =>
        LoggedAsync<object?>(async () =>
        {
            await install();
            write("Kurulum tamam.");
            return null;
        });

    private async Task<T> LoggedAsync<T>(Func<Task<T>> body)
    {
        try
        {
            return await body();
        }
        catch (DevModeException error)
        {
            write($"HATA {error.Error}: {error.Detail}");
            throw;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            write($"Beklenmeyen hata: {error}");
            throw;
        }
    }
}
