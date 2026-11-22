// SPDX-License-Identifier: AGPL-3.0-only

namespace CouchSubs.Core.LgTv;

/// <summary>
/// Çeviri başlayınca TV uygulamasını kendiliğinden açma neden olmadı (bekçinin son denemesi). Ana ekranda TV uygulaması
/// bağlı değilken tek satırla söylenir. Mac/iPhone (TVOpenProblem) ve Android telefondaki (TvOpenProblem) ile aynı.
/// Eskiden açma sessizce başarısız oluyordu: kullanıcı TV'de CouchSubs'ı kendisinin açması gerektiğini bilmiyordu.
/// </summary>
public enum TvOpenProblem
{
    /// <summary>LG/Samsung: TV yanıt vermedi (kapalı, başka ağda ya da açmayı reddetti).</summary>
    Unreachable,
    /// <summary>LG/Samsung: bu cihazın TV'den aldığı izin (anahtar) yok; TV'ye yeniden bağlanılmalı.</summary>
    NotPaired,
    /// <summary>Android TV: ADB portuna ulaşılamadı (TV kapalı ya da ağ üzerinden hata ayıklama kapalı).</summary>
    DebugOff,
    /// <summary>Android TV: TV bu cihazın hata ayıklama iznini onaylamamış (ADB eşleşmesi yok).</summary>
    DebugNotApproved,
    /// <summary>Samsung: açma komutu gitti ama TV uygulaması <see cref="TvKeeper.SamsungOpenCheck"/> içinde bağlanmadı (TV komutu yok saydı).</summary>
    NotOpened,
    /// <summary>
    /// Samsung: TV, CouchSubs'ın kurulu olduğunu doğrulamadı (listede yok ya da liste 3 sn'de gelmedi); açma komutu
    /// gönderilmedi. Kurulu olmayan uygulamaya DEEP_LINK Smart Hub'ı mağazaya yollar, TV "Samsung sunucusuna bağlanılamıyor
    /// (AS400)" der (Samsung 7 Series 2018, 21 Kas).
    /// </summary>
    NotInstalled,
}

/// <summary>TV uygulaması bağlı değilken ana ekranda görünen yönlendirme metinleri (Localizable.xcstrings anahtarları).</summary>
public static class TvOpenText
{
    /// <summary>
    /// Bekçinin bildirdiği sorun, ekranda gösterilecek olana çevrilir: LG/Samsung'da kayıtlı anahtar yokken yanıt vermeyen
    /// TV "izin yok" sayılır (TV'nin izin sorusu yanıtlanmamış).
    /// </summary>
    public static TvOpenProblem? Shown(TvOpenProblem? reported, TvBrand brand, bool hasKey) =>
        reported == TvOpenProblem.Unreachable && brand != TvBrand.AndroidTv && !hasKey ? TvOpenProblem.NotPaired : reported;

    /// <summary>TV markasına göre tek cümle: CouchSubs TV'de nerede bulunur.</summary>
    public static string OpenOnTv(TvBrand brand) => brand == TvBrand.AndroidTv
        ? "If CouchSubs didn't open on the TV by itself, open it on the TV: on Android TV it's under Apps."
        : "If CouchSubs didn't open on the TV by itself, open it on the TV: it's in the TV's app list.";

    /// <summary>Otomatik açmanın neden olmadığı (bilinmiyorsa null).</summary>
    public static string? Reason(TvOpenProblem? problem) => problem switch
    {
        TvOpenProblem.Unreachable => "Couldn't open it automatically: the TV didn't answer. Is the TV on and on the same Wi-Fi as this device?",
        TvOpenProblem.NotPaired => "Couldn't open it automatically: this device has no permission from the TV yet. Connect the TV again and allow it on the TV.",
        TvOpenProblem.DebugOff => "Couldn't open it automatically: the TV can't be reached for debugging. Is the TV on, with network debugging on in Developer options?",
        TvOpenProblem.DebugNotApproved => "Couldn't open it automatically: the TV hasn't allowed debugging from this device. Reinstall the TV app and allow it on the TV.",
        TvOpenProblem.NotOpened => "Couldn't open it automatically: the TV got the open command but didn't open CouchSubs. Open it on the TV with the remote.",
        TvOpenProblem.NotInstalled => NotInstalledReason,
        _ => null,
    };

    public const string NotInstalledReason = "Couldn't open it automatically: the TV didn't confirm that the CouchSubs TV app is installed, so no open command was sent. Install the TV app, then try again. If the TV shows “Unable to connect to Samsung server” (AS400), the TV can't reach Samsung's servers: check its internet connection and unplug it for 30 seconds.";

