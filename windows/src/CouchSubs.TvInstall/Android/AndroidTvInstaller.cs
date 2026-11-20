// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace CouchSubs.TvInstall.Android;

/// <summary>
/// CouchSubs'ın Android TV uygulamasını ağ üzerinden kurar. TV'de geliştirici seçenekleri ve USB hata ayıklama
/// açık olmalıdır; Android TV'lerin çoğu bu ayarla 5555 portunda ADB bekler.
/// </summary>
public sealed partial class AndroidTvInstaller(string host, string keyDirectory, int port = AndroidTvInstaller.DefaultPort)
{
    public const int DefaultPort = 5555;
    public const string PackageName = "com.couchsubs.tv";

    /// <summary>Kurulum sırasında TV'nin onay sorusunu göstermesi.</summary>
    public Action? OnApprovalNeeded { get; init; }

    /// <summary>
    /// Uygulama açılırken verilen başlatma parametreleri (webOS ve Samsung'daki gibi JSON, ör. <c>{"server":"http://…:8787"}</c>).
    /// TV uygulaması bunu <c>params</c> ekinden okur; altyazı sunucusu 8787 dışında bir portta olsa da onu bulur (#617).
    /// </summary>
    public string? LaunchParams { get; init; }

    /// <summary>Uygulamayı açan ADB komutu; <paramref name="launchParams"/> varsa <c>--es params '…'</c> ile.</summary>
    public static string StartCommand(string? launchParams)
    {
        var command = $"shell:am start -n {PackageName}/.MainActivity";
        // TV'de sh çalıştırır: değer tek tırnak içinde gider; tek tırnak ve satır sonu içeren değer hiç gönderilmez.
        if (string.IsNullOrEmpty(launchParams) || launchParams.IndexOfAny(['\'', '\n', '\r', '\0']) >= 0) return command;
        return $"{command} --es params '{launchParams}'";
    }

