// SPDX-License-Identifier: AGPL-3.0-only
// Karşılama ve kurulum (PSN girişi, PS5 eşleme, altyazının yeri). Onaylı tuvaldeki Telefon · 1–6 ekranları;
// uygulama hesap istemediği için kayıt/giriş ekranı yok.

import CouchSubsCore
import RemotePlay
import SwiftUI

// MARK: - 1–2 Karşılama (3 sayfa)

struct WelcomeFlow: View {
    let onFinish: () -> Void
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
            .frame(minHeight: 560)
        } bottom: {
            PageDots(count: 3, current: page)
            Button(page == 2 ? "Let's start" : "Continue") {
                if page == 2 { onFinish() } else { withAnimation { page += 1 } }
            }
            .buttonStyle(.mobilePrimary)
        }
    }

    private var pageOne: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            Spacer(minLength: 0)
            Tile {
                Text(verbatim: "Are you listening to me?").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Text("Are you listening to me?").font(Mobile.TypeScale.headline)
                HStack(spacing: Mobile.Space.inline) {
                    MobilePill(text: String(localized: "PS5 connected"), dot: true)
                    MobilePill(text: String(localized: "Ready translation"), kind: .pro)
                }
            }
            ScreenTitle(title: "Turkish subtitles for PS5 games",
                        message: "Your phone reads the English subtitles in the game, translates them and shows them on the TV or on its own screen. You keep playing without putting the controller down.")
        }
    }

    private var pageTwo: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            Spacer(minLength: 0)
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
            ScreenTitle(title: "Instantly with ready packs",
                        message: "The whole text of popular games is already translated. Subtitles come without waiting, even offline. In other games the free translation works.")
        }
    }

    private var pageThree: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            Spacer(minLength: 0)
            BentoGrid {
                InfoTile(symbol: "tv", title: "On the TV", caption: "Over the game")
                InfoTile(symbol: "iphone", title: "On the phone", caption: "Next to the TV")
                InfoTile(symbol: "wifi", title: "The same Wi-Fi is enough", caption: "Keep the PS5, TV and phone on the same network")
                    .bentoWide()
            }
            ScreenTitle(title: "On the screen you want",
                        message: "Show the subtitles on the TV over the game, or in large text on your phone. Setup takes a few minutes.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            HStack(spacing: Mobile.Space.gap) {
                if let onBack { IconButton(symbol: "chevron.left", label: "Back", action: onBack) }
                HStack(spacing: Mobile.Space.hair) {
                    ForEach(1...3, id: \.self) { index in
                        Capsule().fill(index <= step ? Mobile.Palette.accent : Mobile.Palette.borderStrong).frame(height: 4)
                    }
                }
            }
            .frame(height: Mobile.Control.icon)
        }
    }
}

struct PSNScreen: View {
    @EnvironmentObject private var model: PhoneModel
    var onBack: (() -> Void)?
    var onDone: () -> Void
    @State private var showLogin = false
    @State private var showWhy = false
    @State private var redirected = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        MobileScreen {
            SetupHeader(step: 1, onBack: onBack)
        } content: {
            ScreenTitle(caption: "Setup · Step 1/3", title: "Second PSN account",
                        message: "The phone connects to the PS5 with Remote Play. Sign in with a free second PSN account, separate from the one you play with.")
            BentoGrid {
                InfoTile(symbol: "person.badge.plus", title: "Free account", caption: "No PS Plus needed")
                InfoTile(symbol: "gamecontroller", title: "You play", caption: "With your own account, on the TV")
                InfoTile(symbol: "lock.shield", title: "We don't keep your password", caption: "You sign in on Sony's page")
                    .bentoWide()
            }
            if model.accountId != nil { MobilePill(text: String(localized: "Signed in"), dot: true) }
            if working { ProgressView().tint(Mobile.Palette.accent) }
            if let error { MobileNote(text: error) }
        } bottom: {
            Button("Why a second account?") { showWhy = true }.buttonStyle(.mobileGhost)
            if model.accountId != nil {
                Button("Sign in again") {
                    redirected = false
                    showLogin = true
                }
                .buttonStyle(.mobileSecondary)
                Button("Continue", action: onDone).buttonStyle(.mobilePrimary)
            } else {
                Button("Sign in with Sony") {
                    redirected = false
                    showLogin = true
                }
                .buttonStyle(.mobilePrimary)
                .disabled(working)
            }
        }
        .sheet(isPresented: $showLogin, onDismiss: {
            if !redirected { error = PhoneError.loginWindowClosed.localizedDescription }
        }) {
            NavigationStack {
                LoginWebView(onRedirect: received, onProblem: { _ in })
                    .navigationTitle(Text(verbatim: "PlayStation Network"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showLogin = false } } }
            }
            .presentationDragIndicator(.visible)
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
    var onDone: () -> Void
    @State private var consoles: [ConsoleInfo] = []
    @State private var manualHost = ""
    @State private var pin = ""
    @State private var searching = false
    @State private var working = false
    @State private var error: String?
    @State private var showManual = false
    @FocusState private var codeFocused: Bool

    private var host: String {
        let typed = manualHost.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? consoles.first?.host ?? "" : typed
    }

