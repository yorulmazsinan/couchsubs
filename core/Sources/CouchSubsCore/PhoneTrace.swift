// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
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
    /// adayın zayıf yanı (yan eşiğine oranla; aday yoksa yazılmaz), tek görülüp doğrulanmayan gözlemler ve üst şeridin
    /// ortalama parlaklığı (`level`, 0–255; -1: ölçülmedi). Karanlık sahnede (`GamePhoneGeometry.darkLevel`) en ileri
    /// ölçüte ulaşan aramanın kazancı da yazılır (`gain`, 256 = ×1,0).
    public static func missedFirst(samples: Int, furthest: String, common: String, commonCount: Int, side: Int,
                                   unconfirmed: Int, strict: Int, level: Int = -1, gain: Int = 256) -> String {
        let candidate = side >= 0 ? ", en iyi aday yan gücü \(side)/\(GamePhoneGeometry.sideThreshold)" : ""
        var light = ""
        if level >= 0 {
            light = ", parlaklık \(level)/255"
            if level < GamePhoneGeometry.darkLevel { light += " (karanlık, kazanç ×\(times(gain)))" }
        }
        return "telefon ilk aramada bulunamadı (\(samples) arama): en ileri ölçüt \(furthest), en sık \(common) (\(commonCount))"
            + "\(candidate), doğrulanmayan gözlem \(unconfirmed) (\(strict) sıkı)\(light)"
    }

    /// Kazanç (256 = 1) bir ondalıkla, virgülle ("2,5").
    static func times(_ gain: Int) -> String {
        let tenths = (gain * 10 + 128) / 256
        return "\(tenths / 10),\(tenths % 10)"
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
/// kalabalık, tek görülüp doğrulanmayan gözlem) pencere sonunda tek satır yazılır (`PhoneTrace.missedFirst`). Karanlık
/// sahnede (pencerenin ortalama parlaklığı `GamePhoneGeometry.darkLevel`'dan az) hoparlör yarığı bulunan pencere de yazılır:
/// karanlıkta telefon kameranın ya da alt çentiğin önünde kalıyordu ve satır hiç yazılmıyordu (X, beta.104: "karanlıksa
/// olmuyor"). Telefonsuz oyunda aramaların hemen hepsi "hoparlör yarığı yok"ta kalır, satır yazılmaz. Windows (PhoneMissLog,
/// PhoneTrace.cs) ve Android (PhoneTrace.kt) ile aynı.
final class PhoneMissLog {
    /// Özet penceresi (ms): en çok bu aralıkla bir satır.
    static let windowMs = 20_000
    private var windowStart: Int?
    private var samples = 0, unconfirmed = 0, unconfirmedStrict = 0, side = -1
    private var furthest = GamePhoneGeometry.Step.noPicture
    private var counts: [GamePhoneGeometry.Step: Int] = [:]
    /// Ölçülen parlaklıkların toplamı ve sayısı; en ileri ölçüte ulaşan aramanın kazancı.
    private var levelSum = 0, levels = 0, gain = 256

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
        if probe.step > furthest { gain = probe.gain }
        furthest = max(furthest, probe.step)
        side = max(side, probe.side)
        if probe.level >= 0 {
            levelSum += probe.level
            levels += 1
        }
        guard now - start >= Self.windowMs else { return }
        if suspicious, let common = counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first {
            log(PhoneTrace.missedFirst(samples: samples, furthest: PhoneTrace.reason(furthest), common: PhoneTrace.reason(common.key),
                                       commonCount: common.value, side: side, unconfirmed: unconfirmed, strict: unconfirmedStrict,
                                       level: level, gain: gain))
        }
        begin(now)
    }

    /// Pencerenin ortalama parlaklığı (0–255); ölçülmediyse -1.
    private var level: Int { levels > 0 ? levelSum / levels : -1 }

    /// Pencerede telefona benzer bir şey görüldü mü; karanlık sahnede hoparlör yarığı yeter.
    private var suspicious: Bool {
        furthest >= .noBottomSlot || unconfirmed > 0 || counts[.topCrowded] != nil || counts[.bottomCrowded] != nil
            || (level >= 0 && level < GamePhoneGeometry.darkLevel && furthest >= .noCamera)
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
        levelSum = 0
        levels = 0
        gain = 256
    }
}

/// Okunan telefon satırlarının günlük özeti (X, 26 Kas, beta.104: en üstteki uzun mesaj çevrilmiyor, cevap seçenekleri
/// karışık görünüyordu; hangi satırın okunup hangi rolle panele girdiği günlükte yoktu). Her grubun türü (header, bubble,
/// option, note, list, card) ve ilk sözcükleri (`PhoneChat.rowSummary`); özet değişince yazılır, en çok `intervalMs`'de bir,
/// aynı özet yinelenmez. Windows (PhoneRowsLog, PhoneTrace.cs) ve Android (PhoneRowsLog, PhoneTrace.kt) aynı.
final class PhoneRowsLog {
    static let intervalMs = 5_000
    /// Özetin en uzun hâli (karakter).
    static let maxLength = 400
    private var last: String?
    private var at: Int?

