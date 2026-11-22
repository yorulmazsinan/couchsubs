// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import CoreImage.CIFilterBuiltins
import RemotePlay
import SwiftUI

/// Yeni kurulum sihirbazı (tuval 00–08): açılış (yalnız ilk kurulumda), konsol, PlayStation hesabı, PS5'e bağlan
/// (bulunamazsa nedenler), TV (kod iki ekranda), TV girişi, daha iyi çeviri, deneyelim. Adım mantığı AppModel'de aynı;
/// eski adım görünümlerinin içerikleri yeni dilde gömülüdür (başlık ve açıklamayı sihirbaz çizer). Reklam yok.
struct WizardView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("introPlayed") private var introPlayed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.step == .welcome && !introPlayed && !model.demoMode {
                IntroView { introPlayed = true }
                    .transition(.opacity)
            } else {
                WizardFrame()
                    .transition(.opacity)
            }
        }
        .animation(DS.animation(.page, reduced: reduceMotion || !model.settings.transitionAnimations), value: introPlayed)
        .environment(\.dsMotionOff, !model.settings.transitionAnimations)
        .newLook()
    }
}

// MARK: Açılış

/// Koyu zeminde kanepe parçaları sırayla yükselir, çubuklar açılır, "CouchSubs" ve "by Enmera" belirir; ses yalnız
/// burada ve Ayarlar › Temel › Açılış Sesi açıkken. Atlanabilir.
private struct IntroView: View {
    @EnvironmentObject private var model: AppModel
    let finish: () -> Void
    @State private var run = 0
    @State private var stage = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color(red: 0.071, green: 0.075, blue: 0.086).ignoresSafeArea()
            VStack(spacing: 28) {
                IntroLogo(stage: stage)
                    .frame(width: 240, height: 185)
                Text(verbatim: "CouchSubs")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.68)
                    .foregroundStyle(Color(red: 0.953, green: 0.933, blue: 0.894))
                    .opacity(stage >= 1.15 ? 1 : 0)
                    .offset(y: stage >= 1.15 ? 0 : 10)
                HStack(spacing: 8) {
                    Text("by").font(.system(size: 11, design: .monospaced)).tracking(1.5)
                    Image("EnmeraWhite").resizable().aspectRatio(contentMode: .fit).frame(height: 11).opacity(0.75)
                        .accessibilityLabel(Text(verbatim: "Enmera"))
                }
                .foregroundStyle(Color(red: 0.553, green: 0.533, blue: 0.498))
                .opacity(stage >= 1.5 ? 1 : 0)
                VStack(spacing: 12) {
                    Button("Let's Get Started") { finish() }
                        .buttonStyle(DSButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                    Text("Setup takes about 3 minutes.").font(.dsSmall).foregroundStyle(Color(red: 0.553, green: 0.533, blue: 0.498))
                }
                .padding(.top, 16)
                .opacity(stage >= 2.3 ? 1 : 0)
                .offset(y: stage >= 2.3 ? 0 : 10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 8) {
                Button("Replay with Sound") { play(sound: true) }.buttonStyle(IntroGhost())
                Button("Replay Silently") { play(sound: false) }.buttonStyle(IntroGhost())
            }
            .padding(24)
        }
        .overlay(alignment: .topTrailing) {
            Button("Skip Intro") { finish() }.buttonStyle(IntroGhost()).padding(24).keyboardShortcut(.cancelAction)
        }
        .onAppear { play(sound: model.settings.startupSound) }
        .onDisappear { StartupChime.shared.stop() }
    }

    /// Zaman çizelgesi tuvaldeki gibi: arkalık 80 ms, oturak 300 ms, parıltı 650 ms, çubuklar 780/920 ms, yazı 1150 ms,
    /// "by" 1500 ms, düğme 2300 ms. Hareket azaltılmışsa hepsi hemen görünür.
    private func play(sound: Bool) {
        run += 1
        let current = run
        if sound { StartupChime.shared.play() } else { StartupChime.shared.stop() }
        stage = 0
        guard !(reduceMotion || !model.settings.transitionAnimations) else { stage = 3; return }
        for mark in [0.08, 0.3, 0.65, 0.78, 0.92, 1.15, 1.5, 2.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + mark) {
                guard current == run else { return }
                withAnimation(DS.enter(500)) { stage = mark }
            }
        }
    }
}

private struct IntroLogo: View {
    let stage: Double

