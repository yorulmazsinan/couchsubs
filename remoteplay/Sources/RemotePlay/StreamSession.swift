// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
import CoreGraphics
import Foundation

/// Saniyede en fazla belirli sayıda karenin geçmesine izin verir.
struct FrameThrottle {
    let minInterval: TimeInterval
    let now: () -> Date
    private var last: Date?

    init(minInterval: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.minInterval = minInterval
        self.now = now
    }

    mutating func shouldPass() -> Bool {
        let current = now()
        if let last, current.timeIntervalSince(last) < minInterval { return false }
        last = current
        return true
    }
}

/// Bağlantı koptuğunda yeniden deneme aralıkları: 2, 4, 8, 16, 32, en çok 60 sn (Android ve Windows'taki
/// ReconnectPolicy ile aynı kural).
///
/// Aralık bağlanınca hemen değil, oturum `stableAfter` kadar sürdükten sonra kapanınca baştan başlar. Eskiden her
/// bağlanışta sıfırlanıyordu: PS5 oturumu açılıp birkaç saniyede düşürünce (ör. aynı ikinci hesapla bağlı başka bir
/// cihaz) telefon 2 sn sonra yeniden bağlanıyor, PS5'te ikinci hesap durmadan girip çıkıyordu.
///
/// Akış sürerken kopan oturumdan sonra en az 8 sn beklenir; aralık 2 dk süren oturumdan sonra baştan başlar.
/// Eskiden 60 sn yetiyordu ve en çok 30 sn beklenirdi: kablosuz ağ bozulunca oturumlar birer dakika sürüp düşüyor, her
/// seferinde 2 sn sonra yeniden deneniyor, "her dakika bağlanıp kopuyor" döngüsü uzun süre sürüyordu (TestFlight, iPad).
/// Yeni oturum istekleri PS5'in eski oturumu bırakmasını beklemeden geldikçe PS5 30 sn ile birkaç dakika yanıt
/// vermiyordu (GitHub #593). Bir ara 5 dk'ydı: üç dört dakikada bir kopan ağda bekleme 8, 16, 32, 60 sn diye büyüyüp
/// 60 sn'de kalıyor, her kopma bir dakikadan uzun sürüyordu ("sürekli kopuyor").
struct ReconnectPolicy {
    static let stableAfter: TimeInterval = 2 * 60
    static let maxDelay = 60
    /// Akış sürerken kopan oturumdan sonraki en kısa bekleme: `2 << afterDropAttempt` = 8 sn.
    static let afterDropAttempt = 2
    private var attempt = 0
    private var connectedAt: Date?

    /// `inUse`: Uzaktan Oynatma başka cihazda; sık denemek boşuna, en az 8 sn beklenir (8, 16, 32). Hemen en uzuna
    /// atlanmaz: telefonun kendi eski oturumu PS5'te birkaç saniye daha açık görünebilir.
    mutating func nextDelay(inUse: Bool = false) -> Int {
        if inUse { attempt = max(attempt, 2) }
        defer { attempt = min(attempt + 1, 5) }
        return min(Self.maxDelay, 2 << attempt)
    }

    mutating func reset() {
        attempt = 0
        connectedAt = nil
    }

    mutating func connected(at now: Date = Date()) { connectedAt = now }

    /// Oturum kapandı: uzun sürdüyse aralık baştan başlar, kısa sürdüyse büyümeye devam eder. Bağlı oturum kapandıysa
    /// PS5 eski oturumu bıraksın diye en az 8 sn beklenir.
    mutating func ended(at now: Date = Date()) {
        if let connectedAt {
            if now.timeIntervalSince(connectedAt) >= Self.stableAfter { attempt = 0 }
            attempt = max(attempt, Self.afterDropAttempt)
        }
        connectedAt = nil
    }
}

/// Dinlenme modundaki PS5 uyandırılsın mı (Android ve Windows'taki WakePolicy ile aynı kural).
///
/// Yalnız kullanıcı "Çeviriyi başlat"a bastıktan sonra, PS5'e henüz bağlanılmamışken uyandırılır. Eskiden yeniden bağlanma
/// döngüsü de uyandırıyordu: oyuncu PS5'i kapatınca (dinlenme modu) PS5 oturumu bitiriyor, uygulama birkaç saniye sonra
/// PS5'i yeniden açıyor ve yeniden bağlanıyordu. TV kapalı, PS5 kapatılmış görünürken ana ekran "PS5 bağlı" diyor, çeviri
/// sürüyordu (X'te kullanıcı bildirimi, 19 Kas). Bu çeviride akış bir kez kurulduysa dinlenmedeki PS5'e dokunulmaz:
/// "PS5'i açın" görünür ve PS5 açılınca bağlanılır.
struct WakePolicy {
    enum Action: Equatable {
        /// PS5 uyanık ya da aramaya yanıt vermedi: oturum açılmaya çalışılır.
        case connect
        /// PS5 dinlenmede, çeviri yeni başladı: uyandırılır.
        case wake
        /// PS5 dinlenmede ve bu çeviride zaten bağlanılmıştı (kullanıcı kapattı): uyandırılmaz, açılması beklenir.
        case waitUntilOn
    }

    private var hasStreamed = false

    /// Kullanıcı çeviriyi başlattı.
    mutating func reset() { hasStreamed = false }

    /// PS5'e bağlanıldı.
    mutating func streamed() { hasStreamed = true }

    /// `awake`: aramada PS5'in durumu (nil: yanıt vermedi).
    func action(awake: Bool?) -> Action {
        guard awake == false else { return .connect }
        return hasStreamed ? .waitUntilOn : .wake
    }
}

/// PS5'teki Uzaktan Oynatma çöktüyse (`DisconnectReason.consoleRemotePlayCrashed`) kaç kez yeniden denenir (Windows ve
/// Android'deki CrashRetryLimit ile aynı kural).
///
/// PS5 tamamen kapatılıp açılmadan her oturum isteği aynı yanıtı alır; eskiden sonsuza kadar "Yeniden bağlanılıyor…"
/// deneniyordu (GitHub #519). Art arda `maxRetries` denemeden sonra durulur ve kullanıcıya PS5'i tamamen kapatıp açması
/// söylenir. Sayaç çeviri başlayınca, ağ değişince ve bağlanınca sıfırlanır.
struct CrashRetryLimit {
    static let maxRetries = 2
    /// Art arda bildirilen çökme sayısı.
    private(set) var crashes = 0

