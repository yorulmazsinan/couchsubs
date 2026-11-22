// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

// Yeni arayüzün ortak bileşenleri (tuvaldeki .card, .btnp/.btnk/.btns/.btnok/.btnlive, .segwrap/.seg, .sw, .inp,
// .mono, .badge, .adband). Windows aynı adlarla aynı bileşenleri kurar (design/yeni-arayuz/METINLER.md › Bileşenler).

// MARK: Kart

/// Kart: yüzey zemin, 24 köşe, 1 pt çerçeve halkası, 24 iç boşluk. İçerik taşarsa kart kendi içinde ince çubukla kayar.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.space("l")
    var spacing: CGFloat = DS.space("m")
    /// Sol kenarda 4 pt renk şeridi (ör. Deneysel kartında kırmızı).
    var accent: Color?
    /// Seçili/etkin kartın 2 pt amber halkası.
    var highlighted = false
    var scrolls = true
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("card"), style: .continuous)
        Group {
            if scrolls {
                ViewThatFits(in: .vertical) {
                    stack
                    ScrollView(.vertical) { stack }
                        .scrollIndicators(.automatic)
                }
            } else {
                stack
            }
        }
        .background(Color.dsSurface, in: shape)
        .overlay(alignment: .leading) {
            if let accent { accent.frame(width: 4).allowsHitTesting(false) }
        }
        .overlay(shape.strokeBorder(highlighted ? Color.dsAmber : Color.dsBorder, lineWidth: highlighted ? 2 : 1))
        .clipShape(shape)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(padding)
    }
}

/// Kart başlığı (mono etiket) ile içerik arasında 24 pt kalsın diye etiketin altına 8 pt ek boşluk.
struct DSCardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var color: Color = .dsMuted
    @ViewBuilder var trailing: Trailing

    init(_ title: LocalizedStringKey, color: Color = .dsMuted, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.color = color
        self.trailing = trailing()
    }

    var body: some View {
        // Başlık + sağda düğme satırında alt boşluk satırın kendisindedir; ikisi dikeyde ortalıdır.
        HStack(alignment: .center, spacing: DS.space("s")) {
            DSMonoLabel(title, color: color)
            Spacer(minLength: DS.space("s"))
            trailing
        }
        .padding(.bottom, DS.space("xs"))
    }
}

extension DSCardHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, color: Color = .dsMuted) {
        self.title = title
        self.color = color
        self.trailing = EmptyView()
    }
}

/// Yatay ayraç (1 pt, çerçeve rengi).
struct DSDivider: View {
    var body: some View {
        Rectangle().fill(Color.dsBorder).frame(height: 1).accessibilityHidden(true)
    }
}

// MARK: Düğmeler

/// Düğme türleri: ana (amber, ekranda tek), koyu (kömür), ikincil (yüzey, ince halka), canlı/durdur (kırmızı tonlu,
/// kare ya da atan nokta), küçük koyu (reklam bandındaki İncele). Hepsi tam yuvarlak, 48 yükseklik, alt çizgisiz.
/// İşlem sürerken çağıran `.disabled(true)` verir ve "…ıyor…" yazar: düğme soluklaşır, tekrar basılamaz.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, dark, secondary, stop, live, small, danger }
    var kind: Kind = .secondary
    var fullWidth = false
    /// Yazı ile sağdaki ok arası boşluk (ör. "Altyazı Görünümünü Düzenle →").
    var spread = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, spread: spread)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let fullWidth: Bool
    let spread: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let hovered = hovering && isEnabled
        HStack(spacing: kind == .live || kind == .stop ? 10 : DS.space("xs")) {
            if kind == .stop {
                RoundedRectangle(cornerRadius: 2).fill(Color.dsLiveText).frame(width: 10, height: 10).accessibilityHidden(true)
            } else if kind == .live {
                DSPulseDot(color: .dsLive, size: 8)
            }
            configuration.label
                .lineLimit(1)
                .frame(maxWidth: spread ? .infinity : nil, alignment: .leading)
        }
        .font(kind == .secondary ? .dsButtonSecondary : kind == .small ? .system(size: 13, weight: .semibold) : .dsButton)
        .foregroundStyle(foreground)
        .padding(.horizontal, kind == .small ? DS.space("m") : kind == .secondary ? 20 : DS.space("l"))
        .frame(maxWidth: fullWidth || spread ? .infinity : nil)
        .frame(height: kind == .small ? DS.size("adCta") : DS.size("button"))
        .background(background(hovered: hovered, pressed: pressed), in: Capsule())
        .overlay { ring }
        .overlay { if isFocused { Capsule().strokeBorder(Color.dsAmberText, lineWidth: 2) } }
        .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
        .opacity(isEnabled ? 1 : 0.55)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(DS.animation(.short, reduced: reduceMotion), value: pressed)
        .animation(DS.animation(.short, reduced: reduceMotion), value: hovered)
    }

    @ViewBuilder private var ring: some View {
        switch kind {
        case .secondary: Capsule().strokeBorder(Color.dsBorder)
        case .stop, .live, .danger: Capsule().strokeBorder(Color.dsLiveRing)
        default: EmptyView()
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .dsOnAmber
        case .dark, .small: .dsOnCharcoal
        case .secondary: .dsText
        case .stop, .live, .danger: .dsLiveText
        }
    }

    private func background(hovered: Bool, pressed: Bool) -> Color {
        switch kind {
        case .primary: hovered || pressed ? .dsAmberHover : .dsAmber
        case .dark, .small: .dsCharcoal
        case .secondary: hovered || pressed ? .dsField : .dsSurface
        case .stop, .live, .danger: hovered || pressed ? Color.dsLive.opacity(0.18) : .dsLiveSoft
        }
    }
}

