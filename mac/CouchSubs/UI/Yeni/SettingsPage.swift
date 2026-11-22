// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// Ayarların bölümleri (tuval 19–25). Profil sayfası yok; her şey burada. Solda üstte üç bölüm (Temel, Altyazı Görünümü,
/// Gelişmiş), altında altı sayfa.
enum SettingsSection: Hashable, CaseIterable {
    case basics, appearance, advanced, area, packs, dubbing, outputs, shortcuts, console

    var title: LocalizedStringKey {
        switch self {
        case .basics: "Basics"
        case .appearance: "Subtitle Appearance"
        case .advanced: "Advanced"
        case .area: "Subtitle Area"
        case .packs: "Game Packs"
        case .dubbing: "Turkish Dubbing"
        case .outputs: "Output Screens"
        case .shortcuts: "Keyboard Shortcuts"
        case .console: "Console and Source"
        }
    }

    var hint: LocalizedStringKey? {
        switch self {
        case .basics: "Translation, Sound"
        case .appearance: "Size, Colors"
        case .advanced: "Engine, Experimental"
        default: nil
        }
    }

    static let main: [SettingsSection] = [.basics, .appearance, .advanced]
    static let pages: [SettingsSection] = [.area, .packs, .dubbing, .outputs, .shortcuts, .console]
}

/// Ayarlar sekmesi: 240 genişlikte gezinme kartı ve seçili bölüm.
struct SettingsPage: View {
    @Binding var section: SettingsSection
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            SettingsNav(section: $section)
                .frame(width: DS.size("settingsNav"))
            Group {
                switch section {
                case .basics: BasicsSettings(section: $section)
                case .appearance: SubtitleLookSettings()
                case .advanced: AdvancedSettings()
                case .area: AreaSettings()
                case .packs: SettingsScroll { GamePacksPage() }
                case .dubbing: SettingsScroll { DubbingCard() }
                case .outputs: OutputSettings()
                case .shortcuts: SettingsScroll { ShortcutsCard() }
                case .console: ConsoleSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .id(section)
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
        .padding(DS.space("l"))
        .animation(DS.animation(.page, reduced: reduceMotion || !model.settings.transitionAnimations), value: section)
    }
}

private struct SettingsNav: View {
    @Binding var section: SettingsSection
    @EnvironmentObject private var model: AppModel

    var body: some View {
        DSCard(padding: DS.space("m"), spacing: DS.space("xxs")) {
            ForEach(SettingsSection.main, id: \.self) { item in
                NavRow(item: item, selected: item == section, height: 64) { section = item }
            }
            DSDivider().padding(.vertical, DS.space("xs"))
            ForEach(SettingsSection.pages, id: \.self) { item in
                NavRow(item: item, selected: item == section, height: 44) { section = item }
            }
            Spacer(minLength: DS.space("s"))
            Text("All settings in one place. The Profile page is gone.")
                .font(.dsCaption)
                .foregroundStyle(Color.dsFaint)
                .tracking(DS.mutedTracking)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(DS.space("s"))
        }
        .frame(maxHeight: .infinity)
    }

    private struct NavRow: View {
        let item: SettingsSection
        let selected: Bool
        let height: CGFloat
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(item.hint == nil ? .dsRow : .dsBodyStrong).foregroundStyle(Color.dsText)
                    if let hint = item.hint { Text(hint).font(.dsCaption).foregroundStyle(Color.dsFaint) }
                }
                .padding(.horizontal, DS.space("m"))
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(selected || hovering ? Color.dsField : Color.clear,
                            in: RoundedRectangle(cornerRadius: item.hint == nil ? 14 : DS.radius("tile"), style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }
}

/// Eski kartlardan kurulan sayfalar için kayan tek sütun.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: DS.space("l")) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, DS.space("l"))
        }
        .scrollIndicators(.automatic)
    }
}

/// İki eşit sütun; sütunlar kendi içinde kayar.
private struct TwoColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            ScrollView(.vertical) { VStack(spacing: DS.space("l")) { left }.padding(.bottom, 1) }
                .frame(maxWidth: .infinity)
            ScrollView(.vertical) { VStack(spacing: DS.space("l")) { right }.padding(.bottom, 1) }
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Temel

/// Hızlı / Dengeli / Doğru: bozuk ve yarım okunan satır beklemelerinin hazır değerleri (Gelişmiş'teki kaydırıcılarla aynı
/// iki ayar; Windows aynı değerleri kullanır, METINLER.md).
enum TranslationPace: Hashable, CaseIterable {
    case fast, balanced, accurate

