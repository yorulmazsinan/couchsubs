// SPDX-License-Identifier: AGPL-3.0-only

using System.Text.RegularExpressions;
using CouchSubs.TvInstall.Android;

namespace CouchSubs.TvInstall;

/// <summary>
/// Android TV kurulumunun önü ve arkası (Windows uygulaması ve Mac'in yardımcısı aynı yolu kullanır):
/// <list type="bullet">
/// <item>TV'den kaldırılan uygulamanın kaydı paket yöneticisinde kalabilir (veri saklanarak kaldırma, arşivleme): dumpsys
/// sürümü yine söyler ama uygulama ana kullanıcıda (User 0) kurulu değildir; TV uygulamayı yalnız ana kullanıcıdan
/// kaldırıp çocuk/ikincil profilde bırakmış da olabilir (#528). Kurulum aracı dumpsys'e bakıp "güncel" der ve kurmazdı;
/// başka profilde kuruluysa önce APK göndermeden geri getirilir (pm install-existing), olmazsa kalıntı kaldırılır ve
/// uygulama baştan kurulur (#352, #389).</item>
/// <item>"TV uygulamasını yeniden kur"da uygulama TV'de güncelse de açılır.</item>
/// </list>
/// </summary>
public static partial class AndroidTvApp
{
    private const string Package = AndroidTvInstaller.PackageName;

    /// <summary>dumpsys'teki kullanıcı satırları: "User 0: ceDataInode=… installed=true hidden=false …".</summary>
    [GeneratedRegex(@"^\s*User (\d+):.*?\binstalled=(true|false)\b", RegexOptions.Multiline)]
    private static partial Regex UserInstalled();

    /// <summary>pm install-existing komutu: başka profilde kurulu APK'yı ana kullanıcıya geri getirir (#528).</summary>
    public const string InstallExistingCommand = $"shell:pm install-existing --user 0 {Package}";

    private static Dictionary<string, bool> Users(string dumpsys) =>
        UserInstalled().Matches(dumpsys).GroupBy(match => match.Groups[1].Value)
            .ToDictionary(group => group.Key, group => group.First().Groups[2].Value == "true");

    /// <summary>
    /// dumpsys sürüm söylüyor ama uygulama TV'nin ana kullanıcısında (User 0) kurulu değil: kaydı kalmış (#352, #389) ya da
    /// TV uygulamayı yalnız ana kullanıcıdan kaldırmış, çocuk/ikincil profilde kurulu kalmış (#528).
    /// Kullanıcı satırı yoksa (eski Android) kalıntı sayılmaz. Telefondaki AndroidTvInstaller.isLeftover ile aynıdır.
    /// </summary>
    public static bool IsLeftover(string dumpsys)
    {
        if (AndroidTvInstaller.VersionFromDumpsys(dumpsys) is null) return false;
        var users = Users(dumpsys);
        if (users.Count == 0) return false;
        return (users.TryGetValue("0", out var main) && !main) || !users.Values.Any(installed => installed);
    }

    /// <summary>Kalıntı ama APK başka bir profilde kurulu: pm install-existing ile APK göndermeden geri getirilir (#528).</summary>
    public static bool CanInstallExisting(string dumpsys) => IsLeftover(dumpsys) && Users(dumpsys).Values.Any(installed => installed);

    /// <summary>pm install-existing başarılı mı ("Package com.couchsubs.tv installed for user: 0")?</summary>
    public static bool InstallExistingSucceeded(string output) => output.Contains("installed for user", StringComparison.Ordinal);

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
            var started = await adb.RunAsync(AndroidTvInstaller.StartCommand(installer.LaunchParams), cancellationToken: cancellationToken);
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
        if (CanInstallExisting(dumpsys))
        {
            var existing = await adb.RunAsync(InstallExistingCommand, cancellationToken: cancellationToken);
            log?.Invoke($"Android TV: uygulama başka bir profilde kurulu; ana kullanıcıya geri getiriliyor: {existing.Trim()}");
            if (InstallExistingSucceeded(existing)) return;
        }
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
