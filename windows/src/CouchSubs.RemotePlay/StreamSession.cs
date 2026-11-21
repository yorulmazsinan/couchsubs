// SPDX-License-Identifier: AGPL-3.0-only

using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using CouchSubs.Core;

namespace CouchSubs.RemotePlay;

/// <summary>
/// Son PS5 aramasının sonucu ve "bulunamadı" etiketi (Mac/iPhone ve Android'deki ConsoleSearchState ile aynı kural).
/// Oturum ağ hatasıyla düşer ve PS5 son aramada da yanıt vermediyse neden "bulunamadı"dır. Eskiden aramanın sonucu PS5'e
/// bağlanınca unutulmuyordu: arama yanıtı kaçıp "yine de bağlanılıyor" ile kurulan oturum saatlerce sürse de sonraki her
/// kopma (görüntü bekçisininki dahil) "PS5 … adresinde bulunamadı" diye gösteriliyordu (X'te bildirim, iPad, 60-70 dk
/// sonra). Art arda yanıtsız aramalarda bu cihazın ağ durumu günlüğe yazılır (bkz. <see cref="DeviceDiagnostics"/>).
/// </summary>
internal sealed class ConsoleSearchState
{
    /// <summary>İlk yanıtsız aramada ve sonra her bu kadar yanıtsız aramada bir tanı satırı yazılır.</summary>
    public const int DiagnoseEvery = 5;

    /// <summary>Son aramada PS5 yanıt verdi mi (ya da o aramadan sonra PS5'e bağlanıldı mı).</summary>
    public bool Answered { get; private set; } = true;

    /// <summary>Art arda yanıtsız arama sayısı.</summary>
    public int Unanswered { get; private set; }

    public void Reset()
    {
        Answered = true;
        Unanswered = 0;
    }

    /// <returns>Tanı satırı yazılacaksa true.</returns>
    public bool Searched(bool answered)
    {
        Answered = answered;
        if (answered)
        {
            Unanswered = 0;
            return false;
        }
        Unanswered++;
        return Unanswered == 1 || Unanswered % DiagnoseEvery == 0;
    }

    /// <summary>Oturum bağlandı: PS5'e ulaşılıyor, sonraki kopma "bulunamadı" sayılmaz.</summary>
    public void Connected()
    {
        Answered = true;
        Unanswered = 0;
    }

    public DisconnectReason Classify(DisconnectReason reason, string host) => StreamSession.Classify(reason, Answered, host);
}

/// <summary>
/// PS5 aramaya yanıt vermeyince bu cihazın kendi ağ durumu (Mac/iPhone ve Android'deki DeviceDiagnostics ile aynı satır):
/// açık tanıtıcı sayısı ve IPv4 ağları. "PS5 ağdan düştü" ile "bu cihaz PS5'e paket gönderemiyor" günlükten ayrılsın.
/// Windows'ta süreç başına tanıtıcı sınırı yoktur; sınır yerine "-" yazılır.
/// </summary>
internal static class DeviceDiagnostics
{
    public static string Line()
    {
        int handles;
        try { handles = System.Diagnostics.Process.GetCurrentProcess().HandleCount; }
        catch { handles = -1; }
        return Describe(handles, null, Ipv4Networks());
    }

    public static string Describe(int openFiles, int? limit, IReadOnlyList<string> networks) =>
        $"açık tanıtıcı {openFiles}/{(limit is { } value ? value.ToString(System.Globalization.CultureInfo.InvariantCulture) : "-")}; "
        + (networks.Count == 0 ? "IPv4 ağı yok" : "IPv4 " + string.Join(", ", networks));

    private static List<string> Ipv4Networks()
    {
        var result = new List<string>();
        try
        {
            foreach (var adapter in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up
                    || adapter.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                foreach (var unicast in adapter.GetIPProperties().UnicastAddresses)
                {
                    if (unicast.Address.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) continue;
                    result.Add($"{adapter.Name} {unicast.Address}/{unicast.PrefixLength}");
                }
            }
        }
        catch (Exception error) { result.Add($"okunamadı ({error.GetType().Name})"); }
        return result;
    }
}

/// <summary>
/// Dinlenme modundaki PS5 uyandırılsın mı (Mac/iPhone ve Android'deki WakePolicy ile aynı kural). Yalnız kullanıcı çeviriyi
/// başlattıktan sonra, PS5'e henüz bağlanılmamışken uyandırılır. Eskiden yeniden bağlanma döngüsü de uyandırıyordu: oyuncu
/// PS5'i kapatınca (dinlenme modu) uygulama birkaç saniye sonra PS5'i yeniden açıp bağlanıyor, TV kapalıyken "PS5 bağlı"
/// görünüyordu. Bu çeviride akış bir kez kurulduysa dinlenmedeki PS5'e dokunulmaz; açılınca bağlanılır.
/// </summary>
internal sealed class WakePolicy
{
    public enum Action
    {
        /// <summary>PS5 uyanık ya da aramaya yanıt vermedi: oturum açılmaya çalışılır.</summary>
        Connect,
        /// <summary>PS5 dinlenmede, çeviri yeni başladı: uyandırılır.</summary>
        Wake,
        /// <summary>PS5 dinlenmede ve bu çeviride zaten bağlanılmıştı (kullanıcı kapattı): açılması beklenir.</summary>
        WaitUntilOn,
    }

    private bool hasStreamed;

    /// <summary>Kullanıcı çeviriyi başlattı.</summary>
    public void Reset() => hasStreamed = false;

    /// <summary>PS5'e bağlanıldı.</summary>
    public void Streamed() => hasStreamed = true;

