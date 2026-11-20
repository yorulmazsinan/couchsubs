// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation
#if os(iOS)
import os
#endif

/// Uzun oturumun sağlık satırı ve "durdurulmadan biten oturum" kaydı. Telefon uygulamasının uzun oyunda (40-45 dk)
/// kendiliğinden kapandığı bildirildi; sistemin belleği yetmediği için öldürdüğü (jetsam) uygulama çökme raporu
/// bırakmaz. Çeviri sürerken on dakikada bir bellek, ısı ve oturum süresi günlüğe yazılır; uygulama oturum sürerken
/// kapanırsa bir sonraki açılışta son satırla birlikte raporlanır. Android'deki SessionHealth ile aynı biçim.
public enum SessionHealth {
    /// Sağlık satırının aralığı.
    public static let interval: TimeInterval = 10 * 60

    /// ProcessInfo.ThermalState (0 normal … 3 kritik); Android'in PowerManager.THERMAL_STATUS_* değerleri de
    /// bu dört basamağa indirilir.
    public static func thermalName(_ state: Int) -> String {
        switch state {
        case ..<1: "normal"
        case 1: "orta"
        case 2: "yüksek"
        default: "kritik"
        }
    }

    /// "oturum 40 dk; bellek 812 MB (boş 310 MB); bellek uyarısı 2; ısı yüksek"
    public static func line(minutes: Int, memoryMB: Int, availableMB: Int?, memoryWarnings: Int, thermal: Int) -> String {
        var text = "oturum \(max(0, minutes)) dk; bellek \(memoryMB) MB"
        if let availableMB { text += " (boş \(availableMB) MB)" }
        text += "; bellek uyarısı \(memoryWarnings); ısı \(thermalName(thermal))"
        return text
    }

    /// Çeviri sürerken kalıcı olarak saklanan iz: oturum düzgün durdurulunca silinir. Açılışta hâlâ duruyorsa uygulama
    /// oturum sürerken kapanmıştır (çökme, bellek yetmemesi ya da arka planda sistemin kapatması).
    public struct Mark: Codable, Equatable, Sendable {
        public var startedAt: Date
        public var lastLine: String?
        /// Kapanmadan önce uygulama arka planda mıydı (arka planda iOS'un kapatması olağandır).
        public var background: Bool

        public init(startedAt: Date, lastLine: String? = nil, background: Bool = false) {
            self.startedAt = startedAt
            self.lastLine = lastLine
            self.background = background
        }
    }

    public static let markKey = "sessionHealthMark"

    public static func loadMark(_ defaults: UserDefaults) -> Mark? {
        defaults.data(forKey: markKey).flatMap { try? JSONDecoder().decode(Mark.self, from: $0) }
    }

    public static func saveMark(_ mark: Mark?, _ defaults: UserDefaults) {
        if let mark, let data = try? JSONEncoder().encode(mark) { defaults.set(data, forKey: markKey) }
        else { defaults.removeObject(forKey: markKey) }
    }

    /// Önceki açılışta durdurulmadan biten oturumun rapor satırı; iz yoksa nil. Süre ve bellek son sağlık satırından
    /// gelir; hiç satır yazılmadıysa oturum ilk 10 dakikada bitmiştir.
    public static func unexpectedEnd(_ mark: Mark?) -> String? {
        guard let mark else { return nil }
        let place = mark.background ? "arka planda" : "ön planda"
        return "Önceki çeviri oturumu durdurulmadan bitti (\(place)); son durum: \(mark.lastLine ?? "ilk 10 dk içinde")"
    }

    /// Bu sürecin bellek ayak izi (Xcode'un ve jetsam'ın ölçtüğü phys_footprint), MB.
    public static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : 0
    }

    /// Sistem kapatmadan önce uygulamanın daha ne kadar bellek alabileceği (yalnız iOS), MB.
    public static func availableMB() -> Int? {
        #if os(iOS)
        return Int(os_proc_available_memory() / 1_048_576)
        #else
        return nil
        #endif
    }
}
