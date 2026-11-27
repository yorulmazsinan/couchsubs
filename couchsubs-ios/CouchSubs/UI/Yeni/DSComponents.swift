// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import UIKit

// Yeni arayüzün ortak bileşenleri, iPhone karşılığı (Mac: mac/CouchSubs/UI/Yeni/DSComponents.swift; aynı adlar, aynı
// ölçüler). Telefonda üzerine gelme yok; yükseklikler Dinamik Yazı büyüdüğünde kesilmesin diye en az değer olarak verilir.

// MARK: Düğmeler

/// Düğme türleri (Perde; Mac ile aynı adlar): ana (amber degrade + ışıma, ekranda tek), koyu (kömür), ikincil
/// (yükseltilmiş yüzey, kıl çizgi), hayalet (amber yazılı düz), canlı/durdur (kırmızı tonlu; atan nokta ya da kare),
/// tehlikeli, küçük ikincil (`compact`, 32+). Hepsi tam yuvarlak, en az 48 yükseklik, alt çizgisiz. İşlem sürerken
/// çağıran `busy: true` + `.disabled(true)` verir ("…ıyor…"): yükleyici çubuklar, soluk yazı.
struct DSButtonStyle: ButtonStyle {
    enum Kind { case primary, dark, secondary, stop, live, danger, ghost, compact }
    var kind: Kind = .secondary
    var fullWidth = true
    var busy = false

    func makeBody(configuration: Configuration) -> some View {
        DSButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, busy: busy)
    }
}

private struct DSButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: DSButtonStyle.Kind
    let fullWidth: Bool
    let busy: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.isFocused) private var isFocused
    /// Tek hareket kapısı (hareketi azalt ve Geçiş Animasyonları kapalıyken yalnız kısa solma).
    @Environment(\.dsMotionGate) private var gate

    var body: some View {
        let pressed = configuration.isPressed
        let shape = Capsule()
        HStack(spacing: kind == .live || kind == .stop ? 10 : DS.space("xs")) {
            if busy {
                DSBarsLoader(color: kind == .primary ? .dsOnAmber : .dsAmber)
            } else if kind == .stop {
                RoundedRectangle(cornerRadius: 2).fill(Color.dsOnStop).frame(width: 10, height: 10).accessibilityHidden(true)
            } else if kind == .live {
                DSPulseDot(color: .dsOnStop, size: 8)
            }
            configuration.label
                .labelStyle(.titleAndIcon)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
        }
        .font(font)
        .foregroundStyle(busy ? Color.dsMuted : kind == .primary && !isEnabled ? Color.dsFaint : foreground)
        .padding(.horizontal, kind == .ghost || kind == .compact ? DS.space("s") : DS.space("l"))
        .padding(.vertical, kind == .compact ? DS.space("xxs") : DS.space("xs"))
        .frame(maxWidth: fullWidth && kind != .ghost && kind != .compact ? .infinity : nil)
        .frame(minHeight: kind == .ghost ? 44 : kind == .compact ? DS.size("buttonSmall") : DS.size("button"))
        .background { background(pressed: pressed, shape: shape) }
        .overlay { ring }
        .shadow(color: kind == .primary && isEnabled && !busy ? Color.dsAmberGlow.opacity(pressed ? 1 : 0.85) : .clear,
                radius: 14, y: 8)
        .scaleEffect(pressed && !gate.reduced ? 0.97 : 1)
        .opacity(busy ? 0.85 : isEnabled || kind == .primary ? 1 : 0.55)
        .contentShape(shape)
        .dsFocusRing(isFocused, in: shape)
        .animation(DS.animation(.short, gate: gate), value: pressed)
    }

    private var font: Font {
        switch kind {
        case .secondary, .ghost: .dsButtonSecondary
        case .compact: .system(.footnote, weight: .semibold)
        default: .dsButton
        }
    }

    @ViewBuilder private func background(pressed: Bool, shape: Capsule) -> some View {
        if busy && kind != .primary {
            shape.fill(Color.dsSurfaceRaised)
        } else if kind == .primary && !isEnabled && !busy {
            // Pasif ana düğme: soluk amber değil alan zemini + soluk yazı (Perde .bdis).
            shape.fill(Color.dsField)
        } else {
            switch kind {
            case .primary:
                shape.fill(LinearGradient(colors: [pressed ? .dsAmber : .dsAmberHover, .dsAmber], startPoint: .top, endPoint: .bottom))
                    // Üst kenarda ince beyaz parlama (inset 0 1 0 #FFFFFF73).
                    .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center)))
            case .dark: shape.fill(Color.dsCharcoal)
            case .secondary, .compact: shape.fill(pressed ? Color.dsSurfaceHigh : Color.dsSurfaceRaised)
            // Durdur (çeviri sürerken birincil eylem): dolu canlı zemin, beyaz yazı. Sil/Kaldır (danger) soluk kalır.
            case .stop, .live: shape.fill(Color.dsStopFill).overlay(shape.fill(Color.black.opacity(pressed ? 0.16 : 0)))
            case .danger: shape.fill(pressed ? Color.dsLive.opacity(0.22) : .dsLiveSoft)
            case .ghost: shape.fill(pressed ? Color.dsField : .clear)
            }
        }
    }

    @ViewBuilder private var ring: some View {
        switch kind {
        case .primary: Capsule().strokeBorder(isEnabled ? Color.dsAmberLine.opacity(0.6) : .clear)
        case .secondary, .compact: Capsule().strokeBorder(Color.dsBorder)
        case .danger: Capsule().strokeBorder(Color.dsLiveRing)
        default: EmptyView()
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .dsOnAmber
        case .dark: .dsOnCharcoal
        case .secondary, .compact: .dsText
        case .stop, .live: .dsOnStop
        case .danger: .dsLiveText
        case .ghost: .dsAmberText
        }
    }
}

