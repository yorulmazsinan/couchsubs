// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

// Yeni arayüzün ortak bileşenleri (tuvaldeki .card, .btnp/.btnk/.btns/.btnok/.btnlive, .segwrap/.seg, .sw, .inp,
// .mono, .badge, .adband). Windows aynı adlarla aynı bileşenleri kurar (design/yeni-arayuz/METINLER.md › Bileşenler).

// MARK: Kart

/// Kart: yüzey zemin, 24 köşe, 1 pt çerçeve halkası, 24 iç boşluk. İçerik taşarsa kart kendi içinde ince çubukla kayar.
/// Öğeler (ayar birimleri) arası varsayılan `DS.unitGap` (24); kart başlığı → ilk birim de 24.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.space("l")
    var spacing: CGFloat = DS.unitGap
    /// Vurgulu kart: kartı köşe yarıçapıyla komple saran 1,5 pt renkli kenarlık + %5 aynı renk zemin tonu
    /// (Deneysel turuncu-kırmızı, uyarı/geliştirici amber). Sol şerit kullanılmaz.
    var accent: Color?
    /// Seçili/etkin kartın 2 pt amber halkası.
    var highlighted = false
    var scrolls = true
    /// Yüzey ile içerik arasında çizilen zemin (ör. Ayarlar menüsünün hareketli renk geçişi).
    var backdrop: AnyView?
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
        .background {
            ZStack {
                shape.fill(Color.dsSurface)
                if let accent { shape.fill(accent.opacity(0.05)) }
                if let backdrop { backdrop.clipShape(shape) }
            }
        }
        // Perde e1: kıl çizgi + koyu temada üst kenar parlaması (gölge yerine ışık).
        .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [Color.dsTopHighlight, .clear], startPoint: .top, endPoint: .center))
            .allowsHitTesting(false))
        .overlay(shape.strokeBorder(highlighted ? Color.dsAmber : accent ?? Color.dsBorder,
                                    lineWidth: highlighted ? 2 : accent == nil ? 1 : 1.5))
        .clipShape(shape)
        .shadow(color: highlighted ? Color.dsAmberGlow.opacity(0.6) : .clear, radius: 11)
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .environment(\.csInsideCard, true)
            .environment(\.dsCardSpacing, spacing)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(padding)
    }
}

/// Kart başlığı: sistem yazısı, cümle düzeni ("Başka bir cihazda göster" gibi), 17 orta kalın; içerikle arası 24 pt kalsın
/// diye altına 8 pt ek boşluk. Mono büyük harf başlık kullanılmaz (Sinan Bey, 22 Kas).
struct DSCardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var color: Color = .dsMuted
    @ViewBuilder var trailing: Trailing
    @Environment(\.dsCardSpacing) private var cardSpacing

    init(_ title: LocalizedStringKey, color: Color = .dsMuted, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.color = color
        self.trailing = trailing()
    }

    var body: some View {
        // Başlık + sağda düğme satırında alt boşluk satırın kendisindedir; ikisi dikeyde ortalıdır.
        HStack(alignment: .center, spacing: DS.space("s")) {
            Text(title)
                .font(.dsCardTitle)
                .foregroundStyle(color == .dsMuted ? Color.dsText : color)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.space("s"))
            trailing
        }
        // Başlık → ilk birim her kartta 24: kartın öğe aralığı neyse eksiği burada.
        .padding(.bottom, max(0, DS.unitGap - cardSpacing))
    }
}

private struct DSCardSpacingKey: EnvironmentKey {
    static let defaultValue = DS.space("m")
}

extension EnvironmentValues {
    /// İçinde bulunulan kartın öğe aralığı (kart başlığının alt boşluğu buna göre).
    var dsCardSpacing: CGFloat {
        get { self[DSCardSpacingKey.self] }
        set { self[DSCardSpacingKey.self] = newValue }
    }
}

// MARK: Ayar birimi