    /// <summary>Samsung kurulumu başarısız olunca: TV'nin kendi "Samsung sunucusuna bağlanılamıyor (AS400)" uyarısı ne demek.</summary>
    public const string SamsungServerHint = "If the TV shows “Unable to connect to Samsung server” (AS400): this warning comes from the TV itself; the TV can't reach Samsung's servers. Check the TV's internet connection, unplug the TV and plug it back in after 30 seconds. To install CouchSubs, enter this device's address as Host PC IP.";

    public const string TryButton = "Try opening automatically";

    /// <summary>Kurulum sihirbazının son adımı (TV seçildiyse).</summary>
    public const string WizardNote = "Every time you start translating, CouchSubs tries to open the TV app by itself. If it doesn't open, open CouchSubs on the TV.";
}

/// <summary>
/// Android TV bekçisinin "şimdi açmayı dene" kararı (Mac/iPhone'daki AndroidTVOpenRule ve Android telefondaki
/// AndroidTvOpenRule ile aynı kural).
/// </summary>
/// <remarks>
/// X'te bildirildi (Android TV 8, çeviri MacBook'tan, beta.74): "TV'den uygulamayı açtığımda çevirili ekran gelip hemen
/// başka bir ekrana geçiyor, HDMI seçemiyorum". Bekçi TV uygulaması bağlı görünmediği her an, 30 sn'de bir ve sınırsız
/// <c>am start</c> gönderiyordu; kullanıcı CouchSubs'ı kumandadan açınca katmanın bağlantısı kapanıp sayfanınki kurulana
/// kadar geçen birkaç saniye de buna yetiyordu. TV uygulaması (0.9.54 ve öncesi) parametreli açılışta kayıtlı katman
/// tercihine dönüp ekranı kapatıyordu. Artık: bu çeviride bir kez bağlanan uygulama bir daha açılmaz; hiç bağlanmadıysa
/// en çok <c>maxOpens</c> kez, aralarında en az <c>interval</c>; "Otomatik açmayı dene" ve uykudan dönüş sıfırlar.
/// Uygulama TV'de zaten çalışıyorsa <c>am start</c> hiç gönderilmez (<see cref="AlreadyRunning"/>).
///
/// X'te bildirildi (Android TV, beta.77): "izni sürekli yeniden istiyor". Kanıtlı (kod): sınır yalnız gerçekten gönderilen
/// <c>am start</c>'ları sayıyordu. TV bu cihazı "Her zaman izin ver" işaretlenmeden onayladıysa ya da hiç onaylamadıysa her
/// deneme "açılamadı" oluyor, uygulama TV'de çalışıp bağlı değilse "zaten açık" oluyor, ikisi de sayılmıyordu: bekçi çeviri
/// boyunca 30 sn'de bir yeni ADB bağlantısı açıyor, TV her seferinde "Hata ayıklamaya izin verilsin mi?" diye soruyordu.
/// (ADB anahtarı kalıcıdır; soru anahtar değiştiği için değil, onay kalıcı verilmediği için yineleniyordu.) Artık her ADB
/// bağlantısı, sonucu ne olursa olsun bir deneme sayılır: çeviri başına en çok <c>maxOpens</c> bağlantı.
/// </remarks>
public sealed class AndroidTvOpenRule(int maxOpens = AndroidTvOpenRule.DefaultMaxOpens, TimeSpan? interval = null)
{
    public const int DefaultMaxOpens = 3;
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromSeconds(30);
    /// <summary>Açıcı uygulamayı TV'de çalışırken buldu, <c>am start</c> göndermedi (AndroidTvInstaller.AlreadyRunning).</summary>
    public const string AlreadyRunning = "zaten açık";

    private DateTime? lastAttempt;
    /// <summary>Açılan ADB bağlantıları (açıldı, zaten açık ya da açılamadı); sınır bunu sayar.</summary>
    public int Attempts { get; private set; }
    /// <summary>Gerçekten gönderilen <c>am start</c>'lar.</summary>
    public int Opens { get; private set; }
    public bool EverConnected { get; private set; }

    /// <summary>
    /// Bu kontrolde ADB bağlantısı açılıp açma denensin mi; true dönerse deneme sayılır. Uygulama bağlıyken hiç bağlantı
    /// açılmaz.
    /// </summary>
    public bool ShouldTry(bool connected, DateTime now)
    {
        if (connected) { EverConnected = true; return false; }
        if (EverConnected || Attempts >= maxOpens) return false;
        if (lastAttempt is { } last && now - last < (interval ?? DefaultInterval)) return false;
        lastAttempt = now;
        Attempts++;
        return true;
    }