    var body: some View {
        GeometryReader { geometry in
            let s = geometry.size.width / 640
            ZStack(alignment: .topLeading) {
                part(282, 290, 460, 320, 52, Color(red: 0.263, green: 0.275, blue: 0.31), s)
                    .opacity(stage >= 0.08 ? 1 : 0).offset(y: stage >= 0.08 ? 0 : 18 * s).scaleEffect(stage >= 0.08 ? 1 : 0.96)
                // Parıltı: çubukların arkasında yumuşak amber ışık.
                Ellipse().fill(Color.dsAmber.opacity(0.35)).blur(radius: 40 * s)
                    .frame(width: 300 * s, height: 160 * s).offset(x: (362 - 192) * s, y: (340 - 250) * s)
                    .opacity(stage >= 0.65 ? 1 : 0)
                bar(367, 362, 290, s, open: stage >= 0.78)
                bar(414, 436, 196, s, open: stage >= 0.92)
                Group {
                    part(262, 690, 40, 44, 12, Color(red: 0.953, green: 0.933, blue: 0.894), s)
                    part(722, 690, 40, 44, 12, Color(red: 0.953, green: 0.933, blue: 0.894), s)
                    part(202, 446, 112, 254, 56, Color(red: 0.953, green: 0.933, blue: 0.894), s)
                    part(710, 446, 112, 254, 56, Color(red: 0.953, green: 0.933, blue: 0.894), s)
                    part(202, 574, 620, 126, 56, Color(red: 0.953, green: 0.933, blue: 0.894), s)
                }
                .opacity(stage >= 0.3 ? 1 : 0).offset(y: stage >= 0.3 ? 0 : 26 * s)
            }
        }
        .aspectRatio(640 / 494, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func part(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: Color, _ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r * s, style: .continuous).fill(color)
            .frame(width: w * s, height: h * s).offset(x: (x - 192) * s, y: (y - 250) * s)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ s: CGFloat, open: Bool) -> some View {
        Capsule().fill(Color.dsAmber)
            .frame(width: w * s, height: 50 * s)
            .scaleEffect(x: open ? 1 : 0, y: 1, anchor: .leading)
            .offset(x: (x - 192) * s, y: (y - 250) * s)
    }
}

private struct IntroGhost: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color(red: 0.741, green: 0.722, blue: 0.682))
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Color(red: 0.11, green: 0.114, blue: 0.129), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(red: 0.2, green: 0.208, blue: 0.235)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: Çerçeve

/// Üst çubuk (logo, ilerleme noktaları, "Sonra Ayarlarım"), içerik (yanlar 120, üst 24, alt 40), alt çubuk (Geri, not,
/// tek ana düğme).
private struct WizardFrame: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DSBrand().frame(maxWidth: .infinity, alignment: .leading)
                ProgressDots(position: WizardText.position(model.step))
                Button("I'll Set Up Later") { model.step = .done }
                    .buttonStyle(.plain)
                    .font(.dsSmall)
                    .foregroundStyle(Color.dsMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, DS.space("l"))
            .frame(height: DS.size("header"))
            VStack(alignment: .leading, spacing: DS.space("xl")) {
                DSPageTitle(eyebrow: WizardText.eyebrow(model.step, xbox: model.isXbox),
                            title: WizardText.title(model.step, xbox: model.isXbox),
                            message: WizardText.message(model.step, xbox: model.isXbox, hasTV: model.hasTV))
                ScrollView(.vertical) {
                    StepBody().frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 2)
                }
                .frame(maxHeight: .infinity)
                WizardFooter()
            }
            .padding(.horizontal, DS.space("wizardSide"))
            .padding(.top, DS.space("l"))
            .padding(.bottom, DS.space("xxl"))
            .id(model.step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
        }
        .frame(maxWidth: DS.size("contentMax"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBackground)
        .animation(DS.animation(.page, reduced: reduceMotion || !model.settings.transitionAnimations), value: model.step)
    }
}

/// Dört ilerleme noktası: geçerli adım 24 genişlikte amber, öbürleri 8.
private struct ProgressDots: View {
    let position: Int

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            ForEach(1...4, id: \.self) { index in
                Capsule().fill(index == position ? Color.dsAmber : index < position ? Color.dsAmberLine.opacity(0.6) : Color.dsBorder)
                    .frame(width: index == position ? 24 : 8, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(String(format: String(localized: "STEP %lld / %lld"), position, 4)))
    }
}

private struct WizardFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: DS.space("m")) {
            if model.step != .welcome {
                Button("Back") { model.back() }.buttonStyle(.dsSecondary)
            }
            DemoModeButton(kind: .ghost)
            Spacer(minLength: DS.space("s"))
            if let note = WizardText.footnote(model) {
                Text(note).font(.dsSmall).foregroundStyle(Color.dsMuted).tracking(DS.mutedTracking)
                    .multilineTextAlignment(.trailing).lineLimit(2)
            }
            if model.step == .betterTranslation && !model.usesFreeGemini {
                Button("Skip for Now") { model.advance() }.buttonStyle(.dsSecondary)
            } else if model.step != .test {
                Button("Continue") { continueStep() }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
    }