extension ButtonStyle where Self == DSButtonStyle {
    static var dsPrimary: DSButtonStyle { DSButtonStyle(kind: .primary) }
    static var dsDark: DSButtonStyle { DSButtonStyle(kind: .dark) }
    static var dsSecondary: DSButtonStyle { DSButtonStyle(kind: .secondary) }
    static var dsStop: DSButtonStyle { DSButtonStyle(kind: .stop) }
}

/// Başarı durumu (Eşleşti, Onaylandı, Kaydedildi): açık yeşil zemin, yeşil yazı, tik, küçük oturma animasyonu.
/// Düğme değil; aynı yerde düğmenin yerini alır.
struct DSSuccessBadge: View {
    let text: LocalizedStringKey
    var fullWidth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var seated = false

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .font(.dsButton)
        .foregroundStyle(Color.dsSuccessText)
        .padding(.horizontal, DS.space("l"))
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(height: DS.size("button"))
        .background(Color.dsSuccessSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.dsSuccessRing))
        .scaleEffect(seated || reduceMotion ? 1 : 0.94)
        .onAppear { withAnimation(DS.animation(.medium, reduced: reduceMotion)) { seated = true } }
        .accessibilityElement(children: .combine)
    }
}

/// Ataan nokta (canlı/çalışıyor). Azaltılmış harekette sabit.
struct DSPulseDot: View {
    var color: Color = .dsLive
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dsMotionOff) private var motionOff
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion && !motionOff else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: Sekme seçici

/// Tek seçimli seçici, üst menü sekme stilinde: kapsül zemin (alan rengi), seçili sekme yüzey rengi + gölge + halka.
/// `fill` true ise sekmeler genişliği eşit paylaşır (ayar seçicileri); false ise en az 112 genişlikte (üst menü).
struct DSTabs<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]
    var fill = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    init(selection: Binding<Value>, items: [(Value, LocalizedStringKey)], fill: Bool = true) {
        _selection = selection
        self.items = items.map { Item(value: $0.0, title: $0.1) }
        self.fill = fill
    }

    var body: some View {
        HStack(spacing: DS.space("xxs")) {
            ForEach(items) { item in
                let on = item.value == selection
                Button {
                    withAnimation(DS.animation(.medium, reduced: reduceMotion)) { selection = item.value }
                } label: {
                    Text(item.title)
                        .font(.dsTab)
                        .foregroundStyle(on ? Color.dsText : Color.dsMuted)
                        .lineLimit(1)
                        .padding(.horizontal, DS.space("m"))
                        .frame(minWidth: fill ? 0 : DS.size("tabMin"), maxWidth: fill ? .infinity : nil)
                        .frame(height: DS.size("tab"))
                        .background {
                            if on {
                                Capsule().fill(Color.dsSurface)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                    .overlay(Capsule().strokeBorder(Color.dsBorder))
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(DS.space("xxs"))
        .background(Color.dsField, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.dsBorder))
    }
}

// MARK: Anahtar

/// Anahtar: 44 × 26, açıkken amber (yeşil değil), düğmecik beyaz gölgeli; satır başında, yazının solunda durur.
struct DSToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DSSwitch(isOn: configuration.$isOn)
    }
}

struct DSSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let width = DS.size("switchWidth"), height = DS.size("switchHeight"), knob = DS.size("switchKnob")
        Button {
            withAnimation(DS.animation(.medium, reduced: reduceMotion)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? Color.dsAmber : Color.dsSwitchOff)
                .frame(width: width, height: height)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .padding(.horizontal, 3)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// Anahtar satırı: solda anahtar, sağında başlık ve noktalı açıklama; en az 56 yükseklik, altta ayraç.
struct DSSwitchRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool
    var divider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.space("m")) {
                DSSwitch(isOn: $isOn)
                    .accessibilityLabel(Text(title))
                DSTitleBlock(title: title, subtitle: subtitle)
                    .contentShape(Rectangle())
                    .onTapGesture { isOn.toggle() }
            }
            .padding(.vertical, DS.space("s"))
            .frame(minHeight: DS.size("row"))
            if divider { DSDivider() }
        }
    }
}

