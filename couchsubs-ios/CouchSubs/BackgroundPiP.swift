// SPDX-License-Identifier: AGPL-3.0-only
// "Arka planda sürdür (Resim içinde resim)": çeviri sürerken uygulamadan çıkılınca oyun görüntüsü ve canlı altyazı
// iOS'un Resim içinde resim (PiP) penceresinde oynamaya devam eder. Pencere açıkken iOS uygulamayı askıya almaz; PS5/Xbox
// görüntüsü okunur, çeviri ve TV'ye gönderim sürer (Android'de aynı ayar ön plan hizmetinin yanında küçük pencere açar).
//
// App Store: PiP için "Audio, AirPlay, and Picture in Picture" arka plan modu (UIBackgroundModes: audio) ve .playback
// ses oturumu gerekir (Apple, "Configuring your app for media playback"). Sessiz ses çalınmaz: uygulamayı ayakta tutan
// görünür PiP penceresidir; pencere kapanınca iOS uygulamayı her zamanki gibi duraklatır. Pencere yalnız kullanıcı
// uygulamadan çıkınca (sistemin kendi "satır içinden kendiliğinden başlat" davranışı) ya da düğmeye dokununca açılır.

import AVFoundation
import AVKit
import Combine
import CouchSubsCore
import RemotePlay
import SwiftUI
import UIKit

@MainActor
final class BackgroundPiP: NSObject, ObservableObject {
    static let shared = BackgroundPiP()

    /// Pencerede oynayan görüntü (oyun karesi + canlı altyazı, saniyede birkaç kare).
    let displayLayer = AVSampleBufferDisplayLayer()
    /// PiP penceresi açık.
    @Published private(set) var isActive = false
    /// Bu cihaz ve o anki durum PiP açmaya elveriyor (FaceTime penceresi açıkken iOS izin vermez).
    @Published private(set) var isPossible = false
    /// PiP penceresi başladı / uygulama arka plandayken kapandı (uygulama bildirim zamanlar ya da siler).
    var onStarted: () -> Void = {}
    var onStoppedInBackground: () -> Void = {}

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var model: PhoneModel?
    private var bindings: Set<AnyCancellable> = []
    private var renderTask: Task<Void, Never>?
    private var ownsAudioSession = false
    /// Satır içi görüntüyü taşıyan görünümler (çalışma ekranı, üstünde açılan altyazı ekranı); katman en üsttekinde durur.
    private var hosts: [WeakHost] = []
    /// Son arka plan geçişinde PiP açıktı ve uygulama dönene kadar kapanmadı: bağlantılar askıya alınmadı.
    private var keptAlive = false
    private var starting = false

    static let size = CGSize(width: 640, height: 360)
    /// Saniyede kare (altyazı ve oyun görüntüsü için yeter; işlemciyi yormaz).
    static let framesPerSecond: Double = 3

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    /// Ayar ve çeviri durumu izlenir: ikisi de açıkken PiP hazırlanır, biri kapanınca kalkar.
    func bind(_ model: PhoneModel) {
        self.model = model
        bindings = []
        model.$isRunning.combineLatest(model.$backgroundPiP)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] running, enabled in
                // @Published, değer yazılmadan önce yayınlar: bir sonraki turda okunur.
                DispatchQueue.main.async { self?.update(running: running, enabled: enabled) }
            }
            .store(in: &bindings)
    }

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    private func update(running: Bool, enabled: Bool) {
        if running && enabled && Self.isSupported { prepare() } else { tearDown() }
    }

    private func prepare() {
        configureAudio()
        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            // Canlı görüntü: ileri/geri sarma düğmeleri yok.
            controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
                let possible = controller.isPictureInPicturePossible
                Task { @MainActor in self?.isPossible = possible }
            }
            self.controller = controller
        }
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.renderFrame()
                try? await Task.sleep(for: .seconds(1 / Self.framesPerSecond))
            }
        }
    }

    private func tearDown() {
        renderTask?.cancel()
        renderTask = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        possibleObservation = nil
        controller = nil
        isPossible = false
        flush()
        releaseAudio()
    }

    /// Düğmeyle açma (Apple: PiP yalnız kullanıcının isteğiyle başlar).
    func startManually() {
        guard let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    // MARK: - Arka plan geçişleri

    /// Uygulama arka plana geçti. PiP açılıyor ya da açıksa bağlantılar ayakta kalır.
    func enteredBackground() {
        keptAlive = isActive || starting
    }

    /// Uygulama öne döndü: arka planda PiP hiç kapanmadıysa iOS uygulamayı askıya almadı, bağlantılar yenilenmez.
    func takeKeptAlive() -> Bool {
        defer { keptAlive = false }
        return keptAlive
    }

    // MARK: - Ses oturumu

    /// PiP .playback ses oturumu ister (Apple belgesi). Sessiz ses çalınmaz; oturum yalnız kategori olarak açılır.
    /// Xbox oyun sesi bu telefonda çalıyorsa oturumu XboxPlayoutDevice aynı ayarla (PhoneAudioPolicy.media) açar.
    /// `.mixWithOthers`: .playback tek başına karışmaz, açılınca telefonda çalan müziği/podcast'i keser (Apple,
    /// AVAudioSession.Category.playback). Bu oturum ses çalmadığı için başka uygulamanın sesine karışır; kategori yine
    /// .playback olduğundan PiP'in şartı (arka plan modu + .playback) karşılanır.
    private func configureAudio() {
        guard !ownsAudioSession else { return }
        if let model, model.isXbox, model.settings.xboxAudioOnDevice { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try PhoneAudioPolicy.media.apply(to: session)
            try session.setActive(true)
            ownsAudioSession = true
        } catch {
            RemotePlayLog.write("PiP ses oturumu açılamadı: \(error.localizedDescription)")
        }
    }

    private func releaseAudio() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Satır içi görünüm

    fileprivate func attach(_ host: PiPHostView) {
        hosts.removeAll { $0.view == nil || $0.view === host }
        hosts.append(WeakHost(view: host))
        moveLayer()
    }

    fileprivate func detach(_ host: PiPHostView) {
        hosts.removeAll { $0.view == nil || $0.view === host }
        moveLayer()
    }

    fileprivate func layout(_ host: PiPHostView) {
        guard displayLayer.superlayer === host.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = host.bounds
        CATransaction.commit()
    }

    private func moveLayer() {
        guard let top = hosts.last?.view else {
            displayLayer.removeFromSuperlayer()
            return
        }
        if displayLayer.superlayer !== top.layer { top.layer.addSublayer(displayLayer) }
        layout(top)
    }

    // MARK: - Görüntü

    private func renderFrame() {
        guard let model else { return }
        let text = model.phoneLines.last(where: { $0.role == .current })?.text ?? ""
        let image = PiPFrame.render(frame: model.framePreview.image, subtitle: text, size: Self.size)
        guard let buffer = image.flatMap(PiPFrame.sampleBuffer) else { return }
        enqueue(buffer)
    }

    private func enqueue(_ buffer: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(buffer)
        } else {
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(buffer)
        }
    }

    private func flush() {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            displayLayer.flushAndRemoveImage()
        }
    }

    private struct WeakHost {
        weak var view: PiPHostView?
    }
}

