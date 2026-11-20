// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Altyazıları TV'ye ileten taraf (gerçekte `SubtitleServer`).
public protocol SubtitleSending: AnyObject {
    /// `box`: oyundaki altyazının karedeki yeri (kenarlara oranla), bilinmiyorsa nil.
    /// `replaces`: satır az önce gösterilenin uzamış ya da düzelmiş okumasıdır; TV onu öncekinin üstüne yığmaz.
    func sendSubtitle(_ text: String, durationMs: Int, box: TextBox?, replaces: Bool)
    func clear()
}

extension SubtitleServer: SubtitleSending {}

/// Kare → bölge → yazı tanıma → kararlılık → çeviri → TV.
@MainActor
public final class SubtitlePipeline {
    /// Satır ekrandan bundan uzun süre önce kalktıysa geç gelen çevirisi gösterilmez (sonraki sahnenin üstüne düşmesin).
    /// Yavaş çeviride (ücretsiz motor, zayıf işlemci) art arda gelen satırların çevirisi satır kalktıktan bir iki saniye
    /// sonra gelir; sınır 1 sn iken üç satırlık konuşmanın yalnız ilki görünüyordu.
    public static let lateResultMs = 2500
    /// Çeviri sürerken sırada en çok bu kadar satır bekler; daha eskisi atlanır (kuyruk konuşma hızıyla büyümesin).
    public static let maxWaiting = 2
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
        let source: String
        let box: TextBox?
        let session: Int
        /// Baştaki konuşan adı ("ARTHUR: …"); çeviriye yalnız cümle gider.
        let prefix: SpeakerPrefix.Split?
        /// Satırı kararlı yapan karenin geldiği an, o okumanın süresi ve güveni (ölçümler için).
        let read: ReadInfo
        /// Satırın ekrandan kalktığı an (hâlâ ekrandaysa nil).
        var leftAt: Int?
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
    private var lastPanelReading = Reading.empty
    private var stickyRows = StickyRows()
    private var mission = MissionLine()
    /// Görev satırının bölgesi değişti (nil: görev kalktı). Görev altyazıya girmez; bölgesi "auto-mission" ek alanı olarak
    /// kendi yerinde ve özgün stilinde gösterilir (bkz. `MissionLine`).
    public var onMissionChanged: ((CropRegion?) -> Void)?
    /// Son yazı tanımanın süresi (ms); kare değişmeyip okuma yeniden kullanılınca da o okumanın süresi geçerlidir.
    private var lastReadMs: Int?
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
    /// Yalnız GTA 6 altyazı renginin üstündeki OCR satırlarını oku.
    public var watchSubtitleBackground = false
    /// Hiçbir pakette bulunmayan kararlı satır (ortak havuz için).
    public var onPackMiss: ((String) -> Void)?
    /// Son gösterilen çevirinin nereden geldiği: "paket" ya da "motor" (günlük ve sayım için).
    public private(set) var lastOrigin: String?
    /// Bu hatta paketten gelen satır sayısı.
    public private(set) var packHits = 0
    /// Altyazı günlüğü (`SubtitleLog`): ilk kare, okunan her kararlı satır ve akıbeti (paket, önbellek, çeviri, geç
    /// kaldı, atıldı), çöp sayılıp bırakılan ve yok sayılan yeniden okumalar. Kararları değiştirmez.
    public var onLog: ((String) -> Void)?
    /// Paket isabetinde satırın geldiği paket (günlük için; bilinmiyorsa nil).
    public var packName: (() -> String?)?
    /// Oturumun (hat kurulunca ya da sıfırlanınca) başladığı an; ilk karenin ne kadar sonra geldiği günlüğe yazılır.
    private var sessionStart: Int
    private var sawFrame = false
    private var sawText = false
    private var lastNote: StabilizerNote?

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
        sessionStart = clock()
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
        // Okuma sürerken hat sıfırlandıysa (çeviri durdu, hat yeniden kuruldu) bu karenin sonucu yeni oturuma karışmaz:
        // geç biten eski okuma TV'ye eski satırı göndermesin.
        let startedSession = session
        // Yazı tanıma uzun sürebilir; arayüz takılmasın diye ana iş parçacığının dışında yapılır.
        let reader = self.reader
        let watchSubtitleBackground = self.watchSubtitleBackground
        let (area, signature) = await Task.detached(priority: .userInitiated) {
            let area = RegionCropper.crop(frame, to: region)
            return (area, RegionCropper.signature(of: area))
        }.value
        guard session == startedSession else { return }
        var visible = lastOcrReading
        var panelLeft = false
        var plan = scheduler.plan(signature: signature)
        if case .reuse = plan, watchSubtitleBackground {
            let cached = lastOcrReading
            if cached.lines.contains(where: { $0.box != nil }) {
                visible = await Task.detached(priority: .userInitiated) {
                    SubtitleBackground.filter(cached, in: area)
                }.value
                guard session == startedSession else { return }
                // Panel yeni bir kutunun altına geldiyse eski HUD yazısını diyalog sanma.
                if !visible.lines.allSatisfy(lastPanelReading.lines.contains) { plan = .read(deep: false) }
                // Aynı kutular yeniden sınandı ve panel yoksa bu boşluk bir OCR kaçağı değil.
                panelLeft = !lastPanelReading.lines.isEmpty && visible.lines.isEmpty
            } else {
                visible = .empty
            }
        }
        if case .read(let deep) = plan {
            let started = now()
            // Okuma kendi sırasında (`ReadQueue`) yapılır, Swift havuzunu tutmaz; takılırsa süre dolunca kare atlanır (#507).
            let result: Result<(ocr: Reading, visible: Reading), Error>
            do {
                result = .success(try await readQueue.run {
                    let ocr = try reader.readLines(area, deep: deep)
                    return (ocr, watchSubtitleBackground ? SubtitleBackground.filter(ocr, in: area) : ocr)
                })
            } catch {
                result = .failure(error)
                if case ReadQueueError.timedOut(let ms) = error { log("okuma \(ms) ms'de bitmedi; kare atlandı") }
            }
            guard session == startedSession else {
                log("eski okuma \(now() - started) ms sonra bitti, hat sıfırlanmıştı; atıldı")
                return
            }
            lastReadMs = now() - started
            let observations = try? result.get()
            lastOcrReading = observations?.ocr ?? .empty
            visible = observations?.visible ?? .empty
            onReadResult?(result.failure)
            scheduler.record(visible.text)
        }
        lastPanelReading = watchSubtitleBackground ? visible : .empty
        // Kumanda ipuçları ("R2 Swing") altyazı değildir; çevrilmez, yeri de altyazının yerine katılmaz.
        // Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") de çevirmene gitmez.
        // Alandaki menü ve köşe göstergeleri de altyazı değildir; yalnız altyazı bloğu çevrilir ve kutusu ona göre olur.
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        // Konuşma değişirken sabit duran görev/HUD satırı ("Get in the sea plane", GTA 6) altyazı bloğuna katılmaz.
        let rows = stickyRows.filter(visible.withoutButtonPrompts().withoutOcrNoise().joiningRows(), at: now())
        for row in stickyRows.newlySticky { log("sabit satır: \(SubtitleLog.excerpt(row)) görev/HUD yazısı sayıldı, çevrilmiyor") }
        if mission.observe(stickyRows.removed, area: place, at: now()) {
            log(mission.region == nil ? "görev satırı kalktı" : "görev satırı kendi yerinde gösteriliyor")
            onMissionChanged?(mission.region)
        }
        let reading = rows.subtitleBlock(in: place)
        currentRead = ReadInfo(capturedAt: captured, ocrMs: lastReadMs, confidence: reading.confidence)
        let box = reading.box?.placed(in: place).centeredOnScreen()
        if !sawText, !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sawText = true
            log("ilk yazı: oturum başından \(now() - sessionStart) ms sonra \(SubtitleLog.excerpt(reading.text))")
        }
        // Bölge izi ve satırın yeri: okuma boş dönse de satırın yeri değişmediyse satır silinmez (parlak zemin).
        var action = stabilizer.feed(reading.text, signature: panelLeft ? nil : signature, box: reading.box)
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
            server.clear()
            log("kalktı: bölge boş okundu, ekran temizlendi")
        case .translate(let source):
            translateOrHold(source, box: box)
        case .restore(let source):
            lineLeft()
            restore(source, box: box)
        }
        // Restore önce işlenir: geri görünen satırın leftAt bilgisi temizlenmeden iptal edilmemeli.
        abandonUndisplayableTranslation()
    }

    /// Süren çeviri artık gösterilemeyecekse üretimi iptal eder, böylece sıradaki satır onu beklemez. Yalnız iki durumda:
    /// daha yeni bir satır ekranda gösterilmişse, ya da satır `lateResultMs`'ten önce kalkmış, ekranda değil ve sırada
    /// gösterilebilir yeni bir satır bekliyorsa. Ekranda duran satır üretimi ne kadar uzarsa uzasın iptal edilmez.
    /// İptal edilen satır ekrana geri gelirse (`restore`) yeniden çevrilir. Windows (SubtitlePipeline.cs) ve Android
    /// (SubtitlePipeline.kt) aynı kuralları uygular.
    private func abandonUndisplayableTranslation() {
        guard let current = inFlight, current.session == session, !current.superseded, !current.abandoned,
              work != nil else { return }
        let time = now()
        let replaced = current.number < lastShown
        let expired = current.number > lastShown && current.number != lineOnScreen
            && current.leftAt.map { time - $0 > Self.lateResultMs } == true
        guard replaced || expired else { return }
        let hasWaiting = waiting.contains {
            $0.session == session && !$0.superseded && !$0.abandoned && !($0.leftAt.map { time - $0 > Self.lateResultMs } == true)
        }
        guard replaced || hasWaiting else { return }
        current.abandoned = true
        log(current, replaced ? "bırakıldı: daha yeni satır gösterildi" : "bırakıldı: gösterim süresi doldu, yeni satır bekliyor")
        work?.cancel()
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
        if restoreQueued(source) { return }
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
        if let packed = packMatch(request) {
            showPacked(request, packed)
            return
        }
        if skipsTurkish, TurkishText.isSure(source) {
            remember(request.number, source, nil)
            log(request, "\(SubtitleLog.excerpt(source)) → zaten Türkçe, çevrilmedi")
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
        guard shouldSend else {
            log(request, "\(SubtitleLog.excerpt(source)) → \(pack), zaten hedef dilde, gösterilmedi")
            return
        }
        let metrics = measure(request, translation: nil, origin: .pack)
        log(request, "\(SubtitleLog.excerpt(source)) → \(pack)")
        lastShown = request.number
        server.sendSubtitle(translated, durationMs: 15000, box: request.box, replaces: revisesShown(source))
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
            log("#\(pair.number) geri geldi: \(SubtitleLog.excerpt(source))")
            guard let translation = pair.translation else { return }
            server.sendSubtitle(translation, durationMs: 15000, box: box, replaces: revisesShown(source))
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
        // Çevirisi hiç yoksa (atlanmış ya da başarısız olmuş) normal yoldan çevrilir.
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
                } else if let left = old.leftAt, time - left > Self.lateResultMs {
                    log(old, "atıldı: çevrilmeden ekrandan kalktı (\(time - left) ms önce)")
                }
            }
            waiting.removeAll { $0.session != session || $0.leftAt.map { time - $0 > Self.lateResultMs } == true }
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
        let source = request.source
        let started = now()
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
            guard request.number > lastShown, shouldSend, !request.superseded else {
                let reason = !shouldSend ? "zaten hedef dilde"
                    : request.superseded ? "uzamış okuması geldi" : "daha yeni satır gösterildi (#\(lastShown))"
                log(request, "\(result), atıldı: \(reason)")
                return
            }
            let onScreen = request.number == lineOnScreen
            // Satır ekrandan çoktan kalktıysa çevirisi sonraki sahnenin üstüne düşmesin.
            if !onScreen, let left = request.leftAt, now() - left > Self.lateResultMs {
                log(request, "\(result), geç: satır \(now() - left) ms önce kalktı, gösterilmedi")
                return
            }
            let metrics = measure(request, translation: (started, finished), origin: .engine)
            log(request, "\(result), gösterildi\(onScreen ? "" : " (satır kalkmıştı)")")
            lastShown = request.number
            // Satır hâlâ ekrandaysa kalkınca silinir; kalktıysa okunacak kadar gösterilir.
            server.sendSubtitle(translated, durationMs: onScreen ? 15000 : Self.readingTime(for: translated), box: request.box,
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
            if let image = context?.makeImage() { _ = try? await readQueue.run { try reader.read(image) } }
        }
        let translator = self.translator
        Task { await translator.warmUp() }
    }

    /// Okuma durunca TV'deki son altyazıyı kaldırır.
    public func reset() {
        log("hat sıfırlandı (paketten \(packHits) satır)")
        sessionStart = now()
        sawFrame = false
        sawText = false
        lastNote = nil
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
        lastPanelReading = .empty
        lastReadMs = nil
        scheduler.reset()
        stickyRows.reset()
        mission.reset()
        if stabilizer.reset() == .clear { server.clear() }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