    mutating func reset() { crashes = 0 }

    /// PS5 çöktü dedi: yeniden denenecekse true, durulacaksa false.
    mutating func crashed() -> Bool {
        crashes += 1
        return crashes <= Self.maxRetries
    }
}

/// Bağlantı sık kopuyorsa görüntü 720p'ye düşürülür (Windows ve Android'deki QualityFallback ile aynı kural).
///
/// 1080p akış ~15 Mbit/sn, 720p ~10 Mbit/sn ister. Kablosuz ağda PS5 akışı birkaç dakikada bir kopuyor ya da görüntü
/// takılıyordu (GitHub #388, #401); altyazı okumak için 720p yeterlidir. `window` içinde `dropsToLower` kopma olursa bu
/// çeviri boyunca 720p kullanılır.
struct QualityFallback {
    static let window: TimeInterval = 10 * 60
    static let dropsToLower = 2
    private var drops: [Date] = []
    /// Görüntü 720p'ye düşürüldü mü.
    private(set) var lowered = false

    /// Akış sürerken bağlantı koptu ya da görüntü takıldı. Bu kopmayla 720p'ye geçildiyse true.
    mutating func dropped(at now: Date = Date()) -> Bool {
        guard !lowered else { return false }
        drops.append(now)
        drops.removeAll { now.timeIntervalSince($0) > Self.window }
        guard drops.count >= Self.dropsToLower else { return false }
        lowered = true
        return true
    }

    /// Kopma ağ kaynaklı mı (akış sürerken PS5 ile bağlantı gitti ya da görüntü kesildi). PS5'in reddi, başka cihazda
    /// kullanım ya da durdurma sayılmaz: düşük çözünürlük bunlara çare değildir.
    static func countsAsDrop(_ reason: DisconnectReason) -> Bool {
        switch reason {
        case .network, .other: return true
        default: return false
        }
    }
}

/// Bağlı oturumda PS5'ten görüntü gelmiyor mu (Windows'taki PictureWatchdog ve Android'deki eşi ile aynı kural).
///
/// libchiaki bir karenin FEC onarımı tutmayınca PS5'ten yeni anahtar kare (IDR) ister ve o gelene kadar bütün kareleri
/// atlar (`enable_idr_on_fec_failure`). İstek ya da IDR karesi kaybolursa eskiden bir daha istenmiyordu: bağlantı açık
/// kalıyor, ama bir daha hiç kare gelmiyordu. chiaki-stream-recovery.patch ile istek saniyede bir yinelenir. Bağlıyken
/// görüntü `stallAfter` (oturumda henüz görüntü gelmediyse `firstPictureAfter`) boyunca gelmezse oturum yine yeniden
/// kurulur; yeni oturum anahtar kareyle başlar. `stallAfter` eskiden 8 sn'ydi: ağ birkaç saniye bozulunca IDR yinelenmeden
/// oturum kapatılıyor, PS5 ardından 30 sn ile birkaç dakika yanıt vermiyordu (GitHub #593).
struct PictureWatchdog {
    /// Saniyede bir yinelenen IDR isteğine ve libchiaki'nin 5 sn'lik yeniden gönderme süresine yer kalır.
    static let stallAfter: TimeInterval = 15
    /// Bağlandıktan sonra ilk görüntü bu sürede gelmezse takılma sayılır.
    static let firstPictureAfter: TimeInterval = 8
    /// Yeniden bağlanırken ana ekranda "Yeniden bağlanılıyor… (…)" içinde görünen neden.
    static let reason = "no picture from the PS5"
    /// Art arda bu kadar oturumda hiç görüntü gelmezse yeniden bağlanma bırakılır (Android'deki eşi ile aynı).
    static let maxNoPictureSessions = 3

    /// Takılma sonrası ne yapılacak.
    enum Next: Equatable {
        /// Yeniden kur.
        case reconnect
        /// Art arda `maxNoPictureSessions` oturumda hiç görüntü gelmedi: sonsuz "Yeniden bağlanılıyor…" yerine dur.
        case giveUp
    }

    /// Bağlıyken son görüntünün (ya da bağlanmanın) anı; bağlı değilken nil.
    private var since: Date?
    /// Bu oturumda görüntü geldi mi.
    private var hasPicture = false
    /// Oturumun bağlandığı an ve o andan beri gelen görüntü sayısı: kopma günlüğü için.
    private var connectedAt = Date()
    private var pictures = 0
    /// Art arda hiç görüntü gelmeyen oturum sayısı; görüntü gelince sıfırlanır.
    private(set) var noPictureSessions = 0

    /// Kullanıcı başlattı ya da ağ değişti: sayaç sıfırdan.
    mutating func reset() {
        since = nil
        hasPicture = false
        noPictureSessions = 0
    }

    /// Oturum bağlandı: süre bağlanma anından sayılır (ilk kare hiç gelmezse de yakalanır).
    mutating func connected(at now: Date = Date()) {
        since = now
        hasPicture = false
        connectedAt = now
        pictures = 0
    }

    /// Görüntü geldi.
    mutating func picture(at now: Date = Date()) {
        guard since != nil else { return }
        since = now
        hasPicture = true
        pictures += 1
        noPictureSessions = 0
    }

    /// Kopma günlüğüne eklenen özet: oturum kaç saniye sürdü, kaç görüntü geldi, son görüntü kaç saniye önceydi. Bağlı
    /// değilken nil. Kopmanın nedenini ayırır: görüntü son ana kadar geliyorsa bağlantıyı PS5 ya da ağ kesmiştir;
    /// saniyelerdir gelmiyorsa akış önce donmuştur.
    func summary(at now: Date = Date()) -> String? {
        guard let since else { return nil }
        let lasted = Int(now.timeIntervalSince(connectedAt))
        guard hasPicture else { return "oturum \(lasted) sn sürdü, hiç görüntü gelmedi" }
        return "oturum \(lasted) sn sürdü, \(pictures) görüntü geldi, sonuncusu \(String(format: "%.1f", now.timeIntervalSince(since))) sn önce"
    }

