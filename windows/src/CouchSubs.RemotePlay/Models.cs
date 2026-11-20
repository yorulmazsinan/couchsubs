// SPDX-License-Identifier: AGPL-3.0-only

using CouchSubs.Core;

namespace CouchSubs.RemotePlay;

// Remote Play katmanının uygulamaya açtığı türler (Mac'teki RemotePlay modülünün karşılıkları).

/// <param name="RunningAppTitleId">PS5'te o an çalışan uygulama (keşif yanıtındaki <c>running-app-titleid</c>); ana
/// ekranda ya da dinlenme modunda null.</param>
public sealed record ConsoleInfo(string Host, string Name, bool IsAwake, string? RunningAppTitleId = null, string? RunningAppName = null);

/// <summary>PS5'e kaydedilmiş bu bilgisayarın bağlantı bilgileri. Şifreli olarak saklanır.</summary>
/// <param name="RegistKey">16 baytlık kayıt anahtarı (ASCII onaltılık, sıfırla doldurulmuş).</param>
/// <param name="Morning">16 baytlık oturum anahtarı.</param>
public sealed record RegisteredConsole(string Host, string Name, byte[] RegistKey, byte[] Morning)
{
    /// <summary>Uyandırma için kayıt anahtarının onaltılık değeri.</summary>
    public ulong? WakeCredential
    {
        get
        {
            var end = Array.IndexOf(RegistKey, (byte)0);
            var text = System.Text.Encoding.ASCII.GetString(RegistKey, 0, end < 0 ? RegistKey.Length : end);
            return ulong.TryParse(text, System.Globalization.NumberStyles.HexNumber, null, out var value) ? value : null;
        }
    }

    public RegisteredConsole WithHost(string host) => this with { Host = host };
}

/// <summary>Bağlantının neden koptuğu; kullanıcıya anlatılabilecek biçimde.</summary>
public enum DisconnectKind
{
    Stopped,
    /// <summary>PS5 kapalı ya da uyandırılamadı.</summary>
    ConsoleAsleep,
    /// <summary>Remote Play başka bir cihazda kullanılıyor.</summary>
    InUse,
    /// <summary>PS5 bağlantıyı reddetti (ör. kayıt geçersiz ya da Uzaktan Oynatma kapalı).</summary>
    Refused,
    Network,
    /// <summary>PS5 bu hesap için giriş şifresi istiyor; Ayarlar'da kayıtlı şifre yok.</summary>
    LoginPasscode,
    /// <summary>Kayıtlı adreste PS5 aramaya yanıt vermedi ve oturum da açılamadı (ayrıntı: adres).</summary>
    NotFound,
    Other,
    /// <summary>PS5 oturum isteğinde kaydı kabul etmedi (0x80108b09 kayıt geçersiz, 0x80108b02 hesap tanınmıyor, 0x80108b26
    /// PS5 bu cihazın eşlemesini bulamadı).
    /// Yeniden denemek aynı yere çıkar; PS5 ikinci hesapla yeniden eşlenmelidir.</summary>
    RegistrationInvalid,
    /// <summary>PS5 Ayarlar'daki giriş şifresini kabul etmedi. Yeniden gönderilmez (yanlış şifreyle döngüye girilmez).</summary>
    LoginPasscodeIncorrect,
    /// <summary>PS5 oturum isteğini kayıt dışı bir nedenle reddetti ya da yanıtı okunamadı; libchiaki bunu yalnız
    /// "Unknown Session Request Error" diye verir (GitHub #33, #202). Ayrıntı: PS5'in "Reported Application Reason" kodu
    /// (ör. 0x80108bff; günlükte kod yoksa null).</summary>
    Rejected,
    /// <summary>PS5'teki Uzaktan Oynatma çöktü (libchiaki CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH, "Remote Play on Console
    /// has crashed"). PS5 tamamen kapatılıp açılana kadar her oturum isteği aynı yanıtı alır; eskiden İngilizce metinle
    /// sonsuza kadar "Yeniden bağlanılıyor…" deneniyordu (GitHub #519). <see cref="CrashRetryLimit.MaxRetries"/> denemeden
    /// sonra durulur.</summary>
    ConsoleRemotePlayCrashed,
}

/// <summary>PS5 oturum giriş şifresi (4 hane). PS5 ikinci hesapta şifre isterse Ayarlar'da kayıtlı şifre gönderilir.</summary>
public static class LoginPasscode
{
    public const int Length = 4;

    /// <summary>Boşlukları atar; tam 4 rakam değilse null.</summary>
    public static string? Normalized(string? value)
    {
        var trimmed = value?.Trim();
        return trimmed is { Length: Length } && trimmed.All(c => c is >= '0' and <= '9') ? trimmed : null;
    }

