// SPDX-License-Identifier: AGPL-3.0-only
// Mac uygulamasının Samsung ve Android TV kurulumu için çağırdığı yardımcı. Windows uygulaması aynı kitaplığı
// (CouchSubs.TvInstall) doğrudan kullanır. Her satır bir JSON olaydır:
//   {"event":"progress","step":"signing"}   {"event":"login","url":"https://…"}   {"event":"approve"}
//   {"event":"done","version":"0.7.0","installed":true}   {"event":"error","code":"Unreachable","message":"…"}
//   {"event":"found","hosts":["192.168.1.40"]}

using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;
using CouchSubs.TvInstall;
using CouchSubs.TvInstall.Android;
using CouchSubs.TvInstall.Samsung;
using TizenSdb.SigningManager;

// TizenInstaller konsola yazar ve kurulum sırasında Console.Out yakalanır; olaylar her zaman gerçek çıktıya gider.
var output = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
var gate = new object();

void Emit(string name, params (string Key, JsonNode? Value)[] fields)
{
    var json = new JsonObject { ["event"] = name };
    foreach (var (key, value) in fields) json[key] = value;
    lock (gate) output.WriteLine(json.ToJsonString());
}

string Option(string name) =>
    args.SkipWhile(a => a != name).Skip(1).FirstOrDefault()
    ?? throw new ArgumentException($"{name} eksik");

// Kurulum günlüğü (Mac: ~/Library/Logs/CouchSubs/tvinstall.log); verilmezse yazılmaz.
var log = new InstallLog(args.SkipWhile(a => a != "--log").Skip(1).FirstOrDefault());

using var cancel = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancel.Cancel(); };
// Mac uygulaması kapanırsa yardımcı da kapansın: girdi kapanınca iptal et.
_ = Task.Run(async () =>
{
    try { await Console.OpenStandardInput().CopyToAsync(Stream.Null); } catch (IOException) { }
    if (args.Contains("--exit-with-input")) cancel.Cancel();
});

