// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import RemotePlay
import SwiftUI

/// Ana ekran: solda başlat/durdur, durum karoları ve uyarılar; sağda paket notu ve canlı altyazı.
/// Sütunlar hiçbir genişlikte üst üste binmez: sol sütun en çok `mainColumn`, sağ sütun en az `liveColumnMin`
/// genişliğindedir; ikisi sığmazsa (pencere sistem tarafından daraltıldıysa) sütunlar alt alta dizilir.
struct MainView: View {
    @EnvironmentObject private var model: AppModel

    /// Sol sütunun en dar hâli (iki durum karosu yan yana okunur kalır).
    static let controlsColumnMin: CGFloat = 340
    /// Canlı altyazı sütununun en dar hâli.
    static let liveColumnMin: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            MainHeader()
            GeometryReader { geometry in
                let gap = Theme.space("gap")
                let available = geometry.size.width
                if available >= Self.controlsColumnMin + gap + Self.liveColumnMin {
                    HStack(alignment: .top, spacing: gap) {
                        ControlsColumn(width: min(Theme.size("mainColumn"), available - gap - Self.liveColumnMin))
                        VStack(alignment: .leading, spacing: gap) {
                            PackInUseTile()
                            LiveSubtitlesTile()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: gap) {
                            MainControls()
                            PackInUseTile()
                            LiveSubtitlesTile().frame(minHeight: Self.liveColumnMin)
                        }
                        // Kaydırma alanı içeriğe genişlik önermeyebilir; genişlik sabitlenmezse yazılar satıra inmez.
                        .frame(width: available)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .padding(Theme.space("screen"))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $model.showSettings) { SettingsView().appSurface() }
        .sheet(isPresented: $model.showHistory) { HistoryView().appSurface() }
    }
}

/// Logo, ad, geçmiş ve ayarlar düğmeleri.
private struct MainHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Theme.space("m")) {
            LogoView(size: 36)
            Text(verbatim: "CouchSubs").font(.csTitle)
            Spacer()
            Button { model.showHistory = true } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.secondary)
            .help(Text("History"))
            Button { model.showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.secondary)
            .help(Text("Settings"))
        }
    }
}

/// Sol sütun, kendi genişliğinde kayan. İçerik genişliği sabitlenir: dikey `ScrollView` içeriğine her düzen
/// geçişinde kendi genişliğini önermez; pencere içerik boyuna göre yeniden ölçülünce (Ayarlar sayfası açılıp
/// kapanınca) içerik "ideal" genişliğinde, yazılar tek satırda ölçülebiliyor. `MainControls`'ün ideal genişliği
/// sütundan geniştir (456–681 pt); sabitlenmezse karolar sütundan taşıp ortalanır: sol kenar boşluğu daralır,
/// sağda karolar sağ sütuna dayanır ve kenarları kesilir.
struct ControlsColumn: View {
    let width: CGFloat

    var body: some View {
        ScrollView {
            MainControls()
                .padding(.vertical, Theme.space("m"))
                .frame(width: width)
        }
        .scrollIndicators(.never)
        .padding(.vertical, -Theme.space("m"))
        .frame(width: width)
    }
}

/// Sol sütun: başlat/durdur, PS5 ve TV, altyazının yeri, çeviri motoru, kısayol, uyarılar.
struct MainControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            HStack(spacing: Theme.space("m")) {
                StartStopButton()
                TestSubtitleButton()
            }
            HStack(alignment: .top, spacing: Theme.space("gap")) {
                StatusTile(symbol: "gamecontroller", title: "PS5", value: model.ps5StatusText,
                           tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning))
                // Altyazı yalnız bilgisayar ekranındaysa TV durumu gösterilmez.
                if model.settings.output.showsOnTV { TVStatusTile() }
            }
            .fixedSize(horizontal: false, vertical: true)
            SubtitleOutputCard()
            HStack(alignment: .top, spacing: Theme.space("gap")) {
                StatusTile(symbol: "globe", title: "Translation", value: engineName)
                StatusTile(symbol: "keyboard", title: "Shortcut", value: String(localized: "Translate the screen (⌥⌘T)"))
            }
            .fixedSize(horizontal: false, vertical: true)
            MainWarnings()
        }
    }

    private var engineName: String {
        let engine = model.settings.translationEngine
        return engine == .free ? String(localized: "Free") : engine.displayName
    }
}