/// Ayar birimi: başlık (üstte) + denetim (altta, tam genişlik) + açıklama (denetimin altında). Birim içi aralıklar sabit:
/// başlık → denetim `DS.unitTitleGap` (8), denetim → açıklama `DS.unitHintGap` (6). Birimler arası her yerde
/// `DS.unitGap` (24); bunu birimleri dizen kart (DSCard / Card) ya da `DSUnitStack` verir. Etiket solda, denetim sağda
/// düzeni kullanılmaz (anahtar satırı ve kaydırıcının değer yazısı hariç).
struct DSUnit<Control: View>: View {
    var title: LocalizedStringKey?
    var hint: LocalizedStringKey?
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, DS.unitTitleGap)
            }
            control
            if let hint { Text(hint).dsMuted().padding(.top, DS.unitHintGap) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Birimleri kart dışında (ör. kartın bir bölümünde) dizen yığın: aralık her yerde `DS.unitGap`.
struct DSUnitStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.unitGap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// Düğme türleri (Perde): ana (amber degrade + ışıma, ekranda tek), koyu (kömür), ikincil (yükseltilmiş yüzey, kıl
/// çizgi), hayalet (amber yazılı düz), canlı/durdur (kırmızı tonlu; atan nokta ya da kare), tehlikeli, küçük koyu
/// (reklam bandındaki İncele) ve küçük ikincil (`compact`, 32). Hepsi tam yuvarlak, 48 yükseklik, alt çizgisiz.
/// İşlem sürerken çağıran `busy: true` + `.disabled(true)` verir ve "…ıyor…" yazar: düğme yükleyici çubukları gösterir,
/// soluklaşır, tekrar basılamaz. Klavye odağında amber odak halkası.
struct DSButtonStyle: ButtonStyle {
    /// `compact`: küçük ikincil (32 yükseklik) — başlık satırında "Yeniden Ara", kutunun içinde "Ekle" gibi.
    enum Kind { case primary, dark, secondary, ghost, stop, live, small, danger, compact }
    var kind: Kind = .secondary
    var fullWidth = false
    /// Yazı ile sağdaki ok arası boşluk (ör. "Altyazı Görünümünü Düzenle →").
    var spread = false
    /// Sürüyor durumu: yükleyici çubuklar + soluk yazı (çağıran ayrıca `.disabled(true)` verir).
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, spread: spread, busy: busy)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let fullWidth: Bool
    let spread: Bool
    let busy: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.dsMotionGate) private var gate
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let hovered = hovering && isEnabled && !busy
        let shape = Capsule(style: .circular)
        HStack(spacing: kind == .live || kind == .stop ? 10 : DS.space("xs")) {
            if busy {
                DSBarsLoader(color: kind == .primary ? .dsOnAmber : .dsAmber)
            } else if kind == .stop {
                RoundedRectangle(cornerRadius: 2).fill(Color.dsOnStop).frame(width: 10, height: 10).accessibilityHidden(true)
            } else if kind == .live {
                DSPulseDot(color: .dsOnStop, size: 8)
            }
            configuration.label
                .lineLimit(1)
                .frame(maxWidth: spread ? .infinity : nil, alignment: .leading)
        }
        .font(font)
        .foregroundStyle(busy ? Color.dsMuted : kind == .primary && !isEnabled ? Color.dsFaint : foreground)
        .padding(.horizontal, horizontalPadding)
        .frame(maxWidth: fullWidth || spread ? .infinity : nil)
        .frame(height: kind == .compact ? DS.size("chip") : kind == .small ? DS.size("adCta") : DS.size("button"))
        .background { background(hovered: hovered, pressed: pressed, shape: shape) }
        .overlay { ring(hovered: hovered) }
        .shadow(color: glow(hovered: hovered), radius: hovered ? 17 : 14, y: hovered ? 6 : 8)
        .scaleEffect(pressed && !gate.reduced ? 0.97 : 1)
        .opacity(busy ? 0.85 : isEnabled || kind == .primary ? 1 : 0.55)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .dsFocusRing(isFocused, in: shape)
        .animation(DS.animation(.short, gate: gate), value: pressed)
        .animation(DS.animation(.short, gate: gate), value: hovered)
    }

    private var font: Font {
        switch kind {
        case .secondary, .ghost: .dsButtonSecondary
        case .small, .compact: .system(size: 13, weight: .semibold)
        default: .dsButton
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .compact: DS.space("s")
        case .small: DS.space("m")
        case .secondary: 20
        case .ghost: DS.space("xs")
        default: DS.space("l")
        }
    }

    /// Ana düğmenin amber ışıması (0 10 28 -8 amberGlow; üzerine gelince güçlenir). Diğerlerinde yok.
    private func glow(hovered: Bool) -> Color {
        guard kind == .primary, isEnabled, !busy else { return .clear }
        return Color.dsAmberGlow.opacity(hovered ? 1 : 0.85)
    }

    @ViewBuilder private func background(hovered: Bool, pressed: Bool, shape: Capsule) -> some View {
        if busy && kind != .primary {
            shape.fill(Color.dsSurfaceRaised)
        } else if kind == .primary && !isEnabled && !busy {
            // Pasif ana düğme: soluk amber değil alan zemini + soluk yazı (Perde .bdis).
            shape.fill(Color.dsField)
        } else {
            switch kind {
            case .primary:
                shape.fill(LinearGradient(colors: [hovered || pressed ? Color(red: 1, green: 0.835, blue: 0.47) : .dsAmberHover, .dsAmber],
                                          startPoint: .top, endPoint: .bottom))
                    // Üst kenarda ince beyaz parlama (inset 0 1 0 #FFFFFF73).
                    .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center)))
            case .dark, .small: shape.fill(Color.dsCharcoal)
            case .secondary, .compact: shape.fill(hovered || pressed ? Color.dsSurfaceHigh : Color.dsSurfaceRaised)
            case .ghost: shape.fill(hovered || pressed ? Color.dsField : .clear)
            // Durdur (çeviri sürerken birincil eylem): dolu canlı zemin, beyaz yazı. Sil/Kaldır (danger) soluk kalır.
            case .stop, .live: shape.fill(Color.dsStopFill).overlay(shape.fill(Color.black.opacity(pressed ? 0.16 : hovered ? 0.08 : 0)))
            case .danger: shape.fill(hovered || pressed ? Color.dsLive.opacity(0.22) : .dsLiveSoft)
            }
        }
    }

    @ViewBuilder private func ring(hovered: Bool) -> some View {
        // Halka kapsülün içine yarım nokta çekilerek çizilir; kapsül zeminiyle birebir örtüşür (yanlarda taşan dikey çizgi olmaz).
        let shape = Capsule(style: .circular).inset(by: 0.5)
        switch kind {
        case .primary: shape.stroke(isEnabled ? Color.dsAmberLine.opacity(0.6) : .clear, lineWidth: 1)
        case .secondary, .compact: shape.stroke(hovered ? Color.dsBorderStrong : Color.dsBorder, lineWidth: 1)
        case .danger: shape.stroke(Color.dsLiveRing, lineWidth: 1)
        default: EmptyView()
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .dsOnAmber
        case .dark, .small: .dsOnCharcoal
        case .secondary, .compact: .dsText
        case .ghost: .dsAmberText
        case .stop, .live: .dsOnStop
        case .danger: .dsLiveText
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
    @Environment(\.dsMotionOff) private var motionOff
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
        .background(Color.dsSuccessSoft, in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(Color.dsSuccessRing))
        .scaleEffect(seated || reduceMotion ? 1 : 0.94)
        .onAppear { withAnimation(DS.spring(reduced: reduceMotion || motionOff)) { seated = true } }
        .accessibilityElement(children: .combine)
    }
}

