// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Çapanın bir andaki yeri: başvuru karesindeki telefon dörtgeni ve başvurudan güncel kareye dönüşüm. Bütün ölçüler kareye
/// oranlıdır (0–1, soldan ve üstten); dönüşümün merkezi başvuru dörtgeninin ortasıdır (`ScreenAnchor.Motion` ile aynı
/// biçim). TV'ye giden `anchor` olayı bu sayıları taşır (docs/ekran-capasi.md, "Sunucu olayı").
public struct AnchorPose: Equatable, Sendable {
    /// Çapanın kuşağı: her yeniden kurulumda bir artar. Balon kutuları bu kuşağın başvuru koordinatındadır.
    public let generation: Int
    /// Başvuru karesinde telefonun dörtgeni (çapanın kurulduğu okumadaki `Pose.bounds`).
    public let reference: CropRegion
    /// Başvurudan güncel kareye dönüşüm, kareye oranlı birimlerde.
    public let motion: ScreenAnchor.Motion

    public init(generation: Int, reference: CropRegion, motion: ScreenAnchor.Motion = .identity) {
        self.generation = generation
        self.reference = reference
        self.motion = motion
    }

    public var centerX: Double { (reference.left + reference.right) / 2 }
    public var centerY: Double { (reference.top + reference.bottom) / 2 }

    /// Ortalama ölçek (başvurudaki 1 birim güncel karede kaç birim).
    public var scale: Double { motion.scale }

    /// Başvurudaki noktanın güncel karedeki yeri.
    public func map(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        motion.map(x, y, cx: centerX, cy: centerY)
    }

    /// Güncel karedeki noktanın başvurudaki yeri; dönüşüm tekilse nil.
    public func unmap(_ x: Double, _ y: Double) -> (x: Double, y: Double)? {
        let m = motion
        guard let inverse = ScreenAnchor.invert3([m.a, m.b, m.dx, m.c, m.d, m.dy, m.g, m.h, 1]) else { return nil }
        let u = x - centerX, v = y - centerY
        let w = inverse[6] * u + inverse[7] * v + inverse[8]
        guard abs(w) > 1e-9 else { return nil }
        return (centerX + (inverse[0] * u + inverse[1] * v + inverse[2]) / w,
                centerY + (inverse[3] * u + inverse[4] * v + inverse[5]) / w)
    }

    /// Güncel karedeki kutunun başvurudaki yeri (dört köşenin sınır kutusu).
    public func toReference(_ box: TextBox) -> TextBox {
        let corners = [(box.left, box.top), (box.right, box.top), (box.left, box.bottom), (box.right, box.bottom)]
            .compactMap { unmap($0.0, $0.1) }
        guard corners.count == 4 else { return box }
        return Self.bounds(corners)
    }

    /// Başvurudaki kutunun güncel karedeki yeri (dört köşenin sınır kutusu).
    public func fromReference(_ box: TextBox) -> TextBox {
        Self.bounds([(box.left, box.top), (box.right, box.top), (box.left, box.bottom), (box.right, box.bottom)]
            .map { map($0.0, $0.1) })
    }

    public func fromReference(_ region: CropRegion) -> CropRegion {
        let box = fromReference(TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom))
        return CropRegion(top: box.top, bottom: box.bottom, left: box.left, right: box.right)
    }

    public func toReference(_ region: CropRegion) -> CropRegion {
        let box = toReference(TextBox(left: region.left, top: region.top, right: region.right, bottom: region.bottom))
        return CropRegion(top: box.top, bottom: box.bottom, left: box.left, right: box.right)
    }

    /// Başvuru koordinatındaki noktayı güncel kareye taşıyan 3×3 izdüşüm matrisi, satır satır, mutlak (kareye oranlı)
    /// koordinatta: x' = (m0 x + m1 y + m2) / (m6 x + m7 y + m8), y' = (m3 x + m4 y + m5) / (m6 x + m7 y + m8).
    public var matrix: [Double] {
        let m = motion, cx = centerX, cy = centerY
        let w0 = 1 - m.g * cx - m.h * cy
        return [cx * m.g + m.a, cx * m.h + m.b, cx * w0 - m.a * cx - m.b * cy + m.dx,
                cy * m.g + m.c, cy * m.h + m.d, cy * w0 - m.c * cx - m.d * cy + m.dy,
                m.g, m.h, w0]
    }

    /// İzleme karesinin pikselindeki dönüşümün (`width` × `height` kare) kareye oranlı karşılığı.
    public static func normalized(_ m: ScreenAnchor.Motion, width: Int, height: Int) -> ScreenAnchor.Motion {
        let w = Double(max(1, width)), h = Double(max(1, height))
        return ScreenAnchor.Motion(a: m.a, b: m.b * h / w, c: m.c * w / h, d: m.d, dx: m.dx / w, dy: m.dy / h,
                                   g: m.g * w, h: m.h * h)
    }

    private static func bounds(_ points: [(x: Double, y: Double)]) -> TextBox {
        TextBox(left: points.map(\.x).min() ?? 0, top: points.map(\.y).min() ?? 0,
                right: points.map(\.x).max() ?? 0, bottom: points.map(\.y).max() ?? 0)
    }
}

