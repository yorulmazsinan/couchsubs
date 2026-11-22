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
        /// Telefonun ekranı değişti (sohbet kaydı ya da değişti), henüz durulmadı: yerindeki mesaj çevirileri hemen
        /// kalksın (artık başka balonların üstündeler); durulunca `refresh` gelir. Yalnız `hidesOnChange` açıkken.
        case hide
    }

    /// Çeviriler balonların üstünde, yerinde (kartsız): ekran değişir değişmez `hide`.
    public let hidesOnChange: Bool

    /// Yoklama aralığı (ms).
    public static let interval = 700
    /// Telefon bu kadar yoklama art arda bulunamazsa kapanmış sayılır.
    public static let missTurns = 3
    /// Telefon bu kadar yer değiştirirse (kenarlara oranla) kart yeniden dizilir.
    static let moveTolerance = 0.02

    private let lock = NSLock()
    private var baseline: (box: TextBox, signature: [UInt8])?
    private var pending: (box: TextBox, signature: [UInt8])?
    private var misses = 0

    public init(hidesOnChange: Bool = false) {
        self.hidesOnChange = hidesOnChange
    }

    /// Ekran bu telefon görüntüsüyle çevrildi (kartın dayandığı hâl).
    public func settled(_ box: TextBox, signature: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        baseline = (box, signature)
        pending = nil
        misses = 0
    }

    /// Bir yoklama: telefonun yeri ve ekranının izi (telefon yoksa nil).
    public func step(_ box: TextBox?, signature: [UInt8]?) -> Step {
        lock.lock(); defer { lock.unlock() }
        guard let box, let signature else {
            misses += 1
            pending = nil
            return misses >= Self.missTurns ? .stop : .wait
        }
        misses = 0
        guard let base = baseline else {
            baseline = (box, signature)
            return .keep
        }
        guard Self.differs(base, (box, signature)) else {
            pending = nil
            return .keep
        }
        if let last = pending, !Self.differs(last, (box, signature)) {
            pending = nil
            return .refresh
        }
        let first = pending == nil
        pending = (box, signature)
        return hidesOnChange && first ? .hide : .wait
    }

    private static func differs(_ a: (box: TextBox, signature: [UInt8]), _ b: (box: TextBox, signature: [UInt8])) -> Bool {
        abs(a.box.left - b.box.left) > moveTolerance || abs(a.box.right - b.box.right) > moveTolerance
            || abs(a.box.top - b.box.top) > moveTolerance || abs(a.box.bottom - b.box.bottom) > moveTolerance
            || changedShare(a.signature, b.signature) > changeShare
    }

    /// Telefonun ekranı bu paydan fazla değişirse (iz örneklerinin) değişmiş sayılır. Elde sallanan telefonun kenar
    /// kıpırtısı birkaç örnektir; sohbet değişince ya da yeni mesajla kayınca ekranın çoğu değişir.
    static let changeShare = 0.08
    /// Bir iz örneği bundan fazla değişirse değişmiş sayılır (sıkıştırma kıpırtısı sayılmaz).
    static let sampleChange = 24

    /// İki izin değişen örneklerinin payı (boyları farklıysa tümü).
    static func changedShare(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        let changed = zip(a, b).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > sampleChange ? 1 : 0) }
        return Double(changed) / Double(a.count)
    }

    /// Karedeki telefonun yeri ve ekranının izi; telefon yoksa nil.
    public static func look(_ frame: CGImage) -> (box: TextBox, signature: [UInt8])? {
        guard let phone = ScreenPhoneCard.phone(in: frame) else { return nil }
        let box = phone.bounds
        let region = CropRegion(top: box.top, bottom: box.bottom, left: box.left, right: box.right)
        return (box, RegionCropper.signature(of: RegionCropper.crop(frame, to: region)))
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