// Atan nokta (DSPulseDot) Perde.swift'te: halka nabzı, hareket kapısına bağlı.

// MARK: Sekme seçici

/// Tek seçimli seçici, üst menü sekme stilinde: bej iz (alan rengi, içe hafif gölge, kıl çizgi), seçili sekme yükselmiş
/// hap (açıkta beyaz, koyuda #3A3C44) + gölge + güçlü kıl çizgi; hap 250 ms kayar.
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
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, fill ? DS.space("xs") : DS.space("m"))
                        .frame(minWidth: fill ? 0 : DS.size("tabMin"), maxWidth: fill ? .infinity : nil)
                        .frame(height: DS.size("tab"))
                        .background {
                            if on {
                                Capsule(style: .circular).fill(Color.dsSegPill)
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .overlay(Capsule(style: .circular).strokeBorder(Color.dsBorderStrong))
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule(style: .circular))
                }
                .buttonStyle(DSPlainFocusRingStyle())
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(DS.space("xxs"))
        .background(Color.dsField, in: Capsule(style: .circular))
        // İze içe doğru hafif gölge (inset 0 1 2 #0000001A) ve kıl çizgi.
        .overlay(Capsule(style: .circular).inset(by: 0.5)
            .stroke(LinearGradient(colors: [.black.opacity(0.10), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
        .overlay(Capsule(style: .circular).strokeBorder(Color.dsBorder))
    }
}

/// Seçici sekmesi ve anahtar: düz; klavye odağında amber odak halkası (fareyle tıklamada görünmez).
private struct DSPlainFocusRingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { DSPlainFocusRingBody(configuration: configuration) }
}

private struct DSPlainFocusRingBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var focused

    var body: some View {
        configuration.label.dsFocusRing(focused, in: Capsule(style: .circular))
    }
}

