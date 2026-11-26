// SPDX-License-Identifier: AGPL-3.0-only

using System.ComponentModel;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CouchSubs.Core.LgTv;

public sealed record CommandResult(int Status, string Output);

/// <summary>Dış komut çalıştıran her şey (gerçekte <see cref="ProcessRunner"/>).</summary>
public interface ICommandRunner
{
    Task<CommandResult> RunAsync(string executable, IReadOnlyList<string> arguments, string? inputFile);
}

/// <summary>TV uygulamasını kurarken çıkan sorunlar (LG, Samsung ve Android TV ortak).</summary>
public enum DevModeError
{
    Unreachable, KeyServerOff, WrongPassphrase, KeyRefused, InstallFailed, ToolMissing,
    /// <summary>Samsung: TV Tizen 2.4'ten (2016) eski.</summary>
    TooOld,
    /// <summary>Samsung hesabıyla giriş tamamlanmadı.</summary>
    SignInFailed,
    /// <summary>Samsung TV'ye özel sertifikayı vermedi.</summary>
    CertificateFailed,
    /// <summary>Android: TV'de hata ayıklama izni verilmedi.</summary>
    NotApproved,
    /// <summary>TV kurulumda yer kalmadığını söyledi.</summary>
    NotEnoughSpace,
    /// <summary>Samsung: TV'de başka sertifikayla imzalı eski kopya var ve kaldırılamadı.</summary>
    CertificateMismatch,
    /// <summary>Samsung: TV imza sertifikasını reddetti (internet, saat ya da sertifika).</summary>
    CertificateRejected,
    /// <summary>TV'nin saati geride. Samsung: sertifika ona göre henüz geçerli değil. LG: TV paketi "ipk verified failed"
    /// (errorCode -5) ile reddetti; paketteki dosya tarihleri TV'ye göre gelecekte.</summary>
    TvClockWrong,
    /// <summary>Samsung: TV, silinmiş eski kopyanın kaydı yüzünden uygulamayı kabul etmiyor ([118, -22]).</summary>
    PackageBlocked,
    /// <summary>Kurulum sırasında TV bağlantısı koptu.</summary>
    ConnectionLost,
    /// <summary>Samsung: TV'deki "Host PC IP" bu bilgisayarın adresi değil; sdb denenmez (#343).</summary>
    HostPcMismatch,
    /// <summary>TV'de CouchSubs'ın kimliğiyle başka bir uygulama kurulu; kaldırıp CouchSubs'ı kurmak için kullanıcı onayı gerekir.</summary>
    ForeignApp,
    /// <summary>LG: SSH (9922) bağlanmıyor ama Key Server (9991) yanıt veriyor; geliştirici modu açık görünüyor, TV kurulum
    /// bağlantısını reddediyor (TV yeniden başlamamış ya da webOS Hub'lı TV'nin yazılımında bu kapı kapalı; #200, #1116).
    /// Mac'teki devConnectionClosed, iPhone/Android'deki restartNeeded ile aynı durum ve metin.</summary>
    DevConnectionClosed,
    /// <summary>Kayıtlı adreste TV hiç yanıt vermiyor (kapılar zaman aşımında) ve TV ağda yeniden aranınca da bulunamadı
    /// (TvReach). "Geliştirici modu kapalı" ya da "Key Server kapalı" denmez: TV'de ikisi açık olabilir. Mac tvNotResponding.</summary>
    TvNotResponding,
}

/// <param name="detail">Sorunu bulmak için ayrıntı (komut çıktısı gibi); hata günlüğüne yazılır, kullanıcıya gösterilmez.</param>
public sealed class DevModeException(DevModeError error, string? detail = null)
    : Exception(detail is null ? error.ToString() : $"{error}: {detail}")
{
    public DevModeError Error { get; } = error;

    /// <summary>TV'nin ya da aracın verdiği asıl sebep (ör. Samsung'un "install failed[118]" çıktısı).</summary>
    public string? Detail { get; } = detail;
}