    /// `stalled` boşluk bildirdi; oturum kapatılırken ne yapılacağı.
    mutating func afterStall() -> Next {
        if hasPicture { return .reconnect }
        noPictureSessions += 1
        return noPictureSessions >= Self.maxNoPictureSessions ? .giveUp : .reconnect
    }

    /// Oturum kapandı ya da yeniden kuruluyor.
    mutating func ended() { since = nil }

    /// Bağlıyken `stallAfter`'dan (oturumda henüz görüntü yoksa `firstPictureAfter`'dan) uzun süredir görüntü yoksa
    /// boşluğun süresi (sn); yoksa nil.
    func stalled(at now: Date = Date()) -> TimeInterval? {
        guard let since else { return nil }
        let gap = now.timeIntervalSince(since)
        return gap >= (hasPicture ? Self.stallAfter : Self.firstPictureAfter) ? gap : nil
    }
}

/// Son PS5 aramasının sonucu ve "bulunamadı" etiketi (Windows ve Android'deki ConsoleSearchState ile aynı kural).
///
/// Oturum ağ hatasıyla düşer ve PS5 son aramada da yanıt vermediyse neden `.notFound`'dur. Eskiden aramanın sonucu PS5'e
/// bağlanınca unutulmuyordu: arama yanıtı kaçıp "yine de bağlanılıyor" ile kurulan oturum saatlerce sürse de sonraki her
/// kopma (görüntü bekçisininki dahil) "PS5 … adresinde bulunamadı" diye gösteriliyordu (X'te bildirim, iPad, 60-70 dk
/// kesintisiz çeviriden sonra). Bağlanınca PS5'e ulaşıldığı bilinir.
///
/// Art arda yanıtsız aramalarda bu cihazın ağ durumu (açık dosya tanıtıcısı ve sınırı, IPv4 ağları) günlüğe yazılır:
/// "PS5 ağdan düştü" ile "bu cihaz soket açamıyor ya da ağı değişti" bir sonraki bildirimde günlükten ayrılsın.
struct ConsoleSearchState {
    /// İlk yanıtsız aramada ve sonra her bu kadar yanıtsız aramada bir tanı satırı yazılır.
    static let diagnoseEvery = 5
    /// Son aramada PS5 yanıt verdi mi (ya da o aramadan sonra PS5'e bağlanıldı mı).
    private(set) var answered = true
    /// Art arda yanıtsız arama sayısı.
    private(set) var unanswered = 0

    /// Kullanıcı başlattı.
    mutating func reset() {
        answered = true
        unanswered = 0
    }

    /// Arama bitti. Tanı satırı yazılacaksa true.
    mutating func searched(answered: Bool) -> Bool {
        self.answered = answered
        guard !answered else {
            unanswered = 0
            return false
        }
        unanswered += 1
        return unanswered == 1 || unanswered % Self.diagnoseEvery == 0
    }

    /// Oturum bağlandı: PS5'e ulaşılıyor, sonraki kopma "bulunamadı" sayılmaz.
    mutating func connected() {
        answered = true
        unanswered = 0
    }

    func classify(_ reason: DisconnectReason, host: String) -> DisconnectReason {
        DisconnectReason.classify(reason, searchAnswered: answered, host: host)
    }
}

/// Bağlantının neden koptuğu; kullanıcıya anlatılabilecek biçimde.
public enum DisconnectReason: Equatable, Sendable {
    case stopped
    /// PS5 kapalı ya da uyandırılamadı.
    case consoleAsleep
    /// Remote Play başka bir cihazda kullanılıyor.
    case inUse
    /// PS5'in adresi oturum ya da ctrl bağlantısını (TCP 9295) reddetti: PS5 yeni uyanıyor ya da adres başka bir cihaza
    /// geçmiş. Eşleme sorunu değildir (eskiden "PS5'i yeniden kurun" deniyordu); beklenip yeniden denenir ve PS5 ağda
    /// yeniden aranır.
    case refused
    case network
    /// İkinci kullanıcının PS5'te giriş şifresi var ve Ayarlar'da kayıtlı şifre yok.
    case loginPasscode
    /// Ayarlar'daki giriş şifresini PS5 kabul etmedi. Yeniden gönderilmez (yanlış şifreyle döngüye girilmez).
    case loginPasscodeIncorrect
    /// PS5 oturum isteğinde kaydı kabul etmedi (0x80108b09 kayıt geçersiz, 0x80108b02 hesap tanınmıyor, 0x80108b26 PS5 bu
    /// cihazın eşlemesini bulamadı). Yeniden denemek aynı yere çıkar; PS5 ikinci hesapla yeniden eşlenmelidir.
    case registrationInvalid
    /// Bağlantı kuruluyor ama art arda `PictureWatchdog.maxNoPictureSessions` oturumda PS5'ten hiç görüntü gelmedi;
    /// yeniden bağlanma bırakıldı (eskiden sonsuza kadar "Yeniden bağlanılıyor…").
    case noPicture
    /// Kayıtlı adreste PS5 aramaya yanıt vermedi ve oturum da açılamadı (değer: adres).
    case notFound(String)
    /// PS5 oturum isteğini (TCP 9295) kayıt dışı bir nedenle reddetti ya da yanıtı okunamadı; libchiaki bunu yalnız
    /// "Unknown Session Request Error" diye verir (GitHub #33, #202). Değer: PS5'in "Reported Application Reason" kodu
    /// (libchiaki'nin tanımadığı kodlar, ör. 0x80108bff; günlükte kod yoksa nil).
    case rejected(UInt32?)
    /// PS5'teki Uzaktan Oynatma çöktü (CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH, "Remote Play on Console has crashed").
    /// PS5 tamamen kapatılıp açılana kadar her oturum isteği aynı yanıtı alır; eskiden İngilizce metinle sonsuza kadar
    /// "Yeniden bağlanılıyor…" deneniyordu (GitHub #519). `CrashRetryLimit.maxRetries` denemeden sonra durulur.
    case consoleRemotePlayCrashed
    case other(String)

