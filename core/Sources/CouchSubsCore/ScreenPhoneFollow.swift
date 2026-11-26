// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// "Ekranı çevir"in telefon kartı sohbeti izler. Önceden kart tek bir karenin çevirisiydi: telefonda başka bir sohbete
/// geçince kart eski sohbette kalıyor, süresi dolunca kayboluyordu; yeni sohbet ancak tuşa yeniden basınca geliyordu.
/// Kart ekrandayken uygulama telefonu düzenli aralıkla (`interval`) yoklar: telefonun ekranı değişip bir yoklama boyunca
/// durulunca (sohbet değişti, yeni mesaj geldi, sohbet kaydı) ekran yeniden çevrilir; değişmeyen telefonda kart ekranda
/// kalır; telefon art arda `missTurns` yoklamada bulunamazsa (kapandı) kart kalkar. Yeniden çeviri `PhoneChatMemory`
/// ile hızlıdır: daha önce görülen sohbetin mesajları çevirmene gitmez (Windows: ScreenPhoneFollow.cs, Android:
/// ScreenPhoneFollow.kt; ortak deneme dosyası Fixtures/phone-chat.json `follow` bölümü).
///
/// Elde sallanan telefon (#1253, #1326): GTA 6'nın telefonu elde durur, her karede birkaç piksel kayar. Önceden kutunun
/// kenarı %2 oynayınca ya da iz örneklerinin %8'i değişince ekran "değişti" sayılıyor, yerindeki çeviriler ilk yoklamada
/// kalkıyordu (`hide`); yeniden çeviri için iki yoklamanın aynı çıkması gerekiyordu, sallanan telefon bunu nadiren
/// veriyordu: "Ekranı çevir"in çevirisi 1–2 sn'de kayboluyordu. Artık iz telefonun kendi koordinatında, hücre ortalamasıyla
/// alınır (`look`; birkaç piksellik kayma ortalamayı az oynatır), iki iz yatayda `maxShift` hücreye dek kaydırılarak
/// karşılaştırılır, kenar payı `moveTolerance`; çeviriler ancak art arda `hideTurns` yoklama değişirse kalkar.
public final class ScreenPhoneFollow: @unchecked Sendable {
    public enum Step: String, Equatable, Sendable {
        /// Bir şey yapma (telefon kıpırdıyor ya da ilk yoklama).
        case wait
        /// Telefonun ekranı değişti ve duruldu: ekranı yeniden çevir.
        case refresh
        /// Telefon aynı: kart ekranda kalsın (süresi uzatılır).
        case keep
        /// Telefon kapandı: kartı kaldır, izlemeyi bırak.
        case stop
        /// Telefonun ekranı art arda `hideTurns` yoklama değişti, henüz durulmadı: yerindeki mesaj çevirileri kalksın
        /// (artık başka balonların üstündeler); durulunca `refresh` gelir. Yalnız `hidesOnChange` açıkken.
        case hide
    }

    /// Çeviriler balonların üstünde, yerinde (kartsız): ekran durulmadan değişmeye devam ederse `hide`.
    public let hidesOnChange: Bool

    /// Yoklama aralığı (ms).
    public static let interval = 700
    /// Telefon bu kadar yoklama art arda bulunamazsa kapanmış sayılır.
    public static let missTurns = 3
    /// Telefon bu kadar yer değiştirirse (kenarlara oranla) kart yeniden dizilir. Önceden 0,02'ydi: elde sallanan
    /// telefonun bulunan kutusu bundan çok oynuyordu.
    static let moveTolerance = 0.04
    /// Yerindeki çeviriler ancak telefonun ekranı art arda bu kadar yoklama (baştaki hâlinden) değişirse kalkar; tek
    /// yoklamalık değişim (sallanma, geçiş karesi) kaldırmaz. Değişip duruldıysa zaten `refresh` gelir.
    static let hideTurns = 2