    /// <summary><paramref name="awake"/>: aramada PS5'in durumu (null: yanıt vermedi).</summary>
    public Action Decide(bool? awake) => awake != false ? Action.Connect : hasStreamed ? Action.WaitUntilOn : Action.Wake;
}

/// <summary>
/// Bağlantı koptuğunda yeniden deneme aralıkları: 2, 4, 8, 16, 32, en çok 60 sn (Mac ve Android'deki ReconnectPolicy ile
/// aynı kural). Aralık bağlanınca hemen değil, oturum <see cref="StableAfter"/> kadar sürdükten sonra kapanınca baştan
/// başlar. Eskiden her bağlanışta sıfırlanıyordu: PS5 oturumu açılıp birkaç saniyede düşürünce (ör. "açıldıktan 3-4 sn
/// sonra kapanıyor") 2 sn sonra yeniden bağlanılıyor, PS5'te ikinci hesap durmadan girip çıkıyordu.
///
/// Akış sürerken kopan oturumdan sonra en az 8 sn beklenir; aralık 2 dk süren oturumdan sonra baştan başlar. Eskiden
/// 60 sn yetiyordu ve en çok 30 sn beklenirdi: kablosuz ağ bozulunca oturumlar birer dakika sürüp düşüyor, her seferinde
/// 2 sn sonra yeniden deneniyordu. Yeni oturum istekleri PS5'in eski oturumu bırakmasını beklemeden geldikçe PS5 30 sn ile
/// birkaç dakika yanıt vermiyordu (GitHub #593). Bir ara 5 dk'ydı: üç dört dakikada bir kopan ağda bekleme 8, 16, 32,
/// 60 sn diye büyüyüp 60 sn'de kalıyor, her kopma bir dakikadan uzun sürüyordu ("sürekli kopuyor").
/// </summary>
internal sealed class ReconnectPolicy
{
    public static readonly TimeSpan StableAfter = TimeSpan.FromMinutes(2);
    public const int MaxDelay = 60;
    /// <summary>Akış sürerken kopan oturumdan sonraki en kısa bekleme: 2 &lt;&lt; 2 = 8 sn.</summary>
    public const int AfterDropAttempt = 2;
    private int attempt;
    private long? connectedAt;

    /// <param name="inUse">Uzaktan Oynatma başka cihazda: sık denemek boşuna, en az 8 sn beklenir (8, 16, 32).</param>
    public int NextDelay(bool inUse = false)
    {
        if (inUse) attempt = Math.Max(attempt, 2);
        var delay = Math.Min(MaxDelay, 2 << attempt);
        attempt = Math.Min(attempt + 1, 5);
        return delay;
    }

    public void Reset()
    {
        attempt = 0;
        connectedAt = null;
    }

    public void Connected(long nowMs) => connectedAt = nowMs;

    /// <summary>Oturum kapandı: uzun sürdüyse aralık baştan başlar, kısa sürdüyse büyümeye devam eder. Bağlı oturum
    /// kapandıysa PS5 eski oturumu bıraksın diye en az 8 sn beklenir.</summary>
    public void Ended(long nowMs)
    {
        if (connectedAt is { } at)
        {
            if (nowMs - at >= (long)StableAfter.TotalMilliseconds) attempt = 0;
            attempt = Math.Max(attempt, AfterDropAttempt);
        }
        connectedAt = null;
    }
}

/// <summary>
/// PS5'teki Uzaktan Oynatma çöktüyse (<see cref="DisconnectKind.ConsoleRemotePlayCrashed"/>) kaç kez yeniden denenir
/// (Mac/iPhone ve Android'deki CrashRetryLimit ile aynı kural). PS5 tamamen kapatılıp açılmadan her oturum isteği aynı
/// yanıtı alır; eskiden sonsuza kadar "Yeniden bağlanılıyor…" deneniyordu (GitHub #519). Art arda
/// <see cref="MaxRetries"/> denemeden sonra durulur ve kullanıcıya PS5'i tamamen kapatıp açması söylenir. Sayaç çeviri
/// başlayınca, ağ değişince ve bağlanınca sıfırlanır.
/// </summary>
internal sealed class CrashRetryLimit
{
    public const int MaxRetries = 2;

    /// <summary>Art arda bildirilen çökme sayısı.</summary>
    public int Crashes { get; private set; }

    public void Reset() => Crashes = 0;

    /// <summary>PS5 çöktü dedi: yeniden denenecekse true, durulacaksa false.</summary>
    public bool Crashed() => ++Crashes <= MaxRetries;
}

/// <summary>
/// Bağlantı sık kopuyorsa görüntü 720p'ye düşürülür (Mac ve Android'deki QualityFallback ile aynı kural).
/// 1080p akış ~15 Mbit/sn, 720p ~10 Mbit/sn ister. Kablosuz ağda PS5 akışı birkaç dakikada bir kopuyor ya da görüntü
/// takılıyordu (GitHub #388, #401); altyazı okumak için 720p yeterlidir. <see cref="Window"/> içinde
/// <see cref="DropsToLower"/> kopma olursa bu çeviri boyunca 720p kullanılır.
/// </summary>
internal sealed class QualityFallback
{
    public static readonly TimeSpan Window = TimeSpan.FromMinutes(10);
    public const int DropsToLower = 2;
    private readonly Queue<long> drops = new();

    /// <summary>Görüntü 720p'ye düşürüldü mü.</summary>
    public bool Lowered { get; private set; }

    /// <summary>Akış sürerken bağlantı koptu ya da görüntü takıldı. Bu kopmayla 720p'ye geçildiyse true.</summary>
    public bool Dropped(long nowMs)
    {
        if (Lowered) return false;
        drops.Enqueue(nowMs);
        while (drops.Count > 0 && nowMs - drops.Peek() > (long)Window.TotalMilliseconds) drops.Dequeue();
        if (drops.Count < DropsToLower) return false;
        Lowered = true;
        return true;
    }

