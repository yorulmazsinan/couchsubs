// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Kurulum sihirbazı: solda adım listesi, sağda adımın karosu, altında Geri / Devam.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.space("gap")) {
            StepSidebar()
            VStack(spacing: Theme.space("gap")) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            switch model.step {
                            case .welcome: WelcomeStep()
                            case .secondAccount: SecondAccountStep()
                            case .psnLogin: PSNLoginStep()
                            case .console: ConsoleStep()
                            case .tv: TVStep()
                            case .test: TestStep()
                            case .betterTranslation, .done: BetterTranslationStep()
                            }
                        }
                        .padding(Theme.space("xl"))
                    }
                    // Adımlar kendi iletilerini görünür kılabilsin (ör. PS5 eşleşti iletisi kaydırılmış alanda kalmasın).
                    .environment(\.scrollOnboardingTo, { id in
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tile(padding: 0)
                StepButtons()
            }
        }
        .padding(Theme.space("screen"))
    }
}

extension EnvironmentValues {
    /// Sihirbazın kaydırma alanında verilen kimlikli görünüme kaydırır (adımın dışında hiçbir şey yapmaz).
    @Entry var scrollOnboardingTo: (String) -> Void = { _ in }
}

/// Geri ve Devam (ya da isteğe bağlı adımda "Şimdilik geç").
private struct StepButtons: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Theme.space("m")) {
            if model.step != .welcome {
                Button("Back") { model.back() }.buttonStyle(CSButtonStyle(kind: .secondary, height: "buttonLarge"))
            }
            Spacer()
            if model.step == .betterTranslation && !model.usesFreeGemini {
                // İsteğe bağlı adım: anahtar yoksa geçilir (birincil düğme adımdaki "Ücretsiz anahtar al").
                Button("Skip for now") { model.advance() }
                    .buttonStyle(CSButtonStyle(kind: .secondary, height: "buttonLarge"))
            } else if model.step != .test {
                Button("Continue") { model.advance() }
                    .buttonStyle(CSButtonStyle(kind: .primary, height: "buttonLarge"))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canAdvance)
            }
        }
    }
}

/// Adım listesi: biten adımlar onaylı, sıradaki adım vurgulu; altta "Adım n / toplam" ve ilerleme çubuğu.
private struct StepSidebar: View {
    @EnvironmentObject private var model: AppModel

    private var steps: [AppModel.Step] { AppModel.Step.allCases.filter { $0 != .done } }

    var body: some View {
        let total = steps.count
        VStack(alignment: .leading, spacing: Theme.space("xs")) {
            HStack(spacing: Theme.space("m")) {
                LogoView(size: 32)
                Text("Setup").font(.csTitle)
            }
            .padding(.horizontal, Theme.space("s"))
            .padding(.bottom, Theme.space("m"))
            ForEach(steps, id: \.self) { step in
                StepRow(step: step, current: model.step)
            }
            Spacer(minLength: Theme.space("l"))
            Text(String(format: String(localized: "Step %lld of %lld"), min(model.step.rawValue + 1, total), total))
                .font(.csCaption.monospacedDigit())
                .foregroundStyle(Color.csSecondary)
                .padding(.horizontal, Theme.space("s"))
            ProgressBar(value: Double(model.step.rawValue + 1) / Double(total))
                .padding(.horizontal, Theme.space("s"))
                .padding(.top, Theme.space("xs"))
        }
        .frame(width: Theme.size("sidebarWidth"), alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .tile(padding: Theme.space("m"))
    }
}

private struct StepRow: View {
    let step: AppModel.Step
    let current: AppModel.Step

    private var isDone: Bool { step.rawValue < current.rawValue }
    private var isCurrent: Bool { step == current }

    var body: some View {
        HStack(spacing: Theme.space("m")) {
            marker
            Text(Self.title(step))
                .font(isCurrent ? .csBody.weight(.semibold) : .csBody)
                .foregroundStyle(isCurrent || isDone ? Color.csText : Color.csSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.space("s"))
        .padding(.vertical, Theme.space("s"))
        .background(isCurrent ? Color.csSurface2 : Color.clear, in: RoundedRectangle(cornerRadius: Theme.radius("control"), style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// Bitti: yeşil daire ve onay; şimdi: sarı daire; sonra: nötr daire. Parıltı yok.
    @ViewBuilder private var marker: some View {
        let size: CGFloat = 28
        if isDone {
            Image(systemName: "checkmark")
                .font(.csCaption.weight(.semibold))
                .foregroundStyle(Color.csSurface)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.csSuccess))
        } else {
            Text("\(step.rawValue + 1)")
                .font(.csCaption.monospacedDigit().weight(.semibold))
                .foregroundStyle(isCurrent ? Color.csOnAccent : Color.csSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(isCurrent ? Color.csAccent : Color.csSurface2))
        }
    }

    /// Adımın kendi başlığı (adım ekranındaki StepLayout başlığıyla aynı).
    static func title(_ step: AppModel.Step) -> LocalizedStringKey {
        switch step {
        case .welcome: "Welcome to CouchSubs"
        case .secondAccount: "A second PSN account"
        case .psnLogin: "Sign in with the second account"
        case .console: "Connect your PS5"
        case .tv: "Connect your TV"
        case .test: "Let's test it"
        case .betterTranslation, .done: "Better translation (free)"
        }
    }
}

/// İnce, yuvarlak uçlu ilerleme çubuğu.
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.csBorder)
                Capsule().fill(Color.csAccent)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(verbatim: "\(Int(value * 100))%"))
    }
}