private struct StartStopButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            Task { model.isRunning ? model.stop() : await model.start() }
        } label: {
            Label(model.isRunning ? "Stop translating" : "Start translating",
                  systemImage: model.isRunning ? "stop.fill" : "play.fill")
                .font(.csHeadline)
        }
        .buttonStyle(CSButtonStyle(kind: model.isRunning ? .danger : .primary, fullWidth: true, height: "primaryActionHeight"))
        .disabled(model.isStarting || (!model.isRunning && !model.canStart))
    }
}

/// Başlat düğmesinin yanında: deneme altyazısını TV'ye (ya da bilgisayar ekranına) gönderir.
private struct TestSubtitleButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let onTV = model.settings.output.showsOnTV
        Button {
            Task { await model.testSubtitle() }
        } label: {
            Label(onTV ? "Test on TV" : "Test on screen", systemImage: onTV ? "tv" : "macwindow")
        }
        .buttonStyle(CSButtonStyle(kind: .secondary, height: "primaryActionHeight"))
        .fixedSize()
        .disabled(onTV && !model.hasTV && !model.settings.output.showsOnComputer)
        .help(Text(onTV ? "Sends a sample subtitle to the TV." : "Shows a sample subtitle on this computer's screen."))
    }
}

private struct TVStatusTile: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.hasTV {
            StatusTile(symbol: "tv", title: "TV",
                       value: model.tvClients > 0 ? String(localized: "Connected") : String(localized: "Waiting for the TV app"),
                       tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning))
        } else {
            StatusTile(symbol: "tv", title: "TV", value: String(localized: "Not set up")) {
                Button("Connect a TV") { model.step = .tv }.buttonStyle(.secondary)
            }
        }
    }
}

/// Dil paketi eksik, çevrimiçi motor çeviremiyor, macOS yazıyı okuyamıyor.
private struct MainWarnings: View {
    @EnvironmentObject private var model: AppModel

    private var sourceName: String { Locale.current.localizedString(forLanguageCode: model.settings.sourceLanguage) ?? model.settings.sourceLanguage }
    private var targetName: String { Locale.current.localizedString(forLanguageCode: model.settings.targetLanguage) ?? model.settings.targetLanguage }

    var body: some View {
        if model.translatorStatus != .ready {
            Card {
                if model.translatorStatus == .needsDownload {
                    Label(String(format: String(localized: "The %@–%@ language pack is not downloaded yet."), sourceName, targetName),
                          systemImage: "arrow.down.circle")
                        .font(.csBody.weight(.semibold))
                        .foregroundStyle(Color.csWarning)
                    HintText(text: "Open System Settings › General › Language & Region › Translation Languages and download both languages.")
                    Button("Open Language & Region") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
                    }
                    .buttonStyle(.secondary)
                } else {
                    Label(String(format: String(localized: "Translation from %@ to %@ is not available on this Mac."), sourceName, targetName),
                          systemImage: "exclamationmark.triangle")
                        .font(.csBody.weight(.semibold))
                        .foregroundStyle(Color.csWarning)
                    if !Translator.isAvailable {
                        HintText(text: "Apple's free translation needs macOS 26 or later. Game packs, DeepL and AI translation (Settings › Translation) work on this Mac.")
                    }
                }
            }
        }

