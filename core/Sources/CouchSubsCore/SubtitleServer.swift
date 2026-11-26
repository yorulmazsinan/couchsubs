// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Network

/// TV'de çevirinin oyundaki İngilizce altyazıya göre yeri.
public enum SubtitlePlacement: String, Codable, CaseIterable, Sendable {
    /// İngilizce altyazının üstüne, onu örterek.
    case cover
    /// İngilizce altyazının hemen üstünde.
    case above
    /// İngilizce altyazının hemen altında.
    case below
    /// Ekranda sabit bir yükseklikte (`bottomPercent`).
    case fixed
}

/// Altyazı kutusunun kapladığı alan.
public enum SubtitleBackgroundShape: String, Codable, CaseIterable, Sendable {
    /// Kutu yazı kadar (ya da örtüyse okunan altyazı bölgesi kadar) yer kaplar.
    case fit
    /// Kutu tam genişlikte bir bant: oyundaki İngilizce altyazı yan yana taşsa da görünmez.
    case band
}

/// TV'de altyazı yazısının rengi.
public enum SubtitleTextColor: String, Codable, CaseIterable, Sendable {
    case white
    case yellow
}

/// Karakter adının rengi (Altyazı Görünümü › Karakter Adı): yazıyla aynı, herkes tek renk ya da karaktere göre.
public enum NameColorMode: String, Codable, CaseIterable, Sendable {
    case text, single, speaker
    /// "Tüm Satır": karaktere göre renk; ad ve cümle o karakterin renginde (TV'ye `style.wholeLine`).
    case line

    /// Ad renkleri karaktere göre mi (Karaktere Göre ya da Tüm Satır).
    public var perCharacter: Bool { self == .speaker || self == .line }
}

/// Android TV'de PS5 görüntüsünün nasıl gösterildiği (Windows TvDisplayMode, Android TvDisplayMode ile aynı).
///
/// Ham değer hem kayıtta hem TV'ye giden `displayMode` alanındadır. Eskiden varsayılan "uygulama içinde"ydi ve "inApp"
/// diye kaydediliyordu; bazı TV'lerde (Philips 55PUS8609, TCL) görüntü orada siyah kalıyor, altyazı yalnız Katman'da
/// geliyordu. "inApp" artık Otomatik'tir: kullanıcı seçmediyse de bu kaydediliyordu, ayrılamaz. TV uygulaması 0.9.74+
/// Otomatik'te izin varsa katmanda açar; eski TV uygulaması "inApp"i eskisi gibi uygulama içi sayar.
public enum TVDisplayMode: String, Codable, CaseIterable, Sendable {
    /// Varsayılan: TV uygulaması katmana izin veriyorsa (bilgisayarın/telefonun kurduğu APK) katman, yoksa uygulama içi.
    case auto = "inApp"
    /// Bilerek seçilmiş uygulama içi: HDMI CouchSubs'ın içinde; TV uygulaması (0.9.84+) hiçbir durumda kendiliğinden katmana geçmez.
    case inApp = "inAppOnly"
    /// TV HDMI'yı kendi ekranında gösterir, altyazı üstteki şeffaf katmanda (bazı TV'lerde uygulama içi görüntü siyah kalıyor).
    case overlay
}

/// TV'de altyazının görünümü.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    /// 36 (küçük), 46 (orta), 58 (büyük), 72 (çok büyük)
    public var fontSize: Int
    /// Sabit yerleşimde altyazının ekranın altından uzaklığı, yüzde.
    public var bottomPercent: Int
    public var placement: SubtitlePlacement
    /// Yazının arkasındaki siyah zeminin koyuluğu, yüzde (0: zemin yok).
    public var background: Int
    /// Zeminin kapladığı alan; eski TV uygulamaları alanı tanımaz, `fit` gibi davranır.
    public var backgroundShape: SubtitleBackgroundShape
    public var bold: Bool
    public var textColor: SubtitleTextColor
    /// Yalnız Android TV uygulaması kullanır; diğer TV'ler ve OBS katmanı alanı tanımaz.
    public var displayMode: TVDisplayMode
    /// Hızlı konuşmada önceki satır(lar) yeni satırın üstünde kısa süre soluk kalsın mı; kapalıysa yeni satır eskisinin
    /// yerine geçer. TV uygulaması 0.9.16 ve sonrası tanır (Windows: SubtitleStyle.StackPrevious).
    public var stackPrevious: Bool
    /// Zeminin rengi ("#RRGGBB"); koyuluğu `background`. TV'ye `backgroundColor` olarak gider; eski TV uygulaması siyah çizer.
    public var backgroundColor: String
    /// Yazının rengi ("#RRGGBB"); nil ise `textColor` (beyaz/sarı). TV'ye `textHex` olarak gider, `textColor` da en yakın
    /// eski renkle gönderilir.
    public var textHex: String?
    /// Karakter adının rengi; `speaker` ve `single`da satırın `speakers` alanı dolar (bkz. `SpeakerColorBook.configure`).
    public var nameColorMode: NameColorMode
    /// "Tek Renk"te adların rengi.
    public var nameHex: String?
    /// "Karaktere Göre"de kullanıcının seçtiği renkler (küçük harfli ad → "#RRGGBB").
    public var characterColors: [String: String]
    /// Konuşan rengi yalnız adı boyar (yeni arayüz); false ise eski davranış: ad ve satır o renkte. TV'ye `nameOnly`.
    public var nameOnly: Bool
    /// Kurulumda seçilen TV girişi (HDMI 1–4); TV uygulaması değer değişince o girişi açar (TV'de elle seçilen giriş,
    /// aynı değer yeniden gelince ezilmez). nil: seçilmedi. TV'ye `hdmiInput`.
    public var hdmiInput: Int?

    public static let defaultBackgroundColor = "#101014"

    public init(fontSize: Int = 46, bottomPercent: Int = 7, placement: SubtitlePlacement = .cover, background: Int = 90, backgroundShape: SubtitleBackgroundShape = .fit, bold: Bool = false,
                textColor: SubtitleTextColor = .white, displayMode: TVDisplayMode = .auto, stackPrevious: Bool = true,
                backgroundColor: String = SubtitleStyle.defaultBackgroundColor, textHex: String? = nil, nameColorMode: NameColorMode = .speaker,
                nameHex: String? = nil, characterColors: [String: String] = [:], nameOnly: Bool = false, hdmiInput: Int? = nil) {
        self.fontSize = fontSize
        self.bottomPercent = bottomPercent
        self.placement = placement
        self.background = background
        self.backgroundShape = backgroundShape
        self.bold = bold
        self.textColor = textColor
        self.displayMode = displayMode
        self.stackPrevious = stackPrevious
        self.backgroundColor = backgroundColor
        self.textHex = textHex
        self.nameColorMode = nameColorMode
        self.nameHex = nameHex
        self.characterColors = characterColors
        self.nameOnly = nameOnly
        self.hdmiInput = hdmiInput
    }

    private enum CodingKeys: String, CodingKey {
        case fontSize, bottomPercent, placement, background, backgroundShape, bold, textColor, displayMode, stackPrevious
        case backgroundColor, textHex, nameColorMode, nameHex, characterColors, nameOnly, hdmiInput
    }

    /// Eski sürümün kaydettiği ayarlarda yeni alanlar yoktur; eksikler varsayılanla dolar.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SubtitleStyle()
        fontSize = try values.decodeIfPresent(Int.self, forKey: .fontSize) ?? defaults.fontSize
        bottomPercent = try values.decodeIfPresent(Int.self, forKey: .bottomPercent) ?? defaults.bottomPercent
        placement = (try? values.decodeIfPresent(SubtitlePlacement.self, forKey: .placement)) ?? defaults.placement
        background = try values.decodeIfPresent(Int.self, forKey: .background) ?? defaults.background
        backgroundShape = (try? values.decodeIfPresent(SubtitleBackgroundShape.self, forKey: .backgroundShape)) ?? defaults.backgroundShape
        bold = try values.decodeIfPresent(Bool.self, forKey: .bold) ?? defaults.bold
        textColor = (try? values.decodeIfPresent(SubtitleTextColor.self, forKey: .textColor)) ?? defaults.textColor
        displayMode = (try? values.decodeIfPresent(TVDisplayMode.self, forKey: .displayMode)) ?? defaults.displayMode
        stackPrevious = try values.decodeIfPresent(Bool.self, forKey: .stackPrevious) ?? defaults.stackPrevious
        backgroundColor = Self.hex((try? values.decodeIfPresent(String.self, forKey: .backgroundColor)) ?? nil) ?? defaults.backgroundColor
        textHex = Self.hex((try? values.decodeIfPresent(String.self, forKey: .textHex)) ?? nil)
        nameColorMode = (try? values.decodeIfPresent(NameColorMode.self, forKey: .nameColorMode)) ?? defaults.nameColorMode
        nameHex = Self.hex((try? values.decodeIfPresent(String.self, forKey: .nameHex)) ?? nil)
        characterColors = ((try? values.decodeIfPresent([String: String].self, forKey: .characterColors)) ?? nil)?
            .compactMapValues { Self.hex($0) } ?? [:]
        nameOnly = (try? values.decodeIfPresent(Bool.self, forKey: .nameOnly)) ?? defaults.nameOnly
        hdmiInput = ((try? values.decodeIfPresent(Int.self, forKey: .hdmiInput)) ?? nil).flatMap { (1...4).contains($0) ? $0 : nil }
    }

    /// Geçerli "#RRGGBB" ise büyük harfle; değilse nil.
    public static func hex(_ value: String?) -> String? {
        guard let value, value.count == 7, value.first == "#", UInt32(value.dropFirst(), radix: 16) != nil else { return nil }
        return value.uppercased()
    }

    /// TV'ye giden `style` olayının gövdesi.
    var json: [String: Any] {
        ["fontSize": fontSize, "bottomPercent": bottomPercent, "placement": placement.rawValue,
         "background": max(0, min(100, background)), "backgroundShape": backgroundShape.rawValue, "bold": bold, "textColor": textColor.rawValue,
         "displayMode": displayMode.rawValue, "stackPrevious": stackPrevious,
         "backgroundColor": backgroundColor, "nameOnly": nameOnly, "wholeLine": nameColorMode == .line]
            .merging(textHex.map { ["textHex": $0] } ?? [:]) { $1 }
            .merging(hdmiInput.map { ["hdmiInput": $0] } ?? [:]) { $1 }
    }
}