    var waits: (misread: Int, partial: Int) {
        switch self {
        case .fast: (400, 0)
        case .balanced: (SubtitlePipeline.packWaitMs, SubtitlePipeline.cleanWaitMs)
        case .accurate: (1000, 800)
        }
    }

    static func of(_ settings: UserSettings) -> TranslationPace? {
        allCases.first { $0.waits.misread == settings.misreadWaitMs && $0.waits.partial == settings.partialWaitMs }
    }

    var explanation: LocalizedStringKey {
        switch self {
        case .fast: "Subtitles arrive as fast as possible; you may rarely see half a sentence."
        case .balanced: "Recommended for most games. Speed and accuracy balanced."
        case .accurate: "Translated once the sentence is complete; arrives about half a second later."
        }
    }
}

private struct BasicsSettings: View {
    @Binding var section: SettingsSection
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            VStack(spacing: DS.space("l")) {
                DSCard {
                    DSCardHeader("TRANSLATION")
                    let pace = Binding<TranslationPace?>(get: { TranslationPace.of(model.settings) }, set: { value in
                        guard let value else { return }
                        model.settings.misreadWaitMs = value.waits.misread
                        model.settings.partialWaitMs = value.waits.partial
                    })
                    DSTabs(selection: pace, items: [(TranslationPace?.some(.fast), "Fast"), (TranslationPace?.some(.balanced), "Balanced"), (TranslationPace?.some(.accurate), "Accurate")])
                    if let current = pace.wrappedValue {
                        Text(current.explanation).dsMuted()
                    } else {
                        Text("These waits only delay lines that were read badly; most lines are shown without waiting. A shorter wait shows those lines sooner but lets more wrong translations through.").dsMuted()
                    }
                    DSRow(title: "Translation Language", subtitle: "The game language is detected by itself.", divider: false) {
                        Text(verbatim: Locale.current.localizedString(forLanguageCode: model.settings.targetLanguage) ?? model.settings.targetLanguage)
                            .font(.dsBodyStrong)
                    }
                }
                DSCard(spacing: DS.space("xs")) {
                    DSCardHeader("SOUND")
                    DSSwitchRow(title: "Startup Sound", subtitle: "Plays only on the first launch.", isOn: $model.settings.startupSound)
                    DSSwitchRow(title: "Transition Animations", subtitle: "When off, only a short fade is used.",
                                isOn: $model.settings.transitionAnimations)
                    HStack(spacing: DS.space("m")) {
                        Text("Appearance").font(.dsBody.weight(.medium))
                        DSTabs(selection: $model.settings.appearance,
                               items: [(AppAppearance.light, "Light"), (.dark, "Dark"), (.system, "Follow System")])
                    }
                    .padding(.top, DS.space("s"))
                }
            }
            .frame(maxWidth: .infinity)
            DSCard {
                DSCardHeader("SUBTITLE APPEARANCE")
                SubtitlePreviewBox(lines: [SubtitleSample.lines[0]], height: 180).frame(maxWidth: .infinity)
                Text("Text size, background, text and character name colors. The settings apply the same on the TV, phone and computer screen.")
                    .dsMuted(.system(size: 14))
                Spacer(minLength: 0)
                Button { section = .appearance } label: {
                    HStack {
                        Text("Edit Subtitle Appearance")
                        Spacer()
                        Text(verbatim: "→").accessibilityHidden(true)
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Altyazı Görünümü

/// Tuvaldeki renk listeleri (Windows aynı değerleri kullanır).
enum SubtitlePalette {
    struct Swatch: Hashable {
        /// Katalog anahtarı (İngilizce).
        let name: String
        let hex: String?

        static func == (lhs: Swatch, rhs: Swatch) -> Bool { lhs.hex == rhs.hex }
        func hash(into hasher: inout Hasher) { hasher.combine(hex) }
    }

    static let backgrounds: [Swatch] = [
        Swatch(name: "Black", hex: "#101014"), Swatch(name: "Navy", hex: "#0E1A30"), Swatch(name: "Dark Gray", hex: "#2B2D33"),
        Swatch(name: "Brown", hex: "#2A1F14"), Swatch(name: "White", hex: "#FFFFFF"), Swatch(name: "Cream", hex: "#F3EEE4"),
        Swatch(name: "No Background", hex: nil),
    ]
    static let texts: [Swatch] = [
        Swatch(name: "White", hex: "#FFFFFF"), Swatch(name: "Cream", hex: "#F3EEE4"), Swatch(name: "Yellow", hex: "#FFE066"),
        Swatch(name: "Light Blue", hex: "#BFE3FF"), Swatch(name: "Black", hex: "#111114"), Swatch(name: "Navy", hex: "#0E1A30"),
        Swatch(name: "Dark Gray", hex: "#2B2D33"),
    ]
    static let names: [Swatch] = [
        Swatch(name: "Amber", hex: "#F5B83D"), Swatch(name: "Turquoise", hex: "#4FD1C5"), Swatch(name: "Pink", hex: "#FF8FAB"),
        Swatch(name: "Purple", hex: "#B794F6"), Swatch(name: "Green", hex: "#68D391"), Swatch(name: "Orange", hex: "#F6874F"),
        Swatch(name: "Red", hex: "#F56565"), Swatch(name: "Blue", hex: "#63B3ED"),
    ]
    /// Koyuluk: Açık / Orta / Koyu (Koyu tam örter, İngilizce altyazı görünmez).
    static let darkness: [Int] = [45, 75, 100]

    static func color(_ hex: String?) -> Color? {
        guard let hex, let (r, g, b, a) = DSTokens.rgba(hex) else { return nil }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Yeni kaydırıcı (16–50) ile TV'nin yazı boyu (1920'de 16–90 piksel) arasında doğrusal eşleme; eski büyük boylar kaybolmaz.
    static func display(_ fontSize: Int) -> Int { Int((16 + Double(min(max(fontSize, 16), 90) - 16) * 34 / 74).rounded()) }
    static func fontSize(_ display: Int) -> Int { Int((16 + Double(min(max(display, 16), 50) - 16) * 74 / 34).rounded()) }

    /// Seçili yazı rengi (eski kayıtta textHex yok: beyaz ya da sarı).
    static func textHex(_ style: SubtitleStyle) -> String { style.textHex ?? (style.textColor == .yellow ? "#FFE066" : "#FFFFFF") }

    /// Yarı saydam zemin TV görüntüsüyle karışır: kontrast karışık renge göre (WCAG 4.5).
    static func lowContrast(_ style: SubtitleStyle) -> Bool {
        let scene = (109.0 / 255, 106.0 / 255, 93.0 / 255)
        let alpha = Double(max(0, min(100, style.background))) / 100
        let bg = DSTokens.rgba(style.backgroundColor) ?? (0, 0, 0, 1)
        let mixed = (bg.0 * alpha + scene.0 * (1 - alpha), bg.1 * alpha + scene.1 * (1 - alpha), bg.2 * alpha + scene.2 * (1 - alpha))
        let text = DSTokens.rgba(textHex(style)) ?? (1, 1, 1, 1)
        func lum(_ c: (Double, Double, Double)) -> Double {
            func l(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * l(c.0) + 0.7152 * l(c.1) + 0.0722 * l(c.2)
        }
        let (x, y) = (lum((text.0, text.1, text.2)), lum(mixed))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05) < 4.5
    }
}

/// Önizlemedeki örnek satırlar (tuvaldeki gibi).
enum SubtitleSample {
    static let lines: [(who: String, text: String)] = [
        ("Jason", "Tamam. Gidelim."), ("Lucia", "Yakınımda kal. Bunu birlikte yapacağız."), ("Cal", "Bir sürü silah sesi duyuyorum!"),
    ]
}

/// TV önizlemesi: oyun sahnesi üstünde altyazı kutuları, ayarların renk ve boyuyla.
struct SubtitlePreviewBox: View {
    @EnvironmentObject private var model: AppModel
    let lines: [(who: String, text: String)]
    var height: CGFloat?

    var body: some View {
        let style = model.settings.style
        let display = SubtitlePalette.display(style.fontSize)
        DSScreenFrame {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    (Text(verbatim: model.settings.showSpeakerNames ? line.who + ": " : "").foregroundColor(nameColor(line.who, index: index, style: style))
                     + Text(verbatim: line.text).foregroundColor(SubtitlePalette.color(SubtitlePalette.textHex(style)) ?? .white))
                        .font(.system(size: CGFloat(display) * 0.5, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.space("s"))
                        .padding(.vertical, 6)
                        .background((SubtitlePalette.color(style.backgroundColor) ?? .black).opacity(Double(style.background) / 100),
                                    in: RoundedRectangle(cornerRadius: DS.radius("small")))
                        .shadow(color: style.background == 0 ? .black.opacity(0.85) : .clear, radius: 1.5, y: 1)
                }
            }
            .padding(DS.space("m"))
        }
        .frame(height: height)
        .aspectRatio(height == nil ? 16 / 9 : nil, contentMode: .fit)
        .animation(DS.animation(.medium, reduced: !model.settings.transitionAnimations), value: style)
    }

    private func nameColor(_ who: String, index: Int, style: SubtitleStyle) -> Color {
        switch style.nameColorMode {
        case .text: return SubtitlePalette.color(SubtitlePalette.textHex(style)) ?? .white
        case .single: return SubtitlePalette.color(style.nameHex ?? SubtitlePalette.names[0].hex) ?? .dsAmber
        case .speaker:
            let hex = style.characterColors[who.lowercased()] ?? SubtitlePalette.names[(index + 1) % SubtitlePalette.names.count].hex
            return SubtitlePalette.color(hex) ?? .dsAmber
        }
    }
}

private struct SubtitleLookSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var size: Double = 30

    var body: some View {
        let style = model.settings.style
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard {
                DSCardHeader("SUBTITLES ON THE TV")
                SubtitlePreviewBox(lines: SubtitleSample.lines)
                if SubtitlePalette.lowContrast(style) {
                    Text("The text color is too close to the background; it may be hard to read on the TV.")
                        .font(.dsSmall).foregroundStyle(Color.dsLive)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                Text("The settings apply the same on the TV, phone and computer screen.").dsMuted()
                Button("Send Test Subtitle") { model.sendTestSubtitle() }.buttonStyle(.dsSecondary)
            }
            .frame(maxWidth: .infinity)
            DSCard(spacing: 0) {
                sizeSection
                DSDivider()
                backgroundSection.padding(.vertical, DS.space("l"))
                DSDivider()
                textSection.padding(.vertical, DS.space("l"))
                DSDivider()
                nameSection.padding(.top, DS.space("l"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear { size = Double(SubtitlePalette.display(style.fontSize)) }
    }

    private func update(_ change: (inout SubtitleStyle) -> Void) {
        change(&model.settings.style)
        model.settings.style.nameOnly = true
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: DS.space("m")) {
            HStack {
                Text("Text Size").font(.dsBodyStrong)
                Spacer()
                Text(String(format: String(localized: "%lld px"), Int(size.rounded()))).font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            HStack(spacing: DS.space("s")) {
                Text(verbatim: "A").font(.dsSmall).foregroundStyle(Color.dsMuted)
                Slider(value: $size, in: 16...50) { editing in
                    if editing { model.sendTestSubtitle() }
                }
                .onChange(of: size) { value in update { $0.fontSize = SubtitlePalette.fontSize(Int(value.rounded())) } }
                .accessibilityLabel(Text("Text Size"))
                Text(verbatim: "A").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.dsMuted)
            }
            HStack {
                Text(verbatim: "16")
                Spacer()
                Text(verbatim: "50")
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.dsFaint)
            .padding(.top, -DS.space("xs"))
        }
        .padding(.bottom, DS.space("l"))
    }

    private var backgroundSection: some View {
        let style = model.settings.style
        let selected = style.background == 0 ? nil : style.backgroundColor
        let current = SubtitlePalette.backgrounds.first { $0.hex == selected }
        return VStack(alignment: .leading, spacing: DS.space("m")) {
            Text("Background Color").font(.dsBodyStrong)
            SwatchRow(swatches: SubtitlePalette.backgrounds, selected: selected) { swatch in
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
            if let current { Text(String(format: String(localized: "Selected: %@."), String(localized: String.LocalizationValue(current.name)))).dsMuted() }
            HStack(spacing: DS.space("m")) {
                Text("Darkness").font(.dsRow).frame(width: 72, alignment: .leading)
                let level = Binding<Int?>(get: {
                    guard style.background > 0 else { return nil }
                    return SubtitlePalette.darkness.min { abs($0 - style.background) < abs($1 - style.background) }
                }, set: { value in
                    guard let value else { return }
                    update { $0.background = value }
                    model.sendTestSubtitle()
                })
                DSTabs(selection: level, items: [(Int?.some(45), "Light"), (Int?.some(75), "Medium"), (Int?.some(100), "Dark")])
                    .disabled(style.background == 0)
            }
        }
    }

    private var textSection: some View {
        let style = model.settings.style
        let selected = SubtitlePalette.textHex(style)
        let current = SubtitlePalette.texts.first { $0.hex == selected }
        return VStack(alignment: .leading, spacing: DS.space("m")) {
            Text("Text Color").font(.dsBodyStrong)
            SwatchRow(swatches: SubtitlePalette.texts, selected: selected) { swatch in
                update { style in
                    style.textHex = swatch.hex
                    style.textColor = swatch.hex == "#FFE066" ? .yellow : .white
                }
                model.sendTestSubtitle()
            }
            if let current { Text(String(format: String(localized: "Selected: %@."), String(localized: String.LocalizationValue(current.name)))).dsMuted() }
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
        return VStack(alignment: .leading, spacing: DS.space("m")) {
            Text("Character Name").font(.dsBodyStrong)
            DSTabs(selection: mode, items: [(NameColorMode.text, "Same as Text"), (.single, "Single Color"), (.speaker, "By Character")])
            switch mode.wrappedValue {
            case .text:
                Text("The character name is shown in the same color as the text.").dsMuted()
            case .single:
                SwatchRow(swatches: SubtitlePalette.names, selected: style.nameHex ?? SubtitlePalette.names[0].hex) { swatch in
                    update { $0.nameHex = swatch.hex }
                    model.sendTestSubtitle()
                }
            case .speaker:
                CharacterColors()
            }
            DSSwitchRow(title: "Show Speaker Name", isOn: $model.settings.showSpeakerNames, divider: false)
        }
    }
}

private struct SwatchRow: View {
    let swatches: [SubtitlePalette.Swatch]
    let selected: String?
    var size: CGFloat = 32
    let pick: (SubtitlePalette.Swatch) -> Void

    var body: some View {
        HStack(spacing: size < 32 ? DS.space("xs") : DS.space("s")) {
            ForEach(swatches, id: \.self) { swatch in
                Button { pick(swatch) } label: {
                    DSColorDot(color: SubtitlePalette.color(swatch.hex), selected: swatch.hex == selected, size: size)
                }
                .buttonStyle(.plain)
                .help(Text(LocalizedStringKey(swatch.name)))
                .accessibilityLabel(Text(LocalizedStringKey(swatch.name)))
                .accessibilityAddTraits(swatch.hex == selected ? [.isSelected] : [])
            }
        }
        .padding(4)
        .animation(DS.animation(.short, reduced: false), value: selected)
    }
}

/// "Karaktere Göre": bu oturumda görülen (ve rengi seçilmiş) karakterler; her birinin rengi seçilebilir.
private struct CharacterColors: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let style = model.settings.style
        let names = characters
        VStack(alignment: .leading, spacing: 0) {
            ForEach(names, id: \.self) { name in
                let key = name.lowercased()
                let current = style.characterColors[key] ?? model.speakerBook.known.first { $0.key == key }?.color
                HStack(spacing: DS.space("m")) {
                    Text(verbatim: name).font(.dsBodyStrong)
                        .foregroundStyle(SubtitlePalette.color(current) ?? Color.dsText)
                        .frame(width: 88, alignment: .leading)
                        .lineLimit(1)
                    SwatchRow(swatches: SubtitlePalette.names, selected: current?.uppercased(), size: 24) { swatch in
                        model.settings.style.characterColors[key] = swatch.hex
                        model.settings.style.nameOnly = true
                        model.sendTestSubtitle()
                    }
                }
                .padding(.vertical, DS.space("s"))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.dsTileBorder).frame(height: 1) }
            }
            Text(names.isEmpty ? "Characters you meet while playing appear here." : "New characters get colors in turn.")
                .dsMuted()
                .padding(.top, DS.space("s"))
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

// MARK: Gelişmiş

private struct AdvancedSettings: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        TwoColumns {
            DSCard(spacing: DS.space("xs"), scrolls: false) {
                DSCardHeader("TRANSLATION ENGINE")
                ForEach(TranslationEngine.allCases, id: \.self) { engine in
                    Button { model.settings.translationEngine = engine } label: {
                        DSTitleBlock(title: title(engine), subtitle: subtitle(engine), titleFont: .dsBodyStrong)
                    }
                    .buttonStyle(DSOptionStyle(selected: model.settings.translationEngine == engine, minHeight: 72))
                }
                engineDetails.padding(.top, DS.space("s"))
            }
        } right: {
            DSCard(spacing: DS.space("xs"), accent: .dsLive, scrolls: false) {
                DSCardHeader("EXPERIMENTAL", color: .dsLive)
                Text("These settings may slow down or interrupt translation. If there's a problem, go back to the defaults.").dsMuted()
                DSSwitchRow(title: "Translate On-Screen Text Automatically", subtitle: "Objectives, menus and other text on the screen.",
                            isOn: $model.settings.autoScreenText)
                if model.settings.autoScreenText { ScreenTextKindRows(settings: $model.settings) }
                DSSwitchRow(title: "Translate the GTA 6 Phone Automatically", subtitle: "Each message is translated over its own bubble.",
                            isOn: $model.settings.autoReadGamePhone)
                DSSwitchRow(title: "Set On-Screen Text Apart from Subtitles", subtitle: "On-screen text keeps its own colours and place, and never looks like the subtitle box.",
                            isOn: $model.settings.setTextApart)
                DSSwitchRow(title: "Check Unchanged Subtitle Areas More Often",
                            subtitle: "When the subtitle area looks unchanged, read it again after 2 frames instead of 20. Uses more CPU.",
                            isOn: $model.settings.fastSubtitleDetection)
                VStack(alignment: .leading, spacing: DS.space("s")) {
                    WaitSlider(title: "Wait for a misread line", ms: $model.settings.misreadWaitMs)
                    HintText(text: "When a line is read with words that are not in the dictionary, a better reading is awaited for at most this long. Measured in GTA V, translations from misread lines compared with 0 s: 0.2 s → 77%, 0.4 s → 49%, 0.6 s → 41%, 0.8 s (recommended) → 34%, 1.0 s → 31%.")
                    WaitSlider(title: "Wait for a half-read line", ms: $model.settings.partialWaitMs)
                    HintText(text: "When a line looks cut off (no sentence ending, such as a mission text with a colored word), the full line is awaited for at most this long. Its effect is small: at 0 s a few more lines arrive cut off. Recommended: 0.3 s.")
                }
                .padding(.vertical, DS.space("s"))
                Button("Restore Defaults") { restoreDefaults() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            }
        }
    }

    private func restoreDefaults() {
        let defaults = UserSettings()
        model.settings.autoScreenText = defaults.autoScreenText
        model.settings.autoReadGamePhone = defaults.autoReadGamePhone
        model.settings.setTextApart = defaults.setTextApart
        model.settings.fastSubtitleDetection = defaults.fastSubtitleDetection
        model.settings.misreadWaitMs = SubtitlePipeline.packWaitMs
        model.settings.partialWaitMs = SubtitlePipeline.cleanWaitMs
        model.settings.screenTextPhone = defaults.screenTextPhone
        model.settings.screenTextMission = defaults.screenTextMission
        model.settings.screenTextHelp = defaults.screenTextHelp
        model.settings.screenTextMenus = defaults.screenTextMenus
        model.settings.screenTextOther = defaults.screenTextOther
    }

    private func title(_ engine: TranslationEngine) -> LocalizedStringKey {
        switch engine {
        case .free: "Free Translation"
        case .local: "Local Model"
        default: LocalizedStringKey(engine.displayName)
        }
    }

    private func subtitle(_ engine: TranslationEngine) -> LocalizedStringKey {
        switch engine {
        case .free: "Apple's translation runs on this Mac; subtitle text never leaves it."
        case .gemini: "Better translation with a free Google key."
        case .deepL: "With your own DeepL key."
        case .openAI, .claude: "With your own key."
        case .local: "Ollama or LM Studio; no quota."
        }
    }

    @ViewBuilder private var engineDetails: some View {
        let engine = model.settings.translationEngine
        if engine != .free, model.settings.sourceLanguage != "en" {
            HintText(text: "Online engines only translate English games. Other game languages use the free translation.")
        }
        switch engine {
        case .free:
            HStack(spacing: DS.space("s")) {
                Text("For better translation, get a free Gemini key.").font(.dsSmall).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Get a Free Key") {
                    model.chooseFreeGemini()
                    openURL(AIProvider.gemini.keyPage)
                }
                .buttonStyle(.dsSecondary)
            }
        case .deepL: DeepLKeySection()
        case .gemini, .openAI, .claude:
            if let provider = engine.aiProvider { AIKeySection(provider: provider).id(provider) }
        case .local: LocalAISection()
        }
        if engine.aiProvider != nil { AIInstructionSection() }
        if engine == .gemini {
            SwitchRow(title: "I use a paid Gemini API key", isOn: $model.settings.geminiPaidTier)
            HintText(text: "Paid API keys may incur charges. Google still enforces quotas.")
            HintText(text: FreeGemini.privacy)
            if !model.settings.geminiPaidTier { HintText(text: FreeGemini.limit) }
        }
    }
}

// MARK: Altyazı Alanı

private struct AreaSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TwoColumns {
            DSCard(scrolls: false) {
                DSCardHeader("SUBTITLE AREA") {
                    Button("Refresh Picture") { model.requestSnapshot() }
                        .buttonStyle(.dsSecondary)
                        .help(Text(HotkeyText.title(model.settings, .snapshot, String(localized: "Refresh picture (%@)"))))
                }
                DSTabs(selection: Binding(get: { model.settings.areaPreset }, set: { model.settings.selectAreaPreset($0) }),
                       items: AreaPreset.allCases.map { ($0, $0.newTitle) })
                LiveRegionPreview(settings: $model.settings, preview: model.framePreview)
                if model.settings.areaPreset == .custom { CustomAreaSliders(settings: $model.settings) }
                Text("Drag the frame to move it, or grab an edge or corner to resize it. The subtitle frame should cover where the game shows its subtitles.").dsMuted()
                if model.settings.areaPreset == .full {
                    Text("While Full Screen is selected the whole screen is read, so extra areas aren't read; choosing another area reads them again.").dsMuted()
                }
                DSSwitchRow(title: "Keep Centered", isOn: $model.settings.keepAreaCentered, divider: false)
                Button("Reset Areas") { model.settings.selectAreaPreset(.bottom) }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            }
            Card(title: LocalizedStringKey(HotkeyText.title(model.settings, .screen, String(localized: "Translate the screen (%@)")))) {
                HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .screen,
                    String(localized: "Press %@ while playing: every text on the screen is translated once and shown on the TV in its own place. Press again to remove the translations."))))
            }
            // Otomatik telefon okumasına ve "Ekranı çevir"e uygulanır; varsayılan Yanda Panel (dört platformda aynı).
            DSCard(scrolls: false) {
                Text("GTA 6 Phone Messages").font(.dsBodyStrong)
                DSTabs(selection: $model.settings.phoneMessagesPanel, items: [(true, "Side Panel"), (false, "On the Bubbles")])
                Text("Side Panel: the chat is shown next to the phone, the other person on the left and you on the right. On the Bubbles: each message is translated on top of its own bubble.").dsMuted()
            }
            Card(title: LocalizedStringKey(HotkeyText.title(model.settings, .freeArea, String(localized: "Free area (%@)")))) {
                HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .freeArea,
                    String(localized: "Press %@ while playing: the picture freezes on the PC, drag over any part of it to translate that part once. Esc closes."))))
                ResultTargetPicker(target: $model.settings.freeAreaTarget)
                HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .pauseSubtitles,
                    String(localized: "%@ pauses or resumes the live subtitle translation, which helps when you translate areas."))))
            }
        } right: {
            ExtraAreasCard()
            AreaProfileCard(areas: model.gameAreas)
            GameProfilesCard(areas: model.gameAreas)
            DSCard(scrolls: false) {
                DSSwitchRow(title: "Use Ready Areas for Known Games",
                            subtitle: "When a game with ready areas (such as GTA 6) is being played, its help box and messages are read and translated automatically. Your own extra areas take precedence.",
                            isOn: $model.settings.gameAreaPresets, divider: false)
            }
        }
    }
}

