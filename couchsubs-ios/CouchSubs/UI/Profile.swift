// SPDX-License-Identifier: AGPL-3.0-only
// Ayarlar sekmesi (Perde; tuvaldeki DL-iPhone-Ayarlar): en üstte hesap kartları, Mac'teki Ayarlar menüsünün bölümleri,
// ardından eski Profil sayfasının içeriği (cihazlar ve bağlantı, bildirimler, arka planda sürdürme, gizlilik, yardım,
// hakkında). Uygulama tamamen ücretsizdir ve hesap istemez.

import CouchSubsCore
import RemotePlay
import SwiftUI

// MARK: - Ayarlar

/// Ayarlar: hesap kartları, Mac'teki Ayarlar menüsünün bölümleri (aynı ad, sıra ve alt yazı; her biri kendi sayfasını
/// açar) ve telefona özgü ayarlar (eski Profil). Sekme kökünde büyük başlık; Ana ekrandan açılınca geri düğmesi.
struct SettingsScreen: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @Binding var path: [Route]
    @AppStorage(PackNotice.settingKey) private var notifyPackUpdates = true
    @AppStorage(PhoneModel.notifyDisconnectKey) private var notifyDisconnect = true
    @State private var confirmPSNSignOut = false

    var body: some View {
        MobileScreen {
            BackHeader(title: "Settings")
        } content: {
            PerdeAccountCards(path: $path)
            Tile(spacing: 0) {
                ForEach(Array(PhoneSettingsSection.allCases.enumerated()), id: \.element) { index, section in
                    if index > 0 { RowDivider() }
                    NavigationLink(value: section.route) { SettingsSectionRow(section: section) }
                }
            }
            .buttonStyle(.plain)
            // Telefona özgü ayarlar (eski Profil sayfası).
            SectionTitle("Profile")
                .padding(.top, Mobile.Space.inline)
            Tile(spacing: 0) {
                NavigationLink(value: Route.target) { ListRow(symbol: "tv", title: "Devices", detail: devicesText) }
                RowDivider()
                NavigationLink(value: Route.psn) {
                    ListRow(symbol: "person.2.fill", title: "PSN account",
                            detail: model.accountId == nil ? String(localized: "Not set up") : String(localized: "Signed in"))
                }
                RowDivider()
                NavigationLink(value: Route.platform) {
                    ListRow(symbol: "gamecontroller.fill", title: "Console", detail: model.isXbox ? "Xbox (Beta)" : "PlayStation 5")
                }
                RowDivider()
                NavigationLink(value: Route.ps5) {
                    if model.isXbox {
                        ListRow(symbol: "gamecontroller", title: "Xbox and connection", detail: model.xboxConsole?.name)
                    } else {
                        ListRow(symbol: "gamecontroller", title: "PS5 and connection", detail: model.console?.name)
                    }
                }
                if model.isXbox && model.xboxSignedIn {
                    RowDivider()
                    Button { model.signOutXbox() } label: { ListRow(symbol: "person.crop.circle.badge.xmark", title: "Sign out of Microsoft") }
                }
                if !model.isXbox && (model.accountId != nil || model.console != nil) {
                    RowDivider()
                    Button { confirmPSNSignOut = true } label: {
                        ListRow(symbol: "person.crop.circle.badge.xmark", title: "Sign out of PSN and reset the account")
                    }
                }
                RowDivider()
                NavigationLink(value: Route.target) { ListRow(symbol: "tv", title: "Subtitle target", detail: targetName) }
            }
            .buttonStyle(.plain)
            // Bildirimler ve arka planda sürdürme telefona özgü (Mac'te karşılığı yok: masaüstü uygulaması arka planda zaten
            // sürer); çeviri ve görünüm ayarları yukarıdaki bölümlerde (Mac ile aynı yer ve ad).
            Tile(spacing: 0) {
                toggleRow("Notifications", "New packs and updates", isOn: $notifyPackUpdates)
                RowDivider()
                toggleRow("PS5 connection", "Notify me when the connection drops", isOn: $notifyDisconnect)
                RowDivider()
                // Android'de aynı ad ve açıklama (ön plan hizmetiyle zaten süren çeviriye küçük pencere).
                toggleRow("Keep translating in the background (Picture in Picture)",
                          "When you leave CouchSubs while translating, the game picture and the live subtitle stay in a small window; reading and sending to the TV continue.",
                          isOn: $model.backgroundPiP)
            }
            Tile(spacing: 0) {
                Link(destination: AppConfig.privacyURL) { ListRow(symbol: "hand.raised", title: "Data and privacy") }
                RowDivider()
                Link(destination: AppConfig.helpURL) { ListRow(symbol: "questionmark.circle", title: "Help") }
                RowDivider()
                NavigationLink(value: Route.about) { ListRow(symbol: "info.circle", title: "About", detail: AppIdentity.version) }
            }
            .buttonStyle(.plain)
            HStack(spacing: Mobile.Space.gap) {
                DSLogoMark(height: 28)
                VStack(alignment: .leading, spacing: Mobile.Space.micro) {
                    Text(verbatim: "CouchSubs").font(Mobile.TypeScale.headline)
                    Text(verbatim: "CouchSubs \(AppIdentity.version) · © 2026 Enmera · AGPL-3.0")
                        .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    Text("Free, no account needed").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.tertiary)
                }
                Spacer(minLength: 0)
            }
            DeveloperSignature()
        } bottom: {
            // Deneme altyazısı Altyazı Görünümü ve Çıkış Ekranları'nda (Mac ile aynı yer).
            EmptyView()
        }
        // Bağlantı bildirimi açılınca izin hemen istenir (yoksa ilk çeviride).
        .onChange(of: notifyDisconnect) { value in if value { model.requestNotificationPermission() } }
        .onChange(of: notifyPackUpdates) { value in if value { model.requestNotificationPermission() } }
        .onAppear { app.analytics.screen("settings") }
        .confirmationDialog("Sign out of PSN?", isPresented: $confirmPSNSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { model.signOutPSN() }
        } message: {
            Text("The second PSN account and the PS5 pairing are removed from this phone. To translate again, sign in with Sony and pair the PS5 again.")
        }
    }

    private var devicesText: String {
        String(format: String(localized: "%lld PS5 · %lld TV"), model.console == nil ? 0 : 1, model.hasTV ? 1 : 0)
    }

    private var targetName: String {
        if model.settings.output == .computer { return String(localized: "This phone") }
        if model.settings.output == .obs { return String(localized: "OBS only (stream)") }
        if model.settings.output == .both, model.hasTV { return String(format: String(localized: "%@ and this phone"), model.tv?.name ?? "TV") }
        return model.hasTV ? model.tv?.name ?? "TV" : String(localized: "Not set up")
    }

    private func toggleRow(_ title: LocalizedStringKey, _ caption: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(title).font(Mobile.TypeScale.headline).fixedSize(horizontal: false, vertical: true)
                Text(caption).dsMuted()
            }
        }
        .padding(.vertical, Mobile.Space.gap)
    }
}

