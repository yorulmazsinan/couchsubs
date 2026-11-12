// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// TV uygulamasındaki altyazı yığınının (tv-webos/app.js: showSubtitle, onClear, showPrevious) aynısı; bilgisayar
/// ekranındaki altyazı penceresi bunu kullanır, böylece ekranda TV'dekiyle aynı satırlar aynı sürelerle görünür.
///
/// Hızlı konuşmada önceki satır yeni satırın üstünde küçük ve soluk kalır, sonra solarak kalkar; üç kişi art arda
/// konuşursa iki önceki satır da en üstte durur (en çok üç satır). Zaman dışarıdan verilir (saniye); testler saati
/// kendisi ilerletir. Windows'taki `SubtitleStack` ile aynı kurallar.
public struct SubtitleStack: Equatable, Sendable {
    /// Yeni satır öncekinden bu süre içinde gelirse önceki üstte kalır.
    public static let stackWithin: TimeInterval = 1.5
    /// Üstteki satırın tam görünür kaldığı süre; sonra solmaya başlar.
    public static let previousHold: TimeInterval = 1.5
    public static let previousFade: TimeInterval = 0.4
    /// Yeni satırla yer değiştirmedikçe hiçbir satır bundan kısa görünmez.
    public static let minVisible: TimeInterval = 1.2
    /// "Temizle" olayı satırı okuma süresinden erken kaldırmaz; bu sürenin üst sınırı.
    public static let holdMax: TimeInterval = 5

    /// Ekrandaki bir satır.
    public struct Line: Equatable, Identifiable, Sendable {
        public enum Role: Equatable, Sendable {
            /// Son gelen satır (en altta, tam boy).
            case current
            /// Bir önceki satır (üstünde, küçük ve soluk).
            case previous
            /// İki önceki satır (en üstte, daha soluk).
            case older
        }

        public let id: Int
        public let text: String
        public let role: Role
        /// Başlık ve maddeli yazılar (görev paneli gibi) satır satır, sola yaslı gösterilir.
        public let paragraphs: Bool
        /// Üstteki satır solarak kalkıyor.
        public let fading: Bool

        public init(id: Int, text: String, role: Role, paragraphs: Bool = false, fading: Bool = false) {
            self.id = id
            self.text = text
            self.role = role
            self.paragraphs = paragraphs
            self.fading = fading
        }
    }

    private struct Current: Equatable, Sendable {
        var id: Int
        var text: String
        var paragraphs: Bool
        var shownAt: TimeInterval
        var hideAt: TimeInterval
        var holdUntil: TimeInterval
    }

    private struct Slot: Equatable, Sendable {
        var id: Int
        var text: String
        var shownAt: TimeInterval

        var fadeAt: TimeInterval { shownAt + SubtitleStack.previousHold }
        var hideAt: TimeInterval { fadeAt + SubtitleStack.previousFade }
    }

    private var current: Current?
    private var previous: Slot?
    private var older: Slot?
    private var lastId = 0

    public init() {}

    /// Ekranda hiçbir satır yok.
    public func isEmpty(at now: TimeInterval) -> Bool { lines(at: now).isEmpty }

    /// Yeni altyazı. `durationMs`: bilgisayarın bildirdiği süre (0 ya da eksi ise yazının uzunluğundan hesaplanır).
    /// `replaces`: bilgisayar bu satırı öncekinin uzamış ya da düzelmiş okuması saydı; önceki üste çıkmaz, bunun
    /// yerine geçer (üstteki daha eski satırlar kalır).
    public mutating func show(_ text: String, durationMs: Int, paragraphs: Bool = false, replaces: Bool = false,
                              now: TimeInterval) {
        prune(now)
        // Önceki satır kısa göründüyse yeni satırın üstünde kalır. Aynı cümlenin başka bir okunuşu ikinci çeviri gibi
        // durmasın diye üste çıkmaz; görev paneli gibi çok satırlı yazılar da üst üste binmez.
        if replaces, current != nil, !paragraphs {
            // Üstteki satırlar olduğu gibi kalır.
        } else if let shown = current, now - shown.shownAt < Self.stackWithin, !paragraphs, !shown.paragraphs,
           !Self.sameLine(shown.text, text) {
            pushPrevious(shown.text, now: now)
        } else {
            previous = nil
            older = nil
        }
        let length = Double(text.utf16.count)
        let reading = 2 + length * 0.06
        let visible = durationMs > 0 ? max(Self.minVisible, Double(durationMs) / 1000) : min(8, reading)
        current = Current(id: nextId(), text: text, paragraphs: paragraphs, shownAt: now, hideAt: now + visible,
                          holdUntil: now + min(Self.holdMax, reading))
    }