/// Başarı durumu (Eşleşti, Onaylandı, Kaydedildi): açık yeşil zemin, yeşil yazı, tik, küçük oturma animasyonu.
struct DSSuccessBadge: View {
    let text: LocalizedStringKey
    var fullWidth = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Ayarlar › Geçiş Animasyonları kapalıyken de yalnız kısa solma.
    @Environment(\.dsMotionOff) private var motionOff
    private var reduceMotion: Bool { systemReduceMotion || motionOff }
    @State private var seated = false

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            Image(systemName: "checkmark").font(.footnote.weight(.heavy)).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .font(.dsButton)
        .foregroundStyle(Color.dsSuccessText)
        .padding(.horizontal, DS.space("l"))
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(minHeight: DS.size("button"))
        .background(Color.dsSuccessSoft, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.dsSuccessRing))
        .scaleEffect(seated || reduceMotion ? 1 : 0.94)
        .onAppear { withAnimation(DS.spring(reduced: reduceMotion)) { seated = true } }
        .accessibilityElement(children: .combine)
    }
}

// Atan nokta (DSPulseDot) Perde.swift'te: halka nabzı, hareket kapısına bağlı.

// MARK: Sekme seçici

/// Tek seçimli seçici (her yerde aynı): bej iz (alan rengi, kapsül, içe hafif gölge, kıl çizgi), seçili sekme yükselmiş
/// hap (açıkta beyaz, koyuda #3A3C44) + gölge + güçlü kıl çizgi; hap 250 ms kayar. Sekmeler genişliği eşit paylaşır.
struct DSTabs<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: LocalizedStringKey
        var id: Value { value }
    }

    @Binding var selection: Value
    let items: [Item]
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Ayarlar › Geçiş Animasyonları kapalıyken de yalnız kısa solma.
    @Environment(\.dsMotionOff) private var motionOff
    private var reduceMotion: Bool { systemReduceMotion || motionOff }
    @Namespace private var namespace

    init(selection: Binding<Value>, items: [(Value, LocalizedStringKey)]) {
        _selection = selection
        self.items = items.map { Item(value: $0.0, title: $0.1) }
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
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, DS.space("xs"))
                        .frame(maxWidth: .infinity, minHeight: DS.size("tab"))
                        .background {
                            if on {
                                Capsule().fill(Color.dsSegPill)
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                                    .overlay(Capsule().strokeBorder(Color.dsBorderStrong))
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .selectionFeedback(trigger: on)
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
        .padding(DS.space("xxs"))
        .background(Color.dsField, in: Capsule())
        // İze içe doğru hafif gölge (inset 0 1 2 #0000001A) ve kıl çizgi.
        .overlay(Capsule().inset(by: 0.5).stroke(LinearGradient(colors: [.black.opacity(0.10), .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
        .overlay(Capsule().strokeBorder(Color.dsBorder))
    }
}

// MARK: Anahtar

/// Anahtar: 51 × 31 (iPhone), açıkken amber + hafif amber ışıma (yeşil değil), beyaz gölgeli düğmecik.
struct DSSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Ayarlar › Geçiş Animasyonları kapalıyken de yalnız kısa solma.
    @Environment(\.dsMotionOff) private var motionOff
    private var reduceMotion: Bool { systemReduceMotion || motionOff }

    var body: some View {
        let width = DS.size("switchWidthIOS"), height = DS.size("switchHeightIOS"), knob = height - 4
        Capsule()
            .fill(isOn ? Color.dsAmber : Color.dsSwitchOff)
            .frame(width: width, height: height)
            .shadow(color: isOn && isEnabled ? Color.dsAmberGlow : .clear, radius: 7)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                    .padding(.horizontal, 2)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .animation(DS.animation(.medium, reduced: reduceMotion), value: isOn)
            .accessibilityHidden(true)
    }
}

/// Bütün anahtarlar (Toggle) bu biçimde: anahtar satırın başında, yazının solunda; satırın tamamı dokunulabilir.
struct DSToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .center, spacing: DS.space("m")) {
                DSSwitch(isOn: configuration.$isOn)
                configuration.label
                    .foregroundStyle(Color.dsText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Anahtar satırı (bir ayar birimi; Mac DSSwitchRow): solda anahtar, sağında başlık ve altında açıklama; satırın tamamı
/// dokunulabilir.
struct DSSwitchRow: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: DS.unitHintGap) {
                Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText).fixedSize(horizontal: false, vertical: true)
                if let subtitle { Text(subtitle).dsMuted() }
            }
        }
        .toggleStyle(DSToggleStyle())
    }
}

