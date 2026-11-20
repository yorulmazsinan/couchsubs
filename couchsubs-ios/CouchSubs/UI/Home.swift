// SPDX-License-Identifier: AGPL-3.0-only
// Ana ekran, çeviri sürüyor ekranı, yatay altyazı ekranı ve kullanım turu (tuvaldeki Telefon · 7–10).

import CouchSubsCore
import RemotePlay
import SwiftUI
import Translation
import UIKit

/// Ana ekrandan açılan sayfalar.
enum Route: Hashable {
    case settings, profile, packs, target, ps5, psn, about, history
    /// Konsol türü (PlayStation ya da Xbox Beta).
    case platform
    /// TV uygulamasını bu telefondan kurmak; `tvUpdate` ana ekrandaki güncellemeyi kendiliğinden başlatır.
    case tvInstall, tvUpdate
}

/// Turun vurguladığı öğeler.
enum TourTarget: Int, CaseIterable {
    case start, target, packs, profile
}

struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>], nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tourTarget(_ target: TourTarget) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

/// Ana ekranın ortak üst satırı: logo, geçmiş, ayarlar, profil.
struct HomeHeader: View {
    @Binding var path: [Route]

    var body: some View {
        HStack(spacing: Mobile.Space.gap) {
            LogoView(size: 36)
            Spacer()
            IconButton(symbol: "clock.arrow.circlepath", label: "History") { path.append(.history) }
            IconButton(symbol: "gearshape", label: "Settings") { path.append(.settings) }
            AvatarButton(initials: "") { path.append(.profile) }
                .tourTarget(.profile)
        }
        .frame(height: Mobile.Control.icon)
    }
}

// MARK: - 8 Ana ekran

