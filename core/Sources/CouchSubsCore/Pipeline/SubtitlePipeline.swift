// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Altyazıları TV'ye ileten taraf (gerçekte `SubtitleServer`).
public protocol SubtitleSending: AnyObject {
    /// `box`: oyundaki altyazının karedeki yeri (kenarlara oranla), bilinmiyorsa nil.
    /// `replaces`: satır az önce gösterilenin uzamış ya da düzelmiş okumasıdır; TV onu öncekinin üstüne yığmaz.
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool)
    func clear()
    /// Ekrandaki görev satırının karedeki yeri (yoksa nil): altyazı kutusu onu örtmez, üstüne kayar (`MissionLine.clearance`).
    func sendObjective(_ box: TextBox?)
}

extension SubtitleSending {
    public func sendObjective(_ box: TextBox?) {}
}

extension SubtitleServer: SubtitleSending {}

/// Kare → bölge → yazı tanıma → kararlılık → çeviri → TV.
@MainActor
public final class SubtitlePipeline {
    /// Satır ekrandan bundan uzun süre önce kalktıysa geç gelen çevirisi gösterilmez (sonraki sahnenin üstüne düşmesin).
    /// Yavaş çeviride (ücretsiz motor, zayıf işlemci) art arda gelen satırların çevirisi satır kalktıktan bir iki saniye
    /// sonra gelir; sınır 1 sn iken üç satırlık konuşmanın yalnız ilki görünüyordu.
    /// Süre satırın kalktığı andan, satır sırada beklediyse çevirisinin başladığı andan sayılır: önceki satırların
    /// çevirisini bekleyen satır sıranın gecikmesi yüzünden atılmaz.
    public static let lateResultMs = 2500
    /// Arkasından yeni satır gelmiş (konuşma sürüyor) satırın geç gelen çevirisi bu süreye kadar yine gösterilir; yeni
    /// satır onun ardından gider, sıra bozulmaz. Daha eskisi hiçbir zaman gösterilmez. GitHub #893: yapay zekâ çevirisi
    /// satır başına bir iki saniye sürüyor; art arda gelen satırların ilki yenisi geldikten 2,5 sn sonra çevrilince
    /// atılıyor ya da yarıda bırakılıyordu, bazı satırlar TV'ye hiç gitmiyordu (ücretsiz motorda olmuyordu).
    public static let queuedLateResultMs = 8000
    /// Çeviri sürerken sırada en çok bu kadar satır bekler; daha eskisi atlanır (kuyruk konuşma hızıyla büyümesin).
    public static let maxWaiting = 4
    private static let rememberedPairs = 8
    /// Bozuk okunan (OCR izi taşıyan) ve pakette bulunmayan satır en çok bu kadar bekletilir: aynı satırın düzgün okuması
    /// gelirse o çevrilir (Windows: PackWaitMs).
    public static let packWaitMs = 800
    /// Temiz ama yarım olabilecek satırın (küçük harfle başlıyor ya da cümle sonu işareti yok) bekleme süresi. iPhone ve
    /// Mac yarım okumayı ("Get Franklin close to the") hemen çevirmene gönderiyordu; çeviri Windows'takinden kötü
    /// görünüyordu (Windows: CleanWaitMs).
    public static let cleanWaitMs = 300
    /// Çevrilen satırın daha iyi olmayan yeniden okuması bu süre içinde yeni satır sayılmaz.
    public static let rereadWithinMs = 4000

    /// Bekletilen okuma: kaynak, yer, bekletilmeye başlandığı an, en çok bekleme, puanı, ilk okunduğu kare.
    private struct Held {
        var source: String
        var box: TextBox?
        var since: Int
        var wait: Int
        var score: Int
        var read: ReadInfo
    }
    private var held: Held?
    /// Son çevrilen (motora ya da pakete giden) okuma, puanı ve zamanı.
    private var lastSent: (source: String, score: Int, at: Int)?
    private var lastClearAt = Int.min
    /// Yarım ya da bozuk okuma kısa süre bekletilip aynı satırın en iyi okuması mı çevrilsin (Windows'ta yazım denetimiyle
    /// açık). Mac ve iPhone'da açık (Windows ve Android ile aynı); kapalıyken her kararlı okuma hemen çevrilir.
    public var holdReadings = true
    /// Bozuk okumanın bekleme süresi (0: beklenmez); testler değiştirir.
    public var packWait = SubtitlePipeline.packWaitMs
    /// Yarım olabilecek temiz okumanın bekleme süresi (0: beklenmez); testler değiştirir.
    public var cleanWait = SubtitlePipeline.cleanWaitMs

    /// Bir çeviri isteği; satır ekrandan kalkınca `leftAt` not edilir.
    private final class Request {
        let number: Int
        /// Ad sonradan okunursa (`nameRead`) adlı okumaya döner; çeviriye giden cümle aynı kalır.
        var source: String
        let box: TextBox?
        let session: Int
        /// Baştaki konuşan adı ("ARTHUR: …"); çeviriye yalnız cümle gider.
        var prefix: SpeakerPrefix.Split?
        /// Satırı kararlı yapan karenin geldiği an, o okumanın süresi ve güveni (ölçümler için).
        let read: ReadInfo
        /// Satırın ekrandan kalktığı an (hâlâ ekrandaysa nil).
        var leftAt: Int?
        /// Çevirisinin başladığı an (sırada bekliyorsa nil).
        var startedAt: Int?
        /// Yerine aynı cümlenin uzamış okuması geldi (daktilo efekti); çevirisi gösterilmez.
        var superseded = false
        /// Mevcut gösterim kurallarına göre elendi (daha yeni satır gösterildi ya da süresi doldu); iptali dinlemeyen
        /// motorun sonucu da gösterilmez.
        var abandoned = false
        init(number: Int, source: String, box: TextBox?, session: Int, read: ReadInfo) {
            self.number = number
            self.source = source
            self.box = box
            self.session = session
            self.read = read
            prefix = SpeakerPrefix.split(source)
        }
    }

    /// Bir karenin okunması: karenin geldiği an, yazı tanımanın süresi (ms) ve güveni (0–1).
    fileprivate struct ReadInfo {
        var capturedAt: Int
        var ocrMs: Int?
        var confidence: Double?
    }

