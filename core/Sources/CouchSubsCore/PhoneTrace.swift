// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// GTA 6 telefonunun otomatik okumasında önceden günlüğe hiçbir şey yazmayan yollar (#1251): telefon açıldı/kapandı, telefon
/// oynadığı için açılmadı, tur telefon karede yerinde olmadığı ya da bulunamadığı için atlandı, eğik ekranın düzeltilmiş
/// okuması boş geldi. Satırlar `DropLog` ile sınırlıdır (aynı satır 60 sn'de bir, dakikada en çok 20). Windows
/// (PhoneTrace.cs) ve Android (PhoneTrace.kt) aynı metinler.
public enum PhoneTrace {
    public static let component = "PhoneTrace"
    public static let opened = "telefon açıldı"
    public static let closed = "telefon kapandı"
    /// Telefon kapandı: kaç ms görülmedi, kaç örnekte bulunamadı (#1334: çevirinin kalkma gecikmesi günlükte görünsün).
    public static func closed(afterMs ms: Int, misses: Int) -> String { "\(closed) (\(ms) ms görülmedi, \(misses) ıska)" }
    public static let missing = "PhoneMissing: telefon bu karede bulunamadı, tur atlandı"
    public static let emptyFlat = "eğik ekran düzeltilmiş okuması boş"

    /// Telefon bulundu ama önceki örnekten çok oynadı; iki uyumlu gözlem olmadığı için açılmadı.
    public static func moving(_ share: Double) -> String { "telefon oynuyor, açılmadı (%\(percent(share)) oynama)" }

    /// Okunacak karede telefon izlenen yerden çok uzakta: tur atlandı.
    public static func displaced(_ share: Double) -> String { "telefon karede yerinde değil, tur atlandı (%\(percent(share)) oynama)" }

    /// Oranın yüzdesi (tam sayı).
    public static func percent(_ share: Double) -> Int { Int((share * 100).rounded(.toNearestOrAwayFromZero)) }

    /// İki bölgenin en çok oynayan kenarı (kareye oranla).
    public static func shift(_ a: CropRegion, _ b: CropRegion) -> Double {
        max(abs(a.top - b.top), abs(a.bottom - b.bottom), abs(a.left - b.left), abs(a.right - b.right))
    }
}
