// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Çeviri başlayınca TV uygulamasını kendiliğinden açma neden olmadı (bekçinin son denemesi). Ana ekranda TV uygulaması
/// bağlı değilken tek satırla söylenir. Windows (TvOpenProblem) ve Android telefondaki (TvOpenProblem) ile aynı.
///
/// Eskiden açma sessizce başarısız oluyordu: kullanıcı TV'de CouchSubs'ı kendisinin açması gerektiğini bilmiyordu ("ilk
/// başta olmadı, sonra oldu; TV'den de uygulamayı açmak lazımmış", mobil sürüm, 21 Kas).
public enum TVOpenProblem: String, Sendable, Equatable {
    /// LG/Samsung: TV yanıt vermedi (kapalı, başka ağda ya da açmayı reddetti).
    case unreachable
    /// LG/Samsung: bu cihazın TV'den aldığı izin (anahtar) yok; TV'ye yeniden bağlanılmalı.
    case notPaired
    /// Android TV: ADB portuna ulaşılamadı (TV kapalı ya da ağ üzerinden hata ayıklama kapalı).
    case debugOff
    /// Android TV: TV bu cihazın hata ayıklama iznini onaylamamış (ADB eşleşmesi yok).
    case debugNotApproved
    /// Samsung: açma komutu gitti ama TV uygulaması `TVKeeper.samsungOpenCheck` içinde bağlanmadı (TV komutu yok saydı).
    case notOpened
    /// Samsung: TV, CouchSubs'ın kurulu olduğunu doğrulamadı (listede yok ya da liste 3 sn'de gelmedi); açma komutu
    /// gönderilmedi. Kurulu olmayan uygulamaya DEEP_LINK Smart Hub'ı mağazaya yollar, TV "Samsung sunucusuna
    /// bağlanılamıyor (AS400)" der (Samsung 7 Series 2018, 21 Kas).
    case notInstalled

    /// Bekçinin bildirdiği sorun, ekranda gösterilecek olana çevrilir: LG/Samsung'da kayıtlı anahtar yokken yanıt vermeyen
    /// TV "izin yok" sayılır (TV'nin izin sorusu yanıtlanmamış).
    public static func shown(_ reported: TVOpenProblem?, brand: TVBrand, hasKey: Bool) -> TVOpenProblem? {
        guard let reported else { return nil }
        if reported == .unreachable, brand != .androidTV, !hasKey { return .notPaired }
        return reported
    }
}

/// TV uygulaması bağlı değilken ana ekranda görünen yönlendirme metinleri (İngilizce anahtar; Localizable.xcstrings TR/EN,
/// Windows da aynı anahtarları okur, Android strings.xml'de aynı metinler).
public enum TVOpenText {
    /// TV markasına göre tek cümle: CouchSubs TV'de nerede bulunur.
    public static func openOnTV(_ brand: TVBrand) -> String {
        brand == .androidTV
            ? "If CouchSubs didn't open on the TV by itself, open it on the TV: on Android TV it's under Apps."
            : "If CouchSubs didn't open on the TV by itself, open it on the TV: it's in the TV's app list."
    }

    /// Otomatik açmanın neden olmadığı (bilinmiyorsa nil).
    public static func reason(_ problem: TVOpenProblem?) -> String? {
        switch problem {
        case nil: nil
        case .unreachable: "Couldn't open it automatically: the TV didn't answer. Is the TV on and on the same Wi-Fi as this device?"
        case .notPaired: "Couldn't open it automatically: this device has no permission from the TV yet. Connect the TV again and allow it on the TV."
        case .debugOff: "Couldn't open it automatically: the TV can't be reached for debugging. Is the TV on, with network debugging on in Developer options?"
        case .debugNotApproved: "Couldn't open it automatically: the TV hasn't allowed debugging from this device. Reinstall the TV app and allow it on the TV."
        case .notOpened: "Couldn't open it automatically: the TV got the open command but didn't open CouchSubs. Open it on the TV with the remote."
        case .notInstalled: notInstalledReason
        }
    }

    public static let notInstalledReason = "Couldn't open it automatically: the TV didn't confirm that the CouchSubs TV app is installed, so no open command was sent. Install the TV app, then try again. If the TV shows “Unable to connect to Samsung server” (AS400), the TV can't reach Samsung's servers: check its internet connection and unplug it for 30 seconds."

    /// Samsung kurulumu başarısız olunca: TV'nin kendi "Samsung sunucusuna bağlanılamıyor (AS400)" uyarısı ne demek.
    public static let samsungServerHint = "If the TV shows “Unable to connect to Samsung server” (AS400): this warning comes from the TV itself; the TV can't reach Samsung's servers. Check the TV's internet connection, unplug the TV and plug it back in after 30 seconds. To install CouchSubs, enter this device's address as Host PC IP."

    public static let tryButton = "Try opening automatically"

    /// Kurulum sihirbazının son adımı (TV seçildiyse).
    public static let wizardNote = "Every time you start translating, CouchSubs tries to open the TV app by itself. If it doesn't open, open CouchSubs on the TV."
}

