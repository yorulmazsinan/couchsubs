// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreMedia
import CouchSubsCore
import RemotePlay
import ScreenCaptureKit
import VideoToolbox

/// Görüntüyü PS5'e bağlanmadan, bu Mac'te açık olan Remote Play penceresinden alır (ScreenCaptureKit): Sony'nin PS
/// Remote Play'i ya da açık kaynak chiaki-ng (bkz. `RemotePlayApp`). Oyun o uygulamada oynanır ya da izlenir; CouchSubs
/// PS5'e ikinci bir Remote Play oturumu açmadığı için ikinci hesap
/// gerekmez ve "Remote Play başka bir cihazda kullanılıyor" çakışması olmaz. Yalnız o pencere yakalanır: üstündeki
/// altyazı penceremiz (ya da başka pencereler) okunmaz. Kareler `StreamSession`'ınkiler gibi `onFrame` ile gelir; okuma
/// hattının geri kalanı (bölge, yazı tanıma, çeviri, paketler, dublaj) aynıdır.
final class RemotePlayWindowStream: NSObject, StreamControlling, SCStreamOutput, SCStreamDelegate {
    /// Okunabilen Remote Play uygulamaları.
    static let sonyBundleIdentifier = "com.playstation.RemotePlay"
    static let chiakiBundleIdentifier = "org.streetpea.chiaking"

    /// Seçime göre aranan uygulamalar; "hangisi açıksa"da Sony önce (kapalıysa ilk o açılır).
    static func bundleIdentifiers(for app: RemotePlayApp) -> [String] {
        switch app {
        case .automatic: [sonyBundleIdentifier, chiakiBundleIdentifier]
        case .sony: [sonyBundleIdentifier]
        case .chiaki: [chiakiBundleIdentifier]
        }
    }

