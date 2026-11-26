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

    /// <summary>
    /// CouchSubs TV çalışıyor mu: etkinlik yığınlarındaki kayıtlar (ekran arka planda olsa da yığındadır) ve paketin
    /// servisleri (katman). Mac/iPhone'daki AndroidTVApp.runningCommand ve Android telefondaki ile aynı.
    /// </summary>
    public const string RunningCommand =
        $"shell:dumpsys activity activities | grep Hist; dumpsys activity services {PackageName} | grep ServiceRecord";

    /// <summary>Uygulama zaten açıkken <see cref="OpenAsync"/>'in döndürdüğü sonuç (<c>am start</c> gönderilmedi).</summary>
    public const string AlreadyRunning = "zaten açık";

    /// <summary>
    /// <see cref="RunningCommand"/> çıktısında CouchSubs TV'nin ekranı ya da katman servisi var mı. Boş ya da tanınmayan
    /// çıktı (çok eski TV'de <c>grep</c> yok) çalışmıyor sayılır: eski yol, bekçinin açma sınırı yine geçerli.
    /// </summary>
    public static bool IsRunning(string output) =>
        output.Split('\n').Any(line =>
            ((line.Contains("Hist") && line.Contains("ActivityRecord{")) || line.Contains("ServiceRecord{"))
            && line.Contains(PackageName + "/"));

    /// <summary>
    /// Uygulamadan kendisinin kapanmasını isteyen komut (TV 0.9.114+: MainActivity EXTRA_EXIT → HDMI bırakılır, ekran ve
    /// katman kapanır). Eski TV uygulaması bunu sıradan açılış sayar; o zaman <see cref="ForceStopCommand"/> gönderilir.
    /// Mac/iPhone exitCommand ve Android telefondaki EXIT_COMMAND ile aynı.
    /// </summary>
    public const string ExitCommand = $"shell:am start -n {PackageName}/.MainActivity --ez exit true";

    /// <summary>Kapanma isteğinden sonra <c>am force-stop</c>'a kadar beklenen süre (testlerde kısaltılır).</summary>
    internal static TimeSpan ExitWait { get; set; } = TimeSpan.FromMilliseconds(1500);

    /// <summary>
    /// Kapanma isteğinden sonraki <see cref="RunningCommand"/> çıktısına göre <c>am force-stop</c> gerekiyor mu: uygulama
    /// hâlâ görünüyorsa ya da çıktı okunamıyorsa (boş, <c>grep</c> yok: yığın satırı hiç yok) evet.
    /// </summary>
    public static bool NeedsForceStop(string runningOutput) =>
        IsRunning(runningOutput) || !runningOutput.Contains("Hist", StringComparison.Ordinal);

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
        Stall?.Enter("approve");
        await using var adb = await ConnectAsync(cancellationToken);
        Stall?.OnStall(() => _ = adb.DisposeAsync().AsTask().ContinueWith(t => _ = t.Exception, TaskScheduler.Default));
        Stall?.Enter("reading");
        var dumpsys = await adb.RunAsync($"shell:dumpsys package {PackageName}", cancellationToken: cancellationToken);
        var installed = VersionFromDumpsys(dumpsys);
        if (IsForeign(dumpsys))
        {
            // Bizim kimliğimizle (com.couchsubs.tv) başka imzalı bir uygulama: sürümü bizimkinden yüksekse "güncel" sayılıp
            // o açılıyordu. Kullanıcı onaylamadan dokunulmaz; onaylarsa kaldırılır ve CouchSubs kurulur.
            if (!ReplaceForeign) throw new AndroidInstallException(AndroidInstallError.ForeignApp, ForeignDetail(dumpsys, installed));
            Stall?.Enter("uninstalling");
            await adb.RunAsync($"shell:pm uninstall {PackageName}", cancellationToken: cancellationToken);
            installed = null;
            dumpsys = "";
        }
        // Unknown signature must not make another app with this package name appear up to date.
        if (installed is not null && IsOurs(dumpsys) && !Versions.IsNewer(version, installed))
        {
            // Bu izni vermeyen eski bir CouchSubs'ın kurduğu güncel uygulama da izni alsın.
            await GrantOverlayAsync(adb, cancellationToken);
            return (installed, false);
        }
        // Play'de ve TV'de Play Store varsa Play'den (PlayStoreRedirect.cs); olmazsa APK ile.
        if (await InstallFromPlayAsync(adb, installed, InstalledFromPlay(dumpsys), cancellationToken) is { } fromPlay)
            return (fromPlay, true);
        // Güncellemede TV'de çalışan eski uygulama önce kapatılır (am force-stop); kurulumdan sonra temiz açılır.
        if (installed is not null) await ForceStopAsync(adb, Stall, cancellationToken);
        Stall?.Enter("installing");
        await InstallAsync(adb, apkPath, ReplaceForeign || IsOurs(dumpsys), cancellationToken);
        Installed = true;
        Stall?.Enter("launching");
        await GrantOverlayAsync(adb, cancellationToken);
        await StartFreshAsync(adb, LaunchParams, null, cancellationToken);
        return (version, true);
    }

    /// <summary>Kurulumun bekçisi (AndroidTvApp verir); adımların süresini ölçer, takılınca bağlantıyı kapatır.</summary>
    internal TvStall? Stall { get; set; }

    /// <summary>Bu kurucu APK ile kurdu (ikinci deneme güncel bulsa da "kuruldu" sayılır).</summary>
    internal bool Installed { get; set; }

    /// <summary>Çalışan uygulamayı kapatan komut (Mac/iPhone ve Android telefondaki forceStopCommand ile aynı).</summary>
    public const string ForceStopCommand = $"shell:am force-stop {PackageName}";

    /// <summary>
    /// TV'deki CouchSubs'ı kapatır (güncellemeden önce ve bekçinin "kapat ve aç" denemesinde). #1221: önce kendisinden
    /// kapanması istenir (<see cref="ExitCommand"/>; HDMI girişini bırakır), <see cref="ExitWait"/> beklenir, hâlâ
    /// çalışıyorsa (ya da bilinemiyorsa) <c>am force-stop</c>. Eskiden doğrudan <c>am force-stop</c> gönderiliyordu;
    /// MediaTek'li Philips Google TV'lerde bırakılmayan HDMI TV kapatılıp açılana kadar siyah kalıyordu. Kapatılamasa da
    /// kurulum sürer (paket yöneticisi de kapatır); TV yanıt vermezse bekçi adımı takılmış sayar. Android telefondaki
    /// stopApp ve iPhone'daki stopApp ile aynı.
    /// </summary>
    internal static async Task ForceStopAsync(AdbConnection adb, TvStall? stall, CancellationToken cancellationToken,
        Action<string>? log = null)
    {
        stall?.Enter("closing");
        try { await adb.RunAsync(ExitCommand, cancellationToken: cancellationToken); }
        catch (Exception error) when (error is not OperationCanceledException and not AndroidInstallException) { }
        if (ExitWait > TimeSpan.Zero) await Task.Delay(ExitWait, cancellationToken);
        string after;
        try { after = await adb.RunAsync(RunningCommand, cancellationToken: cancellationToken); }
        catch (Exception error) when (error is not OperationCanceledException and not AndroidInstallException) { after = ""; }
        if (!NeedsForceStop(after))
        {
            log?.Invoke("Android TV: uygulama kapanma isteğiyle kapandı (am force-stop gerekmedi)");
            return;
        }
        log?.Invoke($"Android TV: uygulama kapanma isteğinden {ExitWait.TotalMilliseconds:0} ms sonra hâlâ çalışıyordu; am force-stop");
        try { await adb.RunAsync(ForceStopCommand, cancellationToken: cancellationToken); }
        catch (Exception error) when (error is not OperationCanceledException and not AndroidInstallException) { }
    }

    /// <summary>
    /// Kullanıcı "Kaldırıp Kur" dedi: TV'de bizim kimliğimizi kullanan başka imzalı uygulama kaldırılıp CouchSubs kurulur.
    /// Verilmezse (varsayılan) böyle bir uygulamada <see cref="AndroidInstallError.ForeignApp"/> fırlatılır, hiçbir şey silinmez.
    /// </summary>
    public bool ReplaceForeign { get; init; }

    /// <summary>
    /// CouchSubs TV'nin imza sertifikasının (TV_KEYSTORE, CN=CouchSubs TV, O=Enmera; SHA-256 5FFE122E…D0D5FB) Android'deki
    /// özeti: <c>Signature.hashCode()</c> (sertifikanın DER baytlarında <c>Arrays.hashCode</c>), dumpsys'in yazdığı biçimde.
    /// Play'in uygulama imza anahtarı da budur; Play'den ve ADB ile kurulan kopyanın ikisi de bunu taşır.
    /// </summary>
    public const string OurSignature = "32d37cf9";

    /// <summary>
    /// dumpsys'teki imza özetleri: <c>signatures=PackageSignatures{… version:2, signatures:[32d37cf9], past signatures:[]}</c>
    /// (Android 9+) ya da <c>signatures=PackageSignatures{41ab21 [32d37cf9]}</c> (eski). Satırdaki ilk köşeli parantez geçerli
    /// imzalardır. Okunamazsa boş.
    /// </summary>
    internal static IReadOnlyList<string> SignaturesFromDumpsys(string dumpsys)
    {
        var line = dumpsys.Split('\n').FirstOrDefault(l => l.Contains("signatures=PackageSignatures{", StringComparison.Ordinal));
        if (line is null) return [];
        var open = line.IndexOf('[');
        var close = open < 0 ? -1 : line.IndexOf(']', open + 1);
        if (close < 0) return [];
        return [.. line[(open + 1)..close].Split(',').Select(s => s.Trim().ToLowerInvariant()).Where(s => s.Length > 0)];
    }

    /// <summary>TV'deki com.couchsubs.tv bizim imzamızı taşıyor (kesin).</summary>
    internal static bool IsOurs(string dumpsys) => SignaturesFromDumpsys(dumpsys).Contains(OurSignature);

    /// <summary>
    /// TV'de com.couchsubs.tv kurulu ve imzası bizimki değil: başka bir uygulama bizim kimliğimizi kullanıyor. İmza okunamazsa
    /// (bilinmiyor) yabancı sayılmaz; o zaman da imza farkı kurulumda INSTALL_FAILED_UPDATE_INCOMPATIBLE ile yakalanır.
    /// </summary>
    internal static bool IsForeign(string dumpsys) =>
        VersionFromDumpsys(dumpsys) is not null && SignaturesFromDumpsys(dumpsys) is { Count: > 0 } signatures && !signatures.Contains(OurSignature);

    private static string ForeignDetail(string dumpsys, string? version) =>
        $"TV'de {PackageName} {version ?? "?"} başka bir imzayla kurulu ({string.Join(", ", SignaturesFromDumpsys(dumpsys))}; CouchSubs {OurSignature})";

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

    /// <summary>
    /// APK'yı kurar. İmzası farklı (ya da sürümü yüksek) bir kopya varsa onu ancak <paramref name="mayUninstall"/> ise kaldırır
    /// (kullanıcı onayladı ya da TV'deki kopyanın bizim imzamızı taşıdığı kesin); yoksa
    /// <see cref="AndroidInstallError.ForeignApp"/>: başka imzalı uygulama kullanıcı onayı olmadan silinmez.
    /// </summary>
    private static async Task InstallAsync(AdbConnection adb, string apkPath, bool mayUninstall, CancellationToken cancellationToken)
    {
        var result = await StreamInstallAsync(adb, apkPath, cancellationToken);
        if (result.Contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || result.Contains("INSTALL_FAILED_VERSION_DOWNGRADE"))
        {
            if (!mayUninstall) throw new AndroidInstallException(AndroidInstallError.ForeignApp, result.Trim());
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

    /// <summary>
    /// <c>am start</c> çıktısı uygulamanın zaten çalıştığını söylüyor mu ("Warning: Activity not started, intent has been
    /// delivered to currently running top-most instance" / "its current task has been brought to the front"): ekran yalnız
    /// öne geldi, sayfa yeniden açılmadı. Samsung'daki "resumed"ın karşılığı; Core'daki AndroidTvLauncher.IsResumed,
    /// Mac/iPhone AndroidTVLauncher ve Android telefondaki ile aynı.
    /// </summary>
    public static bool StartedExisting(string output) => output.Contains("Activity not started", StringComparison.Ordinal);

    /// <summary>
    /// Uygulamayı açar; TV "zaten çalışıyor, yalnız öne getirildi" derse eski ekran kapatılıp (<c>am force-stop</c>) temiz
    /// açılır. Samsung kurulumundaki "resumed → was_kill + was_execute" ile aynı (#1248): eski sayfa çalışmayı sürdürüp akışa
    /// bağlanmıyordu.
    /// </summary>
    internal static async Task<string> StartFreshAsync(AdbConnection adb, string? launchParams, Action<string>? log,
        CancellationToken cancellationToken)
    {
        var started = (await adb.RunAsync(StartCommand(launchParams), cancellationToken: cancellationToken)).Trim();
        if (!StartedExisting(started)) return started;
        log?.Invoke($"Android TV: uygulama zaten çalışıyordu ({started}); kapatılıp (am force-stop) yeniden açılıyor");
        return await RestartOnAsync(adb, launchParams, cancellationToken, log);
    }

    /// <summary>
    /// Uygulamayı kapatır (<see cref="ForceStopAsync"/>: kapanma isteği, gerekirse <c>am force-stop</c>) ve temiz açar
    /// (<c>am start</c>); <c>am start</c> çıktısı döner.
    /// </summary>
    internal static async Task<string> RestartOnAsync(AdbConnection adb, string? launchParams, CancellationToken cancellationToken,
        Action<string>? log = null)
    {
        await ForceStopAsync(adb, null, cancellationToken, log);
        return (await adb.RunAsync(StartCommand(launchParams), cancellationToken: cancellationToken)).Trim();
    }

    /// <summary>
    /// Kurulu uygulamayı bu bilgisayarın adresiyle açar (kurmadan, sessizce; çeviri başlarken bekçi çağırır). TV bu
    /// bilgisayarı hiç onaylamadıysa onay sorusu beklenmez: <see cref="AndroidInstallError.NotApproved"/> fırlatılır.
    /// ADB kapalıysa <see cref="AndroidInstallError.Unreachable"/>.
    /// </summary>
    /// <remarks>
    /// Uygulama TV'de zaten çalışıyorsa (ekranı önde ya da arkada, ya da katmanı) <c>am start</c> gönderilmez ve
    /// <see cref="AlreadyRunning"/> döner. X'te bildirildi (Android TV 8, beta.74): <c>am start</c> çalışan uygulamayı öne
    /// çekiyor, TV uygulaması da parametreli açılışta kayıtlı katman tercihine dönüp ekranı kapatıyordu; kullanıcı
    /// CouchSubs'ın ekranında HDMI seçemiyor, TV'nin kendi girişindeyken de CouchSubs öne geliyordu.
    /// </remarks>
    /// <returns><c>am start</c> çıktısı ya da <see cref="AlreadyRunning"/>.</returns>
    public static Task<string> OpenAsync(string host, string keyDirectory, string? launchParams, int port = DefaultPort,
        CancellationToken cancellationToken = default) =>
        OpenAsync(host, keyDirectory, launchParams, restart: false, port, cancellationToken: cancellationToken);

    /// <summary>
    /// <see cref="OpenAsync(string, string, string?, int, CancellationToken)"/>; <paramref name="restart"/> ise uygulama
    /// çalışıyor olsa da kapatılıp (<c>am force-stop</c>) temiz açılır: bekçi uygulamayı çalışırken buldu ama uygulama
    /// <c>SamsungLauncher.ResumeWait</c> içinde bağlanmadı (Samsung'daki #1248 ile aynı yol). Aynı TV'de kurulum ya da başka
    /// bir ADB oturumu sürüyorsa sırası beklenir (#1223; <see cref="TvLane"/>).
    /// </summary>
    public static async Task<string> OpenAsync(string host, string keyDirectory, string? launchParams, bool restart,
        int port = DefaultPort, TvLane? lane = null, Action<string>? log = null, CancellationToken cancellationToken = default)
    {
        if (!await IsReachableAsync(host, port, TimeSpan.FromSeconds(2)))
            throw new AndroidInstallException(AndroidInstallError.Unreachable, "ADB kapalı");
        return await (lane ?? TvLane.Shared).RunAsync(host, restart ? "kapatıp açma" : "açma", async () =>
        {
            await using var adb = await AdbConnection.ConnectAsync(host, port, LoadOrCreateKey(keyDirectory),
                () => throw new AndroidInstallException(AndroidInstallError.NotApproved, "onay gerekiyor"), cancellationToken: cancellationToken);
            return restart ? await RestartOnAsync(adb, launchParams, cancellationToken, log) : await OpenOnAsync(adb, launchParams, cancellationToken);
        }, log, cancellationToken);
    }

    /// <summary><see cref="OpenAsync"/>'in kurulmuş bağlantıdaki adımları: çalışıyorsa dokunmaz, değilse <c>am start</c>.</summary>
    internal static async Task<string> OpenOnAsync(AdbConnection adb, string? launchParams, CancellationToken cancellationToken = default)
    {
        string running;
        try
        {
            running = await adb.RunAsync(RunningCommand, cancellationToken: cancellationToken);
        }
        catch (Exception error) when (error is not OperationCanceledException and not AndroidInstallException)
        {
            running = "";
        }
        if (IsRunning(running))
        {
            // Çalışan uygulama bize bağlı değil (bekçi yalnız o zaman açar): kayıtlı eski bir adrese (bu bilgisayarın eski
            // portu, başka bir CouchSubs) bağlı kalmış olabilir. Adres ekranı öne çekmeden bildirilir (TV 0.9.63+; eskisi yok sayar).
            if (AddressCommand(launchParams) is { } address)
            {
                try { await adb.RunAsync(address, cancellationToken: cancellationToken); }
                catch (Exception error) when (error is not OperationCanceledException and not AndroidInstallException) { }
            }
            return AlreadyRunning;
        }
        return (await adb.RunAsync(StartCommand(launchParams), cancellationToken: cancellationToken)).Trim();
    }

    /// <summary>
    /// TV'de çalışan CouchSubs'a adresi bildiren yayın (TV uygulamasındaki AddressReceiver): ekranı öne çekmez, görüntü
    /// modunu değiştirmez. Parametre yoksa ya da kabukta güvenle gönderilemiyorsa (tek tırnak, satır sonu) null.
    /// Mac/iPhone ve Android telefondaki addressCommand ile aynı.
    /// </summary>
    public static string? AddressCommand(string? launchParams) =>
        string.IsNullOrEmpty(launchParams) || launchParams.IndexOfAny(['\'', '\n', '\r', '\0']) >= 0 ? null
            : $"shell:am broadcast -a {PackageName}.action.ADDRESS -n {PackageName}/.AddressReceiver --es params '{launchParams}'";

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
        var corrupt = false;
        if (File.Exists(path))
        {
            // Okuma hatası (G/Ç) yükselir: okunamayan anahtarın üstüne yenisi yazılmaz.
            var pem = File.ReadAllText(path);
            try
            {
                key.ImportFromPem(pem);
                if (key.KeySize == 2048) return key;
            }
            catch (Exception error) when (error is CryptographicException or ArgumentException) { /* bozuk dosya: yenisi üretilir */ }
            corrupt = true;
        }
        key.Dispose();
        key = RSA.Create(2048);
        // Önce geçici dosyaya yazılır, sonra yerine taşınır: yarım kalan yazma anahtarı bozmaz. Aynı anda iki işlem (Mac'te
        // kurulum yardımcısı ve bekçinin yardımcısı) anahtar üretirse ilk yazılan kalır, ikincisi onu okur; yoksa TV'nin
        // onayladığı anahtarın üstüne başkası yazılır, TV yeniden sorar.
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, key.ExportPkcs8PrivateKeyPem());
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        if (corrupt)
        {
            // Bozuk dosyanın yerine.
            File.Move(temporary, path, overwrite: true);
            return key;
        }
        try
        {
            File.Move(temporary, path, overwrite: false);
            return key;
        }
        catch (IOException) when (File.Exists(path))
        {
            File.Delete(temporary);
            key.Dispose();
            var existing = RSA.Create();
            existing.ImportFromPem(File.ReadAllText(path));
            return existing;
        }
    }

    [GeneratedRegex(@"versionName=(\S+)")]
    private static partial Regex VersionName();
}
