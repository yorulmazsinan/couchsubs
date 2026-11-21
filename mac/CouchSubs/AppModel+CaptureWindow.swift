// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import Foundation
import RemotePlay

/// Seçilen pencereden okuma (Windows'taki `FrameSource.CaptureWindow`): görüntü PS5 bağlantısı ya da Remote Play yerine
/// kullanıcının Ayarlar › Görüntü kaynağı'nda seçtiği OBS projektöründen ya da oyun penceresinden okunur. Yakalama
/// `RemotePlayWindowStream`'dedir; kareler konsol akışıyla aynı okuma hattına gider.
extension AppModel {
    /// Xbox seçili ve görüntü seçilen OBS/oyun penceresinden okunuyor (#853; Windows'taki `XboxReadsWindow`): oyun Xbox
    /// uygulamasında, play.xbox.com'da ya da capture card ile OBS'te oynanır; CouchSubs Xbox'a bağlanmaz (Xbox aynı anda
    /// tek bağlantıya izin verir), Microsoft girişi ve Xbox seçimi gerekmez.
    var readsXboxWindow: Bool { isXbox && settings.xboxFrameSource == .captureWindow }

    /// Görüntü seçilen pencereden okunuyor (PS5'te ya da Xbox'ta).
    var readsCaptureWindow: Bool { isXbox ? readsXboxWindow : settings.frameSource == .captureWindow }

    /// PS5 dışındaki kaynaklarda görüntü hazır mı: Remote Play penceresi her zaman, seçilen pencere yalnız bir pencere
    /// seçildiyse (seçim yokken bütün masaüstü okunmaz), PS5 hesap ve eşleşme varsa.
    var pictureSourceReady: Bool {
        if isXbox { return readsXboxWindow ? settings.captureWindow?.isComplete == true : xboxSignedIn && xboxConsole != nil }
        switch settings.frameSource {
        case .remotePlayWindow: return true
        case .captureWindow: return settings.captureWindow?.isComplete == true
        case .ps5: return console != nil && accountId != nil
        }
    }

    /// Sihirbazdaki "Bu Mac'te OBS veya oyun penceresi mi kullanıyorsunuz?": PSN girişi, PS5 eşleştirmesi ve TV adımı
    /// atlanır, kurulum biter; pencere sonra Ayarlar › Görüntü kaynağı'nda seçilir. TV eşleşmemişse altyazı bilgisayar
    /// ekranında gösterilir.
    func useCaptureWindow() {
        settings.frameSource = .captureWindow
        if !hasTV { settings.output = .computer }
        step = .done
    }

    /// Sihirbazın Xbox girişi adımındaki "Bilgisayarda Xbox uygulaması/play.xbox.com ile mi oynuyorsunuz?" (#853; Windows
    /// `UseXboxWindow` ile aynı): Microsoft girişi, Xbox seçimi ve TV adımı atlanır, kurulum biter; pencere Ayarlar ›
    /// Görüntü kaynağı'nda seçilir. CouchSubs Xbox'a bağlanmaz. TV eşleşmemişse altyazı bilgisayar ekranında gösterilir.
    func useXboxWindow() {
        settings.xboxFrameSource = .captureWindow
        if !hasTV { settings.output = .computer }
        step = .done
    }

    /// Ana ekrandaki "Görüntü kaynağı" satırının değeri, konsol türüne göre (Xbox'ta da seçim var, #853).
    var pictureSourceName: String {
        isXbox ? Self.xboxPictureSourceTitle(settings.xboxFrameSource) : Self.pictureSourceTitle(settings.frameSource)
    }

    static func xboxPictureSourceTitle(_ source: XboxFrameSource) -> String {
        switch source {
        case .xbox: String(localized: "Xbox (this app connects)")
        case .captureWindow: String(localized: "OBS projector or game window")
        }
    }

    /// Ayarlardaki listeye girecek açık pencereler (kendi pencerelerimiz, başlıksızlar ve küçükler hariç).
    func availableCaptureWindows() async -> [WindowCaptureTarget] { await services.captureWindows() }

    /// Ekran kaydı izni verilmiş mi; verilmemişse macOS pencere başlıklarını ve görüntüsünü vermez.
    var screenRecordingAllowed: Bool { services.screenRecordingAllowed() }

    /// "Sistem Ayarları'nı aç": macOS izin sorusunu çıkarır ve Gizlilik ve Güvenlik › Ekran Kaydı sayfasını açar.
    func openScreenRecordingSettings() { services.openScreenRecordingSettings() }

    /// Ana ekrandaki "Görüntü kaynağı" satırının değeri (Ayarlar'daki seçeneklerle aynı ad).
    static func pictureSourceTitle(_ source: FrameSource) -> String {
        switch source {
        case .ps5: String(localized: "The PS5 (second account)")
        case .remotePlayWindow: String(localized: "Remote Play window on this Mac")
        case .captureWindow: String(localized: "OBS projector or game window")
        }
    }

    /// Görüntü seçilen pencereden okunurken durumun metni (Windows'taki `CaptureWindowStatusText`).
    static func captureWindowStatusText(_ state: SessionState, running: Bool, target: WindowCaptureTarget?) -> String {
        guard let target, target.isComplete else {
            return String(localized: "Choose an OBS or game window in Settings › Picture source.")
        }
        if case .streaming = state { return String(localized: "Reading the selected window") }
        guard running else { return String(format: String(localized: "Ready to read %@ when translation starts."), target.title) }
        if case .disconnected(.other(let detail)) = state, !detail.isEmpty { return detail }
        return String(format: String(localized: "Waiting for the selected window: %@"), target.title)
    }
}
