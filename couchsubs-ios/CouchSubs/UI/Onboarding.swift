// SPDX-License-Identifier: AGPL-3.0-only
// Karşılama ve kurulum (PSN girişi, PS5 eşleme, altyazının yeri). Onaylı tuvaldeki Telefon · 1–6 ekranları;
// uygulama hesap istemediği için kayıt/giriş ekranı yok.

import CouchSubsCore
import RemotePlay
import SwiftUI

// MARK: - 1–2 Karşılama (3 sayfa)

struct WelcomeFlow: View {
    let onFinish: () -> Void
    @EnvironmentObject private var model: PhoneModel
    @State private var page = 0

    var body: some View {
        MobileScreen {
            HStack {
                Spacer()
                Button("Skip", action: onFinish).buttonStyle(.mobileGhost)
            }
            .frame(height: Mobile.Control.icon)
        } content: {
            TabView(selection: $page) {
                pageOne.tag(0)
                pageTwo.tag(1)
                pageThree.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(minHeight: 500)
        } bottom: {
            PageDots(count: 3, current: page)
            Button(page == 2 ? "Let's start" : "Continue") {
                if page == 2 { onFinish() } else { withAnimation { page += 1 } }
            }
            .buttonStyle(.mobilePrimary)
            // Kurulumdan önce: konsolu olmayan (ve App Store incelemesi) uygulamayı örnek görüntülerle dener.
            DemoModeButton(kind: .ghost)
        }
        .perdeAmbient()
        // Ayarlar › Temel › Açılış Sesi: karşılama yalnız ilk açılışta görünür; ses Mac'teki açılış adımıyla aynı.
        .onAppear { if model.settings.startupSound { StartupChime.shared.play() } }
        .onDisappear { StartupChime.shared.stop() }
    }

    private var pageOne: some View {
        // Başlık üstte, görsel altında (küçük ekranda başlık düğmelerin altında kalmaz).
        VStack(alignment: .leading, spacing: Mobile.Space.unit) {
            ScreenTitle(title: "Turkish subtitles for PS5 games",
                        message: "Your phone reads the English subtitles in the game, translates them and shows them on the TV or on its own screen. You keep playing without putting the controller down.")
            Tile {
                Text(verbatim: "Are you listening to me?").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Text("Are you listening to me?").font(Mobile.TypeScale.headline)
                HStack(spacing: Mobile.Space.inline) {
                    MobilePill(text: String(localized: "PS5 connected"), dot: true)
                    MobilePill(text: String(localized: "Ready translation"), kind: .pro)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var pageTwo: some View {
        // Başlık üstte, görsel altında (küçük ekranda başlık düğmelerin altında kalmaz).
        VStack(alignment: .leading, spacing: Mobile.Space.unit) {
            ScreenTitle(title: "Instantly with ready packs",
                        message: "The whole text of popular games is already translated. Subtitles come without waiting, even offline. In other games the free translation works.")
            BentoGrid {
                Tile {
                    HStack(spacing: Mobile.Space.gap) {
                        GameMonogram(code: "GTA")
                        VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                            Text(verbatim: "Grand Theft Auto V").font(Mobile.TypeScale.headline)
                            Text("190 thousand lines ready").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                        }
                    }
                }
                .bentoWide()
                gameTile("RDR", "Red Dead 2", lines: 195)
                gameTile("MAF", "Mafia", lines: 18)
            }
            Spacer(minLength: 0)
        }
    }

    private var pageThree: some View {
        // Başlık üstte, görsel altında (küçük ekranda başlık düğmelerin altında kalmaz).
        VStack(alignment: .leading, spacing: Mobile.Space.unit) {
            ScreenTitle(title: "On the screen you want",
                        message: "Show the subtitles on the TV over the game, or in large text on your phone. Setup takes a few minutes.")
            BentoGrid {
                InfoTile(symbol: "tv", title: "On the TV", caption: "Over the game")
                InfoTile(symbol: "iphone", title: "On the phone", caption: "Next to the TV")
                InfoTile(symbol: "wifi", title: "The same Wi-Fi is enough", caption: "Keep the PS5, TV and phone on the same network")
                    .bentoWide()
            }
            Spacer(minLength: 0)
        }
    }

    private func gameTile(_ code: String, _ title: String, lines: Int) -> some View {
        Tile {
            GameMonogram(code: code)
            Spacer(minLength: Mobile.Space.inline)
            Text(verbatim: title).font(Mobile.TypeScale.headline)
            Text(PacksScreen.linesText(lines * 1000)).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        }
    }
}

// MARK: - Kurulum adımları (4–6)

/// "Kurulum · Adım n/3" ve üç parçalı ilerleme çubuğu.
struct SetupHeader: View {
    let step: Int
    let onBack: (() -> Void)?
    /// Kurulumda "Şimdilik geç" (PSN ve PS5 adımları); ana ekrandan açılınca nil.
    var onSkip: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            HStack(spacing: Mobile.Space.gap) {
                if let onBack { IconButton(symbol: "chevron.left", label: "Back", action: onBack) }
                HStack(spacing: Mobile.Space.hair) {
                    ForEach(1...3, id: \.self) { index in
                        Capsule().fill(index <= step ? Mobile.Palette.accent : Mobile.Palette.borderStrong).frame(height: 4)
                            .shadow(color: index <= step ? Color.dsAmberGlow : .clear, radius: 4)
                    }
                }
                if let onSkip { Button("Skip for Now", action: onSkip).buttonStyle(.mobileGhost).fixedSize() }
            }
            .frame(height: Mobile.Control.icon)
        }
    }
}

struct PSNScreen: View {
    @EnvironmentObject private var model: PhoneModel
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    var onDone: () -> Void
    @State private var showLogin = false
    @State private var showWhy = false
    @State private var redirected = false
    @State private var working = false
    @State private var error: String?
    /// Giriş sayfası açılamadı ya da Sony hata kodu döndürdü; eskiden yok sayılıyor, sayfa beyaz kalıyordu (TestFlight).
    @State private var pageProblem: String?
    @State private var pageAttempt = 0
    /// Uygulama içi giriş Sony'nin "Can't connect to the server" hatasında kalırsa giriş tarayıcıda yapılır, yönlendirme
    /// adresi buraya yapıştırılır (Windows, Mac ve Android'deki "Tarayıcıda giriş yap" ile aynı akış).
    @State private var showBrowser = false
    /// Hesap kartındaki "Diğer Giriş Yolları" açık mı.
    @State private var showOtherWays = false
    /// Tarayıcıya uygulama içi sayfa sunucusuna bağlanamadığı için geçildi (nedeni de yazılır).
    @State private var browserAutomatic = false
    @State private var browserURL = ""
    @State private var browserError: String?
    /// Son denenen yönlendirme adresi: tek kullanımlık kod panodan ikinci kez denenmez.
    @State private var lastBrowserRedirect: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MobileScreen {
            SetupHeader(step: 1, onBack: onBack, onSkip: onSkip)
        } content: {
            ScreenTitle(caption: "Setup · Step 1/3", title: "Second PSN account",
                        message: "The phone connects to the PS5 with Remote Play. Sign in with a free second PSN account, separate from the one you play with.")
            BentoGrid {
                InfoTile(symbol: "person.badge.plus", title: "Free account", caption: "No PS Plus needed")
                InfoTile(symbol: "gamecontroller", title: "You play", caption: "With your own account, on the TV")
                InfoTile(symbol: "lock.shield", title: "We don't keep your password", caption: "You sign in on Sony's page")
                    .bentoWide()
            }
            // Kol ikinci hesaba atanırsa ana hesapla açılan oyun onu kendi kolu saymaz (GitHub #231).
            MobileNote(text: String(localized: "When you turn on the controller to play, choose your MAIN account on the PS5. Don't play with the second account CouchSubs signs in with, or the controller will turn off by itself or won't work in the game."))
            accountBlock
            if working { ProgressView().tint(Mobile.Palette.accentText) }
            if let error { MobileNote(text: error) }
            if showBrowser {
                if browserAutomatic {
                    MobileNote(text: String(localized: "Sony's sign-in page could not reach its server inside the app, so sign-in moved to your browser."))
                }
                MobileNote(text: String(localized: "Sign in with your second account in the browser that opened. When you finish, the browser stays on a remoteplay.dl.playstation.net page that only says redirect. Tap the address bar, copy the whole address and come back here. CouchSubs picks up the copied address by itself; if it does not, paste it below and tap Save."))
                TextField("", text: $browserURL)
                    .textFieldStyle(MobileFieldStyle())
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(submitBrowser)
                if let browserError { MobileNote(text: browserError) }
                Button("Save", action: submitBrowser).buttonStyle(.mobileSecondary).disabled(working)
                Button("Open the browser again") { openURL(PSNAccount.authorizeURL) }.buttonStyle(.mobileGhost)
            }
        } bottom: {
            // Giriş kartın içinde; adımın ana düğmesi giriş yapılınca açılır.
            Button("Continue", action: onDone).buttonStyle(.mobilePrimary).disabled(model.accountId == nil || working)
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            guard !redirected else { return }
            error = pageProblem.map { String(format: String(localized: "Sony's sign-in page could not be opened (%@). Check the phone's internet connection and try again."), $0) }
                ?? PhoneError.loginWindowClosed.localizedDescription
        }) {
            NavigationStack {
                ZStack {
                    LoginWebView(onRedirect: received, onProblem: { pageProblem = $0 }, reloadToken: pageAttempt, onUnreachable: {
                        // Sony'nin sayfası uygulama içinde sunucusuna bağlanamadı; aynı giriş tarayıcıda çalışıyor.
                        redirected = true
                        showLogin = false
                        openBrowserLogin(automatic: true)
                    })
                    if let pageProblem { loginProblem(pageProblem) }
                }
                .navigationTitle(Text(verbatim: "PlayStation Network"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showLogin = false } }
                    // Sayfa boş kalırsa kullanıcı her zaman baştan yükleyebilir.
                    ToolbarItem(placement: .primaryAction) {
                        Button { retryLogin() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(Text("Reload"))
                    }
                }
            }
            .presentationDragIndicator(.visible)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { takeRedirectFromPasteboard() }
        }
        .sheet(isPresented: $showWhy) {
            VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                ScreenTitle(title: "Why a second account?",
                            message: "Remote Play with your own account would take over your controller and stop your game. With a second, free account the PS5 lets the phone watch the picture while you keep playing on the TV. Create it on the PS5 (Add User) or at playstation.com.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Mobile.Space.screen)
            .fittedSheet()
            .sheetBackground(Mobile.Palette.surface)
        }
    }

    /// Kompakt hesap kartı: solda yuvarlak PlayStation simgesi, ortada "PlayStation Hesabı" ve altında durum (yeşil nokta
    /// "Giriş Yapıldı" ya da gri nokta "Giriş Yapılmadı"), sağda kartın içinde küçük "Yeniden Giriş Yap" ya da birincil
    /// "Giriş Yap". Altta ince ayraç ve "Diğer Giriş Yolları ›"; açılınca seçenekler kartın içinde.
    private var accountBlock: some View {
        let signedIn = model.accountId != nil
        return Tile(spacing: Mobile.Space.gap) {
            HStack(spacing: Mobile.Space.gap) {
                Image(systemName: "playstation.logo")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(Mobile.Palette.text)
                    .frame(width: 40, height: 40)
                    .background(Mobile.Palette.surface2, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Mobile.Space.micro) {
                    Text("PlayStation Account").font(Mobile.TypeScale.headline).foregroundStyle(Mobile.Palette.text)
                    HStack(spacing: Mobile.Space.titleToBody) {
                        Circle().fill(signedIn ? Mobile.Palette.success : Mobile.Palette.tertiary).frame(width: 8, height: 8)
                        Text(signedIn ? "Signed In" : "Not Signed In").font(Mobile.TypeScale.caption)
                            .foregroundStyle(signedIn ? Mobile.Palette.successText : Mobile.Palette.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Mobile.Space.inline)
                if signedIn {
                    Button("Sign In Again", action: openLogin)
                        .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: false))
                        .disabled(working)
                } else {
                    Button("Sign In", action: openLogin)
                        .buttonStyle(DSButtonStyle(kind: .primary, fullWidth: false))
                        .disabled(working)
                }
            }
            RowDivider()
            DisclosureGroup(isExpanded: $showOtherWays) {
                VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                    if !showBrowser {
                        Button("Sign In in the Browser") { openBrowserLogin(automatic: false) }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                            .disabled(working)
                    }
                    Button("Why a second account?") { showWhy = true }.buttonStyle(.mobileGhost)
                }
                .padding(.top, Mobile.Space.gap)
            } label: {
                Text("Other Sign-In Ways").font(Mobile.TypeScale.caption.weight(.medium)).foregroundStyle(Mobile.Palette.secondary)
            }
            .tint(Mobile.Palette.secondary)
        }
    }