    /// Altyazı günlüğüne (altyazi.log) yazılan kısa neden: adres ve ayrıntı olmadan, yalnız türü. Kullanıcılar çoğu zaman
    /// yalnız altyazi.log gönderiyor; GitHub #456'daki günlükte 30 kopmanın hiçbirinin nedeni görünmüyordu.
    public var logName: String {
        switch self {
        case .stopped: "stopped"
        case .consoleAsleep: "consoleAsleep"
        case .inUse: "inUse"
        case .refused: "refused"
        case .network: "network"
        case .loginPasscode: "loginPasscode"
        case .loginPasscodeIncorrect: "loginPasscodeIncorrect"
        case .registrationInvalid: "registrationInvalid"
        case .noPicture: "noPicture"
        case .notFound: "notFound"
        case .rejected(let code): code.map { String(format: "rejected 0x%08x", $0) } ?? "rejected"
        case .consoleRemotePlayCrashed: "consoleRemotePlayCrashed"
        case .other(let text): text.isEmpty ? "other" : "other: \(text)"
        }
    }

    /// Oturum ağ hatasıyla düştüyse ve PS5 aramaya da yanıt vermediyse neden "bulunamadı"dır (eskiden yalnız
    /// "Yeniden bağlanılıyor…" görünüyordu).
    static func classify(_ reason: DisconnectReason, searchAnswered: Bool, host: String) -> DisconnectReason {
        guard !searchAnswered else { return reason }
        switch reason {
        case .network, .other: return .notFound(host)
        default: return reason
        }
    }

    /// libchiaki oturum isteği (TCP 9295) düşünce yalnız "Unknown Session Request Error" der; asıl neden aynı iş
    /// parçacığının az önce yazdığı günlük satırındadır. Satırdan anlaşılan neden; anlaşılmıyorsa nil (genel metin
    /// kalır, PS5'in kodu zaten "Reported Application Reason" satırıyla remoteplay.log'dadır).
    static func sessionRequestHint(fromLog line: String) -> DisconnectReason? {
        if let marker = line.range(of: "Reported Application Reason:") {
            let token = line[marker.upperBound...].drop { $0 == " " }.prefix { !$0.isWhitespace }.lowercased()
            let hex = token.hasPrefix("0x") ? String(token.dropFirst(2)) : token
            guard let code = UInt32(hex, radix: 16) else { return nil }
            return registrationRejectedCodes.contains(code) ? .registrationInvalid : .rejected(code)
        }
        // PS5'e bağlanılamadı ya da yanıt gelmedi: PS5 dinlenmeden yeni uyandıysa ilk denemelerde olağandır.
        return unreachableLines.contains(where: line.contains) ? .network : nil
    }

    /// CHIAKI_RP_APPLICATION_REASON_REGIST_FAILED, _INVALID_PSN_ID ve 0x80108b26. 0x80108b26'yı libchiaki tanımaz: PS5
    /// gönderilen kayıt anahtarını (RP-Registkey) kendi eşli cihaz listesinde bulamadı (eşleme PS5'te silinmiş ya da PS5
    /// sıfırlanmış). Yeniden denemek aynı yere çıkar; PS5 yeniden eşlenmelidir.
    static let registrationRejectedCodes: Set<UInt32> = [0x80108b09, 0x80108b02, 0x80108b26]
    /// PS5'te Uzaktan Oynatma kapalı (Ayarlar › Sistem › Uzaktan Oynatma › Uzaktan Oynatmayı Etkinleştir). libchiaki
    /// tanımaz; GitHub #9'da kullanıcı ayarı açınca düzeldi. `.rejected(remotePlayDisabled)` olarak gelir ve ayar açılınca
    /// bağlanılsın diye yeniden denenir.
    public static let remotePlayDisabled: UInt32 = 0x80108b12
    private static let unreachableLines = [
        "Session request connect failed eventually",
        "Failed to send session request",
        "Failed to receive session request response",
    ]

    /// Oturum isteği bilinmeyen nedenle düştüyse günlükten anlaşılan neden kullanılır. Günlükte neden yoksa (PS5'in
    /// yanıtı okunamadı) PS5 oturumu başlatmamıştır: anlamsız İngilizce metin yerine `.rejected(nil)`.
    init(quit: ChiakiQuitReason, sessionRequestHint hint: DisconnectReason?) {
        if quit == CHIAKI_QUIT_REASON_SESSION_REQUEST_UNKNOWN {
            self = hint ?? .rejected(nil)
        } else {
            self.init(quit: quit)
        }
    }

    init(quit: ChiakiQuitReason) {
        switch quit {
        case CHIAKI_QUIT_REASON_STOPPED: self = .stopped
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_IN_USE: self = .inUse
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_CONNECTION_REFUSED, CHIAKI_QUIT_REASON_CTRL_CONNECTION_REFUSED: self = .refused
        // PSN üzerinden eşleme reddedildi: yalnız bu yeniden eşleme ister (eskiden TCP reddiyle aynı `.refused`'du).
        case CHIAKI_QUIT_REASON_PSN_REGIST_FAILED: self = .registrationInvalid
        case CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_DISCONNECTED, CHIAKI_QUIT_REASON_STREAM_CONNECTION_REMOTE_SHUTDOWN,
             CHIAKI_QUIT_REASON_CTRL_CONNECT_FAILED, CHIAKI_QUIT_REASON_STREAM_CONNECTION_UNKNOWN: self = .network
        case CHIAKI_QUIT_REASON_SESSION_REQUEST_RP_CRASH: self = .consoleRemotePlayCrashed
        default: self = .other(String(cString: chiaki_quit_reason_string(quit)))
        }
    }
}

