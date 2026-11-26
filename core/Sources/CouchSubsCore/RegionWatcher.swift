// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Ek alanların çevirisini TV'ye ileten taraf (gerçekte `SubtitleServer`).
public protocol RegionSending: AnyObject {
    /// `text` boşsa alanın kutusu kalkar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?)
    /// Çevirinin içinde kumanda simgeleri varsa (`ButtonIcons`); simgeyi bilmeyen gönderici düz metni yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?)
    /// Alanda birbirinden ayrı duran yazı grupları varsa (görev başlığı ve ayrı sütundaki hedef) `blocks` her grubun
    /// çevirisini kendi yeriyle taşır; TV her birini kendi İngilizce yazısının üstüne koyar. Blokları bilmeyen gönderici
    /// birleşik metni yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                    blocks: [ScreenTranslation.Item]?)
    /// Telefona yapışık çeviri (`PhoneAnchorSession`): bloklar `anchor` kuşağının başvuru koordinatındadır; çizim her
    /// karede `sendAnchor` dönüşümüyle taşınır. Çapayı bilmeyen gönderici blokları olduğu gibi yollar.
    func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                    blocks: [ScreenTranslation.Item]?, anchor: AnchorPose?)
    func clearRegions()
    /// Okuma turu sürüyor (her tur başında ve her alandan sonra): gösterilen alanlar yalnız tur dönerken TV'de yenilenir
    /// (`SubtitleServer.regionAliveMs`). Turu bilmeyen gönderici yok sayar.
    func regionsAlive()
}

extension RegionSending {
    public func regionsAlive() {}

    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight)
    }

    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons)
    }

    public func sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?, icons: [IconPlacement]?,
                           blocks: [ScreenTranslation.Item]?, anchor: AnchorPose?) {
        sendRegion(id: id, text: text, box: box, lineHeight: lineHeight, icons: icons, blocks: blocks)
    }
}

extension SubtitleServer: RegionSending {}

/// Ek alanları (görev yazısı, telefon mesajı, bildirim) ana altyazıdan ayrı ve seyrek okur, çevirip TV'ye kendi
/// yerleriyle gönderir (Windows: CouchSubs.Core/RegionWatcher.cs ile aynı kurallar).
///
/// - Ana okuma hattını beklemez, onu da bekletmez: `offer` hemen döner; tur ayrı bir görevde ve düşük öncelikle sürer.
/// - En çok `intervalMs`'te bir tur atılır; önceki tur (okuma ya da çeviri) bitmediyse kare atlanır.
/// - Bölge izi (`RegionCropper.signature`) değişmeyen alan yeniden okunmaz.
/// - Okunan yazı ancak kararlıysa çevrilir: iz bir tur değişmeden kaldıysa ya da iki okuma aynı yazıyı verdiyse (arkası
///   kıpırdayan köşe yazıları). Böylece belirirken yarım okunan yazı çevrilmez.
/// - Yazı değişmedikçe yeniden çevrilmez; boşalan alanın kutusu kalkar.
/// - Paket eşleşmesi ve çeviri motoru ana altyazıyla aynıdır; ama ek alan satırları ortak havuza önerilmez (arayüz
///   yazıları havuzu kirletmesin).
@MainActor
public final class RegionWatcher {
    /// Ek alanlar altyazıyla aynı seri OCR kuyruğunu kullanır. Mac ve iPhone'da saniyede en çok bir tur çalışır.
    public static let defaultIntervalMs = 1000

    /// Otomatik bulunmuş alan varken okuma aralığı en çok bu kadardır (yazı belirdikten ~1 sn içinde Türkçesi).
    public static let autoIntervalMs = 500

    /// Ekrandakinden yalnız biraz farklı (ya da eksik) kararlı okuma en çok bu kadar tur bekletilir; o hâlde kalırsa
    /// gerçekten değişmiş sayılır ve gösterilir (görevin tek sözcüğü değişebilir: "Go to the barn" → "Go to the bank").
    static let holdLimit = 4

    /// Hazır alanın arayüz kutusu (`UiPanel.hasText`) art arda bu kadar tur bulunamazsa gösterilen çeviri silinir. Tek
    /// karelik ıska çeviriyi siliyordu; iz değişmediği için de panel aynı yazıyla geri gelince çeviri bir daha gelmiyordu
    /// (#1202, GTA 6 telefonu; Windows ve Android ile aynı).
    static let panelMissTurns = 3

    /// Çevirisi saklanan en çok yazı sayısı (oyun görev yazısını arada silip yeniden gösteriyor).
    private static let translationLimit = 64

    private struct State {
        var signature: [UInt8]?
        /// Günlüğe son yazılan, güveni düşük olduğu için çevrilmeyen satırlar (aynı satırlar her turda yeniden yazılmaz).
        var unsureLogged: [String] = []
        /// Son okumanın sadeleştirilmiş yazısı; bir sonraki okuma aynıysa yazı kararlıdır.
        var lastRead: String?
        /// Okunmuş ama henüz kararlı sayılmamış yazı.
        var candidate: Candidate?
        /// TV'de şu an çevirisi duran yazı (sadeleştirilmiş); boşsa kutu yok.
        var shown = ""
        /// Gösterilen yazının `Candidate.text`'i.
        var shownText = ""
        /// Gösterilen yazıdaki tuş simgesi sayısı.
        var shownIcons = 0
        /// Son gösterilen (boş olmayan) yazı; alan boşalınca da hatırlanır (yarım okumayı tanımak için).
        var remembered = ""
        /// Bekletilen okuma ve kaç turdur bekletildiği (`holdLimit`).
        var held: String?
        /// Bekletilen okumanın yazısı (günlük için).
        var heldText: String?
        var holds = 0
        /// Son gönderilen çeviri, aynı yazı yeni bir konuma taşındığında yeniden kullanılır.
        var renderedKey: String?
        var renderedText: String?
        var renderedIcons: [IconPlacement]?
        var renderedBox: TextBox?
        var renderedLineHeight: Double?
        var renderedLayout: [Block]?
        /// Gönderilen bloklar ve her birinin `Candidate.blocks` içindeki sırası.
        var renderedBlocks: [(group: Int, item: ScreenTranslation.Item)]?
        /// Hazır alanda arayüz kutusunun art arda bulunamadığı tur sayısı (`panelMissTurns`).
        var panelMisses = 0
        /// Çevirisi gösterilirken art arda kaç turdur okuma değişip doğrulanamadı (`unsteadyTurns`) ve ilkinin zamanı
        /// (`unsteadyMs`).
        var unsteady = 0
        var unsteadySince: Int?
        /// Çevirinin gönderildiği turdaki alan izi: özgün yazının izi (`traceGone`).
        var shownTrace: [UInt8]?
    }

    /// Alanın kaldırma geçmişi; alanın durumu silinse de (otomatik alan listeden çıkıp dönünce) kalır.
    private struct Steadiness {
        /// Kaldırma eşiğinin çarpanı eksi bir (`maxPatience`); kaldırılan yazı hemen geri geldikçe artar.
        var patience = 0
        /// Son kaldırılan yazı ve zamanı (`reboundMs`).
        var clearedText = ""
        var clearedAt: Int?
    }

    /// Çevirisi gösterilen alanda okuma en az bu kadar tur ve en az `unsteadyMs` boyunca art arda değişip doğrulanamazsa
    /// (yazı gitti, yerinde sahne oynuyor) çeviri kaldırılır: menü, tabela ve ipucu kutusunun çevirisi yazı oyundan
    /// kalktıktan sonra TV'de kalıyordu (#1198). Yalnız tur sayısı (3 tur, 500 ms'lik turlarda 1,5 sn) arkası oynayan sabit
    /// yazının çevirisini kaldırıp önbellekten geri getiriyordu: koyu kutu 2-3 sn'de bir yanıp sönüyordu (Samsung'da
    /// parlaklık sıçraması). Windows ve Android ile aynı.
    static let unsteadyTurns = 4
    static let unsteadyMs = 3000
    /// Kaldırılan yazı bu süre içinde yeniden gösterilirse yerindeydi: alanın kaldırma eşiği uzar (`maxPatience`).
    static let reboundMs = 10_000
    /// Kaldırma eşiği en çok (1 + bu) katına uzar.
    static let maxPatience = 2
    /// Ekrandaki yazının en az bu kadar harfli bir sözcüğü okumada geçiyorsa yazı hâlâ (kısmen) görünür (`partlyVisible`).
    static let visibleWordLength = 4
    /// Alanın izindeki örneklerin bu kadarı bir turda değiştiyse görüntü bütünüyle değişmiştir (`clearIfUnsteady`).
    static let bigChangeShare = 0.5
    /// Çeviri motoru bu süreyi aşarsa tur biter (aday sonraki turda yeniden denenir): asılı istek turu kilitliyordu.
    public var translationTimeoutMs = 8000

    /// Alanda ayrı duran bir yazı grubu: `Candidate.paragraphs` içinde `start`'tan başlayan `count` parça, karedeki yeri
    /// ve satır yüksekliği (kareye oranla).
    struct Block: Equatable {
        var start: Int
        var count: Int
        var box: TextBox
        var lineHeight: Double
        /// Otomatik ekran yazısında özgün yazının renkleri ve görünüşü (`TextStyleSampler`); diğerlerinde nil.
        var style: PhoneTextStyle? = nil
        var look: TextLook? = nil
        /// Yerinde birebir çizim ölçüleri (`TextPainter`), karedeki yeriyle; otomatik ekran yazısında.
        var paint: TextPaint? = nil
        /// Özgün yazının satır sayısı (`Group.rows`); TV çeviriyi bu satır aralığıyla dizer.
        var rows = 1
        /// Görev/hedef satırının bloğu (`MissionLine.areaId`): çevirisi altyazıdan ayrı görünüşte (`MissionLine.style`,
        /// başında `MissionLine.marker`).
        var mission = false
    }

    struct Candidate {
        var paragraphs: [String]
        var box: TextBox?
        var lineHeight: Double?
        var key: String
        /// Her parçadaki kumanda simgeleri (kareden kesilmiş), parçadaki sırasıyla; simge yoksa nil.
        var icons: [[IconSlot]]? = nil
        /// Alanda birden çok ayrı yazı grubu varsa grupları; tek grupta nil (tek kutu).
        var blocks: [Block]? = nil
        /// Yazının sadeleştirilmiş hâli (simgeler dahil, yerleşim hariç); okumaları karşılaştırmak için.
        var text = ""
        /// Otomatik alanda haritanın görev kartı var (yardım köşesinde değil): türü "Görev ve hedef yazısı".
        var missionCard = false
        /// Menüde güveni düşük okunduğu için çeviriye gönderilmeyen satırlar (`ScreenTextNoise.isUnsure`; günlük için).
        var unsure: [String] = []
    }