    /// Seçilen Remote Play uygulaması bu Mac'te kurulu mu ("hangisi açıksa"da ikisinden biri yeter).
    static func isInstalled(_ app: RemotePlayApp) -> Bool {
        bundleIdentifiers(for: app).contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// Resmi indirme sayfaları: Sony PS Remote Play (Mac ve Windows sürümleri) ve chiaki-ng'nin son sürümü.
    static let sonyDownloadURL = URL(string: "https://remoteplay.dl.playstation.net/remoteplay/")!
    static let chiakiDownloadURL = URL(string: "https://github.com/chiaki-ng/chiaki-ng/releases/latest")!
    /// Saniyedeki kare. PS5 akışı 30 verir ama okuma zaten bir önceki kare bitmeden yenisini almaz (`FrameGate`);
    /// fazlası yalnız işlemciyi yorar ve aynı makinede çalışan Remote Play'i yavaşlatabilir.
    static let framesPerSecond: Int32 = 10
    /// Remote Play'in küçük pencereleri (denetim çubuğu, giriş) oyun penceresi sanılmasın.
    static let minimumSize = CGSize(width: 400, height: 250)
    /// Yakalanan karenin en geniş hali (PS5 akışı gibi 1920). Daha büyüğü yazı tanımayı yavaşlatır, okumayı iyileştirmez.
    static let maximumWidth: CGFloat = 1920
    /// Pencere yokken ya da yakalama düşünce yeniden arama aralığı.
    static let searchInterval: Duration = .seconds(2)

    var onFrame: ((CGImage) -> Void)?
    var onState: ((SessionState) -> Void)?
    /// Bu kaynakta PS5'in adresi bilinmez; hiç çağrılmaz.
    var onConsoleMoved: ((RegisteredConsole) -> Void)?

    /// Yakalama kuyruğu düşük öncelikte: kare kopyası oyunun (Remote Play) önüne geçmez (Windows'ta süreç "normalin altı").
    private let queue = DispatchQueue(label: "com.couchsubs.remoteplay-window", qos: .utility)
    /// Karelerin kopyalanma sıklığı; okuma hattı kendi örneğini verir (`useCadence`).
    private var cadence = FrameCadence()
    private let cpu = SystemCpuLoad()
    /// Sıklık sınırına takılan son kare. Görüntü durunca ScreenCaptureKit yeni kare göndermez: altyazı belirirken gelen son
    /// kare atılsaydı yeni satır kamera oynayana dek okunmazdı (#1019). Sınır dolunca o okunur. Yalnız `queue`'da değişir.
    private var held: (stream: SCStream, buffer: CMSampleBuffer)?
    private var heldScheduled = false
    let lock = NSLock()
    /// Her başlatma/durdurma bir numara alır; eski aramanın ya da yakalamanın geç gelen sonucu yenisine karışmaz.
    private var generation = 0
    private var running = false
    private(set) var stream: SCStream?
    private(set) var window: (id: CGWindowID, size: CGSize)?
    /// Pencere arama ve izleme görevleri; yalnız ana iş parçacığında kurulur ve kaldırılır (`start`, `stop`,
    /// `reconnectNow` uygulama modelinden ana iş parçacığında çağrılır).
    private var search: Task<Void, Never>?
    private var sizeWatch: Task<Void, Never>?
    private var askedPermission = false
    /// Son bildirilen durum. Arama her iki saniyede aynı durumu bulur; aynısı yeniden bildirilmez (her "bağlantı yok"
    /// bildirimi okuma hattını sıfırlıyor ve günlüğe yazıyordu).
    private var reported: SessionState?
    private let bundleIdentifiers: [String]
    /// Kullanıcının seçtiği OBS projektörü ya da oyun penceresi (`UserSettings.captureWindow`); Remote Play okunurken nil.
    /// Seçiliyken hiçbir uygulama açılmaz, yalnız bu pencere aranır ve kapanınca başka pencereye geçilmez.
    private let selected: WindowCaptureTarget?
    /// Seçilen pencereden kare gelmiyorsa nedeni günlüğe yazılır, siyah kareler uyarılır (bkz. `RemotePlayWindowStream+Selected`).
    var selectedCapture: SelectedCapture?
    var frameWatch: Task<Void, Never>?
    /// "Ekranı yerinde Türkçe çiz": GTA 6 telefonunun çapası. Verilirse her yakalama karesi (okuma sıklığından bağımsız)
    /// çapaya verilir; Türkçe çizim telefonla birlikte kıpırdar. `lock` altında.
    private var anchor: PhoneAnchorSession?
    /// Yerinde çizim açıkken pencere saniyede `trackingFramesPerSecond` kare yakalanır (okuma yine en çok 10). `lock` altında.
    private var fastFrames = false
    static let trackingFramesPerSecond: Int32 = 30

    var trackAnchor: PhoneAnchorSession? {
        get { lock.withLock { anchor } }
        set { lock.withLock { anchor = newValue } }
    }

    /// Okunan pencerenin kimliği (yerinde çizim katmanı onun üstüne konur).
    var windowID: CGWindowID? { lock.withLock { window?.id } }

    /// Yakalama hızı: yerinde çizimde saniyede 30, yoksa 10. Yakalama sürüyorsa hemen uygulanır.
    func setFastFrames(_ on: Bool) {
        let (stream, window, changed) = lock.withLock { () -> (SCStream?, (id: CGWindowID, size: CGSize)?, Bool) in
            let changed = fastFrames != on
            fastFrames = on
            return (self.stream, self.window, changed)
        }
        guard changed, let stream, let window else { return }
        let configuration = Self.configuration(for: window.size, framesPerSecond: framesPerSecondNow)
        Task { try? await stream.updateConfiguration(configuration) }
    }

    var framesPerSecondNow: Int32 { lock.withLock { fastFrames } ? Self.trackingFramesPerSecond : Self.framesPerSecond }

    /// Dakikalık kare sayımı (günlükte "pencere kareleri: N/dk"): kare aralığı bir dahaki sefere günlükte görünsün (#822).
    let frameCounts = WindowFrameCounts()

    init(app: RemotePlayApp = .automatic) {
        bundleIdentifiers = Self.bundleIdentifiers(for: app)
        selected = nil
        super.init()
    }

    /// OBS ya da oyun penceresi kullanıcı tarafından seçildi: Remote Play açılmaz, tam ekran yakalanmaz.
    init(target: WindowCaptureTarget) {
        bundleIdentifiers = []
        selected = target
        super.init()
    }

    func report(_ state: SessionState) {
        let changed = lock.withLock { () -> Bool in
            guard reported != state else { return false }
            reported = state
            return true
        }
        if changed { onState?(state) }
    }

    func start() {
        let current = lock.withLock { () -> Int in
            running = true
            generation += 1
            reported = nil
            return generation
        }
        report(.connecting)
        if selected == nil { Self.openRemotePlayIfNeeded(bundleIdentifiers) }
        startSearch(current)
    }

    /// Çeviri başlarken seçilen Remote Play uygulamalarından hiçbiri açık değilse, kurulu olan ilki açılır; oyun o
    /// uygulamada oynanır, pencere bulununca okuma kendiliğinden başlar.
    static func openRemotePlayIfNeeded(_ identifiers: [String]) {
        guard identifiers.allSatisfy({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }),
              let url = identifiers.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { return }
        let name = url.deletingPathExtension().lastPathComponent
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        RemotePlayLog.write("\(name) açılıyor")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { RemotePlayLog.write("\(name) açılamadı: \(error.localizedDescription)") }
        }
    }

