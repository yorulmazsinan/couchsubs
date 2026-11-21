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
                            if model.demoMode { DemoFrameTile(preview: model.framePreview) }
                            PackInUseTile()
                            LiveSubtitlesTile()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: gap) {
                            MainControls()
                            if model.demoMode { DemoFrameTile(preview: model.framePreview) }
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
        .alert(item: $model.tvPairingRequest) { ticket in
            Alert(title: Text("Pair this TV?"),
                  message: Text(String(format: String(localized: "TV code: %@. You don't type this code anywhere: if your TV shows the same code, approve it here."), ticket.code)),
                  primaryButton: .default(Text("Approve")) { model.resolveTVPairing(ticket, accept: true) },
                  secondaryButton: .cancel(Text("Reject")) { model.resolveTVPairing(ticket, accept: false) })
        }
        .sheet(isPresented: $model.showSettings, onDismiss: { model.settingsSection = .appearance }) {
            SettingsView(section: model.settingsSection).appSurface()
        }
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

/// Sol sütun: başlat/durdur, PS5 ve TV, altyazının yeri, çeviri motoru ve kısayol (bilgi karosu), uyarılar.
struct MainControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            // Önceki çalışma çöktüyse macOS'un raporu bir kez bildirilir.
            CrashReportCard()
            HStack(spacing: Theme.space("m")) {
                StartStopButton()
                TestSubtitleButton()
            }
            if model.testTVNotConnected && model.tvClients == 0 {
                HintText(text: "The test subtitle did not reach the TV because the TV app is not connected. Open CouchSubs on the TV. If the TV shows a 6-digit code, don't type it anywhere: approve it in the “Pair this TV?” window that opens on this computer, then test again.")
            }
            // Çeviri sürüyor ama TV uygulaması bağlı değil: CouchSubs TV'de nerede bulunur (markaya göre), otomatik açma neden
            // olmadı ve "Otomatik açmayı dene" (Windows, iPhone ve Android ile aynı).
            if model.isRunning, !model.demoMode, model.settings.output.showsOnTV, model.hasTV, model.tvClients == 0, let tv = model.tv {
                Card {
                    Text(LocalizedStringKey(TVOpenText.openOnTV(tv.brand))).font(.csCallout).foregroundStyle(Color.csText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = TVOpenText.reason(model.tvOpenProblem) {
                        Text(LocalizedStringKey(reason)).font(.csCallout).foregroundStyle(Color.csWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(LocalizedStringKey(TVOpenText.tryButton)) { model.retryTVOpen() }
                        .buttonStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: Theme.space("gap")) {
                if model.demoMode {
                    StatusTile(symbol: "play.rectangle", title: "Demo mode", value: model.ps5StatusText,
                               tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning))
                } else if model.isXbox && !model.readsXboxWindow {
                    StatusTile(symbol: "gamecontroller", title: "Xbox · Beta", value: model.ps5StatusText,
                               tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning)) {
                        // Microsoft girişi ya da Xbox seçimi eksikse buradan tamamlanır.
                        if model.needsXboxLink {
                            Button(model.xboxSignedIn ? "Choose your Xbox" : "Sign in with Microsoft") { model.linkXbox() }
                                .buttonStyle(.secondary)
                        }
                        ReconnectButton()
                    }
                } else {
                    StatusTile(symbol: "gamecontroller", title: model.readsCaptureWindow ? "Selected window" : "PS5",
                               value: model.ps5StatusText,
                               tone: AppModel.ps5Tone(model.sessionState, running: model.isRunning)) {
                        ReconnectButton()
                    }
                }
                // Altyazı yalnız bilgisayar ekranındaysa TV durumu gösterilmez.
                if model.settings.output.showsOnTV { TVStatusTile() }
            }
            .fixedSize(horizontal: false, vertical: true)
            if model.isRunning && !model.demoMode { GameSection(choice: model.gameChoice, areas: model.gameAreas) }
            // Kurulum bitmeden de uygulama örnek görüntülerle denenebilir.
            if !model.canStart && !model.isRunning && !model.demoMode { DemoModeButton(kind: .ghost) }
            SubtitleOutputCard()
            // Ayar bilgisi durum karosu gibi değil, satır olarak durur (TASARIM.md › InfoCard).
            InfoCard {
                // Görüntünün nereden okunduğu; dokununca Ayarlar › Görüntü kaynağı (DM'de ayar bulunamıyordu).
                if model.isXbox {
                    // Xbox'ta görüntü kaynağı seçimi yok (Windows'taki gibi gizli); konsol türü gösterilir.
                    InfoRow("Console", value: String(localized: "Xbox Series / Xbox One (Beta)"), action: { model.openSettings(.console) })
                    InfoDivider()
                }
                // Xbox'ta da görüntü kaynağı seçilir (#853): Xbox bağlantısı ya da OBS/oyun penceresi.
                InfoRow("Picture source", value: model.pictureSourceName, action: { model.openSettings(.source) })
                InfoDivider()
                InfoRow("Translation", value: engineName, action: { model.openSettings(.translation) })
                InfoDivider()
                InfoRow("Translate screen") { ScreenKeys(settings: model.settings) }
            }
            MainWarnings()
        }
    }

    private var engineName: String {
        let engine = model.settings.translationEngine
        return engine == .free ? String(localized: "Free") : engine.displayName
    }
}

