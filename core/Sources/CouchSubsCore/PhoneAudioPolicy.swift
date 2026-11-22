// SPDX-License-Identifier: AGPL-3.0-only
// iPhone'da CouchSubs'ın açtığı ses oturumunun tek tanımı (Xbox oyun sesi ve PiP aynı ayarı kullanır).
// Uygulama mikrofonu hiç kullanmaz: oturum medya oynatma oturumudur (.playback). Kullanıcının seçtiği çıkış (kablolu
// kulaklık, AirPods, Bluetooth hoparlör, AirPlay) korunur; çıkış hiçbir yerde hoparlöre zorlanmaz.
// #907: Xbox sesi WebRTC'nin varsayılan ses birimiyle .playAndRecord + .defaultToSpeaker oturumunda çalınıyordu.
// Ses işleme birimi (VoiceProcessingIO) mikrofonu da açtığı için iOS Bluetooth kulaklığın medya (A2DP) çıkışını
// bırakıyor, .defaultToSpeaker da sesi alt hoparlöre veriyordu: bağlanınca ses kulaklıktan telefona geçiyordu.
// Değerler AVAudioSession'ın ham adlarıdır; çekirdek macOS'ta da derlendiği için AVAudioSession türü kullanılmaz.

public struct PhoneAudioPolicy: Equatable, Sendable {
    /// AVAudioSession.Category ham adı.
    public let category: String
    /// AVAudioSession.Mode ham adı.
    public let mode: String
    /// .mixWithOthers: telefonda çalan müzik/podcast kesilmez.
    public let mixesWithOthers: Bool
    /// .defaultToSpeaker ya da overrideOutputAudioPort(.speaker): çıkışı alt hoparlöre zorlar. Hep kapalı.
    public let forcesSpeaker: Bool
    /// Mikrofon girişi (.playAndRecord, ses işleme birimi). Hep kapalı.
    public let usesMicrophone: Bool

    public static let playbackCategory = "AVAudioSessionCategoryPlayback"
    public static let moviePlaybackMode = "AVAudioSessionModeMoviePlayback"

    /// Xbox oyun sesi ve PiP oturumu.
    public static let media = PhoneAudioPolicy(category: playbackCategory, mode: moviePlaybackMode,
                                               mixesWithOthers: true, forcesSpeaker: false, usesMicrophone: false)

    /// Oyun sesinin bu cihazda çalınma biçimi: mono, 16 bit, 48 kHz (WebRTC'nin iOS ses biriminin eski çıkışıyla aynı).
    public static let playoutSampleRate = 48_000.0
    public static let playoutChannels = 1
}

#if os(iOS)
import AVFoundation

public extension PhoneAudioPolicy {
    /// AVAudioSession seçenekleri. `.defaultToSpeaker` yalnız .playAndRecord'da geçerlidir; burada hiç eklenmez.
    var options: AVAudioSession.CategoryOptions { mixesWithOthers ? [.mixWithOthers] : [] }

    /// Oturumu bu ayarla kurar (etkinleştirmez). Çıkış yolu değiştirilmez: iOS kullanıcının seçtiği çıkışı kullanır.
    func apply(to session: AVAudioSession = .sharedInstance()) throws {
        try session.setCategory(AVAudioSession.Category(rawValue: category), mode: AVAudioSession.Mode(rawValue: mode), options: options)
    }
}
#endif