    private let reader: TextReader
    private let readQueue: ReadQueue
    private let translator: TextTranslator
    private let server: SubtitleSending
    private let now: () -> Int
    private var stabilizer: SubtitleStabilizer
    private var scheduler: ReadScheduler
    /// Her çeviri isteği sıra numarası alır. Aynı anda yalnız bir çeviri sürer, en çok `maxWaiting` satır sırada bekler:
    /// hızlı konuşmada satırlar sırayla çevrilir, kuyruk konuşma hızıyla büyümez. Bekleyen satırın uzamış ya da düzelmiş
    /// okuması gelirse eskisi sıradan çıkar.
    private var lastRequested = 0
    private var lastShown = 0
    private var inFlight: Request?
    private var waiting: [Request] = []
    private var pump: Task<Void, Never>?
    /// Süren çevirinin kendisi; okuma durunca iptal edilir.
    private var work: Task<String, Error>?
    /// Şu an oyun ekranında duran satırın numarası (bölge boşalınca nil).
    private var lineOnScreen: Int?
    /// Son çevrilen satırlar (kaynak → çeviri; zaten hedef dildeyse nil). Geri gelen satır bunlardan yeniden gösterilir.
    private var pairs: [(number: Int, source: String, translation: String?)] = []
    /// Okuma durdurulunca artar; önceki oturumdan dönen çeviriler gösterilmez.
    private var session = 0
    /// Son ham OCR. Gri görüntü izi aynı kalırken satırların altındaki panel rengi değişebilir.
    private var lastOcrReading = Reading.empty
    private var stickyRows = StickyRows()
    /// Kamerayla kayan yazı (plaka, tabela) altyazı alanına girse de altyazı sayılmaz (`SceneMotion`).
    private var sceneMotion = SceneMotion()
    /// Bu oturumda kesin altyazının okunduğu yükseklikler: oradaki kısa satır sahne yazısı sayılmaz (`SceneText`).
    private var subtitleBand = SubtitleBand()
    /// Oyunun altyazısı koyu yazı mı (açık zemindeki koyu yazı kuralı o oturumda kapanır, `InkTone`; GitHub #1124).
    private var darkInkStyle = DarkInkStyle()
    /// Günlüğe yazılmış son sahne yazıları (her karede yeniden yazılmasın).
    private var loggedSceneText: [String] = []
    /// Karara bağlanmış (atılan ya da gösterilen) satırlar, ekranda durdukça (`SettledText`): zaten hedef dilde olan
    /// bloğun bozuk okunmuş parçası çevrilmez, aynı satır değişmeyen ekranda yeniden işlenmez.
    private var settled = SettledText()
    private var mission = MissionLine()
    /// TV'ye son bildirilen görev satırı yeri (`MissionLine.clearance`).
    private var sentClearance: TextBox?
    /// Düşürülen ya da bekletilen satırın nedeni, sınırlı ve tekrarsız (`DropLog`).
    private let drops: DropLog
    /// Altyazı sayılmayan satırların neden başına sayacı (`RejectTally`; beta.103 kaçan altyazı).
    private let rejects = RejectTally()
    /// Görev satırının bölgesi değişti (nil: görev kalktı). Görev altyazıya girmez; bölgesi "auto-mission" ek alanı olarak
    /// kendi yerinde ve özgün stilinde gösterilir (bkz. `MissionLine`).
    public var onMissionChanged: ((CropRegion?) -> Void)?
    private var notices = ScreenNotices()
    /// Ekranın kenarındaki bildirim kartlarının alanları değişti (boş: hiç yok). Bildirim altyazıya girmez; alanları
    /// "auto-notice-<n>" ek alanı olarak kendi yerinde ve özgün stilinde gösterilir (bkz. `ScreenNotices`).
    public var onNoticesChanged: (([ExtraArea]) -> Void)?
    /// Altyazının son okunan satırları ve alanı; ekran yazısı okuyucuları bunlarla altyazıyı dışlar (bkz. `SubtitleEcho`).
    /// Uygulama `SubtitleEcho.shared` verir.
    public var echo: SubtitleEcho? {
        didSet { echo?.own = own }
    }
    /// Gösterilen çeviriler: karede okunan kendi altyazımız (OBS Program projektörü) yeni satır sayılmaz (bkz.
    /// `OwnSubtitles`). Ekran yazısı okuyucuları da `echo` üstünden bunu kullanır.
    public let own: OwnSubtitles
    /// Günlüğe yazılmış son kendi altyazısı (her karede yeniden yazılmasın).
    private var loggedOwn: String?
    /// Günlüğe yazılmış son telefon yazısı (her karede yeniden yazılmasın).
    private var loggedPhone: String?
    /// Sessizlik bekçisi (`watchSilence`).
    private var silence = SilenceWatch()
    /// Günlüğe yazılmış son "altyazı sayılmadı" kümesi (`logLeftOut`).
    private var loggedLeftOut = ""
    /// Son günlüğe yazılan sabit blok (`logStale`; aynı bant her karede yazılmasın).
    private var loggedStale = ""
    /// Karede açık GTA 6 telefonunun ekranındaki satırlar altyazı sayılmaz (`ScreenPhoneCard.holds`); telefonun çevirisi
    /// kendi yerindedir (telefon okuyucusu, "Ekranı çevir"). Kullanıcı bildirimleri (X, beta.79, üç kişi): telefonun alt
    /// kısmındaki mesajlar (telefon ortaya yakın tutulunca bütün sohbet) altyazı sanılıp ekranın ortasında tek uzun satır
    /// olarak çevriliyor, telefonun çevirisi de altyazının altında kalıyordu. Varsayılan açık (Windows ve Android ile aynı).
    public var findsPhone = true
    /// Telefon arandı (bulundu mu); `findsPhone` açıkken `GamePhoneTracker.intervalMs` arayla. Telefon çevirisi kapalıyken
    /// "Telefon çevirisi kapalı, açmak ister misiniz?" ipucu (`GamePhoneHint.observePhone`, #1282). Kararları değiştirmez.
    public var onPhoneLooked: ((Bool) -> Void)?
    private var phone: ScreenPhoneCard.Handset?
    private var phoneLookedAt: Int?
    /// Açık telefonun art arda bulunamadığı arama sayısı: telefon `GamePhoneTracker.missGrace` aramada bulunamazsa kalkar.
    /// Sinan Bey (beta.100, 3418, 3420, 3421): telefon tek aramada ıskalanınca süzgeç o an kapanıyor, gönderinin açıklaması
    /// hem balonda hem altyazıda, haber kaynağı ("Weazel News") ve makale satırı altyazıda çıkıyordu. Açık telefon artık
    /// izleyicinin toleransıyla tutulur ve son yerinde gevşek doğrulanır (`GamePhoneGeometry.locate(near:)`; Windows ve
    /// Android ile aynı).
    private var phoneMisses = 0
    /// Doğrulanmamış telefon adayı (sıkı aramada yanları zayıf kalan; `GamePhoneGeometry.Probe.weak`) ve ilk görüldüğü an.
    /// Adayın ekranındaki satırlar `candidateHoldMs` boyunca altyazı sayılmaz; sonraki aramada adayın yerinde gevşek
    /// doğrulama telefonu bulursa süzgeç telefonu tutar, bulamazsa satırlar süre dolunca altyazıya geçer (#1251: telefon
    /// mesajları telefon bulunana dek altyazı gibi çevriliyordu; Windows ve Android ile aynı).
    private var phoneCandidate: ScreenPhoneCard.Handset?
    private var phoneCandidateSince = 0
    /// Doğrulanmamış adayın satırlarının en çok bekletildiği süre (ms).
    static let candidateHoldMs = 1500
    /// Son yazı tanımanın süresi (ms); kare değişmeyip okuma yeniden kullanılınca da o okumanın süresi geçerlidir.
    private var lastReadMs: Int?
    /// Son yazı tanımanın süresi (ms): kare sıklığı okuma yavaşsa seyrekleşir (`FrameCadence`).
    public var lastOcrMs: Int? { lastReadMs }
    /// İşlenen karenin okunması (satır kararlı olunca isteğe geçer).
    private var currentRead = ReadInfo(capturedAt: 0)

    public private(set) var lastPair: (source: String, translation: String)?
    /// Son gösterilen çevirinin oyundaki altyazının yeri.
    public private(set) var lastBox: TextBox?
    public private(set) var lastError: TranslatorError?
    public var onPair: ((String, String) -> Void)?
    /// TV'ye giden her yeni satırın ölçümleri (`onPair`'den hemen önce çağrılır).
    public var onMetrics: ((LineMetrics) -> Void)?
    /// Son gösterilen satırın ölçümleri.
    public private(set) var lastMetrics: LineMetrics?
    /// TV'ye giden her yeni altyazının seslendirilecek cümleleri (dublaj).
    public var onSpeech: (([SpokenLine]) -> Void)?
    /// Her yazı tanıma denemesinden sonra çağrılır (başarılıysa nil). Disk dolunca macOS okumayı hep hata ile bitirir.
    public var onReadResult: ((Error?) -> Void)?
    /// Her çeviri denemesinden sonra çağrılır (başarılıysa nil).
    public var onTranslationResult: ((TranslatorError?) -> Void)?
    /// Oyun paketi: kararlı satırın hazır Türkçesi (yoksa nil). Çeviri motorundan ve önbellekten önce bakılır; bulunursa
    /// motor hiç çağrılmaz ve çeviri beklemeden gösterilir. Uygulama paketler açıkken verir.
    public var packLookup: ((String) -> PackMatch?)?
    /// Konuşan adı ("ARTHUR: …") TV'ye giden çeviride gösterilir; kapalıysa yalnız cümle gider.
    public var showSpeakerNames = true
    /// Hedef dil Türkçe: yüksek güvenle Türkçe olan satır (`TurkishText.isSure`) çevirmene gönderilmez (#289). Uygulama
    /// hedef dil Türkçe değilse kapatır.
    public var skipsTurkish = true
    /// Hiçbir pakette bulunmayan kararlı satır (ortak havuz için).
    public var onPackMiss: ((String) -> Void)?
    /// Altyazı alanındaki blok sahne yazısı sayılıp atıldı (`SceneText.reason`); telefon çevirisi kapalıyken telefon
    /// listesi için ipucu (`GamePhoneHint`). Kararları değiştirmez.
    public var onSceneTextDropped: ((String) -> Void)?
    /// Son gösterilen çevirinin nereden geldiği: "paket" ya da "motor" (günlük ve sayım için).
    public private(set) var lastOrigin: String?
    /// Bu hatta paketten gelen satır sayısı.
    public private(set) var packHits = 0
    /// Altyazı günlüğü (`SubtitleLog`): ilk kare, okunan her kararlı satır ve akıbeti (paket, önbellek, çeviri, geç
    /// kaldı, atıldı), çöp sayılıp bırakılan ve yok sayılan yeniden okumalar. Kararları değiştirmez.
    public var onLog: ((String) -> Void)?
    /// Altyazı alanında konuşan adıyla başlayan bir satır okundu (her okumada). Uygulama ekran yazısı dedektörüne bildirir
    /// (`ScreenTextDetector.noteDialogue`): konuşma sürerken menü sayılmaz (#1240). Windows ve Android aynı.
    public var onDialogue: (() -> Void)?
    /// Altyazı alanında menünün geçmiş listesi okundu (`Reading.isHistoryList`; her okumada). Uygulama ekran yazısı
    /// dedektörüne (`ScreenTextDetector.noteList`) ve menü göndericisine (`MenuHeldSender.forget`) bildirir: liste
    /// ekranda durdukça menü sürer, listeden bekletilen satır menü kapanınca altyazı olarak gönderilmez. Windows ve
    /// Android aynı.
    public var onList: (() -> Void)?
    /// Doğruysa bu karede okunan blok `echo`'ya kaydedilmez: ekranda menü var, altyazı bekletiliyor; okunan menü satırları
    /// altyazı sayılmaz (yoksa menünün kendi çevirisi metin eşleşmesiyle atılırdı). Windows: EchoPaused.
    public var echoPaused: (() -> Bool)?
    /// Paket isabetinde satırın geldiği paket (günlük için; bilinmiyorsa nil).
    public var packName: (() -> String?)?
    /// Oturumun (hat kurulunca ya da sıfırlanınca) başladığı an; ilk karenin ne kadar sonra geldiği günlüğe yazılır.
    private var sessionStart: Int
    private var sawFrame = false
    private var sawText = false
    private var lastNote: StabilizerNote?
    /// Altyazı alanında yazı çıkmayan sürenin tanısı (`QuietReads`); sessizlik `QuietReads.reportAfterMs` sürerse nedeni
    /// (okunmadı mı, boş mu okundu, süzgeçte mi kaldı, hata mı) günlüğe yazılır.
    private var quiet: QuietReads

