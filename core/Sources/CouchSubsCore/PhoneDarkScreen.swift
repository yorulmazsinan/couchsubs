// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Koyu ekranlı telefonun (koyu temalı uygulama, gece, kısılmış ekran) okunmadan önceki hazırlığı. Kullanıcı bildirimi (X,
/// beta.104): "telefonda parlaklık varsa çeviri oluyor karanlıksa olmuyor". Düzeltilmiş ekran olduğu gibi okunuyordu: koyu
/// zeminde açık ve soluk yazı (kısılmış ekranda yazı ile zemin arasında 40–60 ton) yazı tanımada sık kayboluyordu. Ekranın
/// ortanca tonu `darkLevel`'dan azsa ve açık yazı varsa (en açık %1'in tonu ortancadan en az `minSpread` fazla) ekran
/// gri tona çevrilir, zeminden yazıya gerilir ve ters çevrilir: yazı koyu, zemin açık (aydınlık ekranın okunduğu biçim).
/// Aydınlık ekran değişmez. Windows (PhoneDarkScreen.cs) ve Android (PhoneDarkScreen.kt) aynı kural; ortak deneme dosyası
/// Fixtures/phone-dark.json.
enum PhoneDarkScreen {
    /// Ortanca tonu bundan az ekran koyu sayılır (0–255).
    static let darkLevel = 96
    /// En açık %1'in tonu ortancadan en az bu kadar fazla olmalı (açık yazı var).
    static let minSpread = 40

    /// Koyu ekranın düz gri tonları (0–255) için hazır tonlar; ekran koyu değilse ya da açık yazı yoksa nil. Alt sınır en
    /// koyu %2'nin, üst sınır en açık %1'in tonu; ton `255 - (ton - alt) × 255 / (üst - alt)` (0–255'e kırpılır).
    static func prepared(_ tones: [UInt8]) -> [UInt8]? {
        guard let map = mapping(tones) else { return nil }
        return tones.map { map[Int($0)] }
    }

    /// Tonların dönüşüm tablosu (256 öğe); hazırlık gerekmiyorsa nil.
    static func mapping(_ tones: [UInt8]) -> [UInt8]? {
        guard !tones.isEmpty else { return nil }
        var counts = [Int](repeating: 0, count: 256)
        for tone in tones { counts[Int(tone)] += 1 }
        return mapping(counts: counts, total: tones.count)
    }

    static func mapping(counts: [Int], total: Int) -> [UInt8]? {
        func percentile(_ share: Int) -> Int {
            var sum = 0
            for (tone, count) in counts.enumerated() {
                sum += count
                if sum * 100 >= total * share { return tone }
            }
            return 255
        }
        let low = percentile(2), median = percentile(50), high = percentile(99)
        guard median < darkLevel, high - median >= minSpread, high > low else { return nil }
        return (0..<256).map { tone in UInt8(255 - min(255, max(0, tone - low) * 255 / (high - low))) }
    }
}