// MARK: Anahtar

/// Anahtar: 44 × 26, açıkken amber + hafif amber ışıma (yeşil değil), düğmecik beyaz gölgeli; satır başında, yazının
/// solunda durur.
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
            Capsule(style: .circular)
                .fill(isOn ? Color.dsAmber : Color.dsSwitchOff)
                .frame(width: width, height: height)
                .shadow(color: isOn && isEnabled ? Color.dsAmberGlow : .clear, radius: 7)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                        .padding(.horizontal, 3)
                }
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(DSPlainFocusRingStyle())
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityRepresentation { Toggle("", isOn: $isOn) }
    }
}

/// Anahtar satırı (bir ayar birimi): solda anahtar, sağında başlık ve altında açıklama. Kendi dikey boşluğu ve ayracı
/// yok; birimler arası 24'ü onu dizen kart verir (diğer birimlerle aynı aralık). `divider` eski çağrılar içindir, yok sayılır.
struct DSSwitchRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool
    var divider = false

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: DS.space("m")) {
            DSSwitch(isOn: $isOn)
                .accessibilityLabel(Text(title))
            VStack(alignment: .leading, spacing: DS.unitHintGap) {
                Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).dsMuted() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Seçenek kartı (tuvaldeki SEL): en az 64 (ya da 72) yükseklik, 16 köşe. Tıklanabilir her kart/seçenek böyle görünür:
/// her zaman 1 pt kenarlık, üzerine gelince alan zemini, seçiliyken 2 pt amber kenarlık + hafif amber dolgu; solda radyo.
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
    @Environment(\.isFocused) private var isFocused
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
        .background(hovering && !selected ? Color.dsSurfaceHigh : Color.dsSurface, in: shape)
        .overlay(shape.strokeBorder(hovering && !selected ? Color.dsBorderStrong : Color.dsBorder, lineWidth: 1))
        // Seçili: 2 pt amber iç kenar + amber yumuşak dolgu + hafif ışıma (Perde).
        .dsSelectedGlow(selected, in: shape)
        .dsFocusRing(isFocused, in: shape)
        .contentShape(shape)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(DS.animation(.short, reduced: reduceMotion), value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: Hesap kartı

/// Hesap kartı (PlayStation / Microsoft): solda yuvarlak rozet, ortada başlık ve durum (yeşil/gri nokta + "Giriş yapıldı"
/// ya da "Giriş yapılmadı", varsa hesap adı gri), sağda kartın içinde dikey ortalı tek düğme (girişliyse küçük ikincil
/// "Yeniden Giriş Yap", değilse birincil "Giriş Yap"). Altta ince ayraçtan sonra "Diğer Giriş Yolları ›"; açılınca
/// seçenekler kartın içinde.
struct DSAccountCard<Others: View>: View {
    let badge: String
    let title: LocalizedStringKey
    let signedIn: Bool
    var detail: String?
    var busy = false
    /// Diğer yollardan biri sürüyorsa (ör. giriş tarayıcıya geçti) açılır kendiliğinden açık kalır.
    var expanded = false
    let signIn: () -> Void
    @ViewBuilder var others: Others
    @State private var showOthers = false
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // Dar sütunda (ör. 380 pt kurulum sütunu) düğme başlığın altına iner; durum yazısı kırpılmaz.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.space("s")) {
                    identity.fixedSize()
                    Spacer(minLength: DS.space("s"))
                    action
                }
                VStack(alignment: .leading, spacing: DS.space("s")) {
                    identity
                    action
                }
            }
            .padding(DS.space("m"))
            DSDivider()
            Button {
                withAnimation(DS.animation(.medium, reduced: false)) { showOthers.toggle() }
            } label: {
                HStack(spacing: DS.space("xxs")) {
                    Text("Other Sign-In Ways")
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showOthers || expanded ? 90 : 0)).accessibilityHidden(true)
                    Spacer(minLength: 0)
                }
                .font(.dsSmall)
                .foregroundStyle(hovering ? Color.dsText : Color.dsMuted)
                .padding(.horizontal, DS.space("m"))
                .padding(.vertical, DS.space("s"))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            if showOthers || expanded {
                VStack(alignment: .leading, spacing: DS.unitGap) { others }
                    .padding([.horizontal, .bottom], DS.space("m"))
                    .transition(.opacity)
            }
        }
        .dsElevation(signedIn ? .raised : .card, in: shape)
    }

    @ViewBuilder private var action: some View {
        if signedIn {
            Button(busy ? "Signing In…" : "Sign In Again", action: signIn)
                .buttonStyle(DSButtonStyle(kind: .compact, busy: busy)).disabled(busy)
        } else {
            Button(busy ? "Signing In…" : "Sign In", action: signIn)
                .buttonStyle(DSButtonStyle(kind: .primary, busy: busy)).disabled(busy)
        }
    }

    private var identity: some View {
            HStack(spacing: DS.space("s")) {
                Text(verbatim: badge)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(signedIn ? Color.dsOnAmber : Color.dsOnCharcoal)
                    .frame(width: 40, height: 40)
                    .background {
                        if signedIn {
                            Circle().fill(LinearGradient(colors: [Color(red: 1, green: 0.796, blue: 0.388), .dsPeach],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                        } else {
                            Circle().fill(Color.dsCharcoal)
                        }
                    }
                    // Bağlıyken 3 pt aralıklı amber halka.
                    .overlay { if signedIn { Circle().inset(by: -4.5).strokeBorder(Color.dsAmber, lineWidth: 1.5) } }
                    .padding(signedIn ? 4.5 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.space("line")) {
                    Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText)
                    HStack(spacing: DS.space("xxs")) {
                        Circle().fill(signedIn ? Color.dsSuccess : Color.dsFaint).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(signedIn ? "Signed in" : "Not signed in").font(.dsSmall).foregroundStyle(Color.dsMuted)
                        if let detail { Text(verbatim: "· \(detail)").font(.dsSmall).foregroundStyle(Color.dsMuted).lineLimit(1) }
                    }
                    .fixedSize()
                }
            }
    }
}