    /// Yazılacak satır; okuma boşsa, özet aynıysa ya da son satırdan bu yana `intervalMs` geçmediyse nil.
    func line(_ groups: [ScreenTranslation.Group], now: Int) -> String? {
        guard !groups.isEmpty else { return nil }
        let summary = PhoneChat.rowSummary(groups)
        guard summary != last else { return nil }
        if let at, now >= at, now - at < Self.intervalMs { return nil }
        last = summary
        at = now
        let shown = summary.count > Self.maxLength ? String(summary.prefix(Self.maxLength)) + "…" : summary
        return "telefon satırları: \(shown)"
    }
}

/// Telefon aramasının durumu, GTA 6 oynanırken `windowMs`'de bir tek satır (beta-105, X: "telefon komple çalışmıyor";
/// #1385'in beta-104 günlüğünde telefon hiç bulunamayınca tek satır yoktu: `PhoneMissLog` yalnız telefona benzer bir şey
/// görüldüğünde yazar). Satır telefonun açık mı kapalı mı olduğunu, pencerede kaç arama yapılıp kaçında bulunduğunu, en sık
/// ve en ileri ıska ölçütünü, üst şeridin ortalama parlaklığını, karenin ortanca parlaklığını, boyunu ve kare biçimini
/// (Mac/iPhone: renk uzayı; Android: çözücü biçimi ve ham Y aralığı) verir. Windows (PhoneSearchStatus, PhoneTrace.cs) ve
/// Android (PhoneSearchStatus, PhoneTrace.kt) aynı metin; ortak deneme Fixtures/phone-search-status.json.
final class PhoneSearchStatus {
    static let windowMs = 30_000
    static let columns = 64, rows = 36
    private var windowStart: Int?
    private var searches = 0, found = 0
    private var furthest: GamePhoneGeometry.Step?
    private var counts: [GamePhoneGeometry.Step: Int] = [:]
    private var levelSum = 0, levels = 0

    /// Bir arama: sıkı aramanın sonucu (`probe`; yoksa nil), telefon bu aramada bulundu mu (`seen`). Satır zamanı geldiyse true.
    func note(_ probe: GamePhoneGeometry.Probe?, seen: Bool, now: Int) -> Bool {
        let start: Int
        if let windowStart, now >= windowStart { start = windowStart } else {
            windowStart = now
            start = now
        }
        searches += 1
        if seen { found += 1 }
        if let probe {
            counts[probe.step, default: 0] += 1
            if furthest.map({ probe.step > $0 }) ?? true { furthest = probe.step }
            if probe.level >= 0 {
                levelSum += probe.level
                levels += 1
            }
        }
        return now - start >= Self.windowMs
    }

    /// Pencerenin satırı; pencere baştan başlar. `median`: karenin ortanca parlaklığı (0–255), `frame`: kare biçimi.
    func line(open: Bool, width: Int, height: Int, median: Int, frame: String?) -> String {
        let common = counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).first
        let level = levels > 0 ? levelSum / levels : -1
        var text = "telefon arama durumu (\(Self.windowMs / 1000) sn): telefon \(open ? "açık" : "kapalı"), "
            + "\(searches) arama, \(found) bulundu, "
            + (common.map { "en sık ölçüt \(PhoneTrace.reason($0.key)) (\($0.value))" } ?? "en sık ölçüt yok")
            + ", en ileri ölçüt " + (furthest.map { PhoneTrace.reason($0) } ?? "yok")
            + ", üst şerit parlaklığı " + (level >= 0 ? "\(level)/255" : "ölçülmedi")
        if level >= 0, level < GamePhoneGeometry.darkLevel { text += " (karanlık)" }
        text += ", ortanca parlaklık \(median)/255, kare \(width)x\(height)"
        if let frame, !frame.isEmpty { text += ", " + frame }
        reset()
        return text
    }

    func reset() {
        windowStart = nil
        searches = 0
        found = 0
        furthest = nil
        counts = [:]
        levelSum = 0
        levels = 0
    }

    /// Kare biçimi: Xbox oturumunda önce kaynak karenin düzeni (boyut, düzlem adımları, aralık; #1385), sonra CGImage'ın
    /// renk uzayı.
    static func frame(_ image: CGImage) -> String {
        let color = FrameColor.describe(image)
        return XboxFrameFormat.current.map { "\($0), \(color)" } ?? color
    }

    /// Tonların (0–255) ortancası; boşsa 0.
    static func median(_ tones: [Int]) -> Int {
        guard !tones.isEmpty else { return 0 }
        return tones.sorted()[(tones.count - 1) / 2]
    }

    /// Karenin ortanca parlaklığı (0–255): `columns`×`rows` noktaya küçültülmüş karede 77·R + 150·G + 29·B.
    static func median(_ image: CGImage) -> Int {
        guard let small = GamePhonePixels(image, width: columns, height: rows) else { return 0 }
        var tones = [Int]()
        tones.reserveCapacity(columns * rows)
        for p in stride(from: 0, to: small.bytes.count - 3, by: 4) {
            tones.append((77 * Int(small.bytes[p]) + 150 * Int(small.bytes[p + 1]) + 29 * Int(small.bytes[p + 2])) >> 8)
        }
        return median(tones)
    }
}