        // Çevrimiçi motor çeviremiyor: satırlar bu arada ücretsiz çeviriyle geliyor.
        if model.isRunning, let issue = model.onlineIssue {
            Card {
                Label(String(format: String(localized: "%@ is not translating right now"), model.settings.onlineEngine.displayName),
                      systemImage: "exclamationmark.triangle")
                    .font(.csBody.weight(.semibold))
                    .foregroundStyle(Color.csWarning)
                Text(verbatim: TranslationCard.describe(issue, engine: model.settings.onlineEngine, server: model.settings.localAIServer) + " "
                     + String(localized: "Meanwhile the free translation is used."))
                    .font(.csCallout)
                    .foregroundStyle(Color.csSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let free = model.readingFailedFreeGB {
            Card {
                Label("macOS can't read the text on the screen.", systemImage: "exclamationmark.triangle")
                    .font(.csBody.weight(.semibold))
                    .foregroundStyle(Color.csWarning)
                if free < 10 {
                    HintText(text: LocalizedStringKey(String(format: String(localized: "The disk is almost full (%.1f GB free). macOS needs free space to read text; free up a few GB and start the translation again."), free)))
                } else {
                    HintText(text: "Restart the Mac and start the translation again.")
                }
            }
        }
    }
}

/// Hazır Türkçe çevirisi olan oyunlar kullanılıyor (yalnız İngilizce→Türkçede ve ayar açıkken).
private struct PackInUseTile: View {
    @EnvironmentObject private var model: AppModel

    private var active: Bool {
        model.settings.gamePacks && model.settings.sourceLanguage == "en" && model.settings.targetLanguage == "tr"
            && !model.installedPacks.isEmpty
    }

    var body: some View {
        if active {
            HStack(spacing: Theme.space("m")) {
                TileIcon(symbol: "shippingbox", tint: .csPro)
                Text(verbatim: String(format: String(localized: "Game packs are on · %lld games translated in advance"), model.installedPacks.count))
                    .font(.csBody)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile()
        }
    }
}

/// Son altyazı büyük ve altyazı sarısında, öncekiler altında ikincil renkte; çeviri sürerken sağ üstte canlı nokta.
private struct LiveSubtitlesTile: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            HStack {
                Text("Live subtitles").font(.csHeadline)
                Spacer()
                if model.isRunning { Pill(text: String(localized: "Translating…"), tone: .success, live: true) }
            }
            if model.lastTranslation.isEmpty {
                HintText(text: "Subtitles will appear here while you play.")
            } else {
                CurrentLine(translation: model.lastTranslation, source: model.lastSource)
                if let metrics = model.lastMetrics { MetricsRow(metrics: metrics) }
                SubtitleHistoryList()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
    }
}

private struct CurrentLine: View {
    let translation: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("hair")) {
            Text(verbatim: translation)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.csAccentText)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: source)
                .font(.csCaption)
                .foregroundStyle(Color.csSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}

/// Son satırın ölçümleri: yazı tanıma, çeviri, karenin gelişinden TV'ye kadar gecikme ve tanıma güveni.
/// Küçük ve sessiz (13 pt, ikincil renk, sabit genişlikte rakamlar).
struct MetricsRow: View {
    let metrics: LineMetrics

    var body: some View {
        Text(verbatim: metrics.summary)
            .font(.csCaption.monospacedDigit())
            .foregroundStyle(Color.csSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel(Text("Measurements"))
            .accessibilityValue(Text(verbatim: metrics.summary))
    }
}

/// Kaçırılan satır buradan yeniden okunur (en yenisi üstte; yalnız bu oturumun satırları).
private struct SubtitleHistoryList: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let entries = Array(model.sessionHistory.dropFirst())
        if !entries.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.space("m")) {
                    ForEach(entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: Theme.space("m")) {
                            Divider().overlay(Color.csBorder)
                            HistoryRow(entry: entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .accessibilityLabel(Text("Subtitle history"))
        }
    }
}

private struct HistoryRow: View {
    let entry: SubtitleHistory.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("hair")) {
            Text(verbatim: entry.translation)
                .font(.csHeadline.weight(.regular))
                .foregroundStyle(Color.csSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: entry.source)
                .font(.csCaption)
                .foregroundStyle(Color.csSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}
