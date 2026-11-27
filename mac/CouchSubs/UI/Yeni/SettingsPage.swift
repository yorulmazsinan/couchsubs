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

    /// Her bölümün iki kelimelik alt yazısı (hepsinde var; tutarlı düzen).
    var hint: LocalizedStringKey {
        switch self {
        case .basics: "Translation, Sound"
        case .appearance: "Size, Colors"
        case .advanced: "Engine, On-Screen Text"
        case .area: "Frame, Extra Areas"
        case .packs: "Ready Translations"
        case .dubbing: "Voices, Characters"
        case .outputs: "TV, OBS"
        case .shortcuts: "Translation Keys"
        case .console: "PS5, Xbox"
        }
    }

    /// Gezinme simgesi (SF Symbol).
    var icon: String {
        switch self {
        case .basics: "slider.horizontal.3"
        case .appearance: "textformat.size"
        case .advanced: "gearshape.2"
        case .area: "viewfinder"
        case .packs: "shippingbox"
        case .dubbing: "waveform"
        case .outputs: "tv"
        case .shortcuts: "keyboard"
        case .console: "gamecontroller"
        }
    }

    /// Simge karesinin tonu (tasarım paleti; amber ağırlıklı, hepsi aynı değil).
    var tint: Color {
        switch self {
        case .basics, .area: .dsAmber
        case .appearance, .console: .dsPeach
        case .advanced: .dsLive
        case .packs: .dsOlive
        case .dubbing: .dsPlum
        case .outputs: .dsTeal
        case .shortcuts: .dsSky
        }
    }

    /// Perde simge karesinin tonu (tasarim.json: peach, olive, teal, plum, sky; ana ayar amber, geliştirici gri).
    var tone: DSIconSquare.Tone {
        switch self {
        case .basics: .amber
        case .appearance: .peach
        case .advanced: .gray
        case .area, .packs: .olive
        case .dubbing: .plum
        case .outputs: .teal
        case .shortcuts: .sky
        case .console: .gray
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
    @Environment(\.dsChromeInsets) private var chrome

    var body: some View {
        // Yan menü ve bölüm içeriği pencere boyu iki ayrı kaydırma; ikisi de üst ve alt cam çubuğun arkasından kayar.
        // İlk açılışta çubukların altından başlar, en alttaki içerik kaydırınca tam görünür.
        HStack(alignment: .top, spacing: DS.space("l")) {
            ScrollView(.vertical) {
                SettingsNav(section: $section)
                    .padding(.top, chrome.top + DS.space("l"))
                    .padding(.bottom, chrome.bottom + DS.space("l"))
            }
            .scrollIndicators(.never)
            .frame(width: DS.size("settingsNav"))
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: DS.space("m")) {
                    SectionHeading(section: section)
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
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, chrome.top + DS.space("l"))
                .padding(.bottom, chrome.bottom + DS.space("l"))
            }
            .scrollIndicators(.automatic)
            .id(section)
            .transition(.opacity.combined(with: .offset(y: 8)))
        }
        .padding(.horizontal, DS.space("l"))
        .animation(DS.animation(.page, reduced: reduceMotion || !model.settings.transitionAnimations), value: section)
    }
}

