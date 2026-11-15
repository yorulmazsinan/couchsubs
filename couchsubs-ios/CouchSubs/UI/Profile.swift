// SPDX-License-Identifier: AGPL-3.0-only
// Profil (hesapsız: cihazlar, PSN hesabı, bildirim, havuz, kullanım verisi) ve ayarlar (tuvaldeki Telefon · Profil,
// Ayarlar). Uygulama tamamen ücretsizdir ve hesap istemez.

import CouchSubsCore
import RemotePlay
import SwiftUI

// MARK: - Profil

struct ProfileScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @Binding var path: [Route]
    @AppStorage("notifyPackUpdates") private var notifyPackUpdates = true
    @AppStorage(PhoneModel.notifyDisconnectKey) private var notifyDisconnect = true
    @AppStorage(UsageData.key) private var usageData = true

    var body: some View {
        MobileScreen {
            BackHeader(title: "Profile")
        } content: {
            Tile {
                HStack(spacing: Mobile.Space.gap) {
                    LogoView(size: 56)
                    VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                        Text(verbatim: "CouchSubs").font(Mobile.TypeScale.title)
                        Text("Free, no account needed").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            BentoGrid {
                Button { path.append(.target) } label: {
                    StatTile(symbol: "tv", tint: .ok, label: "Devices", value: devicesText)
                }
                .buttonStyle(.plain)
                Button { path.append(.psn) } label: {
                    StatTile(symbol: "person.2.fill", label: "PSN account",
                             value: model.accountId == nil ? String(localized: "Not set up") : String(localized: "Signed in"))
                }
                .buttonStyle(.plain)
            }
            Tile(spacing: 0) {
                NavigationLink(value: Route.ps5) {
                    ListRow(symbol: "gamecontroller", title: "PS5 and connection", detail: model.console?.name)
                }
                RowDivider()
                NavigationLink(value: Route.target) { ListRow(symbol: "tv", title: "Subtitle target", detail: targetName) }
            }
            .buttonStyle(.plain)
            Tile(spacing: 0) {
                toggleRow("Notifications", "New packs and updates", isOn: $notifyPackUpdates)
                RowDivider()
                toggleRow("PS5 connection", "Notify me when the connection drops", isOn: $notifyDisconnect)
                RowDivider()
                toggleRow("Contribute to the shared pool", "English lines that are read, anonymous", isOn: $model.settings.sharePool)
                RowDivider()
                toggleRow("Ask which game I'm playing", "If no pack recognises the game, asked once two minutes after translation starts.",
                          isOn: $model.settings.askGame)
                RowDivider()
                toggleRow("Usage data", "Error and usage statistics", isOn: $usageData)
            }
            Tile(spacing: 0) {
                Link(destination: AppConfig.privacyURL) { ListRow(symbol: "hand.raised", title: "Data and privacy") }
                RowDivider()
                Link(destination: AppConfig.helpURL) { ListRow(symbol: "questionmark.circle", title: "Help") }
                RowDivider()
                NavigationLink(value: Route.about) { ListRow(symbol: "info.circle", title: "About", detail: AppIdentity.version) }
            }
            .buttonStyle(.plain)
            Text(verbatim: "CouchSubs \(AppIdentity.version) · Copyright © 2026 Sinan Yorulmaz · AGPL-3.0")
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary).frame(maxWidth: .infinity)
        } bottom: {
            EmptyView()
        }
        .onChange(of: usageData) { value in app.analytics.setCollection(value) }
        // Bağlantı bildirimi açılınca izin hemen istenir (yoksa ilk çeviride).
        .onChange(of: notifyDisconnect) { value in if value { model.requestNotificationPermission() } }
        .onAppear { app.analytics.screen("profile") }
    }

    private var devicesText: String {
        String(format: String(localized: "%lld PS5 · %lld TV"), model.console == nil ? 0 : 1, model.hasTV ? 1 : 0)
    }

    private var targetName: String {
        if model.settings.output == .computer { return String(localized: "This phone") }
        return model.hasTV ? model.tv?.name ?? "TV" : String(localized: "Not set up")
    }

    private func toggleRow(_ title: LocalizedStringKey, _ caption: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(title).font(Mobile.TypeScale.headline)
                Text(caption).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
        }
        .tint(Mobile.Palette.accent)
        .padding(.vertical, Mobile.Space.gap)
    }
}

// MARK: - Ayarlar

