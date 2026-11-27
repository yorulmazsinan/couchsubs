// SPDX-License-Identifier: AGPL-3.0-only
// Ayarlar'ın bölümleri: Mac'teki yeni arayüzün Ayarlar menüsüyle aynı ad, sıra, seçenek ve varsayılanlar (Temel, Altyazı
// Görünümü, Gelişmiş, Altyazı Alanı, Oyun Paketleri, Türkçe Dublaj, Çıkış Ekranları, Konsol ve Kaynak). Klavye Kısayolları
// telefonda yok (klavye yok). Android'de aynı bölümler ve metinler (ui/SettingsPages.kt); fark scripts/parity-check.py'de denetlenir.

import CouchSubsCore
import SwiftUI

enum PhoneSettingsSection: String, Hashable, CaseIterable {
    case basics, appearance, advanced, area, packs, dubbing, outputs, console

    var title: LocalizedStringKey {
        switch self {
        case .basics: "Basics"
        case .appearance: "Subtitle Appearance"
        case .advanced: "Advanced"
        case .area: "Subtitle Area"
        case .packs: "Game Packs"
        case .dubbing: "Turkish Dubbing"
        case .outputs: "Output Screens"
        case .console: "Console and Source"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .basics: "Translation, Sound"
        case .appearance: "Size, Colors"
        case .advanced: "Engine, On-Screen Text"
        case .area: "Frame, Extra Areas"
        case .packs: "Ready Translations"
        case .dubbing: "Voices, Characters"
        case .outputs: "TV, OBS"
        case .console: "PS5, Xbox"
        }
    }

    var icon: String {
        switch self {
        case .basics: "slider.horizontal.3"
        case .appearance: "textformat.size"
        case .advanced: "gearshape.2"
        case .area: "viewfinder"
        case .packs: "shippingbox"
        case .dubbing: "waveform"
        case .outputs: "tv"
        case .console: "gamecontroller"
        }
    }

    var tint: Color {
        switch self {
        case .basics, .area: .dsAmber
        case .appearance, .console: .dsPeach
        case .advanced: .dsLive
        case .packs: .dsOlive
        case .dubbing: .dsPlum
        case .outputs: .dsTeal
        }
    }

    /// Bölümün sayfası; Oyun Paketleri mevcut paketler sayfasını açar.
    var route: Route { self == .packs ? .packs : .settingsPage(self) }
}

/// Ayarlar menüsündeki bölüm satırı: renkli simge karesi, ad ve iki kelimelik alt yazı (Mac'teki NavRow).
struct SettingsSectionRow: View {
    let section: PhoneSettingsSection

    var body: some View {
        HStack(spacing: Mobile.Space.gap) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.radius("chip"), style: .continuous).fill(section.tint.opacity(0.16))
                Image(systemName: section.icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(section.tint)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(section.title).font(Mobile.TypeScale.headline).foregroundStyle(Mobile.Palette.text)
                Text(section.hint).font(Mobile.TypeScale.caption).foregroundStyle(Mobile.Palette.secondary)
            }
            Spacer(minLength: Mobile.Space.inline)
            RowChevron()
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

/// Bir ayar bölümünün sayfası.
struct SettingsPageScreen: View {
    let section: PhoneSettingsSection
    @Binding var path: [Route]
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel

    var body: some View {
        MobileScreen {
            BackHeader(title: section.title)
        } content: {
            switch section {
            case .basics: BasicsPage(path: $path)
            case .appearance: AppearancePage()
            case .advanced: AdvancedPage()
            case .area: AreaPage()
            case .packs: PackSettingsTile()
            case .dubbing: DubbingTile()
            case .outputs: OutputsPage(path: $path)
            case .console: ConsolePage(path: $path)
            }
            DeveloperSignature()
        } bottom: {
            EmptyView()
        }
        .onAppear { app.analytics.screen("settings_" + section.rawValue) }
    }
}

/// Açık/kapalı ayar: anahtar solda (yeni dil), başlık ve altında isteğe bağlı açıklama (Mac'teki DSSwitchRow).
struct SettingSwitch: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(title).font(Mobile.TypeScale.headline).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).dsMuted() }
            }
        }
    }
}

// MARK: - Temel

private struct BasicsPage: View {
    @Binding var path: [Route]
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        let pace = Binding<TranslationPace?>(get: { TranslationPace.of(model.settings) }, set: { value in
            guard let value else { return }
            model.settings.misreadWaitMs = value.waits.misread
            model.settings.partialWaitMs = value.waits.partial
        })
        Tile(spacing: Mobile.Space.unit) {
            SectionTitle("Translation")
            SettingUnit(title: "Speed", hint: pace.wrappedValue?.explanation ?? "These waits only delay lines that were read badly; most lines are shown without waiting. A shorter wait shows those lines sooner but lets more wrong translations through.") {
                DSTabs(selection: pace, items: [(TranslationPace?.some(.fast), "Fast"), (TranslationPace?.some(.balanced), "Balanced"), (TranslationPace?.some(.accurate), "Accurate")])
            }
            SettingUnit(title: "Translation Language", hint: "The game language is detected by itself.") {
                Text(verbatim: Locale.current.localizedString(forLanguageCode: model.settings.targetLanguage) ?? model.settings.targetLanguage)
                    .font(Mobile.TypeScale.body)
            }
        }
        Tile(spacing: Mobile.Space.unit) {
            SectionTitle("Sound")
            SettingSwitch(title: "Startup Sound", subtitle: "Plays only on the first launch.", isOn: $model.settings.startupSound)
            SettingSwitch(title: "Transition Animations", subtitle: "When off, only a short fade is used.", isOn: $model.settings.transitionAnimations)
            SettingUnit(title: "Appearance") {
                DSTabs(selection: $model.settings.appearance, items: [(AppAppearance.light, "Light"), (.dark, "Dark"), (.system, "Follow System")])
            }
        }
        Tile(spacing: Mobile.Space.gap) {
            SectionTitle("Subtitle appearance")
            PhoneSubtitlePreview(lines: [SubtitleSample.lines[0]])
            Text("Text size, background, text and character name colors. The settings apply the same on the TV, phone and computer screen.").dsMuted()
            Button { path.append(.settingsPage(.appearance)) } label: {
                HStack {
                    Text("Edit Subtitle Appearance")
                    Spacer()
                    Text(verbatim: "→").accessibilityHidden(true)
                }
            }
            .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
        }
    }
}