/// Sunucudan geçen ve bilgisayar ekranındaki altyazı penceresinin de gösterdiği olay.
public enum SubtitleEvent: Equatable, Sendable {
    /// `replaces`: satır öncekinin uzamış ya da düzelmiş okumasıdır; öncekinin üstüne yığılmaz, yerine geçer. `box`: oyundaki
    /// altyazının karedeki yeri; pencere "Yazı kadar" kutuyu onu örtecek kadar büyütür (bkz. `OverlayCover`).
    case subtitle(text: String, durationMs: Int, paragraphs: Bool, replaces: Bool = false, box: TextBox? = nil)
    case clear
    /// "Ekranı çevir" sonuçları: grupların çevirisi, yukarıdan aşağı, her biri ayrı satırda; `items` her birini yeri ve
    /// özgün stiliyle taşır (yayın penceresi onları kendi yerinde çizer, telefon kartı dahil).
    case screen(text: String, durationMs: Int, items: [ScreenTranslation.Item] = [])
    /// "Ekranı çevir" çevirileri kaldırıldı.
    case screenClear
    /// Ek alanın (görev, telefon, bildirim) çevirisi; `text` boşsa o alanın kutusu kalkar.
    case region(id: String, text: String, box: TextBox?)
    /// Bütün ek alan kutuları kalktı (çeviri durdu).
    case regionClear
    /// Oyun içi telefonun renkleri ve yerleriyle gösterilen balonları. Boş liste yalnız telefonu kaldırır.
    case gamePhone([ScreenTranslation.Item])
    /// Kendiliğinden bulunan ekran yazısının blokları, özgün yazının yeri ve stiliyle (`TextLook`). Kutu kaldırılırken
    /// `region` olayı boş metinle gelir.
    case screenText(id: String, items: [ScreenTranslation.Item])
}