struct SettingsScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @Binding var path: [Route]
    @State private var key = ""
    @State private var checking = false
    @State private var keyResult: String?

    /// Segmentteki seçim: Ücretsiz, DeepL, Gemini, Diğer (OpenAI, Claude).
    private enum Choice: Hashable { case free, deepL, gemini, other }
    private static let choices: KeyValuePairs<Choice, LocalizedStringKey> = [.free: "Free", .deepL: "DeepL", .gemini: "Gemini", .other: "Other"]

    var body: some View {
        MobileScreen {
            BackHeader(title: "Settings")
        } content: {
            Tile {
                Text("Translation engine").font(Mobile.TypeScale.headline)
                SegmentedTabs(options: Self.choices,
                              selection: Binding(get: { choice }, set: { setChoice($0) }))
                if choice == .other {
                    SegmentedTabs(options: [TranslationEngine.openAI: "OpenAI", .claude: "Claude"],
                                  selection: Binding(get: { model.settings.translationEngine == .claude ? .claude : .openAI },
                                                     set: { model.settings.translationEngine = $0 }))
                }
                let engine = model.settings.translationEngine
                if engine != .free {
                    HStack(spacing: Mobile.Space.inline) {
                        if model.hasKey(engine) {
                            Text(String(format: String(localized: "%@ key"), engine.displayName)).font(Mobile.TypeScale.headline.weight(.regular))
                            Spacer()
                            Label(String(localized: "saved"), systemImage: "checkmark")
                                .font(Mobile.TypeScale.caption)
                                .foregroundStyle(Mobile.Palette.success)
                            Button { model.removeKey(engine) } label: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(Mobile.Palette.secondary)
                                .accessibilityLabel(Text("Remove key"))
                        } else {
                            SecureField(String(format: String(localized: "%@ key"), engine.displayName), text: $key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Save") { Task { await save(engine) } }
                                .foregroundStyle(Mobile.Palette.accent)
                                .disabled(checking || key.isEmpty)
                        }
                    }
                    .font(Mobile.TypeScale.headline.weight(.regular))
                    .padding(.horizontal, Mobile.Space.tile)
                    .frame(minHeight: Mobile.Control.field)
                    .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.control).strokeBorder(Mobile.Palette.border))
                    if checking { ProgressView().tint(Mobile.Palette.accent) }
                    if let keyResult { MobileNote(text: keyResult) }
                }
                Text("In games with a ready pack this engine only translates the missing lines.")
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
            Tile {
                HStack {
                    Text("Subtitle appearance").font(Mobile.TypeScale.headline)
                    Spacer()
                    Text(verbatim: "%\(percent)").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
                Slider(value: Binding(get: { Double(percent) }, set: { setPercent(Int($0)) }), in: 80...160, step: 10)
                    .tint(Mobile.Palette.accent)
                Text(verbatim: "Dinliyor musun beni?")
                    .font(Mobile.TypeScale.subtitle(landscape: false, scale: Double(percent) / 100))
                    .foregroundStyle(model.settings.style.textColor == .yellow ? Mobile.Palette.accent : Mobile.Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack {
                    Text("Text colour").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    Spacer()
                    ForEach([SubtitleTextColor.white, .yellow], id: \.self) { color in
                        Button { model.settings.style.textColor = color } label: {
                            Circle()
                                .fill(color == .yellow ? Mobile.Palette.accent : Mobile.Palette.text)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Mobile.Palette.accent, lineWidth: model.settings.style.textColor == color ? 2 : 0).padding(-4))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(color == .yellow ? "Yellow" : "White"))
                    }
                }
                // Kutu TV'de görünür; %100 tamamen opak olur ve oyundaki İngilizce yazıyı kapatır.
                HStack {
                    Text("Background").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    Spacer()
                    Text(verbatim: "%\(model.settings.style.background)").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                }
                Slider(value: Binding(get: { Double(model.settings.style.background) },
                                      set: { model.settings.style.background = Int($0.rounded()) }), in: 0...100, step: 5)
                    .tint(Mobile.Palette.accent)
                Text("Background area").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                SegmentedTabs(options: [SubtitleBackgroundShape.fit: "Fit the text", .band: "Full-width band"],
                              selection: $model.settings.style.backgroundShape)
                Text("Drag Background all the way to Solid to fully hide the English subtitle in the game. A full-width band also covers the sides.")
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Toggle(isOn: $model.settings.style.stackPrevious) {
                    VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                        Text("Keep previous lines above in fast dialogue").font(Mobile.TypeScale.headline)
                        Text("When off, each new line replaces the previous one. Needs TV app 0.9.16 or later.")
                            .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    }
                }
                .tint(Mobile.Palette.accent)
            }
            AreaTile()
            ExtraAreasTile()
            LoginPasscodeTile()
            Tile(spacing: 0) {
                NavigationLink(value: Route.packs) {
                    ListRow(symbol: "bolt.fill", tint: .pro, title: "Game packs",
                            detail: model.settings.gamePacks ? String(localized: "On") : String(localized: "Off"))
                }
                RowDivider()
                NavigationLink(value: Route.target) { ListRow(symbol: "tv", title: "Subtitle target", detail: targetName) }
                RowDivider()
                NavigationLink(value: Route.tvInstall) {
                    ListRow(symbol: "arrow.down.app", title: "Install the TV app from this phone", detail: model.installedTVApp?.version)
                }
                RowDivider()
                NavigationLink(value: Route.ps5) {
                    ListRow(symbol: "gamecontroller", title: "PS5 and connection", detail: model.console?.name)
                }
                RowDivider()
                NavigationLink(value: Route.about) { ListRow(symbol: "info.circle", title: "About", detail: AppIdentity.version) }
            }
            .buttonStyle(.plain)
        } bottom: {
            Button("Send test subtitle") { model.sendTestSubtitle() }.buttonStyle(.mobileSecondary)
        }
        .onAppear { app.analytics.screen("settings") }
    }

    private var choice: Choice {
        switch model.settings.translationEngine {
        case .free: .free
        case .deepL: .deepL
        case .gemini: .gemini
        // Yerel model (Ollama, LM Studio) yalnız Mac ve Windows'ta seçilir; telefonda başka hizmet sayılır.
        case .openAI, .claude, .local: .other
        }
    }

    private func setChoice(_ choice: Choice) {
        keyResult = nil
        key = ""
        switch choice {
        case .free: model.settings.translationEngine = .free
        case .deepL: model.settings.translationEngine = .deepL
        case .gemini: model.settings.translationEngine = .gemini
        case .other: model.settings.translationEngine = model.settings.translationEngine == .claude ? .claude : .openAI
        }
    }

    /// Yazı boyu TV'deki varsayılana (46) göre yüzde; telefon ekranı da aynı oranı kullanır.
    private var percent: Int { Int((Double(model.settings.style.fontSize) / Double(SubtitleStyle().fontSize) * 100 / 10).rounded()) * 10 }

    private func setPercent(_ value: Int) {
        model.settings.style.fontSize = Int((Double(SubtitleStyle().fontSize) * Double(value) / 100).rounded())
    }

    private var targetName: String {
        if model.settings.output == .computer { return String(localized: "This phone") }
        return model.hasTV ? model.tv?.name ?? "TV" : String(localized: "Not set up")
    }

    private func save(_ engine: TranslationEngine) async {
        checking = true
        keyResult = nil
        let accepted = await model.saveKey(key, for: engine)
        keyResult = accepted ? nil : String(localized: "The key did not work. Check it and try again.")
        if accepted { key = "" }
        checking = false
    }
}