    private var canContinue: Bool {
        model.step == .welcome ? true : model.canAdvance
    }

    private func continueStep() {
        // "Oyun Penceresi" seçildiyse görüntü seçilen pencereden okunur, kurulum biter (pencere Ayarlar'dan seçilir).
        if model.step == .welcome, WelcomeChoice.shared.window {
            if model.isXbox { model.useXboxWindow() } else { model.useCaptureWindow() }
            return
        }
        model.advance()
    }
}

/// Sihirbazın metinleri (METINLER.md › Kurulum).
enum WizardText {
    static func position(_ step: AppModel.Step) -> Int {
        switch step {
        case .welcome: 1
        case .secondAccount, .psnLogin, .console: 2
        case .tv, .hdmi: 3
        case .betterTranslation, .test, .done: 4
        }
    }

    static func eyebrow(_ step: AppModel.Step, xbox: Bool) -> String {
        let stepText = String(format: String(localized: "STEP %lld / %lld"), position(step), 4)
        switch step {
        case .secondAccount, .psnLogin: return xbox ? stepText : String(localized: "SETUP · ACCOUNT")
        case .hdmi: return stepText + " · " + String(localized: "TV INPUT")
        case .betterTranslation: return String(localized: "SETUP · TRANSLATION")
        default: return stepText
        }
    }

    static func title(_ step: AppModel.Step, xbox: Bool) -> LocalizedStringKey {
        switch step {
        case .welcome: "Which console do you play on?"
        case .secondAccount: "Second PlayStation Account"
        case .psnLogin: xbox ? "Sign In with Your Microsoft Account" : "Second PlayStation Account"
        case .console: xbox ? "Choose Your Xbox at Home" : "Let's Connect to the PS5"
        case .tv: "Show Subtitles on the TV"
        case .hdmi: "Which TV Input Is the PS5 Plugged Into?"
        case .betterTranslation, .done: "Better Translation (Free)"
        case .test: "Let's Try It"
        }
    }

    static func message(_ step: AppModel.Step, xbox: Bool, hasTV: Bool) -> LocalizedStringKey {
        switch step {
        case .welcome: "CouchSubs gets the picture from the console over your local network. Nothing is installed on your console."
        case .secondAccount, .psnLogin:
            xbox ? "Link your Xbox account with a Microsoft device code. The sign-in page opens in your default browser."
                 : "CouchSubs connects to the PS5 by itself with a second account. You keep playing with your main account."
        case .console: xbox ? "Choose the console to use." : "You signed in with your free second PlayStation account. Now we're looking for the PS5 on the same network."
        case .tv: hasTV ? "We found a TV on the network. Choose it and CouchSubs installs its app on the TV by itself."
                        : "We're looking for TVs on the network. Choose yours and CouchSubs installs its app on the TV by itself."
        case .hdmi: "CouchSubs opens this input on the TV to show subtitles over the game. If the wrong input is chosen, the screen stays black."
        case .betterTranslation, .done: "If you like, add a free Gemini key. Without it the free translation is used; you can also add it later in Settings."
        case .test: "We test each part one by one. You should see a sample Turkish subtitle on the TV."
        }
    }

    @MainActor static func footnote(_ model: AppModel) -> LocalizedStringKey? {
        switch model.step {
        case .welcome: "You can change the console later in Settings."
        case .psnLogin: model.isXbox ? nil : "If sign-in opens in the browser, finish it there; the app continues by itself."
        case .console: model.isXbox ? nil : "If the PS5 isn't found, tips open after 10 seconds."
        case .tv: model.hasTV ? "If the installation continues in the background, it shows on the home screen when it's done."
                              : "Approve the code on the TV to continue. If you don't have a TV, skip with \"I Don't Have a TV\"."
        case .hdmi: model.settings.style.hdmiInput.map { LocalizedStringKey(String(format: String(localized: "HDMI %lld saved."), $0)) }
            ?? "Confirm the picture to continue."
        case .betterTranslation: "The key is stored only in this Mac's keychain."
        default: nil
        }
    }
}

/// Konsol adımındaki "Oyun Penceresi" seçimi (Devam'a basılınca uygulanır).
@MainActor
final class WelcomeChoice: ObservableObject {
    static let shared = WelcomeChoice()
    @Published var window = false
}

// MARK: Adımlar

private struct StepBody: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        switch model.step {
        case .welcome: ConsoleChoiceStep()
        case .secondAccount: AccountStep()
        case .psnLogin: if model.isXbox { XboxLoginStep() } else { PSNLoginStep() }
        case .console: if model.isXbox { XboxConsoleStep() } else { ConnectPS5Step() }
        case .tv: TVWizardStep()
        case .hdmi: HDMIStep()
        case .betterTranslation, .done: BetterTranslationStep()
        case .test: TryItStep()
        }
    }
}

