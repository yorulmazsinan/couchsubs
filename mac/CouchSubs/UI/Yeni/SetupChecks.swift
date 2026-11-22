// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreWLAN
import Darwin
import Foundation
import RemotePlay

/// "PS5 Bulunamadı" ekranının kendiliğinden denetimleri (tuval 04). Okunamayan madde `unknown` kalır; tahmin yok.
struct SetupCheck: Identifiable, Equatable {
    enum State: Equatable { case passed, problem, unknown }
    enum Kind: CaseIterable { case sameNetwork, ps5Responds, remotePlay, restModeInternet, wifi5GHz, vpn }

    let kind: Kind
    let state: State
    var id: Kind { kind }

    /// Denetimleri çalıştırır. `consoles`: az önceki aramanın sonucu (aynı arama yeniden yapılmaz).
    static func run(consoles: [ConsoleInfo]) -> [SetupCheck] {
        let addresses = Interfaces.read()
        let lan = addresses.contains { $0.isPrivateIPv4 && ($0.name.hasPrefix("en") || $0.name.hasPrefix("bridge")) }
        let vpn = addresses.contains { entry in entry.isIPv4 && ["utun", "ipsec", "ppp", "tun", "tap"].contains { entry.name.hasPrefix($0) } }
        return [
            SetupCheck(kind: .sameNetwork, state: lan ? .passed : .problem),
            SetupCheck(kind: .ps5Responds, state: consoles.isEmpty ? .problem : .passed),
            // PS5'in Uzaktan Oynatma ayarı ağdan okunamaz; eşleşme denemesi söyler.
            SetupCheck(kind: .remotePlay, state: .unknown),
            // Dinlenme modundaki PS5 aramaya yalnız "İnternete Bağlı Kal" açıkken yanıt verir.
            SetupCheck(kind: .restModeInternet, state: consoles.contains { !$0.isAwake } ? .passed : .unknown),
            SetupCheck(kind: .wifi5GHz, state: wifiBand()),
            SetupCheck(kind: .vpn, state: vpn ? .problem : .passed),
        ]
    }

    /// Wi-Fi bandı (CoreWLAN); kabloyla bağlıysa ya da okunamazsa bilinmiyor.
    private static func wifiBand() -> State {
        guard let channel = CWWiFiClient.shared().interface()?.wlanChannel() else { return .unknown }
        switch channel.channelBand {
        case .band5GHz, .band6GHz: return .passed
        case .band2GHz: return .problem
        default: return .unknown
        }
    }

    private struct Interfaces {
        let name: String
        let isIPv4: Bool
        let isPrivateIPv4: Bool

        static func read() -> [Interfaces] {
            var list: [Interfaces] = []
            var head: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&head) == 0, let first = head else { return [] }
            defer { freeifaddrs(head) }
            var pointer: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = pointer {
                defer { pointer = entry.pointee.ifa_next }
                guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                      (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
                let name = String(cString: entry.pointee.ifa_name)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let ip = String(cString: host)
                let isPrivate = ip.hasPrefix("10.") || ip.hasPrefix("192.168.")
                    || (ip.hasPrefix("172.") && (16...31).contains(Int(ip.split(separator: ".").dropFirst().first ?? "") ?? 0))
                list.append(Interfaces(name: name, isIPv4: true, isPrivateIPv4: isPrivate))
            }
            return list
        }
    }
}

/// Açılış sesi: iki notalı kısa, yumuşak bir çan (2,4 sn; dosya yok, sesi uygulama üretir). Yalnız ilk kurulumun
/// açılış adımında ve Ayarlar › Temel › Açılış Sesi açıkken çalar.
@MainActor
final class StartupChime {
    static let shared = StartupChime()
    private var engine: AVAudioEngine?