/// TV uygulamasının bağlandığı yerel Server-Sent Events sunucusu.
/// `GET /events` akışında `subtitle`, `clear` ve `style` olaylarını yayınlar.
public final class SubtitleServer: @unchecked Sendable {
    public enum ServerError: Error { case failedToStart(String) }

    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "couchsubs.subtitle-server")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    /// OBS katmanı gibi TV olmayan izleyiciler: olayları alır ama "TV bağlı" sayısına katılmaz.
    private var viewers: Set<ObjectIdentifier> = []
    private var lastStyle: SubtitleStyle?
    private var pingTimer: DispatchSourceTimer?
    /// Gösterilen ek alanların son `region` olayları (sunucunun kuyruğunda). TV yeniden bağlanınca bunlar yeniden
    /// gönderilir, gösterilmeyenler kaldırılır (`region-sync`); her `regionRefreshInterval`'da telefon kartı dışındakiler
    /// `keep` bayrağıyla yenilenir. TV, yenilenmeyen alanı 15 sn sonra kendisi kaldırır (#1198; tv-webos/app.js
    /// REGION_LIFE_MS). Windows: SubtitleServer.liveRegions, Android: SubtitleServer.liveRegions.
    private var liveRegions: [String: [String: Any]] = [:]
    /// Telefona yapışık çevirinin son `anchor` olayı (kaybolunca nil); yeni bağlanan TV'ye yinelenir. Sunucunun kuyruğunda.
    private var liveAnchor: [String: Any]?
    private var regionTimer: DispatchSourceTimer?
    /// Gösterilen ek alanların TV'de yenilenme aralığı (TV'deki 15 sn'lik ömrün üçte biri).
    var regionRefreshInterval: TimeInterval = 5
    /// Ek alanların okuma turunun (`RegionWatcher.pass`) en son döndüğü an (`regionsAlive`; sunucunun kuyruğunda).
    private var regionAliveAt: Int?
    /// Okuma turu bu kadar süredir dönmüyorsa (uygulama donmuş, tur takılmış) gösterilen alanlar TV'de yenilenmez ve yeni
    /// bağlanan TV'ye yinelenmez: TV onları 15 sn'lik ömrü dolunca kendisi kaldırır. Yenileme kendi zamanlayıcısıyla
    /// döndüğü için uygulama donsa da sürüyor, son çeviri ("ARKANA BAK") TV'de sonsuza dek kalıyordu (#1271). En uzun tur
    /// (okuma + 8 sn'lik çeviri sınırı, yavaşlatılmış aralık) bunun altında kalır. Windows ve Android aynı.
    public static let regionAliveMs = 20_000
    /// `GET` ile verilen dosyalar: dublaj sesleri ve seslendirme modelinin ses örnekleri.
    private var files: [String: (data: Data, type: String)] = [:]
    private var speechPaths: [String] = []
    private var speechNumber = 0
    private var key: String
    private let allowLegacy: Bool
    public let pairing: SubtitlePairing
    /// 403 alan Origin değerleri günlüğe bir kez yazılır (GitHub #1132).
    private let rejectedOrigins = SubtitleAccess.RejectedOrigins()
    public var onPairingRequest: (@Sendable (SubtitlePairing.Ticket) -> Void)?
    private var legacySeen = false
    public var onLegacyClient: (@Sendable () -> Void)?
    public var accessKey: String { queue.sync { key } }
    public var hasLegacyClient: Bool { queue.sync { legacySeen } }

    public func rotateKey(_ key: String) {
        queue.sync {
            self.key = key
            pairing.reset()
            for connection in clients.values { connection.cancel() }
            clients.removeAll()
            viewers.removeAll()
            legacyClients.removeAll()
            linkIds.removeAll()
            ackMisses.removeAll()
            notifyClientsChanged()
        }
    }

    public var onClientsChanged: ((Int) -> Void)?

    /// Altyazı ve temizleme olayları gönderildiği anda buraya da verilir (çağıranın iş parçacığında). Bilgisayar
    /// ekranındaki pencere TV'ye gidenin aynısını gösterir; sunucu başlamamış olsa da çalışır.
    public var onEvent: (@Sendable (SubtitleEvent) -> Void)?

    /// false ise altyazı olayları TV'lere gitmez (altyazı yalnız bilgisayar ekranında); OBS katmanı almaya devam eder.
    public var sendsToTV: Bool {
        get { queue.sync { tvEnabled } }
        set { queue.sync { tvEnabled = newValue } }
    }
    private var tvEnabled = true

    /// Konuşan adını renklendir: açıksa adlı satırları olan `subtitle` olayına `speakerNames` alanı ([{name, color}])
    /// eklenir; TV yalnız satır başındaki adı o renkte gösterir, cümle yazı renginde kalır. Eski `speakers` alanı
    /// gönderilmez: 0.9.79'dan eski TV uygulamaları onunla bütün satırı boyuyordu; yeni alanı tanımaz, tek renk gösterir.
    public var speakerColors: Bool {
        get { queue.sync { colorsEnabled } }
        set { queue.sync { colorsEnabled = newValue } }
    }
    private var colorsEnabled = false

    /// Oturumun konuşan renkleri (v2; çeviri başlayınca sıfırlanır). Bilgisayar ekranındaki pencereler de buradan boyar.
    public let speakerBook = SpeakerColorBook()

    /// "Ekran yazılarını altyazıdan ayır": TV ek alan kutularını özgün renginde ve kendi yerinde, altyazı kutusundan farklı
    /// zeminde çizer (`style` olayının `setApart` alanı; yoksa açık sayılır). Değişince `sendStyle` yeniden gönderilmeli.
    public var setApart: Bool {
        get { queue.sync { apart } }
        set { queue.sync { apart = newValue } }
    }
    private var apart = true

    /// Bu cihazın paketindeki TV uygulamasının sürümü: `link` olayının `latest` alanıyla TV'ye bildirilir. TV'deki
    /// uygulama bundan eskiyse TV'nin paneli "TV uygulaması eski" der (GitHub #1199: LG'de 0.9.71 kalmıştı, düzeltme
    /// 0.9.94'teydi). nil ya da boş: alan gönderilmez. Windows ve Android ile aynı.
    public var latestTVAppVersion: String? {
        get { queue.sync { latestVersion } }
        set { queue.sync { latestVersion = newValue } }
    }
    private var latestVersion: String?

    /// Bağlantı canlı tutma çerçevesi: yorum satırını EventSource görmez; adlı "ping" olayını TV görür ve
    /// bir süre gelmezse yarı açık kalmış bağlantıyı kapatıp yeniden bağlanır (Windows ile aynı).
    static let pingFrame = ": ping\n\nevent: ping\ndata: {}\n\n"
    private let pingInterval: TimeInterval

    /// TV'nin alındısı (bağlantı denetimi): ping yalnız bilgisayardan TV'ye gidiyordu; TV'nin onu gerçekten aldığı
    /// bilinmiyordu. LG uygulaması arka plana düşüp askıya alınınca (ya da Android TV uygulamayı dondurunca) TV'nin ağ
    /// katmanı soketi açık tutuyor, TCP canlılık denetimi ve gönderim hatası hiç gelmiyordu: telefon/bilgisayar saatlerce
    /// "Bağlı" gösteriyor, altyazı TV'ye ulaşmıyor, LG bekçisi geri çekildiyse uygulama bir daha öne gelmiyordu; kullanıcı
    /// ancak CouchSubs'tan çıkıp girince düzeliyordu (LG + iPhone, 20-25 dk sonra). Akış açılınca `link` olayı bağlantının
    /// kimliğini (`id`) taşır; 0.9.76+ TV her ping'de (ve `link`'te) `GET /ack?c=<id>` gönderir. Bir kez alındı gönderen
    /// bağlantıdan `ackTimeout` boyunca alındı gelmezse bağlantı kopmuş sayılır ve kapatılır (TV sayısı düşer, "Bağlı"
    /// kalkar), `onTVStale` çağrılır; TV kendi tarafında yeniden bağlanır, bekçi uygulamayı yeniden açar. Hiç alındı
    /// göndermeyen eski TV uygulaması eskisi gibi kalır (olayı tanımaz). Bilinmeyen kimliğe 404 döner: TV bağlantısının
    /// sunucuda artık olmadığını anlayıp hemen yeniden bağlanır. Windows ve Android ile aynı.
    ///
    /// #1055 (beta.86): süre saatle ölçülüyordu; ping zamanlayıcısı gecikince (iPhone arka planda askıya alındı, Mac/Windows
    /// zamanlayıcıyı erteledi) ping hiç gitmediği halde sağlam TV "susmuş" sayılıyordu. Artık alındısız geçen ping turları
    /// sayılır (`ackMissLimit`): gitmeyen ping için TV'den alındı beklenmez. `onTVStale` de yalnız TV'den hiç bağlantı
    /// kalmadıysa çağrılır: TV yeni akışını açmışken eski, yarı açık bağlantısının susması bekçiyi yenilemez.
    private let ackTimeout: TimeInterval
    private var linkIds: [String: ObjectIdentifier] = [:]
    /// Alındı göndermiş bağlantının son alındıdan beri geçen ping turu (hiç göndermemiş eski TV burada yok).
    private var ackMisses: [ObjectIdentifier: Int] = [:]
    static func ackTimeout(pingInterval: TimeInterval) -> TimeInterval { pingInterval * Double(ackMissLimit) }
    /// Bu kadar ping turu alındısız geçerse bağlantı kopmuş sayılır.
    static let ackMissLimit = 3

    /// Alındısı kesilen TV bağlantısı kapatıldı (ana iş parçacığında). Çağıran "Yeniden bağlanılıyor" gösterip TV
    /// bekçisini yeniler (uygulama arka plandaysa öne getirilir).
    public var onTVStale: (@Sendable () -> Void)?

    /// TV bağlantısı kopunca uygulamanın "Yeniden bağlanılıyor…" dediği en uzun süre; sonra "TV uygulaması bekleniyor"a
    /// döner (Windows ve Android ile aynı).
    public static let reconnectingFor: Duration = .seconds(60)

    /// Bu kurulumun kalıcı kimliği (`/hello` yanıtında). Aynı ağda iki CouchSubs varken TV uygulaması kendi bilgisayarını
    /// ya da telefonunu adres değişse de bununla tanır; eskiden ağda ilk bulduğuna bağlanıyordu (GitHub #425).
    public let instanceId: String

    public init(port: UInt16 = 8787, pingInterval: TimeInterval = 15, key: String? = nil,
                allowLegacy: Bool = SubtitleAccess.allowLegacyClients, instanceId: String = SubtitleServer.installationId,
                pairing: SubtitlePairing = SubtitlePairing()) {
        requestedPort = port
        self.pairing = pairing
        self.pingInterval = pingInterval
        self.ackTimeout = Self.ackTimeout(pingInterval: pingInterval)
        self.key = key ?? SubtitleAccess.createKey()
        self.allowLegacy = allowLegacy
        self.instanceId = instanceId
    }

    /// Kurulumun kimliği: ilk istekte rastgele üretilir ve ayarlarda saklanır (Mac ve iPhone).
    public static var installationId: String {
        let key = "couchsubs.serverId"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let made = UUID().uuidString.lowercased()
        UserDefaults.standard.set(made, forKey: key)
        return made
    }

    /// `/hello` yanıtı: uygulama, eşleştirme gerektiği (`auth`), kurulum kimliği ve bağlı TV sayısı (Windows ve Android ile
    /// aynı biçim). Erişim anahtarını içermez. TV, ağda birden çok CouchSubs bulursa kayıtlı kimliği, yoksa TV'si bağlı
    /// olmayanı seçer; onayladığı anahtarı da bu kimlikle eşler.
    /// `live`: bu CouchSubs şu an çeviriyor ve altyazıyı TV'ye gönderiyor (1) ya da boşta (0). Aynı ağda iki CouchSubs
    /// (ör. bilgisayar açık bırakılmış, çeviri telefondan) varken TV kayıtlı ama boştaki CouchSubs'a bağlı kalıyor, TV'de
    /// "bağlı" görünüp altyazı hiç gelmiyordu; TV çeviren CouchSubs'ı bununla seçer. Alanı tanımayan eski TV yok sayar.
    static func helloBody(id: String, tvs: Int, live: Bool = false) -> String {
        let escaped = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return #"{"app":"couchsubs","auth":1,"id":""# + escaped + #"","tvs":"# + String(max(0, tvs)) + #","live":"# + (live ? "1" : "0") + "}"
    }

    public var connectedClients: Int {
        queue.sync { clients.count - viewers.count }
    }

    private var reportedPort: Int?

    /// TV uygulamasının gösterdiği HDMI girişi (1-4): altyazı akışına bağlanırken `/events?hdmi=2` ile bildirir. Bağlantı
    /// kopsa da son bildirilen akılda kalır. Bekçi (TVKeeper) PS tuşunun TV'yi konsol girişine geçirmesini kullanıcının
    /// başka girişe geçmesinden bununla ayırır (Windows ve Android ile aynı). Eski TV uygulaması bildirmez: nil.
    public var consolePort: Int? { queue.sync { reportedPort } }

    private var reportedVersion: String?

    /// Sürüm bildirmeyen (0.9.69'den eski) TV bağlantıları. Bunlara `clear` geciktirilerek gider (bkz. `legacyClearHold`).
    private var legacyClients: Set<ObjectIdentifier> = []
    /// Son `subtitle` olayının eski TV'lerde en az görünmesi gereken an (`legacyClearHold`); sayaç her yeni satırda artar.
    private var legacyHoldUntil = Date.distantPast
    private var legacyHoldGeneration = 0

    /// Eski TV uygulamaları (0.9.7'den önce) `clear` gelir gelmez satırı kaldırır. Oyundaki satır ekrandan ~1 sn'de
    /// kalkınca çevirisi TV'de yalnız bir an görünüyordu: "TV'de test et" yazısı (8 sn, `clear` yok) görünüyor, oyun
    /// altyazıları hiç görünmüyordu. Yeni TV uygulaması satırı kendisi `min(5000, 2000 + 60 × harf)` ms tutar
    /// (tv-webos/app.js `holdUntil`); sürüm bildirmeyen bağlantılara `clear` bu süre dolunca gider, arada yeni satır
    /// gelirse hiç gitmez. Yeni TV'lere ve izleyicilere hemen gider. Windows ve Android ile aynı kural.
    static func legacyClearHold(textLength: Int) -> TimeInterval {
        Double(min(5000, 2000 + 60 * max(0, textLength))) / 1000
    }

    /// Bağlanan TV uygulamasının altyazı akışıyla bildirdiği sürüm (`/events?v=0.9.69`). nil: bu çalışmada henüz TV
    /// bağlanmadı. Boş: bağlanan TV sürüm bildirmedi, yani 0.9.69'den eski bir TV uygulaması. LG'de geliştirici modu
    /// kapalıyken ya da anahtar bu cihazda değilken TV'deki sürüm başka yoldan okunamıyor, TV uygulaması eski kalıyor ve
    /// hiç "TV uygulamasını güncelle" çıkmıyordu (GitHub #884, #891). Windows ve Android ile aynı.
    public var tvAppVersion: String? { queue.sync { reportedVersion } }

    /// TV uygulaması altyazı akışına her bağlandığında bildirdiği sürümle (boş: eski TV uygulaması) ana iş parçacığında çağrılır.
    public var onTVAppVersion: (@Sendable (String) -> Void)?

    /// `v` parametresi: yalnız rakam ve nokta, en çok 20 karakter; yoksa ya da bozuksa boş (eski TV sayılır).
    static func tvAppVersion(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 20, value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return "" }
        return value
    }

    /// 0.9.69'den eski TV uygulamaları sürüm bildirmez; ekranda böyle görünür.
    public static let unreportedTVAppVersion = "< 0.9.69"

    /// TV'nin bildirdiği sürüm (boş: sürüm bildirmeyen eski TV uygulaması) bu cihazdaki TV paketinden eski mi?
    public static func isTVAppOutdated(reported: String, bundled: String) -> Bool {
        guard !bundled.isEmpty else { return false }
        return reported.isEmpty || DevModeInstaller.isNewer(bundled, than: reported)
    }

    /// `hdmi` parametresi: 1-4 arası tek rakam, değilse nil.
    static func hdmiPort(_ value: String?) -> Int? {
        guard let value, value.count == 1, let port = Int(value), (1...4).contains(port) else { return nil }
        return port
    }

    /// Dinleyici açık ve bağlantı kabul ediyor. iPhone'da uygulama arka planda askıya alınınca iOS dinleyiciyi
    /// kapatabiliyor; eskiden bu sessiz kalıyor, sunucu "başlamış" sayıldığı için TV bir daha bağlanamıyordu.
    public var isListening: Bool { queue.sync { listening } }
    private var listening = false
    /// Hazır olduktan sonra dinleyici düştü (neden); çağıran `start()` ile yeniden açabilir. Sunucunun kuyruğunda çağrılır.
    public var onListenerFailed: (@Sendable (String) -> Void)?

    /// OBS'de "Tarayıcı kaynağı" olarak eklenen altyazı katmanı (`GET /obs`).
    public static let obsOverlay: Data = {
        guard let url = Bundle.module.url(forResource: "obs-overlay", withExtension: "html"),
              let data = try? Data(contentsOf: url) else { return Data() }
        return data
    }()

    /// Sunucuyu başlatır ve dinlenen portu döner (`port: 0` ise rastgele seçilen port).
    ///
    /// Sabit portta "Address already in use" gelirse kısa aralıklarla yeniden denenir: az önce kapatılan dinleyici portu
    /// birkaç milisaniye sonra bırakır. Eskiden `stop()` ardından `start()` hep bu hatayı veriyor, çağıran rastgele bir
    /// porta düşüyordu; ağı yalnız 8787'de tarayan TV uygulaması (Android TV) telefonu bir daha bulamıyordu.
    public func start() async throws -> UInt16 {
        var attempt = 0
        while true {
            do {
                return try await startOnce()
            } catch PortBusy.busy(let reason) {
                attempt += 1
                guard requestedPort != 0, attempt < Self.busyRetries else { throw ServerError.failedToStart(reason) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private enum PortBusy: Error { case busy(String) }
    static let busyRetries = 10

    private func startOnce() async throws -> UInt16 {
        let port: NWEndpoint.Port = requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        // Sessizce kaybolan TV'ler (fişten çekme, Wi-Fi kopması) TCP canlılık denetimiyle fark edilir.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        // Altyazı çerçeveleri küçüktür; Nagle beklemesi her satırı TV'ye geç ulaştırmasın.
        tcp.noDelay = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            // Durum değişiklikleri seri kuyrukta gelir; devamı yalnız bir kez çağırmak için saklanır.
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                guard let continuation = self.startContinuation else {
                    // Açıldıktan sonra düşen dinleyici (stop() ile kapatılan .cancelled olur, o sayılmaz).
                    if case .failed(let error) = state, self.listener === listener {
                        self.listening = false
                        self.pingTimer?.cancel()
                        self.regionTimer?.cancel()
                        self.pingTimer = nil
                        listener.cancel()
                        self.onListenerFailed?(error.localizedDescription)
                    }
                    return
                }
                switch state {
                case .ready:
                    self.startContinuation = nil
                    self.listening = true
                    self.pingTimer?.cancel()
                    self.regionTimer?.cancel()
                    self.startPing()
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    // .waiting: port ya da ağ şu an kullanılamıyor; beklemek yerine hata ver ki çağıran başka port denesin.
                    self.startContinuation = nil
                    listener.cancel()
                    if case .posix(.EADDRINUSE) = error {
                        continuation.resume(throwing: PortBusy.busy(error.localizedDescription))
                    } else {
                        continuation.resume(throwing: ServerError.failedToStart(error.localizedDescription))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private var startContinuation: CheckedContinuation<UInt16, Error>?

    /// `keepPairing`: sunucu hemen yeniden açılacaksa (dinleyici düştü, port geri alınıyor) eşleştirme durumu korunur.
    /// Eskiden her kapanış onay bekleyen isteği ve "TV eşleştir" süresini siliyordu: TV'de kod beklerken sunucu yeniden
    /// açılınca TV "Eşleştirme tamamlanmadı" diyor, telefondaki pencere artık geçersiz isteği gösteriyordu.
    public func stop(keepPairing: Bool = false) {
        if !keepPairing { pairing.setSession(false) }
        queue.sync {
            listening = false
            pingTimer?.cancel()
            regionTimer?.cancel()
            pingTimer = nil
            listener?.cancel()
            listener = nil
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
            viewers.removeAll()
            legacyClients.removeAll()
            linkIds.removeAll()
            ackMisses.removeAll()
            if !keepPairing { liveRegions.removeAll() }
        }
    }

    /// `box`: oyundaki İngilizce altyazının ekrandaki yeri (kenarlara oranla); TV çeviriyi buna göre yerleştirir.
    /// `replaces`: çeviri, az önce gösterilen satırın uzamış ya da düzelmiş bir okumasından gelir (`TextMatch.isRevision`);
    /// TV onu öncekinin üstüne yığmaz, yerine koyar (`replace` alanı; eski TV uygulamaları yok sayar).
    /// `paragraphs`: çok parçalı yazı (görev paneli: başlık, maddeler); TV satır satır, sola yaslı gösterir (Windows ile aynı).
    public func sendSubtitle(_ text: String, durationMs: Int = 15000, box: TextBox? = nil, replaces: Bool = false) {
        sendSubtitle(text, durationMs: durationMs, box: box, replaces: replaces, paragraphs: false)
    }

    public func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool = false, paragraphs: Bool) {
        let at = Int(Date().timeIntervalSince1970 * 1000)
        var json: [String: Any] = ["text": text, "duration": durationMs, "at": at]
        if let box { json["box"] = Self.json(box) }
        if paragraphs { json["paragraphs"] = true }
        if replaces { json["replace"] = true }
        if speakerColors {
            let speakers = SpeakerColors.speakers(in: text, book: speakerBook)
            if !speakers.isEmpty { json["speakerNames"] = speakers.map { ["name": $0.name, "color": $0.color] } }
        }
        broadcast(event: "subtitle", json: json)
        onEvent?(.subtitle(text: text, durationMs: durationMs, paragraphs: paragraphs, replaces: replaces, box: box))
    }

    /// Dört basamağa yuvarlanır; Decimal, JSON'da 0.80000000000000004 yerine 0.8 yazılsın diye.
    static func json(_ box: TextBox) -> [String: Decimal] {
        let round = unitNumber
        return ["left": round(box.left), "top": round(box.top), "right": round(box.right), "bottom": round(box.bottom)]
    }

    /// Yeriyle bir çeviri ("Ekranı çevir" öğesi ya da ek alan bloğu).
    static func json(_ item: ScreenTranslation.Item, phone: Bool = false) -> [String: Any] {
        let line = unitNumber(item.lineHeight)
        var result: [String: Any] = ["box": Self.json(item.box), "line": line, "text": item.translation]
        if item.paragraphs { result["paragraphs"] = true }
        // Yerleşim (`ScreenFit`): kutunun genişleyebileceği alan ve özgün satır sayısı (eski TV yok sayar).
        if let room = item.room { result["room"] = Self.json(room) }
        if item.rows > 1 { result["rows"] = item.rows }
        if phone || item.look != nil, let style = item.style, isRGB(style.background), isRGB(style.foreground) {
            var surface: [String: Any] = ["background": style.background, "foreground": style.foreground]
            if let look = item.look { surface["flat"] = look.flat }
            result["surface"] = surface
        }
        // Otomatik ekran yazısı: özgün yazının görünüşü (eski TV yok sayar).
        if let look = item.look {
            result["style"] = ["align": look.align.rawValue, "bold": look.bold, "condensed": look.condensed, "upper": look.upper]
        }
        if let icons = item.icons, !icons.isEmpty { result["icons"] = Self.json(icons) }
        // Yerinde birebir çizim (`TextPaint`; eski TV yok sayar): opak kutu tam örtü sınırında, ölçülen zeminle (degrade
        // dahil), yazı özgün renk, kalınlık, büyük harf, hiza ve satır aralığıyla; grup aynı boyda, boş alana uzayabilir.
        if let paint = item.paint, let look = item.look, let style = item.style, isRGB(paint.background), isRGB(style.foreground) {
            result["bg"] = paint.background
            if let second = paint.background2, isRGB(second), let direction = paint.direction {
                result["bg2"] = second
                result["bgDir"] = direction.rawValue
            }
            if paint.patterned { result["bgPat"] = true }
            result["fg"] = style.foreground
            result["weight"] = look.bold ? 700 : 400
            result["upper"] = look.upper
            result["align"] = look.align.rawValue
            result["lineH"] = Decimal(Int((max(0, min(1, paint.pitch)) * 10000).rounded())) / 10000
            result["cover"] = Self.json(paint.cover)
            if let grow = paint.grow { result["grow"] = Self.json(grow) }
            if let group = paint.group { result["group"] = group }
            // Çizim kipi (`TextPaint.mode`; TV uygulaması 0.9.108): yanına yazma ya da ikiz panel. Eski TV alanları yok sayıp
            // yukarıdaki örtüyle çizer.
            if paint.mode != .cover, let spot = paint.spot, let room = paint.spotRoom {
                result["mode"] = paint.mode.rawValue
                result["spot"] = Self.json(spot)
                result["spotRoom"] = Self.json(room)
                if paint.mode == .twin, let twin = paint.twin {
                    result["twinBox"] = Self.json(twin)
                    result["radius"] = unitNumber(paint.radius)
                    result["scale"] = unitNumber(paint.scale)
                    if let tail = paint.tail { result["tail"] = tail }
                    // Kenar çizgisi (TV uygulaması 0.9.109; eski TV yok sayar).
                    if let edge = paint.edge, isRGB(edge.color) {
                        result["edge"] = ["color": edge.color, "top": unitNumber(edge.top), "right": unitNumber(edge.right),
                                          "bottom": unitNumber(edge.bottom), "left": unitNumber(edge.left)] as [String: Any]
                    }
                    if let image = paint.portraitImage, let at = paint.portraitTwin {
                        result["icon"] = ["src": image, "box": Self.json(at)] as [String: Any]
                    }
                }
            }
        }
        // Telefon mesajı kendi balonunda: TV çeviriyi balona sığdırır (eski TV yok sayar, özgün stilde çizer).
        if item.bubble { result["bubble"] = true }
        // Telefonun yanındaki sohbet panelinin parçası: yeni TV paneli akışla, yuvarlak köşeli yarı saydam kartta çizer;
        // eski TV alanı yok sayar, öğeyi stilli kutu olarak yerinde çizer.
        if let panel = item.panel { result["panel"] = panel.rawValue }
        // Hizalı panel (TV uygulaması 0.9.106): parçalar kutularının yerinde, zeminsiz; eski TV akışla çizer.
        if item.aligned { result["aligned"] = true }
        // Liste kartı (TV uygulaması 0.9.110): avatar, kalın ad, önizleme, rozet, seçim çerçevesi. Eski TV yok sayar,
        // `text`'i (ad ve önizleme iki satır) yerinde çizer.
        if let row = item.listRow { result["row"] = Self.json(row) }
        return result
    }

    static func json(_ row: ScreenPhoneCard.ListRow) -> [String: Any] {
        var result: [String: Any] = ["name": row.name, "preview": row.preview]
        if let avatar = row.avatar { result["avatar"] = avatar }
        if let badge = row.badge { result["badge"] = badge }
        if let selected = row.selected, isRGB(selected) { result["selected"] = selected }
        if row.widget { result["widget"] = true }
        return result
    }

    private static func isRGB(_ color: String) -> Bool {
        color.utf8.count == 7 && color.first == "#" && color.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func json(_ icons: [IconPlacement]) -> [[String: Any]] {
        icons.map { icon -> [String: Any] in ["at": icon.at, "src": icon.image] }
    }

    public func clear() {
        broadcast(event: "clear", json: [:])
        onEvent?(.clear)
    }

    /// TV uygulamasını kapatır; çeviri durduğunda TV kendi girişine (HDMI) döner (#268, Windows ile aynı). Yalnız
    /// TV'lere gider, OBS gibi izleyicilere gitmez. `completion`, mesaj bütün TV'lere yazılınca (ya da yazılamayınca)
    /// sunucunun kuyruğunda çağrılır; kapanışta sunucu durdurulmadan önce kısa süre beklenebilir.
    public func exitTVApp(completion: (@Sendable () -> Void)? = nil) {
        let data = Data(Self.frame(event: "exit", json: [:]).utf8)
        queue.async {
            let group = DispatchGroup()
            for (id, connection) in self.clients where !self.viewers.contains(id) {
                group.enter()
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let self, error != nil { self.drop(connection, id: id) }
                    group.leave()
                })
            }
            group.notify(queue: self.queue) { completion?() }
        }
    }

    /// "Ekranı çevir" sonuçları: `screen` olayı her çeviriyi yazının yeri (`box`), tipik satır yüksekliği (`line`,
    /// ekrana oranla) ve çok parçalıysa `paragraphs` ile taşır. TV öncekinin yerine bunları koyar. Çevirinin içinde
    /// kumanda simgeleri varsa `icons` her simgenin düz metindeki yerini (`at`) ve PNG'sini (`src`) taşır; eski TV
    /// uygulamaları alanı yok sayıp düz metni gösterir (Windows ile aynı).
    public func sendScreen(_ items: [ScreenTranslation.Item], durationMs: Int) {
        let items = steadied(items.filter { Self.area($0.box) <= Self.maxBoxArea })
        let shown: [ScreenTranslation.Item] = screenStyleGuard.withLock {
            screenEpoch += 1
            screenShown = (items, Self.uptimeMs() + durationMs)
            screenVisible = items.map { !presence.hidden($0) }
            return items.filter { !presence.hidden($0) }
        }
        emitScreen(shown, durationMs: durationMs)
    }

    private func emitScreen(_ items: [ScreenTranslation.Item], durationMs: Int) {
        broadcast(event: "screen", json: ["duration": durationMs, "items": items.map { Self.json($0) }])
        // Altyazı yalnız bilgisayardaysa (TV yok) çeviriler başka hiçbir yere gitmiyordu: tuşa basınca yalnız
        // "Ekran çevriliyor…" görünüyordu.
        // Telefon kartının zemini (`ScreenPhoneCard.backdropText`) düz metne girmez.
        let text = items.filter { !ScreenPhoneCard.isBackdrop($0) }.map(\.translation).joined(separator: "\n")
        onEvent?(.screen(text: text, durationMs: durationMs, items: items))
    }

    /// Ek alanın çevirisi: `region` olayı alanın kimliğini (`id`), çeviriyi (`text`; boşsa kutu kalkar), yazının karedeki
    /// yerini (`box`) ve satır yüksekliğini (`line`, ekrana oranla) taşır. TV çeviriyi o yerde küçük bir kutuda gösterir;
    /// ana altyazıya dokunmaz. Olayı tanımayan eski TV uygulamaları yok sayar.
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double? = nil) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: nil)
    }

    /// `icons`: çevirinin içindeki kumanda simgeleri; `icons` alanı her simgenin düz metindeki yerini (`at`) ve PNG'sini
    /// (`src`) taşır. Eski TV uygulamaları alanı yok sayıp düz metni gösterir.
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: nil)
    }

    /// `blocks`: alanda ayrı duran yazı gruplarının çevirileri kendi yerleriyle (`blocks`; her biri `screen` olayındaki
    /// öğe gibi `box`, `line`, `text`). TV her birini kendi İngilizce yazısının üstüne koyar. Alanı tanımayan eski TV
    /// uygulamaları birleşik `text`'i tek kutuda gösterir (Windows ile aynı).
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: blocks, anchor: nil)
    }

    /// `anchor`: telefona yapışık çeviri (deneysel, önce Mac). Bloklar bu çapa kuşağının başvuru koordinatındadır;
    /// `region` olayı `anchor: {gen, ref}` taşır, yer her karede `anchor` olayıyla gelir (`sendAnchor`). Alanı tanımayan
    /// TV blokları başvuru yerinde (çapanın kurulduğu okumadaki telefonun yerinde) gösterir.
    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?, anchor: AnchorPose?) {
        var (text, blocks) = Self.guarded(text: text, box: box, blocks: blocks)
        if id != "game-phone", let shown = blocks { blocks = steadied(shown) }
        if id != "game-phone" {
            let sent = (text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: blocks)
            let visible: [ScreenTranslation.Item]? = screenStyleGuard.withLock {
                regionShown[id] = text.isEmpty || (blocks ?? []).isEmpty ? nil : sent
                regionVisible[id] = regionShown[id] == nil ? nil : blocks?.map { !presence.hidden($0) }
                return blocks?.filter { !presence.hidden($0) }
            }
            if let all = blocks, let visible, visible.count != all.count {
                emitRegion(id: id, text: visible.isEmpty ? "" : text, box: box, lineHeight: lineHeight, icons: icons, blocks: visible)
                return
            }
        }
        emitRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: blocks, anchor: anchor)
    }

    private func emitRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                            blocks: [ScreenTranslation.Item]?, anchor: AnchorPose? = nil) {
        var json: [String: Any] = ["id": id, "text": text]
        if let anchor, !text.isEmpty {
            json["anchor"] = ["gen": anchor.generation,
                              "ref": Self.json(TextBox(left: anchor.reference.left, top: anchor.reference.top,
                                                       right: anchor.reference.right, bottom: anchor.reference.bottom))]
        }
        if let icons, !icons.isEmpty { json["icons"] = Self.json(icons) }
        if let blocks, !blocks.isEmpty, !text.isEmpty { json["blocks"] = blocks.map { Self.json($0, phone: id == "game-phone") } }
        if let box { json["box"] = Self.json(box) }
        if let lineHeight { json["line"] = Self.unitNumber(lineHeight) }
        broadcast(event: "region", json: json)
        if id == "game-phone" { onEvent?(.gamePhone(text.isEmpty ? [] : blocks ?? [])) }
        else if let blocks, !blocks.isEmpty, !text.isEmpty, blocks.contains(where: { $0.look != nil }) {
            onEvent?(.screenText(id: id, items: blocks))
        } else { onEvent?(.region(id: id, text: text, box: box)) }
    }

    /// Ekran yazısı çevirilerinin görünüşü oturum boyunca kilitli (`ScreenStyleLock`); "Ekranı çevir" ve otomatik ekran
    /// yazısı aynı kilidi paylaşır (Windows: SubtitleServer.Steadied, Android: SubtitleServer.steadied).
    private let screenStyleGuard = NSLock()
    private var screenStyle = ScreenStyleLock()
    /// Ekrandaki çeviriler ve özgün yazılarının takibi (`ScreenPresence`): yazı kalkınca çevirisi de aynı karede kalkar.
    private var presence = ScreenPresence()
    /// `ScreenPresence`'ın kaldırma ve geri getirme kararları altyazı günlüğüne (`DropLog`; sınırlı, tekrarsız).
    private let presenceDrops = DropLog()
    private var screenShown: (items: [ScreenTranslation.Item], until: Int)?
    /// Her `sendScreen` ve `clearScreen` bir üst numara verir. `observe` değişikliği kilidin dışında gönderir; arada çeviri
    /// kaldırıldıysa eski öğeler yeniden gönderilmez (kaldırılan çeviri TV'de geri çiziliyordu, #1182).
    private var screenEpoch = 0
    private var screenVisible: [Bool] = []
    private var regionShown: [String: (text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                                       blocks: [ScreenTranslation.Item]?)] = [:]
    private var regionVisible: [String: [Bool]] = [:]

    static func uptimeMs() -> Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }

    /// Her karede çağrılır: çevirisi gösterilen yazılar hâlâ yerinde mi (`ScreenPresence`). Özgün yazısı kalkan öğe TV'den
    /// ve masaüstünden aynı karede kalkar; geri gelirse yeniden gösterilir. Windows: SubtitleServer.Observe, Android:
    /// SubtitleServer.observe.
    public func observe(_ frame: CGImage) {
        observe { box in ScreenPresence.patch(frame, box: box) }
    }

    func observe(patch: (TextBox) -> [Int]?) {
        let now = Self.uptimeMs()
        screenStyleGuard.lock()
        let epoch = screenEpoch
        if let shown = screenShown, shown.until <= now { screenShown = nil }
        let screen = screenShown?.items ?? []
        let regions = regionShown.sorted { $0.key < $1.key }
        let all = screen + regions.flatMap { $0.value.blocks ?? [] }
        guard all.contains(where: ScreenPresence.tracks) || !screenVisible.isEmpty || !regionVisible.isEmpty else {
            screenStyleGuard.unlock()
            return
        }
        let visible = presence.visible(all, patch: patch)
        var screenChange: [ScreenTranslation.Item]?
        let screenFlags = Array(visible.prefix(screen.count))
        let screenBefore = screenVisible.isEmpty ? screen.map { _ in true } : screenVisible
        if screenFlags != screenBefore, !screen.isEmpty {
            screenChange = zip(screen, screenFlags).filter(\.1).map(\.0)
        }
        // Kaldırma ya da geri getirme kararı günlüğe (`DropLog`): periyodik kopmalarda hangi yazının izinin kaçtığı görünsün.
        var flips: [(source: String, visible: Bool)] = []
        for (index, item) in screen.enumerated() where index < screenBefore.count && screenBefore[index] != screenFlags[index] {
            flips.append((item.source, screenFlags[index]))
        }
        screenVisible = screen.isEmpty ? [] : screenFlags
        var regionChanges: [(String, String, TextBox?, Double?, [IconPlacement]?, [ScreenTranslation.Item])] = []
        var offset = screen.count
        var flagsById: [String: [Bool]] = [:]
        for (id, sent) in regions {
            let blocks = sent.blocks ?? []
            let flags = Array(visible[offset..<(offset + blocks.count)])
            offset += blocks.count
            flagsById[id] = flags
            let before = regionVisible[id] ?? blocks.map { _ in true }
            for (index, block) in blocks.enumerated() where index < before.count && before[index] != flags[index] {
                flips.append((block.source, flags[index]))
            }
            if flags != before {
                let kept = zip(blocks, flags).filter(\.1).map(\.0)
                regionChanges.append((id, kept.isEmpty ? "" : sent.text, sent.box, sent.lineHeight, sent.icons, kept))
            }
        }
        regionVisible = flagsById
        let until = screenShown?.until ?? now
        screenStyleGuard.unlock()
        for flip in flips {
            presenceDrops.note("ScreenPresence", flip.visible ? "özgün yazı geri geldi, çeviri yeniden gösterildi"
                               : "özgün yazının izi kaçtı, çeviri kaldırıldı", flip.source)
        }
        if let screenChange, screenStyleGuard.withLock({ screenEpoch == epoch }) {
            emitScreen(screenChange, durationMs: max(1, until - now))
        }
        for change in regionChanges {
            emitRegion(id: change.0, text: change.1, box: change.2, lineHeight: change.3, icons: change.4,
                       blocks: change.5.isEmpty ? nil : change.5)
        }
    }

    func steadied(_ items: [ScreenTranslation.Item]) -> [ScreenTranslation.Item] {
        let now = Int(ProcessInfo.processInfo.systemUptime * 1000)
        screenStyleGuard.lock()
        defer { screenStyleGuard.unlock() }
        return screenStyle.steady(items, now: now)
    }

    /// Ekranı çevir'in yerleşimi yeniden ölçülsün (oturum yeniden başladı).
    public func resetScreenStyle() {
        screenStyleGuard.lock()
        screenStyle.reset()
        presence.reset()
        screenStyleGuard.unlock()
    }

    /// Ekranın bu oranından büyük çeviri kutusu gönderilmez. TV ve OBS kutuyu opak zeminle çizer; yanlış bir algılamanın
    /// (oyun telefonu, otomatik ekran yazısı) ekranın büyük kısmını kaplayan kutusu oyun görüntüsünü kapatıyordu
    /// (LG'de "siyah ekran, ses var"). Windows: SubtitleServer.MaxBoxArea, Android: SubtitleServer.MAX_BOX_AREA.
    public static let maxBoxArea = 0.4

    static func area(_ box: TextBox) -> Double { max(0, box.right - box.left) * max(0, box.bottom - box.top) }

    /// Büyük kutu koruması: alanı `maxBoxArea`'dan büyük bloklar atılır; blokların toplamı da sınırı aşıyorsa ya da
    /// bloksuz alanın kutusu sınırdan büyükse alan boş gönderilir (TV kutuyu kaldırır).
    static func guarded(text: String, box: TextBox?, blocks: [ScreenTranslation.Item]?) -> (String, [ScreenTranslation.Item]?) {
        guard !text.isEmpty else { return (text, blocks) }
        var blocks = blocks
        if let all = blocks, !all.isEmpty {
            let kept = all.filter { area($0.box) <= maxBoxArea }
            // Sohbet panelinin balonları panelin zemininin içindedir: toplam alana bir kez (zemin olarak) girer.
            let inside: Set<ScreenPhoneCard.PanelPart> = [.title, .theirs, .mine, .note, .row]
            if kept.filter({ $0.panel.map { !inside.contains($0) } ?? true }).reduce(0, { $0 + area($1.box) }) > maxBoxArea {
                return ("", nil)
            }
            if !kept.isEmpty { return (text, kept) }
            blocks = nil
        }
        if let box, area(box) > maxBoxArea { return ("", nil) }
        return (text, blocks)
    }

    /// Bütün ek alan kutularını kaldırır.
    /// Telefona yapışık çevirinin yeri (deneysel, önce Mac; docs/ekran-capasi.md "Sunucu olayı"). Çapa kıpırdadıkça
    /// (ölü bölgeyi aşan her karede) `anchor` olayı: `{"gen": kuşak, "m": [a, b, c, d, dx, dy, g, h]}`; dönüşüm kareye
    /// oranlı, merkezi `region` olayındaki `anchor.ref` dörtgeninin ortası. Kaybolunca `{"gen": kuşak, "lost": true}`:
    /// o kuşağın balon çevirileri hemen gizlenir. Olayı tanımayan TV yok sayar. Son olay yeni bağlanan TV'ye bölgelerden
    /// sonra yinelenir.
    /// Sonlu olmayan (NaN, sonsuz) dönüşüm gönderilmez: TV son geçerli yerde kalır.
    public func sendAnchor(_ change: PhoneAnchorSession.Change) {
        if case .moved(let pose) = change, !Self.isFinite(pose.motion) { return }
        broadcast(event: "anchor", json: Self.json(change))
    }

    static func isFinite(_ m: ScreenAnchor.Motion) -> Bool {
        [m.a, m.b, m.c, m.d, m.dx, m.dy, m.g, m.h].allSatisfy(\.isFinite)
    }

    /// Çapa dönüşümünün bir sayısı, altı basamağa yuvarlanmış. NaN ya da sonsuz 0 olur, çok büyük değer ±1e6'ya kırpılır:
    /// eskiden `Int(...)` NaN, sonsuz ya da ~9e12'den büyük değerde uygulamayı çökertiyordu (yalnız deneysel "yerinde çizim").
    static func anchorNumber(_ value: Double) -> Decimal {
        guard value.isFinite else { return 0 }
        let clamped = max(-1_000_000, min(1_000_000, value))
        return Decimal(Int((clamped * 1_000_000).rounded())) / 1_000_000
    }

    /// Ekrana oranlı değer [0, 1]'e kırpılmış, dört basamağa yuvarlanmış. NaN 0 olur (Windows ve Android ile aynı; Windows'ta
    /// decimal'e, Android'de BigDecimal'e çevirirken çöküyordu).
    static func unitNumber(_ value: Double) -> Decimal {
        Decimal(Int((max(0, min(1, value.isNaN ? 0 : value)) * 10000).rounded())) / 10000
    }

    static func json(_ change: PhoneAnchorSession.Change) -> [String: Any] {
        let rounded = anchorNumber
        switch change {
        case .moved(let pose):
            let m = pose.motion
            return ["gen": pose.generation, "m": [m.a, m.b, m.c, m.d, m.dx, m.dy, m.g, m.h].map(rounded)]
        case .lost(let generation, _):
            return ["gen": generation, "lost": true]
        }
    }

    public func clearRegions() {
        screenStyleGuard.withLock {
            regionShown = [:]
            regionVisible = [:]
        }
        broadcast(event: "region-clear", json: [:])
        onEvent?(.regionClear)
    }

    /// TV'deki "ekranı çevir" çevirilerini kaldırır (altyazıya dokunmaz).
    public func clearScreen() {
        screenStyleGuard.withLock {
            screenEpoch += 1
            screenShown = nil
            screenVisible = []
        }
        broadcast(event: "screen-clear", json: [:])
        onEvent?(.screenClear)
    }

    /// Dosyayı `path` adresinden verir ("/voices/male_1.wav").
    public func publish(_ data: Data, at path: String, type: String = "audio/wav") {
        queue.async { self.files[path] = (data, type) }
    }

    /// Dublaj sesini TV'ye gönderir: ses `/speech/<n>.wav` adresinden verilir, `speech` olayı adresi bildirir.
    /// Son 16 ses tutulur; TV kopup bağlanınca eskisini istemez.
    public func sendSpeech(_ wav: Data, durationMs: Int) {
        queue.async {
            self.speechNumber += 1
            let path = "/speech/\(self.speechNumber).wav"
            self.files[path] = (wav, "audio/wav")
            self.speechPaths.append(path)
            while self.speechPaths.count > 16 { self.files[self.speechPaths.removeFirst()] = nil }
            self.sendToAll(Data(Self.frame(event: "speech", json: ["url": path, "duration": durationMs]).utf8))
        }
    }

    /// TV'de çalan dublajı durdurur (yeni sahne, oturum sonu).
    public func stopSpeech() {
        broadcast(event: "speech-stop", json: [:])
    }

    public func sendStyle(_ style: SubtitleStyle) {
        queue.async { self.lastStyle = style }
        speakerBook.configure(fixed: style.nameColorMode == .single ? style.nameHex : nil,
                              overrides: style.nameColorMode.perCharacter ? style.characterColors : [:])
        var json = style.json
        json["setApart"] = setApart
        broadcast(event: "style", json: json)
    }

    // MARK: - Bağlantılar

    private func accept(_ connection: NWConnection) {
        guard case let .hostPort(host, _) = connection.endpoint, SubtitleAccess.isLocalPeer("\(host)") else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.route(connection, requestLine: head)
            } else if isComplete || error != nil || buffer.count > 65536 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, requestLine: String) {
        guard let request = SubtitleAccess.parse(requestLine) else {
            respondAndClose(connection, status: "400 Bad Request")
            return
        }
        let access = SubtitleAccess.authorize(request, key: key, allowLegacy: allowLegacy)
        let cors = SubtitleAccess.cors(request)
        guard access.status == 200 else {
            if access.status == 403, let line = rejectedOrigins.line(request) { SubtitleLog.write(line) }
            respondAndClose(connection, status: access.status == 403 ? "403 Forbidden" : "401 Unauthorized", cors: access.status == 403 ? "" : cors)
            return
        }
        let path = request.path
        let method = request.method

        if path == "/pair" {
            if method == "POST" {
                var peer = ""
                if case let .hostPort(host, _) = connection.endpoint { peer = SubtitleAccess.tvHost(fromPeer: "\(host)") }
                guard let ticket = pairing.begin(host: peer) else { respondAndClose(connection, status: "409 Conflict", cors: cors); return }
                if let handler = onPairingRequest { DispatchQueue.main.async { handler(ticket) } }
                let data = try! JSONSerialization.data(withJSONObject: ["id": ticket.id, "code": ticket.code])
                respondAndClose(connection, status: "200 OK", data: data, type: "application/json", cors: cors)
            } else if method == "GET" {
                let state: String
                if request.parameter("validate") == "1" {
                    let supplied = request.parameter("k") ?? ""
                    let check = SubtitleAccess.Request(method: "GET", target: "/events?k=\(supplied.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")", origin: request.origin, host: request.host)
                    state = SubtitleAccess.authorize(check, key: key, allowLegacy: false).status == 200 ? "valid" : "expired"
                } else { state = pairing.poll(request.parameter("id") ?? "") }
                var result: [String: Any] = ["state": state]
                if state == "approved" { result["key"] = key }
                // Eski TV uygulamaları `rejected`'ı tanımaz: `expired` görüp durur. Yenisi `rejected` ile Tamam bekler, yalnız
                // `expired`'da kendisi yeniden ister (GitHub #737).
                if state == "rejected" { result = ["state": "expired", "rejected": true] }
                respondAndClose(connection, status: "200 OK", data: try! JSONSerialization.data(withJSONObject: result), type: "application/json", cors: cors)
            } else { respondAndClose(connection, status: "405 Method Not Allowed", cors: cors) }
            return
        }
        if method == "OPTIONS" {
            // Chromium'un yerel ağ erişimi denetimi (Private Network Access) ön istekte bu başlıkları ister; yeni
            // tarayıcılı TV'ler (Tizen 9.0 ve sonrası) başlık olmadan bilgisayara bağlanmayabilir. Eski TV'ler yok sayar.
            respondAndClose(connection, status: "204 No Content", data: Data(), type: nil, cors: cors + Self.preflightHeaders)
        } else if method == "GET" && path == "/events" {
            // OBS katmanı ve ikinci ekran sayfası izleyicidir: TV sayılmaz, altyazı hedefi TV değilken de olayları alır.
            let obs = request.parameter("viewer") == "obs" || request.parameter("viewer") == SecondScreen.viewer
            // Anahtarsız OBS sayfası eski bir OBS adresidir; TV uygulamasının eski olduğu anlamına gelmez.
            if access.legacy && !obs && !legacySeen {
                legacySeen = true
                if let handler = onLegacyClient { DispatchQueue.main.async { handler() } }
            }
            if !obs, let port = Self.hdmiPort(request.parameter("hdmi")) { reportedPort = port }
            var unreported = false
            if !obs {
                let version = Self.tvAppVersion(request.parameter("v"))
                reportedVersion = version
                unreported = version.isEmpty
                if let handler = onTVAppVersion { DispatchQueue.main.async { handler(version) } }
            }
            openStream(connection, viewer: obs, legacy: unreported, cors: cors)
        } else if method == "GET" && path == "/ack" {
            // TV'nin alındısı (bkz. ackTimeout). Bilinmeyen kimlik: sunucuda bu bağlantı yok, TV yeniden bağlanmalı.
            if let id = linkIds[request.parameter("c") ?? ""], clients[id] != nil {
                ackMisses[id] = 0
                respondAndClose(connection, status: "204 No Content", data: Data(), type: nil, cors: cors)
            } else {
                respondAndClose(connection, status: "404 Not Found", cors: cors)
            }
        } else if method == "GET" && path == "/obs" {
            respondAndClose(connection, status: "200 OK", data: Self.obsOverlay, type: "text/html; charset=utf-8", cors: cors)
        } else if method == "GET" && path == SecondScreen.path {
            // Anahtar `authorize`'da denetlendi (anahtarsız istek 401 aldı).
            respondAndClose(connection, status: "200 OK", data: SecondScreen.page, type: "text/html; charset=utf-8", cors: cors)
        } else if method == "GET" && path == "/hello" {
            // TV uygulaması ağdaki bilgisayarı bu yanıtla tanır (bağlantı kuyruğunda: sayaçlar doğrudan okunur).
            respondAndClose(connection, status: "200 OK", body: Self.helloBody(id: instanceId, tvs: clients.count - viewers.count,
                                                                                   live: tvEnabled && pairing.inSession), cors: cors)
        } else if method == "GET", let file = files[path] {
            respondAndClose(connection, status: "200 OK", data: file.data, type: file.type, cors: cors)
        } else {
            respondAndClose(connection, status: "404 Not Found", cors: cors)
        }
    }

    private func respondAndClose(_ connection: NWConnection, status: String, body: String = "", cors: String = "") {
        respondAndClose(connection, status: status, data: Data(body.utf8), type: nil, cors: cors)
    }

    static let preflightHeaders = "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n"
        + "Access-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 600\r\n"

    private func respondAndClose(_ connection: NWConnection, status: String, data: Data, type: String?, cors: String = "") {
        var head = "HTTP/1.1 \(status)\r\n\(cors)Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        head += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func openStream(_ connection: NWConnection, viewer: Bool = false, legacy: Bool = false, cors: String = "") {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n"
        head += cors + "\r\n"
        head += "retry: 2000\n\n"
        if let style = lastStyle {
            var json = style.json
            json["setApart"] = apart
            head += Self.frame(event: "style", json: json)
        }
        // Bağlantının kimliği (bkz. ackTimeout); stilden sonra: ilk olay eskisi gibi stil.
        let id = ObjectIdentifier(connection)
        if !viewer {
            let link = Self.makeLinkId()
            linkIds[link] = id
            var json: [String: Any] = ["id": link]
            if let latest = latestVersion, !Self.tvAppVersion(latest).isEmpty { json["latest"] = latest }
            head += Self.frame(event: "link", json: json)
        }
        head += regionReplay(tv: viewer || tvEnabled)
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        clients[id] = connection
        if viewer { viewers.insert(id) }
        if legacy { legacyClients.insert(id) }
        notifyClientsChanged()
        watchForClose(connection, id: id)
    }

    /// İstemci bağlantıyı kapattığında listeden çıkarır.
    private func watchForClose(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.drop(connection, id: id)
            } else {
                self.watchForClose(connection, id: id)
            }
        }
    }

    /// Bağlantıyı kapatır ve listelerden çıkarır (sunucunun kuyruğunda).
    private func drop(_ connection: NWConnection, id: ObjectIdentifier) {
        connection.cancel()
        viewers.remove(id)
        legacyClients.remove(id)
        ackMisses[id] = nil
        linkIds = linkIds.filter { $0.value != id }
        if clients.removeValue(forKey: id) != nil { notifyClientsChanged() }
    }

    /// Bir ping turu: son alındıdan beri `ackMissLimit` turdan fazla geçmiş TV bağlantılarını kapatır; kapattıysa true
    /// (ping gönderilmeden hemen önce, sunucunun kuyruğunda). `onTVStale` yalnız TV'den hiç bağlantı kalmadıysa çağrılır.
    @discardableResult
    func dropSilentTVs() -> Bool {
        var silent: [ObjectIdentifier] = []
        for (id, misses) in ackMisses {
            if misses + 1 > Self.ackMissLimit { silent.append(id) } else { ackMisses[id] = misses + 1 }
        }
        for id in silent {
            if let connection = clients[id] { drop(connection, id: id) } else { ackMisses[id] = nil }
        }
        guard !silent.isEmpty else { return false }
        let remaining = clients.count - viewers.count
        SubtitleLog.write("TV \(Self.ackMissLimit) ping turu alındı göndermedi: bağlantı kopmuş sayıldı, kapatıldı"
                          + (remaining > 0 ? " (TV'nin başka bağlantısı açık, bekçiye dokunulmadı)" : ""))
        if remaining == 0, let handler = onTVStale { DispatchQueue.main.async { handler() } }
        return true
    }

    /// `link` olayındaki bağlantı kimliği: tahmin edilemez, URL'de kaçışsız gider.
    static func makeLinkId() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<16).map { _ in letters.randomElement()! })
    }

    private func notifyClientsChanged() {
        let count = clients.count - viewers.count
        if let handler = onClientsChanged { DispatchQueue.main.async { handler(count) } }
    }

    private func broadcast(event: String, json: [String: Any]) {
        let data = Data(Self.frame(event: event, json: json).utf8)
        // Dublaj sesi altyazı yerinden bağımsızdır; yalnız altyazı olayları kapatılır.
        let subtitle = Self.subtitleEvents.contains(event)
        let regionId = event == "region" ? json["id"] as? String : nil
        let now = Date()
        let hold = event == "subtitle" ? Self.legacyClearHold(textLength: (json["text"] as? String)?.count ?? 0) : 0
        queue.async {
            if let regionId {
                self.liveRegions[regionId] = (json["text"] as? String ?? "").isEmpty ? nil : json
            } else if event == "region-clear" {
                self.liveRegions.removeAll()
            } else if event == "anchor" {
                self.liveAnchor = json["lost"] == nil ? json : nil
            }
            let tvs = !subtitle || self.tvEnabled
            if event == "subtitle" {
                self.legacyHoldGeneration += 1
                self.legacyHoldUntil = now.addingTimeInterval(hold)
            }
            guard event == "clear", tvs, !self.legacyClients.isEmpty, self.legacyHoldUntil > now else {
                self.sendToAll(data, includingTVs: tvs)
                return
            }
            // Eski TV'ler satırı kendileri tutmaz: `clear` onlara satırın en az görünme süresi dolunca gider.
            self.sendToAll(data, includingTVs: true, except: self.legacyClients)
            let generation = self.legacyHoldGeneration
            self.queue.asyncAfter(deadline: .now() + self.legacyHoldUntil.timeIntervalSince(now)) {
                guard generation == self.legacyHoldGeneration, self.tvEnabled else { return }
                self.sendToAll(data, includingTVs: true, only: self.legacyClients)
            }
        }
    }

    static let subtitleEvents: Set<String> = ["subtitle", "clear", "screen", "screen-clear", "style", "region", "region-clear",
                                              "anchor"]

    /// Gönderim hatası alan bağlantı kopmuş sayılır ve listeden çıkarılır. `includingTVs` false ise yalnız izleyiciler
    /// (OBS) alır.
    private func sendToAll(_ data: Data, includingTVs: Bool = true, except: Set<ObjectIdentifier> = [],
                           only: Set<ObjectIdentifier>? = nil) {
        for (id, connection) in clients where (includingTVs || viewers.contains(id)) && !except.contains(id)
            && (only?.contains(id) ?? true) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                self.drop(connection, id: id)
            })
        }
    }

    /// Yeni bağlanan TV'ye (ya da OBS'e) gösterilen ek alanlar: önce `region-sync` (listede olmayan alanları TV kaldırır;
    /// kopukken kaçan temizleme komutları), sonra her alanın son `region` olayı `keep` bayrağıyla (TV'de duran aynı alan
    /// yeniden çizilmez). Sunucunun kuyruğunda.
    func regionReplay(tv: Bool) -> String {
        let fresh = Self.keepsRegions(aliveAt: regionAliveAt, now: Self.uptimeMs())
        let live = tv && fresh ? liveRegions.sorted { $0.key < $1.key } : []
        var frames = Self.frame(event: "region-sync", json: ["ids": live.map(\.key)])
        for (_, json) in live {
            var kept = json
            kept["keep"] = true
            frames += Self.frame(event: "region", json: kept)
        }
        if tv, liveRegions["game-phone"]?["anchor"] != nil, let anchor = liveAnchor {
            frames += Self.frame(event: "anchor", json: anchor)
        }
        return frames
    }

    /// Gösterilen ek alanları (telefon kartı hariç) `keep` bayrağıyla yeniden gönderir: TV'de sahnede kalan yazının
    /// çevirisi 15 sn'lik ömrü dolup kalkmasın. Sunucunun kuyruğunda.
    func refreshRegions() {
        guard tvEnabled || !viewers.isEmpty, Self.keepsRegions(aliveAt: regionAliveAt, now: Self.uptimeMs()) else { return }
        for (id, json) in liveRegions.sorted(by: { $0.key < $1.key }) where id != "game-phone" {
            var kept = json
            kept["keep"] = true
            sendToAll(Data(Self.frame(event: "region", json: kept).utf8), includingTVs: tvEnabled)
        }
    }

    /// Ek alanların okuma turu döndü (`RegionSending.regionsAlive`).
    public func regionsAlive() {
        let now = Self.uptimeMs()
        queue.async { self.regionAliveAt = now }
    }

    /// Gösterilen alanlar yenilenir mi: tur hiç bildirilmediyse (eski akış) ya da en son `regionAliveMs` içinde döndüyse.
    static func keepsRegions(aliveAt: Int?, now: Int) -> Bool {
        aliveAt.map { now - $0 <= regionAliveMs } ?? true
    }

    private func startPing() {
        let refresh = DispatchSource.makeTimerSource(queue: queue)
        refresh.schedule(deadline: .now() + regionRefreshInterval, repeating: regionRefreshInterval)
        refresh.setEventHandler { [weak self] in self?.refreshRegions() }
        refresh.resume()
        regionTimer = refresh

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dropSilentTVs()
            self.sendToAll(Data(Self.pingFrame.utf8))
        }
        timer.resume()
        pingTimer = timer
    }

    private static func frame(event: String, json: [String: Any]) -> String {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "event: \(event)\ndata: \(body)\n\n"
    }
}
