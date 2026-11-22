// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import RemotePlay
import ScreenCaptureKit

/// Seçilen pencereden okuma (Ayarlar › Görüntü kaynağı › "OBS projektörü veya oyun penceresi"; Windows'taki karşılığı
/// `RemotePlayWindowStream(WindowCaptureTarget)`). Yakalama `RemotePlayWindowStream` ile aynıdır; buradakiler pencere
/// listesi, kayıtlı seçimin eşlenmesi, kare gelmeyince tanı ve yedek yakalama, siyah kare uyarısı ve ekran kaydı iznidir.
extension RemotePlayWindowStream {
    /// Seçilen pencerenin süren yakalaması: tanı (`WindowCaptureWatch`), siyah kare sayacı ve yedek yakalamanın durumu.
    final class SelectedCapture: @unchecked Sendable {
        let watch = WindowCaptureWatch()
        let filter: SCContentFilter
        private let started = ProcessInfo.processInfo.systemUptime
        private let lock = NSLock()
        private var black = BlackFrameWatch(limit: Int(RemotePlayWindowStream.framesPerSecond) * 4)
        private var fallback = false

        init(filter: SCContentFilter) {
            self.filter = filter
        }

        /// Yakalamanın başladığından bu yana geçen saniye.
        var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - started }
        var usesFallback: Bool { lock.withLock { fallback } }

        /// Yedek yakalamaya geçer; zaten geçildiyse false.
        func beginFallback() -> Bool {
            lock.withLock {
                if fallback { return false }
                fallback = true
                return true
            }
        }

        func note(black isBlack: Bool) -> BlackFrameWatch.Change? {
            lock.withLock { black.note(black: isBlack) }
        }
    }

    /// Yedek yakalamada saniyedeki kare (Windows'taki PrintWindow yedeğiyle aynı).
    static let fallbackFramesPerSecond = 5

    // MARK: - Pencere listesi ve eşleme

    static func info(_ window: SCWindow) -> CaptureWindowInfo {
        CaptureWindowInfo(id: window.windowID, processName: window.owningApplication?.applicationName ?? "",
                          title: window.title ?? "", width: window.frame.width, height: window.frame.height,
                          layer: window.windowLayer, isOnScreen: window.isOnScreen,
                          isOwn: window.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier)
    }

    /// Kayıtlı seçimin şu an açık olan penceresi; yoksa nil (başka pencereye geçilmez).
    static func selectedWindow(_ target: WindowCaptureTarget, in windows: [SCWindow]) -> SCWindow? {
        guard let match = CaptureWindows.match(target, in: windows.map(info)) else { return nil }
        return windows.first { $0.windowID == match.id }
    }

    /// Kullanıcının seçebileceği pencereler. Ekran kaydı izni yoksa macOS pencere başlıklarını vermez; liste boştur.
    static func captureWindows() async -> [WindowCaptureTarget] {
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return [] }
        return CaptureWindows.selectable(content.windows.map(info))
    }

    // MARK: - Ekran kaydı izni

    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    static let screenRecordingSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// macOS'un izin sorusunu (ilk kez) çıkarır, CouchSubs'ı Ekran Kaydı listesine ekler ve o sayfayı açar.
    static func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(screenRecordingSettingsURL)
    }

    // MARK: - Tanı, yedek yakalama, siyah kare

    /// Yakalama başladı ama okumaya kare gitmiyorsa nedeni iki günlüğe de yazılır; beş saniyede hiç kare verilmediyse
    /// yedek yakalamaya geçilir. İlk kare verilince durur. Ana iş parçacığında kurulur.
    func watchFrames(_ number: Int) {
        frameWatch?.cancel()
        frameWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isCurrent(number), let capture = self.lock.withLock({ self.selectedCapture }) else { return }
                if capture.watch.delivered { return }
                if let note = capture.watch.tick(sinceStart: capture.elapsed) {
                    RemotePlayLog.write("Seçilen pencere: \(note)")
                    SubtitleLog.write(note)
                }
                if capture.watch.shouldFallBack(sinceStart: capture.elapsed), capture.beginFallback() {
                    await self.runFallback(capture, number: number)
                    return
                }
            }
        }
    }

    /// ScreenCaptureKit akışı okumaya kare vermedi: pencere saniyede beş kez tek tek görüntülenir (macOS 14 ve sonrası;
    /// Windows'taki PrintWindow yedeğinin karşılığı). Üstteki altyazı penceremiz bu yolla da okunmaz.
    private func runFallback(_ capture: SelectedCapture, number: Int) async {
        guard #available(macOS 14.0, *) else {
            RemotePlayLog.write("Seçilen pencere: macOS pencereden kare vermiyor; yedek yakalama macOS 14 gerektirir")
            return
        }
        let text = "macOS pencereden kare vermiyor; pencere yedek yolla (tek tek görüntü) okunuyor"
        RemotePlayLog.write("Seçilen pencere: \(text)")
        SubtitleLog.write(text)
        var failureNoted = false
        while !Task.isCancelled, isCurrent(number) {
            guard let window = lock.withLock({ self.window }), lock.withLock({ selectedCapture === capture }) else { return }
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: capture.filter,
                                                                       configuration: Self.configuration(for: window.size))
                guard isCurrent(number) else { return }
                if capture.watch.frameDelivered() {
                    SubtitleLog.write("pencereden ilk kare (yedek yakalama): \(image.width)x\(image.height)")
                }
                frameCounts.fallback()
                onFrame?(image)
            } catch {
                if !failureNoted {
                    failureNoted = true
                    RemotePlayLog.write("Seçilen pencere: yedek yakalama hatası: \(error.localizedDescription)")
                    SubtitleLog.write("yedek yakalama hatası: \(error.localizedDescription)")
                }
            }
            try? await Task.sleep(for: .milliseconds(1000 / Self.fallbackFramesPerSecond))
        }
    }

    /// Karenin seyrek bir örneği simsiyah mı (uygulama penceresinin yakalanmasını engelliyor olabilir).
    static func isBlack(_ pixels: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return false }
        let count = CVPixelBufferGetBytesPerRow(pixels) * CVPixelBufferGetHeight(pixels)
        return BlackFrameWatch.isBlack(bgra: UnsafeRawBufferPointer(start: base, count: count))
    }

    /// Kareler dört saniye simsiyah gelirse ana ekranda uyarılır; görüntü gelince uyarı kalkar.
    func noteBlack(_ isBlack: Bool, capture: SelectedCapture, stream: SCStream) {
        guard let change = capture.note(black: isBlack), lock.withLock({ self.stream === stream }) else { return }
        switch change {
        case .warn:
            RemotePlayLog.write("Seçilen pencere siyah geliyor: ekran yakalama engelleniyor olabilir")
            report(.disconnected(.other(String(localized: "The selected window is black. Check the OBS projector or game window."))))
        case .clear:
            report(.streaming)
        }
    }
}