    private let lock = NSLock()
    private var baseline: (box: TextBox, signature: [UInt8])?
    private var pending: (box: TextBox, signature: [UInt8])?
    private var misses = 0
    /// Baştaki hâlinden art arda değişen yoklama sayısı.
    private var changes = 0
    /// Altyazı günlüğü: çevirinin neden gizlendiği, yeniden çevrildiği ya da kalktığı (sınırlı; testlerde yazılmaz).
    private let drops = DropLog()

    public init(hidesOnChange: Bool = false) {
        self.hidesOnChange = hidesOnChange
    }

    /// Ekran bu telefon görüntüsüyle çevrildi (kartın dayandığı hâl).
    public func settled(_ box: TextBox, signature: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        baseline = (box, signature)
        pending = nil
        misses = 0
        changes = 0
    }

    /// Bir yoklama: telefonun yeri ve ekranının izi (telefon yoksa nil).
    public func step(_ box: TextBox?, signature: [UInt8]?) -> Step {
        lock.lock(); defer { lock.unlock() }
        guard let box, let signature else {
            misses += 1
            pending = nil
            changes = 0
            if misses >= Self.missTurns { note("telefon \(misses) yoklamadır yok, çeviri kalktı") }
            return misses >= Self.missTurns ? .stop : .wait
        }
        misses = 0
        let current = (box: box, signature: signature)
        guard let base = baseline else {
            baseline = current
            return .keep
        }
        guard Self.differs(base, current) else {
            pending = nil
            changes = 0
            return .keep
        }
        changes += 1
        if let last = pending, !Self.differs(last, current) {
            pending = nil
            changes = 0
            note("telefon ekranı değişti ve duruldu, yeniden çevriliyor (\(Self.describe(base, current)))")
            return .refresh
        }
        pending = current
        guard hidesOnChange, changes == Self.hideTurns else { return .wait }
        note("telefon ekranı \(changes) yoklamadır değişiyor, yerindeki çeviriler gizlendi (\(Self.describe(base, current)))")
        return .hide
    }

    private func note(_ reason: String) { drops.note("ScreenPhoneFollow", reason, "") }

    private static func differs(_ a: (box: TextBox, signature: [UInt8]), _ b: (box: TextBox, signature: [UInt8])) -> Bool {
        shift(a.box, b.box) > moveTolerance || changedShare(a.signature, b.signature) > changeShare
    }

    /// İki kutunun en çok oynayan kenarı (kareye oranla).
    static func shift(_ a: TextBox, _ b: TextBox) -> Double {
        max(abs(a.left - b.left), abs(a.right - b.right), abs(a.top - b.top), abs(a.bottom - b.bottom))
    }

    /// Günlük için: izin değişen payı ve kutunun oynaması (yüzde).
    private static func describe(_ a: (box: TextBox, signature: [UInt8]), _ b: (box: TextBox, signature: [UInt8])) -> String {
        "%\(PhoneTrace.percent(changedShare(a.signature, b.signature))) değişim, %\(PhoneTrace.percent(shift(a.box, b.box))) oynama"
    }

    /// Telefonun ekranı bu paydan fazla değişirse (iz örneklerinin) değişmiş sayılır. Elde sallanan telefonun kıpırtısı
    /// (hücre ortalaması ve kaydırmalı karşılaştırmadan sonra) birkaç örnektir; sohbet değişince ya da yeni mesajla kayınca
    /// ekranın çoğu değişir. Önceden 0,08'di.
    static let changeShare = 0.12
    /// Bir iz örneği bundan fazla değişirse değişmiş sayılır (sıkıştırma kıpırtısı ve kelime kenarının hücre içinde
    /// kayması sayılmaz; balon zemini ile yazı arasındaki fark bundan çok büyüktür). Önceden 24'tü.
    static let sampleChange = 32
    /// İki iz yatayda en çok bu kadar hücre kaydırılarak karşılaştırılır (telefonun bulunan kutusu elde birkaç piksel
    /// kayar; bir hücre telefon eninin 1/64'ü). Dikeyde kaydırılmaz: yeni mesajla sohbetin kayması değişim sayılmalı.
    static let maxShift = 2
    /// İzin her hücresi, hücrenin bu kadar sütun × satır alt örneğinin ortalamasıdır (birkaç piksellik kayma hücrenin
    /// değerini az oynatır; önceden hücrenin tek ortadaki pikseliydi, yazı satırına denk gelip gelmemesi değişiyordu).
    static let subColumns = 4, subRows = 8

