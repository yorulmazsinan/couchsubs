// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Ayarlar › Görüntü kaynağı › "OBS projektörü veya oyun penceresi": okunacak pencerenin seçimi (Windows'taki
/// `CaptureWindowPanel`). Kayıtlı pencere açık değilse de listede kalır. Ekran kaydı izni yoksa macOS pencere
/// başlıklarını vermez; o zaman izin açıklanır ve Sistem Ayarları açılır.
struct CaptureWindowPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var open: [WindowCaptureTarget] = []
    @State private var allowed = true
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("m")) {
            HintText(text: "Open an OBS projector or game window, then select it below. Only that window is read: CouchSubs never switches to the whole desktop when it closes.")
            if !allowed {
                HStack {
                    Text(RemotePlayWindowStream.permissionText)
                    Spacer()
                    Button("Open System Settings") { model.openScreenRecordingSettings() }
                        .buttonStyle(.secondary)
                }
            }
            HStack {
                Picker("Selected window", selection: $model.settings.captureWindow) {
                    if model.settings.captureWindow == nil { Text("Select").tag(WindowCaptureTarget?.none) }
                    ForEach(CaptureWindows.options(saved: model.settings.captureWindow, open: open)) { option in
                        Text(verbatim: CaptureWindows.label(option, notOpen: String(localized: "Not currently open")))
                            .tag(WindowCaptureTarget?.some(option.target))
                    }
                }
                Button("Refresh windows") { Task { await refresh() } }
                    .buttonStyle(.secondary)
            }
            // OBS'in Program/Önizleme projektörü CouchSubs'ın OBS katmanını da içerir (bkz. `OwnSubtitles`).
            if CaptureWindows.needsSourceProjectorHint(model.settings.captureWindow) {
                HintText(text: "If you use the CouchSubs OBS overlay, select the Source Projector of your capture card source as the video source: in OBS, right-click the source › Open Source Projector › New window. The Program and Preview projectors also contain CouchSubs' own subtitles.")
            }
            if loaded && allowed && open.isEmpty {
                HintText(text: "No suitable windows found. Open OBS or the game first, then refresh.")
            }
        }
        .task { await refresh() }
        // Sistem Ayarları'ndan (ya da OBS'den) dönülünce liste ve izin durumu yenilenir.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        allowed = model.screenRecordingAllowed
        open = await model.availableCaptureWindows()
        loaded = true
    }
}