/// Ayarlar › Gelişmiş › Çeviri motoru: Ücretsiz, DeepL, Gemini, Diğer (OpenAI, Claude, yerel model); anahtar, model, ek
/// talimat ve Gemini'de ücretli anahtar seçimi (Mac ile aynı).
struct EngineTile: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var checking = false
    @State private var keyResult: String?

    /// Segmentteki seçim: Ücretsiz, DeepL, Gemini, Diğer (OpenAI, Claude).
    private enum Choice: Hashable { case free, deepL, gemini, other }
    private static let choices: KeyValuePairs<Choice, LocalizedStringKey> = [.free: "Free", .deepL: "DeepL", .gemini: "Gemini", .other: "Other"]

    var body: some View {
        Tile(spacing: Mobile.Space.unit) {
            SettingUnit(title: "Translation engine", hint: "In games with a ready pack this engine only translates the missing lines.") {
                VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                    SegmentedTabs(options: Self.choices,
                                  selection: Binding(get: { choice }, set: { setChoice($0) }))
                    if choice == .other {
                        // Yerel model: aynı ağdaki bilgisayarda çalışan Ollama, LM Studio ya da başka OpenAI uyumlu sunucu
                        // (Mac ve Windows'taki "Yerel model (Ollama, LM Studio)" motoru; Android ile aynı).
                        SegmentedTabs(options: [TranslationEngine.openAI: "OpenAI", .claude: "Claude", .local: "Local model"],
                                      selection: Binding(get: { [.claude, .local].contains(model.settings.translationEngine) ? model.settings.translationEngine : .openAI },
                                                         set: { keyResult = nil; key = ""; model.settings.translationEngine = $0 }))
                    }
                }
            }
            let engine = model.settings.translationEngine
            if engine != .free, model.settings.sourceLanguage != "en" {
                Text("Online engines only translate English games. Other game languages use the free translation.").dsMuted()
            }
            // Ücretsiz çeviri zayıf kalıyor; ücretsiz Gemini anahtarı en kolay iyileştirme (Mac ile aynı öneri).
            if engine == .free {
                Text("For better translation, get a free Gemini key.").font(Mobile.TypeScale.body).fixedSize(horizontal: false, vertical: true)
                Button("Get a Free Key") {
                    setChoice(.gemini)
                    openURL(AIProvider.gemini.keyPage)
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
            }
            // Model seçimi üç hizmette de var (Mac ve Windows ile aynı liste ve varsayılanlar).
            if let provider = engine.aiProvider, provider != .local { AIModelChoice(provider: provider) }
            if engine == .local { PhoneLocalAISection() }
            if engine != .free, engine != .local {
                VStack(alignment: .leading, spacing: Mobile.Space.inline) {
                    Text(String(format: String(localized: "%@ key"), engine.displayName)).font(Mobile.TypeScale.headline)
                    if model.hasKey(engine) {
                        DSFieldChrome {
                            Label(String(localized: "saved"), systemImage: "checkmark")
                                .foregroundStyle(Mobile.Palette.successText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } trailing: {
                            DSFieldIconButton(symbol: "xmark.circle.fill", label: "Remove key") { model.removeKey(engine) }
                        }
                    } else {
                        DSFieldChrome {
                            SecureField(String(format: String(localized: "%@ key"), engine.displayName), text: $key)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } trailing: {
                            Button(checking ? LocalizedStringKey("Testing…") : LocalizedStringKey("Save")) { Task { await save(engine) } }
                                .font(Mobile.TypeScale.headline)
                                .foregroundStyle(Mobile.Palette.accentText)
                                .padding(.horizontal, Mobile.Space.gap)
                                .frame(minHeight: Mobile.Control.icon)
                                .disabled(checking || key.isEmpty)
                        }
                    }
                    if checking { ProgressView().tint(Mobile.Palette.accentText) }
                    if let keyResult { InfoBox(text: keyResult) }
                    // Mac ve Windows'taki kullanım satırı (#625): kayıtlı DeepL anahtarının bu ayki karakter kullanımı.
                    if engine == .deepL, model.hasKey(.deepL) { DeepLUsageRow() }
                }
            }
            // Ek talimat (#306) yalnız yapay zekâ motorlarında; DeepL'de yoktur (Android ile aynı).
            if engine.aiProvider != nil { AIInstructionField() }
            // Ücretli Gemini anahtarında dakikalık istek sınırı modelin ücretli sınırına çıkar (Mac ve Windows ile aynı).
            if engine == .gemini {
                SettingSwitch(title: "I use a paid Gemini API key", subtitle: "Paid API keys may incur charges. Google still enforces quotas.",
                              isOn: $model.settings.geminiPaidTier)
            }
        }
    }

    private var choice: Choice {
        switch model.settings.translationEngine {
        case .free: .free
        case .deepL: .deepL
        case .gemini: .gemini
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
        case .other:
            let current = model.settings.translationEngine
            model.settings.translationEngine = current == .claude || current == .local ? current : .openAI
        }
    }

    private func save(_ engine: TranslationEngine) async {
        checking = true
        keyResult = nil
        switch await model.saveKey(key, for: engine) {
        case .saved:
            keyResult = nil
            key = ""
        case .rejected:
            // DeepL'de neden ayrı yazılır (geçersiz anahtar, geçersiz karakter, sunucu hatası, ağ yok); Mac ile aynı metinler.
            if engine == .deepL, let check = model.lastDeepLCheck {
                keyResult = DeepLUsageText.describe(check, quotaUsedUp: String(localized: "This month's DeepL limit is used up. Until it renews, the free translation on this phone translates."))
            } else {
                keyResult = String(localized: "The key did not work. Check it and try again.")
            }
        case .notStored:
            keyResult = String(localized: "The API key could not be saved to this iPhone's keychain.")
        }
        checking = false
    }
}