// MARK: - Altyazı Görünümü

/// TV önizlemesi: oyun sahnesi üstünde altyazı kutuları, ayarların renk, zemin ve boyuyla (Mac'teki SubtitlePreviewBox).
struct PhoneSubtitlePreview: View {
    @EnvironmentObject private var model: PhoneModel
    let lines: [(who: String, text: String)]

    var body: some View {
        let style = model.settings.style
        let display = SubtitlePalette.display(style.fontSize)
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        ZStack(alignment: .bottom) {
            PreviewScene()
            VStack(spacing: Mobile.Space.hair) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    (Text(verbatim: model.settings.showSpeakerNames ? line.who + ": " : "").foregroundColor(nameColor(line.who, index: index, style: style))
                     + Text(verbatim: line.text).foregroundColor(model.settings.speakerColors && style.nameColorMode == .line
                                                                    ? nameColor(line.who, index: index, style: style)
                                                                    : SubtitlePalette.color(SubtitlePalette.textHex(style)) ?? .white))
                        .font(.system(size: CGFloat(display) * 0.4, weight: style.bold ? .bold : .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Mobile.Space.inline)
                        .padding(.vertical, Mobile.Space.micro)
                        .background((SubtitlePalette.color(style.backgroundColor) ?? .black).opacity(Double(style.background) / 100),
                                    in: RoundedRectangle(cornerRadius: DS.radius("small")))
                        .shadow(color: style.background == 0 ? .black.opacity(0.85) : .clear, radius: 1.5, y: 1)
                }
            }
            .padding(Mobile.Space.gap)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.dsScreenFrame, lineWidth: 5))
        .animation(DS.animation(.medium, reduced: !model.settings.transitionAnimations), value: style)
        .accessibilityHidden(true)
    }

    private func nameColor(_ who: String, index: Int, style: SubtitleStyle) -> Color {
        switch model.settings.speakerColors ? style.nameColorMode : .text {
        case .text: return SubtitlePalette.color(SubtitlePalette.textHex(style)) ?? .white
        case .single: return SubtitlePalette.color(style.nameHex ?? SubtitlePalette.names[0].hex) ?? .dsAmber
        case .speaker, .line:
            let hex = style.characterColors[who.lowercased()] ?? SubtitlePalette.names[(index + 1) % SubtitlePalette.names.count].hex
            return SubtitlePalette.color(hex) ?? .dsAmber
        }
    }

    /// Görüntü gelmeden önce çerçevede duran yumuşak sahne (Mac'teki DSSceneBackground).
    private struct PreviewScene: View {
        var body: some View {
            GeometryReader { geometry in
                let size = max(geometry.size.width, geometry.size.height)
                ZStack {
                    Color(red: 0.427, green: 0.416, blue: 0.365)
                    RadialGradient(colors: [Color(red: 0.478, green: 0.541, blue: 0.416), .clear],
                                   center: UnitPoint(x: 0.3, y: 0.35), startRadius: 0, endRadius: size * 0.5)
                    RadialGradient(colors: [Color(red: 0.78, green: 0.604, blue: 0.384), .clear],
                                   center: UnitPoint(x: 0.75, y: 0.3), startRadius: 0, endRadius: size * 0.42)
                }
            }
        }
    }
}