    /// <summary>Kopma ağ kaynaklı mı (akış sürerken PS5 ile bağlantı gitti ya da görüntü kesildi). PS5'in reddi, başka
    /// cihazda kullanım ya da durdurma sayılmaz: düşük çözünürlük bunlara çare değildir.</summary>
    public static bool CountsAsDrop(DisconnectKind kind) => kind is DisconnectKind.Network or DisconnectKind.Other;
}

/// <summary>
/// Bağlı oturumda PS5'ten görüntü gelmiyor mu (Mac'teki PictureWatchdog ve Android'deki eşi ile aynı kural).
/// libchiaki bir karenin FEC onarımı tutmayınca PS5'ten yeni anahtar kare (IDR) ister ve o gelene kadar bütün kareleri
/// atlar (enable_idr_on_fec_failure). İstek ya da IDR karesi kaybolursa eskiden bir daha istenmiyordu: bağlantı açık
/// kalıyor, ama bir daha hiç kare gelmiyordu. chiaki-stream-recovery.patch ile istek saniyede bir yinelenir. Bağlıyken
/// görüntü <see cref="StallAfter"/> (oturumda henüz görüntü gelmediyse <see cref="FirstPictureAfter"/>) boyunca gelmezse
/// oturum yine yeniden kurulur; yeni oturum anahtar kareyle başlar. <see cref="StallAfter"/> eskiden 8 sn'ydi: ağ birkaç
/// saniye bozulunca IDR yinelenmeden oturum kapatılıyor, PS5 ardından 30 sn ile birkaç dakika yanıt vermiyordu (GitHub #593).
/// </summary>
internal sealed class PictureWatchdog
{
    /// <summary>Saniyede bir yinelenen IDR isteğine ve libchiaki'nin 5 sn'lik yeniden gönderme süresine yer kalır.</summary>
    public static readonly TimeSpan StallAfter = TimeSpan.FromSeconds(15);
    /// <summary>Bağlandıktan sonra ilk görüntü bu sürede gelmezse takılma sayılır.</summary>
    public static readonly TimeSpan FirstPictureAfter = TimeSpan.FromSeconds(8);
    /// <summary>Yeniden bağlanırken ana ekranda "Yeniden bağlanılıyor… (…)" içinde görünen neden.</summary>
    public const string Reason = "no picture from the PS5";

    private readonly Lock gate = new();
    /// <summary>Bağlıyken son görüntünün (ya da bağlanmanın) anı (ms); bağlı değilken null.</summary>
    private long? since;
    /// <summary>Bu oturumda görüntü geldi mi.</summary>
    private bool hasPicture;
    /// <summary>Oturumun bağlandığı an (ms) ve o andan beri gelen görüntü sayısı: kopma günlüğü için.</summary>
    private long connectedAt;
    private long pictures;

    /// <summary>Oturum bağlandı: süre bağlanma anından sayılır (ilk kare hiç gelmezse de yakalanır).</summary>
    public void Connected(long nowMs)
    {
        lock (gate)
        {
            since = nowMs;
            hasPicture = false;
            connectedAt = nowMs;
            pictures = 0;
        }
    }

    /// <summary>Görüntü geldi (kare iş parçacığından).</summary>
    public void Picture(long nowMs)
    {
        lock (gate)
        {
            if (since is null) return;
            since = nowMs;
            hasPicture = true;
            pictures++;
        }
    }

    /// <summary>Kopma günlüğüne eklenen özet: oturum kaç saniye sürdü, kaç görüntü geldi, son görüntü kaç saniye önceydi.
    /// Bağlı değilken null. Kopmanın nedenini ayırır: görüntü son ana kadar geliyorsa bağlantıyı PS5 ya da ağ kesmiştir;
    /// saniyelerdir gelmiyorsa akış önce donmuştur.</summary>
    public string? Summary(long nowMs)
    {
        lock (gate)
        {
            if (since is not { } last) return null;
            var lasted = (nowMs - connectedAt) / 1000;
            return hasPicture
                ? $"oturum {lasted} sn sürdü, {pictures} görüntü geldi, sonuncusu {(nowMs - last) / 1000.0:0.0} sn önce"
                : $"oturum {lasted} sn sürdü, hiç görüntü gelmedi";
        }
    }

    /// <summary>Oturum kapandı ya da yeniden kuruluyor.</summary>
    public void Ended()
    {
        lock (gate) since = null;
    }

    /// <summary>Bağlıyken <see cref="StallAfter"/>'dan (oturumda henüz görüntü yoksa <see cref="FirstPictureAfter"/>'dan)
    /// uzun süredir görüntü yoksa boşluğun süresi; yoksa null.</summary>
    public TimeSpan? Stalled(long nowMs)
    {
        lock (gate)
        {
            if (since is not { } last) return null;
            var gap = TimeSpan.FromMilliseconds(nowMs - last);
            return gap >= (hasPicture ? StallAfter : FirstPictureAfter) ? gap : null;
        }
    }
}

internal static class DisconnectReasons
{
    /// <summary>Yerel kütüphanenin CS_QUIT_* değerini kullanıcıya anlatılabilecek nedene çevirir.</summary>
    public static DisconnectReason FromNative(int quit, string? text) => quit switch
    {
        NativeMethods.QuitStopped => new(DisconnectKind.Stopped),
        NativeMethods.QuitInUse => new(DisconnectKind.InUse),
        NativeMethods.QuitRefused => new(DisconnectKind.Refused),
        NativeMethods.QuitNetwork => new(DisconnectKind.Network),
        NativeMethods.QuitRpCrashed => new(DisconnectKind.ConsoleRemotePlayCrashed),
        // PSN eşlemesinin reddi yeniden eşleme ister (eskiden TCP reddiyle aynı Refused'du).
        NativeMethods.QuitPsnRegistFailed => new(DisconnectKind.RegistrationInvalid),
        _ => new(DisconnectKind.Other, text),
    };

