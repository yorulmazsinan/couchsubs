// SPDX-License-Identifier: AGPL-3.0-only

using System.Net;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using TizenSdb;
using TizenSdb.SdbClient;
using TizenSdb.SigningManager;

namespace CouchSubs.TvInstall.Samsung;

public enum SamsungInstallError
{
    /// <summary>TV'de geliştirici modu kapalı ya da TV'ye girilen bilgisayar IP'si bu bilgisayarınki değil.</summary>
    Unreachable,
    LoginFailed,
    CertificateFailed,
    /// <summary>TV, Tizen 3.0'dan (2017) eski.</summary>
    TooOld,
    InstallFailed,
    /// <summary>TV'de yer yok ([116]).</summary>
    NotEnoughSpace,
    /// <summary>TV'de başka sertifikayla imzalı eski kopya var ve kaldırılamadı.</summary>
    CertificateMismatch,
    /// <summary>TV imza sertifikasını reddetti (internet, saat ya da sertifika); bir sonraki denemede yenisi alınır.</summary>
    CertificateRejected,
    /// <summary>TV'nin saati geride; sertifika ona göre henüz geçerli değil.</summary>
    TvClockWrong,
    /// <summary>TV, silinmiş eski kopyanın kaydı yüzünden paket kimliğini engelliyor ([118, -22]).</summary>
    PackageBlocked,
    /// <summary>Kurulum sırasında TV bağlantısı koptu.</summary>
    ConnectionLost,
}

/// <param name="detail">Kullanıcıya da gösterilen ayrıntı: TV'nin hata satırı, Samsung'un yanıtı ya da istisna iletisi.</param>
public sealed class SamsungInstallException(SamsungInstallError error, string? detail = null)
    : Exception(detail is null ? error.ToString() : $"{error}: {detail}")
{
    public SamsungInstallError Error { get; } = error;

    public string? Detail { get; } = detail;
}

/// <summary>Kurulumun TV ile konuşan kısmı; testlerde gerçek TV yerine sahtesi kullanılır.</summary>
internal interface ISamsungTvShell
{
    /// <summary>Hazır (imzalı) paketi gönderip <c>vd_appinstall</c> ile kurar; TV'nin bütün çıktısını döner.</summary>
    Task<string> InstallAsync(CancellationToken cancellationToken);

    Task<string> ShellAsync(string command, CancellationToken cancellationToken);
}

/// <summary>
/// CouchSubs'ın Samsung TV uygulamasını geliştirici modu açık TV'ye kurar: TV'nin DUID'ini okur, gerekirse Samsung
/// hesabıyla TV'ye özel sertifika alır, paketi imzalar ve kurar. sdb bağlantısı ve imza TizenSdb.Core'dan (MIT).
/// </summary>
public sealed partial class SamsungTvInstaller(string host, string profilesDirectory, SamsungCertificates certificates)
{
    public const int SdbPort = 26101;
    public const string AppId = "CouchSubsT.CouchSubs";
    internal const string PackageId = "CouchSubsT";

    /// <summary>
    /// Desteklenen en eski Tizen: 3.0 (2017 modelleri, ör. UE43MU7000U). Sayfa ES5 ile yazıldığından Tizen 3.0'ın
    /// tarayıcısında (Chromium 47) çalışır. Tizen 2.x (2015–2016) hiç denenmedi, kurulum yolu da farklıdır
    /// (Apps2Samsung profili /home/developer'a gönderir); reddedilir.
    /// </summary>
    internal const string MinimumTizen = "3.0";

    /// <summary>
    /// Bu sürüme kadar (dahil) TV, kurulumdan önce dağıtıcı sertifikasının cihaz profilini (device-profile.xml) ister;
    /// yenilerde izin imzanın içindedir. Eşik ve hedef klasör Apps2Samsung'un TizenPermitInstall'ından (MIT).
    /// </summary>
    internal const string DeviceProfileUpTo = "4.0";