/// Bilgi satırı: solda başlık + açıklama, sağda değer ya da denetim; en az 56, altta isteğe bağlı ayraç.
struct DSRow<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var divider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.space("m")) {
                DSTitleBlock(title: title, subtitle: subtitle)
                trailing
            }
            .padding(.vertical, DS.space("s"))
            .frame(minHeight: DS.size("row"))
            if divider { DSDivider() }
        }
    }
}

// MARK: Seçenek kartı ve radyo

/// Radyo yuvarlağı: seçiliyken 6 pt amber halka, değilken 2 pt gri.
struct DSRadio: View {
    let on: Bool

    var body: some View {
        Circle()
            .strokeBorder(on ? Color.dsAmber : Color.dsSwitchOff, lineWidth: on ? 6 : 2)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

/// Seçenek kartı (tuvaldeki SEL): en az 64 (ya da 72) yükseklik, 16 köşe, seçiliyken 2 pt amber halka; solda radyo.
struct DSOptionStyle: ButtonStyle {
    var selected: Bool
    var minHeight: CGFloat = DS.size("option")
    var radio = true

    func makeBody(configuration: Configuration) -> some View {
        DSOptionBody(configuration: configuration, selected: selected, minHeight: minHeight, radio: radio)
    }
}

private struct DSOptionBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let minHeight: CGFloat
    let radio: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        HStack(spacing: DS.space("m")) {
            if radio { DSRadio(on: selected) }
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.space("m"))
        .padding(.vertical, DS.space("xs"))
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background(hovering && !selected ? Color.dsField : Color.dsSurface, in: shape)
        .overlay(shape.strokeBorder(selected ? Color.dsAmber : Color.dsBorder, lineWidth: selected ? 2 : 1))
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(DS.animation(.short, reduced: reduceMotion), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: Giriş kutusu

/// Giriş kutusu: tam yuvarlak, 48 yükseklik, alan zemini, ince halka; odakta amber halka. Etiket → kutu 12 pt.
struct DSTextFieldStyle: TextFieldStyle {
    var mono = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        DSFieldChrome(mono: mono) { configuration.textFieldStyle(.plain) }
    }
}

/// Kutunun kendisi; SecureField ve TextField ikisi de içine konur. `trailing` kutunun içinde sağda (kopyala simgesi).
struct DSFieldChrome<Field: View, Trailing: View>: View {
    var mono = false
    @ViewBuilder var field: Field
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            field
                .focused($focused)
                .font(mono ? .system(size: 13, weight: .regular, design: .monospaced) : .dsBody)
                .foregroundStyle(Color.dsText)
            trailing
        }
        .padding(.leading, DS.space("m"))
        .padding(.trailing, Trailing.self == EmptyView.self ? DS.space("m") : DS.space("xs"))
        .frame(height: DS.size("input"))
        .background(Color.dsField, in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Color.dsAmber : Color.dsBorder, lineWidth: focused ? 2 : 1))
    }
}

extension DSFieldChrome where Trailing == EmptyView {
    init(mono: Bool = false, @ViewBuilder field: () -> Field) {
        self.mono = mono
        self.field = field()
        self.trailing = EmptyView()
    }
}