try
{
    switch (args.FirstOrDefault())
    {
        case "android-scan":
        {
            var hosts = await AndroidTvInstaller.ScanAsync(cancellationToken: cancel.Token);
            Emit("found", ("hosts", new JsonArray([.. hosts.Select(h => (JsonNode?)JsonValue.Create(h))])));
            return 0;
        }

        case "android-install":
        {
            void Approve() => Emit("approve");
            var installer = new AndroidTvInstaller(Option("--host"), Option("--key-dir"))
            {
                OnApprovalNeeded = Approve,
                // CouchSubs TV Play'de ve TV'de Play Store varsa TV'de Play sayfası açılır.
                PlayListed = AndroidTvInstaller.IsListedOnPlayAsync,
                OnPlayOpened = () => Emit("progress", ("step", "play")),
                // --replace-foreign: kullanıcı "Kaldırıp Kur" dedi; yoksa başka imzalı uygulamada ForeignApp hatası döner.
                ReplaceForeign = args.Contains("--replace-foreign"),
            };
            // TV'den kaldırılıp kaydı kalan uygulama da kurulur; --open: güncel uygulama da açılır ("yeniden kur").
            var (version, installed) = await AndroidTvApp.EnsureInstalledAsync(installer, Option("--host"), Option("--key-dir"),
                Option("--package"), Option("--version"), args.Contains("--open"), Approve, log.Write, cancel.Token);
            Emit("done", ("version", version), ("installed", installed));
            return 0;
        }

        case "android-open":
        {
            // Çeviri başlarken Mac'in bekçisi kurulu TV uygulamasını Mac'in adresiyle açar; TV onay sorarsa beklenmez
            // (NotApproved), ADB kapalıysa Unreachable.
            var started = await AndroidTvInstaller.OpenAsync(Option("--host"), Option("--key-dir"),
                args.SkipWhile(a => a != "--params").Skip(1).FirstOrDefault(), cancellationToken: cancel.Token);
            Emit("done", ("version", started), ("installed", true));
            return 0;
        }

        case "samsung-install":
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(1) };
            var installer = new SamsungTvInstaller(Option("--host"), Option("--profiles"), new SamsungCertificates(http, log))
            {
                Log = log,
                Progress = step => Emit("progress", ("step", step)),
                ReplaceForeign = args.Contains("--replace-foreign"),
                // Tarayıcıyı Mac uygulaması açar; giriş geri dönüşünü burası dinler.
                SignIn = token => SamsungLogin.SignInAsync(url =>
                {
                    log.Write($"Giriş sayfası açılsın diye Mac uygulamasına gönderildi: {url}");
                    Emit("login", ("url", url));
                }, TimeSpan.FromMinutes(10), token),
            };
            // TV'deki sürüm yeniyse kurulmaz; Mac uygulaması TV'deki sürümü saklar.
            var (version, installed) = await installer.EnsureInstalledAsync(Option("--package"), Option("--version"), cancel.Token);
            Emit("done", ("version", version), ("installed", installed));
            return 0;
        }

        case "samsung-open":
        {
            // Bekçi kurulu TV uygulamasını geliştirici bağlantısıyla (sdb, was_execute) açar; "installed" açıldı mı.
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            var installer = new SamsungTvInstaller(Option("--host"), Option("--profiles"), new SamsungCertificates(http, log)) { Log = log };
            var opened = await installer.OpenAsync(cancel.Token);
            Emit("done", ("version", ""), ("installed", opened));
            return 0;
        }

        case "self-test":
            // Yayın derlemesinde XML imzasının AOT ile çalıştığını doğrular (scripts/build-tv-helper.sh).
            await SelfTestAsync();
            Emit("done", ("version", "self-test"), ("installed", false));
            return 0;

        default:
            Console.Error.WriteLine("kullanım: couchsubs-tv-helper android-scan | android-install --host IP --package APK --version V --key-dir DİZİN [--open] [--replace-foreign] | android-open --host IP --key-dir DİZİN [--params JSON] | samsung-install --host IP --package WGT --version V --profiles DİZİN [--log DOSYA] [--replace-foreign] | samsung-open --host IP --profiles DİZİN [--log DOSYA] | self-test");
            return 2;
    }
}
catch (AndroidInstallException error)
{
    Emit("error", ("code", error.Error.ToString()), ("message", error.Message));
    return 1;
}
catch (SamsungInstallException error)
{
    Emit("error", ("code", error.Error.ToString()), ("message", error.Detail ?? error.Error.ToString()));
    return 1;
}
catch (Exception error) when (error is not OperationCanceledException)
{
    // Beklenmeyen hata da sessiz kalmasın: türü ve iletisi kullanıcıya, yığın günlüğe.
    log.Write($"Yardımcıda beklenmeyen hata: {error}");
    Emit("error", ("code", "InstallFailed"), ("message", $"{error.GetType().Name}: {error.Message}"));
    return 1;
}

static async Task SelfTestAsync()
{
    var dir = Directory.CreateTempSubdirectory("couchsubs-selftest").FullName;
    try
    {
        using var key = RSA.Create(2048);
        var request = new CertificateRequest("CN=CouchSubs self-test", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var withKey = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        var p12 = Path.Combine(dir, "test.p12");
        await File.WriteAllBytesAsync(p12, new X509Certificate2Collection { withKey }.ExportPkcs12(
            new PbeParameters(PbeEncryptionAlgorithm.TripleDes3KeyPkcs12, HashAlgorithmName.SHA1, 2048), "x"));
        // Kayıtlı sertifikanın okunduğunu da sına: macOS'ta okunamayınca ikinci kurulumdan itibaren her kurulum
        // genel hatayla duruyordu.
        File.Copy(p12, Path.Combine(dir, "author.p12"));
        File.Copy(p12, Path.Combine(dir, "distributor.p12"));
        await File.WriteAllTextAsync(Path.Combine(dir, "password.txt"), "x");
        if (!SigningProfile.In(dir).IsValid(DateTime.UtcNow.AddHours(-23)))
            throw new InvalidOperationException("kayıtlı sertifika okunamadı");
        var wgt = Path.Combine(dir, "app.wgt");
        using (var zip = ZipFile.Open(wgt, ZipArchiveMode.Create))
        {
            await using var entry = zip.CreateEntry("config.xml").Open();
            await entry.WriteAsync("<widget/>"u8.ToArray());
        }
        await TizenWgtSigner.ReSignWgtWithCertsInPlace(wgt, p12, p12, "x");
        using var signed = ZipFile.OpenRead(wgt);
        if (signed.GetEntry("author-signature.xml") is null || signed.GetEntry("signature1.xml") is null)
            throw new InvalidOperationException("imza dosyaları oluşmadı");
    }
    finally
    {
        Directory.Delete(dir, recursive: true);
    }
}
