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

    private let queue = DispatchQueue(label: "com.couchsubs.remoteplay-window", qos: .userInitiated)
    private let lock = NSLock()
    /// Her başlatma/durdurma bir numara alır; eski aramanın ya da yakalamanın geç gelen sonucu yenisine karışmaz.
    private var generation = 0
    private var running = false
    private var stream: SCStream?
    private var window: (id: CGWindowID, size: CGSize)?
    /// Pencere arama ve izleme görevleri; yalnız ana iş parçacığında kurulur ve kaldırılır (`start`, `stop`,
    /// `reconnectNow` uygulama modelinden ana iş parçacığında çağrılır).
    private var search: Task<Void, Never>?
    private var sizeWatch: Task<Void, Never>?
    private var askedPermission = false
    /// Son bildirilen durum. Arama her iki saniyede aynı durumu bulur; aynısı yeniden bildirilmez (her "bağlantı yok"
    /// bildirimi okuma hattını sıfırlıyor ve günlüğe yazıyordu).
    private var reported: SessionState?
    private let bundleIdentifiers: [String]

    init(app: RemotePlayApp = .automatic) {
        bundleIdentifiers = Self.bundleIdentifiers(for: app)
        super.init()
    }

    private func report(_ state: SessionState) {
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
        Self.openRemotePlayIfNeeded(bundleIdentifiers)
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

    private func isCurrent(_ number: Int) -> Bool {
        lock.withLock { running && generation == number }
    }

    private func tearDown() {
        search?.cancel()
        search = nil
        sizeWatch?.cancel()
        sizeWatch = nil
        let old = lock.withLock { () -> SCStream? in
            defer { stream = nil; window = nil }
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
                        RemotePlayLog.write("Remote Play penceresi bekleniyor (PS Remote Play ya da chiaki-ng)")
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
        guard let target = Self.gameWindow(in: content.windows, bundleIdentifiers: bundleIdentifiers) else { return .noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: target.frame.size), delegate: self)
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
            return true
        }
        guard kept else {
            try? await stream.stopCapture()
            return .attached
        }
        let name = target.owningApplication?.applicationName ?? "Remote Play"
        RemotePlayLog.write("\(name) penceresi okunuyor: \(Int(target.frame.width))x\(Int(target.frame.height))")
        report(.streaming)
        await MainActor.run { watchWindow(number) }
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
    static func configuration(for size: CGSize) -> SCStreamConfiguration {
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
                let (stream, window) = self.lock.withLock { (self.stream, self.window) }
                guard let stream, let window else { continue }
                if tick % 3 == 0, await Self.betterWindowAppeared(than: window.id, bundleIdentifiers: self.bundleIdentifiers) {
                    RemotePlayLog.write("Remote Play'de oyun başka bir pencerede; o pencereye geçiliyor")
                    await MainActor.run { self.reconnectNow() }
                    return
                }
                guard let size = Self.currentSize(of: window.id) else { continue }
                guard abs(size.width - window.size.width) > 2 || abs(size.height - window.size.height) > 2 else { continue }
                self.lock.withLock { self.window = (window.id, size) }
                try? await stream.updateConfiguration(Self.configuration(for: size))
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

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        // Değişmeyen ekranda gelen boş kareler okunmaz.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return }
        onFrame?(image)
    }

    /// Pencere kapandı ya da Remote Play çıktı: pencere yeniden aranır (çeviri durmaz).
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let current = lock.withLock { () -> Int? in
            guard running, self.stream === stream else { return nil }
            self.stream = nil
            window = nil
            generation += 1
            return generation
        }
        guard let current else { return }
        RemotePlayLog.write("Remote Play penceresi kapandı: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            self.sizeWatch?.cancel()
            self.sizeWatch = nil
            self.report(.connecting)
            self.startSearch(current)
        }
    }
}