/// Seçilebilir adres kutusu: yazı mono, sağda kutunun içinde kopyala simgesi; kopyalanınca tik ve "Kopyalandı".
struct DSCopyField: View {
    let text: String
    var display: String?
    @State private var copied = false

    var body: some View {
        DSFieldChrome(mono: true) {
            Text(verbatim: display ?? text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(copied ? Color.dsSuccessText : Color.dsMuted)
                    .frame(width: DS.size("chip"), height: DS.size("chip"))
                    .contentShape(Circle())
            }
            .buttonStyle(DSIconButtonStyle())
            .help(Text(copied ? "Copied" : "Copy"))
            .accessibilityLabel(Text(copied ? "Copied" : "Copy"))
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }
}

/// Yuvarlak simge düğmesi (32): üzerine gelince alan rengi.
struct DSIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DSIconButtonBody(configuration: configuration)
    }
}

private struct DSIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(Circle().fill(hovering || configuration.isPressed ? Color.dsBorder : Color.clear))
            .onHover { hovering = $0 }
    }
}

// MARK: Rozet, durum hapı

/// Rozet: 24 yükseklik, tam yuvarlak, 12 pt yarı kalın. ok: yeşil, warn: kırmızı, unknown: gri, amber: paket/öneri.
struct DSBadge: View {
    enum Tone { case ok, warn, unknown, amber }
    let text: LocalizedStringKey
    var tone: Tone = .unknown

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: DS.size("badge"))
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .ok: .dsSuccessText
        case .warn: .dsLiveText
        case .unknown: .dsMuted
        case .amber: .dsAmberText
        }
    }

    private var background: Color {
        switch tone {
        case .ok: .dsSuccessSoft
        case .warn: .dsLiveSoft
        case .unknown: .dsField
        case .amber: .dsAmberSoft
        }
    }
}

/// Üst çubuğun sağındaki durum hapı: 40 yükseklik, renkli nokta + kısa durum ("Çeviri Açık", "Hazır").
struct DSStatusPill: View {
    let text: LocalizedStringKey
    let dot: Color

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            Circle().fill(dot).frame(width: DS.size("statusDot"), height: DS.size("statusDot")).accessibilityHidden(true)
            Text(text).font(.dsSmall).foregroundStyle(Color.dsMuted).lineLimit(1)
        }
        .padding(.horizontal, DS.space("m"))
        .frame(height: DS.size("tab"))
        .background(Color.dsSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.dsBorder))
        .accessibilityElement(children: .combine)
    }
}

/// Numaralı adım yuvarlağı (32): yapıldıysa yeşil tik.
struct DSStepNumber: View {
    let number: Int
    var done = false

    var body: some View {
        ZStack {
            Circle().fill(done ? Color.dsSuccess : Color.dsField)
            if done {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
            } else {
                Text(verbatim: "\(number)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.dsText)
            }
        }
        .frame(width: DS.size("chip"), height: DS.size("chip"))
        .accessibilityHidden(true)
    }
}

/// Renk yuvarlağı (altyazı rengi seçimi): seçiliyken 2 pt boşluk + 2 pt amber halka; "Zeminsiz" için dama deseni.
struct DSColorDot: View {
    let color: Color?
    let selected: Bool
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            if let color {
                Circle().fill(color)
            } else {
                Checkerboard().clipShape(Circle())
            }
            Circle().strokeBorder(Color.black.opacity(0.12))
        }
        .frame(width: size, height: size)
        .padding(selected ? 4 : 0)
        .overlay(Circle().strokeBorder(selected ? Color.dsAmber : Color.dsSwitchOff, lineWidth: selected ? 2 : 1))
        .padding(selected ? -4 : 0)
        .scaleEffect(selected ? 1.06 : 1)
    }

    private struct Checkerboard: View {
        var body: some View {
            Canvas { context, size in
                let cell: CGFloat = 5
                for row in 0..<Int(ceil(size.height / cell)) {
                    for column in 0..<Int(ceil(size.width / cell)) {
                        let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                        context.fill(Path(rect), with: .color((row + column).isMultiple(of: 2) ? Color.dsBorder : Color.dsSurface))
                    }
                }
            }
        }
    }
}

// MARK: Oyun görüntüsü çerçevesi

/// Oyun görüntüsü/TV önizlemesi: 16 köşe, 6 pt koyu çerçeve, görüntü yoksa sahne degradesi. Oran dışarıdan verilir (16:9).
struct DSScreenFrame<Content: View>: View {
    var image: NSImage?
    var dark = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        ZStack {
            if dark {
                Color(red: 0.05, green: 0.05, blue: 0.06)
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                DSSceneBackground()
            }
            content
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.dsScreenFrame, lineWidth: 6))
    }
}