    /// Bilgisayardan gelen "temizle": yazı okunacak kadar görünmediyse kalan süre dolunca kalkar.
    public mutating func clear(now: TimeInterval) {
        prune(now)
        guard let shown = current else { return }
        if shown.holdUntil <= now {
            hide()
        } else {
            current?.hideAt = shown.holdUntil
        }
    }

    /// Her şeyi hemen kaldırır (çeviri durdu).
    public mutating func hide() {
        current = nil
        previous = nil
        older = nil
    }

    /// `now` anında görünen satırlar, yukarıdan aşağıya.
    public func lines(at now: TimeInterval) -> [Line] {
        guard let shown = current, now < shown.hideAt else { return [] }
        var result: [Line] = []
        for (slot, role) in [(older, Line.Role.older), (previous, .previous)] {
            guard let slot, now < slot.hideAt else { continue }
            result.append(Line(id: slot.id, text: slot.text, role: role, paragraphs: false, fading: now >= slot.fadeAt))
        }
        result.append(Line(id: shown.id, text: shown.text, role: .current, paragraphs: shown.paragraphs, fading: false))
        return result
    }

    /// Görünümün değişeceği bir sonraki an (satır solmaya başlar ya da kalkar); değişecek bir şey yoksa nil.
    public func nextChange(after now: TimeInterval) -> TimeInterval? {
        guard let shown = current, now < shown.hideAt else { return nil }
        var times = [shown.hideAt]
        for slot in [older, previous].compactMap({ $0 }) { times += [slot.fadeAt, slot.hideAt] }
        return times.filter { $0 > now }.min()
    }

    /// Önceki satır üste çıkar. Orada hâlâ tam görünen bir satır varsa o da bir üst sıraya (iki önceki) kayar.
    private mutating func pushPrevious(_ text: String, now: TimeInterval) {
        if let shown = previous, now < shown.fadeAt, !Self.sameLine(shown.text, text) {
            older = Slot(id: nextId(), text: shown.text, shownAt: now)
        } else {
            older = nil
        }
        previous = Slot(id: nextId(), text: text, shownAt: now)
    }

    /// Süresi dolan satırları atar; son satır kalktıysa üsttekiler de kalkar (TV'deki hideSubtitle gibi).
    private mutating func prune(_ now: TimeInterval) {
        if let shown = current, now >= shown.hideAt { hide() }
        if let slot = previous, now >= slot.hideAt { previous = nil }
        if let slot = older, now >= slot.hideAt { older = nil }
    }

    private mutating func nextId() -> Int {
        lastId += 1
        return lastId
    }

    /// Büyük-küçük harf ve noktalama dışında aynı mı, ya da biri ötekinin başı/devamı mı ("Kapı" → "Kapı daha fazla…").
    public static func sameLine(_ a: String, _ b: String) -> Bool {
        let x = plain(a)
        let y = plain(b)
        if x.isEmpty || y.isEmpty { return x == y }
        return x == y || x.contains(y) || y.contains(x)
    }

    private static let punctuation = Set(" \t\n\r.,!?;:…\"'“”‘’«»()[]-–—")

    private static func plain(_ text: String) -> String {
        String(text.lowercased().filter { !punctuation.contains($0) && !$0.isWhitespace })
    }
}