    /// <summary>TV'de ADB açık mı (port yanıt veriyor mu)?</summary>
    public static async Task<bool> IsReachableAsync(string host, int port = DefaultPort, TimeSpan? timeout = null)
    {
        using var tcp = new TcpClient();
        using var limit = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(1));
        try
        {
            await tcp.ConnectAsync(host, port, limit.Token);
            return true;
        }
        catch (Exception error) when (error is SocketException or OperationCanceledException)
        {
            return false;
        }
    }

    /// <summary>Bu bilgisayarın ağlarında ADB'si açık cihazları arar (her ağın /24 bölümü).</summary>
    public static async Task<IReadOnlyList<string>> ScanAsync(int port = DefaultPort, CancellationToken cancellationToken = default)
    {
        var hosts = ScanTargets(LocalAddresses()).ToList();
        var found = new System.Collections.Concurrent.ConcurrentBag<string>();
        await Parallel.ForEachAsync(hosts, new ParallelOptions { MaxDegreeOfParallelism = 64, CancellationToken = cancellationToken },
            async (candidate, _) =>
            {
                if (await IsReachableAsync(candidate, port, TimeSpan.FromMilliseconds(700))) found.Add(candidate);
            });
        return [.. found.OrderBy(h => IPAddress.Parse(h).GetAddressBytes()[3])];
    }

    internal static IEnumerable<string> ScanTargets(IEnumerable<IPAddress> locals)
    {
        var seen = new HashSet<string>();
        foreach (var local in locals)
        {
            var bytes = local.GetAddressBytes();
            for (var last = 1; last < 255; last++)
            {
                if (last == bytes[3]) continue;
                var candidate = $"{bytes[0]}.{bytes[1]}.{bytes[2]}.{last}";
                if (seen.Add(candidate)) yield return candidate;
            }
        }
    }

    private static IEnumerable<IPAddress> LocalAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && IsPrivate(a));

    internal static bool IsPrivate(IPAddress address)
    {
        var b = address.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168);
    }

    /// <summary>
    /// Uygulama eksikse ya da eskiyse kurar ve açar; hepsi tek bağlantıda yapılır, TV onayı en çok bir kez sorulur.
    /// </summary>
    /// <returns>TV'de artık bulunan sürüm ve kurulum yapılıp yapılmadığı.</returns>
    public async Task<(string Version, bool Installed)> EnsureInstalledAsync(string apkPath, string version,
        CancellationToken cancellationToken = default)
    {
        await using var adb = await ConnectAsync(cancellationToken);
        var dumpsys = await adb.RunAsync($"shell:dumpsys package {PackageName}", cancellationToken: cancellationToken);
        var installed = VersionFromDumpsys(dumpsys);
        if (installed is not null && !Versions.IsNewer(version, installed))
        {
            // Bu izni vermeyen eski bir CouchSubs'ın kurduğu güncel uygulama da izni alsın.
            await GrantOverlayAsync(adb, cancellationToken);
            return (installed, false);
        }
        // Play'de ve TV'de Play Store varsa Play'den (PlayStoreRedirect.cs); olmazsa APK ile.
        if (await InstallFromPlayAsync(adb, installed, InstalledFromPlay(dumpsys), cancellationToken) is { } fromPlay)
            return (fromPlay, true);
        await InstallAsync(adb, apkPath, cancellationToken);
        await GrantOverlayAsync(adb, cancellationToken);
        await adb.RunAsync(StartCommand(LaunchParams), cancellationToken: cancellationToken);
        return (version, true);
    }

    /// <summary>
    /// "Diğer uygulamaların üzerinde göster" iznini verir. Katman modunda (bazı TV'lerde uygulama içindeki HDMI görüntüsü
    /// siyah kalıyor) altyazı TV'nin kendi HDMI ekranının üstündeki şeffaf pencerede çizilir ve bu izin gerekir. Android TV'de
    /// bu ayar çoğu zaman menüde yoktur; ADB ile verilir. Verilemezse kurulum yine başarılıdır, TV uygulaması nasıl
    /// verileceğini kendisi anlatır.
    /// </summary>
    /// <returns>İzin verildi mi.</returns>
    internal static async Task<bool> GrantOverlayAsync(AdbConnection adb, CancellationToken cancellationToken)
    {
        try
        {
            var output = await adb.RunAsync($"shell:appops set {PackageName} SYSTEM_ALERT_WINDOW allow", cancellationToken: cancellationToken);
            if (!LooksFailed(output)) return true;
            // Bazı Android sürümlerinde appops yerine izin olarak verilir.
            output = await adb.RunAsync($"shell:pm grant {PackageName} android.permission.SYSTEM_ALERT_WINDOW", cancellationToken: cancellationToken);
            return !LooksFailed(output);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            return false;
        }
    }

    /// <summary>appops ve pm başarıda bir şey yazmaz; hata metni döner.</summary>
    internal static bool LooksFailed(string output) =>
        output.Contains("Error", StringComparison.OrdinalIgnoreCase) || output.Contains("Exception", StringComparison.OrdinalIgnoreCase)
        || output.Contains("Unknown", StringComparison.OrdinalIgnoreCase) || output.Contains("not allowed", StringComparison.OrdinalIgnoreCase);

    internal static string? VersionFromDumpsys(string output) =>
        VersionName().Match(output) is { Success: true } match ? match.Groups[1].Value : null;

    /// <summary>APK'yı kurar. İmzası farklı eski bir kopya varsa önce onu kaldırır.</summary>
    private static async Task InstallAsync(AdbConnection adb, string apkPath, CancellationToken cancellationToken)
    {
        var result = await StreamInstallAsync(adb, apkPath, cancellationToken);
        if (result.Contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || result.Contains("INSTALL_FAILED_VERSION_DOWNGRADE"))
        {
            await adb.RunAsync($"shell:pm uninstall {PackageName}", cancellationToken: cancellationToken);
            result = await StreamInstallAsync(adb, apkPath, cancellationToken);
        }
        if (!result.Contains("Success"))
            throw new AndroidInstallException(AndroidInstallError.InstallFailed, result.Trim());
    }

    private static async Task<string> StreamInstallAsync(AdbConnection adb, string apkPath, CancellationToken cancellationToken)
    {
        await using var apk = File.OpenRead(apkPath);
        // Android 7 ve sonrası: dosyayı TV'ye ayrıca kopyalamadan doğrudan paket yöneticisine akıtır.
        return await adb.RunAsync($"exec:cmd package install -r -S {apk.Length}", apk, cancellationToken);
    }

    private Task<AdbConnection> ConnectAsync(CancellationToken cancellationToken) =>
        AdbConnection.ConnectAsync(host, port, LoadOrCreateKey(keyDirectory), OnApprovalNeeded, cancellationToken: cancellationToken);

    /// <summary>
    /// Bu bilgisayarın ADB anahtarı. TV onayı bu anahtara verilir; anahtar değişirse TV yeniden sorar.
    /// </summary>
    public static RSA LoadOrCreateKey(string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "adbkey");
        var key = RSA.Create();
        if (File.Exists(path))
        {
            try
            {
                key.ImportFromPem(File.ReadAllText(path));
                if (key.KeySize == 2048) return key;
            }
            catch (CryptographicException) { /* bozuk dosya: yenisi üretilir */ }
        }
        key.Dispose();
        key = RSA.Create(2048);
        File.WriteAllText(path, key.ExportPkcs8PrivateKeyPem());
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        return key;
    }

    [GeneratedRegex(@"versionName=(\S+)")]
    private static partial Regex VersionName();
}