    func stop() {
        lock.withLock {
            running = false
            generation += 1
        }
        tearDown()
        report(.disconnected(.stopped))
    }

    /// Mac uykudan uyandı: yakalama baştan kurulur (pencere uykuda kapanmış ya da yer değiştirmiş olabilir).
    func reconnectNow() {
        let current = lock.withLock { () -> Int? in
            guard running else { return nil }
            generation += 1
            return generation
        }
        guard let current else { return }
        tearDown()
        report(.connecting)
        startSearch(current)
    }

    /// Pencere yakalama yeniden denemeyi bırakmaz (pencere aranır, bulununca okunur).
    var hasGivenUp: Bool { false }

    func isCurrent(_ number: Int) -> Bool {
        lock.withLock { running && generation == number }
    }

    private func tearDown() {
        search?.cancel()
        search = nil
        sizeWatch?.cancel()
        sizeWatch = nil
        frameWatch?.cancel()
        frameWatch = nil
        let old = lock.withLock { () -> SCStream? in
            defer { stream = nil; window = nil; selectedCapture = nil }
            return stream
        }
        if let old { Task { try? await old.stopCapture() } }
    }

    // MARK: - Pencereyi bulma

    private func startSearch(_ number: Int) {
        search?.cancel()
        search = Task { [weak self] in
            var reported = false
            while !Task.isCancelled {
                guard let self, self.isCurrent(number) else { return }
                switch await self.attach(number) {
                case .attached:
                    return
                case .noWindow:
                    if !reported {
                        RemotePlayLog.write(self.selected.map { "Seçilen pencere bekleniyor: \($0.processName) / \($0.title)" }
                            ?? "Remote Play penceresi bekleniyor (PS Remote Play ya da chiaki-ng)")
                        reported = true
                    }
                    self.report(.connecting)
                case .noPermission:
                    self.report(.disconnected(.other(Self.permissionText)))
                case .failed(let detail):
                    RemotePlayLog.write("Remote Play penceresi yakalanamadı: \(detail)")
                    self.report(.disconnected(.other(detail)))
                }
                try? await Task.sleep(for: Self.searchInterval)
            }
        }
    }

    private enum Attach {
        case attached, noWindow, noPermission, failed(String)
    }

    static var permissionText: String {
        String(localized: "Allow Screen Recording for CouchSubs in System Settings › Privacy & Security, then start again.")
    }

