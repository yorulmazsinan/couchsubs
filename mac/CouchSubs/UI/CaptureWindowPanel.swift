// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Ayarlar › Konsol ve Kaynak › "OBS projektörü veya oyun penceresi": seçili pencere ve "Oyun Penceresini Seç" (Windows'taki
/// `CaptureWindowPanel`). Seçim penceresi tuval 14'teki gibi ayrı açılır (GameWindowPicker).
struct CaptureWindowPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("s")) {
            DSRow(title: "SELECTED WINDOW", subtitle: nil, divider: false) {
                if let target = model.settings.captureWindow {
                    DSBadge(text: LocalizedStringKey(target.title.isEmpty ? target.processName : target.title), tone: .ok)
                } else {
                    DSBadge(text: "No window selected.", tone: .unknown)
                }
            }
            Text("Open an OBS projector or game window, then select it below. Only that window is read: CouchSubs never switches to the whole desktop when it closes.").dsMuted()
            if CaptureWindows.needsSourceProjectorHint(model.settings.captureWindow) {
                Text("If you use the CouchSubs OBS overlay, select the Source Projector of your capture card source as the video source: in OBS, right-click the source › Open Source Projector › New window. The Program and Preview projectors also contain CouchSubs' own subtitles.").dsMuted()
            }
            Button("Choose the Game Window") { picking = true }.buttonStyle(.dsSecondary)
        }
        .sheet(isPresented: $picking) { GameWindowPicker().environmentObject(model) }
    }
}

/// Oyun Penceresi Seçimi (tuval 14): solda açık pencereler kart kart (uygulama simgesi, başlık, uygulama), sağda seçilen
/// pencere ve son kare; "Bu Pencereyi Kullan" görüntüyü bu pencereden okutur, "Altyazı Alanını Ayarla" alan ayarına götürür.
/// Ekran kaydı izni yoksa macOS başlık vermez: izin açıklanır, Sistem Ayarları açılır.
struct GameWindowPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var open: [WindowCaptureTarget] = []
    @State private var allowed = true
    @State private var loaded = false
    @State private var selected: WindowCaptureTarget?

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard(spacing: DS.space("xs")) {
                DSCardHeader("OBS PROJECTOR OR GAME WINDOW") {
                    Button("Refresh Windows") { Task { await refresh() } }.buttonStyle(.dsSecondary)
                }
                ForEach(CaptureWindows.options(saved: model.settings.captureWindow, open: open)) { option in
                    Button { selected = option.target } label: {
                        HStack(spacing: DS.space("m")) {
                            AppIcon(processName: option.target.processName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: option.target.title.isEmpty ? option.target.processName : option.target.title)
                                    .font(.dsBodyStrong).lineLimit(1)
                                Text(verbatim: option.isOpen ? option.target.processName
                                     : option.target.processName + " · " + String(localized: "Not currently open"))
                                    .font(.dsSmall).foregroundStyle(Color.dsMuted).lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(DSOptionStyle(selected: selected == option.target, radio: false))
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
                if loaded && allowed && open.isEmpty {
                    Text("No suitable windows found. Open OBS or the game first, then refresh.").dsMuted()
                }
                HStack(spacing: 4) {
                    Text("If the window isn't listed, open OBS or the game first, then refresh. If screen recording permission is needed,").dsMuted()
                }
                if !allowed { Text(verbatim: RemotePlayWindowStream.permissionText).dsMuted() }
                Button("Open macOS Settings") { model.openScreenRecordingSettings() }
                    .buttonStyle(.plain)
                    .font(.dsSmall.weight(.semibold))
                    .underline()
            }
            .frame(width: 440)
            DSCard(scrolls: false) {
                DSCardHeader("SELECTED WINDOW") {
                    if let selected {
                        DSBadge(text: LocalizedStringKey(selected.title.isEmpty ? selected.processName : selected.title), tone: .ok)
                    }
                }
                DSScreenFrame(image: model.readsCaptureWindow && selected == model.settings.captureWindow
                              ? model.lastFrame.map { NSImage(cgImage: $0, size: .zero) } : nil) {
                    if selected == nil {
                        Text("No window selected.").font(.dsSmall).foregroundStyle(.white.opacity(0.8))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                HStack(spacing: DS.space("s")) {
                    Button("Use This Window") {
                        guard let selected else { return }
                        model.settings.captureWindow = selected
                        if model.isXbox { model.settings.xboxFrameSource = .captureWindow } else { model.settings.frameSource = .captureWindow }
                        dismiss()
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(selected == nil)
                    Button("Set the Subtitle Area") {
                        dismiss()
                        model.openSettings(.area)
                    }
                    .buttonStyle(.dsSecondary)
                    Spacer()
                    Button("Close") { dismiss() }.buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(DS.space("l"))
        .frame(width: 1100, height: 620)
        .background(Color.dsBackground)
        .newLook()
        .animation(DS.enter(400), value: open)
        .task {
            selected = model.settings.captureWindow
            await refresh()
        }
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

/// Pencerenin sahibi uygulamanın simgesi (çalışıyorsa); yoksa sade bir kutu.
private struct AppIcon: View {
    let processName: String

    var body: some View {
        Group {
            if let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == processName })?.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).padding(4)
            } else {
                Image(systemName: "macwindow").font(.system(size: 18)).foregroundStyle(Color.dsMuted)
            }
        }
        .frame(width: 56, height: 40)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("small")))
        .accessibilityHidden(true)
    }
}
