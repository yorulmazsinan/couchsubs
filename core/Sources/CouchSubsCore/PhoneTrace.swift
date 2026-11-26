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

    /// Sıkı aramanın ıska ölçütü (`GamePhoneGeometry.Step`) günlükte (Windows ve Android ile aynı metinler).
    static func reason(_ step: GamePhoneGeometry.Step) -> String {
        switch step {
        case .noPicture: return "16:9 görüntü yok"
        case .noTopSlot: return "hoparlör yarığı yok"
        case .topCrowded: return "üst şeritte çok aday"
        case .noCamera: return "ön kamera yok"
        case .noBottomSlot: return "alt çentik yok"
        case .bottomCrowded: return "alt şeritte çok aday"
        case .shape: return "boy/oran tutmadı"
        case .rim: return "kasa kenarı düz değil"
        case .sides: return "yan kenarlar zayıf"
        case .implausible: return "kutu akla yatkın değil"
        case .found: return "bulundu"
        }
    }

    /// Telefon açık değilken ilk açılış ıskalandı (#1251): `samples` aramada en ileri geçilen ölçüt, en sık ıska, en iyi
    /// adayın zayıf yanı (yan eşiğine oranla; aday yoksa yazılmaz) ve tek görülüp doğrulanmayan gözlemler.
    public static func missedFirst(samples: Int, furthest: String, common: String, commonCount: Int, side: Int,
                                   unconfirmed: Int, strict: Int) -> String {
        let candidate = side >= 0 ? ", en iyi aday yan gücü \(side)/\(GamePhoneGeometry.sideThreshold)" : ""
        return "telefon ilk aramada bulunamadı (\(samples) arama): en ileri ölçüt \(furthest), en sık \(common) (\(commonCount))"
            + "\(candidate), doğrulanmayan gözlem \(unconfirmed) (\(strict) sıkı)"
    }

    /// Oranın yüzdesi (tam sayı).
    public static func percent(_ share: Double) -> Int { Int((share * 100).rounded(.toNearestOrAwayFromZero)) }

    /// İki bölgenin en çok oynayan kenarı (kareye oranla).
    public static func shift(_ a: CropRegion, _ b: CropRegion) -> Double {
        max(abs(a.top - b.top), abs(a.bottom - b.bottom), abs(a.left - b.left), abs(a.right - b.right))
    }
}

/// İlk açılışın ıskalanma nedenleri (#1251; `GamePhoneTracker`). Telefon açık değilken her aramanın ıska ölçütü `windowMs`
/// boyunca toplanır; pencerede telefona benzer bir şey varsa (kameralı hoparlör yarığı bulundu ya da daha ileri, şerit
/// kalabalık, tek görülüp doğrulanmayan gözlem) pencere sonunda tek satır yazılır (`PhoneTrace.missedFirst`). Telefonsuz
/// oyunda aramaların hemen hepsi "hoparlör yarığı yok"ta kalır, satır yazılmaz. Windows (PhoneMissLog, PhoneTrace.cs) ve
/// Android (PhoneTrace.kt) ile aynı.
final class PhoneMissLog {
    /// Özet penceresi (ms): en çok bu aralıkla bir satır.
    static let windowMs = 20_000
    private var windowStart: Int?
    private var samples = 0, unconfirmed = 0, unconfirmedStrict = 0, side = -1
    private var furthest = GamePhoneGeometry.Step.noPicture
    private var counts: [GamePhoneGeometry.Step: Int] = [:]

    /// Doğrulanmayı bekleyen gözlem süresi dolup ya da başka yerde gözlem gelip bırakıldı.
    func unconfirmed(strict: Bool) {
        unconfirmed += 1
        if strict { unconfirmedStrict += 1 }
    }

    func note(_ probe: GamePhoneGeometry.Probe, now: Int, log: (String) -> Void) {
        let start: Int
        if let windowStart, now >= windowStart { start = windowStart } else {
            windowStart = now
            start = now
        }
        samples += 1
        counts[probe.step, default: 0] += 1
        furthest = max(furthest, probe.step)
        side = max(side, probe.side)
        guard now - start >= Self.windowMs else { return }
        if suspicious, let common = counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first {
            log(PhoneTrace.missedFirst(samples: samples, furthest: PhoneTrace.reason(furthest), common: PhoneTrace.reason(common.key),
                                       commonCount: common.value, side: side, unconfirmed: unconfirmed, strict: unconfirmedStrict))
        }
        begin(now)
    }

    /// Pencerede telefona benzer bir şey görüldü mü.
    private var suspicious: Bool {
        furthest >= .noBottomSlot || unconfirmed > 0 || counts[.topCrowded] != nil || counts[.bottomCrowded] != nil
    }

    /// Telefon açıldı ya da izleyici sıfırlandı: pencere baştan.
    func reset() { begin(nil) }

    private func begin(_ now: Int?) {
        windowStart = now
        samples = 0
        unconfirmed = 0
        unconfirmedStrict = 0
        side = -1
        furthest = .noPicture
        counts = [:]
    }
}
