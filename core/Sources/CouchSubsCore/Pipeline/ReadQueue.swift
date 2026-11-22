// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

public enum ReadQueueError: Error, Equatable {
    /// Okuma `ms` milisaniyede bitmedi (ya da o kadar sıra bekledi); kare atlandı.
    case timedOut(ms: Int)
    /// Asıl okuyucu takılı ve bağımsız yedek okuyucu yok (ya da o da takıldı); yeni okuma verilmedi (#507, #679).
    case stuck
}

/// Okumanın önceliği: altyazı her zaman öndedir; ek alanlar, ekran yazısı, telefon ve "Ekranı çevir" arkadan gelir.
public enum ReadPriority: Int, Sendable {
    case subtitle = 0
    case background = 1
}

/// Asıl okuyucu (bu süreçteki Vision) takılınca okumayı **bağımsız bir bağlamda** sürdüren yedek (#679).
///
/// Vision'ın metin tanıması süreç genelinde tek kilitle çalışır: bir istek dönmezken (macOS 27'de modelin ANE için
/// derlenmesi 30–90 sn sürer) başka iş parçacığında, yeni `VNRecognizeTextRequest`/`VNImageRequestHandler` ile,
/// hatta "hızlı" düzeyde verilen istek de o bitene kadar bekler. Bu yüzden süreç içinde yeni kuyruk kurmak kurtarmaz;
/// gerçek yedek ayrı bir süreçtir (Mac: `OcrHelperRescuer`).
public protocol ReadRescuer: AnyObject, Sendable {
    /// Yedek bağlamda okur; yedek kuyruğun iş parçacığında, senkron çağrılır.
    func recognize(_ image: CGImage, language: String) throws -> Reading
    /// Yedekteki okuma da süresinde dönmedi: bağlam bırakılır (süreç öldürülür), sonraki okumada yenisi kurulur.
    func abandon()
    /// Asıl okuyucu düzeldi; yedek kapatılabilir.
    func standDown()
}

/// Yazı tanıma (Vision) çağrılarının tek sırası (#385, #507, #679).
///
/// - **Tek okuma**: süreç genelinde aynı anda tek Vision isteği verilir. Aynı anda verilen istekler Vision'ı
///   kilitleyebiliyordu (#385); takılan isteğin yanına yenisini vermek de işe yaramaz, o da aynı kilidi bekler.
/// - **Swift havuzu tutulmaz**: okuma kendi `DispatchQueue`'sunda çalışır, çağıran `await` ile bekler.
/// - **Öncelik**: sırada altyazı okuması varsa önce o verilir; arka plan okumaları (ek alan, ekran yazısı) altyazıyı
///   geciktiriyorsa kendilerini kısar (`backgroundSlowdown`).
/// - **Takılma**: `timeoutMs` içinde dönmeyen okuma `timedOut` ile bırakılır ve asıl okuyucu "takılı" sayılır. Takılıyken
///   yeni Vision isteği verilmez. Yedek (`rescuer`) varsa okumalar ona gider, altyazı sürer; yoksa okuma hemen
///   `stuck` ile döner. Takılan okuma bitince asıl okuyucuya kendiliğinden dönülür. Yedek varken altyazı için sınır
///   `subtitleTimeoutMs`'tir: altyazı okuması ya da önünde beklediği okuma o kadar sürerse takılı sayılır (#822).
/// - **Yedek de takılırsa** bağlamı bırakılıp yenisi kurulur; art arda `maxRescueFailures` kez olursa yedek, asıl
///   okuyucu düzelene kadar kullanılmaz.
public final class ReadQueue: @unchecked Sendable {
    public static let shared = ReadQueue(degradeAfterStalls: 2, subtitleTimeoutMs: ReadQueue.defaultSubtitleTimeoutMs)
    /// Bütün karenin derin okuması (üç Vision isteği) yavaş Mac'te birkaç saniye sürer; `FrameGate`'in 15 saniyesinden
    /// önce dönmeli ki hat yeniden kurulmadan sonraki kare okunsun.
    public static let defaultTimeoutMs = 10_000
    /// Altyazı okuması (ya da önünde beklediği okuma) bundan uzun sürerse asıl okuyucu takılı sayılır, altyazı yedekten
    /// okunur (GitHub #822). Eskiden altyazı da `defaultTimeoutMs` bekliyordu: asıl okuyucu yavaşladığında her takılmada
    /// 10 sn hiç satır okunmuyordu. Mac'te Sony Remote Play penceresinden okuyan kullanıcının altyazı geçmişinde
    /// çeviriler beta.52'deki 1–4 sn yerine 8–11 sn (ve 19–20 sn) arayla geliyordu: "5-6 cümlede bir çeviri" ve ekranda
    /// uzun kalan çeviri. Altyazı okuması normalde 0,1–0,5 sn sürer (derin okuma 1 sn'yi bulmaz).
    public static let defaultSubtitleTimeoutMs = 3_000
    public static let defaultMaxRescueFailures = 3
    /// Altyazı okuması sırada bundan uzun beklediyse arka plan okumaları seyrekleşir.
    public static let subtitleWaitLimitMs = 150