extension BackgroundPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.starting = true }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.starting = false
            self.isActive = true
            if UIApplication.shared.applicationState != .active { self.keptAlive = true }
            RemotePlayLog.write("PiP penceresi açıldı (çeviri arka planda sürüyor)")
            self.onStarted()
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            self.starting = false
            self.keptAlive = false
            RemotePlayLog.write("PiP penceresi açılamadı: \(error.localizedDescription)")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            self.starting = false
            // Arka plandayken kapandı (pencerenin kapatma düğmesi): iOS uygulamayı birazdan askıya alır, dönüşte
            // bağlantılar yenilenmeli. Uygulamaya dönülürken kapanan pencerede durum .inactive'dir; o sayılmaz.
            if UIApplication.shared.applicationState == .background {
                self.keptAlive = false
                RemotePlayLog.write("PiP penceresi arka planda kapandı")
                self.onStoppedInBackground()
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // Pencereden uygulamaya dönülür; çalışma ekranı zaten yerinde.
        completionHandler(true)
    }
}

extension BackgroundPiP: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        // Canlı görüntü duraklatılamaz; çeviriyi durdurmak uygulamadaki "Çeviriyi durdur"dadır.
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        // Sonsuz aralık: canlı yayın (ilerleme çubuğu yok).
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

// MARK: - Kare çizimi

/// PiP karesi: oyun görüntüsü (yoksa koyu zemin) ve altta canlı altyazı. Saf işlev; testlerde de çizilir.
enum PiPFrame {
    static func render(frame: CGImage?, subtitle: String, size: CGSize) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                           kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess, let buffer = output else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // UIKit çizimi üstten aşağı koordinat bekler.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        let bounds = CGRect(origin: .zero, size: size)
        UIColor.black.setFill()
        context.fill(bounds)
        if let frame {
            context.interpolationQuality = .low
            UIImage(cgImage: frame).draw(in: aspectFit(CGSize(width: frame.width, height: frame.height), in: bounds))
        } else {
            let title = NSAttributedString(string: "CouchSubs", attributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor(white: 1, alpha: 0.5),
            ])
            let titleSize = title.size()
            title.draw(at: CGPoint(x: (size.width - titleSize.width) / 2, y: (size.height - titleSize.height) / 2))
        }
        let line = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return buffer }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSAttributedString(string: line, attributes: [
            .font: UIFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
        ])
        let inset: CGFloat = 20
        let width = size.width - inset * 2
        let measured = text.boundingRect(with: CGSize(width: width, height: size.height * 0.6),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let height = min(ceil(measured.height), size.height * 0.6)
        let band = CGRect(x: 0, y: size.height - height - inset * 1.5, width: size.width, height: height + inset * 1.5)
        UIColor(white: 0, alpha: 0.72).setFill()
        context.fill(band)
        text.draw(with: CGRect(x: inset, y: band.minY + inset * 0.75, width: width, height: height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
        return buffer
    }

    static func aspectFit(_ content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return bounds }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Hemen gösterilecek kare (canlı görüntü; zaman damgası saatten).
    static func sampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - SwiftUI

/// Katmanı taşıyan görünüm; birden çok yerde açılabilir, katman en son açılanda durur.
final class PiPHostView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { BackgroundPiP.shared.attach(self) } else { BackgroundPiP.shared.detach(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        BackgroundPiP.shared.layout(self)
    }
}

/// Çalışma ve altyazı ekranındaki canlı önizleme: uygulamadan çıkınca bu görüntü PiP penceresine geçer.
struct PiPPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PiPHostView {
        let view = PiPHostView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PiPHostView, context: Context) {}

    static func dismantleUIView(_ uiView: PiPHostView, coordinator: ()) {
        BackgroundPiP.shared.detach(uiView)
    }
}