/// 01 · Konsol: üç seçenek kartı (PlayStation 5, Xbox Series, Oyun Penceresi).
private struct ConsoleChoiceStep: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var choice = WelcomeChoice.shared

    var body: some View {
        HStack(spacing: DS.space("l")) {
            option(badge: "PS5", title: "PlayStation 5", sub: "With Remote Play", selected: !model.isXbox && !choice.window) {
                choice.window = false
                model.choosePlatform(.playstation)
            }
            option(badge: "Xbox", title: "Xbox Series", sub: "With Remote Features", selected: model.isXbox && !choice.window) {
                choice.window = false
                model.choosePlatform(.xbox)
            }
            option(badge: String(localized: "WINDOW"), title: "Game Window", sub: "Remote Play, OBS, Capture Card", selected: choice.window) {
                choice.window = true
            }
        }
        if model.showsUsageNotice {
            Text("CouchSubs measures how the app is used without linking it to you; no subtitle text, picture or account data is sent. You can turn this off in Settings › Game packs › Usage data.")
                .dsMuted().padding(.top, DS.space("l"))
        }
    }

    private func option(badge: String, title: LocalizedStringKey, sub: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.space("m")) {
                Text(verbatim: badge)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.dsCharcoal)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous))
                HStack {
                    DSTitleBlock(title: title, subtitle: sub, titleFont: .dsH3)
                    DSRadio(on: selected)
                }
            }
            .padding(DS.space("m"))
            .background(Color.dsSurface, in: RoundedRectangle(cornerRadius: DS.radius("card"), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.radius("card"), style: .continuous)
                .strokeBorder(selected ? Color.dsAmber : Color.dsBorder, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: DS.radius("card"), style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 02 · PlayStation Hesabı: solda bir kez yapılan dört madde (tıklanınca yeşil tik) ve "İkinci Hesabım Yok"; sağda
/// Sony'nin hesap açma sayfasının QR kodu (yerel üretilir) ve "Sayfayı Bu Mac'te Aç".
private struct AccountStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var done: Set<Int> = []
    /// Sony'nin resmi, ücretsiz hesap açma sayfası.
    static let signUp = URL(string: "https://www.playstation.com/acct/create-account")!

    private let items: [LocalizedStringKey] = [
        "Create a free account on playstation.com with a different email address.",
        "On the PS5, choose Add User and sign in once with the new account.",
        "While still on the new user, go to Settings › System › Remote Play and turn on Enable Remote Play.",
        "Switch back to your own user. You only do this once.",
    ]

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard(spacing: DS.space("xs"), scrolls: false) {
                DSCardHeader("DONE ONCE")
                ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                    let isDone = done.contains(index)
                    Button {
                        if isDone { done.remove(index) } else { done.insert(index) }
                    } label: {
                        HStack(spacing: DS.space("m")) {
                            DSStepNumber(number: index + 1, done: isDone)
                            Text(text).font(.dsBody).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, DS.space("s"))
                        .padding(.vertical, DS.space("xs"))
                        .frame(minHeight: DS.size("option"))
                        .background(isDone ? Color.dsSuccessSoft : Color.clear, in: RoundedRectangle(cornerRadius: DS.radius("tile")))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Sony's PS Remote Play app can't be used meanwhile.").dsMuted().padding(.top, DS.space("xs"))
                HStack(spacing: DS.space("xs")) {
                    Button("I Don't Have a Second Account: Read the Remote Play Window") { model.useRemotePlayWindow() }
                        .buttonStyle(.dsSecondary)
                }
                Text("When you turn on the controller to play, choose your MAIN account on the PS5. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game.").dsMuted()
            }
            .frame(maxWidth: .infinity)
            DSCard(scrolls: false) {
                DSCardHeader("Scan with Your Phone")
                QRCodeView(text: Self.signUp.absoluteString)
                    .frame(width: 168, height: 168)
                    .frame(maxWidth: .infinity)
                Text("The code opens Sony's free account sign-up page.").dsMuted()
                Button("Open the Page on This Mac") { NSWorkspace.shared.open(Self.signUp) }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            }
            .frame(width: 320)
        }
    }
}

