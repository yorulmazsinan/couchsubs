// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation

/// Bilgisayar ekranındaki altyazı penceresinin durumu. Pencere TV'ye giden olayların aynısını alır (bkz.
/// `SubtitleServer.onEvent`) ve TV uygulamasıyla aynı yığını (`SubtitleStack`) kullanır; TV kurulu olmasa da çalışır.
/// Pencerenin kendisi `SubtitleOverlayController`'dadır.
extension AppModel {
    /// Pencere görünmeli mi: altyazı bilgisayar ekranında gösteriliyor ve ekranda bir satır var (ya da yeri ayarlanıyor).
    var overlayVisible: Bool {
        settings.output.showsOnComputer && (overlayAdjusting || !overlayLines.isEmpty)
    }

    /// Pencere tıklamaları geçiriyor mu (ayarlanırken hiçbir zaman).
    var overlayIgnoresMouse: Bool { settings.overlayClickThrough && !overlayAdjusting }

    func overlayReceive(_ event: SubtitleEvent) {
        guard settings.output.showsOnComputer else { return }
        let now = overlayClock()
        switch event {
        case .subtitle(let text, let durationMs, let paragraphs, let replaces):
            overlayStack.show(text, durationMs: durationMs, paragraphs: paragraphs, replaces: replaces, now: now)
        case .clear:
            overlayStack.clear(now: now)
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
