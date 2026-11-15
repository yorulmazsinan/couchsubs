// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// Bilgisayar ekranındaki pencerede bir ek alanın (görev, telefon, bildirim) çevirisi.
struct OverlayRegion: Equatable, Identifiable {
    let id: String
    let text: String
    /// Yazının oyun karesindeki yeri; pencerede kutu bu yana yaslanır.
    let box: TextBox?

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
        settings.output.showsOnComputer && (overlayAdjusting || !overlayLines.isEmpty || !overlayRegions.isEmpty)
    }

    /// Pencere tıklamaları geçiriyor mu (ayarlanırken hiçbir zaman).
    var overlayIgnoresMouse: Bool { settings.overlayClickThrough && !overlayAdjusting }

    func overlayReceive(_ event: SubtitleEvent) {
        guard settings.output.showsOnComputer || streamWindowOpen else { return }
        let now = overlayClock()
        switch event {
        case .subtitle(let text, let durationMs, let paragraphs, let replaces):
            overlayScreenUntil = 0
            overlayStack.stackPrevious = settings.style.stackPrevious
            overlayStack.show(text, durationMs: durationMs, paragraphs: paragraphs, replaces: replaces, now: now)
        // "Ekranı çevir": çeviriler satır satır gösterilir. Hemen ardından gelen "temizle" ("Ekran çevriliyor…" yazısı
        // için) onları kaldırmaz; yeniden basmak ya da yeni altyazı kaldırır.
        case .screen(let text, let durationMs):
            overlayStack.show(text, durationMs: durationMs, paragraphs: true, now: now)
            overlayScreenUntil = now + Double(durationMs) / 1000
        case .screenClear:
            if overlayScreenUntil > now { overlayStack.hide() }
            overlayScreenUntil = 0
        case .clear:
            if overlayScreenUntil <= now { overlayStack.clear(now: now) }
        // Ek alanların çevirisi altyazının üstünde, alanın bulunduğu yana yaslı küçük kutularda durur.
        case .region(let id, let text, let box):
            var regions = overlayRegions.filter { $0.id != id }
            if !text.isEmpty { regions.append(OverlayRegion(id: id, text: text, box: box)) }
            overlayRegions = regions.sorted { ($0.box?.top ?? 0) < ($1.box?.top ?? 0) }
            return
        case .regionClear:
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
        overlayTimer?.cancel()
        overlayTimer = nil
        if !overlayLines.isEmpty { overlayLines = [] }
        if !overlayRegions.isEmpty { overlayRegions = [] }
        if !settings.output.showsOnComputer { overlayAdjusting = false }
    }

    /// ⌥⌘L ve menü çubuğundaki seçenek: tıklamaların geçmesini açar/kapatır.
    func toggleClickThrough() {
        settings.overlayClickThrough.toggle()
    }

    /// Kısayol yalnız çeviri sürerken ve altyazı bilgisayar ekranındayken tutulur.
    func updateClickThroughHotkey() {
        let wanted = isRunning && settings.output.showsOnComputer
        if wanted, clickThroughHotkey == nil {
            clickThroughHotkey = GlobalHotkey(.clickThrough) { [weak self] in self?.toggleClickThrough() }
        }
        clickThroughHotkey?.enabled = wanted
    }
}