    func play() {
        stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let frames = AVAudioFrameCount(rate * 3.4)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = frames
        Self.render(into: data, count: Int(frames), rate: rate)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer)
        player.play()
        self.engine = engine
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    /// Tuvaldeki açılış sesi (Main.dc.html): 0–0,85 sn yükselen hava (bant geçiren gürültü 250 → 3200 Hz), 0,78 sn derin
    /// vuruş (140 → 42 Hz), 0,80 ve 0,94 sn iki parlak tık (1318,5 / 1760 Hz), 1,15 sn'de yavaş sönen sıcak akor.
    private static func render(into data: UnsafeMutablePointer<Float>, count: Int, rate: Double) {
        var noiseState: (low: Double, band: Double) = (0, 0)
        var seed: UInt32 = 0x2545F491
        var kickPhase = 0.0
        var chordLow = [Double](repeating: 0, count: 5)
        let chord: [Double] = [110, 164.81, 220, 277.18, 329.63]
        func ramp(_ t: Double, _ a: Double, _ b: Double, from v0: Double, to v1: Double) -> Double {
            // Üstel geçiş (Web Audio exponentialRampToValueAtTime gibi).
            guard t > a else { return v0 }
            guard t < b else { return v1 }
            return v0 * pow(v1 / v0, (t - a) / (b - a))
        }
        for frame in 0..<count {
            let t = Double(frame) / rate - 0.05
            var sample = 0.0
            // 1) Hava
            if t >= 0, t < 0.9 {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let noise = Double(seed) / Double(UInt32.max) * 2 - 1
                let frequency = ramp(t, 0, 0.72, from: 250, to: 3200)
                let f = 2 * sin(.pi * frequency / rate)
                let high = noise - noiseState.low - noiseState.band / 1.2
                noiseState.band += f * high
                noiseState.low += f * noiseState.band
                let gain = t < 0.6 ? ramp(t, 0, 0.6, from: 0.0001, to: 0.35) : ramp(t, 0.6, 0.85, from: 0.35, to: 0.0001)
                sample += noiseState.band * gain
            }
            // 2) Vuruş
            if t >= 0.78, t < 1.6 {
                let frequency = ramp(t, 0.78, 1.1, from: 140, to: 42)
                kickPhase += 2 * .pi * frequency / rate
                let gain = t < 0.79 ? ramp(t, 0.78, 0.79, from: 0.0001, to: 0.9) : ramp(t, 0.79, 1.5, from: 0.9, to: 0.0001)
                sample += sin(kickPhase) * gain
            }
            // 3) Tıklar (üçgen dalga)
            for (start, frequency) in [(0.80, 1318.5), (0.94, 1760.0)] where t >= start && t < start + 0.4 {
                let local = t - start
                let phase = (local * frequency).truncatingRemainder(dividingBy: 1)
                let triangle = 4 * abs(phase - 0.5) - 1
                let gain = local < 0.01 ? ramp(local, 0, 0.01, from: 0.0001, to: 0.22) : ramp(local, 0.01, 0.35, from: 0.22, to: 0.0001)
                sample += triangle * gain
            }
            // 4) Akor (ilk ikisi testere dişi, alçak geçiren 400 → 1800 Hz)
            if t >= 1.15, t < 3.3 {
                let cutoff = 400 + 1400 * min(1, max(0, (t - 1.15) / 0.45))
                let alpha = 1 - exp(-2 * .pi * cutoff / rate)
                for (index, base) in chord.enumerated() {
                    let frequency = base * pow(2, (index % 2 == 0 ? -6.0 : 6.0) / 1200)
                    let local = t - 1.15
                    let phase = (local * frequency).truncatingRemainder(dividingBy: 1)
                    let wave = index < 2 ? 2 * phase - 1 : sin(2 * .pi * phase)
                    chordLow[index] += alpha * (wave - chordLow[index])
                    let peak = index < 2 ? 0.08 : 0.12
                    let gain = t < 1.3 ? ramp(t, 1.15, 1.3, from: 0.0001, to: peak) : ramp(t, 1.3, 3.2, from: peak, to: 0.0001)
                    sample += chordLow[index] * gain
                }
            }
            // Sıkıştırıcının yerine yumuşak sınırlama.
            data[frame] = Float(tanh(sample * 0.9))
        }
    }
}
