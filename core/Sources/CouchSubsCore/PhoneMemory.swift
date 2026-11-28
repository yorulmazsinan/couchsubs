// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Telefonun açılışları arasında kalan hafıza: mesajların çevirisi ve panelin yazı boyu. Önceden ikisi de telefon
/// oturumunun içindeydi; telefon izleyicisi telefonu bir an kaybedince (sallanan el, kare geçişi) oturum kapanıyor, yeniden
/// açılışta aynı İngilizce mesajlar motora yeniden gidiyor (yapay zekâ her seferinde biraz başka Türkçe veriyordu) ve yazı
/// boyu baştan ölçülüyordu (X, 22 Kas: "her saniye şekli de hareketi de değişiyor"). Çeviri durunca (`RegionWatcher.reset`)
/// unutulur. Windows (PhoneMemory.cs) ve Android (PhoneMemory.kt) aynı kuralı, aynı sınırı kullanır.
@MainActor
final class PhoneMemory {
    /// En çok bu kadar mesajın çevirisi tutulur; dolunca en eskisi düşer.
    static let capacity = 256

    private var translations: [String: String] = [:]
    private var keys: [String] = []
    /// Yanda Panel'in kilitli telefon yeri ve yazı boyu (`PhonePanelSteady`).
    var steady = PhonePanelSteady()
    /// Telefon listesi kartlarının kesilmiş avatarları, rozetleri ve seçim çerçeveleri (`PhoneListLook`).
    let rows = PhoneListLook()

    init() {}

    /// Mesajın bilinen çevirisi: birebir aynı okunuşunki, yoksa aynı mesajın OCR'la biraz farklı okunuşununki
    /// (`PhoneSteady.translation`).
    func translation(of source: String) -> String? {
        PhoneSteady.translation(of: source, in: translations, order: keys)
    }

    /// Bilinen çevirisi olan okunuşlar (testler ve eşleme için).
    var known: [String: String] { translations }

    /// Aynı mesajın ilk çevirisini döndürür; OCR başka okusa da yeni çeviriyle üzerine yazılmaz (X, 28 Kas, beta.107:
    /// her okunuş ayrı çevrilip saklanıyor, Türkçe her turda değişiyordu; Windows ve Android ile aynı).
    @discardableResult
    func remember(_ source: String, _ translation: String) -> String {
        // Varyant yeni eşleşmelere dayanak olmaz: ardışık OCR hataları iki ayrı mesajı birbirine bağlamaz.
        if let canonical = PhoneSteady.translation(of: source, in: translations, order: keys) { return canonical }
        if keys.count >= Self.capacity { translations[keys.removeFirst()] = nil }
        keys.append(source)
        translations[source] = translation
        return translation
    }

    /// Çeviri durdu ya da hat yeniden kuruldu.
    func clear() {
        translations.removeAll()
        keys.removeAll()
        steady.forget()
        rows.clear()
    }
}