/// Apple çevirisinin dil paketi henüz indirilmedi: "İndir" sistemin indirme penceresini açar.
/// `.translationTask` yalnız yapılandırma değişince çalışır: eskiden ikinci basış aynı yapılandırmayı verdiği için hiçbir
/// şey olmuyor, hata da `try?` ile yutuluyordu (TestFlight). Her basışta yapılandırma geçersiz kılınıp görev yeniden
/// başlatılır, hata karonun altında söylenir.
@available(iOS 26, *)
private struct LanguagePackTile: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var download: TranslationSession.Configuration?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        Tile {
            Text("The English–Turkish language pack is not downloaded yet.").font(Mobile.TypeScale.headline)
            Button("Download") {
                error = nil
                working = true
                let source = Locale.Language(identifier: model.settings.sourceLanguage)
                let target = Locale.Language(identifier: model.settings.targetLanguage)
                if download?.source == source, download?.target == target {
                    download?.invalidate()
                } else {
                    download = TranslationSession.Configuration(source: source, target: target)
                }
            }
            .buttonStyle(.mobileSecondary)
            .disabled(working)
            if let error { MobileNote(text: error) }
        }
        .translationTask(download) { session in
            do {
                try await session.prepareTranslation()
            } catch {
                self.error = String(format: String(localized: "The language pack could not be downloaded (%@). Try again, or download it in Settings › Apps › Translate."),
                                    error.localizedDescription)
            }
            working = false
            await model.refreshTranslatorStatus()
        }
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @Binding var path: [Route]

    var body: some View {
        MobileScreen {
            HomeHeader(path: $path)
        } content: {
            ScreenTitle(title: model.canStart ? "Ready" : "Almost ready",
                        message: model.canStart ? "Open the game on the PS5, then start." : "Finish the setup to start translating.")
            BentoGrid {
                // PS5 karosu eşlemeyi açar; kurulum atlandıysa buradan eşlenir (PSN girişi yoksa önce giriş).
                Button { path.append(.ps5) } label: {
                    if model.isXbox {
                        StatTile(symbol: "gamecontroller.fill", tint: .ok, label: "Xbox · Beta",
                                 value: model.xboxConsole.map { $0.name.isEmpty ? "Xbox" : $0.name } ?? String(localized: "Choose your Xbox"),
                                 live: model.xboxConsole != nil && model.xboxSignedIn, chevron: true)
                    } else {
                        StatTile(symbol: "gamecontroller.fill", tint: .ok, label: "PS5",
                                 value: model.console.map { $0.name.isEmpty ? "PS5" : $0.name } ?? String(localized: "Pair the PS5"),
                                 live: model.console != nil, chevron: true)
                    }
                }
                .buttonStyle(.plain)
                Button { path.append(.target) } label: {
                    StatTile(symbol: model.settings.output == .computer ? "iphone" : "tv", tint: .accent, label: "Subtitles",
                             value: targetName, chevron: true)
                }
                .buttonStyle(.plain)
                .tourTarget(.target)
                packsTile
                    .bentoWide()
                    .tourTarget(.packs)
                // Çeviri motoru ve son oturum durum değil bilgi: iki satırlı tek bilgi karosu (TASARIM.md › Telefon ana ekranı).
                Tile(spacing: 0) {
                    Button { path.append(.settings) } label: { MobileInfoRow(title: "Translation", value: engineName) }
                    RowDivider()
                    Button { path.append(.history) } label: { MobileInfoRow(title: "Last session", value: lastSession) }
                }
                .buttonStyle(.plain)
                .bentoWide()
            }
            if let update = model.tvAppUpdate {
                TVAppUpdateTile(update: update) { path.append(.tvUpdate) }
            } else if model.tvAppMissing {
                Button { path.append(.tvInstall) } label: {
                    InfoTile(symbol: "arrow.down.app", title: "Install the TV app from this phone", caption: "Samsung · LG · Android TV")
                }
                .buttonStyle(.plain)
            }
            // Dil paketi yalnız Apple çevirisinin kullanılabildiği sistemde (iOS 26 ve sonrası) istenir.
            if model.translatorStatus == .needsDownload, #available(iOS 26, *) {
                LanguagePackTile()
            }
            if model.translatorStatus == .unsupported, !Translator.isAvailable {
                MobileNote(text: String(localized: "Apple's free translation needs iOS 26 or later. Game packs, DeepL and AI translation work on this device."))
            }
            DeveloperSignature()
        } bottom: {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await model.start() }
            } label: {
                Label("Start translating", systemImage: "play.fill")
            }
            .buttonStyle(.mobilePrimary)
            .disabled(model.isStarting || !model.canStart)
            .tourTarget(.start)
            // Kurulum bitmeden de uygulama örnek görüntülerle denenebilir.
            if !model.canStart { DemoModeButton(kind: .ghost) }
        }
        .task {
            app.analytics.screen("home")
            await model.refreshTranslatorStatus()
            await model.checkTVApp()
        }
    }

    /// Oyun paketleri karosu (yalnız paket simgesi mor): başlık ve not tek satır, sağda `›`; paketler kapalıysa nötr
    /// "Kapalı" etiketi.
    private var packsTile: some View {
        Button { path.append(.packs) } label: {
            Tile {
                HStack(spacing: Mobile.Space.gap) {
                    MobileTileIcon(symbol: "shippingbox", tint: .pro)
                    VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                        Text("Instant subtitles with ready packs").font(Mobile.TypeScale.headline).lineLimit(1)
                        Text(model.installedPacks.isEmpty ? String(localized: "GTA V, RDR2, Mafia and 3 more games")
                             : PacksScreen.summary(model.installedPacks))
                            .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if !model.settings.gamePacks { MobilePill(text: String(localized: "Off")) }
                    RowChevron()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var targetName: String {
        if model.settings.output == .computer { return String(localized: "This phone") }
        return model.hasTV ? model.tv?.name ?? "TV" : String(localized: "Not set up")
    }

    private var engineName: String {
        model.settings.translationEngine == .free ? String(localized: "Free") : model.settings.translationEngine.displayName
    }

    private var lastSession: String {
        guard let seconds = model.lastSessionSeconds else { return "—" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - 9 Çeviri sürüyor

struct RunningScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var path: [Route]
    @State private var showSubtitles = false

    var body: some View {
        MobileScreen {
            HomeHeader(path: $path)
        } content: {
            HStack(spacing: Mobile.Space.inline) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    MobilePill(text: String(format: String(localized: "Translating · %@"), elapsed(at: context.date)),
                         live: model.sessionState == .streaming)
                }
                if model.packsActive && !model.demoMode { MobilePill(text: String(localized: "Ready translation"), kind: .pro) }
            }
            if model.demoMode {
                DemoModeHeader()
            } else {
                if model.sessionState != .streaming {
                    MobileNote(text: model.ps5StatusText, tone: Mobile.Palette.secondary)
                }
                // İlk altyazı gelene kadar ve bağlantı koptuğunda: kolu açınca PS5'te ana hesap seçilmeli (GitHub #231).
                if MainAccountTip.isVisible(ps5: !model.isXbox, demo: model.demoMode, hasSubtitle: !model.recentLines.isEmpty,
                                            streaming: model.sessionState == .streaming) {
                    MobileNote(text: String(localized: "When you turn on the controller to play, choose your MAIN account on the PS5. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game."),
                               tone: Mobile.Palette.secondary)
                }
                // Görüntü bir dakikadır geliyor ama hiç altyazı satırı okunmadı (GitHub #503, #566, #572; SubtitleOffTip).
                if model.showsSubtitleOffTip {
                    MobileNote(text: String(localized: "Turn on the game's own subtitles: CouchSubs reads the English subtitles on screen, not the audio."),
                               tone: Mobile.Palette.secondary)
                }
                GameSection(choice: model.gameChoice, areas: model.gameAreas)
            }
            Tile {
                Text("Now").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                if let current = model.recentLines.first {
                    Text(verbatim: current.translation)
                        .font(Mobile.TypeScale.subtitle(landscape: false, scale: scale))
                        .foregroundStyle(Mobile.Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        // Azaltılmış harekette yalnız solarak gelir.
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                    HStack {
                        Text(verbatim: current.source).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.tertiary)
                        Spacer()
                        if current.fromPack { Text("ready translation").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.pro) }
                    }
                    // Son satırın ölçümleri: küçük, sessiz, sabit genişlikte rakamlar.
                    if let metrics = model.lastMetrics {
                        Text(verbatim: metrics.summary)
                            .font(Mobile.TypeScale.caption.monospacedDigit())
                            .foregroundStyle(Mobile.Palette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityLabel(Text("Measurements"))
                            .accessibilityValue(Text(verbatim: metrics.summary))
                    }
                } else {
                    Text("Subtitles will appear here while you play.").font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.recentLines.first?.id)
            if model.recentLines.count > 1 {
                Tile(spacing: 0) {
                    ForEach(Array(model.recentLines.dropFirst().prefix(8).enumerated()), id: \.element.id) { index, line in
                        if index > 0 { RowDivider() }
                        HStack(alignment: .top, spacing: Mobile.Space.gap) {
                            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                                // Önceki çeviri 17 pt normal ve ikincil renkte, altında küçük özgün metin (Mac ile aynı;
                                // TASARIM.md › Yazı): canlı satır tek vurgu olarak kalır.
                                Text(verbatim: line.translation).font(Mobile.TypeScale.headline.weight(.regular))
                                    .foregroundStyle(Mobile.Palette.secondary)
                                Text(verbatim: line.source).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                            }
                            Spacer()
                            // Kaynak işareti: düz yazı ("hazır" mor, motor adı üçüncül), hap değil.
                            Text(verbatim: line.fromPack ? String(localized: "ready") : engineName)
                                .font(Mobile.TypeScale.caption)
                                .foregroundStyle(line.fromPack ? Mobile.Palette.pro : Mobile.Palette.tertiary)
                        }
                        .padding(.vertical, Mobile.Space.gap)
                    }
                }
            }
            BentoGrid {
                Tile {
                    Text("From ready translation").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    Text(verbatim: "\(model.sessionPackLines) / \(model.sessionLines)").font(Mobile.TypeScale.title)
                }
                Tile {
                    Text(model.settings.output.showsOnTV ? "TV" : "Screen").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    Text(verbatim: model.settings.output.showsOnTV ? model.tvStatusText : String(localized: "This phone"))
                        .font(Mobile.TypeScale.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            // TV uygulaması 30 saniyede bağlanmadıysa ne yapılacağı (tanı satırı günlüklere yazılır).
            if model.settings.output.showsOnTV, model.tvWaitingLong, model.tvClients == 0 {
                MobileNote(text: String(localized: "The TV app has not connected. Open CouchSubs on the TV and keep the phone and the TV on the same Wi-Fi. If it still waits, check that CouchSubs is allowed in Settings › Privacy & Security › Local Network on this iPhone, then stop and start translating again."))
            }
            Text("Keep CouchSubs open on the screen while you play. iOS stops the connection when the app goes to the background; the screen stays on while translating.")
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        } bottom: {
            // İkincil eylemler tek satırda küçük düğmeler; "Çeviriyi durdur" altta tam genişlikte.
            if model.settings.output.showsOnComputer || model.settings.output.showsOnTV || model.sessionState == .streaming {
                HStack(spacing: Mobile.Space.gap) {
                    if model.settings.output.showsOnComputer || model.demoMode {
                        Button { showSubtitles = true } label: { Label("Subtitle screen", systemImage: "rectangle.landscape.rotate") }
                            .buttonStyle(MobileButtonStyle(kind: .secondary, compact: true))
                    }
                    if model.settings.output.showsOnTV {
                        Button { model.sendTestSubtitle() } label: { Label("Test on TV", systemImage: "tv") }
                            .buttonStyle(MobileButtonStyle(kind: .secondary, compact: true))
                    }
                    if model.sessionState == .streaming {
                        ScreenTranslateButton()
                    }
                }
            }
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                if model.demoMode { model.exitDemo() } else { model.stop() }
            } label: {
                if model.demoMode {
                    Label("Exit demo mode", systemImage: "xmark")
                } else {
                    Label("Stop translating", systemImage: "stop.fill")
                }
            }
            .buttonStyle(.mobileDestructive)
        }
        .fullScreenCover(isPresented: $showSubtitles) { SubtitleScreen() }
        // Deneme modunda örnek görüntü bu ekranda görünsün diye altyazı ekranı kendiliğinden açılmaz.
        .onAppear { if model.settings.output == .computer && !model.demoMode { showSubtitles = true } }
    }

    private var scale: Double { Double(model.settings.style.fontSize) / Double(SubtitleStyle().fontSize) }

    private var engineName: String {
        model.settings.translationEngine == .free ? String(localized: "Free") : model.settings.translationEngine.displayName
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(model.runningSince ?? date)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 10 Yatay altyazı ekranı

struct SubtitleScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    /// Ekran yatay mı; "Ekranı döndür" düğmesi dikeye ve geri çevirir.
    @State private var landscape = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            VStack(spacing: Mobile.Space.inline) {
                ForEach(Array(model.phoneLines.enumerated()), id: \.element.id) { index, line in
                    // Uzun çeviri en çok 3 satıra dengeli bölünür; sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
                    let wrapped = line.wrapped
                    // Önceki satır soldurulmaz, ikincil yazı renginde olur (TASARIM.md › Yazı). Konuşana göre renk
                    // açıksa güncel satırdaki "Mattia: …" o konuşanın renginde (bkz. SpeakerColors).
                    let previous = index < model.phoneLines.count - 1
                    Self.subtitleText(wrapped.text, colored: model.settings.speakerColors && !previous && !line.paragraphs,
                                      base: previous ? Mobile.Palette.secondary : textColor)
                        .font(Mobile.TypeScale.subtitle(landscape: true, scale: scale * CGFloat(wrapped.scale)))
                        .opacity(line.fading ? 0.4 : 1)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                }
            }
            .padding(.horizontal, Mobile.Space.screen)
            .padding(.bottom, Mobile.Space.screen * 2)
            // Ek alanların (görev, telefon, bildirim) çevirisi oyundaki yerinde küçük kutuda (TV'deki gibi).
            GeometryReader { proxy in
                ForEach(model.phoneRegions) { region in
                    let box = region.box ?? TextBox(left: 0.6, top: 0.05, right: 0.95, bottom: 0.2)
                    Text(verbatim: region.text)
                        .font(Mobile.TypeScale.caption)
                        .foregroundStyle(Mobile.Palette.text)
                        .padding(6)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: max(120, proxy.size.width * (box.right - box.left)), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: proxy.size.width * (box.left + box.right) / 2, y: proxy.size.height * box.top + 24)
                }
            }
            .allowsHitTesting(false)
            // "Ekranı çevir" sonuçları: her çeviri kendi yazısının yerinde ve aynı boyda (TV'deki gibi).
            GeometryReader { proxy in
                ForEach(Array(model.screenItems.enumerated()), id: \.offset) { _, item in
                    let box = item.box
                    let width = max(60, proxy.size.width * (box.right - box.left))
                    let size = max(10, min(28, proxy.size.height * item.lineHeight * 0.8))
                    Text(verbatim: item.translation)
                        .font(.system(size: size, weight: .semibold))
                        .foregroundStyle(Mobile.Palette.text)
                        .multilineTextAlignment(.leading)
                        .padding(4)
                        .frame(width: width, alignment: .leading)
                        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize(horizontal: false, vertical: true)
                        .position(x: proxy.size.width * box.left + width / 2,
                                  y: proxy.size.height * (box.top + box.bottom) / 2)
                }
            }
            .allowsHitTesting(false)
            Text("The screen stays on · brightness is lowered automatically")
                .font(Mobile.TypeScale.caption)
                .foregroundStyle(Mobile.Palette.tertiary)
                .padding(.bottom, Mobile.Space.inline)
        }
        .overlay(alignment: .topLeading) {
            MobilePill(text: statusText, live: model.sessionState == .streaming)
                .padding(Mobile.Space.screen)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: Mobile.Space.inline) {
                // Telefon kendiliğinden dönmezse (yön kilidi, iOS isteği geri çevirdi) elle döndürülür (#559).
                IconButton(symbol: "rotate.right", label: "Rotate screen") {
                    landscape.toggle()
                    Orientation.request(Orientation.subtitleMask(landscape: landscape))
                }
                if model.sessionState == .streaming {
                    IconButton(symbol: model.screenState == .idle ? "text.viewfinder" : "xmark.circle",
                               label: model.screenState == .idle ? "Translate screen" : "Remove screen translations") {
                        model.translateScreen()
                    }
                }
                IconButton(symbol: "xmark", label: "Close") { dismiss() }
            }
            .padding(Mobile.Space.screen)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            landscape = true
            Orientation.request(.landscape)
        }
        .onDisappear {
            Orientation.release()
        }
    }

    private var statusText: String {
        if model.demoMode { return String(localized: "Demo mode") }
        guard model.sessionState == .streaming else { return model.ps5StatusText }
        // Xbox'ta "PS5 bağlı" yazmasın: bağlı konsolun türü söylenir.
        if model.isXbox {
            return model.packsActive ? String(localized: "Xbox connected · ready translation") : String(localized: "Xbox connected")
        }
        return model.packsActive ? String(localized: "PS5 connected · ready translation") : String(localized: "PS5 connected")
    }

    private var scale: Double { Double(model.settings.style.fontSize) / Double(SubtitleStyle().fontSize) }

    private var textColor: Color {
        switch model.settings.style.textColor {
        case .yellow: Mobile.Palette.accent
        case .white: Mobile.Palette.text
        }
    }

    /// Konuşana göre renkli altyazı: adlı satır (bölünmüş devamıyla) konuşanın renginde, diğerleri `base` renginde.
    private static func subtitleText(_ text: String, colored: Bool, base: Color) -> Text {
        guard colored else { return Text(verbatim: text).foregroundColor(base) }
        return SpeakerColors.segments(in: text).reduce(Text(verbatim: "")) { result, segment in
            let rgb = segment.color.flatMap(SpeakerColors.rgb)
            let color = rgb.map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) } ?? base
            return result + Text(verbatim: segment.text).foregroundColor(color)
        }
    }

    // Parlaklık kısılmaz: altyazı ekranı açıkken parlaklık 0,4'e indiriliyordu, kullanıcı ekranı karanlık buluyordu (#559).
    // Ekran çeviri sürerken zaten kararmaz (PhoneModel.keepScreenAwake).
}

