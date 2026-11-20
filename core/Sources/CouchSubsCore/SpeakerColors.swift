// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Konuşana göre renk: "Mattia: …" satırında ad ve satır o konuşanın sabit renginde görünür. Renk addan hesaplanır
/// (büyük/küçük harf fark etmez), aynı konuşan her cihazda ve her oturumda aynı renktir. Palet koyu altyazı zemininde
/// okunaklı on renktir; beyaz yoktur (adsız satırlar beyaz kalır). TV'ye `subtitle` olayının `speakers` alanıyla gider.
/// Windows (SpeakerColors.cs), Android (SpeakerColors.kt) ve TV uygulaması aynı paleti ve aynı hesabı kullanır.
public enum SpeakerColors {
    public static let palette = ["#FFD54F", "#4FC3F7", "#81C784", "#FF8A65", "#CE93D8",
                                 "#F06292", "#4DD0E1", "#AED581", "#FFB74D", "#90CAF9"]

    /// Konuşanın rengi ("#RRGGBB"): küçük harfli adın UTF-16 birimleri üzerinde FNV-1a (32 bit).
    public static func color(for name: String) -> String {
        palette[Int(hash(name.trimmingCharacters(in: .whitespaces).lowercased()) % UInt32(palette.count))]
    }

    /// FNV-1a (32 bit), UTF-16 birimleri üzerinde.
    static func hash(_ key: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for unit in key.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        return hash
    }

    /// "#RRGGBB" → 0–1 arası bileşenler; geçersizse nil.
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    public struct Speaker: Equatable, Sendable {
        public var name: String
        public var color: String
    }

    /// Satır başlarındaki konuşan adları (tekrarsız, ilk görünüş sırasıyla) ve renkleri. `book`: oturumun renk defteri
    /// (v2); verilmezse addan hesaplanan renk.
    public static func speakers(in text: String, book: SpeakerColorBook? = nil) -> [Speaker] {
        var seen = Set<String>()
        return text.components(separatedBy: "\n").compactMap { line in
            guard let name = speaker(line), seen.insert(name).inserted else { return nil }
            return Speaker(name: name, color: book?.color(name) ?? color(for: name))
        }
    }

    /// Çeviride ad gibi görünen Türkçe başlıklar ("Hedef: Arabaya bin."); konuşan sayılmaz, renklenmez (Android ile aynı).
    static let turkishHeadings: Set<String> = [
        "hedef", "görev", "not", "ipucu", "uyarı", "ödül", "ödüller", "konum", "bölüm", "güncelleme", "bilgi", "durum",
        "soru", "cevap",
    ]

    /// Satırın baştaki konuşan adı; Türkçe başlıksa nil.
    static func speaker(_ line: String) -> String? {
        guard let name = SpeakerPrefix.split(line)?.name,
              !turkishHeadings.contains(name.lowercased(with: Locale(identifier: "tr"))) else { return nil }
        return name
    }

    public struct Segment: Equatable, Sendable {
        public var text: String
        /// nil: adsız (varsayılan renkte) parça.
        public var color: String?
    }

    /// Metnin renkli parçaları. Konuşan adıyla başlayan satır, sonraki adlı satıra kadar (bölünmüş devam satırları
    /// dahil) o konuşanın renginde; ilk adlı satırdan öncekiler renksiz. Parçalar birleşince metnin kendisi çıkar.
    public static func segments(in text: String, book: SpeakerColorBook? = nil) -> [Segment] {
        var result: [Segment] = []
        var color: String?
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if let name = speaker(line) {
                color = book?.color(name) ?? self.color(for: name)
            } else if SpeakerPrefix.split(line) != nil {
                // Türkçe başlık ("Hedef: …") önceki konuşanın satırı değildir.
                color = nil
            }
            let piece = (index > 0 ? "\n" : "") + line
            if let last = result.last, last.color == color {
                result[result.count - 1].text += piece
            } else {
                result.append(Segment(text: piece, color: color))
            }
        }
        return result
    }
}
