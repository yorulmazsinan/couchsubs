// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.TvInstall.Android;

/// <summary>
/// CouchSubs TV Google Play'de herkese açıksa ve TV'de Play Store varsa uygulama APK yerine Play'den kurulur: TV'de Play
/// sayfası açılır, kullanıcı kumandayla Yükle'ye basar. Play'den kurulmuş kopyanın güncellemesi de Play'e bırakılır.
/// Süre dolarsa (kullanıcı basmadı ya da Play'de yeni sürüm henüz yok) APK ile kurulur. Telefondaki
/// couchsubs-android/.../tv/android/AndroidTvInstaller.kt installFromPlay ile aynıdır.
/// </summary>
public sealed partial class AndroidTvInstaller
{
    public const string PlayUrl = "https://play.google.com/store/apps/details?id=" + PackageName;
    private const string PlayStorePackage = "com.android.vending";

    /// <summary>Play yolu: Play sayfası herkese açık mı? Verilmezse (testler) Play yolu kapalıdır.</summary>
    public Func<CancellationToken, Task<bool>>? PlayListed { get; init; }

    /// <summary>TV'de Play sayfası açıldı: arayüz "TV'de Yükle'ye basın" der.</summary>
    public Action? OnPlayOpened { get; init; }

    public TimeSpan PlayWait { get; init; } = TimeSpan.FromMinutes(4);

    /// <summary>Play sayfası 200 dönüyor mu? Ağ yoksa false.</summary>
    public static async Task<bool> IsListedOnPlayAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
            using var response = await http.GetAsync(PlayUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            return (int)response.StatusCode == 200;
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            return false;
        }
    }

    internal static bool HasPlayStore(string output) =>
        output.Split('\n').Any(line => line.Trim() == "package:" + PlayStorePackage);

    internal static bool InstalledFromPlay(string dumpsys) => dumpsys.Contains("installerPackageName=" + PlayStorePackage);

    /// <summary>Play'den kurar ve açar; Play yolu yoksa ya da süre dolarsa null (APK ile kurulur).</summary>
    private async Task<string?> InstallFromPlayAsync(AdbConnection adb, string? before, bool fromPlay, CancellationToken cancellationToken)
    {
        if (PlayListed is null || !await PlayListed(cancellationToken)) return null;
        if (!fromPlay)
        {
            var packages = await adb.RunAsync($"shell:pm list packages {PlayStorePackage}", cancellationToken: cancellationToken);
            if (!HasPlayStore(packages)) return null;
        }
        var opened = await adb.RunAsync($"shell:am start -a android.intent.action.VIEW -d market://details?id={PackageName}",
            cancellationToken: cancellationToken);
        if (opened.Contains("Error", StringComparison.OrdinalIgnoreCase)) return null;
        OnPlayOpened?.Invoke();
        var deadline = DateTime.UtcNow + PlayWait;
        while (DateTime.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromSeconds(3), cancellationToken);
            var now = VersionFromDumpsys(await adb.RunAsync($"shell:dumpsys package {PackageName}", cancellationToken: cancellationToken));
            if (now is not null && now != before)
            {
                await GrantOverlayAsync(adb, cancellationToken);
                await adb.RunAsync(StartCommand(LaunchParams), cancellationToken: cancellationToken);
                return now;
            }
        }
        return null;
    }
}