    /// <summary><c>am start</c> gerçekten gönderildi (uygulama kapalıydı).</summary>
    public void Opened() => Opens++;

    /// <summary>"Otomatik açmayı dene" ya da uykudan dönüş: yeniden en çok <c>maxOpens</c> deneme, beklemeden.</summary>
    public void Reset()
    {
        Attempts = 0;
        Opens = 0;
        EverConnected = false;
        lastAttempt = null;
    }
}

/// <summary>
/// Android TV'de CouchSubs TV'yi bilgisayarın adresiyle açar (ADB açıksa); ne zaman açılacağı <see cref="AndroidTvOpenRule"/>'dadır
/// (iPhone/Mac'teki AndroidTVKeeper ve Android telefondaki keepAndroidTvOpen ile aynı). Eskiden bilgisayar Android TV'ye
/// hiç dokunmuyordu: çeviri başlayınca TV uygulaması kendiliğinden açılmıyordu. ADB kapalıysa ya da TV bu bilgisayarı
/// onaylamadıysa sessizce geçilir; nedeni ana ekranda söylenir.
/// </summary>
/// <param name="open">Uygulamayı açar (TV onay sorarsa beklemeden hata verir); çıktısı günlüğe yazılır. Uygulama zaten
/// çalışıyorsa <see cref="AndroidTvOpenRule.AlreadyRunning"/> döner.</param>
/// <param name="classify">Açma hatasının ana ekrandaki karşılığı.</param>
public sealed class AndroidTvKeeper(Func<Task<string>> open, Func<bool> appConnected, Func<Exception, TvOpenProblem> classify,
                                    Action<TvOpenProblem?>? onOpenResult = null, Action<string>? log = null,
                                    TimeSpan? relaunchInterval = null, Func<DateTime>? clock = null,
                                    int maxOpens = AndroidTvOpenRule.DefaultMaxOpens) : IDisposable
{
    public static readonly TimeSpan DefaultRelaunchInterval = AndroidTvOpenRule.DefaultInterval;
    private readonly Func<DateTime> now = clock ?? (() => DateTime.UtcNow);
    private readonly SemaphoreSlim tickLock = new(1, 1);
    private readonly AndroidTvOpenRule rule = new(maxOpens, relaunchInterval);
    private CancellationTokenSource? loop;
    private string? lastResult;

    /// <summary>Bir kontrol: <see cref="AndroidTvOpenRule"/> izin verirse açmayı dener.</summary>
    public async Task TickAsync()
    {
        var connected = appConnected();
        await tickLock.WaitAsync();
        try
        {
            bool due;
            lock (rule) due = rule.ShouldTry(connected, now());
            if (!due) return;
            string result;
            try
            {
                var output = (await open()).Trim();
                // Uygulama TV'de çalışırken bulunduysa am start gönderilmedi: açılış sayılmaz.
                if (output != AndroidTvOpenRule.AlreadyRunning) lock (rule) rule.Opened();
                result = "açıldı: " + output;
                onOpenResult?.Invoke(null);
            }
            catch (Exception error)
            {
                result = "açılamadı: " + error.Message;
                onOpenResult?.Invoke(classify(error));
            }
            // Aynı sonuç her denemede yeniden yazılmaz.
            if (result != lastResult) log?.Invoke($"Android TV bilgisayarın adresiyle {result}");
            lastResult = result;
        }
        finally
        {
            tickLock.Release();
        }
    }

    public void Start(TimeSpan interval)
    {
        loop?.Cancel();
        var cancellation = new CancellationTokenSource();
        loop = cancellation;
        _ = Task.Run(async () =>
        {
            while (!cancellation.IsCancellationRequested)
            {
                await TickAsync();
                try { await Task.Delay(interval, cancellation.Token); } catch (OperationCanceledException) { }
            }
        });
    }

    /// <summary>
    /// Uykudan dönüşte ya da "Otomatik açmayı dene"de: sayaç sıfırlanır, sonraki kontrol beklemeden dener (uygulama bağlıysa
    /// ya da TV'de çalışıyorsa yine açılmaz).
    /// </summary>
    public void Reconnect()
    {
        lock (rule) rule.Reset();
    }

    public void Stop()
    {
        loop?.Cancel();
        loop = null;
    }

    public void Dispose() => Stop();
}