    /// Sadeleştirilmiş yazı; tuş simgeleri `ButtonIcons.marker` olarak kalır. Simgesi sonradan bulunan okuma
    /// ("SET DESTINATION ✕") eskisinden ayrılsın.
    static func textKey(_ paragraphs: [String]) -> String {
        var parts: [String] = []
        for part in paragraphs.joined(separator: " ").split(separator: ButtonIcons.marker, omittingEmptySubsequences: false) {
            if !parts.isEmpty { parts.append(String(ButtonIcons.marker)) }
            parts.append(TextMatch.normalize(String(part)))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Paragrafların çevirisi (çevrilmeyen parça nil) ve kaçının paketten geldiği.
    struct Translation: Sendable {
        var result: [String?]
        var readyCount: Int
    }

    private let reader: TextReader
    private let translator: TextTranslator
    private let server: RegionSending
    private let intervalMs: Int
    private let now: () -> Int
    private var states: [String: State] = [:]
    private var lastPass: Int?
    private var phoneSession: PhoneRegionSession?
    /// Telefonun açılışları arasında kalan çeviriler ve panelin yazı boyu (`PhoneMemory`); `reset` unutturur.
    private let phoneMemory = PhoneMemory()
    public var englishPhoneMessages = false
    /// "GTA 6 Telefon Mesajları: Yanda Panel / Balonların Üstünde" ve panelin yazı boyu; her gönderide okunur.
    public var phonePanel: () -> PhonePanelOptions = { PhonePanelOptions() }
    /// Telefona yapışık çeviri (deneysel, yalnız Mac): verilirse telefon okuması çapayı kurar, balon çevirileri başvuru
    /// koordinatında gider ve her karede çapanın dönüşümüyle çizilir (`PhoneAnchorSession`). nil: eski davranış.
    public var phoneAnchor: PhoneAnchorSession?
    private var running: Task<Void, Never>?
    private var session = 0
    /// Yalnız kararlı okumaların başarılı çevirileri saklanır.
    private var translations: [String: Translation] = [:]
    /// Alanların kaldırma geçmişi (`Steadiness`).
    private var steadiness: [String: Steadiness] = [:]

    /// Oyun paketi: satırın hazır Türkçesi (ana altyazıyla aynı arama).
    public var packLookup: ((String) -> PackMatch?)?
    /// Hedef dil Türkçe: yüksek güvenle Türkçe olan parça çevrilmez, aslı sayılır (#289).
    public var skipsTurkish = true
    /// Kısa İngilizce tuş komutlarını Türkçeye çevirir. Yalnız en → tr için açılır.
    public var translatesUiCommands = false
    public var onLog: ((String) -> Void)?

    /// Aşama süreleri (`StageTiming`; okuma, çizim ölçümü, tur, telefon okuması, bütün karenin çizimi); 30 sn'de bir
    /// `onTiming`'e tek satır. Uygulama kare iş parçacığının işlerini (telefon izleme) de ekleyebilir. Android ve Windows aynı.
    public let timing = StageTiming()
    /// `timing` satırı (uygulama altyazı günlüğüne yazar; `onLog`'dan ayrı, günlük satırlarını sayan denemeler karışmasın).
    public var onTiming: ((String) -> Void)?
    public static let stageRead = "okuma"
    public static let stagePaint = "çizim"
    public static let stagePass = "tur"
    public static let stagePhone = "telefon okuması"
    public static let stageScreen = "bütün kare"
    public static let stageTrack = "telefon izleme"

    /// Turun bütün karesi: noktaları (çizim kipi ve boş alan ölçümü için) en çok bir kez çizilir.
    final class ScreenFrame: @unchecked Sendable {
        let image: CGImage
        private var pixels: GamePhonePixels?
        private var drawn = false
        private let timing: StageTiming?

        init(_ image: CGImage, timing: StageTiming? = nil) {
            self.image = image
            self.timing = timing
        }

        /// Noktalar (çizilmediyse şimdi çizilir).
        func measured() -> GamePhonePixels? {
            if !drawn {
                pixels = GamePhonePixels(image)
                drawn = true
            }
            return pixels
        }

        /// Noktaları ana iş parçacığının dışında çizer (turda bir kez).
        @MainActor func prepare() async {
            guard !drawn else { return }
            let image = self.image
            let started = DispatchTime.now().uptimeNanoseconds
            let drawnPixels = await Task.detached(priority: .utility) { GamePhonePixels(image) }.value
            if !drawn {
                pixels = drawnPixels
                drawn = true
            }
            timing?.add(RegionWatcher.stageScreen, nanoseconds: Int64(DispatchTime.now().uptimeNanoseconds - started))
        }
    }
    /// Düşürülen ya da bekletilen okumanın nedeni, sınırlı ve tekrarsız (`DropLog`).
    private let drops: DropLog
    /// Bozuk okunduğu için çeviriye gönderilmeyen parçaların günlüğü, seyreltilmiş (`ReadPlausibility`; GitHub #1293).
    private let implausibleLog: ReadPlausibility.Log
    /// Telefonun sessiz yolları (`PhoneTrace`): ayrı sınır, telefon her açılışta yeniden başlamaz.
    private let phoneTrace: DropLog
    /// Bu tür ekran yazısı çevrilir mi (Ayarlar'daki türler, `UserSettings.screenTextAllows`); varsayılan hepsi.
    public var allows: (ScreenTextKind) -> Bool = { _ in true }
    /// Altyazı hattının son satırları ve alanı (bkz. `SubtitleEcho`); uygulama `SubtitleEcho.shared` verir.
    public var subtitleEcho: SubtitleEcho?
    /// Otomatik alan okundu ama yazı yok ya da gürültü (`ScreenTextNoise`): alanın kimliği (`ScreenTextDetector.reject`).
    public var onAutoRejected: ((String) -> Void)?
    /// Menü durumundaki otomatik alanın yazısı tuş ipucu ya da görev/HUD yazısı (`ScreenTextKind.isHud`): alanın kimliği.
    /// Dedektör bu alanı menü bileşeni saymaz (`ScreenTextDetector.markHud`, #1240).
    public var onAutoHud: ((String) -> Void)?
    /// Her okumanın süresi (ms; ölçüm için).
    public var onReadMs: ((Int) -> Void)?
    /// Tamamlanan tur sayısı ve okuma sayısı (ölçüm ve testler için).
    public private(set) var passes = 0
    public private(set) var reads = 0

    /// Tur aralığının çarpanı (`ReadQueue.backgroundSlowdown`); testler değiştirir.
    public var slowdown: () -> Int = { ReadQueue.shared.backgroundSlowdown }

    public init(reader: TextReader, translator: TextTranslator, server: RegionSending,
                intervalMs: Int = RegionWatcher.defaultIntervalMs, clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.reader = reader
        self.translator = translator
        self.server = server
        self.intervalMs = intervalMs
        self.now = clock
        self.drops = DropLog(clock: clock)
        self.implausibleLog = ReadPlausibility.Log(clock: clock)
        self.phoneTrace = DropLog(clock: clock)
    }

    /// Bir tur sürüyor mu.
    public var isBusy: Bool { running != nil }

    /// Telefon açıldı: otomatik ekran yazısının ve kenar bildirimlerinin gösterilen kutuları (görev satırı dışında) aynı
    /// karede kalkar. Önceden sonraki turu bekliyordu; telefonun ekranına çizilmiş eski kutu (Sinan Bey, beta.100 3422:
    /// önceki haberin "Vali karşılaştırıyor" kutusu hava uygulamasında) bir süre duruyordu. Telefon açıkken bu alanlar
    /// zaten önerilmez (Windows ve Android ile aynı).
    func clearScreenText() {
        for (id, state) in states where id.hasPrefix("auto-") && id != MissionLine.areaId {
            if !state.shown.isEmpty { server.sendRegion(id: id, text: "", box: nil, lineHeight: nil) }
            states[id] = nil
        }
    }

    /// Her karede çağrılır; tur zamanı geldiyse ve önceki tur bittiyse turu arka planda başlatır, hemen döner.
    public func offer(_ frame: CGImage, areas: [ExtraArea], phone pose: GamePhoneGeometry.Pose? = nil, capturedAt: Int? = nil) {
        if let pose {
            if phoneSession == nil {
                let session = PhoneRegionSession(reader: reader, translator: translator, server: server)
                session.onLog = { [weak self] in self?.onLog?($0) }
                session.trace = phoneTrace
                session.panel = { [weak self] in self?.phonePanel() ?? PhonePanelOptions() }
                session.anchor = phoneAnchor
                session.memory = phoneMemory
                phoneSession = session
                clearScreenText()
            }
            phoneSession?.observe(frame, pose: pose, at: capturedAt ?? now())
        } else if phoneSession != nil {
            closePhone()
        }
        guard running == nil else { return }
        let time = now()
        // Altyazı okuması sırada bekliyorsa (ya da okuyucu takılıysa) ek alanlar seyrek okunur: altyazı her zaman önce.
        let interval = (areas.contains(where: \.auto) ? min(intervalMs, Self.autoIntervalMs) : intervalMs) * slowdown()
        let manualDue = (!areas.isEmpty || states.values.contains { !$0.shown.isEmpty })
            && (lastPass.map { time - $0 >= interval } ?? true)
        let phone = phoneSession
        let phoneDue = phone?.beginIfDue(time) ?? false
        guard manualDue || phoneDue else { return }
        if manualDue { lastPass = time }
        let session = self.session
        running = Task { [weak self] in
            guard let self, self.session == session else { return }
            if manualDue {
                let begun = self.now()
                await self.pass(frame, areas: areas)
                self.timing.add(Self.stagePass, milliseconds: self.now() - begun)
            }
            if phoneDue, let phone, self.phoneSession === phone, self.session == session {
                let begun = self.now()
                await phone.visit(packLookup: self.packLookup, skipsTurkish: self.skipsTurkish,
                                  english: self.englishPhoneMessages)
                self.timing.add(Self.stagePhone, milliseconds: self.now() - begun)
            }
            if let line = self.timing.report(now: self.now()) { self.onTiming?(line) }
            // Bu arada sıfırlandıysa yeni oturumun turuna dokunulmaz.
            if self.session == session { self.running = nil }
        }
    }

    /// Bir tur: kaldırılan alanların kutusu kalkar, her açık alan gerekirse okunur ve kararlı yazısı çevrilir.
    /// Testler doğrudan çağırır.
    public func pass(_ frame: CGImage, areas all: [ExtraArea]) async {
        let started = session
        passes += 1
        // Tur dönüyor: TV'deki alanlar yenilenebilir (#1271). Tur takılırsa (donma) yenileme durur, TV alanları kendisi kaldırır.
        server.regionsAlive()
        defer { server.regionsAlive() }
        // Ayarlar'da kapalı türün alanı (menü, hazır yardım/mesaj alanı, görev satırı) okunmaz; kutusu kalkar.
        let areas = Self.yieldingPresets(all.filter { area in ScreenTextKind.reads(area, allows: allows) })
        let ids = Set(areas.map(\.id))
        for (id, state) in states where !ids.contains(id) {
            if !state.shown.isEmpty { server.sendRegion(id: id, text: "", box: nil, lineHeight: nil) }
            states[id] = nil
        }
        // Bütün kare (çizim kipi ve boş alan ölçümü, #1339) turda en çok bir kez, ilk okunan yazıda ve ana iş parçacığının
        // dışında çizilir; önceden her okunan alanda ve her kişi resminde ana iş parçacığında yeniden çiziliyordu (beta.103).
        let screen = ScreenFrame(frame, timing: timing)
        for area in areas {
            guard session == started else { return }
            await visit(area, frame: frame, screen: screen, session: started)
            server.regionsAlive()
        }
    }

    private func visit(_ area: ExtraArea, frame: CGImage, screen: ScreenFrame, session: Int) async {
        let region = area.region
        let (crop, signature) = await Task.detached(priority: .utility) {
            let crop = RegionCropper.crop(frame, to: region)
            return (crop, RegionCropper.signature(of: crop))
        }.value
        guard session == self.session else { return }
        var state = states[area.id] ?? State()
        let before = state.signature
        let changed = state.signature.map {
            ReadScheduler.changed($0, signature, threshold: ReadScheduler.defaultChangeThreshold)
        } ?? true
        state.signature = signature
        guard changed else {
            // İz bir tur değişmedi: okunan yazı kararlıdır.
            state.unsteady = 0
            state.unsteadySince = nil
            if let candidate = state.candidate {
                state.candidate = nil
                states[area.id] = state
                await commit(candidate, area: area)
            } else {
                states[area.id] = state
            }
            return
        }
        if GameAreaPresets.isPreset(area.id), !UiPanel.hasText(crop) {
            // Hazır alanda arayüz kutusu yok (PS5 ana ekranı, başka oyun, oyun dünyası): OCR çalışmaz. İz unutulur: sonraki
            // tur görüntü değişmese de yeniden bakar, panel aynı yazıyla dönünce yeniden okunur.
            state.signature = nil
            state.panelMisses += 1
            if !state.shown.isEmpty, state.panelMisses < Self.panelMissTurns {
                // Tek karelik ıska: gösterilen çeviri `panelMissTurns` tur dolmadan kalkmaz.
                states[area.id] = state
                return
            }
            // Gösterilen kutu kalkar.
            state.candidate = nil
            state.lastRead = nil
            let wasShown = !state.shown.isEmpty
            state.shown = ""
            state.shownText = ""
            state.shownIcons = 0
            state.renderedKey = nil
            state.renderedText = nil
            state.renderedIcons = nil
            state.renderedBox = nil
            state.renderedLineHeight = nil
            state.renderedLayout = nil
            state.renderedBlocks = nil
            states[area.id] = state
            if wasShown {
                server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
                onLog?("ek alan \(area.name): arayüz kutusu yok, kaldırıldı")
            }
            return
        }
        state.panelMisses = 0
        let started = now()
        let reader = self.reader
        let reading = try? await ReadQueue.shared.run(priority: .background, detail: ReadQueue.detail(area.auto ? "ekran yazısı" : "ek alan", crop)) {
            try reader.readLines(crop, deep: false)
        }
        guard session == self.session else { return }
        guard let reading else {
            // OCR hatası boş alan değildir. Eski kutuyu koru; aynı kareyi sonraki normal turda yeniden oku.
            // Başarısız kare, önceki adayın kararlılığını da doğrulayamaz.
            state.signature = nil
            state.lastRead = nil
            state.candidate = nil
            states[area.id] = state
            return
        }
        reads += 1
        onReadMs?(now() - started)
        timing.add(Self.stageRead, milliseconds: now() - started)
        if !reading.lines.isEmpty {
            await screen.prepare()
            guard session == self.session else { return }
        }
        // Altyazı alanındaki ya da altyazı hattının okuduğu satırlar ekran yazısı değildir; altyazı iki yerde çizilmesin
        // (bkz. `SubtitleEcho`). Menüde, görev satırının ve kenar bildiriminin kendi alanında
        // yalnız metin eşleşmesi uygulanır.
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let geometry = (area.auto || GameAreaPresets.isPreset(area.id)) && !area.menu && area.id != MissionLine.areaId
            && !ScreenNotices.isNotice(id: area.id)
        let own = subtitleEcho?.filter(reading, place: place, geometry: geometry) ?? reading
        // Kullanıcının kendi ek alanı da (#1324: "Telefon (sağ alt)" alanındaki tuş ipuçları) hazır ve otomatik alan gibi
        // özgün stilinde, grup grup ve çizim kipiyle (yanına yazma, ikiz kutu) çizilir: önceden tek kutu tuş simgelerinin
        // üstünü örtüyor, yazı boyu her okumada alanın kutusuna göre değişiyordu. Windows ve Android aynı.
        let painting = DispatchTime.now().uptimeNanoseconds
        let candidate = Self.candidate(own, in: region, frame: crop, auto: area.auto, menu: area.menu,
                                       styled: true, kind: ScreenTextKind.of(area), screen: screen)
        timing.add(Self.stagePaint, nanoseconds: Int64(DispatchTime.now().uptimeNanoseconds - painting))
        if candidate.unsure != state.unsureLogged {
            state.unsureLogged = candidate.unsure
            if !candidate.unsure.isEmpty {
                onLog?("ek alan \(area.name): güveni düşük okunan satır çeviriye gönderilmedi: "
                       + candidate.unsure.map { "«\(SubtitleLog.excerpt(IconText.plain($0)))»" }.joined(separator: ", "))
            }
        }
        if candidate.key.isEmpty, !candidate.unsure.isEmpty {
            // Okunan her satır güvensiz: boş alan değildir (alan reddedilmez, gösterilen kutu kalır); sonraki tur yeniden okur.
            state.signature = nil
            state.lastRead = nil
            state.candidate = nil
            states[area.id] = state
            return
        }
        // Çevirisi gösterilen alanda art arda boş okuma (görüntü değişirken) yazının gittiğini tek başına kanıtlamaz: kaldırma
        // kararı `clearIfUnsteady`'de (özgün yazının izi ya da süre).
        let emptyWhileShown = candidate.key.isEmpty && !(state.renderedText ?? "").isEmpty
        if state.lastRead == candidate.key, !emptyWhileShown {
            state.unsteady = 0
            state.unsteadySince = nil
            state.candidate = nil
            states[area.id] = state
            await commit(candidate, area: area)
        } else {
            // Seçim kaydı (#1267): gösterilen bir satırın zemini açıktan koyuya (ya da tersine) döndüyse eski kutular o
            // satırın eski renginde kalıyor, yeni okuma doğrulanana dek bozuk çeviri görünüyordu. Eski kutular hemen
            // kalkar; yeni okuma her zamanki gibi çizilir.
            // Liste kaydı (Sinan Bey beta.100 3381, 3383): menüde liste kayınca eski kutular eski yerinde başka satırın
            // üstünde kalıyordu ("Hazır olunca çık"); yazının bir kısmı hâlâ göründüğü için kararsız okuma da kaldırmıyordu.
            // Gösterilen bir satır başka yerde okunuyor ya da yerinde başka yazı var: eski kutular hemen kalkar.
            // Satır farkı (#1359, #1362): seçim çubuğu ya da liste oynayınca bütün kutular kalkıp ancak iki aynı okumayla
            // geri geliyordu; kumandaya basıldıkça menü boş kalıyordu (GTA 6 duraklatma menüsü, kumanda şeması önizlemesi).
            // Artık yalnız yazısı değişen satır kalkar: yazısı aynı kalan satırın çevirisi korunur, yeri ve stili bu okumadan
            // (kendi satırının şimdiki zemininden) alınır; bu turda okunamayan satır (seçili satırın açık zemindeki soluk
            // yazısı) yerinde kalır, stili kendi yerinden yeniden örneklenir. Yeni satır önbellekteki çevirisiyle hemen,
            // yoksa okuma doğrulanınca çizilir. Windows ve Android aynı.
            let rendered = state.renderedBlocks?.map(\.item) ?? []
            let texts = Self.blockTexts(candidate)
            let listShifted = area.menu && Self.listMoved(rendered: rendered, current: texts)
            if !(state.renderedText ?? "").isEmpty,
               listShifted || Self.selectionMoved(rendered: rendered, current: candidate.blocks ?? []) {
                let diff = Self.carriedRows(rendered: rendered, current: texts, listMoved: listShifted)
                var kept: [(group: Int, item: ScreenTranslation.Item)] = []
                var unread = 0
                for row in diff.kept {
                    var item = rendered[row.rendered]
                    if let c = row.current, let block = candidate.blocks?[c] {
                        item.box = block.box
                        item.lineHeight = block.lineHeight
                        item.style = block.style ?? item.style
                        item.look = block.look ?? item.look
                        item.paint = block.paint ?? item.paint
                        kept.append((c, item))
                    } else {
                        unread += 1
                        kept.append((-1, Self.restyled(item, frame: crop, region: region)))
                    }
                }
                var fresh = 0
                for c in diff.fresh {
                    guard let block = candidate.blocks?[c], block.count == 1, let item = freshRow(block, text: texts[c].text) else { continue }
                    kept.append((c, item))
                    fresh += 1
                }
                if kept.isEmpty {
                    server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
                    state.shownText = ""
                    state.renderedText = nil
                    state.renderedBlocks = nil
                    onLog?("ek alan \(area.name): seçim kaydı, eski kutular kaldırıldı")
                } else {
                    kept.sort { ($0.item.box.top, $0.item.box.left) < ($1.item.box.top, $1.item.box.left) }
                    let text = kept.map(\.item.translation).joined(separator: "\n")
                    server.sendRegion(id: area.id, text: text, box: candidate.box, lineHeight: candidate.lineHeight,
                                      icons: nil, blocks: kept.map(\.item))
                    state.shownText = candidate.text
                    state.renderedText = text
                    state.renderedBlocks = kept
                    onLog?("ek alan \(area.name): seçim kaydı, \(kept.count - unread - fresh) satır yerinde kaldı, "
                           + "\(unread) okunamayan satır korundu, \(fresh) satır önbellekten, "
                           + "\(rendered.count - kept.count + fresh) satır kaldırıldı\(listShifted ? " (liste kaydı)" : "")")
                }
                // Bütün çeviri yeni okuma doğrulanınca yeniden kurulur (önbellekten, motora gitmeden).
                state.shown = ""
                state.shownIcons = 0
                state.renderedKey = nil
                state.renderedIcons = nil
                state.renderedBox = nil
                state.renderedLineHeight = nil
                state.renderedLayout = nil
            }
            state.lastRead = candidate.key
            state.held = nil
            state.holds = 0
            state.candidate = candidate
            if !(state.renderedText ?? "").isEmpty { clearIfUnsteady(candidate, area: area, state: &state, before: before, signature: signature) }
            states[area.id] = state
        }
    }

    /// Çevirisi gösterilen alanda okuma doğrulanamadı. Çeviri iki durumda kaldırılır (#1198; Windows ve Android ile aynı):
    /// - Yazı gitti: okuma boş ve özgün yazının izi yok (`traceGone`); görüntü de bütünüyle değiştiyse (`bigChangeShare`) ilk
    ///   turda, değilse ikinci turda. Gerçekten kalkan yazının çevirisi beklemez.
    /// - Okuma en az `unsteadyTurns` tur ve `unsteadyMs` boyunca gösterilen yazıya benzemedi (`unsteadyLong`).
    /// Okumada gösterilen yazının bir parçası hâlâ görünüyorsa (`partlyVisible`) tur kararsız sayılmaz: arkası oynayan sabit
    /// yazının çevirisi kalkıp geri gelmez.
    private func clearIfUnsteady(_ candidate: Candidate, area: ExtraArea, state: inout State, before: [UInt8]?,
                                 signature: [UInt8]) {
        if Self.partlyVisible(candidate.text, state.shownText) {
            state.unsteady = 0
            state.unsteadySince = nil
            return
        }
        let time = now()
        state.unsteady += 1
        let since = state.unsteadySince ?? time
        state.unsteadySince = since
        let turns = state.unsteady
        let patience = steadiness[area.id]?.patience ?? 0
        let bigChange = before.map { Self.changedShare($0, signature) >= Self.bigChangeShare } ?? false
        // Kaldırılan yazı daha önce geri geldiyse (`patience`) boş okuma da art arda o kadar tur daha görülmeli.
        let gone = candidate.key.isEmpty && Self.traceGone(state.shownTrace, signature) && (bigChange || turns >= 2)
            && turns > patience
        guard gone || Self.unsteadyLong(turns: turns, elapsedMs: time - since, patience: patience) else { return }
        let shownText = state.shownText
        server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
        state.shown = ""
        state.shownText = ""
        state.shownIcons = 0
        state.renderedKey = nil
        state.renderedText = nil
        state.renderedIcons = nil
        state.renderedBox = nil
        state.renderedLineHeight = nil
        state.renderedLayout = nil
        state.renderedBlocks = nil
        state.unsteady = 0
        state.unsteadySince = nil
        state.shownTrace = nil
        if steadiness.count >= Self.translationLimit, steadiness[area.id] == nil { steadiness.removeAll(keepingCapacity: true) }
        var memory = steadiness[area.id] ?? Steadiness()
        memory.clearedText = shownText
        memory.clearedAt = time
        steadiness[area.id] = memory
        drops.note("RegionWatcher", gone ? "\(area.name): yazı kalktı (boş okuma, iz yok), çevirisi kaldırıldı"
                                         : "\(area.name): \(Self.unsteadyMs * (1 + patience) / 1000) sn kararlı okunmadı, çevirisi kaldırıldı",
                   IconText.plain(shownText), log: onLog)
    }

    /// Kaldırılan yazı `reboundMs` içinde yeniden gösterildi: yazı yerindeydi; alanın kaldırma eşiği uzar, günlüğe yazılır.
    private func noteRebound(_ candidate: Candidate, area: ExtraArea) {
        guard var memory = steadiness[area.id], let at = memory.clearedAt else { return }
        memory.clearedAt = nil
        if now() - at <= Self.reboundMs, Self.partlyVisible(candidate.text, memory.clearedText) {
            memory.patience = min(Self.maxPatience, memory.patience + 1)
            drops.note("RegionWatcher", "\(area.name): kaldırılan yazı geri geldi, kaldırma eşiği \(1 + memory.patience) katına uzadı",
                       IconText.plain(candidate.paragraphs.joined(separator: " ")), log: onLog)
        }
        steadiness[area.id] = memory
    }

    /// Okumada ekrandaki yazının bir parçası görünüyor: benzer ya da eksik okuma, ya da ekrandakinin en az bir uzun sözcüğü
    /// (`visibleWordLength`) okumada geçiyor (arkası oynayan yazı yarım okunur).
    static func partlyVisible(_ reading: String, _ shown: String) -> Bool {
        guard !reading.isEmpty, !shown.isEmpty else { return false }
        if matches(reading, shown) || isPartOf(reading, shown) { return true }
        let have = words(reading)
        return words(shown).contains { word in
            word.filter(\.isLetter).count >= visibleWordLength && have.contains { matches($0, word) }
        }
    }

    /// Kararsız okuma kaldırmaya yetecek kadar sürdü mü: en az `unsteadyTurns` tur ve `unsteadyMs`; alanın kaldırılan
    /// yazısı daha önce geri geldiyse ikisi de (1 + `patience`) katı.
    static func unsteadyLong(turns: Int, elapsedMs: Int, patience: Int) -> Bool {
        let scale = 1 + max(0, min(maxPatience, patience))
        return turns >= unsteadyTurns * scale && elapsedMs >= unsteadyMs * scale
    }

    /// Çevirinin gönderildiği turdaki alan izi (`trace`) bu turdakine benzemiyor: özgün yazı yerinde değil
    /// (`ScreenPresence.goneCorrelation`; izlerden biri düzse de yok sayılır).
    static func traceGone(_ trace: [UInt8]?, _ signature: [UInt8]) -> Bool {
        guard let trace else { return true }
        guard let score = ScreenPresence.correlation(trace.map(Int.init), signature.map(Int.init)) else { return true }
        return score < ScreenPresence.goneCorrelation
    }

    /// İzdeki örneklerin `ReadScheduler.defaultChangeThreshold`'dan çok değişen payı.
    static func changedShare(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let changed = zip(a, b).filter { abs(Int($0) - Int($1)) > ReadScheduler.defaultChangeThreshold }.count
        return Double(changed) / Double(a.count)
    }

    private static func iconCount(_ candidate: Candidate) -> Int {
        candidate.paragraphs.reduce(0) { count, paragraph in count + paragraph.filter { $0 == ButtonIcons.marker }.count }
    }

    /// Okuma bekletilmeli mi (gösterilmeden önce bir iki tur daha okunur):
    /// - Az önce gösterilen yazının başı: yazı belirirken renkli sözcük geç geliyor ("Fly to a" ← "Fly to a drop");
    ///   görev her belirişinde iki kez çevrilip değişiyordu.
    /// - Ekrandakiyle neredeyse aynı ya da onun eksik hâli, ve daha çok simge bulmamış: harita arkada oynarken tuş
    ///   çubuğu "SET DESTINATION ✕ EXIT ○" / "SET DESTINATIPN EXIT ○" diye okunup kutu sürekli değişiyordu.
    /// - Daha çok simge bulmuş ama ekrandakinin bir sözcüğünü simgeyle değiştirmiş ("Find □" ← "Find Donnie").
    private static func shouldHold(_ candidate: Candidate, _ state: State) -> Bool {
        guard !candidate.text.isEmpty else { return false }
        if state.remembered.count > candidate.text.count, state.remembered.hasPrefix(candidate.text + " ") { return true }
        if state.shownText.isEmpty || state.shownText == candidate.text { return false }
        if TextMatch.addsMeaning(candidate.text, to: state.shownText) { return false }
        return iconCount(candidate) <= state.shownIcons
            ? TextMatch.isSimilar(state.shownText, candidate.text, threshold: 0.85) || isPartOf(candidate.text, state.shownText)
            : losesWords(candidate.text, state.shownText)
    }

    private static func matches(_ a: String, _ b: String) -> Bool { a == b || TextMatch.isSimilar(a, b, threshold: 0.75) }

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ").filter { token in token.contains { $0.isLetter || $0.isNumber } }.map(String.init)
    }

    /// Okuma ekrandakinin eksik hâli mi: sözcükleri (biri tanınmayabilir) ekrandakinde sırasıyla geçiyor.
    static func isPartOf(_ reading: String, _ shown: String) -> Bool {
        let part = reading.split(separator: " ").map(String.init)
        let whole = shown.split(separator: " ").map(String.init)
        guard !part.isEmpty, part.count < whole.count else { return false }
        var at = 0, misses = 0
        for word in part {
            guard let found = whole[at...].firstIndex(where: { matches($0, word) }) else {
                misses += 1
                if misses > 1 { return false }
                continue
            }
            at = found + 1
        }
        return at > 0
    }

    /// Okumanın bütün sözcükleri ekrandakinde geçiyor ama ekrandakinin bir sözcüğü kayıp (simge onun yerine okunmuş).
    static func losesWords(_ reading: String, _ shown: String) -> Bool {
        let have = words(reading)
        let whole = words(shown)
        return !have.isEmpty
            && whole.contains { word in !have.contains { matches($0, word) } }
            && have.allSatisfy { word in whole.contains { matches($0, word) } }
    }

    /// Okumadan çevrilecek parçalar: kumanda ipuçları, yazı tanıma çöpleri ve harfsiz göstergeler ("23m", "9") atılır;
    /// satırlar yukarıdan aşağı parçalara toplanır (başlık, cümle, madde). Yazının içindeki kumanda simgeleri `frame`'den
    /// (okunan alan) kesilir; çeviride yerleri korunur.
    /// `auto`: otomatik bulunmuş alan; her yazı grubu (tek grup da) blok olur ve özgün stili çıkarılır.
    /// `menu`: otomatik alan menüde; satır yükseklikleri farklı olabilir (başlık, etiket).
    /// `styled`: ek alan (oyunun hazır alanı `GameAreaPresets` ya da kullanıcının alanı, #1324): otomatik alan gibi her grup kendi bloğu, özgün stilinde; saat ve
    /// sayaç ("12:00 pm") çevrilmez. Önceden hazır alanın çevirisi tek siyah kutuda görev resminin de üstünü örtüyordu (#856).
    /// `kind`: alanın yerinden belli türü (`ScreenTextKind.of(area)`); otomatik alanda grupların çizim kipini seçer.
    /// `screen`: bütün kare (verilirse çizim kipi ve boş alan onda ölçülür; `frame` yalnız okunan alandır).
    static func candidate(_ reading: Reading, in region: CropRegion, frame: CGImage? = nil, auto: Bool = false,
                          menu: Bool = false, styled: Bool = false, kind: ScreenTextKind? = nil,
                          screen: ScreenFrame? = nil) -> Candidate {
        let styled = auto || styled
        // Otomatik alanda (menü, kontrol şeması) tuşlu etiketler ("HOLSTER (L1)", "SELECT (✕)") yazının kendisidir, atılmaz.
        let marked = reading.withButtonIcons(frame: frame, monochrome: auto)
        // Menü şeridinin sekmeleri tek satır okunsa da ayrı satırlardır (#859); kutular alana oranlı.
        let aspect = (region.right - region.left) * 16 / max(1e-6, (region.bottom - region.top) * 9)
        // Otomatik alanda ürün/ambalaj yazısı (bira kutusu, süt kartonu; sahnede, desenli zeminde) ekran yazısı değildir
        // (`PackageText`, Sinan Bey beta.101: buzdolabındaki ambalajların yazıları ürünlerin üstüne çiziliyordu).
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let unpacked = (auto ? marked : marked.withoutButtonPrompts()).withoutOcrNoise()
        let cleaned = (auto && kind != .phone ? PackageText.filter(unpacked, in: place, look: frame.map(PackageText.sampler)).kept
            : unpacked).lines
        // Otomatik alanda aynı satırın yan yana okunan parçaları (simgeden, renkli addan bölünen cümle) tek satırdır.
        var read = (auto ? joinedPieces(cleaned, aspect: aspect) : cleaned)
            // Menü satırının başındaki görev simgesi ("KM", "KK"; daire içinde harfler) yazı değildir (#1365).
            .map { auto && menu ? ScreenTranslation.withoutBadge($0) : $0 }
            .flatMap { ScreenTranslation.menuPieces($0, aspect: aspect, frame: frame) }
            .filter { ScreenTranslation.isWords($0.text) }
            // Otomatik alanda yayın katmanı (logo, alan adı, "Canlı"), karenin kenarında kesilmiş tek sözcük, menüde alanın
            // kenarında kesilmiş satır ve bozuk okuma (düşük güven, tuhaf harfler) atılır.
            .filter { !auto || !(ScreenTextNoise.isOverlay($0.text) || cutAtEdge($0)
                || (menu && cutAtAreaEdge($0, region: region)) || ScreenTextNoise.isGarbled($0)) }
            .filter { !styled || !ScreenTranslation.isClock($0.text) }
            .sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
        // Menüde güveni düşük okunan satır (bozuk okuma: "scarch rol the onuin Ape", "AUD MARNER") çeviri motoruna gitmez;
        // satır bu okumada yok sayılır, gösterilen çevirisi yerinde kalır, temiz okumada çevrilir (#1365).
        var unsure: [String] = []
        if auto && menu {
            unsure = read.filter(ScreenTextNoise.isUnsure).map(\.text)
            read.removeAll(where: ScreenTextNoise.isUnsure)
        }
        // Aynı yazının iki okunuşu tek satır kalır; satırın başındaki/sonundaki simge kutunun dışında kalır (#827;
        // "Ekranı çevir" ile aynı). Kenardaki kumanda simgesi ("RECENTER L3") çeviriye girmez, görünür kalır (#860).
        // Otomatik alanda etiketin sonuna tuş simgesinden okunan tek harf ("RADIO CONTROLS f") çeviriye girmez (#1362).
        let lines = ScreenTranslation.withoutDuplicateLines(read.map(ScreenTranslation.withoutEdgeMarks)
            .map(ScreenTranslation.withoutEdgeIcons)
            .map { line in
                guard auto else { return line }
                var line = line
                line.text = UiCommands.withoutKeyGlyph(line.text)
                return line
            })
        var paragraphs = ScreenTranslation.paragraphs(lines)
        let boxes = lines.compactMap(\.box)
        let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }?.placed(in: place)
        let height = region.bottom - region.top
        let heights = boxes.map { ($0.bottom - $0.top) * height }.sorted()
        let lineHeight = heights.isEmpty ? nil : heights[heights.count / 2]
        var key = textKey(paragraphs)
        var icons = ScreenTranslation.paragraphIcons(lines)
        // Alanda birbirinden ayrı duran yazılar (başlık ile ayrı sütundaki hedef, alt alta iki bildirim) "Ekranı çevir"deki
        // gibi gruplanır; her grubun çevirisi TV'de kendi yerine konur. Tek grupta (ya da yeri bilinmeyen satır varsa)
        // eskisi gibi tek kutu. Anahtar grup yapısını da içerir: aynı yazı farklı gruplanırsa bloklar yeniden kurulur.
        var blocks: [Block]?
        // Görev kartı her alanda kendi parçalarına ayrılır (başlık, açıklama): hazır ya da kullanıcının alanında da başlık
        // açıklamaya katılıp ikisi tek kutuda, görev resminin üstünde çiziliyordu (#856).
        let cards = !lines.isEmpty && boxes.count == lines.count ? MissionCard.find(lines, place: place) : []
        let groups: [ScreenTranslation.Group]
        if (styled || lines.count > 1) && !lines.isEmpty && boxes.count == lines.count {
            if styled {
                groups = autoGroups(lines, menu: menu, cards: cards)
            } else {
                let taken = Set(cards.flatMap(\.all))
                groups = (cards.flatMap { MissionCard.groups($0, lines) }
                    + ScreenTranslation.groups(from: lines.indices.filter { !taken.contains($0) }.map { lines[$0] }))
                    .sorted { $0.box.top < $1.box.top }
            }
        } else {
            groups = []
        }
        if (styled && !groups.isEmpty) || (groups.count > 1 && groups.count < ScreenTranslation.maxGroups) {
            paragraphs = groups.flatMap(\.paragraphs)
            icons = groups.flatMap { $0.icons ?? $0.paragraphs.map { _ in [IconSlot]() } }
            var list: [Block] = []
            var start = 0
            for group in groups {
                var style: PhoneTextStyle?
                var look: TextLook?
                if styled, let frame {
                    // Çeviri özgün yazının stilinde çizilsin: renkler, kalınlık, dar aile, hiza, büyük harf.
                    let own = lines.filter { inside($0.box!, group.box) }
                    (style, look) = TextStyleSampler.sample(frame, box: group.box, lines: own,
                                                            source: group.paragraphs.joined(separator: " "))
                }
                list.append(Block(start: start, count: group.paragraphs.count, box: group.box.placed(in: place),
                                  lineHeight: group.lineHeight * height, style: style, look: look, rows: group.rows))
                start += group.paragraphs.count
            }
            list = styled ? alignByNeighbours(list) : list
            // Yerinde birebir çizim: örtü kutusu, zemin/degrade, satır aralığı, boş alan ve grup bütün karede ölçülür
            // (`screen`; yoksa okunan alanın karesinde, alan koordinatında, sonra karedeki yere taşınır). Okuma turunda bir
            // kez (her karede değil). Okunan alan yazının karolarından yalnız bir karo geniştir: yanına yazmanın boş alanı
            // alanın kenarında bitiyordu; GTA 6 duraklatma menüsünde en uzun satır ("Photo Studio") sağa sığmayıp örtülüyor,
            // ayrı alana düşen "Settings" altına yazılıyordu (#1339). Ortak deneme kareleri de bütün karede ölçer.
            if styled, let frame {
                let whole = screen
                let painted = list.indices.filter { list[$0].style != nil && list[$0].look != nil }
                let targets = painted.map { i -> TextPainter.Target in
                    let group = groups[i], block = list[i]
                    let rows = group.paragraphs.count > 1 ? max(2, group.rows) : group.rows
                    let joined = group.paragraphs.joined(separator: " ")
                    return TextPainter.Target(box: whole == nil ? group.box : group.box.placed(in: place),
                                              lineHeight: whole == nil ? group.lineHeight : group.lineHeight * height, rows: rows,
                                              background: block.style!.background, foreground: block.style!.foreground,
                                              upper: block.look!.upper, align: block.look!.align,
                                              words: TextPainter.words(joined),
                                              kind: Self.paintKind(group, lines: lines, cards: cards, area: kind),
                                              prompt: joined.contains(ButtonIcons.marker) || ButtonPrompts.isPrompt(IconText.plain(joined)))
                }
                // Kare bir kez çizilir (ölçüm ve kişi resmi aynı noktalardan; bütün kare turda bir kez, `ScreenFrame`).
                let pixels = whole != nil ? whole!.measured() : GamePhonePixels(frame)
                var paints = pixels.map { TextPainter.paints(targets, pixels: $0) } ?? []
                for k in paints.indices {
                    if let face = paints[k].portrait, let pixels { paints[k].portraitImage = TextPainter.portraitImage(face, pixels: pixels) }
                }
                for (k, i) in painted.enumerated() where k < paints.count {
                    list[i].paint = whole == nil ? paints[k].placed(in: place) : paints[k]
                    // Kutunun ucunda simge varsa yazı simgeye yaslanır (#1266: "SEÇ" tuş simgesinin yanında).
                    if let side = paints[k].iconSide { list[i].look?.align = side }
                    // Simgesi kutuya katılan kısa etiketin dar yazısı simgesiz harf genişliğiyle yeniden ölçülür (#1360).
                    if paints[k].iconSide != nil, list[i].look?.condensed == false, groups[i].paragraphs.count == 1,
                       let cover = list[i].paint?.cover {
                        let width = (cover.right - cover.left) / max(1e-9, region.right - region.left) * Double(frame.width)
                        let characters = TextStyleSampler.characters(IconText.plain(groups[i].paragraphs[0]))
                        list[i].look?.condensed = TextStyleSampler.isCondensed(
                            width: width, height: groups[i].lineHeight * Double(frame.height), characters: characters)
                    }
                }
                list = Self.condensedTogether(list)
            }
            // Görev/hedef satırı altyazıdan ve öbür ekran yazılarından ayrı görünür: koyu kehribar kutu, başında hedef imi
            // (`MissionLine.style`, `MissionLine.marker`). Yerinde birebir çizim (örtü/yanına yazma) uygulanmaz; kutu
            // görevin kendi yerindedir (#1273). TV ve dört platformun önizlemesi bunu öğenin zemininden çizer.
            if kind == .mission {
                for i in list.indices {
                    list[i].mission = true
                    list[i].style = MissionLine.style
                    list[i].paint = nil
                }
            }
            blocks = list
            key = textKey(paragraphs) + "|" + list.map { String($0.count) }.joined(separator: ",")
        }
        var cut: [[IconSlot]]?
        if let frame, icons.contains(where: { !$0.isEmpty }) {
            cut = icons.map { ButtonIcons.withImages($0, frame: frame) }
        }
        let missionCard = cards.contains { card in
            let own = card.all.compactMap { lines[$0].box }
            return !MissionCard.inHelpCorner(own.dropFirst().reduce(own[0]) { $0.union($1) }.placed(in: place))
        }
        return Candidate(paragraphs: paragraphs, box: box, lineHeight: lineHeight, key: key, icons: cut, blocks: blocks,
                         text: textKey(paragraphs), missionCard: missionCard, unsure: unsure)
    }