/// İkinci hesabın PS5 giriş şifresi (isteğe bağlı, 4 hane, Anahtarlık'ta). PS5 isterse oturum açılırken gönderilir.
private struct LoginPasscodeTile: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var passcode = ""
    @State private var invalid = false

    var body: some View {
        Tile {
            Text("PS5 login passcode").font(Mobile.TypeScale.headline)
            HStack(spacing: Mobile.Space.inline) {
                if model.hasLoginPasscode {
                    Text("Passcode saved.").font(Mobile.TypeScale.headline.weight(.regular))
                    Spacer()
                    Button { model.removeLoginPasscode() } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(Mobile.Palette.secondary)
                        .accessibilityLabel(Text("Remove passcode"))
                } else {
                    SecureField("4 digits", text: $passcode)
                        .keyboardType(.numberPad)
                        .onChange(of: passcode) { value in passcode = String(value.filter(\.isNumber).prefix(LoginPasscode.length)) }
                    Button("Save") {
                        invalid = !model.setLoginPasscode(passcode)
                        if !invalid { passcode = "" }
                    }
                    .foregroundStyle(Mobile.Palette.accent)
                    .disabled(passcode.isEmpty)
                }
            }
            .font(Mobile.TypeScale.headline.weight(.regular))
            .padding(.horizontal, Mobile.Space.tile)
            .frame(minHeight: Mobile.Control.field)
            .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.control).strokeBorder(Mobile.Palette.border))
            if invalid { MobileNote(text: String(localized: "Enter the 4-digit passcode.")) }
            Text("Only needed if the second account has a login passcode on the PS5. CouchSubs enters it when the PS5 asks. It is kept in the Keychain.")
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        }
    }
}

/// Hakkında: sürüm, telif, kaynak kodu.
struct AboutScreen: View {
    var body: some View {
        MobileScreen {
            BackHeader(title: "About")
        } content: {
            Tile {
                LogoView(size: 56)
                Text(verbatim: "CouchSubs \(AppIdentity.version)").font(Mobile.TypeScale.title)
                Text(verbatim: "Copyright © 2026 Sinan Yorulmaz").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Text("CouchSubs is free and open source (AGPL-3.0). Remote Play uses chiaki-ng (AGPL-3.0).")
                    .font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
                Link("Source code", destination: AppIdentity.sourceURL).font(Mobile.TypeScale.headline).tint(Mobile.Palette.accent)
            }
        } bottom: {
            EmptyView()
        }
    }
}
