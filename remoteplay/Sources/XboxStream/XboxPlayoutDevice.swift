// SPDX-License-Identifier: AGPL-3.0-only
// iPhone'da Xbox oyun sesinin yalnız-çalma ses birimi (WebRTC'nin RTCAudioDevice arayüzü).
// WebRTC'nin varsayılan iOS ses birimi görüşme içindir: VoiceProcessingIO'yu mikrofonla birlikte açar ve oturumu
// .playAndRecord + .defaultToSpeaker ister. Bu yüzden Bluetooth kulaklık (AirPods) bağlıyken bağlanınca ses
// kulaklıktan telefonun hoparlörüne geçiyordu (#907). Bu birim mikrofonu hiç açmaz; RemoteIO'nun yalnız çıkışını
// kullanır ve oturumu medya oynatma oturumu olarak kurar (PhoneAudioPolicy.media: .playback, .mixWithOthers). Çıkış
// yolu değiştirilmez: ses kullanıcının seçtiği çıkıştan (kulaklık, AirPods, Bluetooth hoparlör, AirPlay) çalar.
// Kayıt istenirse reddedilir: Xbox'a ses gönderilmez (yerel ses parçası yok).
// Mac'te kullanılmaz (Mac'te ses oturumu yoktur; WebRTC'nin varsayılan birimi sistemin çıkışından çalar).

#if os(iOS)
import AudioToolbox
import AVFoundation
import CouchSubsCore
import Foundation
import RemotePlay
import WebRTC

final class XboxPlayoutDevice: NSObject, RTCAudioDevice {
    private let lock = NSLock()
    private var delegate: RTCAudioDeviceDelegate?
    /// Ses birimi çalışırken okunur (gerçek zamanlı iş parçacığı); yalnız birim dururken değişir.
    fileprivate var playoutData: RTCAudioDeviceGetPlayoutDataBlock?
    private var unit: AudioUnit?
    private var initialized = false
    private var playoutReady = false
    private var playing = false
    /// "Xbox sesini bu cihazda çal" ayarı. Kapalıyken birim çalışmaz, ses oturumuna dokunulmaz.
    private var enabled = false
    private var running = false
    private var interruption: NSObjectProtocol?

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func log(_ text: String) { RemotePlayLog.write("Xbox ses: \(text)") }

    /// Ayar değişti (ya da oturum açıldı/kapandı): birim gerekiyorsa başlatılır, gerekmiyorsa durdurulur.
    func setEnabled(_ value: Bool) {
        locked { enabled = value }
        update()
    }

    // MARK: - RTCAudioDevice

    var deviceInputSampleRate: Double { PhoneAudioPolicy.playoutSampleRate }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }
    var deviceOutputSampleRate: Double { PhoneAudioPolicy.playoutSampleRate }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputNumberOfChannels: Int { PhoneAudioPolicy.playoutChannels }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }
    var isInitialized: Bool { locked { initialized } }
    var isPlayoutInitialized: Bool { locked { playoutReady } }
    var isPlaying: Bool { locked { playing } }
    var isRecordingInitialized: Bool { false }
    var isRecording: Bool { false }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        locked {
            self.delegate = delegate
            initialized = true
        }
        if interruption == nil {
            interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                self?.interrupted(note)
            }
        }
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        locked {
            delegate = nil
            initialized = false
            playoutReady = false
        }
        return true
    }

    func initializePlayout() -> Bool {
        locked { playoutReady = true }
        return true
    }

    func startPlayout() -> Bool {
        locked { playing = true }
        update()
        return true
    }

    func stopPlayout() -> Bool {
        locked { playing = false }
        update()
        return true
    }

    // Mikrofon hiç açılmaz.
    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }

    // MARK: - Ses birimi

    private func update() {
        let (shouldRun, isRunning, block) = locked { (enabled && playing && delegate != nil, running, delegate?.getPlayoutData) }
        if shouldRun && !isRunning {
            guard let block else { return }
            playoutData = block
            if start() {
                locked { running = true }
                log("çalıyor (\(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")))")
            } else {
                playoutData = nil
            }
        } else if !shouldRun && isRunning {
            stop()
            locked { running = false }
            playoutData = nil
            log("durdu")
        }
    }

    private func start() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try PhoneAudioPolicy.media.apply(to: session)
            try session.setActive(true)
        } catch {
            log("oturum açılamadı: \(error.localizedDescription)")
            return false
        }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_RemoteIO,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return false }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return false }
        // RemoteIO'da giriş (mikrofon, 1. veriyolu) varsayılan kapalıdır; yalnız çıkış (0. veriyolu) kullanılır.
        let channels = UInt32(PhoneAudioPolicy.playoutChannels)
        var format = AudioStreamBasicDescription(mSampleRate: PhoneAudioPolicy.playoutSampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                 mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
                                                 mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: xboxPlayoutRender, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let steps: [(String, OSStatus)] = [
            ("biçim", AudioUnitSetProperty(instance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size))),
            ("geri çağırma", AudioUnitSetProperty(instance, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                                                  UInt32(MemoryLayout<AURenderCallbackStruct>.size))),
            ("hazırlama", AudioUnitInitialize(instance)),
            ("başlatma", AudioOutputUnitStart(instance)),
        ]
        for (name, status) in steps where status != noErr {
            log("ses birimi \(name) hatası: \(status)")
            AudioUnitUninitialize(instance)
            AudioComponentInstanceDispose(instance)
            return false
        }
        locked { unit = instance }
        return true
    }

    private func stop() {
        guard let instance = locked({ () -> AudioUnit? in defer { unit = nil }; return unit }) else { return }
        AudioOutputUnitStop(instance)
        AudioUnitUninitialize(instance)
        AudioComponentInstanceDispose(instance)
        // Oturum kapatılmaz: PiP aynı .playback oturumunu ister; başka uygulamanın sesine karıştığı için zararsızdır.
    }

    /// Arama ya da alarm sesi kesti: bitince birim yeniden başlatılır.
    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let isRunning = locked { running }
        switch type {
        case .began:
            guard isRunning else { return }
            stop()
            locked { running = false }
            playoutData = nil
            log("kesildi")
        case .ended:
            update()
        @unknown default:
            break
        }
    }
}

/// RemoteIO çıkış geri çağırması: WebRTC'den çözülmüş oyun sesini ister.
private func xboxPlayoutRender(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               _ timestamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                               _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let device = Unmanaged<XboxPlayoutDevice>.fromOpaque(refCon).takeUnretainedValue()
    guard let data else { return noErr }
    guard let block = device.playoutData else {
        for buffer in UnsafeMutableAudioBufferListPointer(data) {
            if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
        }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }
    return block(flags, timestamp, Int(bus), frames, data)
}
#endif