    /// Günlük için blokların çizim kipi ve boyu (kareye oranla yüzde, genişlik×yükseklik): "ikiz 43.8×33.9 (yazı 9.1×3.9)",
    /// "yan 6.3×3.9", "örtü 6.3×3.9". Tuş istemi ekranın altında dev bir ikiz kutuda çiziliyordu (beta.103, TCL Android
    /// TV); sonraki günlük kutunun boyunu gösterir. Windows PaintSummary, Android paintSummary aynı.
    static func paintSummary(_ blocks: [Block]) -> String? {
        func size(_ b: TextBox) -> String {
            String(format: "%.1f×%.1f", (b.right - b.left) * 100, (b.bottom - b.top) * 100)
        }
        let parts = blocks.compactMap { block -> String? in
            guard let paint = block.paint else { return nil }
            switch paint.mode {
            case .twin: return "ikiz \(paint.twin.map(size) ?? "?") (yazı \(size(paint.cover)))"
            case .beside: return "yan \(paint.spot.map(size) ?? "?")"
            case .cover: return "örtü \(size(paint.cover))"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Menüdeki otomatik alanla kesişen hazır alan (GTA 6 sağdaki mesaj kartı alanı haritanın tuş listesine biniyor) o turda
    /// okunmaz: liste iki alana bölünüp yarısı hazır alanda (ayrı grup, ayrı yazı boyu, örtme), yarısı menü alanında
    /// çiziliyor, bölünme yerindeki satır ("ADD MARKER") hiç çevrilmiyordu (beta.100, 3385). Windows ve Android aynı.
    static func yieldingPresets(_ areas: [ExtraArea]) -> [ExtraArea] {
        let menus = areas.filter { $0.auto && $0.menu }.map(\.region)
        guard !menus.isEmpty else { return areas }
        return areas.filter { area in
            !GameAreaPresets.isPreset(area.id) || !menus.contains { m in
                let r = area.region
                return min(r.right, m.right) > max(r.left, m.left) && min(r.bottom, m.bottom) > max(r.top, m.top)
            }
        }
    }

    /// Otomatik alandaki grubun çizim kipini seçen türü (`TextPainter.Target.kind`): alanın yerinden belli türü (menü,
    /// telefon, yardım köşesi, görev satırı), haritanın görev kartının parçası görev/hedef, kalanı okunan yazıdan
    /// (`ScreenTextKind.of(paragraphs:)`). Windows (RegionWatcher.PaintKind) ve Android (paintKind) aynı.
    static func paintKind(_ group: ScreenTranslation.Group, lines: [TextLine], cards: [MissionCard.Card],
                          area: ScreenTextKind?) -> ScreenTextKind {
        if let area { return area }
        let card = cards.contains { card in card.all.contains { lines[$0].box.map { inside($0, group.box) } ?? false } }
        return card ? .mission : ScreenTextKind.of(paragraphs: group.paragraphs)
    }

    /// Seçim kaydı (#1267): gösterilen bir kutunun yerindeki (satırının en az yarısı örtüşen) yeni bloğun zemini öbür
    /// tonda (biri açık, öbürü koyu: seçili menü satırının ters rengi). Windows ve Android aynı kuralı uygular.
    static func selectionMoved(rendered: [ScreenTranslation.Item], current: [Block]) -> Bool {
        func light(_ hex: String) -> Bool? {
            guard let (r, g, b) = SpeakerColors.rgb(hex) else { return nil }
            return 0.299 * r + 0.587 * g + 0.114 * b > 0.5
        }
        return rendered.contains { item in
            guard let before = item.style.flatMap({ light($0.background) }) else { return false }
            return current.contains { block in
                guard let now = block.style.flatMap({ light($0.background) }), now != before else { return false }
                let a = item.box, b = block.box
                let rows = max(0, min(a.bottom, b.bottom) - max(a.top, b.top)) / max(1e-9, min(a.bottom - a.top, b.bottom - b.top))
                return rows >= 0.5 && min(a.right, b.right) > max(a.left, b.left)
            }
        }
    }

    /// Aynı gruptaki (`TextPaint.group`: tuş çubuğu, menü sütunu) etiketlerden biri dar yazıysa hepsi dar yazıyla çizilir:
    /// tuş çubuğunda kimi etiket dar, kimi geniş yazı tipiyle çiziliyordu (#1360). Windows ve Android aynı.
    static func condensedTogether(_ blocks: [Block]) -> [Block] {
        let narrow = Set(blocks.compactMap { $0.look?.condensed == true ? $0.paint?.group : nil })
        guard !narrow.isEmpty else { return blocks }
        return blocks.map { block in
            guard let group = block.paint?.group, narrow.contains(group), block.look != nil else { return block }
            var block = block
            block.look?.condensed = true
            return block
        }
    }

    /// Satır farkı (#1359, #1362): seçim ya da liste kaydında gösterilen satırlardan hangileri kalır.
    /// - Yazısı yeni okumada da olan satır (okuma oynamaları aynı yazı sayılır) kalır; yeni yeri o bloktur (`current`).
    ///   Liste kaymadıysa blok satırın yerinde (satırının en az yarısı örtüşen) olmalı; kaydıysa aynı yazının en yakın yeri.
    /// - Yeni okumada olmayan satır (seçili satırın soluk yazısı o tur okunamadı) liste kaymadıysa ve yerinde başka yazı
    ///   yoksa yerinde kalır (`current` nil); liste kaydıysa kalkar.
    /// `fresh`: gösterilen hiçbir satıra denk gelmeyen yeni bloklar. Windows ve Android aynı kuralı uygular.
    static func carriedRows(rendered: [ScreenTranslation.Item], current: [(box: TextBox, text: String)],
                            listMoved: Bool) -> (kept: [(rendered: Int, current: Int?)], fresh: [Int]) {
        func same(_ a: String, _ b: String) -> Bool {
            let x = IconText.plain(a).replacingOccurrences(of: "\n", with: " ")
            let y = IconText.plain(b).replacingOccurrences(of: "\n", with: " ")
            return matches(textKey([x]), textKey([y])) || isPartOf(x, y) || isPartOf(y, x)
        }
        func rows(_ a: TextBox, _ b: TextBox) -> Double {
            max(0, min(a.bottom, b.bottom) - max(a.top, b.top)) / max(1e-9, min(a.bottom - a.top, b.bottom - b.top))
        }
        func across(_ a: TextBox, _ b: TextBox) -> Bool { min(a.right, b.right) > max(a.left, b.left) }
        var taken = Set<Int>()
        var kept: [(rendered: Int, current: Int?)] = []
        for (r, item) in rendered.enumerated() {
            let source = item.source
            let found = current.indices.filter { c in
                !taken.contains(c) && same(current[c].text, source) && across(current[c].box, item.box)
                    && (listMoved || rows(current[c].box, item.box) >= 0.5)
            }
            if let c = found.min(by: { abs(current[$0].box.top - item.box.top) < abs(current[$1].box.top - item.box.top) }) {
                taken.insert(c)
                kept.append((r, c))
                continue
            }
            let occupied = current.contains { rows($0.box, item.box) >= 0.5 && across($0.box, item.box) }
            if !listMoved, !occupied, source.contains(where: \.isLetter) { kept.append((r, nil)) }
        }
        let fresh = current.indices.filter { c in
            !taken.contains(c) && current[c].text.contains(where: \.isLetter)
        }
        return (kept, fresh)
    }

    /// Bu turda okunamayan (yerinde tutulan) satırın stili kendi yerinden, şimdiki kareden yeniden örneklenir: seçim
    /// satırdan ayrılınca çevirisi seçili satırın renginde kalıyordu (#1359). `frame` okunan alan, `region` onun karedeki yeri.
    static func restyled(_ item: ScreenTranslation.Item, frame: CGImage, region: CropRegion) -> ScreenTranslation.Item {
        guard item.style != nil else { return item }
        let w = max(1e-9, region.right - region.left), h = max(1e-9, region.bottom - region.top)
        let local = TextBox(left: (item.box.left - region.left) / w, top: (item.box.top - region.top) / h,
                            right: (item.box.right - region.left) / w, bottom: (item.box.bottom - region.top) / h)
        let (surface, _) = TextStyleSampler.sample(frame, box: local, lines: [], source: item.source)
        var item = item
        item.style = surface
        if var paint = item.paint, paint.mode == .cover {
            paint.background = surface.background
            paint.background2 = nil
            paint.direction = nil
            item.paint = paint
        }
        return item
    }

    /// Satır farkında yeni beliren satır: çevirisi önbellekte (etiket sözlüğü ya da daha önce çevrilmiş etiket) varsa
    /// hemen çizilir; yoksa nil (okuma doğrulanınca çevrilir).
    private func freshRow(_ block: Block, text: String) -> ScreenTranslation.Item? {
        guard !text.contains(ButtonIcons.marker) else { return nil }
        let core = text.trimmingCharacters(in: .whitespaces)
        guard var translation = terms[core] ?? (translatesUiCommands ? UiCommands.translateLabelLoosely(core) : nil) else { return nil }
        if block.look?.upper == true { translation = TextStyleSampler.turkishUpper(translation) }
        var item = ScreenTranslation.Item(source: core, translation: translation, box: block.box, lineHeight: block.lineHeight)
        item.style = block.style
        item.look = block.look
        item.paint = block.paint
        item.rows = max(item.rows, block.rows)
        return item
    }

    /// Adayın blokları: karedeki yeri ve yazısı (bloğun parçaları birleşik).
    static func blockTexts(_ candidate: Candidate) -> [(box: TextBox, text: String)] {
        (candidate.blocks ?? []).map { block in
            let end = min(candidate.paragraphs.count, block.start + block.count)
            let text = block.start < end ? candidate.paragraphs[block.start..<end].joined(separator: " ") : ""
            return (block.box, text)
        }
    }

    /// Liste kaydı: gösterilen bir kutunun yazısı yeni okumada satır yüksekliğinin en az yarısı kadar başka yerde, ya da
    /// kutunun yerinde (satırının en az yarısı örtüşen) başka bir yazı var. Okuma oynamaları (benzer okuma, eksik okuma)
    /// aynı yazı sayılır. Windows ve Android aynı kuralı uygular.
    static func listMoved(rendered: [ScreenTranslation.Item], current: [(box: TextBox, text: String)]) -> Bool {
        func same(_ a: String, _ b: String) -> Bool {
            let x = IconText.plain(a), y = IconText.plain(b)
            return matches(textKey([x]), textKey([y])) || isPartOf(x, y) || isPartOf(y, x)
        }
        func rows(_ a: TextBox, _ b: TextBox) -> Double {
            max(0, min(a.bottom, b.bottom) - max(a.top, b.top)) / max(1e-9, min(a.bottom - a.top, b.bottom - b.top))
        }
        return rendered.contains { item in
            let source = item.source
            guard source.contains(where: \.isLetter) else { return false }
            let height = item.box.bottom - item.box.top
            let found = current.filter { same($0.text, source) && min($0.box.right, item.box.right) > max($0.box.left, item.box.left) }
            if let nearest = found.min(by: { abs($0.box.top - item.box.top) < abs($1.box.top - item.box.top) }) {
                let line = min(height, nearest.box.bottom - nearest.box.top) / Double(max(1, item.rows))
                return abs(nearest.box.top - item.box.top) >= 0.5 * line
            }
            return current.contains { block in
                rows(block.box, item.box) >= 0.5 && min(block.box.right, item.box.right) > max(block.box.left, item.box.left)
                    && !same(block.text, source)
            }
        }
    }

    /// Kısa etiket satırı (menü satırı, tuş etiketi): en çok bu kadar sözcük (Windows: ScreenTranslation.MenuLabelWords).
    static let labelWords = 5

    /// Otomatik alanın grupları: kısa etiket satırları (menü satırı, tuş etiketi) her biri kendi bloğudur; stili (seçili
    /// satırın ters rengi) satır başına çıkarılır. Uzun yazı satırları eskisi gibi paragraflara toplanır.
    ///
    /// `cards`: satırlardaki görev kartları (`MissionCard.find`); kartın parçaları kendi bloklarıdır (başlık, alt başlık,
    /// açıklama, ayrıntı), kalan satırlar her zamanki gibi.
    static func autoGroups(_ lines: [TextLine], menu: Bool = false, cards: [MissionCard.Card] = []) -> [ScreenTranslation.Group] {
        func isLabel(_ line: TextLine) -> Bool { line.text.split(whereSeparator: \.isWhitespace).count <= labelWords }
        func isTitle(_ line: TextLine) -> Bool { line.text.contains(where: \.isLetter) && !line.text.contains(where: \.isLowercase) }
        func single(_ line: TextLine) -> ScreenTranslation.Group {
            let icons = ScreenTranslation.paragraphIcons([line])
            let box = line.box!
            return ScreenTranslation.Group(paragraphs: ScreenTranslation.paragraphs([line]), box: box,
                                           lineHeight: box.bottom - box.top, icons: icons.contains { !$0.isEmpty } ? icons : nil)
        }
        // Gruplar önce birlikte kurulur (gerçek kare doğrulaması: sarılmış cümlenin kısa son satırı "cash. Meet her at
        // Delights." ayrı blok olup ayrı çevriliyordu). Bütün satırları kısa etiket olan grup (menü sütunu) satır satır
        // bloktur; uzun satırı olan grup paragraftır, başındaki BÜYÜK HARF başlık ise kendi bloğudur (stili ayrı).
        var groups = cards.flatMap { MissionCard.groups($0, lines) }
        let taken = Set(cards.flatMap(\.all))
        let rest = lines.indices.filter { !taken.contains($0) }.map { lines[$0] }
        for group in ScreenTranslation.groups(from: rest) {
            let own = rest.filter { inside($0.box!, group.box) }
            if own.allSatisfy(isLabel) {
                groups += own.map(single)
                continue
            }
            // Arayüz yazısı perspektifsizdir: menü dışında satır yükseklikleri ±%15'ten çok farklı paragraf (eğik ya da ölçekli
            // dünya yazısı: poster, tabela) çevrilmez (Windows ile aynı).
            let heights = own.filter { !isLabel($0) }.map { $0.box!.bottom - $0.box!.top }
            if !menu, heights.count >= 2, heights.max()! > heights.min()! * (1.15 / 0.85) { continue }
            let titles = Array(own.prefix { isTitle($0) && isLabel($0) })
            groups += titles.map(single)
            if titles.isEmpty { groups.append(group) }
            else { groups += ScreenTranslation.groups(from: Array(own.dropFirst(titles.count))) }
        }
        return readingOrder(groups)
    }

    /// Grupların okuma sırası (#1372): tek satırlık gruplar dikeyde en az yarısı örtüşüyorsa aynı satırdadır, satır içi
    /// soldan sağa, satırlar yukarıdan aşağı. Önceden yalnız üst kenara göre diziliyordu: sekme şeridinde üst kenar
    /// seçili sekmenin rengi, uçtaki simge ve okuma oynamasıyla bir iki nokta oynuyor, sekmeler her karede başka sırada
    /// diziliyor; anahtar değişip çeviri yeniden kuruluyor, şerit yanıp sönüyordu. Çok satırlı grup (paragraf) satıra
    /// katılmaz; eşitlikte özgün sıra korunur. Windows ve Android aynı.
    static func readingOrder(_ groups: [ScreenTranslation.Group]) -> [ScreenTranslation.Group] {
        func single(_ group: ScreenTranslation.Group) -> Bool { group.paragraphs.count == 1 && group.rows <= 1 }
        func sameRow(_ a: TextBox, _ b: TextBox) -> Bool {
            max(0, min(a.bottom, b.bottom) - max(a.top, b.top)) >= 0.5 * min(a.bottom - a.top, b.bottom - b.top)
        }
        let sorted = groups.enumerated().sorted {
            ($0.element.box.top, $0.element.box.left, $0.offset) < ($1.element.box.top, $1.element.box.left, $1.offset)
        }
        var rows: [[(offset: Int, element: ScreenTranslation.Group)]] = []
        for item in sorted {
            if single(item.element), let r = rows.firstIndex(where: { row in
                row.allSatisfy { single($0.element) } && row.contains { sameRow($0.element.box, item.element.box) }
            }) {
                rows[r].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.flatMap { row in
            row.sorted { ($0.element.box.left, $0.offset) < ($1.element.box.left, $1.offset) }.map(\.element)
        }
    }

    /// Tek satırlık etiketin hizası komşularından: sağ kenarı başka etiketlerle hizalıysa (kol resminin solundaki tuş
    /// etiketleri) sağa, sol kenarı hizalıysa sola, ortası hizalıysa ortaya yaslıdır.
    static func alignByNeighbours(_ blocks: [Block]) -> [Block] {
        let tolerance = 0.012
        return blocks.enumerated().map { index, block in
            guard var look = block.look, block.count == 1 else { return block }
            let others = blocks.enumerated().filter { $0.offset != index }.map(\.element)
            let left = others.filter { abs($0.box.left - block.box.left) < tolerance }.count
            let right = others.filter { abs($0.box.right - block.box.right) < tolerance }.count
            let middle = (block.box.left + block.box.right) / 2
            let center = others.filter { abs(($0.box.left + $0.box.right) / 2 - middle) < tolerance }.count
            if right > left && right >= center { look.align = .right }
            else if center > left && center > right { look.align = .center }
            else if left > 0 { look.align = .left }
            else if let lone = ScreenFit.loneAlign(block.box, rows: block.rows) { look.align = lone }
            var aligned = block
            aligned.look = look
            return aligned
        }
    }

    /// Tek sözcüklük satır alanın sol ya da sağ kenarına değiyor: kesilmiş bir yazının parçası ("KELI").
    static func cutAtEdge(_ line: TextLine) -> Bool {
        guard let box = line.box, !IconText.plain(line.text).trimmingCharacters(in: .whitespaces).contains(" ") else { return false }
        // Otomatik alan yazının dışına kadar genişletilir: kenara değen sözcük alanın (ya da karenin) dışından taşıyor.
        return box.left <= 0.005 || box.right >= 0.995
    }

    /// Menüdeki otomatik alanın sol ya da sağ kenarına (karenin kenarı değilse) `areaEdgeTiles` karodan yakın değen satır
    /// alanın dışına taşıyor: uzun satırın bir parçasıdır. Alan yazının karolarından bir karo geniş tutulur; içindeki
    /// yazı kenara değmez. Sinan Bey beta.100 (3381-3383): "What's your problem, as" / "You better be fucking" / "in
    /// just about every facilit" yarım okunup kalan parçası ayrı blok sanılıyor, yanına küçük kutuyla çevriliyordu
    /// ("Delik", "bunun bedelini ödemek!"). Kesik satır çevrilmez; bütün okunduğu alanda (liste kayınca) çevrilir.
    static func cutAtAreaEdge(_ line: TextLine, region: CropRegion) -> Bool {
        guard let box = line.box else { return false }
        let width = region.right - region.left
        guard width > 0 else { return false }
        let margin = areaEdgeTiles / Double(ScreenTextDetector.columns) / width
        return (region.left > 0.001 && box.left <= margin) || (region.right < 0.999 && box.right >= 1 - margin)
    }

    /// `cutAtAreaEdge` payı (karo genişliği cinsinden).
    static let areaEdgeTiles = 0.25

    /// Aynı satırda yan yana okunan parçalar (dikeyde küçüğün %60'ı örtüşür, yazı boyları 1,3 kattan az farklı, aradaki
    /// boşluk satır yüksekliğinin en çok `pieceGap` katı) soldan sağa tek satır olur; en az birinde küçük harf olmalı
    /// (BÜYÜK HARFLİ sekmeler ve tuş etiketleri ayrı kalır, `menuPieces`). Yazı tanıma uzun satırı satır içi simgeden ya da
    /// renkli konuşan adından bölüyor, parçalar ayrı blok olup ayrı ayrı çevriliyordu (Sinan Bey beta.100 3380: "görmek
    /// için", "Ev" yardım paragrafının içine küçük kutularla biniyordu). `aspect`: alanın genişlik/yükseklik oranı.
    static func joinedPieces(_ lines: [TextLine], aspect: Double) -> [TextLine] {
        guard lines.count > 1, lines.allSatisfy({ $0.box != nil }) else { return lines }
        var rows: [TextLine] = []
        for line in lines.sorted(by: { $0.box!.left < $1.box!.left }) {
            let box = line.box!
            if let index = rows.firstIndex(where: { pieceOf(box, line.text, $0, aspect: aspect) }) {
                let row = rows[index]
                var joined = TextLine(row.text + " " + line.text, box: row.box!.union(box),
                                      confidence: [row.confidence, line.confidence].compactMap { $0 }.min())
                if let a = row.words, let b = line.words { joined.words = a + b }
                let icons = (row.icons ?? []) + (line.icons ?? [])
                joined.icons = icons.isEmpty ? nil : icons
                rows[index] = joined
            } else {
                rows.append(line)
            }
        }
        return rows.count == lines.count ? lines : rows.sorted { ($0.box!.top, $0.box!.left) < ($1.box!.top, $1.box!.left) }
    }

    /// `pieceGap`: parçalar arası boşluk (satır yüksekliğine oranla); satır içi simge ve iki yanındaki boşluklar sığar.
    static let pieceGap = 2.5

    private static func pieceOf(_ next: TextBox, _ text: String, _ row: TextLine, aspect: Double) -> Bool {
        let box = row.box!
        let a = next.bottom - next.top, b = box.bottom - box.top
        guard min(a, b) > 0, max(a, b) <= 1.3 * min(a, b),
              min(next.bottom, box.bottom) - max(next.top, box.top) >= 0.6 * min(a, b) else { return false }
        guard text.contains(where: \.isLowercase) || row.text.contains(where: \.isLowercase) else { return false }
        // Tuş çubuğu ("◯ Back  ✕ Select"): her parça kendi başına bir istemse ayrı kalır, ayrı küçük etiket olarak çizilir.
        if ButtonPrompts.isBarPiece(text) && ButtonPrompts.isBarPiece(row.text) { return false }
        let gap = (next.left - box.right) * aspect
        return gap >= -0.5 * max(a, b) && gap <= pieceGap * max(a, b)
    }

    private static func inside(_ line: TextBox, _ group: TextBox) -> Bool {
        let x = (line.left + line.right) / 2, y = (line.top + line.bottom) / 2
        return x >= group.left - 1e-6 && x <= group.right + 1e-6 && y >= group.top - 1e-6 && y <= group.bottom + 1e-6
    }

    /// Okunan yazı arayüz etiketi mi: bütün parçaları arayüz sözlüğünde (yalnız İngilizceden Türkçeye) ya da parçalarından
    /// birinde kareden kesilmiş tuş simgesi var (ipucu: "EXIT ○").
    func isUiLabel(_ candidate: Candidate) -> Bool { Self.isUiLabel(candidate, uiCommands: translatesUiCommands) }

    static func isUiLabel(_ candidate: Candidate, uiCommands: Bool) -> Bool {
        if candidate.icons?.contains(where: { !$0.isEmpty }) == true { return true }
        guard uiCommands, !candidate.paragraphs.isEmpty else { return false }
        return candidate.paragraphs.allSatisfy { UiCommands.translateLabelLoosely(IconText.plain($0)) != nil }
    }

    /// Otomatik alandaki yazının türü: haritanın görev kartı (menüde de) görevdir; yoksa alanın yerinden (hazır alan, görev
    /// satırı, menü) ya da okunan yazıdan çıkar. Kullanıcının kendi alanı nil (her zaman çevrilir).
    static func kind(_ area: ExtraArea, _ candidate: Candidate) -> ScreenTextKind? {
        if area.auto, candidate.missionCard { return .mission }
        if let kind = ScreenTextKind.of(area) { return kind }
        return area.auto ? ScreenTextKind.of(paragraphs: candidate.paragraphs) : nil
    }

    /// Kararlı yazı: öncekinden farklıysa çevrilip gönderilir, boşsa kutu kalkar.
    private func commit(_ candidate: Candidate, area: ExtraArea) async {
        guard var state = states[area.id] else { return }
        // Menü dışındaki otomatik alanın türü okunan yazıdan çıkar (yardım/eylem ya da diğer); kapalı tür gürültü gibi
        // çizilmez, dedektöre bildirilir.
        if area.auto, area.menu, !candidate.missionCard, ScreenTextKind.isHud(candidate.paragraphs) { onAutoHud?(area.id) }
        let unwanted = area.auto && (Self.kind(area, candidate).map { !allows($0) } ?? false)
        // Arayüz sözlüğündeki tek sözcüklük menü/ipucu etiketi ("Map", "Settings", "EXIT") ve tuş simgeli ipucu kısa olsa da
        // menü etiketi gibi çevrilir: kısa metin filtresi (en az 8 harf, iki sözcük) menü durumu kısa süre kaçınca onları
        // atıyordu (Sinan Bey, beta.93: "Map", "Settings", "EXIT" İngilizce kaldı).
        let labelLike = area.menu || isUiLabel(candidate)
        if area.auto, candidate.key.isEmpty || ScreenTextNoise.isNoise(candidate.paragraphs.joined(separator: " "), menu: labelLike)
            || (!area.menu && isWorldText(candidate)) || unwanted {
            // Kendiliğinden bulunan alanda yazı yok ya da gürültü (sayaç, harita, kısa etiket): çevrilmez, dedektöre
            // bildirilir; o görüntü değişmedikçe alan yeniden önerilmez.
            if !state.shown.isEmpty || !(state.renderedText ?? "").isEmpty {
                server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            }
            state.shown = candidate.key
            state.shownText = candidate.text
            state.renderedKey = candidate.key
            state.renderedText = ""
            state.renderedBox = nil
            state.renderedLineHeight = nil
            states[area.id] = state
            onAutoRejected?(area.id)
            return
        }
        if state.shown == candidate.key {
            guard state.renderedKey == candidate.key,
                  let renderedText = state.renderedText, !renderedText.isEmpty else { return }
            guard state.renderedBox != candidate.box || state.renderedLineHeight != candidate.lineHeight
                    || state.renderedLayout != candidate.blocks else { return }
            // Aynı yazı kaydı: çeviriler korunur, bloklar yeni yerlerine taşınır (anahtar aynıysa grup sayısı da aynıdır).
            var moved: [(group: Int, item: ScreenTranslation.Item)]?
            if let rendered = state.renderedBlocks, let current = candidate.blocks {
                moved = rendered.map { block -> (group: Int, item: ScreenTranslation.Item) in
                    var item = block.item
                    guard current.indices.contains(block.group) else { return block }
                    item.box = current[block.group].box
                    item.lineHeight = current[block.group].lineHeight
                    // Seçim gezince yalnız renkler değişir: çeviri yeniden istenmez, zemin/yazı rengi güncellenir.
                    item.style = current[block.group].style ?? item.style
                    item.look = current[block.group].look ?? item.look
                    item.paint = current[block.group].paint ?? item.paint
                    return (block.group, item)
                }
            }
            server.sendRegion(id: area.id, text: renderedText, box: candidate.box, lineHeight: candidate.lineHeight,
                              icons: state.renderedIcons, blocks: moved?.map(\.item))
            state.renderedBox = candidate.box
            state.renderedLineHeight = candidate.lineHeight
            state.renderedLayout = candidate.blocks
            state.renderedBlocks = moved
            states[area.id] = state
            return
        }
        // Bekletilen okuma gösterilmeden yerine başka okuma geldi: o okuma hiç çevrilmedi (günlüğe bir kez).
        if let held = state.held, held != candidate.key {
            drops.note("RegionWatcher", "\(area.name): bekletilen okuma gösterilmeden yerine yenisi geldi, çevrilmedi",
                       state.heldText ?? "", log: onLog)
            state.held = nil
        }
        if Self.shouldHold(candidate, state) {
            if state.held != candidate.key {
                state.held = candidate.key
                state.heldText = IconText.plain(candidate.paragraphs.joined(separator: " "))
                state.holds = 0
            }
            state.holds += 1
            if state.holds <= Self.holdLimit {
                // Sonraki tur (iz değişmese de) bu okumayı yeniden dener; o hâlde kalırsa sınırda gösterilir.
                state.candidate = candidate
                states[area.id] = state
                return
            }
        }
        state.held = nil
        state.holds = 0
        let previous = (shown: state.shown, text: state.shownText, icons: state.shownIcons)
        state.shown = candidate.key
        state.shownText = candidate.text
        state.shownIcons = Self.iconCount(candidate)
        states[area.id] = state
        guard !candidate.key.isEmpty else {
            server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            states[area.id]?.renderedKey = candidate.key
            states[area.id]?.renderedText = ""
            states[area.id]?.renderedIcons = nil
            states[area.id]?.renderedBox = nil
            states[area.id]?.renderedLineHeight = nil
            onLog?("ek alan \(area.name): boşaldı")
            return
        }
        let session = self.session
        let key = Self.translationKey(candidate)
        let cached = translations[key]
        let translation: Translation
        do {
            if let cached { translation = cached }
            else { translation = try await deadline(auto: area.auto, candidate.paragraphs) }
        } catch {
            guard session == self.session else { return }
            if states[area.id]?.shown == candidate.key {
                states[area.id]?.shown = previous.shown
                states[area.id]?.shownText = previous.text
                states[area.id]?.shownIcons = previous.icons
                states[area.id]?.candidate = candidate
            }
            onLog?("ek alan \(area.name): \(SubtitleLog.excerpt(IconText.plain(candidate.paragraphs.joined(separator: " ")))) çevrilemedi (\(error))")
            return
        }
        guard session == self.session, states[area.id]?.shown == candidate.key else { return }
        if cached == nil {
            if translations.count >= Self.translationLimit { translations.removeAll(keepingCapacity: true) }
            translations[key] = translation
        }
        states[area.id]?.remembered = candidate.text
        let translated = translation.result
        let readyCount = translation.readyCount
        // Simgeler çeviride uydurma adlarla korunmuştu (`IconText`); adlar yerlerine konur.
        let prepared = candidate.paragraphs.map(IconText.protect)
        var slots: [IconSlot] = []
        var text: [String] = []
        for (index, source) in candidate.paragraphs.enumerated() {
            let trimmed = (index < translated.count ? translated[index] : nil)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty || trimmed.contains(ButtonIcons.marker) {
                text.append(IconText.indexed(trimmed.isEmpty ? source : trimmed, offset: slots.count))
            } else {
                text.append(IconText.restore(trimmed, names: prepared[index].names, offset: slots.count))
            }
            if let all = candidate.icons, index < all.count { slots += all[index] }
        }
        // Çevirisi aslıyla aynı (ad, sayı, zaten hedef dilde): kutu gösterilmez.
        let similar = zip(candidate.paragraphs, text).map {
            TextMatch.isSimilar(TextMatch.normalize(IconText.plain($0)), TextMatch.normalize(IconText.plain($1)), threshold: 0.90)
        }
        if similar.allSatisfy({ $0 }) {
            drops.note("RegionWatcher", "\(area.name): çevirisi aslıyla aynı, gösterilmedi",
                       IconText.plain(candidate.paragraphs.joined(separator: " ")), log: onLog)
            server.sendRegion(id: area.id, text: "", box: nil, lineHeight: nil)
            states[area.id]?.renderedKey = candidate.key
            states[area.id]?.renderedText = ""
            states[area.id]?.renderedIcons = nil
            states[area.id]?.renderedBox = nil
            states[area.id]?.renderedLineHeight = nil
            states[area.id]?.renderedLayout = nil
            states[area.id]?.renderedBlocks = nil
            return
        }
        let origin = cached != nil || readyCount == candidate.paragraphs.count ? "hazır çeviri" : readyCount > 0 ? "hazır çeviri+motor" : "motor"
        onLog?("ek alan \(area.name): \(SubtitleLog.excerpt(IconText.plain(candidate.paragraphs.joined(separator: " ")))) → \(origin)")
        if let layout = candidate.blocks, let summary = Self.paintSummary(layout) { onLog?("ek alan \(area.name): çizim \(summary)") }
        let rendered = IconText.render(text.joined(separator: "\n"), slots: slots)
        let icons = rendered.icons.isEmpty ? nil : rendered.icons
        var blocks = candidate.blocks.map { Self.renderBlocks(candidate, layout: $0, text: text, similar: similar, slots: slots) }
        // Satır farkıyla yerinde tutulan, bu okumada da okunamayan satır (seçili satırın soluk yazısı, #1359) kalkmaz: ekran
        // durunca doğrulanan okumada o satır yoktu, çevirisi kayboluyordu. Yalnız satır farkından hemen sonraki çizimde
        // (`renderedKey` nil) ve yerinde başka yazı yoksa.
        if blocks != nil, let carried = states[area.id]?.renderedBlocks, states[area.id]?.renderedKey == nil {
            let diff = Self.carriedRows(rendered: carried.map(\.item), current: Self.blockTexts(candidate), listMoved: false)
            for row in diff.kept where row.current == nil { blocks?.append((-1, carried[row.rendered].item)) }
        }
        server.sendRegion(id: area.id, text: rendered.text, box: candidate.box, lineHeight: candidate.lineHeight, icons: icons,
                          blocks: blocks?.map(\.item))
        states[area.id]?.renderedKey = candidate.key
        states[area.id]?.renderedText = rendered.text
        states[area.id]?.renderedIcons = icons
        states[area.id]?.renderedBox = candidate.box
        states[area.id]?.renderedLineHeight = candidate.lineHeight
        states[area.id]?.renderedLayout = candidate.blocks
        states[area.id]?.renderedBlocks = blocks
        let trace = states[area.id]?.signature
        states[area.id]?.shownTrace = trace
        states[area.id]?.unsteady = 0
        states[area.id]?.unsteadySince = nil
        noteRebound(candidate, area: area)
    }

    /// Her grubun çevirisi kendi yeriyle. Çevirisi aslıyla aynı grup (ad, sayı) atlanır; İngilizcesi görünür kalır.
    /// `text` simge imlerini bütün alanın sırasıyla taşır; `slots` o sıradaki simgeler.
    static func renderBlocks(_ candidate: Candidate, layout: [Block], text: [String], similar: [Bool],
                             slots: [IconSlot]) -> [(group: Int, item: ScreenTranslation.Item)] {
        var result: [(group: Int, item: ScreenTranslation.Item)] = []
        for (index, block) in layout.enumerated() {
            let range = block.start..<(block.start + block.count)
            // İkiz panelde çevrilmeyen yazı (kişi adı) da özgün hâliyle yazılır: ikiz özgünün eksiksiz kopyası olsun.
            if range.allSatisfy({ similar[$0] }), block.paint?.mode != .twin { continue }
            var joined = range.map { text[$0] }.joined(separator: "\n")
            // Özgün yazı BÜYÜK HARF: çeviri de Türkçe kurallarıyla büyük harf (simge imleri harf değildir, korunur).
            if block.look?.upper == true { joined = TextStyleSampler.turkishUpper(joined) }
            if block.mission { joined = MissionLine.marker + joined }
            let rendered = IconText.render(joined, slots: slots)
            let source = range.map { IconText.plain(candidate.paragraphs[$0]) }.joined(separator: "\n")
            var item = ScreenTranslation.Item(source: source, translation: rendered.text, box: block.box,
                                              lineHeight: block.lineHeight, icons: rendered.icons.isEmpty ? nil : rendered.icons)
            item.style = block.style
            item.look = block.look
            item.paint = block.paint
            item.rows = max(item.rows, block.rows)
            result.append((index, item))
        }
        return result
    }

    struct TranslationTimeout: Error, CustomStringConvertible {
        let ms: Int
        var description: String { "çeviri \(ms) ms'de bitmedi" }
    }

    /// Çeviri `translationTimeoutMs` içinde bitmezse `TranslationTimeout` (aday korunur, sonraki turda yeniden denenir).
    /// İptali dinlemeyen motorun görevi beklenmez: tur biter, kilit (`running`) açılır.
    private func deadline(auto: Bool, _ paragraphs: [String]) async throws -> Translation {
        let work = Task { @MainActor in try await (auto ? self.translateLabels(paragraphs) : self.translate(paragraphs)) }
        let limit = translationTimeoutMs
        final class Once { var done = false }
        let once = Once()
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Translation, Error>) in
                Task { @MainActor in
                    let result = await work.result
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(with: result)
                }
                timer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000)
                    guard !once.done else { return }
                    once.done = true
                    work.cancel()
                    continuation.resume(throwing: TranslationTimeout(ms: limit))
                }
            }
        } onCancel: { work.cancel() }
    }