    /// <summary>Şifre isteğine yanıt: gönderilecek şifre (ASCII rakamlar, chiaki-ng'deki gibi) ya da oturumu kapatma
    /// nedeni. Şifre yoksa ya da PS5 önceki şifreyi kabul etmediyse oturum kapanır.</summary>
    public static (byte[]? Pin, DisconnectKind? Stop) Reply(string? saved, bool incorrect)
    {
        if (incorrect) return (null, DisconnectKind.LoginPasscodeIncorrect);
        return Normalized(saved) is { } pin ? (System.Text.Encoding.ASCII.GetBytes(pin), null) : (null, DisconnectKind.LoginPasscode);
    }
}

public sealed record DisconnectReason(DisconnectKind Kind, string? Detail = null);

/// <summary>PS5'in oturum isteğine verdiği, libchiaki'nin tanımadığı "RP-Application-Reason" kodları (Mac ve Android'de aynı).</summary>
public static class ApplicationReasons
{
    /// <summary>PS5'te Uzaktan Oynatma kapalı (Ayarlar > Sistem > Uzaktan Oynatma > Uzaktan Oynatmayı Etkinleştir). GitHub #9'da
    /// kullanıcı ayarı açınca düzeldi. <see cref="DisconnectKind.Rejected"/> ayrıntısında bu yazımla gelir; ayar açılınca
    /// bağlanılsın diye yeniden denenir.</summary>
    public const string RemotePlayDisabled = "0x80108b12";
}

public enum SessionPhase { Connecting, Streaming, Disconnected }

public sealed record SessionState(SessionPhase Phase, DisconnectReason? Reason = null)
{
    public static readonly SessionState Connecting = new(SessionPhase.Connecting);
    public static readonly SessionState Streaming = new(SessionPhase.Streaming);
    public static SessionState Disconnected(DisconnectKind kind, string? detail = null) => new(SessionPhase.Disconnected, new DisconnectReason(kind, detail));
}

public enum RegistrationFailure
{
    Failed,
    Canceled,
    /// <summary>PS5 hesabı tanımadı: kod, uygulamada giriş yapılan hesabın PS5 kullanıcısından alınmamış.</summary>
    WrongAccount,
    /// <summary>PS5 arama paketine yanıt vermedi: kod PS5'e hiç ulaşmadı (kapalı, başka ağda ya da Uzaktan Oynatma kapalı).</summary>
    NoAnswer,
    InUse,
    /// <summary>PS5'in Uzaktan Oynatma hizmeti hata verdi.</summary>
    ConsoleCrashed,
    /// <summary>PS5'in sistem sürümü libchiaki'nin bildiği sürümlerden farklı.</summary>
    VersionMismatch,
    /// <summary>PS5 kodu kabul etmedi (0x80108b09): kod yanlış ya da süresi dolmuş.</summary>
    WrongCode,
    /// <summary>PS5 isteği aldı ama yanıtı zamanında gelmedi (libchiaki'nin ya da bizim 30 sn'lik süremiz doldu).</summary>
    NoReply,
    /// <summary>Girilen adres çözülemedi (yanlış yazılmış IP).</summary>
    BadAddress,
    /// <summary>PS5 ağda ama aramayı reddetti: Cihazı Eşleştir ekranı açık değil, kodun süresi dolmuş ya da PS5 dinlenmede.</summary>
    PairingClosed,
    /// <summary>PS5 aramaya yanıt verdi ama eşleştirme bağlantısı (TCP 9295) açılamadı.</summary>
    ConnectFailed,
    /// <summary>Bilgisayarda yeni bağlantı için boş port ya da soket kalmadı (GitHub #590'daki şikâyet).</summary>
    NoFreePort,
}

/// <param name="reason">PS5'in bildirdiği RP-Application-Reason (ör. 0x80108b09); PS5 yanıt vermediyse null.</param>
/// <param name="detail">Kullanıcıya ve günlüğe yazılan teknik ayrıntı (PS5'in kodu ya da libchiaki'nin hata satırı).</param>
public sealed class RegistrationException(RegistrationFailure failure, uint? reason = null, string? detail = null)
    : Exception($"PS5 registration failed: {failure} {detail}")
{
    public RegistrationFailure Failure { get; } = failure;
    public uint? Reason { get; } = reason;
    public string? Detail { get; } = detail;
}

/// <summary>PS5'e Remote Play bağlantısı (gerçekte StreamSession). Ses kapalıdır, kol girdisi gönderilmez.</summary>
public interface IStreamSession : IDisposable
{
    /// <summary>Çözülmüş kare (en çok saniyede 15). Oturumun kendi iş parçacığında çağrılır.</summary>
    event Action<Frame>? FrameReceived;
    event Action<SessionState>? StateChanged;
    /// <summary>PS5 ağda yeni bir adreste bulununca çağrılır; yeni adres kaydedilmelidir.</summary>
    event Action<RegisteredConsole>? ConsoleMoved;
    void Start();
    /// <summary>Bloklamaz: oturum arka planda kapatılır.</summary>
    void Stop();
    /// <summary>Bilgisayar uykudan uyandığında ya da ağ değiştiğinde çağrılır.</summary>
    void ReconnectNow();
}
