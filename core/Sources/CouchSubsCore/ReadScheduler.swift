// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Hangi karede yazı tanıma yapılacağını seçer. Oyun süresinin çoğunda bölge boştur ya da değişmez;
/// işlemcinin büyük kısmı bu karelerde boşa gider.
public struct ReadScheduler {
    public static let defaultMaxReuse = 20, fastMaxReuse = 2
    public enum Plan: Equatable {
        /// Bölge değişmedi, son okuma geçerli.
        case reuse(String)
        /// Yazı tanıma yapılır; `deep` ise boş bölgede kısa satırlar için büyütülmüş okuma da denenir.
        case read(deep: Bool)
    }

    /// Bölge izinin (`RegionCropper.signature`) boyutu: satır başına bu kadar gri örnek, bu kadar satır.
    public static let signatureWidth = 64, signatureHeight = 12
    /// Video gürültüsü bu farkı aşmaz; bir harf eklenmesi aşar.
    public static let defaultChangeThreshold = 16
    /// Değişimle başlayan okumadan sonra bölge hâlâ oturuyorsa (yazı belirmeyi sürdürüyor) bu kadarlık fark da okutur.
    public static let settleThreshold = 4
    /// Değişimden sonra küçük farkla yapılabilecek en çok okuma (gürültülü sahnede her kare okunmasın).
    public static let settleReads = 2

    private let changeThreshold: Int
    private let maxReuse: Int
    private let deepEvery: Int

    /// Son okunan karenin bölge izi. Karşılaştırma önceki kareyle değil bununla yapılır (GitHub #1019): altyazı birkaç
    /// karede belirip (ya da öncekinin yerine geçip) her kare bir öncekinden eşikten az farklıyken satır hiç okunmuyordu.
    /// Sabit arka planda Mac ve Windows pencere yakalaması değişmeyen ekranda kare göndermediğinden yeni satır, kamera
    /// oynatılıp kareler yeniden gelene dek çevrilmiyordu. Android aynı kuralı uygular (son okunan karenin izi).
    private var baseline: [UInt8]?
    private var lastText = ""
    private var reused = 0
    private var emptyReads = 0
    /// Değişimle başlayan okumadan sonra kalan küçük farklı okuma hakkı (`settleReads`).
    private var settling = 0

    public init(changeThreshold: Int = ReadScheduler.defaultChangeThreshold, maxReuse: Int = ReadScheduler.defaultMaxReuse, deepEvery: Int = 3) {
        self.changeThreshold = changeThreshold
        self.maxReuse = maxReuse
        self.deepEvery = deepEvery
    }

    /// Her kare okunur ve boş kareler hep derin okunur.
    public static var always: ReadScheduler { ReadScheduler(changeThreshold: -1, maxReuse: 0, deepEvery: 1) }

    public mutating func plan(signature: [UInt8]) -> Plan {
        if let baseline {
            let moved = changed(baseline, signature)
            // Değişimle başlayan okuma yazı belirirken yapıldıysa yazının son hâli de okunur.
            let settles = !moved && settling > 0
                && Self.changed(baseline, signature, threshold: min(changeThreshold, Self.settleThreshold))
            if reused < maxReuse, !moved, !settles {
                reused += 1
                return .reuse(lastText)
            }
            settling = moved ? Self.settleReads : settles ? settling - 1 : 0
        }
        reused = 0
        baseline = signature
        return .read(deep: emptyReads % deepEvery == 0)
    }

    public mutating func record(_ text: String) {
        lastText = text
        // Yazı yeni kalktıysa derin okuma sırası hemen gelmez.
        emptyReads = text.isEmpty ? emptyReads + 1 : 1
    }

    public mutating func reset() {
        baseline = nil
        settling = 0
        lastText = ""
        reused = 0
        emptyReads = 0
    }

    private func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        Self.changed(a, b, threshold: changeThreshold)
    }

    /// İki bölge izi farklı mı: bir örnek `threshold`'dan çok değiştiyse. `box` verilirse yalnız o kutunun (bölgenin
    /// kenarlarına oranla) örttüğü örneklere bakılır; bölgenin başka yerindeki kıpırtı sayılmaz (Windows: ReadScheduler.Changed).
    public static func changed(_ a: [UInt8], _ b: [UInt8], threshold: Int, within box: TextBox? = nil) -> Bool {
        guard a.count == b.count else { return true }
        let columns = signatureWidth
        let rows = a.count / columns
        guard let box, rows > 0, a.count % columns == 0 else {
            return zip(a, b).contains { abs(Int($0) - Int($1)) > threshold }
        }
        let left = min(max(Int((box.left * Double(columns)).rounded(.down)), 0), columns - 1)
        let right = min(max(Int((box.right * Double(columns)).rounded(.up)), left + 1), columns)
        let top = min(max(Int((box.top * Double(rows)).rounded(.down)), 0), rows - 1)
        let bottom = min(max(Int((box.bottom * Double(rows)).rounded(.up)), top + 1), rows)
        for y in top..<bottom {
            for x in left..<right where abs(Int(a[y * columns + x]) - Int(b[y * columns + x])) > threshold {
                return true
            }
        }
        return false
    }
}