/// Ayar birimi (Mac DSUnit): başlık üstte, 8 altında denetim (tam genişlik), 6 altında açıklama. Birimler arası 24.
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

/// Birimleri 24 arayla dizen yığın (Mac DSUnitStack).
struct DSUnitStack<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.unitGap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Radyo ve seçenek kartı

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

/// Seçenek kartı: tıklanabilir olduğu belli: 1 pt ince halka; seçiliyken amber halka ve hafif amber dolgu; solda radyo.
struct DSOptionStyle: ButtonStyle {
    var selected: Bool
    var radio = true

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        return HStack(spacing: DS.space("m")) {
            if radio { DSRadio(on: selected) }
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DS.space("m"))
        .padding(.vertical, DS.space("s"))
        .frame(maxWidth: .infinity, minHeight: DS.size("option"), alignment: .leading)
        .background(configuration.isPressed && !selected ? Color.dsSurfaceHigh : Color.dsSurface, in: shape)
        .overlay(shape.strokeBorder(Color.dsBorder))
        // Seçili: 2 pt amber iç kenar + amber yumuşak dolgu + hafif ışıma (Perde).
        .dsSelectedGlow(selected, in: shape)
        .contentShape(shape)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: Giriş kutusu

/// Giriş kutusu: tam yuvarlak, en az 48, alan zemini, ince halka; odakta amber halka. `trailing` kutunun içinde sağda.
struct DSFieldChrome<Field: View, Trailing: View>: View {
    var mono = false
    @ViewBuilder var field: Field
    @ViewBuilder var trailing: Trailing
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: DS.space("xs")) {
            field
                .focused($focused)
                .font(mono ? .system(.footnote, design: .monospaced) : .dsBody)
                .foregroundStyle(Color.dsText)
                .tint(Color.dsAmberText)
            trailing
        }
        .padding(.leading, DS.space("m") + 4)
        .padding(.trailing, Trailing.self == EmptyView.self ? DS.space("m") + 4 : DS.space("xxs"))
        .frame(minHeight: DS.size("input"))
        // Kutunun her yerine dokunmak alanı açar: yazı satırı 48'lik kutunun yalnız ortasındaki ince şerit ve iç boşluk
        // dokunuşu almıyordu; kutunun üstüne/altına/soluna dokunan kullanıcıda klavye hiç açılmıyordu (TV kurulumu, X).
        // Dokunuş zeminde yakalanır: yazı alanının ve sağdaki düğmenin kendi dokunuşu değişmez.
        .background { Capsule().fill(Color.dsField).contentShape(Capsule()).onTapGesture { focused = true } }
        .overlay(Capsule().strokeBorder(focused ? Color.dsAmber : Color.dsBorder, lineWidth: focused ? 1.5 : 1).allowsHitTesting(false))
        .background(Capsule().inset(by: -4).fill(focused ? Color.dsAmberSoft : .clear))
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

/// Kutunun içinde sağdaki yuvarlak simge düğmesi (kopyala, kaldır): 40 pt dokunma hedefi.
struct DSFieldIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint: Color = .dsMuted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Seçilebilir adres kutusu: yazı mono, sağda kutunun içinde kopyala simgesi; kopyalanınca yeşil tik.
struct DSCopyField: View {
    let text: String
    @State private var copied = false