/// PS5 oturum giriş şifresi (4 hane). PS5 ikinci hesapta şifre isterse Ayarlar'da kayıtlı şifre gönderilir.
public enum LoginPasscode {
    public static let length = 4

    /// Boşlukları atar; tam 4 rakam değilse nil.
    public static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.count == length, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }

    /// Şifre isteğine ne yapılacağı: kayıtlı geçerli şifre varsa ilk istekte gönderilir (libchiaki rakamları ASCII
    /// olarak bekler, chiaki-ng'deki gibi). Şifre yoksa ya da PS5 önceki şifreyi kabul etmediyse oturum kapatılır.
    public enum Reply: Equatable, Sendable {
        case send(Data)
        case stop(DisconnectReason)
    }

    public static func reply(saved: String?, incorrect: Bool) -> Reply {
        if incorrect { return .stop(.loginPasscodeIncorrect) }
        guard let pin = normalized(saved) else { return .stop(.loginPasscode) }
        return .send(Data(pin.utf8))
    }
}

public enum SessionState: Equatable, Sendable {
    case connecting
    case streaming
    case disconnected(DisconnectReason)
}

/// Tek bir libchiaki oturumunun sahibi. Geri çağrılar bu kutuya gelir; kutu, oturum kapatılıp
/// iş parçacığı beklenene (join) kadar yaşar, böylece geri çağrı serbest bırakılmış belleğe düşmez.
///
/// Oturumun günlüğü de kutunundur: libchiaki `ChiakiLog`'un yalnız adresini tutar ve iş parçacığı kapanırken bile
/// günlüğe yazar. Günlük eskiden `StreamSession`'daydı; "Çeviriyi durdur"da `StreamSession` hemen bırakılıyor, oturum
/// ise arka planda kapatılıyordu. Kapanan iş parçacığı serbest kalmış günlüğe yazınca uygulama çöküyordu
/// (EXC_BAD_ACCESS, chiaki_log ← chiaki_stream_connection_run; GitHub #21).
final class ChiakiSessionBox {
    let pointer = UnsafeMutablePointer<ChiakiSession>.allocate(capacity: 1)
    let logger = ChiakiLogger()
    let generation: Int
    weak var owner: StreamSession?
    private var torn = false
    private let lock = NSLock()
    /// Oturum isteğinin günlükten anlaşılan düşme nedeni. Ayrı kilit: `tearDown` join ederken `lock`'u tutar, o sırada
    /// libchiaki günlüğe yazabilir.
    private var hint: DisconnectReason?
    private let hintLock = NSLock()

    init(generation: Int, owner: StreamSession?) {
        self.generation = generation
        self.owner = owner
        logger.onMessage = { [weak self] text, _ in
            guard let self, let found = DisconnectReason.sessionRequestHint(fromLog: text) else { return }
            self.hintLock.lock()
            self.hint = found
            self.hintLock.unlock()
        }
    }

    var sessionRequestHint: DisconnectReason? {
        hintLock.lock()
        defer { hintLock.unlock() }
        return hint
    }

    /// `chiaki_session_init`; başarısızsa kutu kullanılmamış sayılır (kapatılacak iş parçacığı yok).
    /// `lowQuality`: bağlantı sık koptu, 720p (~10 Mbit/sn) istenir; yoksa 1080p (~15 Mbit/sn).
    func initialize(console: RegisteredConsole, accountId: Data, lowQuality: Bool = false) -> ChiakiErrorCode {
        var info = ChiakiConnectInfo()
        info.ps5 = true
        copy(console.registKey, into: &info.regist_key)
        copy(console.morning, into: &info.morning)
        chiaki_connect_video_profile_preset(&info.video_profile,
                                            lowQuality ? CHIAKI_VIDEO_RESOLUTION_PRESET_720p : CHIAKI_VIDEO_RESOLUTION_PRESET_1080p,
                                            CHIAKI_VIDEO_FPS_PRESET_30)
        info.video_profile.codec = CHIAKI_CODEC_H264
        info.video_profile_auto_downgrade = true
        info.enable_keyboard = false
        info.enable_dualsense = false
        info.audio_video_disabled = CHIAKI_AUDIO_DISABLED
        info.auto_regist = false
        info.holepunch_session = nil
        info.rudp_sock = nil
        copy(accountId, into: &info.psn_account_id)
        info.packet_loss_max = 0.05
        info.enable_idr_on_fec_failure = true

        // libchiaki adresi oturum açılırken kopyalar; geçici C dizgesi yeterli.
        let error = console.host.withCString { host -> ChiakiErrorCode in
            info.host = host
            return chiaki_session_init(pointer, &info, logger.pointer)
        }
        if !error.isSuccess { markUnused() }
        return error
    }

    /// Oturumu durdurur ve iş parçacığını bekler. libchiaki iş parçacığından çağrılmamalı.
    func tearDown() {
        lock.lock()
        defer { lock.unlock() }
        guard !torn else { return }
        torn = true
        chiaki_session_stop(pointer)
        chiaki_session_join(pointer)
        chiaki_session_fini(pointer)
    }

    /// `chiaki_session_init`/`start` başarısız olduysa: join edilecek iş parçacığı yok, kapatma adımları atlanır.
    func markUnused() {
        lock.lock()
        torn = true
        lock.unlock()
    }

    deinit {
        tearDown()
        pointer.deallocate()
    }
}

/// PS5'e (ikinci hesapla) Remote Play bağlantısı kurar ve görüntüyü kare kare verir.
/// Ses kapalıdır, kol girdisi gönderilmez. Bağlantı koparsa kendiliğinden yeniden bağlanır.
public final class StreamSession: @unchecked Sendable {
    public var onFrame: ((CGImage) -> Void)?
    public var onState: ((SessionState) -> Void)?
    /// PS5 ağda yeni bir adreste bulununca (oturum kuyruğunda) çağrılır; yeni adres kaydedilmelidir.
    public var onConsoleMoved: ((RegisteredConsole) -> Void)?