private struct AppearancePage: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var size: Double = 30

    var body: some View {
        let style = model.settings.style
        Tile(spacing: Mobile.Space.gap) {
            SectionTitle("Subtitles on the TV")
            PhoneSubtitlePreview(lines: SubtitleSample.lines)
            if SubtitlePalette.lowContrast(style) {
                Text("The text color is too close to the background; it may be hard to read on the TV.")
                    .font(Mobile.TypeScale.caption).foregroundStyle(Color.dsLiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The settings apply the same on the TV, phone and computer screen.").dsMuted()
            Button("Send Test Subtitle") { model.sendTestSubtitle() }.buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
        }
        Tile(spacing: Mobile.Space.unit) {
            DSSliderRow(title: "Text Size", valueText: String(format: String(localized: "%lld px"), Int(size.rounded())),
                        value: $size, range: 16...50, step: 1) { editing in
                if !editing { model.sendTestSubtitle() }
            }
            .onChange(of: size) { value in update { $0.fontSize = SubtitlePalette.fontSize(Int(value.rounded())) } }
            backgroundSection
            darknessSection
            textSection
            nameSection
            SettingSwitch(title: "Show Speaker Name", isOn: $model.settings.showSpeakerNames)
        }
        .onAppear { size = Double(SubtitlePalette.display(style.fontSize)) }
    }

    /// Yeni arayüzde konuşan rengi yalnız adı boyar (Mac ile aynı).
    private func update(_ change: (inout SubtitleStyle) -> Void) {
        change(&model.settings.style)
        model.settings.style.nameOnly = true
    }

    private func selectedHint(_ swatch: SubtitlePalette.Swatch?) -> LocalizedStringKey? {
        swatch.map { LocalizedStringKey(String(format: String(localized: "Selected: %@."), String(localized: String.LocalizationValue($0.name)))) }
    }

    private var backgroundSection: some View {
        let style = model.settings.style
        let selected = style.background == 0 ? nil : style.backgroundColor
        return SettingUnit(title: "Background Color", hint: selectedHint(SubtitlePalette.backgrounds.first { $0.hex == selected })) {
            SwatchGrid(swatches: SubtitlePalette.backgrounds, selected: selected) { swatch in
                update { style in
                    if let hex = swatch.hex {
                        style.backgroundColor = hex
                        if style.background == 0 { style.background = SubtitlePalette.darkness[1] }
                    } else {
                        style.background = 0
                    }
                }
                model.sendTestSubtitle()
            }
        }
    }

    private var darknessSection: some View {
        let style = model.settings.style
        let level = Binding<Int?>(get: {
            guard style.background > 0 else { return nil }
            return SubtitlePalette.darkness.min { abs($0 - style.background) < abs($1 - style.background) }
        }, set: { value in
            guard let value else { return }
            update { $0.background = value }
            model.sendTestSubtitle()
        })
        return SettingUnit(title: "Darkness") {
            DSTabs(selection: level, items: [(Int?.some(45), "Light"), (Int?.some(75), "Medium"), (Int?.some(100), "Dark")])
                .disabled(style.background == 0)
                .opacity(style.background == 0 ? 0.5 : 1)
        }
    }

    private var textSection: some View {
        let style = model.settings.style
        let selected = SubtitlePalette.textHex(style)
        return SettingUnit(title: "Text Color", hint: selectedHint(SubtitlePalette.texts.first { $0.hex == selected })) {
            SwatchGrid(swatches: SubtitlePalette.texts, selected: selected) { swatch in
                update { style in
                    style.textHex = swatch.hex
                    style.textColor = swatch.hex == "#FFE066" ? .yellow : .white
                }
                model.sendTestSubtitle()
            }
        }
    }

    private var nameSection: some View {
        let style = model.settings.style
        let mode = Binding<NameColorMode>(get: { model.settings.speakerColors ? style.nameColorMode == .text ? .speaker : style.nameColorMode : .text },
                                          set: { value in
            update { $0.nameColorMode = value }
            model.settings.speakerColors = value != .text
            model.sendTestSubtitle()
        })
        return SettingUnit(title: "Character Name",
                           hint: mode.wrappedValue == .text ? "The character name is shown in the same color as the text." : nil) {
            VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                DSTabs(selection: mode, items: [(NameColorMode.text, "Same as Text"), (.single, "Single Color"), (.speaker, "By Character"), (.line, "Whole Line")])
                switch mode.wrappedValue {
                case .text:
                    EmptyView()
                case .single:
                    SwatchGrid(swatches: SubtitlePalette.names, selected: style.nameHex ?? SubtitlePalette.names[0].hex) { swatch in
                        update { $0.nameHex = swatch.hex }
                        model.sendTestSubtitle()
                    }
                case .speaker, .line:
                    CharacterColors()
                }
            }
        }
    }
}

/// Renk yuvarlakları; sığmazsa alt satıra iner (dar telefonlarda 8 renk tek satıra sığmaz).
private struct SwatchGrid: View {
    let swatches: [SubtitlePalette.Swatch]
    let selected: String?
    var size: CGFloat = 32
    let pick: (SubtitlePalette.Swatch) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 10, maximum: size + 14), spacing: Mobile.Space.hair, alignment: .leading)],
                  alignment: .leading, spacing: Mobile.Space.inline) {
            ForEach(swatches, id: \.self) { swatch in
                Button { pick(swatch) } label: {
                    ColorDot(color: SubtitlePalette.color(swatch.hex), selected: swatch.hex == selected, size: size)
                        .frame(width: size + 10, height: size + 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(swatch.name)))
                .accessibilityAddTraits(swatch.hex == selected ? [.isSelected] : [])
            }
        }
        .animation(DS.animation(.short, reduced: false), value: selected)
    }
}

/// Renk yuvarlağı: seçiliyken amber halka; "Zeminsiz" için dama deseni (Mac'teki DSColorDot).
private struct ColorDot: View {
    let color: Color?
    let selected: Bool
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            if let color {
                Circle().fill(color)
            } else {
                Canvas { context, area in
                    let cell: CGFloat = 5
                    for row in 0..<Int(ceil(area.height / cell)) {
                        for column in 0..<Int(ceil(area.width / cell)) {
                            let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                            context.fill(Path(rect), with: .color((row + column).isMultiple(of: 2) ? Color.dsBorder : Color.dsSurface))
                        }
                    }
                }
                .clipShape(Circle())
            }
            Circle().strokeBorder(Color.black.opacity(0.12))
        }
        .frame(width: size, height: size)
        .padding(selected ? 4 : 0)
        .overlay(Circle().strokeBorder(selected ? Color.dsAmber : Color.dsSwitchOff, lineWidth: selected ? 2 : 1))
        .padding(selected ? -4 : 0)
        .scaleEffect(selected ? 1.06 : 1)
    }
}