    /// Saklanan çevirinin anahtarı: paragraflar ayrı ayrı. Aynı yazı başka satırlardan bölünürse paragraf sayısı değişir;
    /// `candidate.key` aynı kalsa da eski çeviri kullanılmaz (dizinin dışına taşardı).
    static func translationKey(_ candidate: Candidate) -> String { candidate.paragraphs.joined(separator: "\n") }

    /// Parçalar önce pakette aranır; kalanlar çeviri motoruna gider (yapay zekâda tek istekte). Motora simgeleri adlarla
    /// korunmuş metin gider (`IconText`; simgeler paket aramasında yok sayılır). Çevrilemeyen parça nil kalır.
    private func translate(_ paragraphs: [String]) async throws -> Translation {
        let prepared = paragraphs.map(IconText.protect)
        var result = paragraphs.map { paragraph in
            // Yalnız özel adlardan oluşan yazı ("JASON & LUCIA") çevrilmez (#859).
            ScreenTranslation.keepsNames(paragraph) ? paragraph
                : packLookup?(IconText.plain(paragraph))?.text ?? (translatesUiCommands ? UiCommands.translate(paragraph) : nil)
        }
        let readyCount = result.compactMap { $0 }.count
        // Zaten Türkçe olan parça çevrilmez: aslı kalır, tümü öyleyse kutu gösterilmez.
        for index in result.indices where result[index] == nil && skipsTurkish && TurkishText.isSure(paragraphs[index]) {
            result[index] = paragraphs[index]
        }
        // Yazı tanımanın bozduğu parça motora gitmez; aslı kalır (gösterilmez), sonraki okuma yeniden denenir (#1293).
        for index in result.indices where result[index] == nil && implausible(IconText.plain(paragraphs[index])) {
            result[index] = paragraphs[index]
        }
        let missing = result.indices.filter { result[$0] == nil }
        if !missing.isEmpty {
            let texts = missing.map { prepared[$0].text }
            let translated = translator.translatesTogether ? try await translator.translateAll(texts)
                : try await sequential(texts)
            for (index, translation) in zip(missing, translated) { result[index] = translation }
        }
        return Translation(result: result, readyCount: readyCount)
    }