/// Android TV bekçisinin "şimdi açmayı dene" kararı (Mac ve iPhone; Windows'taki AndroidTvOpenRule ve Android telefondaki
/// AndroidTvOpenRule ile aynı kural).
///
/// X'te bildirildi (Android TV 8, çeviri MacBook'tan, beta.74): "TV'den uygulamayı açtığımda çevirili ekran gelip hemen başka
/// bir ekrana geçiyor, HDMI seçemiyorum". Bekçi TV uygulaması bağlı görünmediği her an, 30 sn'de bir ve sınırsız `am start`
/// gönderiyordu; kullanıcı CouchSubs'ı kumandadan açınca katmanın bağlantısı kapanıp sayfanınki kurulana kadar geçen birkaç
/// saniye de buna yetiyordu. TV uygulaması (0.9.54 ve öncesi) parametreli açılışta kayıtlı katman tercihine dönüp ekranı
/// kapatıyordu; kullanıcı TV'nin kendi girişindeyken de CouchSubs öne çekiliyordu. Artık:
/// - TV uygulaması bu çeviride bir kez bağlandıysa bekçi onu bir daha açmaz (kullanıcı çıktı ya da başka girişe geçti);
/// - hiç bağlanmadıysa en çok `maxOpens` kez, aralarında en az `interval` saniye açılır;
/// - "Otomatik açmayı dene" ve uykudan dönüş (`reset`) sayacı sıfırlar.
/// Uygulama TV'de zaten çalışıyorsa (ekranı ya da katmanı) `am start` hiç gönderilmez (ADB tarafı `AndroidTVApp.isRunning`
/// ile bakar).
///
/// X'te bildirildi (Android TV, beta.77): "izni sürekli yeniden istiyor". Kanıtlı (kod): sınır yalnız gerçekten gönderilen
/// `am start`'ları sayıyordu. TV bu cihazı "Her zaman izin ver" işaretlenmeden onayladıysa ya da hiç onaylamadıysa her deneme
/// "açılamadı" oluyor, uygulama TV'de çalışıp bağlı değilse "zaten açık" oluyor, ikisi de sayılmıyordu: bekçi çeviri boyunca
/// 30 sn'de bir yeni ADB bağlantısı açıyor, TV her seferinde "Hata ayıklamaya izin verilsin mi?" diye soruyordu. (ADB
/// anahtarı dört platformda kalıcıdır; soru anahtar değiştiği için değil, onay kalıcı verilmediği için yineleniyordu.)
/// Artık her ADB bağlantısı, sonucu ne olursa olsun bir deneme sayılır: çeviri başına en çok `maxOpens` bağlantı.
public struct AndroidTVOpenRule: Sendable {
    public static let defaultMaxOpens = 3
    public static let defaultInterval: TimeInterval = 30

    public let maxOpens: Int
    public let interval: TimeInterval
    /// Açılan ADB bağlantıları (açıldı, zaten açık ya da açılamadı); sınır bunu sayar.
    public private(set) var attempts = 0
    /// Gerçekten gönderilen `am start`'lar.
    public private(set) var opens = 0
    public private(set) var everConnected = false
    private var lastAttempt: TimeInterval?

    public init(maxOpens: Int = AndroidTVOpenRule.defaultMaxOpens, interval: TimeInterval = AndroidTVOpenRule.defaultInterval) {
        self.maxOpens = maxOpens
        self.interval = interval
    }

    /// Bu kontrolde ADB bağlantısı açılıp açma denensin mi (`now`: saniye, tekdüze saat). true dönerse deneme sayılır.
    /// Uygulama bağlıyken hiç bağlantı açılmaz.
    public mutating func shouldTry(connected: Bool, now: TimeInterval) -> Bool {
        if connected { everConnected = true; return false }
        if everConnected || attempts >= maxOpens { return false }
        if let lastAttempt, now - lastAttempt < interval { return false }
        lastAttempt = now
        attempts += 1
        return true
    }

    /// `am start` gerçekten gönderildi (uygulama kapalıydı).
    public mutating func opened() { opens += 1 }

    /// "Otomatik açmayı dene" ya da uykudan dönüş: yeniden en çok `maxOpens` deneme, beklemeden.
    public mutating func reset() {
        attempts = 0
        opens = 0
        everConnected = false
        lastAttempt = nil
    }
}

/// CouchSubs TV Android TV'de çalışıyor mu (ADB kabuğundan; Windows ve Android telefondaki AndroidTvApp ile aynı).
public enum AndroidTVApp {
    public static let packageName = "com.couchsubs.tv"

    /// Etkinlik yığınlarındaki kayıtlar (ekran arka planda olsa da yığındadır) ve paketin servisleri (katman).
    public static let runningCommand = "shell:dumpsys activity activities | grep Hist; dumpsys activity services \(packageName) | grep ServiceRecord"

    /// `runningCommand` çıktısında CouchSubs TV'nin ekranı ya da katman servisi var mı. Çıktı boşsa ya da tanınmıyorsa
    /// (çok eski TV'de `grep` yok) çalışmıyor sayılır: eski yol, açma sınırı yine geçerli.
    public static func isRunning(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            ((line.contains("Hist") && line.contains("ActivityRecord{")) || line.contains("ServiceRecord{"))
                && line.contains("\(packageName)/")
        }
    }

    /// Uygulama zaten açıkken açma denemesinin sonucu (günlükte "açıldı: zaten açık").
    public static let alreadyRunning = "zaten açık"
}
