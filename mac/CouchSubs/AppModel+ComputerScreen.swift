// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// Bilgisayar ekranındaki pencerede bir ek alanın (görev, telefon, bildirim) çevirisi.
struct OverlayRegion: Equatable, Identifiable {
    let id: String
    let text: String
    /// Yazının oyun karesindeki yeri; pencerede kutu bu yana yaslanır.
    let box: TextBox?
    /// Kendiliğinden bulunan ekran yazısının blokları, özgün yazının yeri ve stiliyle (`TextLook`); diğerlerinde nil.
    var items: [ScreenTranslation.Item]? = nil

    /// Ekranın solundaki alan sola, sağındaki sağa, ortadaki ortaya.
    var side: HorizontalPlacement {
        guard let box else { return .center }
        let middle = (box.left + box.right) / 2
        return middle < 0.4 ? .leading : middle > 0.6 ? .trailing : .center
    }

    enum HorizontalPlacement { case leading, center, trailing }
}

/// Bilgisayar ekranındaki altyazı penceresinin durumu. Pencere TV'ye giden olayların aynısını alır (bkz.
/// `SubtitleServer.onEvent`) ve TV uygulamasıyla aynı yığını (`SubtitleStack`) kullanır; TV kurulu olmasa da çalışır.
/// Pencerenin kendisi `SubtitleOverlayController`'dadır.
extension AppModel {
    /// Pencere görünmeli mi: altyazı bilgisayar ekranında gösteriliyor ve ekranda bir satır var (ya da yeri ayarlanıyor).
    var overlayVisible: Bool {
        settings.output.showsOnComputer && (overlayAdjusting || !overlayLines.isEmpty || overlayRegions.contains { $0.items == nil }
                                             || !overlayPhoneItems.isEmpty)
    }

    /// Pencere tıklamaları geçiriyor mu (ayarlanırken hiçbir zaman).
    var overlayIgnoresMouse: Bool { settings.overlayClickThrough && !overlayAdjusting }

    func overlayReceive(_ event: SubtitleEvent) {
        guard settings.output.showsOnComputer || streamWindowOpen else { return }
        let now = overlayClock()
        switch event {
        case .subtitle(let text, let durationMs, let paragraphs, let replaces, let box):
            overlayScreenUntil = 0
            // "Örtsün": oyundaki altyazının yeri gelmezse son bilinen yer örtülür; yazı boyu seçilen boyda kalır, ancak
            // 3 satıra sığmazsa bir kademe küçülür (bkz. CoverFontScale; TV ve OBS sayfası da aynı; bu pencerede satır başına 66 karakter).
            let style = settings.style
            let covering = style.placement == .cover && style.backgroundShape != .band && !paragraphs
            overlayCover = (text: text, box: box ?? overlayCover?.box,
                            scale: covering ? overlayCoverFont.scale(for: text, fontSize: style.fontSize,
                                                                     maxChars: SubtitleWrap.desktopMaxChars) : 1)
            if let box, !paragraphs, box.bottom - box.top > 0, box.bottom - box.top <= 0.25 {
                overlayBoxHeights = Array((overlayBoxHeights + [box.bottom - box.top]).suffix(9))
            }
            overlayStack.stackPrevious = settings.style.stackPrevious
            overlayStack.show(text, durationMs: durationMs, paragraphs: paragraphs, replaces: replaces, now: now)
        // "Ekranı çevir": çeviriler satır satır gösterilir. Hemen ardından gelen "temizle" ("Ekran çevriliyor…" yazısı
        // için) onları kaldırmaz; yeniden basmak ya da yeni altyazı kaldırır.
        case .screen(let text, let durationMs, let items):
            overlayStack.show(text, durationMs: durationMs, paragraphs: true, now: now)
            overlayScreenUntil = now + Double(durationMs) / 1000
            // Stilli öğeler (özgün görünüşüyle) yayın penceresinde kendi yerlerinde çizilir; "Ekran yazılarını altyazıdan
            // ayır" kapalıysa eskisi gibi liste.
            let styled = settings.setTextApart && items.contains { $0.look != nil }
            overlayScreenText = styled ? text : ""
            if overlayScreenItems != (styled ? items : []) { overlayScreenItems = styled ? items : [] }
            overlayScreenExpiry?.cancel()
            overlayScreenExpiry = styled ? Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(durationMs))
                guard !Task.isCancelled else { return }
                self?.overlayScreenItems = []
            } : nil
        case .screenClear:
            if overlayScreenUntil > now { overlayStack.hide() }
            overlayScreenUntil = 0
            if !overlayScreenItems.isEmpty { overlayScreenItems = [] }
        case .clear:
            if overlayScreenUntil <= now { overlayStack.clear(now: now) }
        // Ek alanların çevirisi altyazının üstünde, alanın bulunduğu yana yaslı küçük kutularda durur.
        case .region(let id, let text, let box):
            var regions = overlayRegions.filter { $0.id != id }
            // Kenar bildirimi (`ScreenNotices`) bu pencerede altyazının yanında gösterilmez: kendi yerinde (yayın penceresi,
            // TV) çizilir ya da hiç (Windows'ta kendiliğinden bulunan alanlar gibi).
            if !text.isEmpty, !ScreenNotices.isNotice(id: id) { regions.append(OverlayRegion(id: id, text: text, box: box)) }
            overlayRegions = regions.sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
            return
        // Kendiliğinden bulunan ekran yazısı: bloklar özgün yazının stilinde çizilir (yayın penceresinde kendi yerinde).
        case .screenText(let id, let items):
            var regions = overlayRegions.filter { $0.id != id }
            let boxes = items.map(\.box)
            let box = boxes.dropFirst().reduce(boxes.first) { $0?.union($1) }
            regions.append(OverlayRegion(id: id, text: items.map(\.translation).joined(separator: "\n"), box: box, items: items))
            overlayRegions = regions.sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
            return
        case .gamePhone(let items):
            if overlayPhoneItems != items { overlayPhoneItems = items }
            return
        case .regionClear:
            if !overlayPhoneItems.isEmpty { overlayPhoneItems = [] }
            if !overlayRegions.isEmpty { overlayRegions = [] }
            return
        }
        overlayRefresh()
    }

    /// Görünen satırları günceller ve bir sonraki değişim anına (solma, kalkma) zamanlayıcı kurar.
    func overlayRefresh() {
        let now = overlayClock()
        let lines = overlayStack.lines(at: now)
        if lines != overlayLines { overlayLines = lines }
        overlayTimer?.cancel()
        overlayTimer = nil
        guard let next = overlayStack.nextChange(after: now) else { return }
        let wait = max(0.01, next - now)
        overlayTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.overlayRefresh()
        }
    }

    /// Penceredeki her şeyi hemen kaldırır (çeviri durdu ya da altyazı artık bilgisayarda gösterilmiyor).
    func overlayHide() {
        overlayStack.hide()
        if !overlayScreenItems.isEmpty { overlayScreenItems = [] }
        if !overlayPhoneItems.isEmpty { overlayPhoneItems = [] }
        overlayTimer?.cancel()
        overlayTimer = nil
        if !overlayLines.isEmpty { overlayLines = [] }
        if !overlayRegions.isEmpty { overlayRegions = [] }
        if !settings.output.showsOnComputer { overlayAdjusting = false }
    }

    /// Kısayol (varsayılan Num 7 / ⌃⇧7) ve menü çubuğundaki seçenek: tıklamaların geçmesini açar/kapatır.
    func toggleClickThrough() {
        settings.overlayClickThrough.toggle()
    }
}