/// QR kodu yerelde (Core Image) üretilir; ağ isteği yok.
struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(nsImage: image).interpolation(.none).resizable().aspectRatio(1, contentMode: .fit)
                .padding(DS.space("s"))
                .background(Color.white, in: RoundedRectangle(cornerRadius: DS.radius("control")))
                .accessibilityLabel(Text(verbatim: text))
        }
    }

    static func image(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// 03–04 · PS5'e Bağlan: bulunan PS5'ler kart kart; 10 sn'de bulunamazsa ipuçları, "Neyin Eksik Olduğunu Denetle" ve
/// elle IP. Sağda bağlantı adımları ve 8 haneli kod (PS5'te Ayarlar › Sistem › Uzaktan Oynama › Cihazı Eşleştir).
private struct ConnectPS5Step: View {
    @EnvironmentObject private var model: AppModel
    @State private var consoles: [ConsoleInfo] = []
    @State private var selected: String?
    @State private var manualHost = ""
    @State private var pin = ""
    @State private var searching = false
    @State private var working = false
    @State private var error: String?
    @State private var paired = false
    @State private var tips = false
    @State private var checks: [SetupCheck]?
    @State private var checking = false

    private var host: String { selected ?? manualHost.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        if let checks {
            DiagnosticsView(checks: checks, checking: checking, manualHost: $manualHost,
                            retry: { Task { await runChecks() } },
                            connect: { selected = nil; self.checks = nil; Task { await register() } },
                            back: { self.checks = nil })
        } else {
            HStack(alignment: .top, spacing: DS.space("l")) {
                VStack(spacing: DS.space("l")) { searchCard; if tips && consoles.isEmpty { tipsCard } }
                    .frame(maxWidth: .infinity)
                connectionCard.frame(width: 380)
            }
            .task { await search() }
        }
    }

    private var searchCard: some View {
        DSCard(spacing: DS.space("s"), scrolls: false) {
            HStack(spacing: DS.space("m")) {
                ZStack {
                    Circle().fill(Color.dsAmberSoft).frame(width: 48, height: 48)
                    if searching { DSPulseDot(color: .dsAmber, size: 12) } else {
                        Image(systemName: consoles.isEmpty ? "magnifyingglass" : "checkmark").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(consoles.isEmpty ? Color.dsAmberText : Color.dsSuccess)
                    }
                }
                VStack(alignment: .leading, spacing: DS.space("xxs")) {
                    Text(consoles.isEmpty ? "Searching for the PS5" : "PS5 Found").font(.dsH3)
                    Text(consoles.isEmpty ? "Scanning devices on the same network." : "Choose the one you want to connect to.").dsMuted()
                }
                Spacer()
                Button(searching ? "Searching…" : "Search Again") { Task { await search() } }
                    .buttonStyle(.dsSecondary)
                    .disabled(searching)
            }
            .padding(.bottom, DS.space("xs"))
            ForEach(consoles, id: \.host) { console in
                Button { selected = console.host } label: {
                    HStack(spacing: DS.space("m")) {
                        Text(verbatim: "PS5").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.dsCharcoal)
                            .frame(width: 48, height: 40).background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("small")))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: console.name.isEmpty ? "PS5" : console.name).font(.dsBodyStrong)
                            Text(verbatim: "\(console.host) · \(String(localized: console.isAwake ? "On" : "In Rest Mode"))")
                                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.dsMuted)
                        }
                    }
                }
                .buttonStyle(DSOptionStyle(selected: selected == console.host))
                .transition(.opacity.combined(with: .offset(y: 14)))
            }
        }
        .animation(DS.enter(400), value: consoles)
    }

    private var tipsCard: some View {
        DSCard(scrolls: false) {
            DSCardHeader("Can't Find the PS5?")
            Text("The PS5 and this Mac must be on the same Wi-Fi network. On the PS5, Stay Connected to the Internet must be on in Settings › System › Power Saving. Turn off any VPN. A 5 GHz network works better.").dsMuted()
            Button("Check What's Missing") { Task { await runChecks() } }.buttonStyle(.dsSecondary)
            Text("Manual IP Address").font(.dsRow)
            TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                .textFieldStyle(DSTextFieldStyle(mono: true))
                .onSubmit { selected = nil }
        }
        .transition(.opacity.combined(with: .offset(y: 12)))
    }

    private var connectionCard: some View {
        DSCard(spacing: DS.space("s"), scrolls: false) {
            DSCardHeader("CONNECTION")
            ConnectionRow(title: "PlayStation Account", sub: "Signed in with the second account.", done: model.accountId != nil)
            ConnectionRow(title: model.console != nil || selected != nil ? "PS5 Found" : "Searching for the PS5",
                          sub: LocalizedStringKey(selected.map { host in String(format: String(localized: "%@ selected."), consoles.first { $0.host == host }?.name ?? host) } ?? ""),
                          done: model.console != nil || selected != nil)
            ConnectionRow(title: "Pairing and First Picture", sub: "Setting up an encrypted connection with the PS5.", done: model.console != nil && paired)
            Text("Turn on the PS5. As the second user, open Settings › System › Remote Play › Pair Device and enter the 8-digit code shown there.")
                .dsMuted().padding(.top, DS.space("xs"))
            TextField("8-digit code", text: Binding(get: { pin }, set: { pin = $0; if !$0.isEmpty { paired = false } }), prompt: Text(verbatim: "12345678"))
                .textFieldStyle(DSTextFieldStyle(mono: true))
                .onSubmit { Task { await register() } }
            if paired {
                DSSuccessBadge(text: "Paired", fullWidth: true)
            } else {
                Button(working ? "Connecting…" : "Connect") { Task { await register() } }
                    .buttonStyle(DSButtonStyle(kind: .dark, fullWidth: true))
                    .disabled(working || host.isEmpty || pin.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(verbatim: error).font(.dsSmall).foregroundStyle(Color.dsLive).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button("Show Log File") { showLogFile() }.buttonStyle(.dsSecondary)
                    Button("Check What's Missing") { Task { await runChecks() } }.buttonStyle(.dsSecondary)
                }
            }
            Text("Always start the game on the PS5 with your main account. CouchSubs only watches the picture and never touches the game.")
                .dsMuted().padding(.top, DS.space("xs"))
        }
    }

    private func search() async {
        searching = true
        tips = false
        let started = Date()
        consoles = await model.discoverConsoles()
        if selected == nil { selected = consoles.first?.host }
        searching = false
        if consoles.isEmpty {
            let wait = max(0, 10 - Date().timeIntervalSince(started))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            withAnimation(DS.enter(400)) { tips = consoles.isEmpty }
        }
    }

    private func runChecks() async {
        checking = true
        checks = SetupCheck.Kind.allCases.map { SetupCheck(kind: $0, state: .unknown) }
        let found = await model.discoverConsoles()
        if !found.isEmpty { consoles = found }
        checks = SetupCheck.run(consoles: found)
        checking = false
    }

    private func register() async {
        guard !working, !host.isEmpty else { return }
        working = true
        error = nil
        do {
            try await model.register(host: host, pin: pin)
            paired = true
            pin = ""
        } catch {
            self.error = error.localizedDescription
        }
        working = false
        guard paired else { return }
        try? await Task.sleep(for: .seconds(1))
        model.continueAfterPairing()
    }

    private func showLogFile() {
        let file = RemotePlayLog.defaultFile
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }
}

