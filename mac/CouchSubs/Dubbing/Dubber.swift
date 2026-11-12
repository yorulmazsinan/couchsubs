// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CouchSubsCore
import Foundation

/// Çevrilen cümleleri sırayla seslendirir. Bir cümle çalarken sonraki hazırlanır; oyun konuşması hızlıysa geride kalan
/// eski cümleler atlanır ki ses altyazının çok gerisinde kalmasın.
@MainActor
final class Dubber {
    private let engine = PocketTTSEngine()
    private let server: SubtitleServer
    private var serverPort: UInt16
    private var queue: [SpokenLine] = []
    private var worker: Task<Void, Never>?
    /// Her yeni okuma işi bir numara alır; durdurulan eski iş, yerine başlayanın kaydını silmesin.
    private var generation = 0
    private var player: AVAudioPlayer?
    private var voicesPublished = false

    var cast: VoiceCast
    var output: DubbingOutput
    /// Yeni bir karaktere ses verildi; ayarlara kaydedilir.
    var onCastChanged: ((VoiceCast) -> Void)?
    var onError: ((String) -> Void)?

    /// Bekleyen en çok cümle: fazlası eskiden başlayarak atlanır.
    static let backlog = 3

    init(server: SubtitleServer, serverPort: UInt16, settings: DubbingSettings) {
        self.server = server
        self.serverPort = serverPort
        cast = settings.cast
        output = settings.output
    }

    func update(serverPort: UInt16) {
        self.serverPort = serverPort
    }

    /// Model yüklenir, ilk cümle beklemesin.
    func prepare() {
        publishVoices()
        Task { [engine, weak self] in
            do { try await engine.start() } catch { self?.onError?(error.localizedDescription) }
        }
    }

    func speak(_ lines: [SpokenLine]) {
        guard !lines.isEmpty else { return }
        publishVoices()
        // Yeni altyazı geldiyse öncekilerin cümleleri artık geç kalmıştır: bekleyenler atılır, çalan da kesilir.
        // Ses yazının gerisinde kalıp oyunu karıştırmasın; dublaj hep ekrandaki altyazıyı söyler.
        if worker != nil {
            worker?.cancel()
            worker = nil
            player?.stop()
            player = nil
            server.stopSpeech()
        }
        queue = lines
        if queue.count > Self.backlog { queue.removeFirst(queue.count - Self.backlog) }
        startWorker()
    }

    private func startWorker() {
        generation += 1
        let current = generation
        worker = Task { await run(current) }
    }

    /// Ayarlardaki "Dinle" düğmesi.
    func preview(_ voice: DubbingVoice) {
        stop()
        previewVoice = voice
        // Dublaj yalnız Türkçe: arayüz dili ne olursa olsun deneme cümlesi Türkçedir.
        speak([SpokenLine(english: "Listen.", turkish: "Merhaba, oyundaki karakterleri Türkçe seslendireceğim.")])
    }

    private var previewVoice: DubbingVoice?

    func stop() {
        queue.removeAll()
        worker?.cancel()
        worker = nil
        generation += 1
        player?.stop()
        player = nil
        server.stopSpeech()
    }

    func shutdown() async {
        stop()
        await engine.stop()
    }

    private func run(_ number: Int) async {
        var next: Task<(SpeechAudio, Bool)?, Never>? = makeNext()
        while let current = next {
            guard let (audio, preview) = await current.value, !Task.isCancelled, number == generation else { break }
            // Bu cümle çalarken sonraki hazırlanır.
            next = makeNext()
            // Ayarlardaki deneme her zaman Mac'ten çalar: kullanıcı o an Mac'in başında.
            await play(audio, on: preview ? .computer : output)
            if Task.isCancelled || number != generation { next?.cancel(); break }
        }
        guard number == generation else { return }
        worker = nil
        if !queue.isEmpty, !Task.isCancelled { startWorker() }
    }

    private func makeNext() -> Task<(SpeechAudio, Bool)?, Never>? {
        guard !queue.isEmpty else { return nil }
        let line = queue.removeFirst()
        let voice: DubbingVoice
        let preview = previewVoice != nil
        if let previewVoice {
            voice = previewVoice
            self.previewVoice = nil
        } else {
            let before = cast
            voice = cast.voice(for: line)
            if cast.assignments != before.assignments { onCastChanged?(cast) }
        }
        let text = SpeechText.prepare(line.turkish, emotion: SpeechEmotion.guess(english: line.english))
        let url = URL(string: "http://127.0.0.1:\(serverPort)/voices/\(voice.rawValue).wav")!
        return Task { [engine, weak self] in
            do {
                return (try await engine.synthesize(text, voice: url).tightened(), preview)
            } catch {
                if !Task.isCancelled { await MainActor.run { self?.onError?(error.localizedDescription) } }
                return nil
            }
        }
    }

    private func play(_ audio: SpeechAudio, on output: DubbingOutput) async {
        let wav = audio.wav
        let milliseconds = Int(audio.duration * 1000)
        switch output {
        case .tv:
            server.sendSpeech(wav, durationMs: milliseconds)
            // TV sesi ağdan alıp çalmaya biraz geç başlar; sıradaki cümle bunu kesmesin.
            try? await Task.sleep(for: .milliseconds(milliseconds + 250))
        case .computer:
            player = try? AVAudioPlayer(data: wav)
            player?.play()
            try? await Task.sleep(for: .milliseconds(milliseconds + 60))
        }
    }

    /// pocket-tts sesleri altyazı sunucusundan alır (`/voices/<ad>.wav`).
    private func publishVoices() {
        guard !voicesPublished, DubbingModelStore.isReady else { return }
        for voice in DubbingVoice.allCases {
            if let data = try? Data(contentsOf: DubbingModelStore.voiceFile(voice)) {
                server.publish(data, at: "/voices/\(voice.rawValue).wav")
            }
        }
        voicesPublished = true
    }
}