    /// Dünya yazısı listesinde kalma süresi (oturum içinde).
    static let worldTextMs = 10 * 60 * 1000
    private var autoSeen: [String: (box: TextBox, at: Int)] = [:]
    private var worldText: [String: Int] = [:]

    /// Kamera hareket ederken kayan ya da ölçeklenen yazı (aynı metin başka yerde ya da boyda yeniden okundu) oyun
    /// dünyasındadır (poster, plaka, tabela): metni 10 dk dünya yazısı listesine girer, çevrilmez. Arayüz yazısı yerinde durur.
    private func isWorldText(_ candidate: Candidate) -> Bool {
        let key = candidate.text
        guard !key.isEmpty else { return false }
        let time = now()
        if let until = worldText[key], until > time { return true }
        guard let box = candidate.box else { return false }
        if let seen = autoSeen[key] {
            let moved = abs((box.left + box.right) / 2 - (seen.box.left + seen.box.right) / 2) > 0.02
                || abs((box.top + box.bottom) / 2 - (seen.box.top + seen.box.bottom) / 2) > 0.02
            let height = box.bottom - box.top, before = seen.box.bottom - seen.box.top
            if moved || max(height, before) > 1.15 * min(height, before) {
                if worldText.count > 512 { worldText.removeAll() }
                worldText[key] = time + Self.worldTextMs
                return true
            }
        }
        if autoSeen.count > 512 { autoSeen.removeAll() }
        autoSeen[key] = (box, time)
        return false
    }