private struct ConnectionRow: View {
    let title: LocalizedStringKey
    let sub: LocalizedStringKey
    let done: Bool

    var body: some View {
        HStack(spacing: DS.space("m")) {
            ZStack {
                Circle().fill(done ? Color.dsSuccess : Color.dsField)
                Image(systemName: done ? "checkmark" : "circle.dotted").font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(done ? Color.white : Color.dsFaint)
            }
            .frame(width: 28, height: 28)
            DSTitleBlock(title: title, subtitle: sub, titleFont: .dsBodyStrong)
        }
        .frame(minHeight: 48)
        .animation(DS.enter(300), value: done)
    }
}

/// 04 · PS5 Bulunamadı: denetimlerin sonucu (Geçti / Sorunlu / Bilinmiyor), PS5'in adresi ve Yeniden Dene.
private struct DiagnosticsView: View {
    let checks: [SetupCheck]
    let checking: Bool
    @Binding var manualHost: String
    let retry: () -> Void
    let connect: () -> Void
    let back: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard(spacing: DS.space("xs"), scrolls: false) {
                DSCardHeader("COULDN'T CONNECT TO THE PS5", color: .dsLive)
                Text("Here's What We Checked").font(.dsH3)
                Text("Fix the item with a problem and press Try Again. Things we couldn't read are shown as \"Unknown\".").dsMuted()
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: DS.space("m")) {
                        DSTitleBlock(title: title(check.kind), subtitle: checking ? nil : fix(check), titleFont: .dsBodyStrong)
                        if checking {
                            DSBadge(text: "Checking…")
                        } else {
                            DSBadge(text: check.state == .passed ? "Passed" : check.state == .problem ? "Problem" : "Unknown",
                                    tone: check.state == .passed ? .ok : check.state == .problem ? .warn : .unknown)
                        }
                    }
                    .padding(.vertical, DS.space("s"))
                    .overlay(alignment: .bottom) { DSDivider() }
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: DS.space("l")) {
                DSCard(scrolls: false) {
                    Text("Do You Know the PS5's Address?").font(.dsH3)
                    Text("On the PS5, the IP address is shown in Settings › Network › Connection Status.").dsMuted()
                    TextField("IP address, e.g. 192.168.1.20", text: $manualHost).textFieldStyle(DSTextFieldStyle(mono: true))
                    Button("Connect") { connect() }
                        .buttonStyle(DSButtonStyle(kind: .dark, fullWidth: true))
                        .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button(checking ? "Checking…" : "Try Again") { retry() }
                    .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(checking)
                Button("Back") { back() }.buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
                Text("If the problem continues, attach the log file to an issue on GitHub.").dsMuted()
            }
            .frame(width: 340)
        }
    }

    private func title(_ kind: SetupCheck.Kind) -> LocalizedStringKey {
        switch kind {
        case .sameNetwork: "Same Network"
        case .ps5Responds: "PS5 Responds"
        case .remotePlay: "Remote Play On"
        case .restModeInternet: "Internet in Rest Mode"
        case .wifi5GHz: "Wi-Fi 5 GHz"
        case .vpn: "VPN Off"
        }
    }

    private func fix(_ check: SetupCheck) -> LocalizedStringKey {
        switch (check.kind, check.state) {
        case (.sameNetwork, .passed): "This Mac and the PS5 appear to be on the same network."
        case (.sameNetwork, _): "This Mac isn't connected to a local network. Connect it to the same Wi-Fi as the PS5."
        case (.ps5Responds, .passed): "The PS5 was found."
        case (.ps5Responds, _): "The PS5 didn't answer the search. The PS5 must be on or in rest mode."
        case (.remotePlay, _): "On the second user, Settings › System › Remote Play › Enable Remote Play must be on."
        case (.restModeInternet, _): "Staying connected to the internet in rest mode must be on; otherwise the PS5 can't be woken up."
        case (.wifi5GHz, .passed): "You're on a 5 GHz network."
        case (.wifi5GHz, .problem): "This Mac is on a 2.4 GHz network. A 5 GHz network works more smoothly and reliably."
        case (.wifi5GHz, _): "This Mac is connected by cable or the Wi-Fi band couldn't be read."
        case (.vpn, .passed): "No active VPN was found."
        case (.vpn, _): "A VPN is on. Turn it off while playing; it can hide the PS5."
        }
    }
}

