// SPDX-License-Identifier: AGPL-3.0-only
// "Geçmiş" ekranı ve Ayarlar'daki altyazı bölgesi karosu.

import CouchSubsCore
import SwiftUI
import UIKit

/// Bu ve önceki oturumlarda çevrilen son satırlar (en yenisi üstte); satırlar ve liste kopyalanabilir.
struct HistoryScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmClear = false
    @State private var copiedAll = false

    var body: some View {
        MobileScreen {
            BackHeader(title: "History")
        } content: {
            Text(String(format: String(localized: "The last %lld translated lines are kept on this phone."), SubtitleHistory.defaultLimit))
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            if model.history.entries.isEmpty {
                Text("No subtitles yet. Lines translated in this and earlier sessions appear here.")
                    .font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Tile(spacing: 0) {
                    ForEach(Array(model.history.entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { RowDivider() }
                        HistoryRow(entry: entry)
                    }
                }
            }
        } bottom: {
            if !model.history.entries.isEmpty {
                HStack(spacing: Mobile.Space.gap) {
                    Button {
                        UIPasteboard.general.string = SubtitleHistory.plainText(model.history.entries)
                        copiedAll = true
                    } label: {
                        Label(copiedAll ? "Copied" : "Copy all", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.mobileSecondary)
                    Button(role: .destructive) { confirmClear = true } label: { Label("Clear", systemImage: "trash") }
                        .buttonStyle(.mobileDestructive)
                }
            }
        }
        .confirmationDialog("Clear the history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { model.clearHistory() }
        } message: {
            Text("All saved lines are removed from this phone.")
        }
    }
}

/// Bir satır: saat ve kaynak, Türkçe, altında İngilizcesi. Basılı tutunca kopyalanır.
private struct HistoryRow: View {
    let entry: SubtitleHistory.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.hair) {
            Text(verbatim: "\(entry.date.formatted(date: .omitted, time: .standard)) · \(origin)")
                .font(Mobile.TypeScale.caption.monospacedDigit())
                .foregroundStyle(entry.origin == .pack ? Mobile.Palette.pro : Mobile.Palette.tertiary)
            Text(verbatim: entry.translation)
                .font(Mobile.TypeScale.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: entry.source)
                .font(Mobile.TypeScale.caption)
                .foregroundStyle(Mobile.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Mobile.Space.gap)
        .contentShape(Rectangle())
        .contextMenu {
            Button { UIPasteboard.general.string = "\(entry.translation)\n\(entry.source)" } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    private var origin: String {
        entry.origin == .pack ? String(localized: "Pack") : String(localized: "Translation engine")
    }
}

/// Ayarlar › Altyazı alanı: hazır seçimler, son kareyle canlı önizleme (çerçeve sürüklenir), Özel'de kaydırıcılar.
struct AreaTile: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Tile {
            Text("Subtitle area").font(Mobile.TypeScale.headline)
            SegmentedTabs(options: [AreaPreset.bottom: "Bottom area", .top: "Top area", .full: "Full screen", .custom: "Custom"],
                          selection: Binding(get: { model.settings.areaPreset }, set: { model.settings.selectAreaPreset($0) }))
            PhoneRegionPreview(settings: $model.settings, preview: model.framePreview)
            if model.settings.areaPreset == .custom {
                let percent = model.settings.region.verticalPercent
                sliderRow("Vertical position", value: percent.position, range: 0...max(1, 100 - percent.height)) {
                    model.settings.setCustomRegion(model.settings.region.withVertical(position: $0, height: percent.height))
                }
                sliderRow("Height", value: percent.height, range: CropRegion.minimumSize * 100...100) {
                    model.settings.setCustomRegion(model.settings.region.withVertical(position: percent.position, height: $0))
                }
            }
            Text("Drag the frame to move it, or drag its corner to resize it.")
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        }
    }

    private func sliderRow(_ title: LocalizedStringKey, value: Double, range: ClosedRange<Double>,
                           set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: Mobile.Space.hair) {
            HStack {
                Text(title).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Spacer()
                Text(verbatim: percentText(value)).font(Mobile.TypeScale.caption.monospacedDigit()).foregroundStyle(Mobile.Palette.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: range).tint(Mobile.Palette.accent)
        }
    }
}

/// Önizleme son kareyi izler; kare değişince yalnız bu görünüm yeniden çizilir.
private struct PhoneRegionPreview: View {
    @Binding var settings: UserSettings
    @ObservedObject var preview: PhoneFramePreview

    var body: some View {
        RegionPreview(region: settings.region, frame: preview.image) { settings.setCustomRegion($0) }
    }
}