    private func openLogin() {
        redirected = false
        pageProblem = nil
        showLogin = true
    }

    private func loginProblem(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            MobileNote(text: String(format: String(localized: "Sony's sign-in page could not be opened (%@). Check the phone's internet connection and try again."), problem))
            Button("Try Again") { retryLogin() }.buttonStyle(.mobilePrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(Mobile.Space.screen)
        .background(Mobile.Palette.surface)
    }

    private func retryLogin() {
        pageProblem = nil
        pageAttempt += 1
    }

    /// Sony'nin giriş sayfası Safari'de açılır, adres yapıştırma alanı görünür.
    private func openBrowserLogin(automatic: Bool) {
        showBrowser = true
        browserAutomatic = automatic
        browserError = nil
        error = nil
        openURL(PSNAccount.authorizeURL)
    }

    /// Kullanıcı tarayıcıdan dönünce panoda adres varsa kendiliğinden alınır (iOS yapıştırma iznini kendisi sorar).
    private func takeRedirectFromPasteboard() {
        guard showBrowser, !working, UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs,
              let redirect = PSNAccount.redirect(fromPastedText: UIPasteboard.general.string),
              redirect.absoluteString != lastBrowserRedirect else { return }
        browserURL = redirect.absoluteString
        submitBrowser()
    }

    private func submitBrowser() {
        guard !working else { return }
        guard let redirect = PSNAccount.redirect(fromPastedText: browserURL) else {
            browserError = String(localized: "This address has no sign-in code. It should start with https://remoteplay.dl.playstation.net/remoteplay/redirect?code=")
            return
        }
        browserError = nil
        lastBrowserRedirect = redirect.absoluteString
        browserURL = ""
        showBrowser = false
        received(redirect)
    }

    private func received(_ url: URL) {
        redirected = true
        showLogin = false
        working = true
        error = nil
        Task {
            do {
                try await model.completePSNLogin(redirect: url)
                onDone()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

struct PS5PairScreen: View {
    @EnvironmentObject private var model: PhoneModel
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    var onDone: () -> Void
    @State private var consoles: [ConsoleInfo] = []
    @State private var manualHost = ""
    @State private var pin = ""
    @State private var searching = false
    @State private var working = false
    @State private var error: String?
    @State private var showManual = false
    /// Perde başarı anı: "Eşleşti" (ışın + yaylı tik + başarı titreşimi), ardından sonraki adım.
    @State private var paired = false
    @FocusState private var codeFocused: Bool

    private var host: String {
        let typed = manualHost.trimmingCharacters(in: .whitespaces)
        // Virgüllü yazım ("192,168,1,20"), "http://…" ya da port temizlenir.
        return typed.isEmpty ? consoles.first?.host ?? "" : ManualAddress.normalize(typed) ?? typed.replacingOccurrences(of: ",", with: ".")
    }

    var body: some View {
        MobileScreen {
            SetupHeader(step: 2, onBack: onBack, onSkip: onSkip)
        } content: {
            ScreenTitle(caption: "Setup · Step 2/3", title: "Pair the PS5",
                        message: "On the PS5, with the second account, choose Settings › System › Remote Play › Pair Device and type the code on the screen.")
            Tile {
                HStack(spacing: Mobile.Space.gap) {
                    MobileTileIcon(symbol: "gamecontroller.fill")
                    VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                        if let found = consoles.first, manualHost.isEmpty {
                            Text(String(format: String(localized: "%@ found"), found.name)).font(Mobile.TypeScale.headline)
                            Text(String(format: String(localized: "%@ · same Wi-Fi"), found.host)).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                        } else if !manualHost.isEmpty {
                            Text(verbatim: "PS5").font(Mobile.TypeScale.headline)
                            Text(verbatim: manualHost).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                        } else {
                            Text(searching ? "Looking for the PS5…" : "No PS5 found").font(Mobile.TypeScale.headline)
                            Text("Turn on the PS5 and keep it on the same Wi-Fi").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                        }
                    }
                    Spacer()
                    if !host.isEmpty && !searching {
                        MobileLiveDot(pulses: false)
                    } else {
                        SearchAgainButton(searching: searching) { Task { await search() } }
                    }
                }
            }
            Tile(spacing: Mobile.Space.inline) {
                Text("Pairing code").font(Mobile.TypeScale.headline)
                ZStack {
                    TextField("", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($codeFocused)
                        .opacity(0.01)
                        .onChange(of: pin) { value in pin = String(value.filter(\.isNumber).prefix(8)) }
                    HStack(spacing: Mobile.Space.hair + 2) {
                        ForEach(0..<8, id: \.self) { index in
                            let digits = Array(pin)
                            Text(verbatim: index < digits.count ? String(digits[index]) : "")
                                .font(Mobile.TypeScale.title)
                                .frame(maxWidth: .infinity, minHeight: Mobile.Control.field)
                                .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.control, style: .continuous)
                                    .strokeBorder(index == digits.count && codeFocused ? Mobile.Palette.accent : Mobile.Palette.border,
                                                  lineWidth: index == digits.count && codeFocused ? 2 : 1))
                        }
                    }
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture { codeFocused = true }
                if let error {
                    MobileNote(text: error)
                } else {
                    Text("The code is valid for 5 minutes. If something goes wrong, the reason is shown here.").dsMuted()
                }
            }
            // PS5 bağlıyken "Uzaktan Oynama bağlandı" yazısı kalıcıdır; bildirim ayarı değil, bu ayar gizler (GitHub #177).
            InfoBox(text: String(localized: "To hide the \"Remote Play connected\" message on the screen: on the PS5, go to Settings › System › Remote Play and turn on Hide Remote Play Connection Status Pop-Up. Do it for both your main account and the second account."),
                    tone: Mobile.Palette.secondary)
            if working {
                HStack(spacing: Mobile.Space.inline) {
                    ProgressView().tint(Mobile.Palette.accentText)
                    Text("Connecting to the PS5… This can take up to 30 seconds.").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
            }
        } bottom: {
            Button("Can't Find the PS5?") { showManual = true }.buttonStyle(.mobileGhost)
            Button("Pair") { Task { await register() } }
                .buttonStyle(.mobilePrimary)
                .disabled(working || pin.count != 8 || host.isEmpty)
        }
        .overlay {
            if paired {
                PerdeSuccessOverlay(title: "Paired", message: consoles.first(where: { $0.host == host })?.name ?? host)
            }
        }
        .perdeAmbient()
        .task { await search() }
        .sheet(isPresented: $showManual) {
            VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                ScreenTitle(title: "Can't find the PS5?",
                            message: "Make sure the PS5 is on (not in rest mode) and on the same Wi-Fi, and that CouchSubs is allowed in Settings › Privacy & Security › Local Network. You can also type the PS5's IP address (PS5: Settings › Network › Connection Status).")
                TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                    .textFieldStyle(MobileFieldStyle())
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Search Again") { Task { await search() } }.buttonStyle(.mobileSecondary)
                Button("Done") { showManual = false }.buttonStyle(.mobilePrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Mobile.Space.screen)
            .fittedSheet()
            .sheetBackground(Mobile.Palette.surface)
        }
    }

    private func search() async {
        guard !searching else { return }
        searching = true
        consoles = await model.discoverConsoles()
        searching = false
    }

    private func register() async {
        guard !working else { return }
        working = true
        error = nil
        do {
            try await model.register(host: host, pin: pin)
            withAnimation(.easeOut(duration: 0.2)) { paired = true }
            try? await Task.sleep(nanoseconds: UInt64(DSCelebration.duration * 1_100_000_000))
            onDone()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
        working = false
    }
}

/// Altyazının yeri: ağdaki TV'ler (TV uygulaması kurulu) ya da bu telefon. Ayarlar › Altyazı hedefi de burayı açar.
struct TargetScreen: View {
    @EnvironmentObject private var model: PhoneModel
    var setup = true
    var onBack: (() -> Void)?
    var onDone: () -> Void
    @State private var tvs: [LGTV] = []
    @State private var launched: [LGTV: Bool] = [:]
    @State private var searching = false
    @State private var working: LGTV?
    @State private var error: String?
    @State private var showManual = false
    @State private var manualHost = ""
    @State private var manualBrand = TVBrand.lg
    /// Elle yazılan adres geçersizse sayfada gösterilen ileti.
    @State private var manualError: String?
    @State private var showInstall = false

    var body: some View {
        MobileScreen {
            if setup { SetupHeader(step: 3, onBack: onBack) } else { BackHeader(title: "Subtitle target") }
        } content: {
            ScreenTitle(caption: setup ? "Setup · Step 3/3" : nil, title: "Where are the subtitles?",
                        message: "You can change this later on the home screen.")
            Tile(emphasis: model.settings.output == .tv && model.hasTV ? .selected : .none) {
                HStack(spacing: Mobile.Space.gap) {
                    MobileTileIcon(symbol: "tv")
                    Text("On the TV, over the game").font(Mobile.TypeScale.headline)
                    Spacer()
                    if !allTVs.isEmpty {
                        SearchAgainButton(searching: searching) { Task { await search() } }
                    }
                }
                ForEach(allTVs, id: \.self) { tv in
                    RowDivider()
                    Button { Task { await pair(tv) } } label: { tvRow(tv) }.buttonStyle(.plain).disabled(working != nil)
                }
                if allTVs.isEmpty {
                    // Bulunamayınca ne yapılacağı da söylenir: TV uygulaması kurulu değilse buradan kurulur; monitör ya da
                    // akıllı olmayan TV'de altyazı bu telefonda gösterilir (kullanıcı monitörde "Ağda TV bulunamadı"da kalmıştı).
                    HStack(spacing: Mobile.Space.gap) {
                        Text(searching ? "Looking for the TV on the network…" : "No TV found on the network. If the CouchSubs app is not on the TV, install it from this phone below. Using a monitor or a non-smart TV? Choose On this phone.")
                            .dsMuted()
                        Spacer()
                        SearchAgainButton(searching: searching) { Task { await search() } }
                    }
                }
            }
            BentoGrid {
                Button { model.settings.output = .computer } label: {
                    InfoTile(symbol: "iphone", title: "On this phone", caption: "No TV, or the app is not installed",
                             emphasis: model.settings.output == .computer ? .selected : .none, option: true)
                }
                .buttonStyle(.plain)
                // Mac ve Windows'taki "İkisi de": altyazı hem TV'de hem bu telefonda görünür (TV eşleşmişken seçilir).
                Button { model.settings.output = .both } label: {
                    InfoTile(symbol: "rectangle.on.rectangle", title: "Both", caption: "On the TV and on this phone",
                             emphasis: model.settings.output == .both && model.hasTV ? .selected : .none, option: true)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasTV)
                // Mac ve Windows'taki "Yalnız OBS (yayın)": TV aranmaz, bu telefonda altyazı ekranı açılmaz; altyazı yalnız aynı
                // Wi-Fi'daki bilgisayarda OBS'in tarayıcı kaynağına gider (Android ile aynı).
                Button { model.settings.output = .obs } label: {
                    InfoTile(symbol: "dot.radiowaves.left.and.right", title: "OBS only (stream)", caption: "To OBS on a computer on the same Wi-Fi",
                             emphasis: model.settings.output == .obs ? .selected : .none, option: true)
                }
                .buttonStyle(.plain)
                Button { showManual = true } label: {
                    InfoTile(symbol: "questionmark.circle", title: "My TV is not listed", caption: "Supported TVs", chevron: true)
                }
                .buttonStyle(.plain)
            }
            // TV uygulaması yoksa ya da eskiyse bu telefondan kurulur (ilk kurulumda da).
            Button { showInstall = true } label: {
                InfoTile(symbol: "arrow.down.app", title: "Install the TV app from this phone", caption: "Samsung · LG · Android TV · Vestel",
                         emphasis: model.tvAppMissing ? .warning : .none, chevron: true)
            }
            .buttonStyle(.plain)
            if model.settings.output == .obs { OBSOnlyTile() }
            // TV'si olmayan ya da monitörde oynayan için: hangi hedef seçilirse seçilsin altyazı ayrıca bir tarayıcıda da görünür.
            SecondScreenTile()
            if let error { MobileNote(text: error) }
            // TV kurulumu bitti: her çeviride TV uygulaması kendiliğinden açılmaya çalışılır; açılmazsa TV'den açılır.
            if setup, model.hasTV, model.settings.output.showsOnTV {
                Text(LocalizedStringKey(TVOpenText.wizardNote)).dsMuted()
            }
        } bottom: {
            Button(setup ? "Continue" : "Done", action: onDone)
                .buttonStyle(.mobilePrimary)
                .disabled(!(model.hasTV || !model.settings.output.showsOnTV))
        }
        .task { await search() }
        .sheet(isPresented: $showManual) { manualSheet }
        .sheet(isPresented: $showInstall, onDismiss: { Task { await search() } }) {
            // Kurulum bitince sayfa kapanır ve TV eşlendiyse bu adım da geçilir (Android'de ana ekrana geçilir, #113).
            TVInstallScreen(onDone: {
                showInstall = false
                if !setup || model.canAdvance { onDone() }
            }).environmentObject(model)
        }
    }

    private var allTVs: [LGTV] {
        var list = tvs
        if let tv = model.tv, model.hasTV, !list.contains(where: { $0.host == tv.host && $0.brand == tv.brand }) { list.insert(tv, at: 0) }
        return list
    }

    private func tvRow(_ tv: LGTV) -> some View {
        let selected = model.hasTV && model.tv?.host == tv.host && model.tv?.brand == tv.brand && model.settings.output.showsOnTV
        let ready = launched[tv] ?? (selected ? !model.tvAppMissing : nil)
        return HStack(spacing: Mobile.Space.gap) {
            DSRadio(on: selected)
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(verbatim: tv.name).font(Mobile.TypeScale.headline)
                Text(verbatim: Self.brandName(tv.brand) + (ready == true ? " · " + String(localized: "CouchSubs installed") : ready == false ? " · " + String(localized: "no app") : ""))
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
            Spacer()
            if working == tv {
                ProgressView().tint(Mobile.Palette.accent)
            } else if selected, model.tvClients > 0 {
                // "Bağlı" yalnız TV uygulaması gerçekten bağlıyken görünür. Eskiden uygulama kuruluysa "Hazır" yazıyordu;
                // TV uygulaması telefona hiç bağlanmamışken de (TestFlight, #672) her şey yolunda sanılıyordu.
                MobilePill(text: String(localized: "Connected"), dot: true)
            } else if ready == true {
                MobilePill(text: String(localized: "Installed"))
            } else if ready == false {
                MobilePill(text: String(localized: "Not installed"))
            }
        }
        .frame(minHeight: Mobile.Control.row)
        .contentShape(Rectangle())
    }

    static func brandName(_ brand: TVBrand) -> String {
        switch brand {
        case .lg: "LG"
        case .samsung: "Samsung"
        case .androidTV: "Android TV"
        case .vestelLinux: "Vestel Linux"
        }
    }

    private var manualSheet: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            ScreenTitle(title: "My TV is not listed",
                        message: "CouchSubs works with LG (webOS 4+), Samsung (Tizen, 2019+) and Android TV / Google TV. Type the TV's IP address, or choose Android TV: its CouchSubs app finds this phone by itself.")
            SegmentedTabs(options: [TVBrand.lg: "LG", .samsung: "Samsung", .androidTV: "Android TV", .vestelLinux: "Vestel"], selection: $manualBrand)
            if manualBrand != .androidTV {
                TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                    .textFieldStyle(MobileFieldStyle())
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if manualBrand != .androidTV, let manualError { MobileNote(text: manualError) }
            Link("Supported TVs", destination: AppIdentity.tvGuideURL).font(Mobile.TypeScale.caption).tint(Mobile.Palette.accentText)
            Button("Connect") {
                // Adres temizlenir ("192.168.1.5:3000", "http://…", virgüllü yazım); geçersizse sayfa açık kalır ve
                // söylenir. Eskiden olduğu gibi bağlanmaya gönderilen bozuk adres uygulamayı kapatıyordu.
                let host: String
                if manualBrand == .androidTV {
                    host = ""
                } else if let valid = ManualAddress.normalize(manualHost) {
                    host = valid
                } else {
                    manualError = String(localized: "This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number.")
                    return
                }
                manualError = nil
                showManual = false
                Task {
                    await pair(LGTV(name: manualBrand == .androidTV ? "Android TV" : host, host: host, brand: manualBrand))
                    // Vestel Linux'ta TV'de kurulu uygulama yok: istemci bu telefondan kurulur (adres dolu açılır).
                    if manualBrand == .vestelLinux, model.tv?.brand == .vestelLinux { showInstall = true }
                }
            }
            .buttonStyle(.mobilePrimary)
            .disabled(manualBrand != .androidTV && manualHost.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Mobile.Space.screen)
        .fittedSheet()
        .sheetBackground(Mobile.Palette.surface)
    }

    private func search() async {
        guard !searching else { return }
        searching = true
        tvs = await model.discoverTVs()
        searching = false
    }

    private func pair(_ tv: LGTV) async {
        working = tv
        error = nil
        do {
            try await model.pair(tv)
            launched[tv] = !model.tvAppMissing
        } catch {
            self.error = String(localized: "Could not connect to the TV. Accept the request on the TV screen and try again.")
        }
        working = nil
    }
}

/// PS5 ve TV aramasının yanındaki "Yeniden ara" düğmesi; ararken aynı yerde dönen gösterge durur.
struct SearchAgainButton: View {
    let searching: Bool
    let action: () -> Void

    var body: some View {
        if searching {
            ProgressView()
                .tint(Mobile.Palette.accent)
                .frame(width: Mobile.Control.icon, height: Mobile.Control.icon)
        } else {
            IconButton(symbol: "arrow.clockwise", label: "Search again", tint: Mobile.Palette.accentText, action: action)
        }
    }
}

/// "Yalnız OBS (yayın)" seçiliyken: OBS'in tarayıcı kaynağına yazılacak adres (bu telefonun ağ adresiyle) ve kopyala düğmesi.
private struct OBSOnlyTile: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Tile {
            SectionTitle("OBS overlay")
            DSCopyField(text: model.subtitleViewerAddress)
            Text("Subtitles go only to OBS. The TV is not searched for and this phone shows no subtitle screen. In OBS on a computer on the same Wi-Fi, add a Browser source with this address (width 1920, height 1080).")
                .dsMuted()
        }
    }
}