/// Ayarlar › Çıkış Ekranları: TV'deki yer ve biçim (Mac'teki AppearanceCard; yazı boyu ve renkler Altyazı Görünümü'nde).
struct PlacementTile: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Tile(spacing: Mobile.Space.unit) {
            // TV'de çevirinin yeri (Mac ve Windows'taki Yeri seçimi, Android ile aynı): üstünde/altında seçilince oyundaki
            // İngilizce altyazı da görünür; sabit yerde yükseklik kaydırıcıyla ayarlanır, bırakınca TV'de örnek altyazı çıkar.
            SettingUnit(title: "Subtitle position on TV",
                        hint: model.settings.style.placement == .fixed ? nil : "Cover: the translation hides the English subtitle in the game. Choose Above or Below to see the English subtitle too, with the translation right above or below it.") {
                SegmentedTabs(options: [SubtitlePlacement.cover: "Cover", .above: "Above", .below: "Below", .fixed: "Fixed"],
                              selection: $model.settings.style.placement)
            }
            if model.settings.style.placement == .fixed {
                DSSliderRow(title: "Height on screen", valueText: "%\(model.settings.style.bottomPercent)",
                            value: Binding(get: { Double(model.settings.style.bottomPercent) },
                                           set: { model.settings.style.bottomPercent = Int($0.rounded()) }), range: 0...85, step: 1,
                            hint: "A sample subtitle appears on the TV when you let go of the slider. In fixed position you can also move subtitles with the ▲ and ▼ buttons on the TV remote.") { editing in
                    if !editing { model.sendTestSubtitle() }
                }
            }
            SettingUnit(title: "Background area",
                        hint: "A full-width band also covers the sides of the English subtitle.") {
                SegmentedTabs(options: [SubtitleBackgroundShape.fit: "Fit the text", .band: "Full-width band"],
                              selection: $model.settings.style.backgroundShape)
            }
            SettingSwitch(title: "Bold text", isOn: $model.settings.style.bold)
            SettingSwitch(title: "Keep previous lines above in fast dialogue",
                          subtitle: "When off, each new line replaces the previous one. Needs TV app 0.9.16 or later.",
                          isOn: $model.settings.style.stackPrevious)
            // Yalnız Android TV uygulaması kullanır: bazı TV'lerde (ör. TCL) uygulama içindeki PS5 görüntüsü siyah kalıyor.
            // Katman'da TV, PS5'i kendi HDMI girişinde gösterir (Mac ve Windows'taki Görüntü modu seçimi, Android ile aynı).
            if model.settings.output.showsOnTV {
                SettingUnit(title: "Picture mode (Android TV)",
                            hint: "Automatic uses Overlay whenever the TV app allows it: the TV shows the PS5 on its own HDMI input and the subtitles appear on top. On some TVs the picture stays black inside the CouchSubs TV app. To show the PS5 inside the CouchSubs TV app instead, choose Inside the app; the TV app then never switches to Overlay by itself: if no picture arrives, it reopens the HDMI input and lists the inputs, and you can choose Overlay there. With Overlay the TV also keeps its picture mode, Game mode and HDR. The TV app from Google Play has no Overlay mode: there Automatic stays inside the app, and the TV says so on screen if Overlay is chosen.") {
                    SegmentedTabs(options: [TVDisplayMode.auto: "Automatic", .inApp: "Inside the app", .overlay: "Overlay"],
                                  selection: $model.settings.style.displayMode)
                }
            }
        }
    }
}