/// Altyazı ekranı açılınca telefon yataya döner. Uygulamanın izin verdiği yönler (`allowed`, AppDelegate okur) önce
/// isteğe daraltılır, sonra iOS'tan dönüş istenir: yalnız `requestGeometryUpdate` çağrısı ekran sunulurken bazı
/// telefonlarda geri çevriliyor, ekran dik kalıyordu (#559).
@MainActor
enum Orientation {
    /// Uygulamanın genelde izin verdiği yönler (Info.plist ile aynı: dik ve iki yatay).
    static let standard: UIInterfaceOrientationMask = .allButUpsideDown
    /// AppDelegate `supportedInterfaceOrientationsFor` ile bunu döner.
    static var allowed: UIInterfaceOrientationMask = standard

    /// "Ekranı döndür" düğmesinin istediği yön.
    nonisolated static func subtitleMask(landscape: Bool) -> UIInterfaceOrientationMask { landscape ? .landscape : .portrait }

    static func request(_ mask: UIInterfaceOrientationMask) {
        allowed = mask
        apply(mask)
        // Ekran sunulma animasyonu sürerken gelen istek yok sayılabiliyor: kısa süre sonra bir kez daha istenir.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if allowed == mask { apply(mask) }
        }
    }

    /// Altyazı ekranı kapandı: uygulama yine her yöne döner, telefon dike geçer.
    static func release() {
        allowed = standard
        apply(.portrait)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var controller = window.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                RemotePlayLog.write("Ekran yönü değişmedi: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - 7 Kullanım turu (ilk açılışta bir kez, 4 adım)

struct CoachTour: View {
    let anchors: [TourTarget: Anchor<CGRect>]
    let onFinish: () -> Void
    @State private var step = 0

    private let steps: [(title: LocalizedStringKey, text: LocalizedStringKey)] = [
        ("Start translating here", "Tap after you open the game on the PS5. The phone takes the picture, reads the subtitles and translates them."),
        ("Where the subtitles appear", "On the TV over the game, or on this phone. Tap to change it."),
        ("Ready packs", "In popular games the subtitles come from ready translations, without waiting."),
        ("Profile and settings", "Your devices, PSN account and translation settings are here."),
    ]

    var body: some View {
        GeometryReader { proxy in
            let target = TourTarget(rawValue: step) ?? .start
            let rect = anchors[target].map { proxy[$0].insetBy(dx: -6, dy: -6) }
            ZStack(alignment: .topLeading) {
                // %72 karartma, vurgulanan öğenin çevresinde delik ve düz amber halka (parıltı yok).
                Color.black.opacity(0.72)
                    .reverseMask {
                        if let rect {
                            RoundedRectangle(cornerRadius: Mobile.Radius.control).frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }
                if let rect {
                    RoundedRectangle(cornerRadius: Mobile.Radius.control)
                        .strokeBorder(Mobile.Palette.accent, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                card
                    .padding(.horizontal, Mobile.Space.screen)
                    .frame(maxWidth: .infinity)
                    .position(x: proxy.size.width / 2, y: cardY(rect: rect, height: proxy.size.height))
            }
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func cardY(rect: CGRect?, height: CGFloat) -> CGFloat {
        guard let rect else { return height / 2 }
        // Kart vurgulanan öğenin karşı yarısında durur.
        return rect.midY > height / 2 ? max(140, rect.minY - 120) : min(height - 140, rect.maxY + 120)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            HStack {
                Text(verbatim: "\(step + 1) / \(steps.count)").font(Mobile.TypeScale.caption).monospacedDigit()
                    .foregroundStyle(Mobile.Palette.secondary)
                Spacer()
                Button("Skip", action: onFinish).buttonStyle(.mobileGhost)
            }
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(steps[step].title).font(Mobile.TypeScale.title)
                Text(steps[step].text).font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                PageDots(count: steps.count, current: step)
                Spacer()
                Button(step == steps.count - 1 ? "Done" : "Next") {
                    if step == steps.count - 1 { onFinish() } else { withAnimation { step += 1 } }
                }
                .buttonStyle(MobileButtonStyle(kind: .primary))
                .frame(width: 120)
            }
        }
        .padding(Mobile.Space.tile)
        .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.tile))
        .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.tile).strokeBorder(Mobile.Palette.border))
    }
}

extension View {
    /// Verilen şekli görünümden oyar (turdaki delik).
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle().overlay { mask().blendMode(.destinationOut) }.compositingGroup()
        }
    }
}

/// "Ekranı çevir": oyun ekranının tamamını çevirir; çeviri sürerken ya da sonuçlar ekrandayken dokununca kaldırır.
/// Çeviri sürüyor ekranının alt satırında küçük düğme.
struct ScreenTranslateButton: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            model.translateScreen()
        } label: {
            switch model.screenState {
            case .idle: Label("Translate screen", systemImage: "text.viewfinder")
            case .working: Label("Translating the screen…", systemImage: "hourglass")
            case .shown: Label("Remove screen translations", systemImage: "xmark.circle")
            }
        }
        .buttonStyle(MobileButtonStyle(kind: .secondary, compact: true))
    }
}