    /// Yalnız `queue` üzerinde değişir (PS5'in adresi değişirse; Windows'taki gibi).
    private var console: RegisteredConsole
    /// Son aramanın sonucu ve "bulunamadı" etiketi (yalnız `queue`).
    private var search = ConsoleSearchState()
    /// Tüm ağı taramak pahalı; PS5 kapalıyken her yeniden denemede yapılmaz.
    private var nextRelocate = Date.distantPast
    private let accountId: Data
    /// PS5 bu hesap için giriş şifresi isterse gönderilecek 4 hane (Ayarlar'da kayıtlıysa).
    private let loginPasscode: String?
    private let queue = DispatchQueue(label: "couchsubs.stream-session")
    private let decodeQueue = DispatchQueue(label: "couchsubs.decode")
    private var decoder = H264FrameDecoder()
    private var throttle = FrameThrottle(minInterval: 1.0 / 20)
    private var policy = ReconnectPolicy()
    /// Dinlenmedeki PS5 yalnız çeviri başlarken uyandırılır (yalnız `queue`).
    private var wakePolicy = WakePolicy()
    /// Bağlantı sık koparsa görüntü 720p'ye düşürülür (yalnız `queue`).
    private var quality = QualityFallback()
    /// Geçerli oturum bağlandı mı (yalnız `queue`): yalnız akış sürerken olan kopmalar sayılır.
    private var streaming = false
    /// Yalnız `queue` üzerinde okunup yazılır.
    private var box: ChiakiSessionBox?
    /// Bağlıyken görüntü gelmezse oturum yeniden kurulur. Kare çözme kuyruğundan da yazılır; `watchLock` ile korunur.
    private var watchdog = PictureWatchdog()
    private let watchLock = NSLock()
    /// PS5'teki Uzaktan Oynatma çöktüyse en çok iki kez yeniden denenir (yalnız `queue`).
    private var crashLimit = CrashRetryLimit()

    /// Durdurma isteği ve kuşak numarası; her başlat/durdur yeni bir kuşak açar ve eski
    /// bloklar (yeniden deneme, eski oturumun kapanma olayı) kendini iptal eder.
    private let stateLock = NSLock()
    private var running = false
    private var generation = 0

    public init(console: RegisteredConsole, accountId: Data, loginPasscode: String? = nil) {
        self.console = console
        self.accountId = accountId
        self.loginPasscode = LoginPasscode.normalized(loginPasscode)
    }

    deinit {
        // Kuyruk bloklarının hiçbiri self'i güçlü tutmaz; kalan oturum (varsa) arka planda kapatılır.
        if let box { DispatchQueue.global().async { box.tearDown() } }
    }

    public func start() {
        DeviceDiagnostics.raiseOpenFileLimitOnce()
        let current = bump(running: true)
        queue.async { [weak self] in
            self?.policy.reset()
            self?.wakePolicy.reset()
            self?.crashLimit.reset()
            self?.search.reset()
            self?.watch { $0.reset() }
            self?.connect(current)
        }
    }

    /// Bloklamaz: oturum arka planda kapatılır.
    public func stop() {
        _ = bump(running: false)
        queue.async { [weak self] in self?.closeBox() }
    }

    /// Mac uykudan uyandığında ya da ağ değiştiğinde uygulama tarafından çağrılır.
    public func reconnectNow() {
        guard isRunning else { return }
        let current = bump(running: true)
        queue.async { [weak self] in
            guard let self else { return }
            self.closeBox()
            self.policy.reset()
            self.crashLimit.reset()
            self.watch { $0.reset() }
            self.connect(current)
        }
    }