/// Ayarlar › Çıkış Ekranları › OBS katmanı: adres görünür, kutunun içinden kopyalanır; telefonda ayrıca paylaşılır.
struct OBSTile: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Tile {
            SettingUnit(title: "OBS overlay") {
                VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                    DSCopyField(text: model.subtitleViewerAddress)
                    // Yan yana sığmazsa alt alta (uzun Türkçe etiket kesilmesin).
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Mobile.Space.gap) { obsButtons }
                        ButtonStack { obsButtons }
                    }
                    if model.legacyTVWarning { InfoBox(text: String(localized: "The TV app is old. Update it.")) }
                }
            }
        }
    }

    @ViewBuilder private var obsButtons: some View {
        ShareLink(item: model.subtitleViewerAddress) { Label("Share", systemImage: "square.and.arrow.up").fixedSize() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
        Button { model.rotateSubtitleKey() } label: { Text("Renew access key").fixedSize() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
    }
}

/// Deneme modu: konsol olmadan örnek görüntülerle (çeviri sürüyorsa önce durur).
struct DemoModeTile: View {
    @EnvironmentObject private var model: PhoneModel
    @Binding var path: [Route]

    var body: some View {
        Tile {
            Text("Demo mode").font(Mobile.TypeScale.headline)
            Text("Demo mode shows the whole app with sample pictures built into the app. No console, account or TV is needed.")
                .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.demoMode {
                Button("Exit demo mode") {
                    model.exitDemo()
                    path.removeAll()
                }
                .buttonStyle(.mobileSecondary)
            } else {
                Button {
                    Task {
                        await model.startDemo()
                        path.removeAll()
                    }
                } label: {
                    Label("Try demo mode (no console needed)", systemImage: "play.rectangle")
                }
                .buttonStyle(.mobileSecondary)
                .disabled(model.isStarting)
            }
        }
    }
}

/// DeepL anahtarının bu ayki kullanımı: "Bu ay: 500.000 karakterin 12.345 kadarı kullanıldı." (Mac, Windows ve Android
/// ile aynı metin). Ayarlar açılınca ve anahtar kaydedilince sorulur; sorgu karakter kotasından yemez.
private struct DeepLUsageRow: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var usage: OnlineKeyCheck?

    var body: some View {
        Group {
            if let usage {
                Text(DeepLUsageText.describe(usage, quotaUsedUp: String(localized: "This month's DeepL limit is used up. Until it renews, the free translation on this phone translates.")))
                    .font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { usage = await model.deepLUsage() }
    }
}

/// Yapay zekâ modeli: Gemini, OpenAI ve Claude (Mac ve Windows'taki Model seçimi, Android ile aynı). Seçenekler ortak
/// `ai-models.json`'dan gelir, ilki varsayılandır. Kayıt `UserSettings.geminiModel` / `openAIModel` / `claudeModel`;
/// Gemini'de dakikalık istek hakkı seçilen modelin sınırıdır (`RequestBudget.shared`).
private struct AIModelChoice: View {
    @EnvironmentObject private var model: PhoneModel
    let provider: AIProvider

    var body: some View {
        let selected = provider.model(model.settings.model(for: provider)).id
        Text("Model").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
        SegmentedTabs(options: provider.models.map { (key: $0.id, value: Self.label($0)) },
                      selection: Binding(get: { selected }, set: { model.settings.setModel($0, for: provider) }))
        Text(verbatim: selected).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
    }

    /// Modelin kısa açıklaması; listedeki açıklama (label) tanınmazsa olduğu gibi çevrilir.
    private static func label(_ option: AIModel) -> LocalizedStringKey {
        switch option.label {
        case "Fast and cheap (recommended)": "Fast (recommended)"
        case "Better quality, a little slower": "Better quality, slower"
        default: LocalizedStringKey(option.label)
        }
    }
}

/// Ek talimat (#306; Mac, Windows ve Android ile aynı): yapay zekâ çevirmeninin talimatının sonuna eklenir, boşsa hiçbir
/// şey değişmez. Alandan çıkınca kaydedilir; her tuşta çeviri hattı yeniden kurulmaz.
private struct AIInstructionField: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Text("Extra instruction").font(Mobile.TypeScale.headline)
        TextField("Example: Translate swear words without softening them.", text: $text, axis: .vertical)
            .lineLimit(3...6)
            // Giriş kutusuyla aynı dil; çok satırlı alan tam yuvarlak olamaz, 24 köşe.
            .font(Mobile.TypeScale.body)
            .foregroundStyle(Mobile.Palette.text)
            .tint(Mobile.Palette.accentText)
            .padding(.horizontal, Mobile.Space.tile)
            .padding(.vertical, Mobile.Space.gap)
            .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: Mobile.Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mobile.Radius.tile, style: .continuous)
                .strokeBorder(focused ? Mobile.Palette.accent : Mobile.Palette.border, lineWidth: focused ? 2 : 1))
            .focused($focused)
            .onAppear { text = model.settings.aiInstruction }
            .onChange(of: text) { value in
                if value.count > AIRequest.maxInstructionLength { text = String(value.prefix(AIRequest.maxInstructionLength)) }
            }
            .onChange(of: focused) { _ in commit() }
            .onDisappear(perform: commit)
        Text("Added to the end of the AI translator's instructions (up to 1000 characters). Leave it empty if you don't need it.")
            .dsMuted()
    }

    private func commit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != model.settings.aiInstruction { model.settings.aiInstruction = value }
    }
}