    var body: some View {
        DSFieldChrome(mono: true) {
            Text(verbatim: text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } trailing: {
            DSFieldIconButton(symbol: copied ? "checkmark" : "doc.on.doc", label: copied ? "Copied" : "Copy",
                              tint: copied ? .dsSuccessText : .dsMuted) {
                UIPasteboard.general.string = text
                copied = true
            }
        }
        .resetsAfterDelay($copied)
    }
}

/// Kutu içi metin alanı (TextField / SecureField): `textFieldStyle(DSTextFieldStyle())`.
struct DSTextFieldStyle: TextFieldStyle {
    var mono = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        DSFieldChrome(mono: mono) { configuration }
    }
}

// MARK: Rozet

/// Rozet: 24 yükseklik, tam yuvarlak. ok: yeşil, warn: kırmızı, unknown: gri, amber: paket/öneri.
struct DSBadge: View {
    enum Tone { case ok, warn, unknown, amber }
    let text: String
    var tone: Tone = .unknown

    var body: some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(minHeight: DS.size("badge"))
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

// MARK: Kaydırıcı

/// Kaydırıcı: 4 pt ince iz (kapalı anahtar rengi), dolu kısmı amber, 24 pt beyaz gölgeli düğmecik; nokta (tick) yok.
/// İz tam genişlik (uçları başlık ve değer yazısının kenarlarıyla aynı hizada); düğmecik uçlarda yarıçapı kadar taşar.
struct DSSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// Ayarlar › Geçiş Animasyonları kapalıyken de yalnız kısa solma.
    @Environment(\.dsMotionOff) private var motionOff
    private var reduceMotion: Bool { systemReduceMotion || motionOff }
    @State private var dragging = false

    static let knob: CGFloat = 24
    /// Uç etiketlerinin iç boşluğu: iz tam genişlik olduğundan 0.
    static var inset: CGFloat { 0 }
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
                Capsule().fill(Color.dsField)
                    .overlay(Capsule().strokeBorder(Color.dsBorder, lineWidth: 0.5))
                    .frame(width: width, height: Self.track)
                Capsule().fill(Color.dsAmber)
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
        .frame(height: 32)
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
            onEditingChanged(false)
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
        if next != value {
            value = next
            if step != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
    }

    private func clamp(_ x: Double) -> Double { min(max(x, range.lowerBound), range.upperBound) }
}

/// Kaydırıcı satırı: başlık solda, değer sağda (mono); altında tam genişlikte kaydırıcı, en altta isteğe bağlı açıklama.
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
        VStack(alignment: .leading, spacing: DS.space("xs")) {
            HStack(alignment: .firstTextBaseline, spacing: DS.space("s")) {
                Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.space("s"))
                Text(verbatim: valueText)
                    .font(.system(.footnote).weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.dsAmberText)
            }
            VStack(spacing: 0) {
                DSSlider(value: $value, range: range, step: step, onEditingChanged: onEditingChanged)
                    .accessibilityLabel(Text(title))
                if let ends { DSSliderRange(low: ends.0, high: ends.1) }
            }
            if let hint { Text(hint).dsMuted() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kaydırıcının altındaki en küçük / en büyük değer etiketleri (Mac DSSliderRange): çubuğun uçlarıyla hizalı (çubuk tam
/// genişlik; sol etiket sol kenarda, sağ etiket sağ kenarda).
struct DSSliderRange: View {
    let low: String
    let high: String

    var body: some View {
        HStack {
            Text(verbatim: low)
            Spacer()
            Text(verbatim: high)
        }
        .font(.system(.caption).weight(.medium).monospacedDigit())
        .foregroundStyle(Color.dsMuted)
        .accessibilityHidden(true)
    }
}

// MARK: Açılır seçim kutusu

/// Açılır seçim kutusu: yüzey zemini, ince halka, 12 köşe, koyu yazı, sağda tek küçük aşağı ok; dokununca sistemin menüsü
/// açılır, seçili satır tikli.
struct DSSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("control"), style: .continuous)
        Menu {
            Picker(selection: $selection) {
                ForEach(options, id: \.0) { option in Text(verbatim: option.1).tag(option.0) }
            } label: { EmptyView() }
        } label: {
            HStack(spacing: DS.space("xs")) {
                Text(verbatim: options.first { $0.0 == selection }?.1 ?? "")
                    .font(.dsBody)
                    .foregroundStyle(Color.dsText)
                    .lineLimit(1)
                Spacer(minLength: DS.space("xs"))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.dsMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.dsSurfaceRaised, in: shape)
            .overlay(shape.strokeBorder(Color.dsBorder))
            .contentShape(shape)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityValue(Text(verbatim: options.first { $0.0 == selection }?.1 ?? ""))
    }
}

// MARK: Logo

/// CouchSubs logosu, arka plansız: yalnız kanepe ve iki amber altyazı çubuğu (design/logo.svg ile aynı geometri, 640 × 464).
struct DSLogoMark: View {
    var height: CGFloat = 26
    /// Çubuklar yavaşça daralıp genişler (yalnız hareket kapısı açıkken; telefonda varsayılan kapalı).
    var breathing = false
    @Environment(\.dsMotionGate) private var gate
    @State private var narrow = false