/// Konsol karosunda: oturum yeniden denemeyi bıraktıysa hemen, süren denemelerde 45 sn sonra. Uygulamayı kapatıp açmadan
/// konsol bağlantısı baştan kurulur, çeviri sürer (ReconnectOffer; iPhone, Android ve Windows ile aynı).
private struct ReconnectButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isRunning && model.sessionState != .streaming {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if model.offersReconnect(now: context.date) {
                    Button { model.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                        .buttonStyle(.secondary)
                }
            }
        }
    }
}

private struct StartStopButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            if model.demoMode {
                model.exitDemo()
            } else {
                Task { model.isRunning ? model.stop() : await model.start() }
            }
        } label: {
            Group {
                if model.demoMode {
                    Label("Exit demo mode", systemImage: "xmark")
                } else {
                    Label(model.isRunning ? "Stop translating" : "Start translating",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                }
            }
            .font(.csHeadline)
        }
        .buttonStyle(CSButtonStyle(kind: model.isRunning || model.demoMode ? .danger : .primary, fullWidth: true, height: "primaryActionHeight"))
        .disabled(model.isStarting || (!model.isRunning && !model.canStart && !model.demoMode))
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
            if model.openingTVAppForTest {
                Label("Opening the app on the TV…", systemImage: "tv")
            } else {
                Label(onTV ? "Test on TV" : "Test on screen", systemImage: onTV ? "tv" : "macwindow")
            }
        }
        .buttonStyle(CSButtonStyle(kind: .secondary, height: "primaryActionHeight"))
        .fixedSize()
        .disabled((onTV && !model.hasTV && !model.settings.output.showsOnComputer) || model.openingTVAppForTest)
        .help(Text(onTV ? "Sends a sample subtitle to the TV." : "Shows a sample subtitle on this computer's screen."))
    }
}

private struct TVStatusTile: View {
    @EnvironmentObject private var model: AppModel

    /// TV eşleşmişken (TV uygulaması bağlı olsa da) yalnız TV adımı açılır: başka TV seçilir, "Yeniden kur…" gerekmez.
    @ViewBuilder private var changeTV: some View {
        if model.canChangeTV {
            Button("Change TV") { model.step = .tv }.buttonStyle(.link)
        }
    }

    var body: some View {
        if model.hasTV {
            if model.canReinstallTVApp {
                // TV uygulaması bağlanmıyor (ör. TV'den kaldırıldı): TV adımı açılır, uygulama yeniden kurulur ya da açılır.
                StatusTile(symbol: "tv", title: "TV", value: String(localized: "Waiting for the TV app"),
                           tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning)) {
                    Button("Reinstall the TV app") {
                        model.step = .tv
                        Task { await model.reinstallTVApp() }
                    }.buttonStyle(.secondary)
                    changeTV
                }
            } else if model.canReconnectTV {
                // TV uygulaması bağlı değil (LG): TV adımı açılır; başka TV seçilir ya da kurulum adımları yeniden izlenir.
                StatusTile(symbol: "tv", title: "TV", value: String(localized: "Waiting for the TV app"),
                           tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning)) {
                    Button("Connect a TV") { model.step = .tv }.buttonStyle(.secondary)
                }
            } else {
                StatusTile(symbol: "tv", title: "TV",
                           value: model.tvClients > 0 ? String(localized: "Connected") : String(localized: "Waiting for the TV app"),
                           tone: AppModel.tvTone(clients: model.tvClients, running: model.isRunning)) {
                    changeTV
                }
            }
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