/// İkinci hesabın PS5 giriş şifresi (isteğe bağlı, 4 hane, Anahtarlık'ta). PS5 isterse oturum açılırken gönderilir.
struct LoginPasscodeTile: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var passcode = ""
    @State private var invalid = false

    var body: some View {
        Tile {
            Text("PS5 login passcode").font(Mobile.TypeScale.headline)
            if model.hasLoginPasscode {
                DSFieldChrome {
                    Text("Passcode saved.").frame(maxWidth: .infinity, alignment: .leading)
                } trailing: {
                    DSFieldIconButton(symbol: "xmark.circle.fill", label: "Remove passcode") { model.removeLoginPasscode() }
                }
            } else {
                DSFieldChrome {
                    SecureField("4 digits", text: $passcode)
                        .keyboardType(.numberPad)
                        .onChange(of: passcode) { value in passcode = String(value.filter(\.isNumber).prefix(LoginPasscode.length)) }
                } trailing: {
                    Button("Save") {
                        invalid = !model.setLoginPasscode(passcode)
                        if !invalid { passcode = "" }
                    }
                    .font(Mobile.TypeScale.headline)
                    .foregroundStyle(Mobile.Palette.accentText)
                    .padding(.horizontal, Mobile.Space.gap)
                    .frame(minHeight: Mobile.Control.icon)
                    .disabled(passcode.isEmpty)
                }
            }
            if invalid { MobileNote(text: String(localized: "Enter the 4-digit passcode.")) }
            Text("Only needed if the second account has a login passcode on the PS5. CouchSubs enters it when the PS5 asks. It is kept in the Keychain.")
                .dsMuted()
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
                DSLogoMark(height: 40)
                Text(verbatim: "CouchSubs \(AppIdentity.version)").font(Mobile.TypeScale.title)
                Text(verbatim: "© 2026 Enmera").font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
                Text("CouchSubs is free and open source (AGPL-3.0). Remote Play uses chiaki-ng (AGPL-3.0).")
                    .font(Mobile.TypeScale.body).foregroundStyle(Mobile.Palette.secondary)
                Link("Source code", destination: AppIdentity.sourceURL).font(Mobile.TypeScale.headline).tint(Mobile.Palette.accent)
            }
            // remoteplay.log, altyazi.log ve varsa tvinstall.log tek dosyada, kişisel veri maskelenmiş (Android'de de aynı;
            // masaüstünde "Günlük dosyasını göster").
            Tile(spacing: Mobile.Space.gap) {
                LogShareButton(fullWidth: true, title: "Share logs")
                Text("Attach this file to your GitHub issue when reporting a problem, or send it to us.").dsMuted()
            }
        } bottom: {
            EmptyView()
        }
    }
}