    /// <summary>libchiaki'nin CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN metni (yerel kütüphane CS_QUIT_OTHER ile verir).</summary>
    internal const string UnknownSessionRequest = "Unknown Session Request Error";

    /// <summary>CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED, _INVALID_PSN_ID ve 0x80108b26. 0x80108b26'yı libchiaki tanımaz:
    /// PS5 gönderilen kayıt anahtarını (RP-Registkey) kendi eşli cihaz listesinde bulamadı (eşleme PS5'te silinmiş ya da
    /// PS5 sıfırlanmış). Yeniden denemek aynı yere çıkar; PS5 yeniden eşlenmelidir.</summary>
    internal static readonly uint[] RegistrationRejectedCodes = [0x80108b09, 0x80108b02, UnknownRegistKey];

    internal const uint UnknownRegistKey = 0x80108b26;

    private static readonly string[] UnreachableLines =
    [
        "Session request connect failed eventually",
        "Failed to send session request",
        "Failed to receive session request response",
    ];

    /// <summary>libchiaki oturum isteği (TCP 9295) düşünce yalnız "Unknown Session Request Error" der; asıl neden aynı
    /// iş parçacığının az önce yazdığı günlük satırındadır. Satırdan anlaşılan neden; anlaşılmıyorsa null (genel metin
    /// kalır, PS5'in kodu zaten "Reported Application Reason" satırıyla remoteplay.log'dadır).</summary>
    public static DisconnectReason? SessionRequestHint(string? line)
    {
        if (line is null) return null;
        const string marker = "Reported Application Reason:";
        var at = line.IndexOf(marker, StringComparison.Ordinal);
        if (at >= 0)
        {
            var token = line[(at + marker.Length)..].TrimStart().Split(' ', 2)[0];
            if (token.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) token = token[2..];
            if (!uint.TryParse(token, System.Globalization.NumberStyles.HexNumber, null, out var code)) return null;
            return RegistrationRejectedCodes.Contains(code)
                ? new(DisconnectKind.RegistrationInvalid)
                : new(DisconnectKind.Rejected, $"0x{code:x8}");
        }
        // PS5'e bağlanılamadı ya da yanıt gelmedi: PS5 dinlenmeden yeni uyandıysa ilk denemelerde olağandır.
        return UnreachableLines.Any(line.Contains) ? new(DisconnectKind.Network) : null;
    }

    /// <summary>Oturum isteği bilinmeyen nedenle düştüyse günlükten anlaşılan neden kullanılır. Günlükte neden yoksa
    /// (PS5'in yanıtı okunamadı) PS5 oturumu başlatmamıştır: anlamsız İngilizce metin yerine <see cref="DisconnectKind.Rejected"/>.</summary>
    public static DisconnectReason FromNative(int quit, string? text, DisconnectReason? sessionRequestHint) =>
        quit == NativeMethods.QuitOther && text == UnknownSessionRequest
            ? sessionRequestHint ?? new(DisconnectKind.Rejected)
            : FromNative(quit, text);
}

/// <summary>Sırayla çalışan tek iş parçacıklı kuyruk (Mac'teki seri DispatchQueue karşılığı).</summary>
internal sealed class SerialQueue : IDisposable
{
    private readonly Channel<Action> channel = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Thread thread;

    public SerialQueue(string name)
    {
        thread = new Thread(Run) { IsBackground = true, Name = name };
        thread.Start();
    }

    public void Post(Action action) => channel.Writer.TryWrite(action);

    public void PostAfter(TimeSpan delay, Action action) =>
        _ = Task.Delay(delay).ContinueWith(_ => Post(action), TaskScheduler.Default);

    public bool IsCurrent => Thread.CurrentThread == thread;

    private void Run()
    {
        var reader = channel.Reader;
        while (reader.WaitToReadAsync().AsTask().GetAwaiter().GetResult())
        {
            while (reader.TryRead(out var action))
            {
                try { action(); }
                catch (Exception error) { RemotePlayLog.Write(0, $"session queue: {error}"); }
            }
        }
    }

    public void Dispose() => channel.Writer.TryComplete();
}

/// <summary>PS5'e (ikinci hesapla) Remote Play bağlantısı kurar ve görüntüyü kare kare verir.
/// Ses kapalıdır, kol girdisi gönderilmez. Bağlantı koparsa kendiliğinden yeniden bağlanır.</summary>
public sealed class StreamSession : IStreamSession
{
    /// <summary>Saniyede en çok bu kadar kare BGRA'ya çevrilir (Mac'teki gibi).</summary>
    internal const int MaxFps = 20;

    /// <summary>Çözülmüş kare. Oturumun kare iş parçacığında çağrılır; işleyici meşgulken gelen kareler atlanır.</summary>
    public event Action<Frame>? FrameReceived;
    /// <summary>Oturum kuyruğunun iş parçacığında çağrılır.</summary>
    public event Action<SessionState>? StateChanged;
    /// <summary>Oturum kuyruğunun iş parçacığında çağrılır.</summary>
    public event Action<RegisteredConsole>? ConsoleMoved;

    /// <summary>Tüm ağı taramak pahalı; PS5 kapalıyken her yeniden denemede yapılmaz.</summary>
    private static readonly TimeSpan RelocateInterval = TimeSpan.FromSeconds(30);