    var body: some View {
        let scale = height / 464
        ZStack(alignment: .topLeading) {
            rect(282, 290, 460, 320, 52, .dsLogoBack, scale)
            bar(367, 362, 290, 50, scale)
            bar(414, 436, 196, 50, scale)
            rect(262, 690, 40, 44, 12, .dsLogoSeat, scale)
            rect(722, 690, 40, 44, 12, .dsLogoSeat, scale)
            rect(202, 446, 112, 254, 56, .dsLogoSeat, scale)
            rect(710, 446, 112, 254, 56, .dsLogoSeat, scale)
            rect(202, 574, 620, 126, 56, .dsLogoSeat, scale)
        }
        .frame(width: 640 * scale, height: height, alignment: .topLeading)
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

    private func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ s: CGFloat) -> some View {
        Capsule()
            .fill(Color.dsAmber)
            .frame(width: w * s, height: h * s)
            .scaleEffect(x: narrow ? 0.6 : 1, y: 1, anchor: .center)
            .animation(narrow ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : nil, value: narrow)
            .offset(x: (x - 192) * s, y: (y - 280) * s)
    }
}

/// Logo + "CouchSubs" (ana ekranın üst satırı).
struct DSBrand: View {
    var body: some View {
        HStack(spacing: DS.space("s")) {
            DSLogoMark(height: 24)
            Text(verbatim: "CouchSubs").font(.system(.subheadline, weight: .bold)).foregroundStyle(Color.dsText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "CouchSubs"))
    }
}

// MARK: Kart (Mac ile aynı adlar)

/// Kart (Mac DSCard): yüzey zemin, 24 köşe, kıl çizgi + koyu temada üst kenar parlaması (Perde e1). Vurgulu kart komple
/// saran 1,5 pt renkli kenarlık + %5 aynı renk zemin; seçili/etkin kart 2 pt amber halka + ışıma. İçerik taşarsa kart kendi
/// içinde kayar (`scrolls`).
struct DSCard<Content: View>: View {
    var padding: CGFloat = DS.space("cardPadIOS")
    var spacing: CGFloat = DS.unitGap
    var accent: Color?
    var highlighted = false
    var scrolls = false
    var backdrop: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("card"), style: .continuous)
        Group {
            if scrolls {
                ViewThatFits(in: .vertical) {
                    stack
                    ScrollView(.vertical) { stack }
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

/// Kart başlığı (Mac DSCardHeader): cümle düzeni, 17 orta kalın; kart başlığı → ilk birim her kartta 24.
struct DSCardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing
    @Environment(\.dsCardSpacing) private var cardSpacing

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.space("s")) {
            Text(title).font(.dsCardTitle).foregroundStyle(Color.dsText).lineLimit(2).accessibilityAddTraits(.isHeader)
            Spacer(minLength: DS.space("s"))
            trailing
        }
        .padding(.bottom, max(0, DS.unitGap - cardSpacing))
    }
}

extension DSCardHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// Yatay ayraç (1 pt, kıl çizgi).
struct DSDivider: View {
    var body: some View {
        Rectangle().fill(Color.dsBorder).frame(height: 1).accessibilityHidden(true)
    }
}

// MARK: Uyarı kutusu, durum hapı

/// Önemli uyarı (Mac DSCallout): amber yumuşak zemin, komple saran ince amber kenarlık, solda simge; metin **kalın** destekler.
struct DSCallout: View {
    let text: LocalizedStringKey
    var icon = "exclamationmark.triangle.fill"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        HStack(alignment: .top, spacing: DS.space("s")) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
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

/// Durum hapı (Mac DSStatusPill): renkli nokta + kısa durum ("Çeviri Açık", "Hazır"); `pulse` iken nokta nabız atar.
struct DSStatusPill: View {
    let text: LocalizedStringKey
    let dot: Color
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
        .frame(minHeight: DS.size("tab"))
        .dsElevation(.card, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: Hesap kartı

/// Hesap kartı (Mac DSAccountCard): solda yuvarlak rozet (girişliyse amber halkalı), ortada başlık ve durum, sağda tek
/// düğme (girişliyse küçük ikincil "Yeniden Giriş Yap", değilse ana "Giriş Yap"). Altta "Diğer Giriş Yolları ›"; açılınca
/// seçenekler kartın içinde. Girişliyken kart yükseltilmiş (e2).
struct DSAccountCard<Others: View>: View {
    let badge: String
    let title: LocalizedStringKey
    let signedIn: Bool
    var detail: String?
    var busy = false
    var expanded = false
    let signIn: () -> Void
    @ViewBuilder var others: Others
    @State private var showOthers = false
    @Environment(\.dsMotionGate) private var gate

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius("tile"), style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.space("s")) {
                Text(verbatim: badge)
                    .font(.caption.weight(.heavy))
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
                    .overlay { if signedIn { Circle().inset(by: -4.5).strokeBorder(Color.dsAmber, lineWidth: 1.5) } }
                    .padding(signedIn ? 4.5 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.space("line")) {
                    Text(title).font(.dsBodyStrong).foregroundStyle(Color.dsText)
                    HStack(spacing: DS.space("xxs")) {
                        Circle().fill(signedIn ? Color.dsSuccess : Color.dsFaint).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(signedIn ? "Signed in" : "Not signed in").font(.dsSmall).foregroundStyle(Color.dsMuted)
                    }
                    if let detail { Text(verbatim: detail).font(.dsSmall).foregroundStyle(Color.dsFaint).lineLimit(1) }
                }
                Spacer(minLength: DS.space("xs"))
                if busy { ProgressView() }
                Button(signedIn ? "Sign In Again" : "Sign In", action: signIn)
                    .buttonStyle(DSButtonStyle(kind: signedIn ? .compact : .primary, fullWidth: false))
                    .disabled(busy)
            }
            .padding(DS.space("m"))
            if Others.self != EmptyView.self {
                DSDivider()
                Button {
                    withAnimation(DS.animation(.medium, gate: gate)) { showOthers.toggle() }
                } label: {
                    HStack(spacing: DS.space("xxs")) {
                        Text("Other Sign-In Ways")
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(showOthers || expanded ? 90 : 0)).accessibilityHidden(true)
                        Spacer(minLength: 0)
                    }
                    .font(.dsSmall)
                    .foregroundStyle(Color.dsMuted)
                    .padding(.horizontal, DS.space("m"))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showOthers || expanded {
                    VStack(alignment: .leading, spacing: DS.unitGap) { others }
                        .padding([.horizontal, .bottom], DS.space("m"))
                        .transition(.opacity)
                }
            }
        }
        .dsElevation(signedIn ? .raised : .card, in: shape)
    }
}

extension DSAccountCard where Others == EmptyView {
    init(badge: String, title: LocalizedStringKey, signedIn: Bool, detail: String? = nil, busy: Bool = false, signIn: @escaping () -> Void) {
        self.init(badge: badge, title: title, signedIn: signedIn, detail: detail, busy: busy, signIn: signIn) { EmptyView() }
    }
}

// MARK: Altyazı örneği

/// Altyazı kutusu örneği (Mac DSSubtitleSample): Perde altyazı plakası.
struct DSSubtitleSample: View {
    var speaker: String?
    let line: String
    var size: CGFloat = 17

    var body: some View {
        DSSubtitlePlate(speaker: speaker, line: line, size: size)
    }
}

// MARK: Bölüm başlığı

/// Başlık + altında açıklama (Mac DSSectionTitle): aralık her yerde `DS.space("titleBody")` (6).
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