/// Telefona yapışık çeviri (deneysel; önce Mac'te, Sinan Bey kararı 24 Kas; docs/ekran-capasi.md aşama 2–4). Telefon
/// okuması çapayı kurar (`place`): o karede telefonun dörtgeni şablon olur. Sonra gelen her karede (`feed`) dörtgen
/// OCR'sız, alt piksel izlenir (`ScreenAnchor.Tracker`, ölü bölge `ScreenAnchor.Smoother`); her değişim `onChange` ile
/// bildirilir. Çeviriler başvuru koordinatında kalır, çizim her karede bu dönüşümle taşınır: telefon sarsılsa da kaysa da
/// çeviri yapışık ve titremesiz kalır. Uyum düşerse (`ScreenAnchor.lostShare`), dönüşüm akla yatkın değilse ya da köşe bir
/// karede sıçrarsa çapa kaybolur (`lost`), sonraki okuma yeniden kurar.
///
/// İş parçacığı güvenlidir: izleme kendi kuyruğunda yapılır, önceki kare bitmeden gelen kare atılır (yakalama beklemez).
public final class PhoneAnchorSession: @unchecked Sendable {
    public enum Change: Equatable, Sendable {
        /// Çapa kuruldu ya da kıpırdadı (gösterilecek dönüşüm değişti).
        case moved(AnchorPose)
        /// Çapa kayboldu; bu kuşağın çevirileri gizlenmeli.
        case lost(generation: Int, reason: String)
    }

    /// Çapa değişti (izleme kuyruğunda ya da `place`/`reset`'in çağrıldığı iş parçacığında çağrılır).
    public var onChange: ((Change) -> Void)?
    /// Altyazı günlüğü: kuruldu/kayboldu ve 10 saniyelik özet (uyum, kare başı süre); dakikada sınırlı.
    public var onLog: ((String) -> Void)?

    /// Okumadaki telefon dörtgeni çapanın güncel yerinden bu kadar (dörtgen yüksekliğine oranla) uzaksa çapa yanlış yere
    /// yapışmıştır: o okumayla yeniden kurulur.
    static let rebaseShare = 0.25
    /// Okuma karesinin dönüşümü bu kadar ms içindeki izleme karesinden alınır.
    static let historyToleranceMs = 60
    static let historyCount = 90
    /// Özet satırının aralığı ve kuruldu/kayboldu satırlarının dakikalık sınırı.
    static let summaryMs = 10_000
    static let eventLinesPerMinute = 12