    /// <summary>Yalnız kuyrukta değişir (PS5'in adresi değişirse).</summary>
    private RegisteredConsole console;
    private DateTime nextRelocate = DateTime.MinValue;
    private readonly byte[] accountId;
    /// <summary>PS5 bu hesap için giriş şifresi isterse gönderilecek 4 hane (Ayarlar'da kayıtlıysa).</summary>
    private readonly string? loginPasscode;
    private readonly SerialQueue queue = new("CouchSubs stream session");
    private readonly FrameDelivery delivery;
    private readonly ReconnectPolicy policy = new();
    /// <summary>Dinlenmedeki PS5 yalnız çeviri başlarken uyandırılır (yalnız kuyrukta).</summary>
    private readonly WakePolicy wakePolicy = new();
    /// <summary>Bağlantı sık koparsa görüntü 720p'ye düşürülür (yalnız kuyrukta).</summary>
    private readonly QualityFallback quality = new();
    /// <summary>Geçerli oturum bağlandı mı (yalnız kuyrukta): yalnız akış sürerken olan kopmalar sayılır.</summary>
    private bool streaming;
    /// <summary>Bağlıyken görüntü gelmezse oturum yeniden kurulur (kare iş parçacığından da yazılır, kendi kilidi var).</summary>
    private readonly PictureWatchdog watchdog = new();
    /// <summary>PS5'teki Uzaktan Oynatma çöktüyse en çok iki kez yeniden denenir (yalnız kuyrukta).</summary>
    private readonly CrashRetryLimit crashLimit = new();
    /// <summary>Yalnız kuyrukta okunup yazılır.</summary>
    private SessionBox? box;

    /// <summary>Durdurma isteği ve kuşak numarası; her başlat/durdur yeni bir kuşak açar ve eski
    /// bloklar (yeniden deneme, eski oturumun kapanma olayı) kendini iptal eder.</summary>
    private readonly Lock stateLock = new();
    private bool running;
    private int generation;
    private bool disposed;

    public StreamSession(RegisteredConsole console, byte[] accountId, string? loginPasscode = null)
    {
        if (accountId.Length != 8) throw new ArgumentException("PSN account id must be 8 bytes", nameof(accountId));
        this.console = console;
        this.accountId = (byte[])accountId.Clone();
        this.loginPasscode = LoginPasscode.Normalized(loginPasscode);
        delivery = new FrameDelivery(frame => FrameReceived?.Invoke(frame));
    }

    public void Start()
    {
        var current = Bump(running: true);
        queue.Post(() =>
        {
            policy.Reset();
            wakePolicy.Reset();
            crashLimit.Reset();
            search.Reset();
            Connect(current);
        });
    }

    /// <summary>Bloklamaz: oturum arka planda kapatılır.</summary>
    public void Stop()
    {
        Bump(running: false);
        queue.Post(CloseBox);
    }

    /// <summary>Bilgisayar uykudan uyandığında ya da ağ değiştiğinde uygulama tarafından çağrılır.</summary>
    public void ReconnectNow()
    {
        if (!IsRunning) return;
        var current = Bump(running: true);
        queue.Post(() =>
        {
            CloseBox();
            policy.Reset();
            crashLimit.Reset();
            Connect(current);
        });
    }

    public void Dispose()
    {
        lock (stateLock)
        {
            if (disposed) return;
            disposed = true;
        }
        Stop();
        queue.Post(() =>
        {
            queue.Dispose();
            delivery.Dispose();
        });
    }

    // Durum

    private bool IsRunning
    {
        get { lock (stateLock) return running; }
    }

    private int Bump(bool running)
    {
        lock (stateLock)
        {
            this.running = running;
            return ++generation;
        }
    }

    private bool IsCurrent(int value)
    {
        lock (stateLock) return running && generation == value;
    }

    // Bağlantı (hepsi kuyrukta)

    private void Connect(int current)
    {
        if (!IsCurrent(current) || box is not null) return;
        Emit(SessionState.Connecting);

        // PS5 uyuyorsa uyandır; uyanmayı kuyruğu bloklamadan, aralıklı kontrollerle bekle.
        // Kayıtlı adreste başka bir PS5 yanıt verirse (aynı evde iki PS5, modem adresleri değiştirmiş; GitHub #425)
        // kayıtlı PS5 adıyla ağda aranır; bulunamazsa eskisi gibi o adrese bağlanılır.
        var atHost = ConsoleDiscovery.Discover(console.Host, TimeSpan.FromSeconds(2)).FirstOrDefault();
        ConsoleInfo? info;
        if (atHost is not null && ConsoleDiscovery.IsRegistered(atHost, console.Name)) info = atHost;
        else
        {
            if (atHost is not null)
                RemotePlayLog.Note($"PS5 oturumu: {console.Host} adresinde başka PS5 yanıt verdi ({atHost.Name}), {console.Name} aranıyor");
            info = Relocate() ?? atHost;
        }
        if (search.Searched(answered: info is not null))
            RemotePlayLog.Note($"PS5 aranıyor: art arda {search.Unanswered}. yanıtsız arama; bu cihaz: {DeviceDiagnostics.Line()}");
        var action = wakePolicy.Decide(info?.IsAwake);
        RemotePlayLog.Note(info is null
            ? $"PS5 oturumu: {console.Host} aramaya yanıt vermedi, yine de bağlanılıyor"
            : $"PS5 oturumu: {info.Name} {info.Host} {(info.IsAwake ? "uyanık" : action == WakePolicy.Action.Wake ? "dinlenmede, uyandırılıyor" : "dinlenmede, açılması bekleniyor")}");
        switch (action)
        {
            case WakePolicy.Action.Wake:
                try { ConsoleDiscovery.Wake(console); }
                catch (Exception error) { RemotePlayLog.Write(1, $"wake: {error.Message}"); }
                WaitForWake(current, DateTime.UtcNow.AddSeconds(20));
                break;
            case WakePolicy.Action.WaitUntilOn:
                // Kullanıcı PS5'i kapattı: yeniden açılmaz; aralıklı bakılır, PS5 açılınca bağlanılır.
                ScheduleReconnect(current, new DisconnectReason(DisconnectKind.ConsoleAsleep));
                break;
            default:
                OpenSession(current);
                break;
        }
    }

