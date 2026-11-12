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

    /// Bir çeviri isteği; satır ekrandan kalkınca `leftAt` not edilir.
    private final class Request {
        let number: Int
        let source: String
        let box: TextBox?
        let session: Int
        /// Satırı kararlı yapan karenin geldiği an, o okumanın süresi ve güveni (ölçümler için).
        let read: ReadInfo
        /// Satırın ekrandan kalktığı an (hâlâ ekrandaysa nil).
        var leftAt: Int?
        /// Yerine aynı cümlenin uzamış okuması geldi (daktilo efekti); çevirisi gösterilmez.
        var superseded = false
        init(number: Int, source: String, box: TextBox?, session: Int, read: ReadInfo) {
            self.number = number
            self.source = source
            self.box = box
            self.session = session
            self.read = read
        }
    }

    /// Bir karenin okunması: karenin geldiği an, yazı tanımanın süresi (ms) ve güveni (0–1).
    fileprivate struct ReadInfo {
        var capturedAt: Int
        var ocrMs: Int?
        var confidence: Double?
    }

    private let reader: TextReader
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
    /// Son okunan satırlar; kare değişmediyse yeniden okunmaz, bunlar kullanılır.
    private var lastReading = Reading.empty
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
    public init(reader: TextReader, translator: TextTranslator, server: SubtitleSending, scheduler: ReadScheduler = .always,
         clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.reader = reader
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
        // Yazı tanıma uzun sürebilir; arayüz takılmasın diye ana iş parçacığının dışında yapılır.
        let reader = self.reader
        let (area, signature) = await Task.detached(priority: .userInitiated) {
            let area = RegionCropper.crop(frame, to: region)
            return (area, RegionCropper.signature(of: area))
        }.value
        switch scheduler.plan(signature: signature) {
        case .reuse:
            break
        case .read(let deep):
            let started = now()
            let result = await Task.detached(priority: .userInitiated) {
                Result { try reader.readLines(area, deep: deep) }
            }.value
            lastReadMs = now() - started
            lastReading = (try? result.get()) ?? .empty
            onReadResult?(result.failure)
            scheduler.record(lastReading.text)
        }
        // Kumanda ipuçları ("R2 Swing") altyazı değildir; çevrilmez, yeri de altyazının yerine katılmaz.
        // Yazı tanımanın uydurduğu sözcük çöpleri ("ou$3e") de çevirmene gitmez.
        // Alandaki menü ve köşe göstergeleri de altyazı değildir; yalnız altyazı bloğu çevrilir ve kutusu ona göre olur.
        let place = TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom)
        let reading = lastReading.withoutButtonPrompts().withoutOcrNoise().subtitleBlock(in: place)
        currentRead = ReadInfo(capturedAt: captured, ocrMs: lastReadMs, confidence: reading.confidence)
        let box = reading.box?.placed(in: place).centeredOnScreen()
        if !sawText, !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sawText = true
            log("ilk yazı: oturum başından \(now() - sessionStart) ms sonra \(SubtitleLog.excerpt(reading.text))")
        }
        let action = stabilizer.feed(reading.text)
        // Ekranda duran kötü yeniden okuma her karede not edilir; günlüğe bir kez yazılır.
        if let note = stabilizer.note, note != lastNote {
            lastNote = note
            switch note {
            case .worseReread(let text): log("yeniden-okuma: \(SubtitleLog.excerpt(text)) gösterilenden kötü, yok sayıldı")
            case .garbledDropped(let text): log("çöp: \(SubtitleLog.excerpt(text)) kararlı olmadan kalktı, gönderilmedi")
            }
        }
        switch action {
        case .none:
            break
        case .clear:
            lineLeft()
            server.clear()
        case .translate(let source):
            lineLeft()
            enqueue(source, box: box)
        case .restore(let source):
            lineLeft()
            restore(source, box: box)
        }
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

    private func enqueue(_ source: String, box: TextBox?) {
        lastRequested += 1
        let request = Request(number: lastRequested, source: source, box: box, session: session, read: currentRead)
        lineOnScreen = request.number
        if let packed = packLookup?(source) {
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
        for old in waiting where TextMatch.isRevision(source, of: old.source) {
            log(old, "atıldı: yerine düzelmiş okuması geldi (#\(request.number))")
        }
        waiting.removeAll { TextMatch.isRevision(source, of: $0.source) }
        waiting.append(request)
        if waiting.count > Self.maxWaiting {
            for old in waiting.prefix(waiting.count - Self.maxWaiting) { log(old, "atıldı: sıra doldu") }
            waiting.removeFirst(waiting.count - Self.maxWaiting)
        }
        // Süren çeviri bu cümlenin yarım okumasınınsa (daktilo efekti) beklenmez: bırakılır, tamamı hemen çevrilir.
        if !current.superseded, current.session == session, TextMatch.isGrowth(source, of: current.source) {
            log(current, "bırakıldı: uzamış okuması geldi (#\(request.number))")
            current.superseded = true
            work?.cancel()
        }
    }

    /// Satır az önce gösterilenin uzamış ya da düzelmiş okuması mı (TV yerine koyar, üstüne yığmaz).
    private func revisesShown(_ source: String) -> Bool {
        guard let shown = lastPair?.source else { return false }
        return TextMatch.isRevision(source, of: shown)
    }

    /// Paketteki Türkçe hemen gösterilir; süren çevirinin sonucu (eski satır) artık gösterilmez.
    private func showPacked(_ request: Request, _ packed: PackMatch) {
        for old in waiting { log(old, "atıldı: sonraki satır paketten geldi (#\(request.number))") }
        waiting.removeAll()
        packHits += 1
        let source = request.source
        let translated = packed.text
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
        for request in requests where request.source == source && request.session == session && !request.superseded {
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
            let work = Task { try await TranslationProbe.$current.withValue(probe) { try await translator.translate(source) } }
            self.work = work
            defer { self.work = nil }
            let translated = try await work.value
            let finished = now()
            let result = "\(probe.outcome()) \(finished - started) ms"
            guard request.session == session else {
                log(request, "\(result), atıldı: oturum bitti")
                return
            }
            lastError = nil
            onTranslationResult?(nil)
            let shouldSend = stabilizer.shouldSend(source: source, translation: translated)
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
            if let onSpeech { onSpeech(translator.spokenLines(for: source)) }
        } catch {
            // Yerine uzamış okuması gelen satırın bırakılan çevirisi hata sayılmaz.
            guard request.session == session, !request.superseded else { return }
            let retry = request.number == lineOnScreen ? ", satır ekrandayken yeniden denenecek" : ""
            log(request, "hata (\(now() - started) ms): \(error)\(retry)")
            // Dil paketi eksikse ya da geçici bir hata olduysa satır ekranda kaldıkça (saniyede en çok bir kez) yeniden denenir.
            lastError = error as? TranslatorError
            onTranslationResult?(lastError)
            if request.number == lineOnScreen { stabilizer.forgetSent() }
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
        Task.detached(priority: .utility) {
            let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let image = context?.makeImage() { _ = try? reader.read(image) }
        }
        let translator = self.translator
        Task { _ = try? await translator.translate("Hello") }
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
        waiting.removeAll()
        // Apple'ın çevirisi görev iptaline uyar; süren çeviri beklenmeden bırakılır.
        work?.cancel()
        pairs.removeAll()
        lastReading = .empty
        lastReadMs = nil
        scheduler.reset()
        if stabilizer.reset() == .clear { server.clear() }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