    var body: some View {
        MobileScreen {
            SetupHeader(step: 2, onBack: onBack)
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
                    if searching { ProgressView().tint(Mobile.Palette.accent) } else if !host.isEmpty { MobileLiveDot(pulses: false) }
                }
            }
            Tile {
                Text("Pairing code").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
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
                                .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.inner))
                                .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.inner)
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
                    Text("The code is valid for 5 minutes. If something goes wrong, the reason is shown here.")
                        .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
            }
            if working {
                HStack(spacing: Mobile.Space.inline) {
                    ProgressView().tint(Mobile.Palette.accent)
                    Text("Connecting to the PS5… This can take up to 30 seconds.").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
            }
        } bottom: {
            Button("Can't find the PS5?") { showManual = true }.buttonStyle(.mobileGhost)
            Button("Pair") { Task { await register() } }
                .buttonStyle(.mobilePrimary)
                .disabled(working || pin.count != 8 || host.isEmpty)
        }
        .task { await search() }
        .sheet(isPresented: $showManual) {
            VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                ScreenTitle(title: "Can't find the PS5?",
                            message: "Make sure the PS5 is on (not in rest mode) and on the same Wi-Fi, and that CouchSubs is allowed in Settings › Privacy & Security › Local Network. You can also type the PS5's IP address (PS5: Settings › Network › Connection Status).")
                TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                    .textFieldStyle(MobileFieldStyle())
                    .keyboardType(.decimalPad)
                Button("Search again") { Task { await search() } }.buttonStyle(.mobileSecondary)
                Button("Done") { showManual = false }.buttonStyle(.mobilePrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Mobile.Space.screen)
            .fittedSheet()
            .sheetBackground(Mobile.Palette.surface)
        }
    }

    private func search() async {
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
            onDone()
        } catch {
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

    var body: some View {
        MobileScreen {
            if setup { SetupHeader(step: 3, onBack: onBack) } else { BackHeader(title: "Subtitle target") }
        } content: {
            ScreenTitle(caption: setup ? "Setup · Step 3/3" : nil, title: "Where are the subtitles?",
                        message: "You can change this later on the home screen.")
            Tile(emphasis: model.settings.output.showsOnTV && model.hasTV ? .selected : .none) {
                HStack(spacing: Mobile.Space.gap) {
                    MobileTileIcon(symbol: "tv")
                    Text("On the TV, over the game").font(Mobile.TypeScale.headline)
                    Spacer()
                    if searching { ProgressView().tint(Mobile.Palette.accent) }
                }
                ForEach(allTVs, id: \.self) { tv in
                    RowDivider()
                    Button { Task { await pair(tv) } } label: { tvRow(tv) }.buttonStyle(.plain).disabled(working != nil)
                }
                if allTVs.isEmpty && !searching {
                    Text("No TV found on the network.").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
            }
            BentoGrid {
                Button { model.settings.output = .computer } label: {
                    InfoTile(symbol: "iphone", title: "On this phone", caption: "No TV, or the app is not installed",
                             emphasis: model.settings.output == .computer ? .selected : .none)
                }
                .buttonStyle(.plain)
                Button { showManual = true } label: {
                    InfoTile(symbol: "questionmark.circle", title: "My TV is not listed", caption: "Supported TVs")
                }
                .buttonStyle(.plain)
            }
            if model.tvAppMissing {
                MobileNote(text: String(localized: "To install the TV app for the first time, use CouchSubs on a computer once. After that this phone is enough."))
            }
            if let error { MobileNote(text: error) }
        } bottom: {
            Button(setup ? "Continue" : "Done", action: onDone)
                .buttonStyle(.mobilePrimary)
                .disabled(!(model.hasTV || model.settings.output == .computer))
        }
        .task { await search() }
        .sheet(isPresented: $showManual) { manualSheet }
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
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Mobile.Palette.accent : Mobile.Palette.secondary)
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(verbatim: tv.name).font(Mobile.TypeScale.headline)
                Text(verbatim: Self.brandName(tv.brand) + (ready == true ? " · " + String(localized: "CouchSubs installed") : ready == false ? " · " + String(localized: "no app") : ""))
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
            Spacer()
            if working == tv {
                ProgressView().tint(Mobile.Palette.accent)
            } else if ready == true {
                MobilePill(text: String(localized: "Ready"), dot: true)
            } else if ready == false {
                MobilePill(text: String(localized: "Install with a computer"))
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
        }
    }

    private var manualSheet: some View {
        VStack(alignment: .leading, spacing: Mobile.Space.gap) {
            ScreenTitle(title: "My TV is not listed",
                        message: "CouchSubs works with LG (webOS 4+), Samsung (Tizen, 2019+) and Android TV / Google TV. Type the TV's IP address, or choose Android TV: its CouchSubs app finds this phone by itself.")
            SegmentedTabs(options: [TVBrand.lg: "LG", .samsung: "Samsung", .androidTV: "Android TV"], selection: $manualBrand)
            if manualBrand != .androidTV {
                TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                    .textFieldStyle(MobileFieldStyle())
                    .keyboardType(.decimalPad)
            }
            Link("Supported TVs", destination: AppIdentity.tvGuideURL).font(Mobile.TypeScale.caption).tint(Mobile.Palette.accent)
            Button("Connect") {
                let host = manualHost.trimmingCharacters(in: .whitespaces)
                showManual = false
                Task { await pair(LGTV(name: manualBrand == .androidTV ? "Android TV" : host, host: host, brand: manualBrand)) }
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