extension AreaPreset {
    /// Yeni arayüzdeki sekme adı (Alt, Üst, Tam Ekran, Özel).
    var newTitle: LocalizedStringKey {
        switch self {
        case .bottom: "Bottom"
        case .top: "Top"
        case .full: "Full Screen"
        case .custom: "Custom"
        }
    }
}

// MARK: Çıkış Ekranları

private struct OutputSettings: View {
    @EnvironmentObject private var model: AppModel

    @State private var sent = false

    var body: some View {
        TwoColumns {
            DSCard(scrolls: false) {
                DSCardHeader("SHOW SUBTITLES ON")
                DSTabs(selection: $model.settings.output, items: [(SubtitleOutput.tv, "TV"), (.computer, "Computer Screen"),
                                                                  (.both, "Both"), (.obs, "OBS Only (Streaming)")])
                if model.settings.output.showsOnTV { tvSection }
                if model.settings.output == .obs {
                    HintText(text: "Subtitles go only to the OBS overlay. The TV is not searched for or opened, and no subtitle window opens on this computer. In OBS add a Browser source with this address (width 1920, height 1080).")
                    DSCopyField(text: "http://localhost:\(model.serverPort)/obs?k=\(model.subtitleAccessKey)")
                }
            }
            if model.settings.output.showsOnComputer {
                DSCard(scrolls: false) {
                    DSCardHeader("COMPUTER SCREEN")
                    Text("Subtitles appear on this computer in a window over the game or PS Remote Play.").dsMuted()
                    Button("Place the Subtitles") { model.overlayAdjusting = true }
                        .buttonStyle(.dsSecondary)
                        .disabled(model.overlayAdjusting)
                    DSSwitchRow(title: "Clicks Pass Through",
                                subtitle: LocalizedStringKey(HotkeyText.sentence(model.settings, .clickThrough,
                                    String(localized: "When on, clicks go to the window below. To turn it off press %@."))),
                                isOn: $model.settings.overlayClickThrough, divider: false)
                }
            }
            if model.settings.output.showsOnTV || model.settings.output == .obs { AppearanceCard() }
            if model.settings.output.showsOnTV { TVAppCard() }
        } right: {
            SecondScreenCard()
            OBSCard()
        }
    }