/// Ayarlar'ın sol menüsü: her bölümde renkli simge karesi + ad + iki kelimelik alt yazı; seçili bölümün amber yumuşak
/// hapı bölümler arasında kayar. Kartın arkasında yavaş dolaşan sıcak renk lekeleri (SettingsNavGlow).
private struct SettingsNav: View {
    @Binding var section: SettingsSection
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        // Kart içeriği kadar uzar (pencere boyunca değil); sağdaki içerik kayarken üstte sabit kalır.
        DSCard(padding: DS.space("s"), spacing: 0, scrolls: false, backdrop: AnyView(SettingsNavGlow())) {
            VStack(alignment: .leading, spacing: DS.space("xxs")) {
                ForEach(SettingsSection.main, id: \.self) { item in row(item) }
                DSDivider().padding(.vertical, DS.space("xs")).padding(.horizontal, DS.space("s"))
                ForEach(SettingsSection.pages, id: \.self) { item in row(item) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: SettingsSection) -> some View {
        NavRow(item: item, selected: item == section, namespace: namespace) {
            withAnimation(DS.animation(.medium, reduced: reduceMotion || !model.settings.transitionAnimations)) { section = item }
        }
    }

    private struct NavRow: View {
        let item: SettingsSection
        let selected: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
            Button(action: action) {
                HStack(spacing: DS.space("s")) {
                    DSIconSquare(symbol: item.icon, tone: item.tone, size: 30)
                        .opacity(selected || hovering ? 1 : 0.85)
                    VStack(alignment: .leading, spacing: DS.space("line")) {
                        Text(item.title).font(.dsBodyStrong).foregroundStyle(Color.dsText).lineLimit(1).minimumScaleFactor(0.8)
                        Text(item.hint).font(.dsCaption).foregroundStyle(Color.dsMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.space("s"))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background {
                    if selected {
                        shape.fill(Color.dsAmberSoft)
                            .overlay(shape.strokeBorder(Color.dsAmberRing))
                            .shadow(color: Color.dsAmberGlow.opacity(0.5), radius: 10)
                            .matchedGeometryEffect(id: "navSelection", in: namespace)
                    } else if hovering {
                        shape.fill(Color.dsField.opacity(0.8))
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
        }
    }
}

/// Menü kartının arkasındaki sıcak renk lekeleri (amber, şeftali, gök mavisi; radyal, bulanıklık süzgeci yok). Durağan:
/// hareket arkadaki pencere ortam ışığında.
struct SettingsNavGlow: View {
    @Environment(\.dsMotionGate) private var gate

    static let period: Double = 24
    static let fps: Double = 15
    /// Yalnız işlemci ölçümü testi için: oynatmayı zorla aç/kapat.
    @MainActor static var forced: Bool?

    /// Tek hareket kapısı (Perde): çeviri, hareketi azalt, Geçiş Animasyonları, pencere önde değil.
    var animates: Bool { Self.forced ?? gate.ambient }

    /// Durağan lekeler: renk adı (tasarim.json), merkez, opaklık.
    static let blobs: [(String, CGFloat, CGFloat, Double)] = [("amber", 0.2, 0.12, 0.22), ("peach", 0.85, 0.5, 0.14), ("sky", 0.3, 0.92, 0.1)]

    var body: some View {
        // Perde ortam ışığının lekeleri. Arkadaki pencere ortam ışığı zaten süzüldüğü için menüdeki kopya durağan
        // (ikisi birden boşta %2'yi aşıyordu); yalnız ölçüm testi `forced` ile oynatır.
        Group {
            if Self.forced == true {
                DSAmbientGlow(intensity: 1.4)
            } else {
                GeometryReader { geometry in
                    let span = max(geometry.size.width, geometry.size.height)
                    ZStack {
                        ForEach(Self.blobs, id: \.0) { name, x, y, alpha in
                            RadialGradient(colors: [DS.color(name).opacity(alpha), DS.color(name).opacity(0)],
                                           center: UnitPoint(x: x, y: y), startRadius: 0, endRadius: span * 0.55)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Seçili bölümün başlığı: renkli simge karesi + başlık (24) + iki kelimelik alt yazı.
private struct SectionHeading: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: DS.space("s")) {
            DSIconSquare(symbol: section.icon, tone: section.tone, size: 40)
            VStack(alignment: .leading, spacing: DS.space("line")) {
                Text(section.title).font(.dsH2).foregroundStyle(Color.dsText).accessibilityAddTraits(.isHeader)
                Text(section.hint).dsMutedSmall()
            }
            Spacer(minLength: 0)
        }
    }
}

/// Eski kartlardan kurulan sayfalar için tek sütun (sayfanın kaydırmasıyla kayar).
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("l")) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// İki eşit sütun; sayfanın kaydırmasıyla birlikte kayar (cam çubukların arkasından).
private struct TwoColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            VStack(spacing: DS.space("l")) { left }.frame(maxWidth: .infinity, alignment: .top)
            VStack(spacing: DS.space("l")) { right }.frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

// MARK: Temel

private struct BasicsSettings: View {
    @Binding var section: SettingsSection
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TwoColumns {
                DSCard(scrolls: false) {
                    DSCardHeader("Translation")
                    let pace = Binding<TranslationPace?>(get: { TranslationPace.of(model.settings) }, set: { value in
                        guard let value else { return }
                        model.settings.misreadWaitMs = value.waits.misread
                        model.settings.partialWaitMs = value.waits.partial
                    })
                    DSUnit(title: "Speed", hint: pace.wrappedValue?.explanation ?? "These waits only delay lines that were read badly; most lines are shown without waiting. A shorter wait shows those lines sooner but lets more wrong translations through.") {
                        DSTabs(selection: pace, items: [(TranslationPace?.some(.fast), "Fast"), (TranslationPace?.some(.balanced), "Balanced"), (TranslationPace?.some(.accurate), "Accurate")])
                    }
                    // Bilgi (denetim değil): başlık üstte, değer altında, açıklama en altta.
                    DSUnit(title: "Translation Language", hint: "The game language is detected by itself.") {
                        Text(verbatim: Locale.current.localizedString(forLanguageCode: model.settings.targetLanguage) ?? model.settings.targetLanguage)
                            .font(.dsBody)
                    }
                }
                DSCard(scrolls: false) {
                    DSCardHeader("Sound")
                    DSSwitchRow(title: "Startup Sound", subtitle: "Plays only on the first launch.", isOn: $model.settings.startupSound)
                    DSSwitchRow(title: "Transition Animations", subtitle: "When off, only a short fade is used.",
                                isOn: $model.settings.transitionAnimations)
                    // Başlık üstte, seçici altta tam genişlik (etiket solda/denetim sağda düzeni kullanılmaz).
                    DSUnit(title: "Appearance") {
                        DSTabs(selection: $model.settings.appearance,
                               items: [(AppAppearance.light, "Light"), (.dark, "Dark"), (.system, "Follow System")])
                    }
                }
        } right: {
            DSCard(scrolls: false) {
                DSCardHeader("Subtitle appearance")
                SubtitlePreviewBox(lines: [SubtitleSample.lines[0]])
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
        }
    }
}

// MARK: Altyazı Görünümü

/// TV önizlemesi: oyun sahnesi üstünde altyazı kutuları, ayarların renk ve boyuyla.
struct SubtitlePreviewBox: View {
    @EnvironmentObject private var model: AppModel
    let lines: [(who: String, text: String)]

    var body: some View {
        let style = model.settings.style
        let display = SubtitlePalette.display(style.fontSize)
        let shape = RoundedRectangle(cornerRadius: DS.radius("preview"), style: .continuous)
        // Perde: sıcak sahne + projeksiyon ışığı; altyazı ayarların renk, zemin ve boyuyla (TV'de nasılsa öyle).
        DSPerdeScene()
            .overlay { DSProjectorLight() }
            .overlay {
                VStack(spacing: DS.space("unitHint")) {
                    Spacer(minLength: 0)
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        sample(line, index: index, style: style, size: CGFloat(display) * 0.5)
                    }
                }
                .padding(DS.space("m"))
            }
            .overlay(alignment: .topLeading) {
                DSStatusChip("Live Preview", tone: .glass, dot: false)
                    .environment(\.colorScheme, .dark)
                    .padding(DS.space("s"))
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.06)))
            // Kart genişliğini doldur, 16:9 kal. Oran hiçbir zaman nil olmamalı: nil oran Perde sahnesinin
            // ideal boyutundan (≈ birkaç pt genişlik) hesaplanıyor ve kutu ince dikey bir şeride dönüşüyordu.
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .animation(DS.animation(.medium, reduced: !model.settings.transitionAnimations), value: style)
    }

    /// Tek örnek satır: ad (ayarın renginde) + metin, zemin rengi ve koyuluğu; zeminsizken okunurluk gölgesi.
    private func sample(_ line: (who: String, text: String), index: Int, style: SubtitleStyle, size: CGFloat) -> some View {
        let name = Text(verbatim: model.settings.showSpeakerNames ? line.who + ": " : "").foregroundColor(nameColor(line.who, index: index, style: style))
        let textColor: Color = model.settings.speakerColors && style.nameColorMode == .line
            ? nameColor(line.who, index: index, style: style)
            : SubtitlePalette.color(SubtitlePalette.textHex(style)) ?? .white
        let body = Text(verbatim: line.text).foregroundColor(textColor)
        let plate: Color = (SubtitlePalette.color(style.backgroundColor) ?? .black).opacity(Double(style.background) / 100)
        let bare = style.background == 0
        return (name + body)
            .font(.system(size: size, weight: .semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.space("s"))
            .padding(.vertical, DS.space("unitHint"))
            .background(plate, in: RoundedRectangle(cornerRadius: DS.radius("small"), style: .continuous))
            .shadow(color: .black.opacity(bare ? 0.85 : 0.3), radius: bare ? 1.5 : 8, y: bare ? 1 : 5)
    }

    private func nameColor(_ who: String, index: Int, style: SubtitleStyle) -> Color {
        switch style.nameColorMode {
        case .text: return SubtitlePalette.color(SubtitlePalette.textHex(style)) ?? .white
        case .single: return SubtitlePalette.color(style.nameHex ?? SubtitlePalette.names[0].hex) ?? .dsAmber
        case .speaker, .line:
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
        TwoColumns {
            DSCard(scrolls: false) {
                DSCardHeader("Subtitles on the TV")
                SubtitlePreviewBox(lines: SubtitleSample.lines)
                if SubtitlePalette.lowContrast(style) {
                    DSNoticeBox(tone: .warning, text: "The text color is too close to the background; it may be hard to read on the TV.")
                        .transition(.opacity)
                }
                Text("The settings apply the same on the TV, phone and computer screen.").dsMuted()
                Button("Send Test Subtitle") { model.sendTestSubtitle() }.buttonStyle(.dsSecondary)
            }
        } right: {
            // Her ayar bir birim (başlık 8 → denetim 6 → açıklama); birimler arası her yerde 24.
            DSCard(scrolls: false) {
                sizeSection
                backgroundSection
                darknessSection
                textSection
                nameSection
                DSSwitchRow(title: "Show Speaker Name", isOn: $model.settings.showSpeakerNames)
            }
        }
        .onAppear { size = Double(SubtitlePalette.display(style.fontSize)) }
    }

    private func update(_ change: (inout SubtitleStyle) -> Void) {
        change(&model.settings.style)
        model.settings.style.nameOnly = true
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Text Size").font(.dsBodyStrong)
                Spacer()
                Text(String(format: String(localized: "%lld px"), Int(size.rounded()))).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Color.dsAmberText)
            }
            DSSlider(value: $size, range: 16...50, step: 1) { editing in
                if editing { model.sendTestSubtitle() }
            }
            .onChange(of: size) { value in update { $0.fontSize = SubtitlePalette.fontSize(Int(value.rounded())) } }
            .accessibilityLabel(Text("Text Size"))
            .padding(.top, DS.unitTitleGap)
            DSSliderRange(low: "16", high: "50")
                .padding(.top, DS.unitHintGap)
        }
    }

    private func selectedHint(_ swatch: SubtitlePalette.Swatch?) -> LocalizedStringKey? {
        swatch.map { LocalizedStringKey(String(format: String(localized: "Selected: %@."), String(localized: String.LocalizationValue($0.name)))) }
    }

    private var backgroundSection: some View {
        let style = model.settings.style
        let selected = style.background == 0 ? nil : style.backgroundColor
        return DSUnit(title: "Background Color", hint: selectedHint(SubtitlePalette.backgrounds.first { $0.hex == selected })) {
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
            .padding(.leading, -DS.space("xxs"))
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
        return DSUnit(title: "Darkness") {
            DSTabs(selection: level, items: [(Int?.some(45), "Light"), (Int?.some(75), "Medium"), (Int?.some(100), "Dark")])
                .disabled(style.background == 0)
        }
    }

    private var textSection: some View {
        let style = model.settings.style
        let selected = SubtitlePalette.textHex(style)
        return DSUnit(title: "Text Color", hint: selectedHint(SubtitlePalette.texts.first { $0.hex == selected })) {
            SwatchRow(swatches: SubtitlePalette.texts, selected: selected) { swatch in
                update { style in
                    style.textHex = swatch.hex
                    style.textColor = swatch.hex == "#FFE066" ? .yellow : .white
                }
                model.sendTestSubtitle()
            }
            .padding(.leading, -DS.space("xxs"))
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
        return DSUnit(title: "Character Name",
                      hint: mode.wrappedValue == .text ? "The character name is shown in the same color as the text." : nil) {
            VStack(alignment: .leading, spacing: DS.space("s")) {
                DSTabs(selection: mode, items: [(NameColorMode.text, "Same as Text"), (.single, "Single Color"), (.speaker, "By Character"), (.line, "Whole Line")])
                switch mode.wrappedValue {
                case .text:
                    EmptyView()
                case .single:
                    SwatchRow(swatches: SubtitlePalette.names, selected: style.nameHex ?? SubtitlePalette.names[0].hex) { swatch in
                        update { $0.nameHex = swatch.hex }
                        model.sendTestSubtitle()
                    }
                    .padding(.leading, -DS.space("xxs"))
                case .speaker, .line:
                    CharacterColors()
                }
            }
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
        .padding(DS.space("xxs"))
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
                VStack(alignment: .leading, spacing: DS.space("xs")) {
                    Text(verbatim: name).font(.dsBodyStrong)
                        .foregroundStyle(SubtitlePalette.color(current) ?? Color.dsText)
                        .lineLimit(1)
                    SwatchRow(swatches: SubtitlePalette.names, selected: current?.uppercased(), size: 24) { swatch in
                        model.settings.style.characterColors[key] = swatch.hex
                        model.settings.style.nameOnly = true
                        model.sendTestSubtitle()
                    }
                    .padding(.leading, -DS.space("xxs"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
                DSCardHeader("Translation engine")
                ForEach(TranslationEngine.allCases, id: \.self) { engine in
                    Button { model.settings.translationEngine = engine } label: {
                        DSTitleBlock(title: title(engine), subtitle: subtitle(engine), titleFont: .dsBodyStrong)
                    }
                    .buttonStyle(DSOptionStyle(selected: model.settings.translationEngine == engine, minHeight: 72))
                }
                engineDetails.padding(.top, DS.space("s"))
            }
        } right: {
            // Ekran yazıları ve altyazı okuma: dört platformda aynı başlık, aynı ad ve sıra (Windows, iPhone, Android).
            DSCard(scrolls: false) {
                DSCardHeader("On-screen text")
                DSSwitchRow(title: "Translate On-Screen Text Automatically", subtitle: "Objectives, menus and other text on the screen.",
                            isOn: $model.settings.autoScreenText)
                if model.settings.autoScreenText { ScreenTextKindRows(settings: $model.settings) }
                // Tek telefon anahtarı: eski "GTA 6 telefonunu otomatik çevir" ve "Telefon" türü birlikte yazılır.
                DSSwitchRow(title: "Translate the GTA 6 Phone", subtitle: "Each message is translated over its own bubble.",
                            isOn: $model.settings.translatesGamePhone)
                DSSwitchRow(title: "Set On-Screen Text Apart from Subtitles", subtitle: "On-screen text keeps its own colours and place, and never looks like the subtitle box.",
                            isOn: $model.settings.setTextApart)
                Button("Restore Defaults") { restoreScreenTextDefaults() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            }
            DSCard(scrolls: false) {
                DSCardHeader("Subtitle reading")
                DSSwitchRow(title: "Check Unchanged Subtitle Areas More Often",
                            subtitle: "When the subtitle area looks unchanged, read it again after 2 frames instead of 20. Uses more CPU.",
                            isOn: $model.settings.fastSubtitleDetection)
                VStack(alignment: .leading, spacing: DS.unitGap) {
                    WaitSlider(title: "Wait for a Misread Line",
                               hint: "If the text is misread, a better reading is awaited for at most this long. Recommended: 0.8 s.",
                               ms: $model.settings.misreadWaitMs)
                    WaitSlider(title: "Wait for a Half-Read Line",
                               hint: "If a line shows only in part, the whole line is awaited for at most this long. Recommended: 0.3 s.",
                               ms: $model.settings.partialWaitMs)
                }
                Button("Restore Defaults") { restoreReadingDefaults() }
                    .buttonStyle(DSButtonStyle(kind: .secondary, fullWidth: true))
            }
        }
    }

    /// Ekran yazıları kartı varsayılana döner (iPhone, Android ve Windows ile aynı alanlar).
    private func restoreScreenTextDefaults() {
        let defaults = UserSettings()
        model.settings.autoScreenText = defaults.autoScreenText
        model.settings.translatesGamePhone = defaults.translatesGamePhone
        model.settings.setTextApart = defaults.setTextApart
        model.settings.screenTextMission = defaults.screenTextMission
        model.settings.screenTextHelp = defaults.screenTextHelp
        model.settings.screenTextMenus = defaults.screenTextMenus
        model.settings.screenTextOther = defaults.screenTextOther
        model.settings.screenTextBeside = defaults.screenTextBeside
    }

    /// Altyazı okuma kartı varsayılana döner.
    private func restoreReadingDefaults() {
        model.settings.fastSubtitleDetection = UserSettings().fastSubtitleDetection
        model.settings.misreadWaitMs = SubtitlePipeline.packWaitMs
        model.settings.partialWaitMs = SubtitlePipeline.cleanWaitMs
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
            SwitchRow(title: "I use a paid Gemini API key", isOn: $model.settings.geminiPaidTier,
                      hint: "Paid API keys may incur charges. Google still enforces quotas.")
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
                DSCardHeader("Subtitle area") {
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
            DSCard(scrolls: false) {
                DSCardHeader("Translate the screen")
                HintText(text: LocalizedStringKey(HotkeyText.sentence(model.settings, .screen,
                    String(localized: "Press %@ while playing: every text on the screen is translated once and shown on the TV in its own place. Press again to remove the translations."))))
            }
            // Otomatik telefon okumasına ve "Ekranı çevir"e uygulanır; varsayılan Yanda Panel (dört platformda aynı).
            DSCard(scrolls: false) {
                DSCardHeader("GTA 6 phone messages")
                DSUnit(hint: "Side Panel: the chat is shown next to the phone, the other person on the left and you on the right. On the Bubbles: each message is translated on top of its own bubble.") {
                    DSTabs(selection: $model.settings.phoneMessagesPanel, items: [(true, "Side Panel"), (false, "On the Bubbles")])
                }
                // Önce yalnız Mac'te deneniyor (Sinan Bey kararı, 24 Kas); varsayılan açık.
                DSSwitchRow(title: "Redraw the Screen in Turkish in Place",
                            subtitle: "GTA 6 phone: the original text is erased and the translation is drawn in its place, right on the phone in the game window, and it moves with the phone. Works when the picture is read from a window on this Mac (Remote Play, chiaki-ng or OBS).",
                            isOn: $model.settings.drawScreenInPlace, divider: false)
            }
            // Kısayol başlıkta değil, açıklamada (diğer kart başlıkları gibi yalnız ad).
            DSCard(scrolls: false) {
                DSCardHeader("Free area")
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
    @State private var enteringAddress = false
    @State private var address = ""
    @State private var confirmRemove = false
    @State private var checking = false
    /// Kartta basılıp süren eylem (düğme bitene kadar yükleniyor görünür, tekrar basılamaz).
    @State private var busy: TVCardAction?
    /// Biten işin kısa süre görünen sonucu ("Bağlandı", "Güncellendi: 0.9.98") ya da açık hata metni.
    @State private var outcome: TVCardOutcome?
    /// Önceki durumlar: sonuç ancak bir geçişte (bağlandı, kurulum bitti) gösterilir.
    @State private var lastClients = 0
    @State private var wasInstalling = false

    private enum TVCardAction { case test, open }
    private struct TVCardOutcome: Equatable {
        let text: String
        let failed: Bool
    }

    var body: some View {
        TwoColumns {
            DSCard(scrolls: false) {
                DSCardHeader("Show subtitles on")
                // Kısa etiketler dört sekmeye sığar; anlamı altındaki cümle verir.
                DSUnit(hint: outputHint) {
                    DSTabs(selection: $model.settings.output, items: [(SubtitleOutput.tv, "TV"), (.computer, "This Mac"),
                                                                      (.both, "Both"), (.obs, "OBS")])
                }
                if model.settings.output.showsOnTV { tvSection }
                if model.settings.output == .obs {
                    HintText(text: "Subtitles go only to the OBS overlay. The TV is not searched for or opened, and no subtitle window opens on this computer. In OBS add a Browser source with this address (width 1920, height 1080).")
                    DSCopyField(text: "http://localhost:\(model.serverPort)/obs?k=\(model.subtitleAccessKey)")
                }
            }
            if model.settings.output.showsOnComputer {
                DSCard(scrolls: false) {
                    DSCardHeader("Computer screen")
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
        // Perde TV kartı: ad + mono marka · adres, sağda durum hapı (bağlıyken yeşil "Eşli").
        DSTVCard(name: model.tv?.name ?? "TV",
                 detail: model.tv.map { "\(TVBrandMark.name($0.brand)) · \($0.host)" } ?? "",
                 status: model.hasTV ? "Linked" : nil, statusTone: model.tvClients > 0 ? .ok : .muted,
                 selected: model.tvClients > 0)
        Text(tvState).dsMuted()
        // Süren iş (kendiliğinden başlayan TV uygulaması güncellemesi dahil): hangi adımda olunduğu.
        if let phase = tvPhase {
            HStack(spacing: DS.space("xs")) {
                ProgressView().controlSize(.small)
                Text(phase.title).font(.dsSmall).foregroundStyle(Color.dsMuted)
            }
            if let step = phase.step {
                Text(tvStepLine(current: step)).font(.dsSmall).foregroundStyle(Color.dsMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let outcome {
            if outcome.failed {
                DSNoticeBox(tone: .error, text: LocalizedStringKey(outcome.text)) { EmptyView() }
            } else {
                DSSuccessBadge(text: LocalizedStringKey(outcome.text))
            }
        }
        // "TV'yi Eşleştir" ve "Deneme Altyazısı Gönder" önce TV'ye ulaşılıyor mu bakar (adresi değiştiyse TV yeni adreste
        // bulunur); ulaşılamazsa açık hata, "TV'yi Yeniden Ara" ve "IP Adresi Gir". Önceden düğmeye basınca hiçbir şey olmuyordu.
        if let host = model.tvUnreachableHost {
            DSNoticeBox(tone: .warning, text: LocalizedStringKey(String(format: String(localized: "The TV isn't responding at %@. Its address may have changed."), host)))
            HStack(spacing: DS.space("xs")) {
                Button("Search for the TV Again") { run { _ = await model.searchTVAgain() } }
                    .buttonStyle(.dsSecondary)
                Button("Enter IP Address") { enteringAddress = true }
                    .buttonStyle(.dsSecondary)
            }
            .disabled(checking)
        }
        if enteringAddress {
            DSFieldChrome(mono: true) {
                TextField("IP address, e.g. 192.168.1.20", text: $address)
                    .textFieldStyle(.plain)
                    .onSubmit(useAddress)
            } trailing: {
                Button("Add", action: useAddress)
                    .buttonStyle(DSButtonStyle(kind: .compact))
                    .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if model.tvAddressRejected {
                Text("No TV was recognised at this address.")
                    .font(.dsSmall).foregroundStyle(Color.dsLiveText).fixedSize(horizontal: false, vertical: true)
            }
        }
        // Düğmeler TV'nin durumuna göre: TV yoksa "TV'yi Bağla", seçili ama eşli değilse "TV'yi Eşleştir", eşli ama TV
        // uygulaması bağlı değilse "TV'de CouchSubs'ı Aç", bağlıyken eşleştirme düğmesi yok (önceden eşli ve bağlı TV'de de
        // "TV'yi Eşleştir" duruyordu).
        HStack(spacing: DS.space("xs")) {
            if sent {
                DSSuccessBadge(text: "Sent")
            } else {
                Button(busy == .test ? "Sending…" : "Send Test Subtitle") {
                    act(.test) {
                        guard await model.ensureTVReachable() else { return }
                        model.sendTestSubtitle()
                        sent = true
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, busy: busy == .test))
            }
            if !model.hasTV {
                Button("Pair the TV") { model.step = .tv }.buttonStyle(.dsSecondary)
            } else if model.tvClients == 0 {
                Button(busy == .open ? "Opening on the TV…" : "Open CouchSubs on the TV") {
                    act(.open) {
                        let connected = await model.openTVAppOnTV()
                        // TV'ye ulaşılamadıysa kartta zaten açık hata ve çözümler var.
                        if !connected, model.tvUnreachableHost == nil {
                            show(TVCardOutcome(text: String(localized: "The TV app did not connect. Make sure the TV is on and on the same network, then try again."), failed: true))
                        }
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, busy: busy == .open))
            }
        }
        .disabled(checking || model.tvApp == .working)
        .task(id: sent) {
            guard sent else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sent = false
        }
        // Kart görünürken TV uygulaması bağlı değilse adres yoklanır; TV yeni adreste bulunursa kartta yeni adres görünür.
        .task(id: model.tv?.host) {
            while !Task.isCancelled {
                await model.checkTVReachable()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        // Biten işin sonucu kısa süre görünür.
        .onAppear {
            lastClients = model.tvClients
            wasInstalling = model.tvApp == .working
        }
        .onChange(of: model.tvClients) { count in
            if lastClients == 0, count > 0 { show(TVCardOutcome(text: String(localized: "Connected"), failed: false)) }
            lastClients = count
        }
        .onChange(of: model.tvApp) { state in
            defer { wasInstalling = state == .working }
            guard wasInstalling else { return }
            switch state {
            case .upToDate(let version):
                show(TVCardOutcome(text: String(format: String(localized: "Updated: %@"), version), failed: false))
            case .failed:
                show(TVCardOutcome(text: String(localized: "The TV app could not be installed. The details are in the TV app card below."), failed: true))
            default: break
            }
        }
        .task(id: outcome) {
            guard let shown = outcome, !shown.failed else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if outcome == shown { outcome = nil }
        }
        // Eşli TV her zaman değiştirilebilir; eşleşme yalnız eşliyken kaldırılabilir.
        if model.tv != nil {
            HStack(spacing: DS.space("xs")) {
                Button("Change the TV") { model.step = .tv }.buttonStyle(.dsSecondary)
                if model.hasTV {
                    Button("Remove Pairing") { confirmRemove = true }.buttonStyle(.dsSecondary)
                }
            }
            .disabled(busy != nil)
            .confirmationDialog("Remove Pairing?", isPresented: $confirmRemove) {
                Button("Remove Pairing", role: .destructive) { model.removeTVPairing() }
            } message: {
                Text("The paired TV will be removed. You can choose a TV again with Change the TV.")
            }
        }
        if model.settings.style.placement == .fixed {
            Text("In fixed position you can also move subtitles with the ▲ and ▼ buttons on the TV remote.").dsMuted()
        }
    }

    /// Kart eylemi: düğme iş bitene kadar yükleniyor durumunda kalır, öteki düğmelere basılamaz.
    private func act(_ action: TVCardAction, _ work: @escaping @MainActor () async -> Void) {
        guard busy == nil else { return }
        busy = action
        outcome = nil
        run {
            await work()
            busy = nil
        }
    }

    private func show(_ result: TVCardOutcome) {
        withAnimation(DS.animation(.medium, reduced: !model.settings.transitionAnimations)) { outcome = result }
    }

    /// TV kartında süren iş: başlık ve (kurulum/açma akışındaysa) üç adımdan hangisinde olunduğu.
    private var tvPhase: (title: LocalizedStringKey, step: Int?)? {
        if model.tvApp == .working {
            return (model.tvAppOutdated != nil ? "Updating the TV app…" : "Installing the TV app…", 1)
        }
        if model.openingTVAppForTest { return ("Opening on the TV…", 2) }
        if model.tvPairingRequest != nil { return ("Pairing… Approve the request in the window that opens.", nil) }
        if checking, busy != nil { return ("Connecting to the TV…", 0) }
        return nil
    }

    /// "TV'ye bağlanılıyor → Uygulama kuruluyor → Açılıyor"; şu anki adım vurgulu.
    private func tvStepLine(current: Int) -> AttributedString {
        let steps = [String(localized: "Connecting to the TV"), String(localized: "Installing the app"), String(localized: "Opening")]
        var line = AttributedString()
        for (index, step) in steps.enumerated() {
            if index > 0 { line += AttributedString(" → ") }
            var part = AttributedString(step)
            if index == current { part.swiftUI.foregroundColor = Color.dsAmber }
            line += part
        }
        return line
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        checking = true
        Task {
            await action()
            checking = false
        }
    }

    private func useAddress() {
        run {
            if await model.useTVAddress(address) {
                enteringAddress = false
                address = ""
            }
        }
    }

    private var outputHint: LocalizedStringKey {
        switch model.settings.output {
        case .tv: "Subtitles are shown on the TV."
        case .computer: "Subtitles are shown in a window on this Mac's screen."
        case .both: "Subtitles are shown on the TV and on this Mac's screen."
        case .obs: "Only for streaming: subtitles go to the OBS overlay."
        }
    }

    private var tvState: LocalizedStringKey {
        guard model.hasTV else { return "Not Set Up" }
        if model.tvClients > 0, case .upToDate(let version) = model.tvApp {
            return LocalizedStringKey(String(format: String(localized: "TV app %@ · Connected."), version))
        }
        return model.tvClients > 0 ? "Connected" : LocalizedStringKey(model.tvStatusText)
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
                    DSCardHeader("PS5 login passcode")
                    LoginPasscodeCard()
                }
            }
            AboutCard()
        } right: {
            DSCard(scrolls: false) {
                DSCardHeader("Read the picture from")
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
                    DSCardHeader("TV input (HDMI)")
                    DSTabs(selection: Binding(get: { model.settings.style.hdmiInput }, set: { value in
                        model.settings.style.hdmiInput = value
                        model.sendTestSubtitle()
                    }), items: (1...4).map { (Int?.some($0), LocalizedStringKey("HDMI \($0)")) })
                }
            }
            DSCard(scrolls: false) {
                DSCardHeader("Language")
                LanguageCard()
                Text("Online engines only translate English games. Other game languages use the free translation.").dsMuted()
            }
            DemoModeCard()
        }
    }
}
