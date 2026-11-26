// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Kayıtlı PS5'i ağda tanıma kuralı (Windows `ConsoleIdentity`, Android `ConsoleIdentity` ile aynı).
///
/// PS5'in değişmeyen kimliği keşif yanıtındaki `host-id`'dir (PS5'in MAC adresi, 12 onaltılık hane; kayıtta PS5'in
/// bildirdiği MAC ile aynı). Eskiden PS5 yalnız adıyla eşleniyordu: ad değişince yeni adreste bulunamıyor, aynı adlı iki
/// PS5'te emin olunamıyordu. Kimliği bilinen kayıt kimlikle eşlenir; eski kayıtta (kimlik yok) ad kuralı geçerlidir ve
/// PS5 adıyla bir kez bulununca kimliği kayda yazılır.
public enum ConsoleIdentity {
    /// Kimliğin karşılaştırılan biçimi: yalnız onaltılık haneler, büyük harf ("1c:98:c1:aa:bb:cc" → "1C98C1AABBCC").
    /// Boş ya da tamamı sıfır kimlik nil.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = String(raw.uppercased().filter { $0.isHexDigit && $0.isASCII })
        return hex.isEmpty || hex.allSatisfy({ $0 == "0" }) ? nil : hex
    }

    /// Kayıt yanıtındaki MAC'ten (6 bayt) kimlik; boşsa nil.
    static func hostId(mac: [UInt8]) -> String? {
        normalized(mac.prefix(6).map { String(format: "%02X", $0) }.joined())
    }

    /// Aramaya yanıt veren PS5 kayıtlı PS5 mi: iki tarafta da kimlik varsa kimlik (ad bakılmaz), yoksa ad (boşluk ve harf
    /// büyüklüğü gözetilmez; kayıtta ad yoksa her yanıt kabul edilir).
    public static func isRegistered(_ info: ConsoleInfo, _ console: RegisteredConsole) -> Bool {
        if let wanted = console.hostId, let found = info.hostId { return wanted == found }
        return matchesName(info, console.name)
    }

    static func matchesName(_ info: ConsoleInfo, _ name: String) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return wanted.isEmpty
            || info.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// Ağda bulunanlar arasından kayıtlı PS5 (tek eşleşen); emin olunamazsa nil (başka PS5'e geçilmez, GitHub #425).
    public static func pickMoved(_ found: [ConsoleInfo], _ console: RegisteredConsole) -> ConsoleInfo? {
        let matches = found.filter { isRegistered($0, console) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Eşleşen yanıttan öğrenilenlerle kayıt: yeni adres, (eski kayıtta) kimlik ve kimlikle eşlendiyse PS5'in yeni adı.
    /// Değişen bir şey yoksa nil.
    public static func updated(_ console: RegisteredConsole, with info: ConsoleInfo) -> RegisteredConsole? {
        let byId = console.hostId != nil && console.hostId == info.hostId
        // Ad yalnız gerçekten değiştiyse yazılır (harf ya da boşluk farkı değişiklik sayılmaz).
        let renamed = byId && !info.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !matchesName(info, console.name)
        let name = renamed ? info.name.trimmingCharacters(in: .whitespacesAndNewlines) : console.name
        let hostId = console.hostId ?? info.hostId
        guard info.host != console.host || hostId != console.hostId || name != console.name else { return nil }
        return RegisteredConsole(host: info.host, name: name, registKey: console.registKey, morning: console.morning, hostId: hostId)
    }

    /// Kayıt güncellenince günlüğe giden satır (Windows ve Android'de aynı metin).
    public static func changeLine(from old: RegisteredConsole, to new: RegisteredConsole) -> String {
        var parts: [String] = []
        if old.host != new.host {
            parts.append("PS5 yeni adreste bulundu: \(old.host) → \(new.host) (\(old.hostId != nil ? "host-id ile" : "adıyla"))")
        }
        if old.hostId == nil, let id = new.hostId { parts.append("PS5 kimliği kayda yazıldı: \(id)") }
        if old.name != new.name { parts.append("PS5'in adı değişmiş: \(old.name) → \(new.name)") }
        return parts.joined(separator: "; ")
    }
}

/// Tüm ağı tarayarak PS5 araması ne zaman yapılır (Windows `RelocateSchedule`, Android `RelocateSchedule` ile aynı).
/// Tarama pahalı (~1000 adres, 3 sn); PS5 kapalıyken her denemede yapılmaz. Eskiden iki tarama arası hep 30 sn'ydi; artık
/// bağlantı kopunca ilk denemede hemen, sonra 10 sn, 30 sn, 1 dk, 2 dk, sonra 5 dk arayla taranır (#1366: PS5 bulunamadıkça
/// tarama seyrelir, ağ yarım dakikada bir taranmaz). PS5 bulununca sıra baştan başlar.
public struct RelocateSchedule: Sendable {
    public static let delays: [TimeInterval] = [0, 10, 30, 60, 120, 300]
    private var next = Date.distantPast
    private var misses = 0

    public init() {}

    public func isDue(_ now: Date = Date()) -> Bool { now >= next }

    /// Tarama bitti: PS5 bulunduysa sonraki tarama hemen yapılabilir, bulunamadıysa bekleme uzar.
    public mutating func searched(found: Bool, now: Date = Date()) {
        if found {
            misses = 0
            next = .distantPast
        } else {
            misses += 1
            next = now.addingTimeInterval(Self.delays[min(misses, Self.delays.count - 1)])
        }
    }

    /// Bağlantı başarısız oldu (akış koptu ya da PS5 bağlantıyı reddetti): sonraki denemede beklemeden taranır.
    public mutating func connectionFailed() {
        misses = 0
        next = .distantPast
    }
}

/// Kayıtlı PS5'i bulur: önce kayıtlı adreste, yanıt yoksa ya da yanıt veren başka bir PS5'se ağda (kimlikle). Oturum
/// dışında da kullanılır (çalışan oyun yoklaması); kayıt değişirse `onChange` çağrılır.
public final class ConsoleFinder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RegisteredConsole
    private var schedule = RelocateSchedule()
    private let discover: (String?) -> [ConsoleInfo]
    public var onChange: ((RegisteredConsole) -> Void)?

    /// `discover(nil)` tüm ağı, `discover(adres)` yalnız o adresi sorar (bloklar).
    public init(console: RegisteredConsole, discover: @escaping (String?) -> [ConsoleInfo] = ConsoleFinder.liveDiscover) {
        current = console
        self.discover = discover
    }

    public static func liveDiscover(_ host: String?) -> [ConsoleInfo] {
        Console.search(timeout: .seconds(host == nil ? 3 : 2), host: host)
    }

    public var console: RegisteredConsole {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Kayıt dışarıdan değişti (ör. adres elle girildi).
    public func replace(_ console: RegisteredConsole) {
        lock.lock(); current = console; lock.unlock()
    }

    public func connectionFailed() {
        lock.lock(); schedule.connectionFailed(); lock.unlock()
    }

    /// Kayıtlı adresi sorar. Yanıt veren kayıtlı PS5'se o (eski kayıtta kimliği öğrenilir). Değilse, `sweep` açıksa ve tarama
    /// zamanıysa ağ taranır. `atHost`: kayıtlı adreste yanıt veren (başka PS5 olabilir). Bloklar.
    ///
    /// `sweep: false`: ağ hiç taranmaz. Oturum bağlıyken çalışan oyun yoklaması bunu kullanır (#1366): PS5 zaten kayıtlı
    /// adreste akış veriyor; eskiden her yoklama yeni bir arayıcıyla geldiği için kayıtlı adres keşfe yanıt vermeyince
    /// bağlanır bağlanmaz ve sonra iki dakikada bir bütün ağ taranıyordu.
    public func locate(sweep: Bool = true) -> (info: ConsoleInfo?, atHost: ConsoleInfo?) {
        let saved = console
        let atHost = discover(saved.host).first
        if let atHost, ConsoleIdentity.isRegistered(atHost, saved) {
            learn(from: atHost)
            return (atHost, atHost)
        }
        if let atHost {
            RemotePlayLog.write("PS5: \(saved.host) adresinde başka PS5 yanıt verdi (\(atHost.name))"
                                + (sweep ? ", \(saved.name) ağda aranıyor" : ""))
        }
        return (sweep ? relocate() : nil, atHost)
    }

    /// Ağı tarar (zamanı geldiyse); kayıtlı PS5 bulunursa kayıt güncellenir.
    public func relocate() -> ConsoleInfo? {
        lock.lock()
        let due = schedule.isDue()
        lock.unlock()
        guard due else { return nil }
        let moved = ConsoleIdentity.pickMoved(discover(nil), console)
        lock.lock()
        schedule.searched(found: moved != nil)
        lock.unlock()
        if let moved { learn(from: moved) }
        return moved
    }

    private func learn(from info: ConsoleInfo) {
        lock.lock()
        let old = current
        let updated = ConsoleIdentity.updated(old, with: info)
        if let updated { current = updated }
        lock.unlock()
        guard let updated else { return }
        RemotePlayLog.write(ConsoleIdentity.changeLine(from: old, to: updated))
        onChange?(updated)
    }
}
