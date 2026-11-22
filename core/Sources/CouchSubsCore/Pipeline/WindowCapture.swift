// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Kullanıcının açıkça seçtiği OBS projektörü ya da oyun penceresi (Windows'taki `WindowCaptureTarget` ile aynı). Pencere
/// numarası ya da süreç numarası saklanmaz (yeniden açılışta değişir); hem uygulamanın adı hem pencere başlığı
/// eşleşmelidir. Pencere bulunmazsa başka kaynağa geçilmez.
public struct WindowCaptureTarget: Codable, Hashable, Sendable {
    /// Pencerenin sahibi uygulamanın adı (Windows'ta süreç adı).
    public var processName: String
    public var title: String

    public init(processName: String, title: String) {
        self.processName = processName
        self.title = title
    }

    /// Hem uygulama adı hem başlık dolu: yalnız böyle bir seçimle çeviri başlatılabilir.
    public var isComplete: Bool {
        !processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Ekrandaki bir pencerenin seçim ve eşleme için gereken bilgisi (ScreenCaptureKit'ten bağımsız; testlerde elle kurulur).
public struct CaptureWindowInfo: Equatable, Sendable {
    public var id: UInt32
    public var processName: String
    public var title: String
    public var width: Double
    public var height: Double
    /// Pencere katmanı; sıradan uygulama pencereleri 0'dır (menü çubuğu, Dock ve yüzen paneller değildir).
    public var layer: Int
    public var isOnScreen: Bool
    /// CouchSubs'ın kendi penceresi (altyazı penceresi seçilirse çeviri kendini okur).
    public var isOwn: Bool

    public init(id: UInt32, processName: String, title: String, width: Double, height: Double, layer: Int = 0,
                isOnScreen: Bool = true, isOwn: Bool = false) {
        self.id = id
        self.processName = processName
        self.title = title
        self.width = width
        self.height = height
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isOwn = isOwn
    }
}

/// Seçilebilir pencerelerin süzülmesi ve kayıtlı seçimin açık pencerelerle eşlenmesi (Windows'taki
/// `RemotePlayWindowStream.ListCaptureWindows` ve `FindGameWindow` ile aynı kurallar).
public enum CaptureWindows {
    /// Küçük pencereler (araç çubuğu, giriş, bildirim) oyun penceresi sanılmasın.
    public static let minimumWidth = 400.0
    public static let minimumHeight = 250.0

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Seçilebilir mi: sıradan bir uygulama penceresi, yeterince büyük, başlığı var ve bizim değil.
    public static func isSelectable(_ window: CaptureWindowInfo) -> Bool {
        window.layer == 0 && !window.isOwn && window.width >= minimumWidth && window.height >= minimumHeight
            && !trimmed(window.title).isEmpty && !trimmed(window.processName).isEmpty
    }

    /// Kullanıcıya gösterilecek liste: aynı uygulama ve başlık bir kez, önce uygulama adına sonra başlığa göre sıralı.
    public static func selectable(_ windows: [CaptureWindowInfo]) -> [WindowCaptureTarget] {
        let targets = Set(windows.filter(isSelectable).map {
            WindowCaptureTarget(processName: trimmed($0.processName), title: trimmed($0.title))
        })
        return targets.sorted {
            let order = $0.processName.localizedCaseInsensitiveCompare($1.processName)
            return order == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                : order == .orderedAscending
        }
    }

    /// Kayıtlı seçimin şu an açık olan penceresi: uygulama adı büyük/küçük harfe bakmadan, başlık birebir eşleşir.
    /// Birden çok pencere uyuyorsa ekranda olan, sonra en büyüğü. Uyan yoksa nil (başka pencereye geçilmez).
    public static func match(_ target: WindowCaptureTarget, in windows: [CaptureWindowInfo]) -> CaptureWindowInfo? {
        guard target.isComplete else { return nil }
        let candidates = windows.filter {
            isSelectable($0) && trimmed($0.processName).caseInsensitiveCompare(target.processName) == .orderedSame
                && trimmed($0.title) == target.title
        }
        return candidates.max { a, b in
            if a.isOnScreen != b.isOnScreen { return !a.isOnScreen }
            return a.width * a.height < b.width * b.height
        }
    }

    /// Ayarlardaki seçim listesinin bir satırı.
    public struct Option: Equatable, Identifiable, Sendable {
        public var target: WindowCaptureTarget
        /// Pencere şu an açık mı; kayıtlı seçim açık değilse de listede kalır ("Şu anda açık değil").
        public var isOpen: Bool
        public var id: WindowCaptureTarget { target }

        public init(target: WindowCaptureTarget, isOpen: Bool) {
            self.target = target
            self.isOpen = isOpen
        }
    }

    /// Açık pencereler; kayıtlı seçim aralarında yoksa en başa "açık değil" olarak eklenir (seçim kaybolmaz).
    public static func options(saved: WindowCaptureTarget?, open: [WindowCaptureTarget]) -> [Option] {
        var options = open.map { Option(target: $0, isOpen: true) }
        if let saved, !open.contains(saved) { options.insert(Option(target: saved, isOpen: false), at: 0) }
        return options
    }

    /// Seçilen pencere OBS'in ve Kaynak projektörü değil (Program/Önizleme projektörü ya da OBS'in ana penceresi): bu
    /// görüntüde CouchSubs'ın OBS katmanı (tarayıcı kaynağı) da vardır, kendi altyazısını okur (bkz. `OwnSubtitles`).
    /// Ayarlar Kaynak projektörünü önerir. Kaynak projektörünün başlığı "Projector - Source: <ad>" (Türkçe OBS'te
    /// "Projektör - Kaynak: <ad>"), eski OBS'te "Windowed Projector (Source) - <ad>". Windows (`ObsProjector`) aynı kural.
    public static func needsSourceProjectorHint(_ target: WindowCaptureTarget?) -> Bool {
        guard let target else { return false }
        let process = target.processName.lowercased()
        guard process == "obs" || process.hasPrefix("obs ") || process.hasPrefix("obs64") || process.hasPrefix("obs32")
            || process.contains("obs studio") || process == "obs-studio" else { return false }
        let title = target.title.lowercased()
        return !["source:", "kaynak:", "(source)", "(kaynak)"].contains { title.contains($0) }
    }

    /// Listede görünen ad: "Başlık (Uygulama)"; açık değilse sonuna `notOpen` eklenir.
    public static func label(_ option: Option, notOpen: String) -> String {
        let name = "\(option.target.title) (\(option.target.processName))"
        return option.isOpen ? name : "\(name) — \(notOpen)"
    }
}

/// Seçilen pencereden okunan karelerin tanısı (Windows'taki `WindowCaptureWatch`, GitHub #566). Yakalama başladıktan
/// `firstReport` sonra hâlâ okumaya kare verilmediyse nedeni tek satırda söylenir; sonra `reportInterval`'da bir
/// yinelenir. İlk kare verilince susar. Kareler ayrı iş parçacığından gelir; kilitlidir. Süreler saniyedir.
public final class WindowCaptureWatch: @unchecked Sendable {
    public static let firstReport: TimeInterval = 5
    public static let reportInterval: TimeInterval = 30
    /// Bir karenin kopyalanması bundan uzun sürüyorsa takılmış sayılır (normalde birkaç milisaniye).
    public static let stuckCopy: TimeInterval = 2
    /// Yakalama başladıktan bu kadar sonra okumaya hâlâ kare verilmediyse yedek yakalamaya geçilir.
    public static let fallbackAfter: TimeInterval = 5

    private let lock = NSLock()
    private let system: String
    private var arrivedCount = 0
    private var failures = 0
    private var lastError: String?
    private var copyStartedAt: TimeInterval?
    private var nextReport = WindowCaptureWatch.firstReport
    private var isDelivered = false

    /// `system`: kareleri veren işletim sisteminin tanı satırındaki adı.
    public init(system: String = "macOS") {
        self.system = system
    }

    /// Okumaya en az bir kare verildi; bundan sonra rapor yazılmaz.
    public var delivered: Bool { lock.withLock { isDelivered } }

    /// İşletim sistemi bir kare verdi (atlanmış olsa da).
    public func arrived() {
        lock.withLock { arrivedCount += 1 }
    }

    /// Kare görüntüye çevrilmeye başladı.
    public func copyStarted(at time: TimeInterval) {
        lock.withLock { copyStartedAt = time }
    }

    /// Çevirme bitti (başarılı ya da değil).
    public func copyEnded() {
        lock.withLock { copyStartedAt = nil }
    }

    /// Kare çevrilemedi. İlk hatada true döner (çağıran altyazi.log'a bir kez yazar).
    public func failed(_ error: String) -> Bool {
        lock.withLock {
            failures += 1
            lastError = error
            return failures == 1
        }
    }

    /// Kare okumaya verildi. İlk karede true döner (çağıran boyutunu altyazi.log'a yazar).
    public func frameDelivered() -> Bool {
        lock.withLock {
            if isDelivered { return false }
            isDelivered = true
            return true
        }
    }

    /// Yakalama `fallbackAfter` içinde okumaya kare veremedi: yedek yakalamaya geçilmeli.
    public func shouldFallBack(sinceStart: TimeInterval) -> Bool {
        lock.withLock { !isDelivered && sinceStart >= Self.fallbackAfter }
    }

    /// `sinceStart`: yakalamanın başladığından bu yana geçen süre. Yazılacak tanı satırını verir; yoksa nil.
    public func tick(sinceStart: TimeInterval) -> String? {
        lock.withLock {
            if isDelivered || sinceStart < nextReport { return nil }
            // Saat takıldıysa kaçan raporlar art arda yazılmaz.
            while nextReport <= sinceStart { nextReport += Self.reportInterval }
            let seconds = Int(sinceStart)
            if let started = copyStartedAt, sinceStart - started >= Self.stuckCopy {
                return "pencere yakalanıyor ama kare kopyalama \(Int(((sinceStart - started) * 1000).rounded())) ms'dir bitmedi; "
                    + "\(seconds) sn'de okumaya kare gelmedi (ekran kartı sürücüsü kareyi vermiyor olabilir)"
            }
            if arrivedCount == 0 {
                return "pencere yakalanıyor ama \(seconds) sn'dir \(system) hiç kare vermedi "
                    + "(pencere simge durumunda, başka bir masaüstünde ya da ekran yakalamaya kapalı olabilir)"
            }
            if failures > 0 {
                return "pencereden \(arrivedCount) kare geldi ama \(failures) kare kopyalanamadı: \(lastError ?? "")"
            }
            return "pencereden \(arrivedCount) kare geldi ama \(seconds) sn'de hiçbiri okumaya verilmedi"
        }
    }
}

/// Bazı uygulamalar penceresinin yakalanmasını engeller; o zaman kareler simsiyah gelir. Art arda `limit` siyah karede
/// bir kez uyarılır, ilk siyah olmayan karede uyarı kalkar (Windows'taki `CheckBlack`).
public struct BlackFrameWatch: Sendable {
    public enum Change: Equatable, Sendable { case warn, clear }

    private let limit: Int
    private var blackFrames = 0
    private var warned = false

    public init(limit: Int) {
        self.limit = limit
    }

    /// Bir kare geldi; uyarı durumunun değişip değişmediğini söyler.
    public mutating func note(black: Bool) -> Change? {
        if black {
            blackFrames += 1
            guard blackFrames == limit, !warned else { return nil }
            warned = true
            return .warn
        }
        blackFrames = 0
        guard warned else { return nil }
        warned = false
        return .clear
    }

    /// BGRA karenin seyrek bir örneği (her 997. piksel) simsiyah mı.
    public static func isBlack(bgra pixels: UnsafeRawBufferPointer) -> Bool {
        var index = 0
        while index + 2 < pixels.count {
            if pixels[index] >= 10 || pixels[index + 1] >= 10 || pixels[index + 2] >= 10 { return false }
            index += 4 * 997
        }
        return true
    }
}

/// Pencere yakalamanın dakikalık kare sayımı (GitHub #822). Mac'te Remote Play penceresinden altyazı ~10,6 sn arayla
/// okunuyordu ve günlükte nedeni görünmüyordu: kareler mi gelmiyor, okuma mı beklemede, ayırt edilemiyordu. Dakikada bir
/// "pencere kareleri: 600/dk, boş: 12, yedek: 0" yazılır (Windows: WindowFrameCounts.cs). İş parçacığı güvenlidir.
public final class WindowFrameCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var idleFrames = 0
    private var fallbackFrames = 0

    public init() {}

    /// Okumaya verilen kare (yakalama akışından).
    public func delivered() { lock.withLock { frames += 1 } }
    /// Değişmeyen ekranda gelen boş kare (okunmaz).
    public func idle() { lock.withLock { idleFrames += 1 } }
    /// Yedek yakalamadan (tek tek görüntü) okumaya verilen kare.
    public func fallback() { lock.withLock { fallbackFrames += 1 } }

    /// Son dakikanın günlük satırı; sayaçlar sıfırlanır.
    public func minuteLine() -> String {
        let (frames, idle, fallback) = lock.withLock {
            defer { self.frames = 0; idleFrames = 0; fallbackFrames = 0 }
            return (self.frames, idleFrames, fallbackFrames)
        }
        return "pencere kareleri: \(frames)/dk, boş: \(idle), yedek: \(fallback)"
    }
}