    /// Günlüğe yazılacak olaylar (tanı).
    public enum Event: Sendable, Equatable {
        /// Asıl okuyucudaki okuma dönmedi. `rescued`: okumalar yedeğe geçti.
        case stalled(Stall, rescued: Bool)
        /// Takılan okuma `ms` sonra bitti; asıl okuyucuya dönüldü.
        case recovered(ms: Int)
        /// Yedekteki okuma da dönmedi; yedek bağlam yeniden kurulacak (`failures`: art arda kaçıncı).
        case rescueFailed(Stall, failures: Int)
        /// Okuyucu `stalls` kez takıldı: bundan sonra hızlı düzeyde okunur (Neural Engine yolu bırakıldı).
        case degraded(stalls: Int)
        /// Bırakılan (iPhone) takılı okuma sonunda bitti; `stillStuck`: hâlâ bitmemiş bırakılan okuma sayısı.
        case abandonedFinished(stillStuck: Int)
    }

    /// Dönmeyen okumanın ayrıntısı.
    public struct Stall: Sendable, Equatable {
        /// Okumanın ne olduğu ve karenin boyutu ("altyazı 1728x324 derin").
        public var detail: String
        public var ms: Int
        /// `ProcessInfo.thermalState` ("nominal", "fair", "serious", "critical").
        public var thermal: String
        /// Sürecin bellek ayak izi (MB); ölçülemezse nil.
        public var memoryMB: Int?
        /// Sırada bekleyen okuma sayısı.
        public var pending: Int
        /// O anda süren okuma sayısı (asıl ve yedek).
        public var running: Int
    }

    /// Bir okuma: sonucu ya da süre aşımı, hangisi önce gelirse bir kez teslim edilir.
    private final class Item: @unchecked Sendable {
        let priority: ReadPriority
        let detail: String
        let submitted = ReadQueue.uptimeMs()
        var started: Int?
        /// Başladığında verilen süre sınırı (ms).
        var limitMs: Int?
        /// Süresi doldu, çağırana haber verildi; iş hâlâ sürüyor olabilir.
        var expired = false
        let work: @Sendable () -> Void
        let fail: @Sendable (Error) -> Void
        init(priority: ReadPriority, detail: String, work: @escaping @Sendable () -> Void, fail: @escaping @Sendable (Error) -> Void) {
            self.priority = priority
            self.detail = detail
            self.work = work
            self.fail = fail
        }
    }