    /// `scheduler`: varsayılanı her kareyi okur; uygulama gereksiz okumaları atlayan planı verir.
    /// `clock`: milisaniye saati; testlerde sahtesi verilir.
    /// `readQueue`: okumaların sırası (süreç genelinde tek); testlerde kısa süreli bir sıra verilir.
    public init(reader: TextReader, translator: TextTranslator, server: SubtitleSending, scheduler: ReadScheduler = .always,
         clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs, readQueue: ReadQueue = .shared) {
        self.reader = reader
        self.readQueue = readQueue
        self.translator = translator
        self.server = server
        self.scheduler = scheduler
        self.now = clock
        self.stabilizer = SubtitleStabilizer(clock: clock)
        self.own = OwnSubtitles(clock: clock)
        self.drops = DropLog(clock: clock)
        sessionStart = clock()
        quiet = QuietReads(since: sessionStart)
    }

    /// Çeviri ekrana gider; kendi altyazısı süzgeci onu hatırlar.
    private func send(_ translation: String, source: String, durationMs: Int, box: TextBox?, replaces: Bool) {
        silence.sent()
        own.record(translation, source: source, durationMs: durationMs)
        server.sendSubtitle(translation, durationMs: durationMs, box: box, replaces: replaces)
    }

    private func clearScreen() {
        own.cleared()
        server.clear()
    }

    private func log(_ message: @autoclosure () -> String) {
        onLog?(message())
    }

    private func log(_ request: Request, _ message: @autoclosure () -> String) {
        onLog?("#\(request.number) \(message())")
    }