    /// İki izin değişen örneklerinin payı: yatayda `maxShift` hücreye dek kaydırmaların en küçüğü, örtüşen sütunlarda
    /// (boyları farklıysa tümü).
    static func changedShare(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let width = ReadScheduler.signatureWidth
        guard a.count % width == 0, width > 2 * maxShift else { return plainShare(a, b) }
        let rows = a.count / width
        var best = 1.0
        for dx in -maxShift...maxShift {
            var changed = 0, total = 0
            for y in 0..<rows {
                for x in max(0, -dx)..<min(width, width - dx) {
                    total += 1
                    if abs(Int(a[y * width + x]) - Int(b[y * width + x + dx])) > sampleChange { changed += 1 }
                }
            }
            if total > 0 { best = min(best, Double(changed) / Double(total)) }
        }
        return best
    }

    private static func plainShare(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let changed = zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > sampleChange ? 1 : 0) }
        return Double(changed) / Double(a.count)
    }

    /// Karedeki telefonun yeri ve ekranının izi; telefon yoksa nil. İz telefonun kutusundan (telefonun koordinatında)
    /// alınır, her hücresi alt örneklerin ortalamasıdır (`signature(of:)`).
    public static func look(_ frame: CGImage) -> (box: TextBox, signature: [UInt8])? {
        guard let phone = ScreenPhoneCard.phone(in: frame) else { return nil }
        let box = phone.bounds
        let region = CropRegion(top: box.top, bottom: box.bottom, left: box.left, right: box.right)
        return (box, signature(of: RegionCropper.crop(frame, to: region)))
    }

    /// Görüntünün `signatureWidth` × `signatureHeight` gri izi; her hücre `subColumns` × `subRows` alt örneğin
    /// ortalaması (Windows ve Android aynı hesap).
    static func signature(of image: CGImage) -> [UInt8] {
        let width = ReadScheduler.signatureWidth, height = ReadScheduler.signatureHeight
        let fine = (width: width * subColumns, height: height * subRows)
        var pixels = [UInt8](repeating: 0, count: fine.width * fine.height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: fine.width, height: fine.height, bitsPerComponent: 8,
                                          bytesPerRow: fine.width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: fine.width, height: fine.height))
        }
        return average(pixels, width: width, height: height)
    }

    /// İnce örnekleri (`signatureWidth`·`subColumns` × `signatureHeight`·`subRows`) hücre ortalamasına indirir.
    static func average(_ fine: [UInt8], width: Int, height: Int) -> [UInt8] {
        let stride = width * subColumns
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                for j in 0..<subRows {
                    let row = (y * subRows + j) * stride + x * subColumns
                    for i in 0..<subColumns { sum += Int(fine[row + i]) }
                }
                out[y * width + x] = UInt8(sum / (subColumns * subRows))
            }
        }
        return out
    }
}

/// Telefon sohbetlerinin çevirileri, sohbetin başlığıyla (kişi adı) birlikte saklanır: başka bir sohbete geçip geri
/// dönünce mesajlar yeniden çevrilmez, kart hemen dolar. Çevirmen ya da hedef dil değişince uygulama yenisini kurar.
public final class PhoneChatMemory: @unchecked Sendable {
    /// En çok bu kadar mesaj saklanır; dolunca en eskisi düşer.
    public static let capacity = 600

    private let lock = NSLock()
    private var saved: [String: String] = [:]
    private var order: [String] = []

    public init() {}

    private static func key(_ chat: String, _ source: String) -> String { chat + "\u{1F}" + source }

    public func translation(chat: String, of source: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return saved[Self.key(chat, source)]
    }

    public func remember(chat: String, source: String, translation: String) {
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let key = Self.key(chat, source)
        if saved[key] == nil {
            if order.count >= Self.capacity { saved[order.removeFirst()] = nil }
            order.append(key)
        }
        saved[key] = translation
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return saved.count
    }
}
