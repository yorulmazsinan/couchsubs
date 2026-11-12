// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI

/// "Altyazıyı göster: TV / Bilgisayar ekranı / İkisi de" ve bilgisayar ekranındaki pencerenin seçenekleri.
/// Ana ekranda ve ayarlarda aynı karo kullanılır (Windows'ta da aynı düzen).
struct SubtitleOutputCard: View {
    @EnvironmentObject private var model: AppModel
    /// Ayarlarda açıklamalar da gösterilir; ana ekranda karo kısa kalır.
    var detailed = false

    var body: some View {
        Card {
            Text("Show subtitles on").font(.csCaption).foregroundStyle(Color.csSecondary)
            Picker("Show subtitles on", selection: $model.settings.output) {
                Text(verbatim: "TV").tag(SubtitleOutput.tv)
                Text("Computer screen").tag(SubtitleOutput.computer)
                Text("Both").tag(SubtitleOutput.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            if model.settings.output.showsOnComputer {
                if detailed {
                    HintText(text: "Subtitles appear in a window on this computer, over the game or PS Remote Play.")
                }
                ComputerScreenOptions()
                if detailed || model.settings.overlayClickThrough {
                    HintText(text: "When on, clicks go through to the window below. Press ⌥⌘L or use the menu bar to turn it off.")
                }
            }
        }
    }
}

/// Bilgisayar ekranındaki altyazı penceresi: tıklamalar geçsin, pencereyi ayarla.
private struct ComputerScreenOptions: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.space("m")) {
                Toggle("Clicks pass through", isOn: $model.settings.overlayClickThrough)
                Spacer()
                adjust
            }
            VStack(alignment: .leading, spacing: Theme.space("s")) {
                Toggle("Clicks pass through", isOn: $model.settings.overlayClickThrough)
                adjust
            }
        }
    }

    private var adjust: some View {
        Button("Adjust the subtitle window") { model.overlayAdjusting = true }
            .buttonStyle(.secondary)
            .disabled(model.overlayAdjusting)
    }
}