    /// Okuma çeviriyi beklemez; böylece çeviri sürerken gelen satırlar da yakalanır.
    /// `capturedAt`: karenin PS5 akışından geldiği an (`clock` ile aynı saat); verilmezse şimdi.
    public func process(_ frame: CGImage, region: CropRegion, capturedAt: Int? = nil) async {
        let captured = capturedAt ?? now()
        if !sawFrame {
            sawFrame = true
            log("ilk kare: oturum başından \(now() - sessionStart) ms sonra")
        }
        quiet.frames += 1
        // Okuma sürerken hat sıfırlandıysa (çeviri durdu, hat yeniden kuruldu) bu karenin sonucu yeni oturuma karışmaz:
        // geç biten eski okuma TV'ye eski satırı göndermesin.
        let startedSession = session
        // Yazı tanıma uzun sürebilir; arayüz takılmasın diye ana iş parçacığının dışında yapılır.
        let reader = self.reader
        // Karede GTA 6 telefonu açıksa ekranındaki satırlar altyazı değildir (`findsPhone`); telefon seyrek aranır
        // (`GamePhoneTracker.intervalMs`), bulunan yer sonraki karelere de geçerlidir.
        let looks = findsPhone && phoneLookedAt.map { captured < $0 || captured - $0 >= GamePhoneTracker.intervalMs } ?? findsPhone
        if looks { phoneLookedAt = captured }
        let near = phone ?? phoneCandidate
        let (area, signature, search) = await Task.detached(priority: .userInitiated) {
            let area = RegionCropper.crop(frame, to: region)
            let none: (phone: ScreenPhoneCard.Handset?, candidate: ScreenPhoneCard.Handset?) = (nil, nil)
            return (area, RegionCropper.signature(of: area), looks ? ScreenPhoneCard.search(in: frame, near: near) : none)
        }.value
        if looks {
            let next = Self.heldPhone(search.phone, shown: phone, misses: &phoneMisses)
            (phoneCandidate, phoneCandidateSince) = Self.candidate(next == nil ? search.candidate : nil, previous: phoneCandidate,
                                                                   since: phoneCandidateSince, now: captured)
            // Telefonun bulunması/kalkması günlüğe yazılır: yanlış bulunan telefon altyazı satırlarını atarsa görünsün.
            if (next == nil) != (phone == nil) {
                log(next == nil ? "telefon kalktı" : "telefon bulundu: ekranındaki satırlar altyazı sayılmayacak")
            }
            phone = next
            onPhoneLooked?(next != nil)
        }
        var handset = findsPhone ? phone : nil
        // Telefon doğrulanmadıysa doğrulanmayı bekleyen adayın ekranındaki satırlar kısa süre bekletilir (`candidateHoldMs`).
        let unconfirmed = handset == nil && findsPhone && Self.holdsCandidate(phoneCandidate, since: phoneCandidateSince, now: captured)
        if unconfirmed { handset = phoneCandidate }
        guard session == startedSession else { return }
        var visible = lastOcrReading
        let plan = scheduler.plan(signature: signature)
        if case .read(let deep) = plan {
            let started = now()
            // Okuma kendi sırasında (`ReadQueue`) yapılır, Swift havuzunu tutmaz; takılırsa süre dolunca kare atlanır (#507).
            let result: Result<Reading, Error>
            do {
                result = .success(try await readQueue.run(priority: .subtitle, detail: ReadQueue.detail("altyazı", area, deep: deep)) {
                    try reader.readLines(area, deep: deep)
                })
            } catch {
                result = .failure(error)
                if case ReadQueueError.timedOut(let ms) = error { log("okuma \(ms) ms'de bitmedi; kare atlandı") }
            }
            quiet.reads += 1
            switch result {
            case .success(let read): if read.lines.isEmpty { quiet.empty += 1 }
            case .failure(let error): quiet.failures += 1; quiet.lastError = "\(error)"
            }
            guard session == startedSession else {
                log("eski okuma \(now() - started) ms sonra bitti, hat sıfırlanmıştı; atıldı")
                return
            }
            lastReadMs = now() - started
            lastOcrReading = (try? result.get()) ?? .empty
            visible = lastOcrReading
            onReadResult?(result.failure)
            scheduler.record(visible.text)
        }
        // Karara bağlanmış satırlar karede hâlâ okunuyor mu (ekran değişti mi; `SettledText`).
        settled.observe(visible.lines.map(\.text), at: now())
        // Kumanda ipuçları ("R2 Swing") altyazı değildir; çevrilmez, yeri de altyazının yerine katılmaz.
        // Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") de çevirmene gitmez.
        // Alandaki menü ve köşe göstergeleri de altyazı değildir; yalnız altyazı bloğu çevrilir ve kutusu ona göre olur.
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        // Konuşma değişirken sabit duran görev/HUD satırı ("Get in the sea plane", GTA 6) altyazı bloğuna katılmaz.
        // Karede kendi altyazımız (OBS Program projektörü, CouchSubs'ın OBS katmanı) varsa okunmaz (bkz. `OwnSubtitles`).
        var (seen, ownLines) = own.split(visible, place: place)
        if let phone = handset {
            let kept = seen.lines.filter { line in
                line.box.map { box in
                    let placed = box.placed(in: place)
                    return unconfirmed ? !ScreenPhoneCard.holdsUnconfirmed(line.text, box: placed, handset: phone)
                        : !ScreenPhoneCard.holds(placed, handset: phone)
                } ?? true
            }
            if kept.count < seen.lines.count {
                let text = seen.lines.filter { !kept.contains($0) }.map(\.text).joined(separator: " ")
                if text != loggedPhone {
                    loggedPhone = text
                    log(unconfirmed ? "telefon adayı: \(SubtitleLog.excerpt(text)) telefon doğrulanana dek bekletildi, altyazı sayılmadı"
                        : "telefon yazısı: \(SubtitleLog.excerpt(text)) telefonun ekranında, altyazı sayılmadı")
                }
                seen = Reading(lines: kept)
                countReject(unconfirmed ? "telefon adayı bekletti" : "telefon yazısı")
            }
        }
        if let first = ownLines.first, first.text != loggedOwn {
            loggedOwn = first.text
            log("kendi altyazısı: \(SubtitleLog.excerpt(ownLines.map(\.text).joined(separator: " "))) karede okundu, yok "
                + "sayıldı (görüntü kaynağı CouchSubs'ın OBS katmanını da içeriyor; OBS'te Kaynak projektörünü seçin)")
        }
        let cleaned = seen.withoutButtonPrompts().withoutOcrNoise().joiningRows()
        // Kamerayla kayan yazı (plaka, tabela, dükkân adı) altyazı değildir (`SceneMotion`, GitHub #1259).
        let moving = sceneMotion.filter(stickyRows.filter(cleaned, at: now()), in: place, at: now())
        for row in stickyRows.newlySticky { log("sabit satır: \(SubtitleLog.excerpt(row)) görev/HUD yazısı sayıldı, çevrilmiyor") }
        for line in sceneMotion.removed { logSceneText(line.text, SceneMotion.reason) }
        // Hareketsiz ürün/ambalaj yazısı (bira kutusu, süt kartonu) altyazı değildir (`PackageText`, Sinan Bey beta.101).
        let packaged = PackageText.filter(moving, in: place, look: PackageText.sampler(area))
        for line in packaged.removed { logSceneText(line.text, PackageText.reason) }
        let rows = packaged.kept
        if mission.observe(stickyRows.removed, area: place, at: now()) {
            log(mission.region == nil ? "görev satırı kalktı" : "görev satırı kendi yerinde gösteriliyor")
            onMissionChanged?(mission.region)
        }
        if mission.clearance != sentClearance {
            if (mission.clearance == nil) != (sentClearance == nil) {
                log(mission.clearance.map { "görev satırının yeri " + String(format: "y %.2f-%.2f", $0.top, $0.bottom)
                    + ": altyazı kutusu onu örtmez, üstüne kayar" }
                    ?? "görev satırının yeri kalktı: altyazı kutusu yerine döner")
            }
            sentClearance = mission.clearance
            server.sendObjective(mission.clearance)
        }
        for line in mission.dropped {
            drops.note("MissionLine", "\(MissionLine.settleMs / 1000) sn dolmadan kalktı, görev sayılmadı, çevrilmedi", line, log: onLog)
        }
        var edge: [Reading] = []
        var sceneTexts: [String] = []
        var staleTexts: [String] = []
        let sticky = stickyRows, readAt = now()
        // Açık zemindeki koyu yazı (duvardaki kâğıt ilan) altyazı değildir (`InkTone`, GitHub #1124); oyunun altyazısı koyu
        // yazıysa (`DarkInkStyle`) renge bakılmaz.
        var darkBlocks: [Reading] = []
        // Menünün geçmiş listesi (`Reading.isHistoryList`; sabit satır süzgecinden önce: liste bir satır kayınca yalnız yeni
        // satır "sabit değil" kalıp altyazı seçiliyordu): hiçbir satırı altyazı olmaz, konuşan adlı satırı menü durumunu
        // bitirmez, bekçi de listeden satır çevirmez. Uygulama ekran yazısı dedektörüne bildirir.
        let listed = cleaned.isHistoryList
        if listed {
            onList?()
            logSceneText(cleaned.text, Reading.listReason)
        }
        let darkInk = darkInkStyle.isGameStyle ? nil : InkTone.sampler(area)
        let reading = listed ? Reading.empty : rows.subtitleBlock(in: place, band: subtitleBand, darkInk: darkInk, dropped: { [weak self] block, reason in
            sceneTexts += block.lines.map(\.text)
            if reason == InkTone.reason { darkBlocks.append(block) }
            self?.logSceneText(block.text, reason)
            self?.onSceneTextDropped?(reason)
        }, notices: { edge.append($0.placed(in: place)) },
           age: { sticky.unchangedMs($0, at: readAt) }, stale: { staleTexts += $0.lines.map(\.text) })
        for block in darkBlocks where darkInkStyle.observe(block, in: place) {
            log("koyu yazılı altyazı: bu oyunun altyazısı koyu yazı sayıldı, açık zemindeki koyu yazı bu oturumda atılmıyor")
        }
        logStale(staleTexts)
        logLeftOut(rows, chosen: reading, logged: sceneTexts + staleTexts + edge.flatMap { $0.lines.map(\.text) })
        // Kenardaki bildirim kartı altyazının yerinde (ekranın ortasında) değil, kendi yerinde çevrilir.
        if notices.observe(edge, at: now()) {
            log(notices.areas.isEmpty ? "kenar bildirimi kalktı" : "kenar bildirimi kendi yerinde gösteriliyor (\(notices.areas.count))")
            onNoticesChanged?(notices.areas)
        }
        subtitleBand.record(reading, in: place)
        if let onDialogue, reading.lines.contains(where: { SpeakerPrefix.split($0.text) != nil }) { onDialogue() }
        // Ekran yazısı okuyucuları altyazıyı ikinci kez çizmesin (bkz. `SubtitleEcho`).
        if echoPaused?() != true { echo?.record(reading, region: region) }
        currentRead = ReadInfo(capturedAt: captured, ocrMs: lastReadMs, confidence: reading.confidence)
        let box = reading.box?.placed(in: place).centeredOnScreen()
        if !sawText, !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sawText = true
            log("ilk yazı: oturum başından \(now() - sessionStart) ms sonra \(SubtitleLog.excerpt(reading.text))")
        }
        if reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !rows.lines.isEmpty { quiet.dropped += 1 } else if !visible.lines.isEmpty { quiet.filtered += 1 }
            reportQuiet()
        } else {
            quiet = QuietReads(since: now())
        }
        // Bölge izi ve satırın yeri: okuma boş dönse de satırın yeri değişmediyse satır silinmez (parlak zemin).
        // Altyazının yerinde yalnız kendi çevirimiz okunduysa (örtme ya da üst üste binen katman) satır kalkmış sayılmaz.
        let ownOnly = !ownLines.isEmpty && reading.lines.isEmpty && OwnSubtitles.coversLine(ownLines, line: lastBox)
        var action: StabilizerAction = ownOnly ? .none
            : stabilizer.feed(reading.text, signature: signature, box: reading.box)
        // Ekranda duran kötü yeniden okuma her karede not edilir; günlüğe bir kez yazılır.
        if let note = stabilizer.note, note != lastNote {
            lastNote = note
            switch note {
            case .worseReread(let text): log("yeniden-okuma: \(SubtitleLog.excerpt(text)) gösterilenden kötü, yok sayıldı")
            case .garbledDropped(let text): log("çöp: \(SubtitleLog.excerpt(text)) kararlı olmadan kalktı, gönderilmedi")
            }
        }
        if let waiting = held {
            let time = now()
            switch action {
            case .translate(let source):
                // Bozuk ve yarım okumaların her biri kararlayıcıya yeni satır gibi görünür.
                let wait = max(waiting.wait, waitFor(source))
                if findPack(source) != nil {
                    // Pakette bulundu: bekleyen okuma çevrilmez, bu okuma her zamanki yoldan gider.
                    held = nil
                    log("bekleyen atıldı: \(SubtitleLog.excerpt(waiting.source)) yerine paketteki satır geldi")
                } else if TextMatch.addsMeaning(source, to: waiting.source),
                          TextMatch.isSimilar(TextMatch.normalize(source), TextMatch.normalize(waiting.source)) {
                    // Olumsuzluk/sayı düzeltmesi bekleyenin yerini alır; yanlış ilk okuma çevrilmez.
                    let merged = Rereads.keepMissingLines(source, older: waiting.source)
                    held = Held(source: merged, box: box ?? waiting.box, since: waiting.since, wait: wait,
                                score: Rereads.score(merged), read: waiting.read)
                    action = .none
                    lineLeft()
                    if time - waiting.since >= wait { flushHeld() }
                } else if Rereads.isRereadOf(source, waiting.source) || Rereads.isRereadOf(waiting.source, source),
                          time - waiting.since < wait {
                    // Aynı satırın başka bir okuması: daha iyisi tutulur, süre baştan başlamaz.
                    if Rereads.score(source) > waiting.score {
                        let merged = Rereads.keepMissingLines(source, older: waiting.source)
                        held = Held(source: merged, box: box ?? waiting.box, since: waiting.since, wait: wait,
                                    score: Rereads.score(merged), read: waiting.read)
                    }
                    action = .none
                    lineLeft()
                } else if Rereads.looksMisread(waiting.source) {
                    // Bekleyen bozuk okumaydı ve yerine başka bir okuma geldi: bozuk okuma çevrilmez.
                    held = nil
                    log("bozuk okuma atıldı: \(SubtitleLog.excerpt(waiting.source)) yerine başka satır geldi")
                } else if Rereads.looksMisread(source), time - waiting.since < waiting.wait {
                    // Araya giren bozuk ve ilgisiz okuma bekleyeni bozmaz; yok sayılır.
                    // Kararlayıcı onu gönderilmiş saymasın: gerçek yeni satırsa bekleme bitince çevrilir.
                    stabilizer.withdrawSent()
                    action = .none
                } else {
                    // Bekleyen temiz bir satırdı, yerine başka satır geldi: önce o çevrilir.
                    flushHeld()
                }
            case .clear, .restore:
                // Bölge boşaldı ya da eski satır geri geldi: bekleyen temiz satır çevrilir, bozuk okuma çevrilmez.
                if Rereads.looksMisread(waiting.source) {
                    held = nil
                    log("bozuk okuma atıldı: \(SubtitleLog.excerpt(waiting.source)) beklerken kalktı")
                } else {
                    flushHeld()
                }
            case .none:
                // Kararlayıcı aynı satır saydı; okuma daha iyiyse (ör. yarım okumanın tamamı) o tutulur.
                let text = reading.text.trimmingCharacters(in: .whitespacesAndNewlines)
                var current = waiting
                if text.count >= 3, Rereads.related(text, waiting.source), Rereads.score(text) > waiting.score {
                    let merged = Rereads.keepMissingLines(text, older: waiting.source)
                    current.source = merged
                    current.box = box ?? waiting.box
                    current.score = Rereads.score(merged)
                    held = current
                }
                if time - current.since >= current.wait { flushHeld() }
            }
        }
        switch action {
        case .none:
            break
        case .clear:
            lastClearAt = now()
            lineLeft()
            clearScreen()
            log("kalktı: bölge boş okundu, ekran temizlendi")
        case .translate(let source):
            translateOrHold(source, box: box)
        case .restore(let source):
            lineLeft()
            restore(source, box: box)
        }
        // Restore önce işlenir: geri görünen satırın leftAt bilgisi temizlenmeden iptal edilmemeli.
        abandonUndisplayableTranslation()
        // Menü listesi okunurken bekçi saymaz: listenin bir satırı 10 sn sonra süzgeçleri atlayıp altyazı olmasın.
        if listed {
            silence = SilenceWatch()
            return
        }
        watchSilence(visible, stages: [("kendi altyazısı", ownLines), ("telefon yazısı", seen.lines),
                                       ("kumanda ipucu ya da okuma gürültüsü", cleaned.lines),
                                       ("sabit satır (görev/HUD)", rows.lines),
                                       ("altyazı bloğu seçilmedi (sahne yazısı, menü ya da başka blok)", reading.lines)],
                     place: place)
    }

    /// Sessizlik bekçisi (`SilenceWatch`): alanda konuşmaya benzeyen satır 10 sn okunup hiçbir şey gönderilmediyse
    /// süzgeçleri atlayıp o satırı doğrudan çevirir (en çok 10 sn'de bir, aynı satırı bir kez). Hangi aşamanın tuttuğu
    /// günlüğe yazılır. Kendi altyazımız ve telefon yazısı hiçbir zaman gönderilmez. İlke: fazladan bir HUD çevirisi
    /// kabul, diyaloğun kaybolması kabul değil (Windows, Android ile aynı).
    private func watchSilence(_ raw: Reading, stages: [(String, [TextLine])], place: TextBox) {
        guard let candidate = silence.due(raw.lines.map(\.text), at: now()) else { return }
        let key = TextMatch.normalize(candidate)
        func holds(_ lines: [TextLine]) -> Bool {
            lines.contains { line in
                let text = TextMatch.normalize(line.text)
                return text.contains(key) || (!text.isEmpty && key.contains(text) && text.count * 2 >= key.count)
            }
        }
        // İlk aşama kendi altyazısı (satır onun içindeyse tutan odur); sonrakiler satırın kalmadığı ilk aşama.
        let holder = holds(stages[0].1) ? stages[0].0 : stages.dropFirst().first { !holds($0.1) }?.0
            ?? "kararlayıcı ya da bekleme (çeviri gönderilmedi)"
        guard holder != "kendi altyazısı", holder != "telefon yazısı" else { return }
        silence.fired(candidate, at: now())
        log("bekçi: \(SubtitleLog.excerpt(candidate)) \(SilenceWatch.silenceMs / 1000) sn'dir okunuyor, hiçbir şey "
            + "gönderilmedi (tutan: \(holder)); doğrudan çevriliyor")
        let box = raw.lines.first { $0.text == candidate }?.box?.placed(in: place).centeredOnScreen()
        lineLeft()
        enqueue(candidate, box: box)
    }

    /// Süren çeviri artık gösterilemeyecekse üretimi iptal eder, böylece sıradaki satır onu beklemez. Yalnız iki durumda:
    /// daha yeni bir satır ekranda gösterilmişse, ya da satırın çevirisi artık geç (`isLate`), satır ekranda değil ve
    /// sırada gösterilebilir yeni bir satır bekliyorsa. Ekranda duran satır üretimi ne kadar uzarsa uzasın iptal edilmez.
    /// İptal edilen satır ekrana geri gelirse (`restore`) yeniden çevrilir. Windows (SubtitlePipeline.cs) ve Android
    /// (SubtitlePipeline.kt) aynı kuralları uygular.
    private func abandonUndisplayableTranslation() {
        guard let current = inFlight, current.session == session, !current.superseded, !current.abandoned,
              work != nil else { return }
        let time = now()
        let replaced = current.number < lastShown
        let expired = current.number > lastShown && current.number != lineOnScreen && isLate(current, at: time)
        guard replaced || expired else { return }
        let hasWaiting = waiting.contains {
            $0.session == session && !$0.superseded && !$0.abandoned && !isLate($0, at: time)
        }
        guard replaced || hasWaiting else { return }
        current.abandoned = true
        log(current, replaced ? "bırakıldı: daha yeni satır gösterildi" : "bırakıldı: gösterim süresi doldu, yeni satır bekliyor")
        work?.cancel()
    }

    /// Satırın çevirisi artık gösterilemeyecek kadar geç mi. Ekrandaki satır hiçbir zaman geç değildir. Süre satırın
    /// kalktığı andan, sırada beklediyse çevirisinin başladığı andan sayılır (`lateResultMs`); arkasından yeni satır
    /// gelmişse yeni satır onu beklediği için `queuedLateResultMs`'e kadar gösterilir (GitHub #893). Windows ve Android aynı.
    private func isLate(_ request: Request, at time: Int) -> Bool {
        guard let left = request.leftAt else { return false }
        if time - left > Self.queuedLateResultMs { return true }
        if request.number < lastRequested { return false }
        return time - max(left, request.startedAt ?? time) > Self.lateResultMs
    }

    /// Süren ve sırada bekleyen istekler.
    private var requests: [Request] { (inFlight.map { [$0] } ?? []) + waiting }

    /// Ekrandaki satır kalktı (ya da yerine başkası geldi); çevirisi sürüyorsa ne zaman kalktığı not edilir.
    private func lineLeft() {
        guard let number = lineOnScreen else { return }
        let time = now()
        for request in requests where request.number == number && request.leftAt == nil {
            request.leftAt = time
        }
        lineOnScreen = nil
    }

    /// Bekletilen okumayı çeviriye gönderir.
    private func flushHeld() {
        guard let waiting = held else { return }
        held = nil
        enqueue(waiting.source, box: waiting.box, read: waiting.read)
    }

    private func findPack(_ source: String) -> PackMatch? {
        if let pending = held, isPackedFragment(source, of: pending.source),
           Rereads.allLinesCovered(source, by: pending.source), Rereads.score(source) <= pending.score { return nil }
        guard let packLookup else { return nil }
        if let found = packLookup(source) { return found }
        guard let prefix = SpeakerPrefix.split(source) else { return nil }
        return packLookup(prefix.body)
    }

    /// Bozuk ya da yarım olabilecek okuma hemen çevrilmez, kısa süre bekletilir; aynı satırın daha iyi okuması gelirse o
    /// çevrilir. Temiz ve tam cümle ya da pakette bulunan satır beklemeden gider (Windows: TranslateOrHold).
    private func translateOrHold(_ source: String, box: TextBox?) {
        if quietDrop(source, box: box) { return }
        if restoreQueued(source) { return }
        if nameRead(source) { return }
        if !holdReadings { lineLeft(); return enqueue(source, box: box) }
        let packed = findPack(source) != nil
        let time = now()
        // Az önce çevrilen satırın daha iyi olmayan yeniden okuması yeni satır değildir (TV'de üst üste binmesin).
        if let last = lastSent, (!packed || (last.at > lastClearAt && isPackedFragment(source, of: last.source))),
           time - last.at < Self.rereadWithinMs, Rereads.allLinesCovered(source, by: last.source), Rereads.score(source) <= last.score {
            lastSent = (last.source, last.score, time)
            log("yeniden-okuma: \(SubtitleLog.excerpt(source)) az önce çevrilenden iyi değil, yok sayıldı")
            return
        }
        lineLeft()
        if packed { return enqueue(source, box: box) }
        let wait = waitFor(source)
        guard wait > 0 else { return enqueue(source, box: box) }
        held = Held(source: source, box: box, since: time, wait: wait, score: Rereads.score(source), read: currentRead)
        log("bekletiliyor (en çok \(wait) ms): \(SubtitleLog.excerpt(source))")
    }

    /// Kararlı satır altyazı adayı değil (`SettledText`): karara bağlanmış ve hâlâ ekranda duruyor (sessizce geçilir),
    /// Türkçe (harfleri bozulmuş da olsa; bekletilmeden atılır), zaten hedef dilde olan aynı yerdeki bloğun bozuk okunmuş
    /// parçası, ya da kapanmayan parantezle bölünmüş çöp okuma (`OcrNoise.looksBracketGarbled`). Atılan satır günlüğe bir
    /// kez yazılır. Windows (QuietDrop) ve Android (quietDrop) aynı kuralları uygular.
    private func quietDrop(_ source: String, box: TextBox?) -> Bool {
        if settled.isSettled(source) {
            if let reason = settled.noteSkip(source) {
                drops.note("SettledText", "karara bağlanmış satırla \(reason), yeniden işlenmedi", source, log: onLog)
            }
            return true
        }
        let note: String
        let target = skipsTurkish && TurkishText.looksTurkish(source)
        if target {
            note = "\(SubtitleLog.excerpt(source)) → zaten Türkçe, çevrilmedi"
        } else if settled.isTargetFragment(source, box: box) {
            note = "altyazı sayılmadı: \(SubtitleLog.excerpt(source)) zaten hedef dilde olan satırın bozuk okunmuş parçası, çevrilmedi"
        } else if OcrNoise.looksBracketGarbled(source) {
            note = "altyazı sayılmadı: \(SubtitleLog.excerpt(source)) çöp okuma (kapanmayan parantezle bölünmüş sözcük), çevrilmedi"
        } else {
            return false
        }
        // Ekrandaki satırın yerine altyazı olmayan yazı geldi: önceki satır kalkmış sayılır.
        lineLeft()
        settled.settle(source, box: box, target: target, shown: false, loose: true, at: now())
        log(note)
        return true
    }

    /// Konuşan adı sonradan okundu: ilk karede renkli ad okunamayıp cümle adsız gitmiş, sonraki karede aynı cümle
    /// "JASON: …" diye okunmuş. Bu yeni satır değildir; cümle yeniden çevrilmez, ekrandaki (ya da süren) çeviriye ad
    /// eklenir ve TV'de aynı satırın yerine geçer. Yoksa her diyalog satırı önce adsız beyaz, sonra adlı renkli iki kez
    /// görünüyordu (X: "çift altyazı"). Windows (NameRead) ve Android (nameRead) aynı kuralı uygular.
    private func nameRead(_ source: String) -> Bool {
        guard let prefix = SpeakerPrefix.split(source) else { return false }
        if let request = requests.last(where: {
            $0.session == session && !$0.superseded && !$0.abandoned && $0.prefix == nil && Self.sameSentence(prefix.body, $0.source)
        }) {
            request.source = source
            request.prefix = prefix
            request.leftAt = nil
            lineOnScreen = request.number
            lastSent = (source, Rereads.score(source), now())
            log(request, "konuşan adı okundu (\(SubtitleLog.excerpt(prefix.name))): çeviri adla gösterilecek, yeniden çevrilmedi")
            return true
        }
        guard let shown = lineOnScreen, shown == lastShown, let last = lastPair, SpeakerPrefix.split(last.source) == nil,
              Self.sameSentence(prefix.body, last.source) else { return false }
        let translated = SpeakerPrefix.present(last.translation, source: source, show: showSpeakerNames)
        remember(shown, source, translated)
        lastSent = (source, Rereads.score(source), now())
        log("#\(shown) konuşan adı okundu (\(SubtitleLog.excerpt(prefix.name))): ekrandaki çeviriye eklendi, yeniden çevrilmedi")
        if translated != last.translation {
            send(translated, source: source, durationMs: 15000, box: lastBox, replaces: true)
            onPair?(source, translated)
        }
        lastPair = (source, translated)
        return true
    }

    /// Adın ayrıldığı cümle, adsız okunan cümleyle aynı mı (yazı tanıma farkı kadar; olumsuzluk ya da sayı eklenmemiş).
    static func sameSentence(_ body: String, _ unnamed: String) -> Bool {
        let a = TextMatch.normalize(body), b = TextMatch.normalize(unnamed)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || (TextMatch.isSimilar(a, b, threshold: 0.9) && !TextMatch.addsMeaning(body, to: unnamed)
            && !TextMatch.addsMeaning(unnamed, to: body))
    }

    // Paket eşleşmesi tek başına eksik parçayı yeni replik yapmaz. Tam kısa cümleler korunur.
    private func isPackedFragment(_ source: String, of previous: String) -> Bool {
        if Rereads.looksComplete(source) { return false }
        let fragment = TextMatch.normalize(source), full = TextMatch.normalize(previous)
        return !fragment.isEmpty && fragment.count < full.count && (" " + full + " ").contains(" " + fragment + " ")
    }

    /// Bozuksa `packWait`, temiz ama yarım olabilecekse `cleanWait`, temiz ve tam cümleyse 0.
    private func waitFor(_ source: String) -> Int {
        guard holdReadings else { return 0 }
        if Rereads.looksMisread(source) { return max(0, packWait) }
        return Rereads.looksComplete(source) ? 0 : max(0, cleanWait)
    }

    private func enqueue(_ source: String, box: TextBox?, read: ReadInfo? = nil) {
        lastRequested += 1
        let request = Request(number: lastRequested, source: source, box: box, session: session, read: read ?? currentRead)
        lineOnScreen = request.number
        lastSent = (source, Rereads.score(source), now())
        // Türkçe satır (harfleri bozulmuş da olsa) pakette aranmaz: paket anahtarları İngilizcedir; PS5'in Türkçe menü
        // satırı ("Yakin zamanda olu...") paketteki bozuk bir parçayla eşleşip "Yakın zamanda öldü." gösteriliyordu.
        if skipsTurkish, TurkishText.looksTurkish(source) {
            remember(request.number, source, nil)
            settled.settle(source, box: box, target: true, shown: false, loose: true, at: now())
            log(request, "\(SubtitleLog.excerpt(source)) → zaten Türkçe, çevrilmedi")
            return
        }
        if let packed = packMatch(request) {
            showPacked(request, packed)
            return
        }
        onPackMiss?(source)
        guard let current = inFlight else {
            log(request, "\(SubtitleLog.excerpt(source)) → çeviriye")
            inFlight = request
            pump = Task { [weak self] in await self?.runPump() }
            return
        }
        log(request, "\(SubtitleLog.excerpt(source)) → sırada (çeviri sürüyor: #\(current.number))")
        // Aynı cümlenin eski okuması sırada bekliyorsa çıkar; sıra dolduysa en eski bekleyen atlanır.
        for old in waiting where replacesQueued(source, old.source) {
            log(old, "atıldı: yerine düzelmiş okuması geldi (#\(request.number))")
        }
        waiting.removeAll { replacesQueued(source, $0.source) }
        waiting.append(request)
        if waiting.count > Self.maxWaiting {
            for old in waiting.prefix(waiting.count - Self.maxWaiting) { log(old, "atıldı: sıra doldu") }
            waiting.removeFirst(waiting.count - Self.maxWaiting)
        }
        // Süren çeviri bu cümlenin yarım okumasınınsa (daktilo efekti) beklenmez: bırakılır, tamamı hemen çevrilir.
        if !current.superseded, !current.abandoned, current.session == session, TextMatch.isGrowth(source, of: current.source) {
            log(current, "bırakıldı: uzamış okuması geldi (#\(request.number))")
            current.superseded = true
            work?.cancel()
        }
    }

    // Tam okuma geri gelirse aradaki kısalmış kayıtları birleştir; sıra ve okuma zamanı korunur.
    // Doğrulanmış boş bölgeyi aşma: kısa metin ayrı bir replik olabilir.
    private func restoreQueued(_ source: String) -> Bool {
        guard let full = waiting.last(where: { $0.source == source }),
              let left = full.leftAt, left > lastClearAt else { return false }
        let fragment: (Request) -> Bool = { $0.number > full.number && TextMatch.isGrowth(source, of: $0.source) }
        guard waiting.contains(where: fragment) else { return false }
        for old in waiting where fragment(old) { log(old, "atıldı: tam okuması geri geldi (#\(full.number))") }
        waiting.removeAll(where: fragment)
        lineLeft()
        full.leftAt = nil
        lineOnScreen = full.number
        lastSent = (source, Rereads.score(source), now())
        return true
    }

    // Yerleşim benzerliği simetriktir; kısalan okuma daha tam kuyruk kaydını silemez.
    private func replacesQueued(_ source: String, _ previous: String) -> Bool {
        TextMatch.isRevision(source, of: previous) && !TextMatch.isGrowth(previous, of: source)
    }

    /// Satır az önce gösterilenin uzamış ya da düzelmiş okuması mı (TV yerine koyar, üstüne yığmaz).
    private func revisesShown(_ source: String) -> Bool {
        guard let shown = lastPair?.source else { return false }
        return TextMatch.isRevision(source, of: shown)
    }

    /// Paket önce adlı satırla, bulunmazsa adsız cümleyle aranır (paket anahtarları çoğu zaman adsızdır).
    private func packMatch(_ request: Request) -> PackMatch? {
        guard let packLookup else { return nil }
        if let found = packLookup(request.source) { return found }
        guard let prefix = request.prefix, let found = packLookup(prefix.body) else { return nil }
        return PackMatch(text: found.text, spoken: SpeakerPrefix.voiced(found.spoken, prefix: prefix))
    }

    /// Gösterilecek çeviri: konuşan adı ayara göre başa eklenir ya da atılır.
    private func present(_ translation: String, _ request: Request) -> String {
        SpeakerPrefix.present(translation, source: request.source, show: showSpeakerNames)
    }

    /// Paketteki Türkçe hemen gösterilir; süren çevirinin sonucu (eski satır) artık gösterilmez.
    private func showPacked(_ request: Request, _ packed: PackMatch) {
        for old in waiting { log(old, "atıldı: sonraki satır paketten geldi (#\(request.number))") }
        waiting.removeAll()
        packHits += 1
        let source = request.source
        let translated = present(packed.text, request)
        let shouldSend = stabilizer.shouldSend(source: source, translation: translated)
        remember(request.number, source, shouldSend ? translated : nil)
        let pack = packName?().map { "paket:" + $0 } ?? "paket"
        settled.settle(source, box: request.box, target: !shouldSend, shown: shouldSend, at: now())
        guard shouldSend else {
            log(request, "\(SubtitleLog.excerpt(source)) → \(pack), zaten hedef dilde, gösterilmedi")
            return
        }
        let metrics = measure(request, translation: nil, origin: .pack)
        log(request, "\(SubtitleLog.excerpt(source)) → \(pack)")
        lastShown = request.number
        send(translated, source: source, durationMs: 15000, box: request.box, replaces: revisesShown(source))
        lastPair = (source, translated)
        lastBox = request.box
        lastOrigin = "paket"
        lastMetrics = metrics
        onMetrics?(metrics)
        onPair?(source, translated)
        onSpeech?(packed.spoken)
    }

    /// Az önce kalkıp geri gelen satır: çevirmene gitmeden eski çevirisi yeniden gösterilir.
    private func restore(_ source: String, box: TextBox?) {
        if restoreQueued(source) { return }
        if let pair = pairs.last(where: { $0.source == source }) {
            lineOnScreen = pair.number
            // Atılan satır ekranda durdukça her geri gelişi günlüğe yazılmaz (`SettledText`).
            guard let translation = pair.translation else {
                if !settled.isSettled(source) { log("#\(pair.number) geri geldi: \(SubtitleLog.excerpt(source))") }
                return
            }
            log("#\(pair.number) geri geldi: \(SubtitleLog.excerpt(source))")
            send(translation, source: source, durationMs: 15000, box: box, replaces: revisesShown(source))
            lastPair = (source, translation)
            lastBox = box
            return
        }
        // Çevirisi henüz gelmediyse istek sürüyordur; satır yeniden ekranda sayılır.
        for request in requests where request.source == source && request.session == session && !request.superseded && !request.abandoned {
            request.leftAt = nil
            lineOnScreen = request.number
            return
        }
        // Çevirisi hiç yoksa (atlanmış ya da başarısız olmuş) normal yoldan çevrilir; altyazı adayı olmayan satır
        // (Türkçe, Türkçe bloğun parçası, çöp ya da ekranda duran atılmış satır) yine atılır.
        if quietDrop(source, box: box) { return }
        enqueue(source, box: box)
    }

    /// Süren çeviriyi, bitince de sıradakini çevirir; sıra boşalınca durur.
    private func runPump() async {
        while let request = inFlight {
            await translate(request)
            // Ekrandan çoktan kalkmış satır çevrilmez; çevirisi zaten gösterilmeyecekti.
            let time = now()
            for old in waiting {
                if old.session != session {
                    log(old, "atıldı: oturum bitti")
                } else if let left = old.leftAt, isLate(old, at: time) {
                    log(old, "atıldı: çevrilmeden ekrandan kalktı (\(time - left) ms önce)")
                }
            }
            waiting.removeAll { $0.session != session || isLate($0, at: time) }
            inFlight = waiting.isEmpty ? nil : waiting.removeFirst()
        }
    }

    /// Süren bütün çevirilerin bitmesini bekler.
    public func waitForTranslations() async {
        while inFlight != nil, let pump { await pump.value }
    }

    /// Satır ekrandan kalktıktan sonra gelen çevirinin TV'de kalacağı süre (TV uygulamasıyla aynı kural).
    public static func readingTime(for text: String) -> Int {
        min(8000, 2000 + text.count * 60)
    }

    private func translate(_ request: Request) async {
        var source = request.source
        let started = now()
        request.startedAt = started
        let probe = TranslationProbe()
        do {
            let translator = self.translator
            let input = request.prefix?.body ?? source
            // Ayrılan ad çevirmene gitmez; cümle içinde geçtiğinde korunsun diye ayrıca bildirilir (#287).
            if let name = request.prefix?.name { translator.noteSpeaker(name) }
            let work = Task { try await TranslationProbe.$current.withValue(probe) { try await translator.translate(input) } }
            self.work = work
            defer { self.work = nil }
            let sentence = try await work.value
            // Çeviri sürerken konuşan adı okunduysa (`nameRead`) çeviri adlı okumayla gösterilir.
            source = request.source
            let translated = present(sentence, request)
            let finished = now()
            let result = "\(probe.outcome()) \(finished - started) ms"
            guard request.session == session, !request.abandoned else {
                log(request, "\(result), atıldı: \(request.abandoned ? "istek bırakıldı" : "oturum bitti")")
                return
            }
            lastError = nil
            onTranslationResult?(nil)
            let shouldSend = stabilizer.shouldSend(source: input, translation: sentence)
            remember(request.number, source, shouldSend ? translated : nil)
            if !shouldSend { settled.settle(source, box: request.box, target: true, shown: false, at: now()) }
            guard request.number > lastShown, shouldSend, !request.superseded else {
                let reason = !shouldSend ? "zaten hedef dilde"
                    : request.superseded ? "uzamış okuması geldi" : "daha yeni satır gösterildi (#\(lastShown))"
                log(request, "\(result), atıldı: \(reason)")
                return
            }
            let onScreen = request.number == lineOnScreen
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if !onScreen, let left = request.leftAt, isLate(request, at: now()) {
                log(request, "\(result), geç: satır \(now() - left) ms önce kalktı, gösterilmedi")
                return
            }
            let metrics = measure(request, translation: (started, finished), origin: .engine)
            log(request, "\(result), gösterildi\(onScreen ? "" : " (satır kalkmıştı)")")
            settled.settle(source, box: request.box, target: false, shown: true, at: now())
            lastShown = request.number
            // Satır hâlâ ekrandaysa kalkınca silinir; kalktıysa okunacak kadar gösterilir.
            send(translated, source: source, durationMs: onScreen ? 15000 : Self.readingTime(for: translated), box: request.box,
                 replaces: revisesShown(source))
            lastPair = (source, translated)
            lastBox = request.box
            lastOrigin = "motor"
            lastMetrics = metrics
            onMetrics?(metrics)
            onPair?(source, translated)
            if let onSpeech { onSpeech(SpeakerPrefix.voiced(translator.spokenLines(for: input), prefix: request.prefix)) }
        } catch {
            // Yerine uzamış okuması gelen satırın bırakılan çevirisi hata sayılmaz.
            guard request.session == session, !request.superseded, !request.abandoned else { return }
            let retry = request.number == lineOnScreen ? ", satır ekrandayken yeniden denenecek" : ""
            log(request, "hata (\(now() - started) ms): \(error)\(retry)")
            // Dil paketi eksikse ya da geçici bir hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
            lastError = error as? TranslatorError
            onTranslationResult?(lastError)
            if request.number == lineOnScreen {
                stabilizer.forgetSent()
                // Çevrilemeyen satırın yeniden okuması "az önce çevrilen" sayılıp atlanmasın; yeniden denensin.
                if lastSent?.source == request.source { lastSent = nil }
            }
        }
    }

    /// Satır şimdi TV'ye gidiyor: okunduğu kareden bu ana kadarki ölçümler.
    private func measure(_ request: Request, translation: (started: Int, finished: Int)?, origin: LineMetrics.Origin) -> LineMetrics {
        LineMetrics.measure(capturedAt: request.read.capturedAt, ocrMs: request.read.ocrMs, translation: translation, sentAt: now(),
                            confidence: request.read.confidence, origin: origin)
    }

    private func remember(_ number: Int, _ source: String, _ translation: String?) {
        pairs.removeAll { $0.source == source }
        pairs.append((number, source, translation))
        if pairs.count > Self.rememberedPairs { pairs.removeFirst() }
    }

    /// Okumanın hemen başlaması için modelleri önceden yükler; ilk okuma yoksa saniyelerce sürer.
    public func warmUp() {
        let reader = self.reader
        let readQueue = self.readQueue
        Task.detached(priority: .utility) {
            let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let image = context?.makeImage() {
                _ = try? await readQueue.run(priority: .background, detail: "ısınma (ilk okuma, model yükleniyor)") { try reader.read(image) }
            }
        }
        let translator = self.translator
        Task { await translator.warmUp() }
    }

    /// Sahne yazısı sayılıp atılan blok günlüğe nedeniyle bir kez yazılır (GitHub #822: atılan altyazı günlükte görünsün).
    /// Her eleme nedeniyle sayılır (`RejectTally`): satır sonunda o nedenin sayısı, dakikada bir neden başına özet.
    private func logSceneText(_ text: String, _ reason: String) {
        let key = text + "|" + reason
        let fresh = !loggedSceneText.contains(key)
        if fresh {
            loggedSceneText.append(key)
            if loggedSceneText.count > 20 { loggedSceneText.removeFirst() }
        }
        let line = fresh ? "sahne yazısı: \(SubtitleLog.excerpt(text)) altyazı sayılmadı (\(reason))" : nil
        for entry in rejects.note(reason, line: line, now: now()) { log(entry) }
    }

    /// Kendi satırı ayrıca yazılan eleme (telefon, sabit blok) yalnız sayılır (`RejectTally`).
    private func countReject(_ reason: String) {
        for entry in rejects.note(reason, line: nil, now: now()) { log(entry) }
    }

    /// Uzun süredir değişmeyen ortalı blok (haber bandı) yeni beliren bloğun yanında altyazı sayılmadı (GitHub #933).
    private func logStale(_ texts: [String]) {
        if !texts.isEmpty { countReject("sabit blok (\(Reading.staleMs / 1000) sn değişmeyen)") }
        let key = texts.joined(separator: "\n")
        guard key != loggedStale else { return }
        loggedStale = key
        guard !texts.isEmpty else { return }
        log("sabit blok atlandı: \(SubtitleLog.excerpt(key)) \(Reading.staleMs / 1000) sn'dir değişmiyor, yanında yeni ortalı blok var")
    }

    /// Alanda okunup altyazı bloğu seçilmeyen satırlar (menü, HUD etiketi, seçilmeyen alt/üst blok) günlüğe yazılır;
    /// sahne yazısı ve kenar bildirimi kendi satırıyla yazıldığı için burada yoktur. Eskiden sessizce atılıyordu: iPhone
    /// 1.0.6'da (2026-11-22) altyazı hiç çevrilmeyince günlükte nedeni görünmüyordu. Aynı küme art arda yazılmaz.
    private func logLeftOut(_ rows: Reading, chosen: Reading, logged: [String]) {
        let kept = Set(chosen.lines.map(\.text)), skip = Set(logged)
        let left = rows.lines.map(\.text).filter { !kept.contains($0) && !skip.contains($0) }
        let key = left.joined(separator: "\n")
        guard key != loggedLeftOut else { return }
        loggedLeftOut = key
        guard !left.isEmpty else { return }
        let picked = chosen.lines.isEmpty ? "altyazı bloğu yok" : "seçilen: \(SubtitleLog.excerpt(chosen.text))"
        log("altyazı sayılmadı: \(SubtitleLog.excerpt(left.joined(separator: "\n"))) (\(picked))")
    }

    /// Ekranda menü var (otomatik ekran yazısı menü durumunda): bu karenin altyazısı gönderilmez, bekletilir
    /// (`MenuHeldSender`). Sessizlik özetinde sayılır. Eskiden bu
    /// atlama günlüğe hiç yazılmıyordu: Mac'te (beta.80, PS5, GTA 6) ekranda diyalog varken altyazı günlüğüne dakikalarca
    /// hiçbir satır düşmüyor, okunmadığı mı, boş mu okunduğu mu anlaşılmıyordu.
    public func skipForMenu() {
        // Geçiş günlüğe uygulamada yazılır (`ScreenTextDetector.menuLog`); burada yalnız sessizlik özetine sayılır.
        quiet.menu += 1
        reportQuiet()
    }

    /// Altyazı alanında `QuietReads.reportAfterMs`'dir yazı çıkmadıysa nedeni günlüğe yazılır, sayaç yeniden başlar.
    private func reportQuiet() {
        let time = now()
        guard time - quiet.since >= QuietReads.reportAfterMs else { return }
        log(quiet.summary(at: time))
        quiet = QuietReads(since: time)
    }

    /// Aramanın sonucundan sonra süzgecin kullanacağı telefon: bulunduysa o; açık telefon bulunamadıysa
    /// `GamePhoneTracker.missGrace` arama boyunca son yeri kalır, sonra nil.
    /// Aramadan sonra doğrulanmamış telefon adayı ve ilk görüldüğü an: aday yoksa nil; önceki adayın yakınındaysa ilk
    /// görüldüğü an korunur (bekletme süresi uzamaz), değilse şimdi başlar (Windows ve Android ile aynı).
    static func candidate(_ weak: ScreenPhoneCard.Handset?, previous: ScreenPhoneCard.Handset?, since: Int,
                          now: Int) -> (ScreenPhoneCard.Handset?, Int) {
        guard let weak else { return (nil, 0) }
        func region(_ box: TextBox) -> CropRegion { CropRegion(top: box.top, bottom: box.bottom, left: box.left, right: box.right) }
        let same = previous.map { region(weak.bounds).isClose(to: region($0.bounds), tolerance: 0.035) } ?? false
        return (weak, same && now >= since ? since : now)
    }

    /// Doğrulanmamış adayın satırları hâlâ bekletilir mi (`candidateHoldMs`).
    static func holdsCandidate(_ candidate: ScreenPhoneCard.Handset?, since: Int, now: Int) -> Bool {
        candidate != nil && now >= since && now - since < candidateHoldMs
    }

    static func heldPhone(_ found: ScreenPhoneCard.Handset?, shown: ScreenPhoneCard.Handset?, misses: inout Int) -> ScreenPhoneCard.Handset? {
        if let found {
            misses = 0
            return found
        }
        guard let shown, misses < GamePhoneTracker.missGrace else {
            misses = 0
            return nil
        }
        misses += 1
        return shown
    }

    /// Okuma durunca TV'deki son altyazıyı kaldırır.
    public func reset() {
        log("hat sıfırlandı (paketten \(packHits) satır)")
        sessionStart = now()
        quiet = QuietReads(since: sessionStart)
        sawFrame = false
        sawText = false
        lastNote = nil
        phone = nil
        phoneLookedAt = nil
        phoneMisses = 0
        phoneCandidate = nil
        phoneCandidateSince = 0
        loggedLeftOut = ""
        loggedStale = ""
        loggedPhone = nil
        silence = SilenceWatch()
        session += 1
        lineOnScreen = nil
        held = nil
        lastSent = nil
        lastClearAt = Int.min
        waiting.removeAll()
        // Apple'ın çevirisi görev iptaline uyar; süren çeviri beklenmeden bırakılır.
        work?.cancel()
        pairs.removeAll()
        lastOcrReading = .empty
        lastReadMs = nil
        scheduler.reset()
        stickyRows.reset()
        sceneMotion.reset()
        subtitleBand.reset()
        darkInkStyle.reset()
        loggedSceneText.removeAll()
        rejects.reset()
        settled.reset()
        mission.reset()
        if sentClearance != nil {
            sentClearance = nil
            server.sendObjective(nil)
        }
        notices.reset()
        echo?.reset()
        loggedOwn = nil
        if stabilizer.reset() == .clear { clearScreen() }
        own.reset()
    }
}