/// 05 · TV: eski TV adımının içeriği (arama, elle ekleme, Android TV, TV'm yok, kurulum kartı) ve TV'nin gösterdiği
/// eşleşme kodu iki ekranda: "TV'de Bu Kodu Görüyorum" ile onaylanır.
private struct TVWizardStep: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            TVStep().frame(maxWidth: .infinity)
            PairingCodeCard().frame(width: 340)
        }
    }
}

struct PairingCodeCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var approved = false

    var body: some View {
        DSCard(scrolls: false) {
            DSCardHeader("CODE SHOWN ON THE TV")
            if let ticket = model.tvPairingRequest {
                HStack(spacing: DS.space("xs")) {
                    ForEach(Array(ticket.code.enumerated()), id: \.offset) { _, digit in
                        Text(String(digit)).font(.system(size: 28, weight: .bold, design: .monospaced))
                            .frame(width: 44, height: 56)
                            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("control")))
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                Text("Do You See This Code on Your TV Too?").font(.dsBodyStrong)
                Text("If you see the same code, you're on the right TV. Approving completes the pairing.").dsMuted()
                Button("I See This Code on the TV") {
                    model.resolveTVPairing(ticket, accept: true)
                    approved = true
                }
                .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                Button("Reject") { model.resolveTVPairing(ticket, accept: false) }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            } else if approved || model.tvClients > 0 {
                DSSuccessBadge(text: "Paired", fullWidth: true)
                Text("Approve the code on the TV, then let's try it.").dsMuted()
            } else {
                Text("Open CouchSubs on the TV. When it shows a code, it appears here too.").dsMuted()
            }
        }
    }
}