/// "Karaktere Göre": bu oturumda görülen (ve rengi seçilmiş) karakterler; her birinin rengi seçilebilir (Mac ile aynı).
private struct CharacterColors: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        let style = model.settings.style
        let names = characters
        VStack(alignment: .leading, spacing: 0) {
            ForEach(names, id: \.self) { name in
                let key = name.lowercased()
                let current = style.characterColors[key] ?? model.speakerBook.known.first { $0.key == key }?.color
                VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                    Text(verbatim: name).font(Mobile.TypeScale.headline)
                        .foregroundStyle(SubtitlePalette.color(current) ?? Mobile.Palette.text)
                        .lineLimit(1)
                    SwatchGrid(swatches: SubtitlePalette.names, selected: current?.uppercased(), size: 24) { swatch in
                        model.settings.style.characterColors[key] = swatch.hex
                        model.settings.style.nameOnly = true
                        model.sendTestSubtitle()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Mobile.Space.inline)
                .overlay(alignment: .bottom) { RowDivider() }
            }
            Text(names.isEmpty ? "Characters you meet while playing appear here." : "New characters get colors in turn.")
                .dsMuted()
                .padding(.top, Mobile.Space.inline)
        }
    }

    private var characters: [String] {
        var seen: [String] = []
        for key in model.speakerBook.known.map(\.key) + model.settings.style.characterColors.keys.sorted() where !seen.contains(where: { $0.lowercased() == key }) {
            seen.append(key.prefix(1).uppercased() + key.dropFirst())
        }
        return Array(seen.prefix(12))
    }
}

// MARK: - Gelişmiş

private struct AdvancedPage: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        EngineTile()
        // Ekran yazıları ve altyazı okuma: dört platformda aynı başlık, aynı ad ve sıra (Mac, Windows, Android).
        Tile(spacing: Mobile.Space.unit) {
            Text("On-screen text").font(Mobile.TypeScale.cardTitle).foregroundStyle(Mobile.Palette.text)
            SettingSwitch(title: "Translate On-Screen Text Automatically", subtitle: "Objectives, menus and other text on the screen.",
                          isOn: $model.settings.autoScreenText)
            // Türler yalnız ayar açıkken görünür; dört platformda aynı ad ve sıra (bkz. ScreenTextKind). Telefon türü ayrı
            // satır değil: tek "GTA 6 Telefonunu Çevir" anahtarı onu da yazar (`translatesGamePhone`).
            if model.settings.autoScreenText {
                VStack(alignment: .leading, spacing: Mobile.Space.gap) {
                    Text("Which on-screen text to translate").font(Font.dsLabel).foregroundStyle(Mobile.Palette.secondary)
                    SettingSwitch(title: "Mission and objective text", isOn: $model.settings.screenTextMission)
                    SettingSwitch(title: "Help boxes and actions (button prompts)", isOn: $model.settings.screenTextHelp)
                    SettingSwitch(title: "Menus (pause, map, settings)", isOn: $model.settings.screenTextMenus)
                    // Menülerde çevirinin biçimi (`MenuLayout`, #1365): yanına koyu etikette ya da üstünü örterek.
                    if model.settings.screenTextMenus {
                        SettingSwitch(title: "Cover the English in menus",
                                      subtitle: "When off, the Turkish is written next to the English on a dark label. When on, the English is covered in its own background colour; icons stay visible.",
                                      isOn: $model.settings.screenTextMenuCover)
                    }
                    SettingSwitch(title: "Other on-screen text", isOn: $model.settings.screenTextOther)
                    Text("Translate the screen always translates everything.").dsMuted()
                }
                .padding(.leading, Mobile.Space.gap)
            }
            SettingSwitch(title: "Translate the GTA 6 Phone", subtitle: "Each message is translated over its own bubble.",
                          isOn: $model.settings.translatesGamePhone)
            SettingSwitch(title: "Set On-Screen Text Apart from Subtitles", subtitle: "On-screen text keeps its own colours and place, and never looks like the subtitle box.",
                          isOn: $model.settings.setTextApart)
            Button("Restore Defaults") { restoreScreenTextDefaults() }
                .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
        }
        Tile(spacing: Mobile.Space.unit) {
            Text("Subtitle reading").font(Mobile.TypeScale.cardTitle).foregroundStyle(Mobile.Palette.text)
            SettingSwitch(title: "Check Unchanged Subtitle Areas More Often",
                          subtitle: "When the subtitle area looks unchanged, read it again after 2 frames instead of 20. Uses more CPU.",
                          isOn: $model.settings.fastSubtitleDetection)
            WaitSlider(title: "Wait for a Misread Line",
                       hint: "If the text is misread, a better reading is awaited for at most this long. Recommended: 0.8 s.",
                       ms: $model.settings.misreadWaitMs)
            WaitSlider(title: "Wait for a Half-Read Line",
                       hint: "If a line shows only in part, the whole line is awaited for at most this long. Recommended: 0.3 s.",
                       ms: $model.settings.partialWaitMs)
            Button("Restore Defaults") { restoreReadingDefaults() }
                .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
        }
    }

    /// Ekran yazıları kartı varsayılana döner (Mac, Windows ve Android ile aynı alanlar).
    private func restoreScreenTextDefaults() {
        let defaults = UserSettings()
        model.settings.autoScreenText = defaults.autoScreenText
        model.settings.translatesGamePhone = defaults.translatesGamePhone
        model.settings.setTextApart = defaults.setTextApart
        model.settings.screenTextMission = defaults.screenTextMission
        model.settings.screenTextHelp = defaults.screenTextHelp
        model.settings.screenTextMenus = defaults.screenTextMenus
        model.settings.screenTextMenuCover = defaults.screenTextMenuCover
        model.settings.screenTextOther = defaults.screenTextOther
    }

    /// Altyazı okuma kartı varsayılana döner.
    private func restoreReadingDefaults() {
        model.settings.fastSubtitleDetection = UserSettings().fastSubtitleDetection
        model.settings.misreadWaitMs = SubtitlePipeline.packWaitMs
        model.settings.partialWaitMs = SubtitlePipeline.cleanWaitMs
    }
}