    /// <summary>Son aramanın sonucu ve "bulunamadı" etiketi (yalnız kuyrukta).</summary>
    private readonly ConsoleSearchState search = new();

    /// <summary>Oturum ağ hatasıyla düştüyse ve PS5 aramaya da yanıt vermediyse neden "bulunamadı"dır (adresle).
    /// Eskiden ikisi de yalnız "Yeniden bağlanılıyor…" idi.</summary>
    internal static DisconnectReason Classify(DisconnectReason reason, bool searchAnswered, string host) =>
        !searchAnswered && reason.Kind is DisconnectKind.Network or DisconnectKind.Other ? new DisconnectReason(DisconnectKind.NotFound, host) : reason;

    /// <summary>Kayıtlı adreste PS5 yoksa (modem adresini değiştirmiş olabilir) ağda arar; bulursa adresi günceller.</summary>
    private ConsoleInfo? Relocate()
    {
        if (DateTime.UtcNow < nextRelocate) return null;
        nextRelocate = DateTime.UtcNow + RelocateInterval;
        var moved = ConsoleDiscovery.PickMoved(ConsoleDiscovery.Discover(null, TimeSpan.FromSeconds(3)), console.Name);
        if (moved is null || moved.Host == console.Host) return null;
        RemotePlayLog.Write(1, $"PS5 yeni adreste: {console.Host} -> {moved.Host}");
        console = console.WithHost(moved.Host);
        try { ConsoleMoved?.Invoke(console); }
        catch (Exception error) { RemotePlayLog.Write(0, $"ConsoleMoved handler: {error}"); }
        return moved;
    }

    private void WaitForWake(int current, DateTime deadline)
    {
        queue.PostAfter(TimeSpan.FromSeconds(2), () =>
        {
            if (!IsCurrent(current)) return;
            if (ConsoleDiscovery.Discover(console.Host, TimeSpan.FromSeconds(2)).Any(c => c.IsAwake))
                OpenSession(current);
            else if (DateTime.UtcNow < deadline)
                WaitForWake(current, deadline);
            else
                ScheduleReconnect(current, new DisconnectReason(DisconnectKind.ConsoleAsleep));
        });
    }

    private void OpenSession(int current)
    {
        if (!IsCurrent(current) || box is not null) return;
        var started = SessionBox.Start(this, current, console, accountId, quality.Lowered ? 720 : 1080, out var failure);
        if (started is null)
        {
            RemotePlayLog.Note($"PS5 oturumu başlatılamadı ({console.Host}): {failure}");
            ScheduleReconnect(current, new DisconnectReason(DisconnectKind.Other, failure ?? "session could not be started"));
            return;
        }
        box = started;
    }

    /// <summary>Geçerli oturumu kapatır. Kapatma join içerdiği için kuyruğu bekletmemek adına arka planda yapılır.</summary>
    private void CloseBox()
    {
        streaming = false;
        watchdog.Ended();
        if (box is not { } closing) return;
        box = null;
        Task.Run(closing.TearDown);
    }

    /// <summary>Yerel kütüphanenin iş parçacığından çağrılır.</summary>
    private void Handle(int eventType, int quitReason, string? text, int eventGeneration, DisconnectReason? sessionRequestHint)
    {
        switch (eventType)
        {
            case NativeMethods.EventConnected:
                queue.Post(() =>
                {
                    if (box?.Generation != eventGeneration || !IsCurrent(eventGeneration)) return;
                    policy.Connected(Environment.TickCount64);
                    wakePolicy.Streamed();
                    crashLimit.Reset();
                    search.Connected();
                    streaming = true;
                    watchdog.Connected(Environment.TickCount64);
                    Emit(SessionState.Streaming);
                    ScheduleWatch(eventGeneration);
                });
                break;
            case NativeMethods.EventLoginPin:
                // libchiaki olayı kilit tutarken verir; şifre kuyrukta gönderilir. quitReason 1: önceki şifre yanlıştı.
                var (pin, stop) = LoginPasscode.Reply(loginPasscode, incorrect: quitReason == 1);
                queue.Post(() =>
                {
                    if (box is not { } current || current.Generation != eventGeneration || !IsCurrent(eventGeneration)) return;
                    if (pin is not null)
                    {
                        RemotePlayLog.Note("PS5 giriş şifresi istedi; Ayarlar'daki şifre gönderiliyor");
                        current.SetLoginPin(pin);
                        return;
                    }
                    // Şifre yok ya da yanlış: yeniden denemek aynı yere çıkar.
                    Bump(running: false);
                    CloseBox();
                    Emit(SessionState.Disconnected(stop ?? DisconnectKind.LoginPasscode));
                });
                break;
            case NativeMethods.EventQuit:
                var reason = DisconnectReasons.FromNative(quitReason, text, sessionRequestHint);
                RemotePlayLog.Write(1, $"Oturum kapandı: neden {quitReason} ({reason.Kind}) {text}");
                queue.Post(() =>
                {
                    // Eski bir oturumun (ör. ReconnectNow ile kapatılanın) kapanma olayı yeni oturumu etkilemez.
                    if (box?.Generation != eventGeneration || !IsCurrent(eventGeneration)) return;
                    var wasStreaming = streaming;
                    // Bekçi değil libchiaki kapattı (PS5 ya da ağ); görüntünün son ana kadar gelip gelmediği nedeni ayırır.
                    if (watchdog.Summary(Environment.TickCount64) is { } summary)
                        RemotePlayLog.Note($"PS5 oturumunu libchiaki kapattı ({reason.Kind}); {summary}");
                    CloseBox();
                    policy.Ended(Environment.TickCount64);
                    if (wasStreaming && QualityFallback.CountsAsDrop(reason.Kind)) NoteDrop();
                    if (reason.Kind == DisconnectKind.RegistrationInvalid)
                    {
                        // Kayıt geçersiz: yeniden denemek aynı yere çıkar (eskiden sonsuza kadar "Yeniden bağlanılıyor…").
                        Bump(running: false);
                        Emit(new SessionState(SessionPhase.Disconnected, reason));
                        return;
                    }
                    if (reason.Kind == DisconnectKind.ConsoleRemotePlayCrashed)
                    {
                        var retry = crashLimit.Crashed();
                        RemotePlayLog.Note($"PS5'teki Uzaktan Oynatma çöktü (art arda {crashLimit.Crashes}); " +
                                           (retry ? "yeniden deneniyor" : "yeniden bağlanma bırakıldı, PS5 tamamen kapatılıp açılmalı"));
                        if (!retry)
                        {
                            // PS5 kapatılıp açılmadan her deneme aynı yanıtı alır (eskiden sonsuz "Yeniden bağlanılıyor…").
                            Bump(running: false);
                            Emit(new SessionState(SessionPhase.Disconnected, reason));
                            return;
                        }
                    }
                    // PS5'in adresi TCP bağlantısını reddetti: PS5 yeni uyanıyor olabilir ya da adres başka bir cihaza geçmiş
                    // olabilir. Bir sonraki denemede beklemeden ağda da aranır (eşlemeyi yenilemek bunu çözmez).
                    if (reason.Kind == DisconnectKind.Refused) nextRelocate = DateTime.MinValue;
                    ScheduleReconnect(eventGeneration, reason);
                });
                break;
        }
    }