    private final class Lane {
        let queue: DispatchQueue
        var pending: [Item] = []
        var running: Item?
        /// Süren okumanın süresi doldu; bitene kadar bu kuyruğa yeni okuma verilmez.
        var stalledSince: Int?
        /// Takılı okumasıyla bırakıldı (`abandonStall`); okuma bitince sayaçtan düşülür.
        var abandoned = false
        /// Takılı sayılan okumanın başladığı an (takılmanın süresi bundan ölçülür).
        var stallStarted: Int?
        init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }
    }

    private let lock = NSLock()
    private var primary: Lane
    private var primaryGeneration = 0
    private var abandonedStalls = 0
    private var rescue: Lane
    private let label: String
    private var rescueGeneration = 0
    private var rescueFailures = 0
    private let timeoutMs: Int
    /// Altyazı okumasının ve önünde beklediği okumanın takılı sayılma süresi (`defaultSubtitleTimeoutMs`).
    private let subtitleTimeoutMs: Int
    private let maxRescueFailures: Int
    /// Asıl okuyucu bu kadar kez takılırsa okuma yolu değiştirilir (`VisionReader.useFastLevel`); nil: değiştirilmez.
    private let degradeAfterStalls: Int?
    private var stalls = 0
    private var lastSubtitleWaitMs = 0
    private var _rescuer: ReadRescuer?
    private var _onEvent: (@Sendable (Event) -> Void)?

    public init(label: String = "com.couchsubs.ocr", timeoutMs: Int = ReadQueue.defaultTimeoutMs,
                maxRescueFailures: Int = ReadQueue.defaultMaxRescueFailures, degradeAfterStalls: Int? = nil,
                subtitleTimeoutMs: Int? = nil) {
        self.degradeAfterStalls = degradeAfterStalls
        self.label = label
        self.timeoutMs = timeoutMs
        self.subtitleTimeoutMs = min(subtitleTimeoutMs ?? timeoutMs, timeoutMs)
        self.maxRescueFailures = maxRescueFailures
        primary = Lane(label: label)
        rescue = Lane(label: "\(label).yedek.0")
    }

    /// Bağımsız yedek okuyucu (yoksa takılınca okuma `stuck` ile döner).
    public var rescuer: ReadRescuer? {
        get { lock.withLock { _rescuer } }
        set { lock.withLock { _rescuer = newValue } }
    }

    public var onEvent: (@Sendable (Event) -> Void)? {
        get { lock.withLock { _onEvent } }
        set { lock.withLock { _onEvent = newValue } }
    }

    /// Asıl okuyucu takılı mı ve kaç milisaniyedir.
    public var stalledMs: Int? { lock.withLock { primary.stalledSince.map { Self.uptimeMs() - $0 } } }

    /// Bağımsız yedeği olmayan yerde (iPhone; ayrı süreç açılamaz) takılan okuma bırakılır: asıl okuyucuya yeni kuyruk
    /// kurulur ve okumalar bundan sonra hızlı düzeyde (Neural Engine'siz) verilir. Eskiden iPhone'da takılan tek okuma
    /// bitmezse altyazı bir daha gelmiyordu; "Durdur / Başlat" düzeltmiyor, yalnız uygulamayı kapatıp açmak
    /// düzeltiyordu (Android'de takılan tanıyıcı zaten bırakılıp yenisi kuruluyor). Bırakılan okuma arka planda kalır
    /// (iş parçacığı durdurulamaz); bu yüzden süreç başına en çok `maxAbandons` kez yapılır.
    ///
    /// `olderThanMs`: takılma en az bu kadar sürmüş olmalı (takılan okuma çoğu zaman kendiliğinden biter). Bırakıldıysa
    /// takılmanın süresi (ms), bırakılmadıysa nil.
    @discardableResult
    public func abandonStall(olderThanMs: Int, maxAbandons: Int = ReadQueue.defaultMaxAbandons) -> Int? {
        let abandoned: Int? = lock.withLock {
            guard let since = primary.stalledSince, abandonedStalls < maxAbandons else { return nil }
            let ms = Self.uptimeMs() - (primary.stallStarted ?? since - timeoutMs)
            guard ms >= olderThanMs else { return nil }
            abandonedStalls += 1
            primary.abandoned = true
            primaryGeneration += 1
            // Eski kuyruğun bekleyenleri yoktur (takılınca yedeğe taşındı ya da hata aldı); takılan iş orada kalır.
            primary = Lane(label: "\(label).\(primaryGeneration)")
            return ms
        }
        guard abandoned != nil else { return nil }
        VisionReader.useFastLevel = true
        let current = lock.withLock { primary }
        pump(current)
        return abandoned
    }

    /// iPhone'da süreç başına bırakılabilecek takılı okuma sayısı (her biri bir iş parçacığını tutar).
    public static let defaultMaxAbandons = 3

    /// Takılıyken okumalar yedekten mi geliyor.
    public var isRescuing: Bool { lock.withLock { primary.stalledSince != nil && rescueUsable } }

    /// Arka plan okumalarının aralığı bununla çarpılır: altyazı okuması sırada beklediyse 2, çok beklediyse 4; asıl
    /// okuyucu takılıyken 4 (yedek yalnız altyazıya yetsin).
    public var backgroundSlowdown: Int {
        lock.withLock {
            if primary.stalledSince != nil { return 4 }
            if lastSubtitleWaitMs > Self.subtitleWaitLimitMs * 4 { return 4 }
            return lastSubtitleWaitMs > Self.subtitleWaitLimitMs ? 2 : 1
        }
    }

    /// Yedek bağlamdaki okumada bu iş parçacığının yedeği (`VisionReader` bakar); asıl okumada nil.
    public static var activeRescuer: ReadRescuer? {
        (Thread.current.threadDictionary[rescuerKey] as? RescuerBox)?.rescuer
    }

    private static let rescuerKey = "com.couchsubs.ocr.rescuer"
    private final class RescuerBox { let rescuer: ReadRescuer; init(_ rescuer: ReadRescuer) { self.rescuer = rescuer } }

    private var rescueUsable: Bool { _rescuer != nil && rescueFailures < maxRescueFailures }

    /// `work`'ü okuma sırasında çalıştırır. Çağıranın thread'i (Swift havuzu) beklerken bloklanmaz.
    /// `detail`: takılırsa günlüğe yazılacak ad ve kare boyutu.
    public func run<T: Sendable>(priority: ReadPriority = .subtitle, detail: @autoclosure () -> String = "",
                                 _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let detail = detail()
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let item = Item(priority: priority, detail: detail,
                            work: { once.resume(Result { try work() }) },
                            fail: { once.resume(.failure($0)) })
            submit(item)
        }
        return try result.get()
    }

    private func submit(_ item: Item) {
        let lane: Lane? = lock.withLock {
            let lane: Lane? = primary.stalledSince == nil ? primary : (rescueUsable && rescue.stalledSince == nil ? rescue : nil)
            guard let lane else { return nil }
            // Altyazı okuması bekleyen arka plan okumalarının önüne geçer; aynı öncelikte geliş sırası korunur.
            let index = lane.pending.firstIndex { $0.priority.rawValue > item.priority.rawValue } ?? lane.pending.count
            lane.pending.insert(item, at: index)
            return lane
        }
        guard let lane else { return item.fail(ReadQueueError.stuck) }
        let timeoutMs = self.timeoutMs
        if item.priority == .subtitle, subtitleTimeoutMs < timeoutMs {
            // Altyazı, asıl okuyucudaki uzun bir okumanın arkasında `subtitleTimeoutMs`'ten fazla beklemez: yedek varsa o
            // okuma takılı sayılır, altyazı (ve öbür bekleyenler) yedeğe geçer.
            let limitMs = subtitleTimeoutMs
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(limitMs)) { [self, weak item] in
                guard let item else { return }
                let blocker: (item: Item, lane: Lane)? = lock.withLock {
                    guard rescueUsable, primary.pending.contains(where: { $0 === item }), let running = primary.running, !running.expired,
                          let started = running.started, Self.uptimeMs() - started >= limitMs else { return nil }
                    return (running, primary)
                }
                if let blocker { overdue(blocker.item, on: blocker.lane) }
            }
        }
        // Sırada `timeoutMs` bekleyen okuma artık bayattır; kare atlanır.
        // Zamanlayıcılar okumayı zayıf tutar (`weak item`): biten okumanın karesi (ve kırpığın bağlı olduğu bütün kare)
        // hemen bırakılır. Eskiden her okuma karesini 10 sn tutuyordu; Mac'te pencere yakalamanın (ScreenCaptureKit) üç
        // karelik havuzu tutulan karelerle dolunca yeni kare gelmiyor, altyazı ~10,6 sn arayla okunuyordu (GitHub #822).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [self, weak item] in
            guard let item else { return }
            // Asıl okuyucu bu arada takıldıysa okuma yedeğin sırasına taşınmıştır.
            let waiting = lock.withLock {
                for lane in [primary, rescue] {
                    if let index = lane.pending.firstIndex(where: { $0 === item }) {
                        lane.pending.remove(at: index)
                        return true
                    }
                }
                return false
            }
            if waiting { item.fail(ReadQueueError.timedOut(ms: timeoutMs)) }
        }
        pump(lane)
    }

    /// Kuyruk boşsa sıradaki okumayı başlatır.
    private func pump(_ lane: Lane) {
        let next: (item: Item, rescuer: ReadRescuer?, limitMs: Int)? = lock.withLock {
            guard lane.running == nil, lane.stalledSince == nil, !lane.pending.isEmpty else { return nil }
            let item = lane.pending.removeFirst()
            let now = Self.uptimeMs()
            item.started = now
            lane.running = item
            if lane === primary, item.priority == .subtitle { lastSubtitleWaitMs = now - item.submitted }
            // Asıl okuyucudaki altyazı okuması, yedek varsa (Mac) `subtitleTimeoutMs`'te takılı sayılır; yedeksiz
            // (iPhone) beklemenin bir yararı olmadığından eski süre geçerlidir.
            let limitMs = lane === primary && item.priority == .subtitle && rescueUsable ? subtitleTimeoutMs : timeoutMs
            item.limitMs = limitMs
            return (item, lane === primary ? nil : _rescuer, limitMs)
        }
        guard let next else { return }
        let item = next.item
        let limitMs = next.limitMs
        lane.queue.async { [self] in
            if let rescuer = next.rescuer { Thread.current.threadDictionary[Self.rescuerKey] = RescuerBox(rescuer) }
            item.work()
            Thread.current.threadDictionary.removeObject(forKey: Self.rescuerKey)
            finished(item, on: lane)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(limitMs)) { [self, weak item, weak lane] in
            guard let item, let lane else { return }
            overdue(item, on: lane)
        }
    }

    private func finished(_ item: Item, on lane: Lane) {
        var events: [Event] = []
        var standDown: ReadRescuer?
        lock.withLock {
            guard lane.running === item else { return }
            lane.running = nil
            if lane.abandoned {
                // Bırakılan okuma sonunda bitti: iş parçacığı serbest, sınırdan düşülür. Eskiden sayaç süreç boyunca
                // yalnız artıyordu; uzun oyunda (TestFlight, X: "2 saat sonra altyazı gitti, uygulamayı kapatıp açınca
                // düzeldi") dördüncü takılma bırakılamıyor, altyazı uygulama kapatılana dek bir daha gelmiyordu.
                lane.abandoned = false
                abandonedStalls = max(0, abandonedStalls - 1)
                events.append(.abandonedFinished(stillStuck: abandonedStalls))
            } else if lane === primary {
                if let since = lane.stalledSince {
                    // Takılan okuma sonunda bitti: asıl okuyucu yeniden kullanılır.
                    let ran = Self.uptimeMs() - (lane.stallStarted ?? since - timeoutMs)
                    lane.stalledSince = nil
                    lane.stallStarted = nil
                    rescueFailures = 0
                    standDown = _rescuer
                    events.append(.recovered(ms: ran))
                    // Takılma yineleniyorsa isabetli düzey (Neural Engine) bu oturumda bırakılır: hızlı düzey o yolu
                    // hiç kullanmaz. Takılıyken değiştirmek işe yaramaz (istek aynı kilidi bekler); düzelince değişir.
                    // Yalnız `timeoutMs`'i aşan okuma sayılır: altyazıyı bekletmemek için erken takılı sayılan, birkaç
                    // saniyede biten okuma (ör. "Ekranı çevir"in bütün kare okuması) isabetli düzeyi bıraktırmaz.
                    if ran >= timeoutMs { stalls += 1 }
                    if ran >= timeoutMs, let degradeAfterStalls, stalls == degradeAfterStalls {
                        VisionReader.useFastLevel = true
                        events.append(.degraded(stalls: stalls))
                    }
                }
            } else if !item.expired {
                rescueFailures = 0
            }
        }
        standDown?.standDown()
        events.forEach { onEvent?($0) }
        pump(lane)
    }

    /// Okuma `timeoutMs`'dir sürüyor: çağırana süre aşımı döner, kuyruk takılı sayılır.
    private func overdue(_ item: Item, on lane: Lane) {
        var event: Event?
        var abandon: ReadRescuer?
        var stranded: [Item] = []
        let stuck: Bool = lock.withLock {
            guard lane.running === item, !item.expired else { return false }
            item.expired = true
            let stall = Stall(detail: item.detail, ms: Self.uptimeMs() - (item.started ?? item.submitted),
                              thermal: Self.thermalName(), memoryMB: Self.memoryMB(),
                              pending: primary.pending.count + rescue.pending.count,
                              running: (primary.running == nil ? 0 : 1) + (rescue.running == nil ? 0 : 1))
            if lane === primary {
                lane.stalledSince = Self.uptimeMs()
                lane.stallStarted = item.started ?? item.submitted
                // Bekleyenler yedeğe taşınır; yedek yoksa beklemeden hata alırlar.
                let waiting = lane.pending
                lane.pending = []
                if rescueUsable, rescue.stalledSince == nil { rescue.pending.append(contentsOf: waiting) } else { stranded = waiting }
                event = .stalled(stall, rescued: rescueUsable)
            } else {
                // Yedek bağlam da takıldı: bırakılır, sonraki okuma yeni bağlamda (yeni kuyruk, yeni süreç) yapılır.
                rescueFailures += 1
                abandon = _rescuer
                stranded = lane.pending
                rescueGeneration += 1
                rescue = Lane(label: "\(label).yedek.\(rescueGeneration)")
                event = .rescueFailed(stall, failures: rescueFailures)
            }
            return true
        }
        guard stuck else { return }
        abandon?.abandon()
        if let event { onEvent?(event) }
        // `resume` bir kez teslim eder: iş sonradan bitse de çağıran süre aşımını almış olur.
        item.fail(ReadQueueError.timedOut(ms: item.limitMs ?? timeoutMs))
        stranded.forEach { $0.fail(ReadQueueError.stuck) }
        let next = lock.withLock { rescue }
        pump(next)
    }

    /// Sonucu yalnız bir kez teslim eden sarmalayıcı.
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, Error>, Never>?
        init(_ continuation: CheckedContinuation<Result<T, Error>, Never>) { self.continuation = continuation }
        func resume(_ result: Result<T, Error>) {
            let pending: CheckedContinuation<Result<T, Error>, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: result)
        }
    }

    // MARK: - Tanı

    static func uptimeMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

    public static func thermalName(_ state: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "bilinmiyor"
        }
    }

    /// Sürecin bellek ayak izi (MB).
    public static func memoryMB() -> Int? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : nil
        #else
        return nil
        #endif
    }
}

extension ReadQueue.Stall {
    /// Günlük satırı: "altyazı 1728x324 derin, 10004 ms; ısı: nominal, bellek 412 MB, sırada 1, süren 1".
    public var logText: String {
        let memory = memoryMB.map { "\($0) MB" } ?? "?"
        return "\(detail.isEmpty ? "okuma" : detail), \(ms) ms; ısı: \(thermal), bellek \(memory), sırada \(pending), süren \(running)"
    }
}

extension ReadQueue {
    /// Günlükte karenin boyutu: "altyazı 1728x324 derin".
    public static func detail(_ name: String, _ image: CGImage, deep: Bool = false) -> String {
        "\(name) \(image.width)x\(image.height)\(deep ? " derin" : "")"
    }
}