/// Bekleme süresi: başlık, 0–1 sn kaydırıcı (0,1 sn adım) ve açıklama; değer milisaniye olarak saklanır.
private struct WaitSlider: View {
    let title: LocalizedStringKey
    let hint: LocalizedStringKey
    @Binding var ms: Int

    var body: some View {
        let seconds = Double(min(max(ms, 0), UserSettings.waitSliderMaxMs)) / 1000
        let unit = String(localized: "sec")
        DSSliderRow(title: title, valueText: "\(seconds.formatted(.number.precision(.fractionLength(1)))) \(unit)",
                    value: Binding(get: { seconds }, set: { ms = Int(($0 * 10).rounded()) * 100 }),
                    range: 0...Double(UserSettings.waitSliderMaxMs) / 1000, step: 0.1, hint: hint)
    }
}

// MARK: - Altyazı Alanı

private struct AreaPage: View {
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        AreaTile(resetTitle: "Reset Areas")
        // Otomatik telefon okumasına ve "Ekranı çevir"e uygulanır; varsayılan Yanda Panel (dört platformda aynı).
        Tile {
            SettingUnit(title: "GTA 6 Phone Messages",
                        hint: "Side Panel: the chat is shown next to the phone, the other person on the left and you on the right. On the Bubbles: each message is translated on top of its own bubble.") {
                SegmentedTabs(options: [true: "Side Panel", false: "On the Bubbles"], selection: $model.settings.phoneMessagesPanel)
            }
        }
        ExtraAreasTile()
        AreaProfileTile(areas: model.gameAreas)
        GameProfilesTile(areas: model.gameAreas)
        Tile {
            SettingSwitch(title: "Use ready areas for known games",
                          subtitle: "When a game with ready areas (such as GTA 6) is being played, its help box and messages are read and translated automatically. Your own extra areas take precedence.",
                          isOn: $model.settings.gameAreaPresets)
        }
    }
}

// MARK: - Oyun Paketleri

/// Paketler sayfasının üstündeki anahtarlar (Mac'teki Oyun Paketleri kartı, aynı ad ve sıra).
struct PackSettingsTile: View {
    @EnvironmentObject private var model: PhoneModel
    @EnvironmentObject private var app: AppModel
    @AppStorage(UsageData.key) private var usageData = true

    var body: some View {
        Tile(spacing: Mobile.Space.unit) {
            SettingSwitch(title: "Use Game Packs",
                          subtitle: "Ready Turkish translations for some games. A line found in the pack appears instantly without going to the translation engine.",
                          isOn: $model.settings.gamePacks)
            SettingSwitch(title: "Send the English Subtitles Read to the Shared Pool",
                          subtitle: "Only the game's English text is sent, anonymously. It helps make better Turkish translations for everyone.",
                          isOn: $model.settings.sharePool)
            SettingSwitch(title: "Usage Data", subtitle: "Error and usage statistics", isOn: $usageData)
            SettingSwitch(title: "Ask Which Game I'm Playing",
                          subtitle: "If no pack recognises the game, asked once two minutes after translation starts.",
                          isOn: $model.settings.askGame)
        }
        .onChange(of: usageData) { value in app.analytics.setCollection(value) }
    }
}

// MARK: - Çıkış Ekranları

private struct OutputsPage: View {
    @Binding var path: [Route]
    @EnvironmentObject private var model: PhoneModel
    @State private var sent = false
    /// "Eşleşmeyi Kaldır" onayı.
    @State private var confirmRemove = false
    /// "IP Adresi Gir": eşli TV'nin yeni adresi elle yazılıyor.
    @State private var enteringAddress = false
    @State private var typedAddress = ""
    @State private var addressRejected = false
    @State private var applyingAddress = false
    /// "TV'de CouchSubs'ı Aç" sürüyor (düğme yükleniyor görünür, tekrar basılamaz).
    @State private var openingApp = false
    /// Biten işin kısa süre görünen sonucu ("Bağlandı") ya da açık hata metni.
    @State private var outcome: (text: String, failed: Bool)?
    @State private var lastClients = 0