// MARK: Bölüm başlığı

/// Başlık + altında açıklama: aralık her yerde `DS.space("titleBody")` (6). Kart içinde başlık ve açıklama ayrı kardeş
/// öğe olarak yazılmaz (kartın 24'lük birim aralığı araya girerdi).
struct DSSectionTitle: View {
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    var font: Font = .dsBodyStrong

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("titleBody")) {
            Text(title).font(font).foregroundStyle(Color.dsText).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).dsMuted() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Düğme yığını

/// Birbiriyle ilişkili ardışık düğmeler (ör. "Evet, Görüyorum" / "Görmüyorum") ve üstlerindeki soru: aralar 12 (düğme →
/// açıklama aralığı kadar). Kartın 24'lük birim aralığı bu yığının dışında kalır.
struct DSButtonStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("s")) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Uyarı kutusu

/// Önemli uyarı: ikincil gri metin değil, ince amber kenarlı, açık amber zeminli kutu; solda simge. Metin Markdown
/// kalın (**ana**) destekler.
struct DSCallout: View {
    let text: LocalizedStringKey
    var icon = "exclamationmark.triangle.fill"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        HStack(alignment: .top, spacing: DS.space("s")) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dsAmberText)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(.dsSmall)
                .foregroundStyle(Color.dsText)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DS.space("m"))
        .background(Color.dsAmberSoft, in: shape)
        .overlay(shape.strokeBorder(Color.dsAmberRing, lineWidth: 1))
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
        // Kutunun her yerine tıklamak alanı açar (iPhone ile aynı): yalnız yazı satırı tıklamayı alıyordu.
        .background { Capsule(style: .circular).fill(Color.dsField).contentShape(Capsule(style: .circular)).onTapGesture { focused = true } }
        .overlay(Capsule(style: .circular).strokeBorder(focused ? Color.dsAmber : Color.dsBorder, lineWidth: focused ? 1.5 : 1).allowsHitTesting(false))
        .background(Capsule(style: .circular).inset(by: -4).fill(focused ? Color.dsAmberSoft : .clear))
        .animation(.easeOut(duration: DS.tokens.motion.short / 1000), value: focused)
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
    /// Varsayılan mono 13; Xbox kodu gibi büyük değerlerde daha iri.
    var font: Font?
    @State private var copied = false

    var body: some View {
        DSFieldChrome(mono: true) {
            Text(verbatim: display ?? text)
                .font(font ?? .system(size: 13, weight: .regular, design: .monospaced))
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
            .background(background, in: Capsule(style: .circular))
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
    /// Canlı/çalışıyor: nokta nabız atar (hareket kapısına bağlı).
    var pulse = false

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            if pulse {
                DSPulseDot(color: dot, size: DS.size("statusDot"))
            } else {
                Circle().fill(dot).frame(width: DS.size("statusDot"), height: DS.size("statusDot")).accessibilityHidden(true)
            }
            Text(text).font(.dsSmall).foregroundStyle(Color.dsMuted).lineLimit(1)
        }
        .padding(.horizontal, DS.space("m"))
        .frame(height: DS.size("tab"))
        .dsElevation(.card, in: Capsule(style: .circular))
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

/// Altyazı kutusu örneği (Perde altyazı plakası: her temada aynı koyu plaka, sıcak beyaz yazı, konuşan adı amber).
struct DSSubtitleSample: View {
    var speaker: String?
    let line: String
    var size: CGFloat = 17

    var body: some View {
        DSSubtitlePlate(speaker: speaker, line: line, size: size)
    }
}

// MARK: Logo

/// CouchSubs logosu, arka plansız: yalnız kanepe ve iki amber altyazı çubuğu (design/logo.svg ile aynı geometri).
/// `breathing`: çubuklar yavaşça daralıp genişler (azaltılmış harekette durur). En-boy oranı korunur (640 × 464).
struct DSLogoMark: View {
    var height: CGFloat = 26
    var breathing = true
    @Environment(\.dsMotionGate) private var gate
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
        // Nefes yalnız hareket kapısı açıkken (çeviri sürerken, hareketi azaltta, arka planda durur).
        .onAppear { narrow = breathing && gate.ambient }
        .onChange(of: gate.ambient) { open in narrow = breathing && open }
        .accessibilityHidden(true)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ color: Color, _ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r * s, style: .continuous)
            .fill(color)
            .frame(width: w * s, height: h * s)
            .offset(x: (x - 192) * s, y: (y - 280) * s)
    }

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: CGFloat, delay: Double) -> some View {
        Capsule(style: .circular)
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
            // Üst çubukta durağan: SwiftUI'nin sonsuz animasyonu boştayken her kare çizim ister (boşta ≤ %2 işlemci).
            DSLogoMark(height: 26, breathing: false)
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

// MARK: Kaydırıcı

/// Kaydırıcı: 4 pt ince iz (kapalı anahtar rengi), dolu kısmı amber, 20 pt beyaz gölgeli düğmecik; nokta (tick) yok.
/// İz tam genişlik (uçları içeriğin kenarlarıyla aynı hizada); `step` verilirse değer o adıma oturur. Windows: Styles.xaml › Slider (aynı ölçüler).
struct DSSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false

    static let knob: CGFloat = 20
    private static let track: CGFloat = 4

    /// İz kartın iç genişliğini tam kaplar: sol ucu 0, sağ ucu genişlik (başlık, değer ve uç etiketleriyle aynı iki dikey
    /// çizgi). Düğmeciğin merkezi iz üzerinde gezer; uçlarda yarıçapı kadar dışarı taşar.
    static func trackSpan(width: CGFloat) -> ClosedRange<CGFloat> { 0...max(width, 0) }

    static func knobCenter(fraction: CGFloat, width: CGFloat) -> CGFloat { max(width, 0) * min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            let knob = Self.knob
            let width = max(geometry.size.width, 1)
            let center = Self.knobCenter(fraction: fraction, width: width)
            ZStack(alignment: .leading) {
                Capsule(style: .circular).fill(Color.dsField)
                    .overlay(Capsule(style: .circular).strokeBorder(Color.dsBorder, lineWidth: 0.5))
                    .frame(width: width, height: Self.track)
                Capsule(style: .circular).fill(Color.dsAmber)
                    .frame(width: center, height: Self.track)
                    .shadow(color: isEnabled ? Color.dsAmberGlow : .clear, radius: 5)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.06)))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .scaleEffect(dragging && !reduceMotion ? 1.08 : 1)
                    .offset(x: center - knob / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        set(fraction: gesture.location.x / width)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.5)
        .animation(DS.animation(.short, reduced: reduceMotion), value: dragging)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: value.formatted(.number.precision(.fractionLength(step.map { $0 < 1 ? 1 : 0 } ?? 0)))))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = clamp(value + delta)
            case .decrement: value = clamp(value - delta)
            @unknown default: break
            }
        }
    }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat((clamp(value) - range.lowerBound) / span)
    }

    private func set(fraction: CGFloat) {
        let raw = range.lowerBound + Double(min(max(fraction, 0), 1)) * (range.upperBound - range.lowerBound)
        let snapped = step.map { (raw / $0).rounded() * $0 } ?? raw
        let next = clamp(snapped)
        if next != value { value = next }
    }

    private func clamp(_ x: Double) -> Double { min(max(x, range.lowerBound), range.upperBound) }
}

