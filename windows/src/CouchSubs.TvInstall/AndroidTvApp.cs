// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.RegularExpressions;
using CouchSubs.TvInstall.Android;

namespace CouchSubs.TvInstall;

/// <summary>
/// Android TV kurulumunun önü ve arkası (Windows uygulaması ve Mac'in yardımcısı aynı yolu kullanır):
/// <list type="bullet">
/// <item>TV'den kaldırılan uygulamanın kaydı paket yöneticisinde kalabilir (veri saklanarak kaldırma, arşivleme): dumpsys
/// sürümü yine söyler ama uygulama hiçbir kullanıcıda kurulu değildir. Kurulum aracı dumpsys'e bakıp "güncel" der ve
/// kurmazdı; böyle kalıntı önce kaldırılır, sonra uygulama baştan kurulur (#352, #389).</item>
/// <item>"TV uygulamasını yeniden kur"da uygulama TV'de güncelse de açılır.</item>
/// </list>
/// </summary>
public static partial class AndroidTvApp
{
    private const string Package = AndroidTvInstaller.PackageName;

    /// <summary>dumpsys'teki kullanıcı satırları: "User 0: ceDataInode=… installed=true hidden=false …".</summary>
    [GeneratedRegex(@"^\s*User \d+:.*?\binstalled=(true|false)\b", RegexOptions.Multiline)]
    private static partial Regex UserInstalled();

    /// <summary>
    /// dumpsys sürüm söylüyor ama uygulama hiçbir kullanıcıda kurulu değil (kullanıcı satırlarının hepsi installed=false).
    /// Kullanıcı satırı yoksa (eski Android) kalıntı sayılmaz.
    /// </summary>
    public static bool IsLeftover(string dumpsys)
    {
        if (AndroidTvInstaller.VersionFromDumpsys(dumpsys) is null) return false;
        var users = UserInstalled().Matches(dumpsys);
        return users.Count > 0 && users.All(match => match.Groups[1].Value == "false");
    }

    /// <summary>Kalıntıyı kaldırır, uygulamayı gerekirse kurar; <paramref name="openIfInstalled"/> ise güncel uygulamayı da açar.</summary>
    public static async Task<(string Version, bool Installed)> EnsureInstalledAsync(AndroidTvInstaller installer, string host,
        string keyDirectory, string apkPath, string version, bool openIfInstalled, Action? onApprovalNeeded, Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        await RemoveLeftoverAsync(host, keyDirectory, onApprovalNeeded, log, cancellationToken);
        var result = await installer.EnsureInstalledAsync(apkPath, version, cancellationToken);
        if (!result.Installed && openIfInstalled)
        {
            await using var adb = await ConnectAsync(host, keyDirectory, onApprovalNeeded, cancellationToken);
            var started = await adb.RunAsync($"shell:am start -n {Package}/.MainActivity", cancellationToken: cancellationToken);
            log?.Invoke($"Android TV: uygulama güncel ({result.Version}), açıldı: {started.Trim()}");
        }
        return result;
    }

    private static async Task RemoveLeftoverAsync(string host, string keyDirectory, Action? onApprovalNeeded, Action<string>? log,
        CancellationToken cancellationToken)
    {
        await using var adb = await ConnectAsync(host, keyDirectory, onApprovalNeeded, cancellationToken);
        var dumpsys = await adb.RunAsync($"shell:dumpsys package {Package}", cancellationToken: cancellationToken);
        if (!IsLeftover(dumpsys)) return;
        var removed = await adb.RunAsync($"shell:pm uninstall {Package}", cancellationToken: cancellationToken);
        log?.Invoke($"Android TV: paket kaydı kalmış ama uygulama kurulu değil; kalıntı kaldırıldı: {removed.Trim()}");
    }

    private static async Task<AdbConnection> ConnectAsync(string host, string keyDirectory, Action? onApprovalNeeded,
        CancellationToken cancellationToken)
    {
        using var key = AndroidTvInstaller.LoadOrCreateKey(keyDirectory);
        return await AdbConnection.ConnectAsync(host, AndroidTvInstaller.DefaultPort, key, onApprovalNeeded,
            cancellationToken: cancellationToken);
    }
}