/// "Günlüğü Paylaş" (Mac'teki Günlüğü Kopyala'nın telefon karşılığı): paylaşım sayfası açılınca günlükler maskelenip tek
/// zip dosyasında paylaşılır (Dosyalar'a kaydet, Mail, Mesajlar, AirDrop…).
struct LogShareButton: View {
    var fullWidth = false
    /// Hakkında'da eski ad ("Günlükleri paylaş"; Android'deki Hakkında ile aynı), ana ekranda "Günlüğü Paylaş".
    var title: LocalizedStringKey = "Share Log"

    var body: some View {
        ShareLink(item: PhoneLogsZip(), preview: SharePreview(PhoneLogsZip.fileName)) {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: fullWidth))
        .frame(maxWidth: .infinity, alignment: fullWidth ? .center : .leading)
    }
}

/// Günlüklerin zip hâli: maskelenmiş tek metin dosyası (PhoneLogs) bir klasöre konur, sistemin dosya koordinatörü klasörü
/// zip olarak verir (ek kitaplık gerekmez).
struct PhoneLogsZip: Transferable {
    static let fileName = "couchsubs-logs.zip"

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { _ in SentTransferredFile(try PhoneLogsZip.file()) }
    }

    static func file() throws -> URL {
        let text = try PhoneLogs.file()
        let temporary = FileManager.default.temporaryDirectory
        let folder = temporary.appendingPathComponent("CouchSubs-Logs", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: text, to: folder.appendingPathComponent(text.lastPathComponent))
        let destination = temporary.appendingPathComponent(fileName)
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinatorError) { zipped in
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        return destination
    }
}

/// "Günlükleri paylaş"ın dosyası: paylaşım sayfası açılınca günlükler birleştirilip maskelenir (CouchSubsCore `LogShare`).
struct PhoneLogs: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in SentTransferredFile(try PhoneLogs.file()) }
    }

    static func file() throws -> URL {
        RemotePlayLog.flush()
        SubtitleLog.flush()
        let header = "CouchSubs iOS \(AppIdentity.version) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
        return try LogShare.write(header: header, logs: [
            ("remoteplay.log", RemotePlayLog.defaultFile),
            ("altyazi.log", SubtitleLog.defaultFile),
            ("tvinstall.log", InstallLog.shared.file),
        ], to: FileManager.default.temporaryDirectory.appendingPathComponent("logs", isDirectory: true))
    }
}