/// Kaydırıcının altındaki en küçük / en büyük değer etiketleri: çubuğun uçlarıyla hizalı (çubuk tam genişlik; sol
/// etiket sol kenarda, sağ etiket sağ kenarda).
struct DSSliderRange: View {
    let low: String
    let high: String

    var body: some View {
        HStack {
            Text(verbatim: low)
            Spacer()
            Text(verbatim: high)
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Color.dsMuted)
        .accessibilityHidden(true)
    }
}

/// Kaydırıcı satırı: başlık solda kendi satırında, değer sağda (mono); altında tam genişlikte kaydırıcı, en altta tek
/// cümlelik açıklama. Ayarlar'daki bütün kaydırıcılar bunu kullanır (Windows: SliderRow, aynı düzen).
struct DSSliderRow: View {
    let title: LocalizedStringKey
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var hint: LocalizedStringKey?
    /// En küçük / en büyük değer etiketleri (ör. "16" / "50"): çubuğun gerçek uçlarıyla hizalı.
    var ends: (String, String)?
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: DS.space("s")) {
                Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText)
                Spacer(minLength: DS.space("s"))
                Text(verbatim: valueText)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.dsAmberText)
            }
            DSSlider(value: $value, range: range, step: step, onEditingChanged: onEditingChanged)
                .accessibilityLabel(Text(title))
                .padding(.top, DS.unitTitleGap)
            if let ends { DSSliderRange(low: ends.0, high: ends.1) }
            if let hint { Text(hint).dsMuted().padding(.top, DS.unitHintGap) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Kısayol rozeti

/// Klavye kısayolu rozeti (kbd): mono 12, alan zemini, ince halka, 8 köşe; birden çok tuş "ya da" ile ayrılır.
struct DSKeys: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: DS.space("xxs")) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                if index > 0 { Text("or").font(.dsCaption).foregroundStyle(Color.dsMuted) }
                Text(verbatim: key)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dsText)
                    .lineLimit(1)
                    .padding(.horizontal, DS.space("xs"))
                    .frame(height: 24)
                    .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("chip"), style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.radius("chip"), style: .continuous).strokeBorder(Color.dsBorder))
            }
        }
        .fixedSize()
    }
}