    /// <summary>
    /// Bağlıyken saniyede bir bakılır: görüntü <see cref="PictureWatchdog.StallAfter"/>'dan uzun süredir gelmiyorsa
    /// bağlantı açık görünse de oturum kapatılıp yeniden kurulur (bkz. <see cref="PictureWatchdog"/>).
    /// </summary>
    private void ScheduleWatch(int boxGeneration)
    {
        queue.PostAfter(TimeSpan.FromSeconds(1), () =>
        {
            if (box?.Generation != boxGeneration || !IsCurrent(boxGeneration)) return;
            if (watchdog.Stalled(Environment.TickCount64) is not { } gap)
            {
                ScheduleWatch(boxGeneration);
                return;
            }
            RemotePlayLog.Note($"PS5'ten {(int)gap.TotalSeconds} sn'dir görüntü gelmiyor (bağlantı açık); oturumu görüntü bekçisi yeniden kuruyor; "
                               + watchdog.Summary(Environment.TickCount64));
            CloseBox();
            policy.Ended(Environment.TickCount64);
            NoteDrop();
            ScheduleReconnect(boxGeneration, new DisconnectReason(DisconnectKind.Other, PictureWatchdog.Reason));
        });
    }

    /// <summary>Akış sürerken bağlantı koptu: sık oluyorsa sonraki oturumlar 720p açılır.</summary>
    private void NoteDrop()
    {
        if (quality.Dropped(Environment.TickCount64))
            RemotePlayLog.Note($"PS5 bağlantısı {QualityFallback.Window.TotalMinutes:0} dk içinde {QualityFallback.DropsToLower} kez koptu; " +
                               "görüntü 720p'ye düşürülüyor (daha az bant genişliği). Kalıcı çözüm: PS5'i modeme kabloyla bağlayın");
    }

    private void ScheduleReconnect(int current, DisconnectReason reason)
    {
        reason = search.Classify(reason, console.Host);
        Emit(new SessionState(SessionPhase.Disconnected, reason));
        if (!IsCurrent(current)) return;
        var delay = policy.NextDelay(inUse: reason.Kind == DisconnectKind.InUse);
        RemotePlayLog.Note($"PS5 oturumu: {delay} sn sonra yeniden denenecek");
        queue.PostAfter(TimeSpan.FromSeconds(delay), () => Connect(current));
    }

    private void Emit(SessionState state)
    {
        // Ana ekrandaki durumun nedeni remoteplay.log'da da görünsün.
        if (state.Phase != SessionPhase.Connecting)
            RemotePlayLog.Note($"PS5 oturumu: {state.Phase}{(state.Reason is { } why ? $" {why.Kind} {why.Detail}" : "")}");
        try { StateChanged?.Invoke(state); }
        catch (Exception error) { RemotePlayLog.Write(0, $"StateChanged handler: {error}"); }
    }

    /// <summary>Tek bir yerel oturumun sahibi. Geri çağrılar bu kutuya gelir; kutu (ve GCHandle'ı) oturum
    /// durdurulup iş parçacıkları beklenene kadar yaşar, böylece geri çağrı bırakılmış nesneye düşmez.</summary>
    private sealed class SessionBox
    {
        public int Generation { get; }
        private readonly StreamSession owner;
        private readonly Lock tearLock = new();
        private GCHandle handle;
        private nint native;
        private string? lastError;
        /// <summary>Oturum isteğinin günlükten anlaşılan düşme nedeni (yerel iş parçacığında yazılır, okunur).</summary>
        private volatile DisconnectReason? sessionRequestHint;

        private SessionBox(StreamSession owner, int generation)
        {
            this.owner = owner;
            Generation = generation;
            handle = GCHandle.Alloc(this);
        }