    /// Her kare işi kendi autorelease havuzunda (#1390).
    private let queue = DispatchQueue(label: "couchsubs.phone-anchor", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private let clock: () -> Int
    // Aşağıdakiler `lock` altında.
    private var active = false
    private var busy = false
    private var current: AnchorPose?
    private var generation = 0
    private var size = (width: 0, height: 0)
    private var rect: ScreenAnchor.Rect?
    private var history: [(ms: Int, pose: AnchorPose)] = []
    // İzleyici ve yumuşatıcı yalnız `queue`'da.
    private let tracker = ScreenAnchor.Tracker()
    private var smoother = ScreenAnchor.Smoother()
    // Ölçüm (lock altında).
    private var stats = Stats()
    private var eventLines = (minute: Int.min, count: 0)

    private struct Stats {
        var since: Int?
        var frames = 0
        var inliers = 0.0
        var lowest = 1.0
        var totalMs = 0.0
        var worstMs = 0.0
        var dropped = 0
    }

    public init(clock: @escaping () -> Int = SubtitleStabilizer.uptimeMs) {
        self.clock = clock
    }

    /// Çapa kurulu ve izleniyor.
    public var isActive: Bool { lock.withLock { active } }

    /// Gösterilen son yer (kurulu değilse nil).
    public var pose: AnchorPose? { lock.withLock { current } }

    /// `ms` anındaki karenin yeri (en yakın izleme karesi; yoksa son yer). Çapa yoksa nil.
    public func pose(at ms: Int) -> AnchorPose? {
        lock.withLock { () -> AnchorPose? in
            guard active, let current else { return nil }
            return nearest(ms) ?? current
        }
    }

    /// `lock` altında.
    private func nearest(_ ms: Int) -> AnchorPose? {
        guard let near = history.min(by: { abs($0.ms - ms) < abs($1.ms - ms) }),
              abs(near.ms - ms) <= Self.historyToleranceMs else { return nil }
        return near.pose
    }

    /// Yeni kare (yakalama ya da okuma hattından). Çapa yoksa ya da önceki kare hâlâ izleniyorsa hemen döner.
    public func feed(_ image: CGImage, at ms: Int) {
        let take = lock.withLock { () -> Bool in
            guard active else { return false }
            if busy {
                stats.dropped += 1
                return false
            }
            busy = true
            return true
        }
        guard take else { return }
        queue.async { [self] in
            if let gray = Self.gray(image) { step(gray, at: ms) }
            lock.withLock { busy = false }
        }
    }

    /// Telefon okumasının karesi: çapa yoksa (ya da okumadaki telefon çapanın yerinden uzaksa) bu kare ve telefonun
    /// dörtgeniyle kurulur ve birim dönüşüm döner; varsa bu karenin (en yakın izleme karesinin) yeri döner. Kare
    /// gri yapılamazsa nil (çapasız eski davranış).
    public func place(_ image: CGImage, region: CropRegion, at ms: Int) -> AnchorPose? {
        if let pose = lookup(at: ms, region: region) { return pose }
        guard let gray = Self.gray(image) else { return nil }
        return queue.sync { begin(gray, region: region, at: ms) }
    }

    /// Testler için: gri kareyle aynı işlem, eşzamanlı.
    func place(gray: ScreenAnchor.Gray, region: CropRegion, at ms: Int) -> AnchorPose {
        if let pose = lookup(at: ms, region: region) { return pose }
        return queue.sync { begin(gray, region: region, at: ms) }
    }

    /// Testler için: kareyi eşzamanlı izler.
    func feed(gray: ScreenAnchor.Gray, at ms: Int) {
        guard isActive else { return }
        queue.sync { step(gray, at: ms) }
    }

    /// Telefon kapandı ya da ayar değişti: çapa bırakılır (kuruluysa `lost` bildirilir).
    public func reset(reason: String = "telefon kapandı") {
        queue.sync { lose(reason) }
    }

    /// `ms` anındaki yer: çapa kurulu ve okumadaki telefon çapanın yerine yakınsa.
    private func lookup(at ms: Int, region: CropRegion) -> AnchorPose? {
        lock.withLock { () -> AnchorPose? in
            guard active, let latest = current else { return nil }
            let pose = nearest(ms) ?? latest
            let shown = pose.fromReference(pose.reference)
            let height = max(1e-6, pose.reference.bottom - pose.reference.top)
            let dx = abs((shown.left + shown.right) - (region.left + region.right)) / 2
            let dy = abs((shown.top + shown.bottom) - (region.top + region.bottom)) / 2
            let dh = abs((shown.bottom - shown.top) - (region.bottom - region.top))
            guard max(dx, dy, dh) <= Self.rebaseShare * height else { return nil }
            return pose
        }
    }

    /// `queue`'da.
    private func begin(_ gray: ScreenAnchor.Gray, region: CropRegion, at ms: Int) -> AnchorPose {
        let wasActive = isActive
        if wasActive { lose("okumadaki telefon çapanın yerinden uzak, yeniden kuruluyor") }
        let rect = ScreenAnchor.Rect(x: region.left * Double(gray.width), y: region.top * Double(gray.height),
                                     width: (region.right - region.left) * Double(gray.width),
                                     height: (region.bottom - region.top) * Double(gray.height))
        tracker.begin(gray, rect: rect)
        smoother.reset()
        let pose = lock.withLock { () -> AnchorPose in
            generation += 1
            let pose = AnchorPose(generation: generation, reference: region)
            active = true
            current = pose
            size = (gray.width, gray.height)
            self.rect = rect
            history = [(ms, pose)]
            stats = Stats(since: clock())
            return pose
        }
        event(String(format: "çapa kuruldu (kuşak %d; telefon %.3f,%.3f %.3f×%.3f, izleme karesi %d×%d)", pose.generation,
                     region.left, region.top, region.right - region.left, region.bottom - region.top, gray.width, gray.height))
        onChange?(.moved(pose))
        return pose
    }

    /// `queue`'da: bir izleme karesi.
    private func step(_ gray: ScreenAnchor.Gray, at ms: Int) {
        let state = lock.withLock { () -> (rect: ScreenAnchor.Rect, size: (width: Int, height: Int), pose: AnchorPose)? in
            guard active, let rect, let current else { return nil }
            return (rect, size, current)
        }
        guard let state else { return }
        guard gray.width == state.size.width, gray.height == state.size.height else {
            lose("kare boyu değişti (\(state.size.width)×\(state.size.height) → \(gray.width)×\(gray.height))")
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let fix = tracker.track(gray)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        guard let fix else {
            lose("uyum %\(Int(ScreenAnchor.lostShare * 100)) altında ya da dönüşüm akla yatkın değil")
            return
        }
        let shown = smoother.push(fix.motion, rect: state.rect)
        if shown.jumped {
            lose("köşe bir karede sıçradı")
            return
        }
        let pose = AnchorPose(generation: state.pose.generation, reference: state.pose.reference,
                              motion: AnchorPose.normalized(shown.motion, width: gray.width, height: gray.height))
        let changed = lock.withLock { () -> Bool in
            guard active, current?.generation == pose.generation else { return false }
            history.append((ms, pose))
            if history.count > Self.historyCount { history.removeFirst(history.count - Self.historyCount) }
            stats.frames += 1
            stats.inliers += fix.inliers
            stats.lowest = min(stats.lowest, fix.inliers)
            stats.totalMs += elapsed
            stats.worstMs = max(stats.worstMs, elapsed)
            let changed = current != pose
            current = pose
            return changed
        }
        summarizeIfDue()
        if changed { onChange?(.moved(pose)) }
    }

    /// `queue`'da (ya da `reset`'ten eşzamanlı).
    private func lose(_ reason: String) {
        let lost = lock.withLock { () -> (generation: Int, line: String?)? in
            guard active, let current else { return nil }
            let line = summaryLine()
            active = false
            self.current = nil
            rect = nil
            history = []
            stats = Stats()
            return (current.generation, line)
        }
        tracker.reset()
        smoother.reset()
        guard let lost else { return }
        if let line = lost.line { onLog?(line) }
        event("çapa kayboldu (kuşak \(lost.generation); \(reason))")
        onChange?(.lost(generation: lost.generation, reason: reason))
    }

    private func summarizeIfDue() {
        let line = lock.withLock { () -> String? in
            guard let since = stats.since, clock() - since >= Self.summaryMs else { return nil }
            let line = summaryLine()
            stats = Stats(since: clock())
            return line
        }
        if let line { onLog?(line) }
    }

    /// `lock` altında.
    private func summaryLine() -> String? {
        guard stats.frames > 0, let current else { return nil }
        let seconds = Double(clock() - (stats.since ?? clock())) / 1000
        return String(format: "çapa: kuşak %d, %.0f sn'de %d kare (%d atlandı), uyum ort %%%.0f (en düşük %%%.0f), "
                      + "kare başı ort %.1f ms (en çok %.1f ms), ölçek %.3f",
                      current.generation, seconds, stats.frames, stats.dropped, stats.inliers / Double(stats.frames) * 100,
                      stats.lowest * 100, stats.totalMs / Double(stats.frames), stats.worstMs, current.scale)
    }

    /// Kuruldu/kayboldu satırı: dakikada en çok `eventLinesPerMinute` (telefon sık açılıp kapanınca günlük dolmasın).
    private func event(_ line: String) {
        let minute = clock() / 60_000
        let write = lock.withLock { () -> Bool in
            if eventLines.minute != minute { eventLines = (minute, 0) }
            eventLines.count += 1
            return eventLines.count <= Self.eventLinesPerMinute
        }
        if write { onLog?(line) }
    }

    /// İzleme karesi: kare `ScreenAnchor.trackWidth` ene (küçükse kendi enine) küçültülmüş gri kopya.
    public static func gray(_ image: CGImage) -> ScreenAnchor.Gray? {
        guard image.width > 1, image.height > 1 else { return nil }
        let width = min(ScreenAnchor.trackWidth, image.width)
        let height = max(2, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ScreenAnchor.Gray(width: width, height: height, pixels: pixels) : nil
    }
}