/// <summary>Key Server'dan gelen anahtarın parolasını çözen ssh-keygen'in yeri.</summary>
public sealed record DevModeTools(string SshKeygen)
{
    public static DevModeTools ForThisSystem() => OperatingSystem.IsWindows()
        ? new(Path.Combine(Environment.SystemDirectory, "OpenSSH", "ssh-keygen.exe"))
        : new("/usr/bin/ssh-keygen");
}

/// <summary>
/// TV uygulamasını LG'nin geliştirici modu üzerinden kurar ve günceller.
/// Geliştirici modu açık TV 9922 portunda SSH bekler; anahtar Key Server'dan bir kez alınır.
/// </summary>
public sealed class DevModeInstaller(IRemoteShell shell, TimeSpan? pollInterval = null, TimeSpan? installTimeout = null,
    TimeSpan? verifyTimeout = null)
{
    /// <summary>TV'ye uygulamanın içinden SSH ile bağlanan kurucu. Kurulum komutu TV'nin sonucunu birkaç dakika bekler.</summary>
    public static DevModeInstaller ForTv(string host, string keyFile) =>
        new(new SshNetShell(host, Port, keyFile) { CommandTimeout = TimeSpan.FromMinutes(5) });

    public const int Port = 9922;
    private const string AppInfoPath = "/media/developer/apps/usr/palm/applications/com.couchsubs.tv/appinfo.json";
    public const string TempDir = "/media/developer/temp";
    private const string InstallLog = TempDir + "/couchsubs-install.log";

    /// <summary>ares-install gibi paket TV'ye kendi adıyla yüklenir (<c>/media/developer/temp/com.couchsubs.tv_0.9.6_all.ipk</c>).</summary>
    public static string RemotePackage(string package) => $"{TempDir}/{Path.GetFileName(package)}";

    /// <summary><c>com.couchsubs.tv_0.6.1_all.ipk</c> → <c>0.6.1</c></summary>
    public static string? VersionOfPackage(string name)
    {
        var parts = name.Split('_');
        return name.EndsWith(".ipk", StringComparison.Ordinal) && parts.Length >= 3 ? parts[1] : null;
    }

    public static bool IsNewer(string a, string b) =>
        Version.TryParse(a, out var left) && Version.TryParse(b, out var right) && left > right;

    public static string? VersionFromAppInfo(string text)
    {
        var match = Regex.Match(text, "\"version\"\\s*:\\s*\"([^\"]+)\"");
        return match.Success ? match.Groups[1].Value : null;
    }

    /// <summary>Key Server'ın (TV'deki Developer Mode uygulaması) anahtarı verdiği port.</summary>
    public const int KeyServerPort = 9991;

    /// <summary>
    /// TV'de geliştirici modu açık mı? Kapalıysa portlar yanıt vermez. SSH (9922) ya da Key Server (9991) yanıt verirse
    /// açık sayılır: yalnız SSH'a bakılırken TV'de Key Server ve parola göründüğü halde SSH geç yanıt verince parola alanı
    /// hiç çıkmıyordu (#94).
    /// </summary>
    public static async Task<bool> IsDevModeOnAsync(string host, TimeSpan? timeout = null)
    {
        var checks = await Task.WhenAll(IsPortOpenAsync(host, Port, timeout), IsPortOpenAsync(host, KeyServerPort, timeout));
        return checks[0] || checks[1];
    }

    public static async Task<bool> IsPortOpenAsync(string host, int port, TimeSpan? timeout)
    {
        using var client = new TcpClient();
        using var cancellation = new CancellationTokenSource(timeout ?? TimeSpan.FromSeconds(2));
        try
        {
            await client.ConnectAsync(host, port, cancellation.Token);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static Uri KeyUrl(string host) => new($"http://{host}:{KeyServerPort}/webos_rsa");

    /// <summary>Key Server'dan anahtarı alır ve TV ekranındaki parolayla çözer.</summary>
    public static async Task<string> FetchKeyAsync(string host, string passphrase, ICommandRunner runner, DevModeTools tools)
    {
        byte[] key;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            key = await http.GetByteArrayAsync(KeyUrl(host));
        }
        catch (Exception)
        {
            throw new DevModeException(DevModeError.KeyServerOff);
        }
        // TV'nin anahtarı eski PEM biçimindedir; uygulamanın içinde çözülür, dış araca ve dosya izinlerine bağlı kalınmaz.
        var pem = System.Text.Encoding.UTF8.GetString(key);
        if (LegacyPemKey.IsLegacyEncrypted(pem)) return DecryptWithCaseFallback(pem, passphrase.Trim());

        var file = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            await WritePrivateAsync(file, key);
            var result = await runner.RunAsync(tools.SshKeygen, ["-q", "-p", "-P", passphrase, "-N", "", "-f", file], null);
            if (result.Status != 0)
            {
                // Yalnız ssh-keygen parolayı reddettiyse "parola yanlış" denir; başka sebep (ör. dosya izni) günlüğe gider.
                var wrong = result.Output.Contains("passphrase", StringComparison.OrdinalIgnoreCase)
                    && (result.Output.Contains("incorrect", StringComparison.OrdinalIgnoreCase)
                        || result.Output.Contains("bad", StringComparison.OrdinalIgnoreCase));
                throw new DevModeException(wrong ? DevModeError.WrongPassphrase : DevModeError.InstallFailed, result.Output.Trim());
            }
            return await File.ReadAllTextAsync(file);
        }
        finally
        {
            File.Delete(file);
        }
    }

    /// <summary>TV parolayı büyük harfle gösterir; küçük harfle yazılmışsa büyük harfli hâli de denenir.</summary>
    private static string DecryptWithCaseFallback(string pem, string passphrase)
    {
        try
        {
            return LegacyPemKey.Decrypt(pem, passphrase);
        }
        catch (DevModeException error) when (error.Error == DevModeError.WrongPassphrase && passphrase != passphrase.ToUpperInvariant())
        {
            return LegacyPemKey.Decrypt(pem, passphrase.ToUpperInvariant());
        }
    }

    /// <summary>
    /// Linux ve macOS'ta ssh-keygen başkalarının okuyabildiği anahtar dosyasını açmaz ("bad permissions") ve bu,
    /// parola doğruyken "parola yanlış" diye görünürdü; dosya baştan yalnız sahibine açık (0600) oluşturulur.
    /// </summary>
    public static async Task WritePrivateAsync(string file, byte[] content)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        await using var stream = new FileStream(file, options);
        await stream.WriteAsync(content);
    }

    /// <summary>TV'deki sürüm; uygulama kurulu değilse null.</summary>
    public async Task<string?> InstalledVersionAsync()
    {
        var result = await SshAsync($"cat {AppInfoPath}");
        return VersionFromAppInfo(result.Output);
    }

    /// <summary>
    /// TV'deki sürüm (kurulu değilse null). TV'de com.couchsubs.tv kimliğiyle başka bir uygulama varsa (appinfo.json'daki ad
    /// CouchSubs ya da üretici Enmera değil) <see cref="DevModeError.ForeignApp"/> fırlatır: sürümü bizimkinden yüksekse
    /// "güncel" sayılıp o açılıyordu; kullanıcı onaylamadan üstüne kurulmaz.
    /// </summary>
    public async Task<string?> CheckInstalledVersionAsync()
    {
        var info = (await SshAsync($"cat {AppInfoPath}")).Output;
        var version = VersionFromAppInfo(info);
        if (version is not null && IsForeignAppInfo(info))
            throw new DevModeException(DevModeError.ForeignApp, $"\"{AppInfoField(info, "title")}\" ({AppInfoField(info, "vendor")}) {version}");
        return version;
    }

    /// <summary>CouchSubs'ın appinfo.json'ındaki ad ve üretici (tv-webos/appinfo.json).</summary>
    public const string OurTitle = "CouchSubs", OurVendor = "Enmera";

    /// <summary>appinfo.json'daki ad CouchSubs değil ya da üretici Enmera değil. Alan yoksa yabancı sayılmaz.</summary>
    public static bool IsForeignAppInfo(string text) =>
        (AppInfoField(text, "title") is { } title && !title.Trim().Equals(OurTitle, StringComparison.OrdinalIgnoreCase)) ||
        (AppInfoField(text, "vendor") is { } vendor && !vendor.Trim().Equals(OurVendor, StringComparison.OrdinalIgnoreCase));

    private static string? AppInfoField(string text, string key)
    {
        var match = Regex.Match(text, $"\"{key}\"\\s*:\\s*\"([^\"]*)\"");
        return match.Success ? match.Groups[1].Value : null;
    }

    /// <summary>
    /// TV'deki com.couchsubs.tv'yi kaldırır (ares-install --remove'un luna çağrısı). Yalnız kullanıcı "Kaldırıp Kur" deyince
    /// çağrılır. TV'nin yanıtını döner (günlük için).
    /// </summary>
    public async Task<string> RemoveAppAsync() =>
        (await SshAsync(RemoveCommand)).Output.Trim();

    /// <summary>Kaldırma TV'de arka planda sürer: appinfo.json gidene kadar (en çok 20 sn) beklenir, kurulum ona çarpmasın.</summary>
    public const string RemoveCommand =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.appInstallService/dev/remove' '{\"id\":\"com.couchsubs.tv\",\"subscribe\":false}'; " +
        "i=0; while [ -f " + AppInfoPath + " ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done";

    /// <summary>
    /// TV'de açık com.couchsubs.tv'yi kapatır (ares-launch --close'un luna çağrısı) ve webOS'un süreci bırakması için kısa
    /// bekler. beta.89 (LG): 0.9.81'den 0.9.84'e güncellenen TV'de appinfo.json 0.9.84 diyordu, açık uygulama ise 0.9.81'in
    /// kodunu çalıştırmayı sürdürüyordu: kurulumdan sonra uygulama kapatılmıyordu, açma komutu açık uygulamayı yalnız öne
    /// getiriyor (webOSRelaunch), sayfa diskten yeniden okunmuyordu. Mac, iPhone ve Android'deki komutla aynı.
    /// </summary>
    public const string CloseCommand =
        "/usr/bin/luna-send-pub -n 1 'luna://com.webos.applicationManager/closeByAppId' '{\"id\":\"com.couchsubs.tv\"}'; sleep 2";

    /// <summary>Uygulamayı kapatır; açık değilse ya da TV reddederse kurulum yine başarılıdır. TV'nin yanıtını döner.</summary>
    public async Task<string> CloseAppAsync()
    {
        try { return (await SshAsync(CloseCommand)).Output.Trim(); }
        catch (Exception error) when (error is not OperationCanceledException) { return error.Message; }
    }

    /// <summary>
    /// Paketi TV'ye yükler ve ares-install'un yaptığı gibi kurar: kurulum aboneliği TV "installed" ya da hata diyene kadar
    /// açık kalır, paket ancak bundan sonra silinir. Eskiden <c>luna-send -n 1</c> ilk yanıttan sonra çıkıyordu; abonelik
    /// kapanınca bazı webOS sürümleri kurulumu yarıda bırakıyor, biz de sürüm görünmeyince "boş alan" hatası veriyorduk.
    /// </summary>
    public async Task InstallAsync(string package, string version)
    {
        var remote = RemotePackage(package);
        // Önceki denemelerden kalan paketler TV'de yer kaplamasın.
        var upload = await SshAsync(
            $"mkdir -p {TempDir} && rm -f {TempDir}/com.couchsubs.tv_*.ipk {TempDir}/couchsubs.ipk && cat > '{remote}'", package);
        if (upload.Status != 0)
            throw Failure($"yükleme çıkış kodu {upload.Status}: {Short(upload.Output)}", upload.Output);
        // Paket TV'ye eksiksiz ulaştı mı? (wc yoksa ya da çıktı okunamazsa denetim atlanır.)
        var expected = new FileInfo(package).Length;
        var size = await SshAsync($"wc -c < '{remote}'");
        if (long.TryParse(size.Output.Trim(), out var actual) && actual != expected)
            throw new DevModeException(DevModeError.InstallFailed, $"paket TV'ye eksik ya da bozuk ulaştı: {actual}/{expected} bayt");

        var wait = installTimeout ?? TimeSpan.FromMinutes(3);
        var response = await SshAsync(InstallCommand(remote, (int)Math.Max(1, Math.Ceiling(wait.TotalSeconds))));
        var outcome = ParseInstallReplies(response.Output);
        if (outcome.Failed)
        {
            var reason = string.IsNullOrWhiteSpace(outcome.Reason) ? $"kurulum başarısız: {Short(response.Output)}" : outcome.Reason;
            // "ipk verified failed" (-5): TV'nin saati okunur; çok gerideyse kullanıcıya saati düzeltmesi söylenir.
            if (IsPackageVerifyFailure(reason))
            {
                string? clock;
                try { clock = (await SshAsync(ClockCommand)).Output; }
                catch (DevModeException) { clock = null; }
                await RemoveAsync(remote);
                var (clockWrong, detail) = VerifyFailureDetail(reason, clock, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                throw new DevModeException(clockWrong ? DevModeError.TvClockWrong : DevModeError.InstallFailed, detail);
            }
            await RemoveAsync(remote);
            throw Failure(reason, response.Output);
        }

        // TV "installed" dese de (ya da sonucu okunamadıysa) sürüm appinfo.json'dan doğrulanır.
        var timer = Stopwatch.StartNew();
        var limit = verifyTimeout ?? TimeSpan.FromSeconds(outcome.Installed ? 30 : 60);
        while (true)
        {
            if (await InstalledVersionAsync() == version)
            {
                await RemoveAsync(remote);
                // Açık (eski) uygulama kapatılır; sonra açılan uygulama yeni sürümü diskten yükler (bkz. CloseCommand).
                await CloseAppAsync();
                return;
            }
            if (timer.Elapsed >= limit) break;
            await Task.Delay(pollInterval ?? TimeSpan.FromSeconds(2));
        }
        // Sonuç gelmediyse paket silinmez: kurulum TV'de sürüyor olabilir; bir sonraki deneme onu temizler.
        if (outcome.Installed) await RemoveAsync(remote);
        throw new DevModeException(DevModeError.InstallFailed,
            $"TV'de {version} sürümü görünmedi; kurulum yanıtı ({response.Status}): {Short(response.Output)}");
    }

    /// <summary>
    /// TV'de kurulumu başlatan kabuk komutu. <c>luna-send-pub -i</c> (ares-install'un kullandığı biçim) girişi açık kaldıkça
    /// aboneliği sürdürür; giriş <c>sleep</c>'ten gelir. Yanıtlar dosyaya yazılır; TV "installed" ya da hata dediğinde,
    /// luna-send kendiliğinden çıktığında ya da süre dolduğunda yanıtlar basılır ve luna-send kapatılır. sleep'in
    /// çıkışları SSH kanalına bağlı değildir; oturum onu beklemez.
    /// </summary>
    public static string InstallCommand(string remotePackage, int waitSeconds)
    {
        var parameters = $"{{\"id\":\"com.ares.defaultName\",\"ipkUrl\":\"{remotePackage}\",\"subscribe\":true}}";
        return string.Join("; ",
            $"rm -f {InstallLog}",
            $"sleep {waitSeconds + 30} </dev/null 2>/dev/null | /usr/bin/luna-send-pub -i 'luna://com.webos.appInstallService/dev/install' '{parameters}' >{InstallLog} 2>&1 & L=$!",
            "i=0",
            $"while [ $i -lt {waitSeconds} ]; do grep -q -i -e '\"state\" *: *\"installed' -e 'failed' -e '\"returnValue\" *: *false' -e '\"state\" *: *\"success' {InstallLog} 2>/dev/null && break; kill -0 $L 2>/dev/null || break; sleep 1; i=$((i+1)); done",
            $"cat {InstallLog}",
            "kill $L 2>/dev/null",
            $"rm -f {InstallLog}");
    }

    /// <summary>luna-send yanıtlarının sonucu; <see cref="Reason"/> TV'nin verdiği sebeptir.</summary>
    public sealed record InstallOutcome(bool Installed, bool Failed, string? Reason);

    /// <summary>
    /// luna-send'in satır satır JSON yanıtlarını ares-install gibi okur: <c>returnValue: false</c> ya da
    /// <c>details.state</c> içinde FAILED hata, <c>installed</c>/<c>SUCCESS</c> başarıdır.
    /// </summary>
    public static InstallOutcome ParseInstallReplies(string output)
    {
        var pending = "";
        foreach (var line in output.Split('\n'))
        {
            pending += line.Trim();
            if (pending.Length == 0) continue;
            if (!pending.StartsWith('{'))
            {
                // luna-send'in kendi yazısı (ör. "Error: ..."); ares de JSON olmayanı atlar.
                pending = "";
                continue;
            }
            JsonElement reply;
            try
            {
                using var document = JsonDocument.Parse(pending);
                reply = document.RootElement.Clone();
            }
            catch (JsonException)
            {
                continue; // Satır yarım; sonrakiyle birleşir.
            }
            pending = "";

            JsonElement? details = reply.TryGetProperty("details", out var d) && d.ValueKind == JsonValueKind.Object ? d : null;
            var state = Text(details, "state") ?? "";
            if (reply.TryGetProperty("returnValue", out var ok) && ok.ValueKind == JsonValueKind.False)
                return new(false, true, Reason(Text(reply, "errorText") ?? Text(reply, "errorMessage"), Text(reply, "errorCode")));
            if (state.Contains("failed", StringComparison.OrdinalIgnoreCase))
                return new(false, true, Reason(Text(details, "reason") ?? Text(details, "errorText") ?? state,
                    Text(details, "errorCode") ?? Text(reply, "errorCode")));
            if (state.Contains("installed", StringComparison.OrdinalIgnoreCase) || state.StartsWith("success", StringComparison.OrdinalIgnoreCase))
                return new(true, false, null);
        }
        return new(false, false, null);
    }

    /// <summary>
    /// TV'nin saati (UTC, saniye). webOS'un kurulum servisi paketi GNU tar ile açar ve tar'ın her uyarısını hata sayar:
    /// paketteki dosya tarihleri TV'nin saatine göre gelecekteyse kurulum "ipk verified failed" (errorCode -5) ile
    /// reddedilir (LG OLED CX/webOS 5'te ağ saati alınamayınca saat 2020-01-01'e döner). Paket artık tarihleri 2010'a
    /// çekilmiş gelir (scripts/normalize-ipk.py); TV'nin saati yine de günlüğe yazılır ve çok gerideyse kullanıcıya
    /// saati düzeltmesi söylenir. Mac, iPhone ve Android'deki komut, eşik ve ayrıntı metniyle aynı.
    /// </summary>
    public const string ClockCommand = "date +%s";
    /// <summary>TV bu kadar saniyeden fazla geride ise sebep saattir.</summary>
    public const long MaxClockLag = 600;

    /// <summary>TV paketi doğrulayamadı mı ("ipk verified failed", errorCode -5)?</summary>
    public static bool IsPackageVerifyFailure(string text) => Regex.IsMatch(text, @"verif|errorCode -5\b", RegexOptions.IgnoreCase);

    /// <summary>-5 hatasının ayrıntısı: TV'nin sebebi ve iki saat; saat çok gerideyse <c>ClockWrong</c>.</summary>
    public static (bool ClockWrong, string Detail) VerifyFailureDetail(string reason, string? tvClock, long nowSeconds)
    {
        if (!long.TryParse(tvClock?.Trim(), System.Globalization.NumberStyles.AllowLeadingSign, System.Globalization.CultureInfo.InvariantCulture, out var tv))
            return (false, $"{reason}; TV saati okunamadı");
        var lag = nowSeconds - tv;
        var side = lag >= 0 ? $"{lag} sn geride" : $"{-lag} sn ileride";
        return (lag > MaxClockLag, $"{reason}; TV saati {Utc(tv)} UTC, bu cihaz {Utc(nowSeconds)} UTC (TV {side})");
    }

    private static string Utc(long seconds) =>
        DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>TV ya da kabuk yer kalmadığını mı söylüyor?</summary>
    public static bool IsStorageProblem(string text) => Regex.IsMatch(text,
        @"no space|not enough (free )?(space|storage)|insufficient (free )?(space|storage)|out of space|storage (is )?full|disk (is )?full|ENOSPC|lack of (space|storage)",
        RegexOptions.IgnoreCase);

    private static DevModeException Failure(string detail, string evidence) =>
        new(IsStorageProblem(evidence) || IsStorageProblem(detail) ? DevModeError.NotEnoughSpace : DevModeError.InstallFailed, detail);

    private static string Reason(string? text, string? code)
    {
        var reason = (text ?? "").Trim();
        return string.IsNullOrWhiteSpace(code) ? reason : $"{reason} (errorCode {code})".Trim();
    }

    private static string? Text(JsonElement? element, string name) =>
        element is { } e && e.TryGetProperty(name, out var value)
            ? value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Number => value.GetRawText(),
                _ => null,
            }
            : null;

    private async Task RemoveAsync(string remote)
    {
        try { await SshAsync($"rm -f '{remote}'"); } catch (DevModeException) { /* geçici dosya kalabilir */ }
    }

    private static string Short(string text) => text.Length <= 500 ? text.Trim() : text[..500].Trim() + "…";

    private const string SessionTokenPath = "/var/luna/preferences/devmode_enabled";
    public static Uri RenewUrl(string token) => new($"https://developer.lge.com/secure/ResetDevModeSession.dev?sessionToken={Uri.EscapeDataString(token)}");
    public static Uri CheckUrl(string token) => new($"https://developer.lge.com/secure/CheckDevModeSession.dev?sessionToken={Uri.EscapeDataString(token)}");

    /// <summary>
    /// Geliştirici modunun 1000 saatlik süresini baştan başlatır (TV'deki Developer Mode uygulamasının EXTEND düğmesi
    /// gibi). Oturum jetonu TV'den okunur ve LG'nin sunucusuna gönderilir; webOS Homebrew'un dev-manager-desktop
    /// aracının yaptığının aynısı. Başarısız olursa yalnız uyarı döner: süre dolmadan kullanıcı TV'den de uzatabilir.
    /// </summary>
    /// <returns>Kalan süre (saat); bilinmiyorsa null.</returns>
    public async Task<int?> RenewSessionAsync(HttpClient http)
    {
        var token = (await SshAsync($"cat {SessionTokenPath}")).Output.Trim();
        if (token.Length == 0 || token.Contains(' ')) return null;
        try
        {
            var renewed = await http.GetStringAsync(RenewUrl(token));
            if (!renewed.Contains("success", StringComparison.OrdinalIgnoreCase)) return null;
            return RemainingHours(await http.GetStringAsync(CheckUrl(token)));
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException)
        {
            return null;
        }
    }

    /// <summary>LG'nin yanıtındaki kalan süre <c>999:58:40</c> (saat:dakika:saniye) biçimindedir.</summary>
    public static int? RemainingHours(string response)
    {
        var match = Regex.Match(response, @"(\d{1,4}):(\d{2}):(\d{2})");
        return match.Success ? int.Parse(match.Groups[1].Value) : null;
    }

    private Task<CommandResult> SshAsync(string command, string? input = null) => shell.RunAsync(command, input);
}

/// <summary>Komutları <see cref="Process"/> ile çalıştırır; pencere açmaz.</summary>
public sealed class ProcessRunner : ICommandRunner
{
    public async Task<CommandResult> RunAsync(string executable, IReadOnlyList<string> arguments, string? inputFile)
    {
        var start = new ProcessStartInfo(executable)
        {
            RedirectStandardInput = inputFile is not null,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);

        Process? started;
        try
        {
            started = ChildProcessGuard.Start(start);
        }
        catch (Win32Exception)
        {
            // Windows'un OpenSSH istemcisi (ssh-keygen) kaldırılmış olabilir.
            throw new DevModeException(DevModeError.ToolMissing);
        }
        using var process = started ?? throw new DevModeException(DevModeError.InstallFailed, "CouchSubs is shutting down for an update");
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        if (inputFile is not null)
        {
            await using (var input = File.OpenRead(inputFile))
                await input.CopyToAsync(process.StandardInput.BaseStream);
            process.StandardInput.Close();
        }
        await process.WaitForExitAsync();
        return new CommandResult(process.ExitCode, await output + await error);
    }
}