    /// TV satırı: ad, TV uygulamasının sürümü ve bağlantısı, "Eşli" rozeti; Deneme Altyazısı Gönder ve TV'yi Eşleştir.
    @ViewBuilder private var tvSection: some View {
        HStack(spacing: DS.space("m")) {
            Image(systemName: "tv").font(.system(size: 18)).foregroundStyle(Color.dsMuted).frame(width: 40, height: 40)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("control")))
            VStack(alignment: .leading, spacing: DS.space("xxs")) {
                Text(verbatim: model.tv?.name ?? "TV").font(.dsBodyStrong)
                Text(tvState).dsMuted()
            }
            Spacer(minLength: DS.space("s"))
            if model.hasTV { DSBadge(text: "Linked", tone: model.tvClients > 0 ? .ok : .unknown) }
        }
        .padding(.top, DS.space("xs"))
        HStack(spacing: DS.space("xs")) {
            if sent {
                DSSuccessBadge(text: "Sent")
            } else {
                Button("Send Test Subtitle") {
                    model.sendTestSubtitle()
                    sent = true
                }
                .buttonStyle(.dsSecondary)
            }
            Button(model.hasTV ? "Pair the TV" : "Connect TV") {
                if model.hasTV { Task { await model.openTVPairing() } } else { model.step = .tv }
            }
            .buttonStyle(.dsSecondary)
        }
        .task(id: sent) {
            guard sent else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sent = false
        }
        if model.settings.style.placement == .fixed {
            Text("In fixed position you can also move subtitles with the ▲ and ▼ buttons on the TV remote.").dsMuted()
        }
    }

    private var tvState: LocalizedStringKey {
        guard model.hasTV else { return "Not Set Up" }
        if model.tvClients > 0, case .upToDate(let version) = model.tvApp {
            return LocalizedStringKey(String(format: String(localized: "TV app %@ · Connected."), version))
        }
        return model.tvClients > 0 ? "Connected" : "TV app · Waiting for connection."
    }
}