    /// Oturum terim sözlüğü: otomatik alanlarda çevrilen etiket ve parçalar (kaynak → çeviri).
    private var terms: [String: String] = [:]
    private static let termLimit = 4096

    private static let keyPrefix = try! NSRegularExpression(pattern: #"^(?:(?:\((?:[LR][1-3]?|[△□○✕])\)|[△□○✕]|[LR][1-3](?=\s))\s*)+"#)
    private static let keySuffix = try! NSRegularExpression(pattern: #"(?:\s*(?:\((?:[LR][1-3]?|[△□○✕])\)|[△□○✕]|(?<=\s)[LR][1-3]))+$"#)
    private static let counter = try! NSRegularExpression(pattern: #"\s+\d+\s*/\s*\d+$"#)

    private static func match(_ regex: NSRegularExpression, _ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard let found = regex.firstMatch(in: text, range: range), let match = Range(found.range, in: text) else { return "" }
        return String(text[match])
    }

    struct LabelPart: Equatable {
        var prefix: String
        var core: String
        var suffix: String
    }

    /// Etiketin çevrilecek parçaları: " / " ile ayrılan her parça; önündeki ve ardındaki tuş adları ("(L1)", "(△)") ve
    /// sondaki sayaç ("Default 1 / 3") olduğu gibi kalır.
    static func splitLabel(_ paragraph: String) -> [LabelPart] {
        // Simgesi kareden kesilmiş parça bölünmez (simge imleri çeviride korunur).
        if paragraph.contains(ButtonIcons.marker) { return [LabelPart(prefix: "", core: paragraph, suffix: "")] }
        // Sondaki sayaç dokunulmaz; " / " yalnız iki yanında harf varsa ayırıcıdır.
        let count = match(counter, paragraph)
        let body = String(paragraph.dropLast(count.count))
        var pieces = body.components(separatedBy: " / ")
        if pieces.contains(where: { !$0.contains(where: \.isLetter) }) { pieces = [body] }
        var result = pieces.map { part -> LabelPart in
            var prefix = match(keyPrefix, part)
            var rest = String(part.dropFirst(prefix.count))
            // Baştaki konuşan adı ("Staff Member: 'Sup?", menünün diyalog geçmişi) ve özel ad ("JASON & LUCIA MAP", sekmeler
            // tek parça okununca) çevrilmez, olduğu gibi kalır; yalnız ardındaki yazı çevrilir (Sinan Bey beta.100 3380:
            // "JASON & LUCIA MAP ÖZETİ", "MAP" çevrilmemişti).
            if let kept = keptHead(rest) {
                prefix += kept
                rest = String(rest.dropFirst(kept.count))
            }
            let suffix = match(keySuffix, rest)
            return LabelPart(prefix: prefix, core: String(rest.dropLast(suffix.count)), suffix: suffix)
        }
        if !count.isEmpty { result[result.count - 1].suffix += count }
        return result
    }

    /// Etiketin başında çevrilmeyecek kısım (ardındaki boşluk dahil): konuşan adı ("Staff Member: ") ya da yalnız özel
    /// adlardan oluşan baş ("JASON & LUCIA " + "MAP"; `ScreenTranslation.keepsNames`). Ardında harfli yazı kalmalı.
    /// Konuşan adının ardı cümle olmalı (noktalamayla biter ya da en az üç sözcük): ayar satırı ("Subtitles: On") bütün
    /// çevrilir.
    static func keptHead(_ text: String) -> String? {
        if let speaker = SpeakerPrefix.split(text),
           SubtitleStabilizer.endsSentence(speaker.body) || speaker.body.split(whereSeparator: \.isWhitespace).count >= 3,
           let range = text.range(of: speaker.body, options: .backwards),
           text[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty {
            return String(text[..<range.lowerBound])
        }
        guard text.contains(" & "), TextStyleSampler.isUpper(text) else { return nil }
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count >= 4 else { return nil }
        for end in stride(from: words.count - 1, through: 3, by: -1) {
            let head = words[..<end].joined(separator: " ")
            let tail = words[end...].joined(separator: " ")
            if tail.contains(where: \.isLetter), ScreenTranslation.keepsNames(head) { return head + " " }
        }
        return nil
    }

    /// Otomatik alanın çevirisi (yoğun menüler): her paragraf " / " ayırıcısından parçalara bölünür, tuş adları ve
    /// sayaçlar olduğu gibi kalır. Parçalar önce oturum terim sözlüğünden, arayüz sözlüğünden ve paketten; kalanların
    /// hepsi tek toplu istekte motordan çevrilir ve terim sözlüğüne yazılır (aynı ekrana dönüşte anında, aynı etiket hep
    /// aynı). Kısa etiketin biçimi korunur ("OFF" → "KAPALI", "Off" → "Kapalı").
    private func translateLabels(_ paragraphs: [String]) async throws -> Translation {
        let parts = paragraphs.map(Self.splitLabel)
        var known: [String: String] = [:]
        var pending: [String] = []
        for part in parts.joined() {
            let core = part.core.trimmingCharacters(in: .whitespaces)
            guard core.contains(where: \.isLetter), known[core] == nil, !pending.contains(core) else { continue }
            // Yalnız özel adlardan oluşan sekme ("JASON & LUCIA") çevrilmez (#859).
            if ScreenTranslation.keepsNames(core) {
                known[core] = core
            } else if let found = (translatesUiCommands ? UiCommands.translateLabelLoosely(core) : nil) ?? terms[core]
                ?? packLookup?(IconText.plain(core))?.text ?? (skipsTurkish && TurkishText.isSure(core) ? core : nil) {
                known[core] = found
            } else if implausible(IconText.plain(core)) {
                // Yazı tanımanın bozduğu parça motora gitmez; aslı kalır (#1293).
                known[core] = core
            } else {
                pending.append(core)
            }
        }
        if !pending.isEmpty {
            let prepared = pending.map { IconText.protect($0).text }
            let translated = translator.translatesTogether ? try await translator.translateAll(prepared)
                : try await sequential(prepared)
            if terms.count + pending.count > Self.termLimit { terms.removeAll() }
            for (source, text) in zip(pending, translated) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                terms[source] = trimmed
                known[source] = trimmed
            }
        }
        // Paket ya da motor görev başlığını olduğu gibi döndürdü ("Hit Kingpin Bowling"): yalnız fiil çevrilir, ad kalır (#1365).
        if translatesUiCommands {
            for (source, text) in known where TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(text), threshold: 0.90) {
                guard let title = UiCommands.missionTitle(source) else { continue }
                known[source] = title
                if terms[source] != nil { terms[source] = title }
            }
        }
        let result: [String?] = parts.map { list in
            var pieces: [String] = []
            for part in list {
                let core = part.core.trimmingCharacters(in: .whitespaces)
                guard let translation = core.contains(where: \.isLetter) ? known[core] : part.core else { return nil }
                pieces.append(part.prefix + translation + part.suffix)
            }
            return pieces.joined(separator: " / ")
        }
        let readyCount = parts.filter { list in list.allSatisfy { !pending.contains($0.core.trimmingCharacters(in: .whitespaces)) } }.count
        return Translation(result: result, readyCount: readyCount)
    }

    /// Parça yazı tanımada bozulmuş mu (`ReadPlausibility`); öyleyse günlüğe seyreltilmiş tek satır yazılır.
    private func implausible(_ text: String) -> Bool {
        guard let reason = ReadPlausibility.reason(text) else { return false }
        if let line = implausibleLog.line(text, reason: reason) { onLog?("ek alan: " + line) }
        return true
    }

    private func sequential(_ texts: [String]) async throws -> [String] {
        var result: [String] = []
        for text in texts {
            try Task.checkCancellation()
            result.append(try await translator.translate(text))
        }
        return result
    }

    /// Telefon kapanınca yalnız onun bekleyen isteğini ve görünür bloklarını kaldırır.
    public func closePhone() {
        phoneSession?.close()
        phoneSession = nil
    }

    /// Çeviri durdu ya da hat yeniden kuruldu: süren tur bırakılır, TV'deki ek alan kutuları kalkar.
    public func reset() {
        closePhone()
        session += 1
        running?.cancel()
        running = nil
        lastPass = nil
        translations.removeAll()
        phoneMemory.clear()
        steadiness.removeAll()
        terms.removeAll()
        worldText.removeAll()
        autoSeen.removeAll()
        let anyShown = states.values.contains { !$0.shown.isEmpty }
        states.removeAll()
        if anyShown { server.clearRegions() }
    }
}