// MARK: Küçük metin düğmesi

/// Küçük metin düğmesi (ör. ek alandaki Kaldır): simge + yazı, gri; üzerine gelince `hoverTint` renginde ve açık zeminli.
struct DSTextButtonStyle: ButtonStyle {
    var hoverTint: Color = .dsLiveText
    var hoverFill: Color = .dsLiveSoft

    func makeBody(configuration: Configuration) -> some View {
        DSTextButtonBody(configuration: configuration, hoverTint: hoverTint, hoverFill: hoverFill)
    }
}

private struct DSTextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverTint: Color
    let hoverFill: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let active = hovering || configuration.isPressed
        configuration.label
            .font(.dsRow)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(active ? hoverTint : Color.dsMuted)
            .padding(.horizontal, DS.space("s"))
            .frame(height: DS.size("chip"))
            .background(active ? hoverFill : Color.clear, in: Capsule(style: .circular))
            .contentShape(Capsule(style: .circular))
            .onHover { hovering = $0 }
            .animation(DS.animation(.short, reduced: reduceMotion), value: active)
    }
}

// MARK: Vurgu şeridi

extension View {
    /// Vurgulu kart/karo (Deneysel turuncu-kırmızı, bildirim amber): sol şerit yerine kartı köşe yarıçapıyla komple saran
    /// 1,5 pt renkli kenarlık ve %5 aynı renk zemin tonu.
    func dsAccentBorder(_ color: Color, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(color.opacity(0.05)))
            .overlay(shape.strokeBorder(color, lineWidth: 1.5).allowsHitTesting(false))
    }
}