    private func attach(_ number: Int) async -> Attach {
        // İzin yoksa macOS bir kez sorar; Sistem Ayarları'nda açıldıktan sonra uygulama yeniden başlatılmalıdır.
        if !CGPreflightScreenCaptureAccess() {
            if !askedPermission {
                askedPermission = true
                _ = CGRequestScreenCaptureAccess()
            }
            return .noPermission
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            return .noPermission
        }
        // Seçilen pencere açık değilse Remote Play'e ya da başka pencereye geçilmez.
        let found: SCWindow?
        if let selected {
            found = Self.selectedWindow(selected, in: content.windows)
        } else {
            found = Self.gameWindow(in: content.windows, bundleIdentifiers: bundleIdentifiers)
        }
        guard let target = found else { return .noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: target.frame.size,
                                                                                    framesPerSecond: framesPerSecondNow), delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            return .failed(error.localizedDescription)
        }
        let kept = lock.withLock { () -> Bool in
            guard running, generation == number else { return false }
            self.stream = stream
            window = (target.windowID, target.frame.size)
            if selected != nil { selectedCapture = SelectedCapture(filter: filter) }
            return true
        }
        guard kept else {
            try? await stream.stopCapture()
            return .attached
        }
        let name = target.owningApplication?.applicationName ?? "Remote Play"
        RemotePlayLog.write("\(name) penceresi okunuyor: \(Int(target.frame.width))x\(Int(target.frame.height))")
        report(.streaming)
        await MainActor.run {
            watchWindow(number)
            if selected != nil { watchFrames(number) }
        }
        return .attached
    }

    /// Seçilen Remote Play uygulamalarının en büyük penceresi (ekranda olan önce): oyunun göründüğü pencere.
    static func gameWindow(in windows: [SCWindow], bundleIdentifiers: [String]) -> SCWindow? {
        let candidates = windows.filter {
            bundleIdentifiers.contains($0.owningApplication?.bundleIdentifier ?? "")
                && $0.frame.width >= minimumSize.width && $0.frame.height >= minimumSize.height
        }
        return candidates.max { a, b in
            if a.isOnScreen != b.isOnScreen { return !a.isOnScreen }
            return a.frame.width * a.frame.height < b.frame.width * b.frame.height
        }
    }

    /// Kare pencerenin oranında ve en çok `maximumWidth` genişliğinde (bölge oranları pencereye göre kalsın).
    static func configuration(for size: CGSize, framesPerSecond: Int32 = framesPerSecond) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        var width = size.width * scale
        var height = size.height * scale
        if width > maximumWidth {
            height *= maximumWidth / width
            width = maximumWidth
        }
        configuration.width = max(2, Int(width.rounded()))
        configuration.height = max(2, Int(height.rounded()))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Kare ekranın renk uzayında (Display P3, ekranın ICC profili) değil sRGB'de gelir: okuma, telefon araması ve renk
        // örnekleri dosyadaki karelerle aynı değerleri görür (X, Mac mini, beta-101: canlıda telefon bulunmuyordu).
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.queueDepth = 3
        if #available(macOS 14.0, *) {
            configuration.scalesToFit = true
            configuration.ignoreShadowsSingleWindow = true
        }
        return configuration
    }

    /// Pencere büyütülür ya da tam ekrana geçerse kare boyu ona uyar. Remote Play oyunu başka bir pencerede açarsa
    /// (PS5 seçim penceresinden akış penceresine geçiş gibi) okuma o pencereye geçer.
    private func watchWindow(_ number: Int) {
        sizeWatch?.cancel()
        sizeWatch = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isCurrent(number) else { return }
                tick += 1
                if tick % 60 == 0 { SubtitleLog.write(self.frameCounts.minuteLine()) }
                let (stream, window) = self.lock.withLock { (self.stream, self.window) }
                guard let stream, let window else { continue }
                if self.selected != nil {
                    // Seçilen pencere kapandı: aynı pencere yeniden aranır, başka pencereye ya da masaüstüne geçilmez.
                    if Self.currentSize(of: window.id) == nil {
                        RemotePlayLog.write("Seçilen pencere kapandı; yeniden açılması bekleniyor")
                        await MainActor.run { self.reconnectNow() }
                        return
                    }
                } else if tick % 3 == 0, await Self.betterWindowAppeared(than: window.id, bundleIdentifiers: self.bundleIdentifiers) {
                    RemotePlayLog.write("Remote Play'de oyun başka bir pencerede; o pencereye geçiliyor")
                    await MainActor.run { self.reconnectNow() }
                    return
                }
                guard let size = Self.currentSize(of: window.id) else { continue }
                guard abs(size.width - window.size.width) > 2 || abs(size.height - window.size.height) > 2 else { continue }
                self.lock.withLock { self.window = (window.id, size) }
                try? await stream.updateConfiguration(Self.configuration(for: size, framesPerSecond: self.framesPerSecondNow))
            }
        }
    }

    /// Okunandan daha uygun bir Remote Play penceresi var mı: okunan kapandı, ekranda olmayana karşı ekranda olan ya da
    /// belirgin biçimde daha büyük olan. Aynı iki pencere arasında gidip gelinmesin diye küçük farklar sayılmaz.
    static func betterWindowAppeared(than id: CGWindowID, bundleIdentifiers: [String]) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let best = gameWindow(in: content.windows, bundleIdentifiers: bundleIdentifiers), best.windowID != id else { return false }
        guard let current = content.windows.first(where: { $0.windowID == id }) else { return true }
        if best.isOnScreen != current.isOnScreen { return best.isOnScreen }
        return best.frame.width * best.frame.height > current.frame.width * current.frame.height * 1.1
    }

    static func currentSize(of id: CGWindowID) -> CGSize? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return rect.size
    }

    // MARK: - SCStreamOutput, SCStreamDelegate

    func useCadence(_ cadence: FrameCadence) {
        lock.withLock { self.cadence = cadence }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let capture = lock.withLock { self.stream === stream ? selectedCapture : nil }
        if let capture {
            capture.watch.arrived()
            // Yedek yakalamaya geçildiyse aynı kare iki yoldan verilmez.
            if capture.usesFallback { return }
        }
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        // Değişmeyen ekranda gelen boş kareler okunmaz.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            frameCounts.idle()
            return
        }
        // Yerinde çizim: her kare (kopyalanmadan, okuma sıklığından bağımsız) telefonun çapasına; çapa yoksa hemen geçilir.
        if let anchor = lock.withLock({ self.stream === stream ? self.anchor : nil }), anchor.isActive {
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            if let image { anchor.feed(image, at: SubtitleStabilizer.uptimeMs()) }
        }
        // Sıklık sınırı dolmadıysa kare kopyalanmaz; son kare tutulur, sınır dolunca okunur (oyun takılmasın).
        let cadence = lock.withLock { self.cadence }
        let now = SubtitleStabilizer.uptimeMs()
        cpu.report(to: cadence, now: now)
        guard cadence.admit(now: now) else {
            frameCounts.idle()
            hold(sampleBuffer, from: stream, cadence: cadence)
            return
        }
        held = nil
        deliver(sampleBuffer, pixels: pixels, from: stream, capture: capture)
    }

    /// Kareyi tutar (öncekini havuza bırakır) ve sıklık sınırı dolunca okunmasını zamanlar. `queue`'da çağrılır.
    private func hold(_ sampleBuffer: CMSampleBuffer, from stream: SCStream, cadence: FrameCadence) {
        held = (stream, sampleBuffer)
        guard !heldScheduled else { return }
        heldScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(cadence.intervalMs)) { [weak self] in
            guard let self else { return }
            self.heldScheduled = false
            guard let pending = self.held else { return }
            let (stream, buffer) = pending
            let current = self.lock.withLock { self.stream === stream ? self.cadence : nil }
            guard let current else {
                self.held = nil
                return
            }
            guard current.admit(now: SubtitleStabilizer.uptimeMs()) else {
                self.hold(buffer, from: stream, cadence: current)
                return
            }
            self.held = nil
            guard let pixels = buffer.imageBuffer else { return }
            let capture = self.lock.withLock { self.stream === stream ? self.selectedCapture : nil }
            if let capture, capture.usesFallback { return }
            self.deliver(buffer, pixels: pixels, from: stream, capture: capture)
        }
    }

    /// Kareyi kendi belleğimize kopyalayıp okumaya verir.
    private func deliver(_ sampleBuffer: CMSampleBuffer, pixels: CVPixelBuffer, from stream: SCStream, capture: SelectedCapture?) {
        capture?.watch.copyStarted(at: capture?.elapsed ?? 0)
        var image: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        // VideoToolbox'ın görüntüsü ScreenCaptureKit'in karesini (IOSurface) paylaşır; görüntü tutuldukça kare havuza
        // dönmez. Havuz `queueDepth` karelik: okuma, ek alanlar ve önizleme kareleri tutunca yeni kare gelmiyordu (#822).
        // Kare kendi belleğimize kopyalanır (1920x1080'de ~8 MB, bir milisaniyeyi bulmaz), havuzun karesi hemen döner.
        image = image.map { Self.detached($0, from: pixels) ?? $0 }
        capture?.watch.copyEnded()
        guard let image else {
            if let capture, capture.watch.failed("VTCreateCGImageFromCVPixelBuffer: \(status)") {
                SubtitleLog.write("pencere karesi kopyalanamadı: VTCreateCGImageFromCVPixelBuffer: \(status)")
            }
            return
        }
        if let capture {
            noteBlack(Self.isBlack(pixels), capture: capture, stream: stream)
            if capture.watch.frameDelivered() { SubtitleLog.write("pencereden ilk kare: \(image.width)x\(image.height)") }
        }
        frameCounts.delivered()
        onFrame?(image)
    }

    /// Görüntünün piksellerini ScreenCaptureKit'in karesinden bağımsız bir kopyaya alır (aynı boyut, renk uzayı, düzen).
    static func detached(_ image: CGImage, from pixels: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels), height == image.height, rowBytes >= image.width * 4,
              let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let data = CFDataCreate(nil, base.assumingMemoryBound(to: UInt8.self), rowBytes * height),
              let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: colorSpace, bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Pencere kapandı ya da Remote Play çıktı: pencere yeniden aranır (çeviri durmaz).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let current = lock.withLock { () -> Int? in
            guard running, self.stream === stream else { return nil }
            self.stream = nil
            window = nil
            selectedCapture = nil
            generation += 1
            return generation
        }
        guard let current else { return }
        RemotePlayLog.write("\(selected == nil ? "Remote Play penceresi" : "Seçilen pencere") kapandı: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            self.sizeWatch?.cancel()
            self.sizeWatch = nil
            self.frameWatch?.cancel()
            self.frameWatch = nil
            self.report(.connecting)
            self.startSearch(current)
        }
    }
}