    // MARK: - Durum

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func bump(running: Bool) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.running = running
        generation += 1
        return generation
    }

    private func isCurrent(_ value: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && generation == value
    }

    // MARK: - Bağlantı (hepsi `queue` üzerinde)

    private func connect(_ current: Int) {
        guard isCurrent(current), box == nil else { return }
        emit(.connecting)

        // PS5 uyuyorsa uyandır; uyanmayı kuyruğu bloklamadan, aralıklı kontrollerle bekle.
        // Kayıtlı adreste başka bir PS5 yanıt verirse (aynı evde iki PS5, modem adresleri değiştirmiş; GitHub #425)
        // kayıtlı PS5 adıyla ağda aranır; bulunamazsa eskisi gibi o adrese bağlanılır.
        let atHost = Console.blockingDiscover(timeout: 2, host: console.host).first
        let info: ConsoleInfo?
        if let atHost, Self.isRegistered(atHost, name: console.name) {
            info = atHost
        } else {
            if let atHost {
                RemotePlayLog.write("PS5 oturumu: \(console.host) adresinde başka PS5 yanıt verdi (\(atHost.name)), \(console.name) aranıyor")
            }
            info = relocate() ?? atHost
        }
        if search.searched(answered: info != nil) {
            RemotePlayLog.write("PS5 aranıyor: art arda \(search.unanswered). yanıtsız arama; bu cihaz: \(DeviceDiagnostics.line())")
        }
        let action = wakePolicy.action(awake: info?.isAwake)
        if let info {
            let detail = info.isAwake ? "uyanık" : action == .wake ? "dinlenmede, uyandırılıyor" : "dinlenmede, açılması bekleniyor"
            RemotePlayLog.write("PS5 oturumu: \(info.name) \(info.host) \(detail)")
        } else {
            RemotePlayLog.write("PS5 oturumu: \(console.host) aramaya yanıt vermedi, yine de bağlanılıyor")
        }
        switch action {
        case .connect:
            openSession(current)
        case .wake:
            do { try Console.wake(console) } catch { RemotePlayLog.write("PS5 uyandırılamadı: \(error)") }
            waitForWake(current, deadline: Date().addingTimeInterval(20))
        case .waitUntilOn:
            // Kullanıcı PS5'i kapattı: yeniden açılmaz; aralıklı bakılır, PS5 açılınca bağlanılır.
            scheduleReconnect(current, reason: .consoleAsleep)
        }
    }

    /// Kayıtlı adreste PS5 yoksa (modem adresini değiştirmiş olabilir) ağda arar; bulursa adresi günceller.
    /// Eskiden yalnız Windows'ta vardı; Mac'te adres değişince bağlantı hiç kurulamıyordu.
    private func relocate() -> ConsoleInfo? {
        guard Date() >= nextRelocate else { return nil }
        nextRelocate = Date().addingTimeInterval(30)
        guard let moved = Self.pickMoved(Console.search(timeout: .seconds(3), host: nil), name: console.name),
              moved.host != console.host else { return nil }
        RemotePlayLog.write("PS5 yeni adreste: \(console.host) -> \(moved.host)")
        console = console.withHost(moved.host)
        onConsoleMoved?(console)
        return moved
    }

    /// Taramada bulunanlar arasından kayıtlı PS5: adı (kayıtta PS5'in verdiği ad) tek eşleşen; emin değilse nil.
    /// Eskiden ağda tek PS5 varsa adına bakılmadan o seçiliyordu; aynı evde iki PS5 varken biri yeniden başlarken
    /// uygulama diğerine geçip onun adresini kaydediyordu (GitHub #425).
    static func pickMoved(_ found: [ConsoleInfo], name: String) -> ConsoleInfo? {
        let named = found.filter { $0.name == name }
        return named.count == 1 ? named[0] : nil
    }

    /// Aramaya yanıt veren PS5 kayıtlı PS5 mi (ad eşleşmesi; kayıtta ad yoksa her yanıt kabul edilir).
    static func isRegistered(_ info: ConsoleInfo, name: String) -> Bool {
        name.isEmpty || info.name == name
    }

    private func waitForWake(_ current: Int, deadline: Date) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            if Console.blockingDiscover(timeout: 2, host: self.console.host).contains(where: \.isAwake) {
                self.openSession(current)
            } else if Date() < deadline {
                self.waitForWake(current, deadline: deadline)
            } else {
                self.scheduleReconnect(current, reason: .consoleAsleep)
            }
        }
    }

    private func openSession(_ current: Int) {
        guard isCurrent(current), box == nil else { return }
        // Yeniden bağlanmada çözücü sıfırdan başlar (uykudan sonra eski oturumu geçersiz olabilir).
        decodeQueue.async { [weak self] in self?.decoder = H264FrameDecoder() }

        let box = ChiakiSessionBox(generation: current, owner: self)
        let error = box.initialize(console: console, accountId: accountId, lowQuality: quality.lowered)
        guard error.isSuccess else {
            return scheduleReconnect(current, reason: .other(ChiakiError(code: error).description), initialized: false, box: box)
        }

        let user = Unmanaged.passUnretained(box).toOpaque()
        chiaki_session_set_event_cb(box.pointer, { event, user in
            guard let event, let user else { return }
            let box = Unmanaged<ChiakiSessionBox>.fromOpaque(user).takeUnretainedValue()
            box.owner?.handle(event.pointee, generation: box.generation, sessionRequestHint: box.sessionRequestHint)
        }, user)
        chiaki_session_set_video_sample_cb(box.pointer, { buffer, size, _, _, user in
            guard let buffer, let user else { return true }
            Unmanaged<ChiakiSessionBox>.fromOpaque(user).takeUnretainedValue().owner?.ingest(Data(bytes: buffer, count: size))
            return true
        }, user)

        // PS5 "bu görüntü yayınlanamaz" (korumalı içerik) ya da "yeniden yayınlanabilir" dediğinde libchiaki ctrl iş parçacığı
        // `cantdisplay_cb`yi koşulsuz çağırır; atanmazsa NULL işlev çağrılır ve uygulama SIGSEGV ile kapanır. Altyazı için
        // yapılacak bir şey yok: yalnız günlüğe yazılır, akış sürer.
        var displaySink = ChiakiCtrlDisplaySink(user: user, cantdisplay_cb: { _, cantDisplay in
            RemotePlayLog.write(cantDisplay ? "PS5 stream can't display (protected content)" : "PS5 stream can display again")
        })
        chiaki_session_ctrl_set_display_sink(box.pointer, &displaySink)

        let started = chiaki_session_start(box.pointer)
        guard started.isSuccess else {
            chiaki_session_fini(box.pointer)
            return scheduleReconnect(current, reason: .other(ChiakiError(code: started).description), initialized: false, box: box)
        }
        self.box = box
    }

    /// Geçerli oturumu kapatır. Kapatma join içerdiği için kuyruğu bekletmemek adına arka planda yapılır.
    private func closeBox() {
        streaming = false
        watch { $0.ended() }
        guard let box else { return }
        self.box = nil
        DispatchQueue.global().async { box.tearDown() }
    }

    /// libchiaki iş parçacığından çağrılır.
    fileprivate func handle(_ event: ChiakiEvent, generation eventGeneration: Int, sessionRequestHint: DisconnectReason?) {
        switch event.type {
        case CHIAKI_EVENT_CONNECTED:
            queue.async { [weak self] in
                guard let self, self.box?.generation == eventGeneration else { return }
                self.policy.connected()
                self.wakePolicy.streamed()
                self.crashLimit.reset()
                self.search.connected()
                self.streaming = true
                self.watch { $0.connected() }
                self.emit(.streaming)
                self.scheduleWatch(eventGeneration)
            }
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            // libchiaki olayı state_mutex tutarken verir; şifre kuyrukta (kilit bırakıldıktan sonra) gönderilir.
            let reply = LoginPasscode.reply(saved: loginPasscode, incorrect: event.login_pin_request.pin_incorrect)
            queue.async { [weak self] in
                guard let self, let box = self.box, box.generation == eventGeneration else { return }
                switch reply {
                case .send(let pin):
                    RemotePlayLog.write("PS5 giriş şifresi istedi; Ayarlar'daki şifre gönderiliyor")
                    pin.withUnsafeBytes { raw in
                        _ = chiaki_session_set_login_pin(box.pointer, raw.bindMemory(to: UInt8.self).baseAddress, pin.count)
                    }
                case .stop(let reason):
                    // Şifre yok ya da yanlış: yeniden denemek aynı yere çıkar, oturum kapatılır.
                    _ = self.bump(running: false)
                    self.closeBox()
                    self.emit(.disconnected(reason))
                }
            }
        case CHIAKI_EVENT_QUIT:
            let reason = DisconnectReason(quit: event.quit.reason, sessionRequestHint: sessionRequestHint)
            queue.async { [weak self] in
                // Eski bir oturumun (ör. reconnectNow ile kapatılanın) kapanma olayı yeni oturumu etkilemez.
                guard let self, self.box?.generation == eventGeneration else { return }
                let wasStreaming = self.streaming
                // Bekçi değil libchiaki kapattı (PS5 ya da ağ); görüntünün son ana kadar gelip gelmediği nedeni ayırır.
                if let summary = self.watch({ $0.summary() }) {
                    RemotePlayLog.write("PS5 oturumunu libchiaki kapattı (\(reason)); \(summary)")
                }
                self.closeBox()
                self.policy.ended()
                if wasStreaming, QualityFallback.countsAsDrop(reason) { self.noteDrop() }
                if reason == .registrationInvalid {
                    // Kayıt geçersiz: yeniden denemek aynı yere çıkar (eskiden sonsuza kadar "Yeniden bağlanılıyor…").
                    _ = self.bump(running: false)
                    return self.emit(.disconnected(.registrationInvalid))
                }
                if reason == .consoleRemotePlayCrashed {
                    let retry = self.crashLimit.crashed()
                    RemotePlayLog.write("PS5'teki Uzaktan Oynatma çöktü (art arda \(self.crashLimit.crashes)); "
                        + (retry ? "yeniden deneniyor" : "yeniden bağlanma bırakıldı, PS5 tamamen kapatılıp açılmalı"))
                    if !retry {
                        // PS5 kapatılıp açılmadan her deneme aynı yanıtı alır (eskiden sonsuz "Yeniden bağlanılıyor…").
                        _ = self.bump(running: false)
                        return self.emit(.disconnected(reason))
                    }
                }
                // PS5'in adresi TCP bağlantısını reddetti: PS5 yeni uyanıyor olabilir ya da adres başka bir cihaza geçmiş
                // olabilir. Bir sonraki denemede beklemeden ağda da aranır (eşlemeyi yenilemek bunu çözmez).
                if reason == .refused { self.nextRelocate = .distantPast }
                self.scheduleReconnect(eventGeneration, reason: reason)
            }
        default:
            break
        }
    }

    private func watch<T>(_ body: (inout PictureWatchdog) -> T) -> T {
        watchLock.lock()
        defer { watchLock.unlock() }
        return body(&watchdog)
    }

    /// Bağlıyken saniyede bir bakılır: görüntü `PictureWatchdog.stallAfter`'dan uzun süredir gelmiyorsa bağlantı açık
    /// görünse de oturum kapatılıp yeniden kurulur (bkz. `PictureWatchdog`).
    private func scheduleWatch(_ boxGeneration: Int) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.box?.generation == boxGeneration, self.isCurrent(boxGeneration) else { return }
            guard let gap = self.watch({ $0.stalled() }) else { return self.scheduleWatch(boxGeneration) }
            let next = self.watch { $0.afterStall() }
            let streak = self.watch { $0.noPictureSessions }
            let summary = self.watch { $0.summary() } ?? ""
            RemotePlayLog.write("PS5'ten \(Int(gap)) sn'dir görüntü gelmiyor (bağlantı açık, art arda görüntüsüz oturum \(streak)); "
                + "oturumu görüntü bekçisi kapatıyor: \(next); \(summary)")
            self.closeBox()
            self.policy.ended()
            self.noteDrop()
            if next == .giveUp {
                // Görüntü hiç gelmiyor: sonsuz yeniden bağlanma döngüsü yerine dur ve nedenini söyle.
                _ = self.bump(running: false)
                return self.emit(.disconnected(.noPicture))
            }
            self.scheduleReconnect(boxGeneration, reason: .other(PictureWatchdog.reason))
        }
    }

    /// Akış sürerken bağlantı koptu: sık oluyorsa sonraki oturumlar 720p açılır.
    private func noteDrop() {
        guard quality.dropped() else { return }
        RemotePlayLog.write("PS5 bağlantısı \(Int(QualityFallback.window / 60)) dk içinde \(QualityFallback.dropsToLower) kez koptu; "
            + "görüntü 720p'ye düşürülüyor (daha az bant genişliği). Kalıcı çözüm: PS5'i modeme kabloyla bağlayın")
    }

    private func scheduleReconnect(_ current: Int, reason: DisconnectReason, initialized: Bool = true, box failed: ChiakiSessionBox? = nil) {
        // Başlatılamamış kutunun join edilecek iş parçacığı yok; yalnız belleği bırakılır.
        if let failed, !initialized { failed.markUnused() }
        emit(.disconnected(search.classify(reason, host: console.host)))
        guard isCurrent(current) else { return }
        let delay = policy.nextDelay(inUse: reason == .inUse)
        RemotePlayLog.write("PS5 oturumu: \(delay) sn sonra yeniden denenecek")
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in self?.connect(current) }
    }

    /// Her kare çözülür (sonraki kareler öncekilere dayanır); görüntü saniyede en çok 20 kez üretilir.
    /// Okuma meşgulken gelen kareler zaten atlanır; sık kare, altyazının erken ve eksiksiz yakalanmasını sağlar.
    fileprivate func ingest(_ sample: Data) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            let wanted = self.throttle.shouldPass()
            if let image = self.decoder.decode(annexB: sample, makeImage: wanted), wanted {
                self.watch { $0.picture() }
                self.onFrame?(image)
            }
        }
    }

    private func emit(_ state: SessionState) {
        // Ana ekrandaki durumun nedeni remoteplay.log'da da görünsün.
        if state != .connecting { RemotePlayLog.write("PS5 oturumu: \(state)") }
        onState?(state)
    }
}

extension Console {
    /// Senkron arama (yalnız oturum kuyruğunda kullanılır).
    static func blockingDiscover(timeout: Double, host: String) -> [ConsoleInfo] {
        search(timeout: .seconds(timeout), host: host)
    }
}