        if model.readingStuck {
            Card {
                Label("macOS can't read the text on the screen.", systemImage: "exclamationmark.triangle")
                    .font(.csBody.weight(.semibold))
                    .foregroundStyle(Color.csWarning)
                HintText(text: "Text reading got stuck. It usually recovers within a minute or two: macOS prepares its text model after the first launch or an update. Don't quit while waiting. If it doesn't recover, restart CouchSubs.")
                Button("Restart CouchSubs") { model.relaunch() }.buttonStyle(.secondary)
            }
        } else if model.readingRescued {
            Card {
                Label("macOS text reading isn't responding. Subtitles continue with the backup reader.", systemImage: "exclamationmark.triangle")
                    .font(.csBody.weight(.semibold))
                    .foregroundStyle(Color.csWarning)
                HintText(text: "This usually clears up within a minute or two: macOS prepares its text model after the first launch or an update. Reading may be a little less accurate until then. If it doesn't clear up, restart CouchSubs.")
                Button("Restart CouchSubs") { model.relaunch() }.buttonStyle(.secondary)
            }
        } else if let free = model.readingFailedFreeGB {
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
                Text(verbatim: String(format: String(localized: "Game packs are on · %lld games translated in advance"),
                                            GameCatalog.packShelf(model.installedPacks).count))
                    .font(.csBody)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tile()
        }
    }
}

/// Son altyazı büyük ve altyazı sarısında, öncekiler altında daha küçük (özgün metinleri ikincil renkte); çeviri sürerken
/// sağ üstte canlı nokta.
private struct LiveSubtitlesTile: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.space("gap")) {
            HStack {
                Text("Live subtitles").font(.csHeadline)
                Spacer()
                if model.isRunning { Pill(text: String(localized: "Translating…"), live: true) }
            }
            // Çeviri PS5'ten (ikinci hesap) okunurken, ilk altyazıya kadar ve bağlantı koptuğunda: kolu açınca ana hesap
            // seçilmeli (GitHub #231, MainAccountTip).
            if model.isRunning && MainAccountTip.isVisible(ps5: !model.isXbox && model.settings.frameSource == .ps5, demo: model.demoMode,
                                                           hasSubtitle: !model.lastTranslation.isEmpty,
                                                           streaming: model.sessionState == .streaming) {
                HintText(text: "To play without the connection dropping: 1. On the PS5, start the game with your MAIN account first. 2. Then start translating. 3. Don't switch users during the game; when you turn on the controller, choose your MAIN account. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game.")
            }
            // Otomatik ekran yazısı beta.63'te açık geliyordu; bir kez kapatıldı, kullanıcıya söylenir.
            if model.showsAutoScreenTextNotice {
                HintText(text: "Automatic on-screen text translation is experimental; you can turn it on in Settings.")
            }
            // Kullanım verisi ilk açılışta bir kez söylenir; ilk çeviride ya da ayar değişince kaybolur.
            if model.showsUsageNotice { HintText(text: "CouchSubs measures how the app is used without linking it to you; no subtitle text, picture or account data is sent. You can turn this off in Settings › Game packs › Usage data.") }
            // Görüntü bir dakikadır geliyor ama hiç altyazı satırı okunmadı (GitHub #503, #566, #572; SubtitleOffTip).
            if model.showsSubtitleOffTip {
                HintText(text: "Turn on the game's own subtitles: CouchSubs reads the English subtitles on screen, not the audio.")
                if model.settings.watchSubtitleBackground {
                    HintText(text: "“Watch subtitle background” is on: only text on GTA 6’s dark subtitle panel is read. Set the game’s subtitle background to Solid or turn this setting off.")
                }
            }
            if model.lastTranslation.isEmpty {
                HintText(text: "Subtitles will appear here while you play.")
            } else {
                // Yeni satır kısa bir geçişle belirir (azaltılmış harekette geçiş yok); eskisiyle üst üste biner, karo zıplamaz.
                ZStack(alignment: .topLeading) {
                    CurrentLine(translation: model.lastTranslation, source: model.lastSource)
                        .id(model.lastTranslation)
                        .transition(.opacity)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.lastTranslation)
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
                // Altyazı içeriği: 28 pt yarı kalın (`display` ile aynı boy), altyazı sarısında.
                .font(.csDisplay)
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
            // Önceki çeviri 17 pt ikincil renkte, özgün metin küçük (docs/TASARIM.md › Yazı); canlı satır tek vurgu kalır.
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

/// Bilgi karosunun "Ekranı çevir" satırı: Ayarlar › Kısayollar'da seçili her tuş bir Keycap, aralarında "ya da"; hiç
/// kısayol yoksa "kısayol yok" (Windows: MainView.ShowScreenKeys).
private struct ScreenKeys: View {
    let settings: UserSettings

    var body: some View {
        let keys = HotkeyTable.keys(settings.hotkeys, .screen)
        if keys.isEmpty {
            Text("no shortcut").font(.csCaption).foregroundStyle(Color.csSecondary)
        } else {
            HStack(spacing: Theme.space("xs")) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 { Text("or").font(.csCaption).foregroundStyle(Color.csSecondary) }
                    Keycap(key.label)
                }
            }
            .help(HotkeyText.title(settings, .screen, String(localized: "Translate the screen (%@)")))
        }
    }
}