extension DSScreenFrame where Content == EmptyView {
    init(image: NSImage? = nil, dark: Bool = false) {
        self.image = image
        self.dark = dark
        self.content = EmptyView()
    }
}

/// Görüntü gelmeden önce çerçevede duran yumuşak sahne (tuvaldeki .game).
struct DSSceneBackground: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color(red: 0.427, green: 0.416, blue: 0.365)
                RadialGradient(colors: [Color(red: 0.478, green: 0.541, blue: 0.416), .clear],
                               center: UnitPoint(x: 0.3, y: 0.35), startRadius: 0, endRadius: max(size.width, size.height) * 0.5)
                RadialGradient(colors: [Color(red: 0.78, green: 0.604, blue: 0.384), .clear],
                               center: UnitPoint(x: 0.75, y: 0.3), startRadius: 0, endRadius: max(size.width, size.height) * 0.42)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Altyazı kutusu örneği (koyu yarı saydam zemin, beyaz yarı kalın yazı, konuşan adı amber).
struct DSSubtitleSample: View {
    var speaker: String?
    let line: String
    var size: CGFloat = 17

    var body: some View {
        (Text(verbatim: speaker.map { $0 + " " } ?? "").foregroundColor(Color.dsAmber) + Text(verbatim: line).foregroundColor(.white))
            .font(.system(size: size, weight: .semibold))
            .lineSpacing(3)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.space("m"))
            .padding(.vertical, DS.space("s"))
            .background(Color(red: 0.063, green: 0.063, blue: 0.078).opacity(0.85), in: RoundedRectangle(cornerRadius: DS.radius("control")))
    }
}

// MARK: Logo

/// CouchSubs logosu, arka plansız: yalnız kanepe ve iki amber altyazı çubuğu (design/logo.svg ile aynı geometri).
/// `breathing`: çubuklar yavaşça daralıp genişler (azaltılmış harekette durur). En-boy oranı korunur (640 × 464).
struct DSLogoMark: View {
    var height: CGFloat = 26
    var breathing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dsMotionOff) private var motionOff
    @State private var narrow = false

    var body: some View {
        let scale = height / 464
        let width = 640 * scale
        ZStack(alignment: .topLeading) {
            rect(282, 290, 460, 320, 52, .dsLogoBack, scale)
            bar(367, 362, 290, 50, scale, delay: 0)
            bar(414, 436, 196, 50, scale, delay: 0.2)
            Group {
                rect(262, 690, 40, 44, 12, .dsLogoSeat, scale)
                rect(722, 690, 40, 44, 12, .dsLogoSeat, scale)
                rect(202, 446, 112, 254, 56, .dsLogoSeat, scale)
                rect(710, 446, 112, 254, 56, .dsLogoSeat, scale)
                rect(202, 574, 620, 126, 56, .dsLogoSeat, scale)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onAppear {
            guard breathing, !reduceMotion, !motionOff else { return }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { narrow = true }
        }
        .accessibilityHidden(true)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: Color, _ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r * s, style: .continuous)
            .fill(color)
            .frame(width: w * s, height: h * s)
            .offset(x: (x - 192) * s, y: (y - 280) * s)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: CGFloat, delay: Double) -> some View {
        Capsule()
            .fill(Color.dsAmber)
            .frame(width: w * s, height: h * s)
            .scaleEffect(x: narrow ? 0.6 : 1, y: 1, anchor: .center)
            .animation(narrow ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(delay) : nil, value: narrow)
            .offset(x: (x - 192) * s, y: (y - 280) * s)
    }
}

/// Logo + "CouchSubs" (üst çubuğun solu): 12 pt aralık, 15 pt kalın.
struct DSBrand: View {
    var body: some View {
        HStack(spacing: DS.space("s")) {
            DSLogoMark(height: 26)
            Text(verbatim: "CouchSubs").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.dsText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "CouchSubs"))
    }
}

// MARK: Kaydırma

extension View {
    /// Kart içi ince kaydırma çubuğu (taşan içerik kendi içinde kayar).
    func dsScroll() -> some View {
        ScrollView(.vertical) { self }.scrollIndicators(.automatic)
    }
}