    var body: some View {
        Tile(spacing: Mobile.Space.gap) {
            SectionTitle("Show subtitles on")
            // Kısa etiketler dört sekmeye sığar; anlamı altındaki cümle verir (Mac ile aynı).
            DSTabs(selection: Binding(get: { model.settings.output }, set: { choose($0) }),
                   items: [(SubtitleOutput.tv, LocalizedStringKey("TV")), (.computer, "This phone"), (.both, "Both"), (.obs, "OBS")])
            Text(outputHint).dsMuted()
            if model.settings.output.showsOnTV { tvSection }
            if model.settings.output.showsOnTV, model.testTVNotConnected, model.tvClients == 0 {
                MobileNote(text: String(localized: "The test subtitle did not reach the TV because the TV app is not connected. Open CouchSubs on the TV. If the TV shows a 6-digit code, don't type it anywhere: approve it in the “Pair this TV?” window that opens on this phone, then test again."))
            }
        }
        if model.settings.output.showsOnTV || model.settings.output == .obs { PlacementTile() }
        OBSTile()
        Tile(spacing: 0) {
            NavigationLink(value: Route.target) { ListRow(symbol: "tv", title: "Subtitle target", detail: targetName) }
            RowDivider()
            NavigationLink(value: Route.tvInstall) {
                ListRow(symbol: "arrow.down.app", title: "Install the TV app from this phone", detail: model.installedTVApp?.version)
            }
        }
        .buttonStyle(.plain)
        SecondScreenTile()
    }

    /// "Both" yalnız TV eşliyken seçilir; TV yoksa önce TV hedef ekranı açılır.
    private func choose(_ output: SubtitleOutput) {
        if output.showsOnTV, !model.hasTV {
            model.settings.output = output
            path.append(.target)
        } else {
            model.settings.output = output
        }
    }