/// 06 · TV Girişi (HDMI): dört giriş; seçim TV uygulamasına gider (style.hdmiInput, TV o girişi açar). "Bilmiyorum,
/// Sırayla Dene" girişleri sırayla açar, görüntü görülünce onaylanır.
private struct HDMIStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var trying = false
    @State private var confirmed = false

    var body: some View {
        let selected = model.settings.style.hdmiInput
        HStack(alignment: .top, spacing: DS.space("l")) {
            VStack(alignment: .leading, spacing: DS.space("m")) {
                HStack(spacing: DS.space("s")) {
                    ForEach(1...4, id: \.self) { port in
                        Button { choose(port, auto: false) } label: {
                            VStack(spacing: DS.space("xxs")) {
                                Text(verbatim: "HDMI").font(.dsMono).foregroundStyle(Color.dsMuted)
                                Text(verbatim: "\(port)").font(.system(size: 28, weight: .bold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 104)
                        }
                        .buttonStyle(DSOptionStyle(selected: selected == port && !trying, minHeight: 104, radio: false))
                    }
                }
                Button { choose(selected.map { $0 % 4 + 1 } ?? 1, auto: true) } label: {
                    DSTitleBlock(title: "I Don't Know, Try Them in Turn", subtitle: "We open the inputs one by one; you confirm when you see the picture.",
                                 titleFont: .dsBodyStrong)
                }
                .buttonStyle(DSOptionStyle(selected: trying, minHeight: 72))
                DSCard(scrolls: false) {
                    Text("How Do I Tell?").font(.dsBodyStrong)
                    Text("The number is printed on the back of the TV next to the port the PS5 cable is plugged into. If the PS5 is plugged into a sound system (soundbar, amplifier), choose the input the sound system is connected to.").dsMuted()
                }
            }
            .frame(maxWidth: .infinity)
            DSCard(scrolls: false) {
                if let selected {
                    DSBadge(text: LocalizedStringKey(trying ? String(format: String(localized: "HDMI %lld · Trying"), selected) : "HDMI \(selected)"), tone: .amber)
                }
                Text("Do You See the Game Picture on the TV?").font(.dsH3)
                if confirmed {
                    DSSuccessBadge(text: "Confirmed", fullWidth: true)
                } else {
                    Button("Yes") { confirmed = true; trying = false }
                        .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                        .disabled(selected == nil)
                    Button("No, Next Input") { choose((selected ?? 0) % 4 + 1, auto: trying) }
                        .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
                }
                Text("The choice is remembered. You can change it later in Settings › Consoles.").dsMuted()
            }
            .frame(width: 340)
        }
    }

    private func choose(_ port: Int, auto: Bool) {
        trying = auto
        confirmed = false
        model.settings.style.hdmiInput = port
        model.sendTestSubtitle()
    }
}

/// 08 · Deneyelim: bağlantı, görüntü, çeviri ve TV ayrı ayrı denenir; örnek altyazı gönderilir, görülünce kurulum biter.
private struct TryItStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var sent = false
    @State private var testing = false

    private var onComputer: Bool { model.settings.output == .computer }

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard(spacing: DS.space("xs"), scrolls: false) {
                CheckRow(title: model.isXbox ? "Xbox · Beta" : "PS5 Connection",
                         sub: model.console.map { $0.name.isEmpty ? "PS5" : $0.name } ?? model.pictureSourceName,
                         done: model.console != nil || model.readsCaptureWindow || model.isXbox)
                CheckRow(title: "Translation Working", sub: model.settings.translationEngine == .free ? String(localized: "Free Translation") : model.settings.translationEngine.displayName,
                         done: model.translatorStatus == .ready)
                CheckRow(title: onComputer ? "Subtitle on This Screen" : "TV Shows the Subtitle", sub: model.tv?.name ?? String(localized: "This Mac"),
                         done: sent && (onComputer || model.tvClients > 0))
                Button(testing ? "Testing…" : sent ? "Try Again" : "Send Test Subtitle") {
                    Task {
                        testing = true
                        await model.testSubtitle()
                        sent = true
                        testing = false
                    }
                }
                .buttonStyle(DSButtonStyle(kind: sent ? .secondary : .primary, fullWidth: true))
                .disabled(testing)
                .padding(.top, DS.space("s"))
                if !onComputer { HintText(text: LocalizedStringKey(TVOpenText.wizardNote)) }
            }
            .frame(maxWidth: .infinity)
            DSCard(scrolls: false) {
                DSScreenFrame {
                    VStack { Spacer(); DSSubtitleSample(speaker: "Lucia:", line: "Hazır olduğunda haber ver, gidiyoruz.", size: 15) }
                        .padding(DS.space("m"))
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                Text(onComputer ? "Do you see this subtitle on the screen?" : "Do you see this subtitle on the TV?").font(.dsBodyStrong)
                Button("Yes, I See It") {
                    model.commitOverlayEdit()
                    model.advance()
                }
                .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: true))
                .disabled(!sent)
                Button("I Don't See It") { model.step = .tv }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
                    .disabled(!sent)
                if onComputer {
                    Button("Position the Subtitles") { model.overlayAdjusting = true }.buttonStyle(.dsSecondary)
                }
            }
            .frame(width: 380)
        }
    }
}

private struct CheckRow: View {
    let title: LocalizedStringKey
    let sub: String
    let done: Bool

    var body: some View {
        HStack(spacing: DS.space("m")) {
            ZStack {
                Circle().fill(done ? Color.dsSuccess : Color.dsField)
                Image(systemName: done ? "checkmark" : "minus").font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(done ? Color.white : Color.dsFaint)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dsBodyStrong)
                Text(verbatim: sub).dsMuted()
            }
            Spacer()
        }
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { DSDivider() }
        .animation(DS.enter(300), value: done)
    }
}