        /// <param name="videoHeight">1080 ya da 720 (bağlantı sık koparsa).</param>
        public static unsafe SessionBox? Start(StreamSession owner, int generation, RegisteredConsole console, byte[] accountId,
                                               int videoHeight, out string? failure)
        {
            var box = new SessionBox(owner, generation);
            failure = null;
            try
            {
                NativeMethods.EnsureInitialized();
                var registKey = NativeMethods.Padded(console.RegistKey, 0x10);
                var morning = NativeMethods.Padded(console.Morning, 0x10);
                delegate* unmanaged[Cdecl]<byte*, int, int, int, nint, void> frame = &OnFrame;
                delegate* unmanaged[Cdecl]<int, int, byte*, nint, void> eventCallback = &OnEvent;
                delegate* unmanaged[Cdecl]<int, byte*, nint, void> log = &OnLog;
                fixed (byte* key = registKey)
                fixed (byte* morningPointer = morning)
                fixed (byte* account = accountId)
                    box.native = NativeMethods.cs_session_start_ex(console.Host, key, morningPointer, account, MaxFps, videoHeight,
                                                                   (nint)frame, (nint)eventCallback, (nint)log,
                                                                   GCHandle.ToIntPtr(box.handle));
            }
            catch (Exception error)
            {
                box.lastError = error.Message;
            }
            if (box.native != 0) return box;
            // Başlamamış oturumun beklenecek iş parçacığı yok; yalnız tutamak bırakılır.
            failure = box.lastError;
            box.handle.Free();
            return null;
        }

        /// <summary>Oturumu durdurur ve iş parçacıklarını bekler. Yerel geri çağrıdan çağrılmamalı.</summary>
        public void TearDown()
        {
            lock (tearLock)
            {
                if (native == 0) return;
                NativeMethods.cs_session_stop(native);
                native = 0;
                handle.Free();
            }
        }

        public unsafe void SetLoginPin(byte[] pin)
        {
            lock (tearLock)
            {
                if (native == 0) return;
                fixed (byte* bytes = pin)
                    NativeMethods.cs_session_set_login_pin(native, bytes, (nuint)pin.Length);
            }
        }

        private static SessionBox? From(nint user) => user == 0 ? null : GCHandle.FromIntPtr(user).Target as SessionBox;

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
        private static unsafe void OnFrame(byte* bgra, int width, int height, int stride, nint user)
        {
            try
            {
                if (From(user) is { } box && bgra != null && width > 0 && height > 0)
                {
                    box.owner.watchdog.Picture(Environment.TickCount64);
                    box.owner.delivery.Offer((nint)bgra, width, height, stride);
                }
            }
            catch (Exception error) { RemotePlayLog.Write(0, $"frame: {error.Message}"); }
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
        private static unsafe void OnEvent(int eventType, int quitReason, byte* reasonText, nint user)
        {
            try
            {
                if (From(user) is { } box)
                    box.owner.Handle(eventType, quitReason, NativeMethods.Utf8(reasonText), box.Generation, box.sessionRequestHint);
            }
            catch (Exception error) { RemotePlayLog.Write(0, $"event: {error.Message}"); }
        }

        [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
        private static unsafe void OnLog(int level, byte* message, nint user)
        {
            // UnmanagedCallersOnly işlevinden kaçan hata süreci uyarısız kapatır (diğer geri çağrılar gibi yakalanır).
            try
            {
                var text = NativeMethods.Utf8(message);
                // Oturum başlatılamazsa nedeni son hata satırıdır (cs_session_start aynı iş parçacığında yazar).
                if (level == 0 && text is not null && From(user) is { } box)
                {
                    box.lastError = text;
                    if (DisconnectReasons.SessionRequestHint(text) is { } hint) box.sessionRequestHint = hint;
                }
                RemotePlayLog.Write(level, text);
            }
            catch
            {
                // Günlük satırı kaybolsa da oturum sürer.
            }
        }
    }
}

/// <summary>Kareleri yerel iş parçacığından alıp kendi iş parçacığında dağıtır. İşleyici meşgulken
/// gelen kareler kopyalanmadan atlanır: ağ iş parçacığı okumayı beklemez, gereksiz bellek ayrılmaz.</summary>
internal sealed class FrameDelivery : IDisposable
{
    private readonly Action<Frame> deliver;
    // Monitor.Wait/Pulse gerektiği için Lock değil düz nesne.
    private readonly object gate = new();
    private readonly Thread thread;
    private Frame? pending;
    private bool busy;
    private bool closed;

    public FrameDelivery(Action<Frame> deliver)
    {
        this.deliver = deliver;
        thread = new Thread(Run) { IsBackground = true, Name = "CouchSubs frames" };
        thread.Start();
    }

    /// <summary>Tampon yalnız bu çağrı süresince geçerlidir.</summary>
    public void Offer(nint bgra, int width, int height, int stride)
    {
        lock (gate)
        {
            if (closed || busy || pending is not null) return;
        }
        var frame = Frame.Copy(bgra, width, height, stride);
        lock (gate)
        {
            if (closed || pending is not null) return;
            pending = frame;
            Monitor.Pulse(gate);
        }
    }

    private void Run()
    {
        while (true)
        {
            Frame frame;
            lock (gate)
            {
                while (pending is null && !closed) Monitor.Wait(gate);
                if (closed) return;
                frame = pending!;
                pending = null;
                busy = true;
            }
            try { deliver(frame); }
            catch (Exception error) { RemotePlayLog.Write(0, $"FrameReceived handler: {error}"); }
            lock (gate) busy = false;
        }
    }

    public void Dispose()
    {
        lock (gate)
        {
            closed = true;
            pending = null;
            Monitor.Pulse(gate);
        }
    }
}