// MARK: Konsol ve Kaynak

private struct ConsoleSettings: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TwoColumns {
            ConsoleSettingsCard()
            if !model.isXbox {
                DSCard(scrolls: false) {
                    DSCardHeader("PS5 LOGIN PASSCODE")
                    LoginPasscodeCard()
                }
            }
            AboutCard()
        } right: {
            DSCard(scrolls: false) {
                DSCardHeader("READ THE PICTURE FROM")
                if model.isXbox {
                    XboxFrameSourceCard()
                    if !model.readsXboxWindow { XboxSoundCard() }
                } else {
                    FrameSourceCard()
                }
            }
            if model.asksTVInput {
                // Kurulumda seçilen TV girişi; değişince TV uygulaması o girişi açar (style.hdmiInput).
                DSCard(scrolls: false) {
                    DSCardHeader("TV INPUT (HDMI)")
                    DSTabs(selection: Binding(get: { model.settings.style.hdmiInput }, set: { value in
                        model.settings.style.hdmiInput = value
                        model.sendTestSubtitle()
                    }), items: (1...4).map { (Int?.some($0), LocalizedStringKey("HDMI \($0)")) })
                }
            }
            DSCard(scrolls: false) {
                DSCardHeader("LANGUAGE")
                LanguageCard()
                Text("Online engines only translate English games. Other game languages use the free translation.").dsMuted()
            }
            DemoModeCard()
        }
    }
}