    /// <summary>TV'nin bildirdiği Tizen sürümü desteklenmiyor mu? Sürüm okunamadıysa (boş) kurulum denenir.</summary>
    internal static bool IsTooOld(string platform) => platform.Length > 0 && Versions.IsNewer(MinimumTizen, platform);

    /// <summary>Tizen 3.0–4.0 (2017–2018): kurulumdan önce cihaz profili TV'ye gönderilmeli.</summary>
    internal static bool NeedsDeviceProfile(string platform) =>
        platform.Length > 0 && !IsTooOld(platform) && !Versions.IsNewer(platform, DeviceProfileUpTo);

    /// <summary>Sertifika yoksa Samsung girişini başlatır; yoksa null döner ve kurulum giriş adımında durur.</summary>
    public Func<CancellationToken, Task<SamsungAccount>>? SignIn { get; init; }

    public Action<string>? Progress { get; init; }

    /// <summary>Her adım ve TV'nin bütün yanıtları buraya yazılır.</summary>
    public InstallLog Log { get; init; } = new(null);

    /// <summary>
    /// TV'de geliştirici modu açık ve bu bilgisayar kabul ediliyor mu? Samsung yalnız geliştirici modunda girilen IP'den
    /// gelen bağlantıyı kabul eder; başka bilgisayardan port açık görünse de bağlantı hemen kapanır.
    /// </summary>
    public static async Task<bool> IsDevModeOnAsync(string host, TimeSpan? timeout = null)
    {
        using var tcp = new TcpClient();
        using var limit = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(2));
        try
        {
            await tcp.ConnectAsync(host, SdbPort, limit.Token);
            return true;
        }
        catch (Exception error) when (error is SocketException or OperationCanceledException)
        {
            return false;
        }
    }

    /// <summary>Bu TV için kayıtlı geçerli sertifika var mı (giriş gerekmeden kurulabilir mi)?</summary>
    public async Task<bool> HasCertificateAsync(CancellationToken cancellationToken = default)
    {
        await using var device = await ConnectAsync(cancellationToken);
        var duid = await ReadDuidAsync(device, cancellationToken);
        var profile = SigningProfile.In(ProfileDirectory(duid));
        return profile.IsValid(DateTime.UtcNow) && profile.IsFor(duid);
    }

    /// <summary>Paketi imzalayıp kurar ve uygulamayı açar (TV'deki sürüme bakmadan).</summary>
    /// <param name="wgtPath">İmzasız ya da imzalı .wgt; dosyanın kendisine dokunulmaz.</param>
    public Task InstallAsync(string wgtPath, CancellationToken cancellationToken = default) =>
        EnsureInstalledAsync(wgtPath, version: null, cancellationToken);

    /// <summary>
    /// TV'deki CouchSubs sürümüne bakar (<c>0 vd_applist</c>); yoksa ya da <paramref name="version"/>'dan eskiyse
    /// imzalayıp kurar. Bilgisayar yalnız kendi kurduğu sürümü hatırlıyordu; TV'de başka yoldan kurulmuş ya da eski
    /// kalmış uygulama (ör. 0.9.10 gelirken TV'de 0.9.7) hiç güncellenmiyordu.
    /// </summary>
    /// <param name="version">Paketin sürümü; null ise TV'deki sürüme bakılmadan kurulur.</param>
    /// <returns>TV'deki sürüm ve bu çağrının kurup kurmadığı.</returns>
    public async Task<(string Version, bool Installed)> EnsureInstalledAsync(string wgtPath, string? version,
        CancellationToken cancellationToken = default)
    {
        Log.Write($"--- Samsung kurulumu başlıyor: TV {host}, paket {Path.GetFileName(wgtPath)}");
        try
        {
            var result = await InstallCoreAsync(wgtPath, version, cancellationToken);
            Log.Write(result.Installed ? "Kurulum tamam." : $"TV'de {result.Version} sürümü var; kurulum gerekmedi.");
            return result;
        }
        catch (SamsungInstallException error)
        {
            Log.Write($"HATA {error.Error}: {error.Detail}");
            throw;
        }
        catch (OperationCanceledException)
        {
            Log.Write("Kurulum iptal edildi.");
            throw;
        }
        catch (Exception error)
        {
            Log.Write($"Beklenmeyen hata: {error}");
            throw;
        }
    }

    private async Task<(string Version, bool Installed)> InstallCoreAsync(string wgtPath, string? version, CancellationToken cancellationToken)
    {
        await using var device = await ConnectAsync(cancellationToken);
        Progress?.Invoke("reading");
        var capabilities = await device.CapabilityAsync(cancellationToken);
        var platform = capabilities.GetValueOrDefault("platform_version", "").Trim();
        var toolPath = capabilities.GetValueOrDefault("sdk_toolpath")?.Trim() is { Length: > 0 } path ? path : "/opt/usr/apps/tmp";
        Log.Write($"TV: Tizen {(platform.Length > 0 ? platform : "?")}, sdk_toolpath {toolPath}");
        if (IsTooOld(platform))
            throw new SamsungInstallException(SamsungInstallError.TooOld, $"Tizen {platform}");
        if (platform.Length > 0 && Versions.IsNewer("5.0", platform))
            Log.Write($"Tizen {platform}: 2017–2018 TV'si, destek deneysel.");

        var onTv = await ReadInstalledVersionAsync(device, cancellationToken);
        if (version is not null && onTv is not null && !Versions.IsNewer(version, onTv)) return (onTv, false);
        Log.Write(onTv is null ? "TV'de CouchSubs görünmüyor; kuruluyor." : $"TV'de {onTv} var, {version ?? "yeni sürüm"} kuruluyor.");

        var duid = await ReadDuidAsync(device, cancellationToken);
        Log.Write($"DUID: {duid}");
        var directory = ProfileDirectory(duid);
        var profile = SigningProfile.In(directory);
        Log.Write($"Kayıtlı sertifika: {profile.Describe(DateTime.UtcNow, duid)}");
        if (!profile.IsValid(DateTime.UtcNow) || !profile.IsFor(duid))
        {
            if (SignIn is null) throw new SamsungInstallException(SamsungInstallError.LoginFailed, "giriş gerekiyor");
            Progress?.Invoke("signin");
            Log.Write("Samsung hesabıyla giriş bekleniyor (tarayıcı açılıyor).");
            var account = await SignIn(cancellationToken);
            Log.Write("Samsung girişi tamam; sertifika isteniyor.");
            Progress?.Invoke("certificate");
            profile = await certificates.CreateAsync(duid, account, directory, cancellationToken);
            Log.Write($"Yeni sertifika: {profile.Describe(DateTime.UtcNow, duid)}");
        }

        if (NeedsDeviceProfile(platform)) await PushDeviceProfileAsync(device, profile, toolPath, cancellationToken);

        Progress?.Invoke("signing");
        DeleteLeftovers(Path.GetTempPath());
        var staged = Path.Combine(Path.GetTempPath(), $"couchsubs-{Guid.NewGuid():N}.wgt");
        File.Copy(wgtPath, staged);
        try
        {
            await TizenWgtSigner.ReSignWgtWithCertsInPlace(staged, profile.AuthorP12, profile.DistributorP12, profile.Password);
            Log.Write("Paket imzalandı.");
            Progress?.Invoke("installing");
            try
            {
                await InstallWithRecoveryAsync(new SdbShell(device, staged, toolPath), Progress, Log, cancellationToken);
            }
            catch (SamsungInstallException error) when (error.Error is SamsungInstallError.CertificateRejected)
            {
                // TV bu sertifikayı kabul etmiyor; bir sonraki denemede Samsung'dan yenisi istensin.
                SigningProfile.Discard(directory);
                Log.Write("Kayıtlı sertifika bırakıldı; bir sonraki denemede yenisi alınacak.");
                throw;
            }
        }
        finally
        {
            DeleteStaged(staged);
        }
        // TV "kuruldu" deyip eski sürümde kalırsa bu da sessiz geçmesin.
        var after = await ReadInstalledVersionAsync(device, cancellationToken);
        if (version is not null && after is not null && Versions.IsNewer(version, after))
            throw new SamsungInstallException(SamsungInstallError.InstallFailed,
                $"TV kurulumu bitirdi ama TV'de hâlâ {after} sürümü var ({version} kurulmalıydı)");
        await LaunchAsync(device, cancellationToken);
        return (after ?? version ?? "", true);
    }

    /// <summary>TV'deki CouchSubs sürümü; uygulama yoksa ya da liste okunamazsa null.</summary>
    private async Task<string?> ReadInstalledVersionAsync(SdbTcpDevice device, CancellationToken cancellationToken)
    {
        try
        {
            var listing = await device.ShellCommandAsync("0 vd_applist", cancellationToken);
            var found = InstalledVersion(listing);
            Log.Write($"vd_applist: {(found is null ? "CouchSubs yok" : $"CouchSubs {found}")} ({listing.Length} karakter)");
            return found;
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Log.Write($"vd_applist okunamadı: {error.Message}");
            return null;
        }
    }

    /// <summary>
    /// <c>vd_applist</c> çıktısında CouchSubs'ın sürümü. Çıktı uygulama bloklarından oluşur, her satır
    /// <c>---- anahtar = değer ----</c> biçimindedir (Apps2Samsung'un TizenInstalledApps'i).
    /// </summary>
    internal static string? InstalledVersion(string? listing)
    {
        if (string.IsNullOrWhiteSpace(listing)) return null;
        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? found = null;

        void Flush()
        {
            var ids = new[] { fields.GetValueOrDefault("app_tizen_id"), fields.GetValueOrDefault("app_id") };
            if (found is null && ids.Any(IsCouchSubs) && fields.GetValueOrDefault("app_version") is { Length: > 0 } version)
                found = version;
            fields.Clear();
        }

        foreach (var raw in listing.Replace("\r", "").Split('\n'))
        {
            if (!raw.Contains('=') && raw.Contains("----"))
            {
                Flush();
                continue;
            }
            var match = FieldLine().Match(raw);
            if (match.Success) fields[match.Groups["key"].Value] = match.Groups["value"].Value.Trim();
        }
        Flush();
        return found;
    }

    private static bool IsCouchSubs(string? id) =>
        id is { Length: > 0 } && (id.Trim().Equals(AppId, StringComparison.OrdinalIgnoreCase) ||
                                  id.Trim().Equals(PackageId, StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Kurar; TV başka sertifikayla kurulmuş eski kopya ya da paket kimliği yüzünden reddederse eski kopyayı kaldırıp bir
    /// kez daha dener. Sonuç yine başarısızsa TV'nin söylediği sebeple <see cref="SamsungInstallException"/> atar.
    /// </summary>
    internal static async Task InstallWithRecoveryAsync(ISamsungTvShell tv, Action<string>? progress, InstallLog log,
        CancellationToken cancellationToken)
    {
        var output = await tv.InstallAsync(cancellationToken);
        log.Write($"vd_appinstall çıktısı:\n{output.Trim()}");
        var problem = SamsungInstallDiagnostics.Classify(output);
        if (problem == InstallProblem.None) return;
        log.Write($"Kurulum başarısız: {problem}");
        if (!SamsungInstallDiagnostics.RemovingOldCopyMayHelp(problem))
            throw new SamsungInstallException(SamsungInstallDiagnostics.ToError(problem), SamsungInstallDiagnostics.Summary(output));

        // Başka sertifikayla kurulmuş eski kopya ("Author certificate not match") ya da yarım kalmış kayıt: kaldırıp bir
        // kez daha dene. TV sürümüne göre kaldırma paket kimliğini ya da uygulama kimliğini bekliyor; ikisi de denenir.
        progress?.Invoke("uninstalling");
        var removal = "";
        foreach (var id in new[] { PackageId, AppId })
        {
            try { removal += $"{id}: {(await tv.ShellAsync($"0 vd_appuninstall {id}", cancellationToken)).Trim()}\n"; }
            catch (Exception error) when (error is not OperationCanceledException) { removal += $"{id}: {error.Message}\n"; }
        }
        log.Write($"Eski kopya kaldırıldı mı:\n{removal.Trim()}");
        var retry = await tv.InstallAsync(cancellationToken);
        log.Write($"İkinci deneme vd_appinstall çıktısı:\n{retry.Trim()}");
        var retryProblem = SamsungInstallDiagnostics.Classify(retry);
        if (retryProblem == InstallProblem.None) return;
        throw new SamsungInstallException(SamsungInstallDiagnostics.ToError(retryProblem), SamsungInstallDiagnostics.Summary(retry));
    }

    /// <summary>
    /// Uygulamayı açar; açılmasa da kurulum başarılıdır (Mac ve Windows uygulaması da ayrıca açar). TizenSdb ve
    /// Apps2Samsung <c>was_execute</c> kullanır; eski <c>execute</c> bazı TV'lerde yoktur.
    /// </summary>
    private async Task LaunchAsync(SdbTcpDevice device, CancellationToken cancellationToken)
    {
        try
        {
            var reply = await device.ShellCommandAsync($"0 was_execute {AppId}", cancellationToken);
            Log.Write($"Uygulama açılıyor: {reply.Trim()}");
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Log.Write($"Uygulama açılamadı (kurulum yine tamam): {error.Message}");
        }
    }

    /// <summary>
    /// Tizen 3.0–4.0: Tizen Studio'daki "Permit to install applications" adımı. Sertifika alınırken saklanan cihaz
    /// profili TV'nin <c>sdk_toolpath</c> klasörüne gönderilir; TV, imzayı bu profildeki DUID listesine göre kabul eder.
    /// Profil yoksa ya da gönderilemezse kurulum yine denenir: TV reddederse sebebi kurulum çıktısında görünür.
    /// </summary>
    private async Task PushDeviceProfileAsync(SdbTcpDevice device, SigningProfile profile, string toolPath,
        CancellationToken cancellationToken)
    {
        var local = Path.Combine(profile.Directory, "device-profile.xml");
        if (!File.Exists(local))
        {
            Log.Write("Cihaz profili (device-profile.xml) yok; gönderilmeden kuruluyor.");
            return;
        }
        var remote = $"{toolPath}/device-profile.xml";
        try
        {
            await using var file = File.OpenRead(local);
            await device.PushAsync(file, remote, ct: cancellationToken);
            Log.Write($"Cihaz profili gönderildi: {remote}");
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Log.Write($"Cihaz profili gönderilemedi ({remote}): {error.Message}");
        }
    }

    /// <summary>
    /// TizenSdb'nin TizenInstaller'ı paketi açıp kapatmıyor; Windows açık dosyanın silinmesine izin vermiyor. Silme
    /// hatası kurulumun asıl sonucunu örtmesin diye tutamak çöp toplayıcıyla bırakılır, yine silinemezse dosya geçici
    /// klasörde kalır (bir sonraki kurulumda temizlenir).
    /// </summary>
    internal static bool DeleteStaged(string path)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                File.Delete(path);
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                GC.Collect();
                GC.WaitForPendingFinalizers();
            }
        }
        return false;
    }

    /// <summary>Önceki kurulumlardan geçici klasörde kalmış paketler.</summary>
    internal static void DeleteLeftovers(string directory)
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(directory, "couchsubs-*.wgt"))
                if (File.GetLastWriteTimeUtc(file) < DateTime.UtcNow.AddMinutes(-10)) DeleteStaged(file);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* temizlik isteğe bağlı */ }
    }

    private string ProfileDirectory(string duid) => Path.Combine(profilesDirectory, SafeName().Replace(duid, "_"));

    private async Task<SdbTcpDevice> ConnectAsync(CancellationToken cancellationToken)
    {
        if (!IPAddress.TryParse(host, out var address))
            throw new SamsungInstallException(SamsungInstallError.Unreachable, $"geçersiz TV adresi: {host}");
        var device = new SdbTcpDevice(address, SdbPort);
        try
        {
            await device.ConnectAsync(cancellationToken);
            Log.Write($"sdb bağlantısı kuruldu ({host}:{SdbPort}).");
            return device;
        }
        catch (Exception error) when (error is not OperationCanceledException || !cancellationToken.IsCancellationRequested)
        {
            await device.DisposeAsync();
            throw new SamsungInstallException(SamsungInstallError.Unreachable, $"sdb {host}:{SdbPort}: {error.Message}");
        }
    }

    private static async Task<string> ReadDuidAsync(SdbTcpDevice device, CancellationToken cancellationToken)
    {
        // Yavaş TV'lerde ilk yanıt boş gelebiliyor; birkaç kez dene.
        var last = "";
        for (var attempt = 0; attempt < 3; attempt++)
        {
            last = await device.ShellCommandAsync("0 getduid", cancellationToken);
            var duid = last.Split('\n')[0].Trim();
            if (IsDuid(duid)) return duid;
            await Task.Delay(500, cancellationToken);
        }
        throw new SamsungInstallException(SamsungInstallError.Unreachable,
            $"TV kimliği (DUID) okunamadı; TV'nin yanıtı: {(last.Trim() is { Length: > 0 } text ? text : "boş")}");
    }

    internal static bool IsDuid(string text) => DuidPattern().IsMatch(text);

    /// <summary>Geriye uyumluluk ve testler için: çıktı kurulumun başarısız olduğunu mu söylüyor?</summary>
    internal static bool InstallFailed(string log) => SamsungInstallDiagnostics.Failed(log);

    /// <summary>TizenInstaller sonucu konsola yazar; çıktıyı yakalayıp hatayı oradan anlarız.</summary>
    private static readonly SemaphoreSlim ConsoleGate = new(1, 1);

    private static async Task<string> CaptureAsync(Func<Task> body)
    {
        await ConsoleGate.WaitAsync();
        var original = Console.Out;
        var writer = new StringWriter();
        Console.SetOut(writer);
        try
        {
            await body();
        }
        catch (Exception error)
        {
            writer.WriteLine($"install failed: {error.GetType().Name}: {error.Message}");
        }
        finally
        {
            Console.SetOut(original);
            ConsoleGate.Release();
        }
        return writer.ToString();
    }

    /// <summary>Gerçek TV: TizenSdb'nin sdb bağlantısı ve TizenInstaller'ı.</summary>
    private sealed class SdbShell(SdbTcpDevice device, string stagedPackage, string toolPath) : ISamsungTvShell
    {
        public Task<string> InstallAsync(CancellationToken cancellationToken) =>
            CaptureAsync(() => new TizenInstaller(stagedPackage, device, toolPath).InstallApp());

        public Task<string> ShellAsync(string command, CancellationToken cancellationToken) =>
            device.ShellCommandAsync(command, cancellationToken);
    }

    [GeneratedRegex(@"^[\s-]*(?<key>[A-Za-z_]+)\s*=\s*(?<value>.*?)[\s-]*$")]
    private static partial Regex FieldLine();

    [GeneratedRegex(@"^[A-Za-z0-9_\-+=/]{8,}$")]
    private static partial Regex DuidPattern();

    [GeneratedRegex(@"[^A-Za-z0-9_\-]")]
    private static partial Regex SafeName();
}
