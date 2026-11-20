// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// "Paketleri şimdi güncelle"nin sonucu: hangi paket eklendi, hangisi güncellendi, kaç satır geldi. Güncellemeden önceki
/// kitaplık (uygulamayla gelen ve önceden inmiş paketler) ile yenilemede inen paketlerin yeni satır sayısı karşılaştırılır.
/// Android'deki packs/PackUpdateSummary.kt ile aynı kurallar.
public struct PackUpdateSummary: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public let id: String
        public let title: String
        /// Önceden bu telefonda yoktu (ne uygulamayla geldi ne indirilmişti).
        public let added: Bool
        /// Paketin şimdiki satır sayısı.
        public let lines: Int
        /// Önceki sürüme göre satır farkı (eklenen pakette bütün satırlar).
        public let lineDelta: Int

        public init(id: String, title: String, added: Bool, lines: Int, lineDelta: Int) {
            (self.id, self.title, self.added, self.lines, self.lineDelta) = (id, title, added, lines, lineDelta)
        }
    }

    /// Yenilemede inen bir paket (sunucudaki başlığı ve satır sayısı).
    public struct Downloaded: Equatable, Sendable {
        public let id: String
        public let title: String
        public let lines: Int

        public init(id: String, title: String, lines: Int) {
            (self.id, self.title, self.lines) = (id, title, lines)
        }
    }

    /// İnen paketler, inme sırasıyla.
    public let changes: [Change]

    public init(changes: [Change]) { self.changes = changes }

    /// `before`: güncellemeden önceki paketler (kimlik → satır sayısı; aynı kimlik birden çok kez varsa son gelen geçerli,
    /// kitaplıktaki gibi). `downloaded`: yenilemede inenler. Aynı kimlik bir kez sayılır.
    public init(before: [(id: String, lines: Int)], downloaded: [Downloaded]) {
        var previous: [String: Int] = [:]
        for pack in before { previous[pack.id] = pack.lines }
        var seen = Set<String>()
        changes = downloaded.compactMap { pack in
            guard seen.insert(pack.id).inserted else { return nil }
            let old = previous[pack.id]
            return Change(id: pack.id, title: pack.title, added: old == nil, lines: pack.lines,
                          lineDelta: pack.lines - (old ?? 0))
        }
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var updated: [Change] { changes.filter { !$0.added } }
    public var added: [Change] { changes.filter(\.added) }
    /// Gelen yeni satırların toplamı (eklenen paketlerin bütün satırları ve güncellenenlerdeki artış; azalan sayılmaz).
    public var newLines: Int { changes.reduce(0) { $0 + max(0, $1.lineDelta) } }
}