    @ViewBuilder private var tvSection: some View {
        HStack(spacing: Mobile.Space.gap) {
            Image(systemName: "tv").font(.system(size: 18)).foregroundStyle(Mobile.Palette.secondary).frame(width: 40, height: 40)
                .background(Mobile.Palette.surface2, in: RoundedRectangle(cornerRadius: DS.radius("control")))
            VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                Text(verbatim: model.tv?.name ?? "TV").font(Mobile.TypeScale.headline)
                // Kartta TV'nin adresi de görünür: TV ağda yeni adreste bulununca yeni adres burada görünür (Mac ile aynı).
                if let tv = model.tv, !tv.host.isEmpty {
                    Text(verbatim: "\(brandName(tv.brand)) · \(tv.host)").font(Font.dsMonoValue).foregroundStyle(Mobile.Palette.tertiary)
                }
                Text(tvState).dsMuted()
            }
            Spacer(minLength: Mobile.Space.inline)
            if model.hasTV { MobilePill(text: String(localized: "Linked"), dot: model.tvClients > 0) }
        }
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Mobile.Space.inline) { tvButtons }
            ButtonStack { tvButtons }
        }
        .task(id: sent) {
            guard sent else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sent = false
        }
        .onAppear { lastClients = model.tvClients }
        .onChange(of: model.tvClients) { count in
            if lastClients == 0, count > 0 { outcome = (String(localized: "Connected"), false) }
            lastClients = count
        }
        .task(id: outcome?.text) {
            guard let shown = outcome, !shown.failed else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if outcome?.text == shown.text { outcome = nil }
        }
        // Eşli TV yanıt vermiyorsa kart kendiliğinden yeniden arar (~10 sn'de bir yoklama, ağ araması en çok 30 sn'de bir).
        .task(id: model.tv?.host) {
            while !Task.isCancelled {
                await model.checkTVReachable()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        if model.tvPairingRequest != nil {
            HStack(spacing: Mobile.Space.inline) {
                ProgressView().controlSize(.small)
                Text("Pairing… Approve the request in the window that opens.").dsMuted()
            }
        } else if openingApp {
            HStack(spacing: Mobile.Space.inline) {
                ProgressView().controlSize(.small)
                Text("Opening on the TV…").dsMuted()
            }
        }
        if let outcome {
            if outcome.failed { MobileNote(text: outcome.text) } else { DSSuccessBadge(text: LocalizedStringKey(outcome.text)) }
        }
        if let host = model.tvUnreachableHost, model.tvClients == 0 { unreachableBox(host) }
        if model.hasTV {
            // Eşli TV her zaman değiştirilebilir ya da kaldırılabilir (önceden eşli TV kaldırılamıyordu).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Mobile.Space.inline) { pairingButtons }
                ButtonStack { pairingButtons }
            }
            .confirmationDialog("Remove Pairing?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Pairing", role: .destructive) { model.removeTVPairing() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The paired TV will be removed. You can choose a TV again with Change the TV.")
            }
        }
        if model.tvPairingOpened, model.tvPairingRequest == nil, model.tvClients == 0 {
            InfoBox(text: String(localized: "Pairing is open for 2 minutes. Open CouchSubs on the TV; if the TV says pairing did not finish, press OK on its remote. When the TV shows a code, approve it in the window that opens on this phone."),
                    tone: Mobile.Palette.secondary)
        }
    }

    @ViewBuilder private var pairingButtons: some View {
        Button("Change the TV") { path.append(.target) }.buttonStyle(DSButtonStyle(kind: .secondary))
        Button("Remove Pairing") { confirmRemove = true }.buttonStyle(DSButtonStyle(kind: .danger))
    }

    /// "TV'yi Eşleştir" / "Deneme Altyazısı Gönder" eşli TV'ye ulaşamadı ve TV ağda bulunamadı: açık hata, yeniden arama ve
    /// elle adres girişi (önceden düğmeler hiçbir şey göstermiyordu).
    @ViewBuilder private func unreachableBox(_ host: String) -> some View {
        MobileNote(text: String(format: String(localized: "The TV isn't responding at %@. Its address may have changed."), host))
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Mobile.Space.inline) { unreachableButtons }
            ButtonStack { unreachableButtons }
        }
        if enteringAddress {
            TVAddressField(label: TVText.address, text: $typedAddress)
                .onChange(of: typedAddress) { _ in addressRejected = false }
            if addressRejected { MobileNote(text: String(localized: "No TV was recognised at this address.")) }
            Button("Add") {
                applyingAddress = true
                Task {
                    let used = await model.useTVAddress(typedAddress)
                    applyingAddress = false
                    addressRejected = !used
                    if used {
                        enteringAddress = false
                        typedAddress = ""
                    }
                }
            }
            .buttonStyle(DSButtonStyle(kind: .primary, busy: applyingAddress))
            .disabled(applyingAddress || typedAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder private var unreachableButtons: some View {
        Button("Search for the TV Again") { Task { await model.searchTVAgain() } }
            .buttonStyle(DSButtonStyle(kind: .secondary, busy: model.tvSearching))
            .disabled(model.tvSearching)
        Button("Enter IP Address") { enteringAddress = true }.buttonStyle(DSButtonStyle(kind: .secondary))
    }

    /// Marka adı çevrilmez (katalog anahtarı değil; Android'deki pairedTvDetail ile aynı).
    private func brandName(_ brand: TVBrand) -> String {
        switch brand {
        case .lg: "LG"
        case .samsung: "Samsung"
        case .androidTV: "Android TV"
        }
    }

    @ViewBuilder private var tvButtons: some View {
        if sent {
            DSSuccessBadge(text: "Sent")
        } else {
            Button("Send Test Subtitle") {
                model.sendTestSubtitle()
                sent = true
            }
            .buttonStyle(DSButtonStyle(kind: .secondary))
        }
        // TV yoksa "TV'yi Bağla", eşli ama TV uygulaması bağlı değilse "TV'de CouchSubs'ı Aç", bağlıyken eşleştirme düğmesi
        // yok (önceden eşli ve bağlı TV'de de "TV'yi Eşleştir" duruyordu; Mac ve Windows ile aynı).
        if !model.hasTV {
            Button("Pair the TV") { path.append(.target) }
                .buttonStyle(DSButtonStyle(kind: .secondary))
        } else if model.tvClients == 0 {
            Button(openingApp ? "Opening on the TV…" : "Open CouchSubs on the TV") {
                openingApp = true
                outcome = nil
                Task {
                    let connected = await model.openTVAppOnTV()
                    openingApp = false
                    // TV'ye ulaşılamadıysa kartta zaten açık hata ve çözümler var.
                    if !connected, model.tvUnreachableHost == nil {
                        outcome = (String(localized: "The TV app did not connect. Make sure the TV is on and on the same network, then try again."), true)
                    }
                }
            }
            .buttonStyle(DSButtonStyle(kind: .secondary, busy: openingApp))
            .disabled(openingApp)
        }
    }

    private var outputHint: LocalizedStringKey {
        switch model.settings.output {
        case .tv: "Subtitles are shown on the TV."
        case .computer: "Subtitles are shown on this phone's screen."
        case .both: "Subtitles are shown on the TV and on this phone's screen."
        case .obs: "Only for streaming: subtitles go to the OBS overlay."
        }
    }

    private var tvState: LocalizedStringKey {
        guard model.hasTV else { return "Not Set Up" }
        if model.tvClients > 0, let version = model.installedTVApp?.version {
            return LocalizedStringKey(String(format: String(localized: "TV app %@ · Connected."), version))
        }
        return model.tvClients > 0 ? "Connected" : LocalizedStringKey(model.tvStatusText)
    }

    private var targetName: String {
        if model.settings.output == .computer { return String(localized: "This phone") }
        if model.settings.output == .obs { return String(localized: "OBS only (stream)") }
        if model.settings.output == .both, model.hasTV { return String(format: String(localized: "%@ and this phone"), model.tv?.name ?? "TV") }
        return model.hasTV ? model.tv?.name ?? "TV" : String(localized: "Not set up")
    }
}

// MARK: - Konsol ve Kaynak

private struct ConsolePage: View {
    @Binding var path: [Route]
    @EnvironmentObject private var model: PhoneModel

    var body: some View {
        Tile(spacing: 0) {
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
        }
        .buttonStyle(.plain)
        if !model.isXbox && model.console != nil { ConsoleAddressTile() }
        if !model.isXbox { LoginPasscodeTile() }
        // Yalnız Xbox: uzaktan oynatmada Xbox sesi istemciye verip TV'yi susturabilir (PS5'te ses TV'de kalır).
        if model.isXbox {
            Tile {
                SettingSwitch(title: "Play Xbox sound on this device",
                              subtitle: "While remote play is running, the Xbox mutes the TV and sends game sound only to this device (an Xbox limitation). If you turn this off, the game has no sound. To hear it from the TV or speakers, connect this phone to a Bluetooth speaker or headphones.",
                              isOn: $model.settings.xboxAudioOnDevice)
            }
        }
        if model.asksTVInput {
            // Kurulumda seçilen TV girişi; değişince TV uygulaması o girişi açar (style.hdmiInput).
            Tile {
                SettingUnit(title: "TV input (HDMI)") {
                    DSTabs(selection: Binding(get: { model.settings.style.hdmiInput }, set: { value in
                        model.settings.style.hdmiInput = value
                        model.sendTestSubtitle()
                    }), items: (1...4).map { (Int?.some($0), LocalizedStringKey("HDMI \($0)")) })
                }
            }
        }
        Tile {
            SectionTitle("Language")
            SettingUnit(title: "Game language", hint: "Online engines only translate English games. Other game languages use the free translation.") {
                DSSelect(selection: $model.settings.sourceLanguage,
                         options: [("en", String(localized: "English")), ("ja", String(localized: "Japanese")), ("de", String(localized: "German")),
                                   ("fr", String(localized: "French")), ("es", String(localized: "Spanish"))])
            }
        }
        DemoModeTile(path: $path)
    }
}

/// Konsol ve Kaynak › "IP Adresi Gir": PS5'in yeni adresi elle yazılır (adres değişip PS5 ağda bulunamazsa; Mac
/// ConsoleSettingsCard ve Android ile aynı). Kayıt korunur, bağlıysa yeni adresle yeniden bağlanılır.
private struct ConsoleAddressTile: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var entering = false
    @State private var typed = ""
    @State private var rejected = false

    var body: some View {
        Tile {
            ListRow(symbol: "network", title: "PS5 and connection", detail: model.console?.host)
            Button("Enter IP Address") { entering.toggle() }.buttonStyle(DSButtonStyle(kind: .secondary))
            if entering {
                DSFieldChrome {
                    TextField("IP address, e.g. 192.168.1.20", text: $typed)
                        .keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: typed) { _ in rejected = false }
                } trailing: {
                    Button("Save") {
                        rejected = !model.enterConsoleAddress(typed)
                        if !rejected {
                            entering = false
                            typed = ""
                        }
                    }
                    .font(Mobile.TypeScale.headline)
                    .foregroundStyle(Mobile.Palette.accentText)
                    .padding(.horizontal, Mobile.Space.gap)
                    .frame(minHeight: Mobile.Control.icon)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if rejected { MobileNote(text: String(localized: "This is not a valid IP address. Type it like 192.168.1.20, without http:// or a port number.")) }
            }
        }
    }
}