/// Altyazı alanında yazı çıkmayan pencerenin sayaçları (tanı): kaç kare geldi, kaçı okundu, okumalar boş mu döndü,
/// satırlar hangi süzgeçte kaldı, okuma hata mı verdi, menü yüzünden mi okunmadı.
struct QuietReads: Equatable {
    /// Bu kadar süre altyazı alanından yazı çıkmazsa günlüğe özet yazılır (sessizlik boyunca bu aralıkla bir satır).
    static let reportAfterMs = 60_000

    var since: Int
    var frames = 0
    var menu = 0
    var reads = 0
    /// Yazı tanıma alanda hiç satır bulmadı.
    var empty = 0
    /// Satırlar kendi altyazısı ya da telefon yazısı sayıldı, ya da kumanda ipucu/gürültü/sabit satır olarak ayıklandı.
    var filtered = 0
    /// Satırlar kaldı ama altyazı bloğu seçilmedi (sahne yazısı, kenar bildirimi).
    var dropped = 0
    var failures = 0
    var lastError: String?

    func summary(at time: Int) -> String {
        var text = "altyazı alanında \((time - since) / 1000) sn'dir yazı yok: \(frames) kare, \(menu) kare menü yüzünden okunmadı, "
            + "\(reads) okuma (\(empty) boş, \(filtered) ayıklandı, \(dropped) altyazı sayılmadı, "
            + "\(failures) hata)"
        if let lastError { text += "; son hata: \(lastError)" }
        return text
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