// MARK: Açılır seçim kutusu

/// Açılır seçim kutusu (selectbox): giriş kutusu yüzeyi (yüzey zemini, ince halka, 12 köşe, 40 yükseklik), koyu yazı,
/// sağda tek küçük aşağı ok; tıklanınca sistemin kendi menüsü açılır, seçili satır tikli. Ayarlar'daki bütün açılır
/// seçimler bunu kullanır (eski Picker'ın soluk sarı görünümü yerine).
struct DSSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @State private var anchor = DSMenuAnchor()
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("control"), style: .continuous)
        Button(action: open) {
            HStack(spacing: DS.space("xs")) {
                Text(verbatim: options.first { $0.0 == selection }?.1 ?? "")
                    .font(.dsBody)
                    .foregroundStyle(Color.dsText)
                    .lineLimit(1)
                Spacer(minLength: DS.space("xs"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dsMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: DS.size("tab"))
            .background(hovering && isEnabled ? Color.dsSurfaceHigh : Color.dsSurfaceRaised, in: shape)
            .overlay(shape.strokeBorder(hovering && isEnabled ? Color.dsBorderStrong : Color.dsBorder))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .background(DSMenuAnchorView(anchor: anchor))
        .accessibilityValue(Text(verbatim: options.first { $0.0 == selection }?.1 ?? ""))
    }

    private func open() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var current: NSMenuItem?
        for (value, title) in options {
            let item = DSMenuAnchor.Item(title: title) { selection = value }
            item.state = value == selection ? .on : .off
            if value == selection { current = item }
            menu.addItem(item)
        }
        menu.minimumWidth = view.bounds.width
        // Seçili satır kutunun üstüne gelir (sistem açılır menüsü gibi).
        menu.popUp(positioning: current, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height - 4 : 4), in: view)
    }
}

/// Başlıklı seçim kutusu: başlık üstte (15 orta kalın), 8 pt altında kutu; isteğe bağlı tek cümle açıklama.
struct DSSelectRow<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [(Value, String)]
    var hint: LocalizedStringKey?

    var body: some View {
        DSUnit(title: title, hint: hint) {
            DSSelect(selection: $selection, options: options).accessibilityLabel(Text(title))
        }
    }
}

/// Menünün açılacağı görünüm (AppKit) ve menü satırının eylemi.
final class DSMenuAnchor {
    weak var view: NSView?

    final class Item: NSMenuItem {
        private let handler: () -> Void

        init(title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError("init(coder:) kullanılmaz") }

        @objc private func run() { handler() }
    }
}

private struct DSMenuAnchorView: NSViewRepresentable {
    let anchor: DSMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