// MARK: - TV girişi (HDMI)

/// Kurulum › TV Girişi (Mac'teki 06 · TV Girişi): dört giriş; seçim TV uygulamasına gider (style.hdmiInput, TV o girişi
/// açar). "Bilmiyorum, Sırayla Dene" girişleri sırayla açar, görüntü görülünce onaylanır. Yalnız TV eşli, altyazı TV'de ve
/// TV Android TV değilken sorulur (`PhoneModel.asksTVInput`).
struct HDMIScreen: View {
    @EnvironmentObject private var model: PhoneModel
    var onBack: (() -> Void)?
    var onDone: () -> Void
    @State private var trying = false
    @State private var confirmed = false

    var body: some View {
        let selected = model.settings.style.hdmiInput
        MobileScreen {
            SetupHeader(step: 3, onBack: onBack)
        } content: {
            ScreenTitle(caption: LocalizedStringKey(String(localized: "Setup · Step 3/3") + " · " + String(localized: "TV input")),
                        title: "Which TV Input Is the PS5 Plugged Into?",
                        message: "CouchSubs opens this input on the TV to show subtitles over the game. If the wrong input is chosen, the screen stays black.")
            HStack(spacing: Mobile.Space.inline) {
                ForEach(1...4, id: \.self) { port in
                    Button { choose(port, auto: false) } label: {
                        VStack(spacing: Mobile.Space.hair) {
                            Text(verbatim: "HDMI").font(.dsMono).foregroundStyle(Mobile.Palette.secondary)
                            Text(verbatim: "\(port)").font(.system(size: 26, weight: .bold))
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                    }
                    .buttonStyle(DSOptionStyle(selected: selected == port && !trying, radio: false))
                    .accessibilityLabel(Text(verbatim: "HDMI \(port)"))
                }
            }
            Button { choose(selected.map { $0 % 4 + 1 } ?? 1, auto: true) } label: {
                VStack(alignment: .leading, spacing: Mobile.Space.hair) {
                    Text("I Don't Know, Try Them in Turn").font(Mobile.TypeScale.headline)
                    Text("We open the inputs one by one; you confirm when you see the picture.").dsMuted()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(DSOptionStyle(selected: trying))
            Tile {
                if let selected {
                    MobilePill(text: trying ? String(format: String(localized: "HDMI %lld · Trying"), selected) : "HDMI \(selected)")
                }
                Text("Do You See the Game Picture on the TV?").font(Mobile.TypeScale.cardTitle)
                if confirmed {
                    DSSuccessBadge(text: "Confirmed", fullWidth: true)
                } else {
                    ButtonStack {
                        Button("Yes") { confirmed = true; trying = false }
                            .buttonStyle(.mobilePrimary)
                            .disabled(selected == nil)
                        Button("No, Next Input") { choose((selected ?? 0) % 4 + 1, auto: trying) }
                            .buttonStyle(.mobileSecondary)
                    }
                }
                Text("The choice is remembered. You can change it later in Settings › Consoles.").dsMuted()
            }
            Tile {
                Text("How Do I Tell?").font(Mobile.TypeScale.headline)
                Text("The number is printed on the back of the TV next to the port the PS5 cable is plugged into. If the PS5 is plugged into a sound system (soundbar, amplifier), choose the input the sound system is connected to.")
                    .dsMuted()
            }
        } bottom: {
            if let selected {
                Text(LocalizedStringKey(String(format: String(localized: "HDMI %lld saved."), selected))).dsMuted()
            }
            Button("Continue", action: onDone).buttonStyle(.mobilePrimary)
        }
    }

    private func choose(_ port: Int, auto: Bool) {
        trying = auto
        confirmed = false
        model.settings.style.hdmiInput = port
        model.sendTestSubtitle()
    }
}
