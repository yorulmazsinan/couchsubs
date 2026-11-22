// SPDX-License-Identifier: AGPL-3.0-only

import CouchSubsCore
import SwiftUI

/// Ana pencerenin sekmeleri. Ayarlar ve Geçmiş eskiden ayrı sayfa (sheet) idi; menüdeki "Ayarlar" (⌘,) ve
/// `openSettings(_:)` aynı bayraklarla sekmeyi açar.
enum ShellTab: Hashable {
    case home, history, settings
}

/// Yeni arayüzün kabuğu: 72 pt üst çubuk (logo, Ana Ekran/Geçmiş/Ayarlar sekmeleri, durum hapı), içerik ve altta
/// reklam bandı. En küçük pencere 1200 × 760; büyüyünce içerik en fazla 1680 genişlikte ortalanır.
struct AppShell: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Açılır reklam (günde en çok bir; açılışta ya da çeviri durunca).
    @State private var popupAd: PopupAd?

    private var tab: Binding<ShellTab> {
        Binding(get: { model.showSettings ? .settings : model.showHistory ? .history : .home },
                set: { value in
                    model.showSettings = value == .settings
                    model.showHistory = value == .history
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            ShellHeader(tab: tab)
            Group {
                switch tab.wrappedValue {
                case .home: HomeView()
                case .history: HistoryPage()
                case .settings: SettingsPage(section: Binding(get: { model.settingsSection }, set: { model.settingsSection = $0 }))
                }
            }
            .transition(.opacity)
            .id(tab.wrappedValue)
            // İçerik pencereden uzun olsa da üst çubuk ve reklam bandı yerinde kalır (kartlar kendi içinde kayar).
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
            DSAdBand()
                .padding(.horizontal, DS.space("l"))
                .padding(.bottom, DS.space("m"))
        }
        .frame(maxWidth: DS.size("contentMax"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBackground)
        .animation(DS.animation(.page, reduced: reduceMotion || !model.settings.transitionAnimations), value: tab.wrappedValue)
        .environment(\.dsMotionOff, !model.settings.transitionAnimations)
        .overlay {
            if let popupAd {
                ZStack {
                    Color.dsScrim.ignoresSafeArea().onTapGesture { self.popupAd = nil }
                    PopupAdView(ad: popupAd) { self.popupAd = nil }
                        .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
                }
                .transition(.opacity)
            }
        }
        .animation(DS.animation(.page, reduced: reduceMotion || !model.settings.transitionAnimations), value: popupAd)
        .onAppear { popupAd = PopupAdSchedule.next(model: model) }
        .onChange(of: model.isRunning) { running in
            // Çeviri başlayınca açık reklam kapanır; çeviri durunca (günde bir) gösterilebilir.
            popupAd = running ? nil : PopupAdSchedule.next(model: model)
        }
        .newLook()
        .alert(item: $model.tvPairingRequest) { ticket in
            Alert(title: Text("Pair this TV?"),
                  message: Text(String(format: String(localized: "TV code: %@. You don't type this code anywhere: if your TV shows the same code, approve it here."), ticket.code)),
                  primaryButton: .default(Text("Approve")) { model.resolveTVPairing(ticket, accept: true) },
                  secondaryButton: .cancel(Text("Reject")) { model.resolveTVPairing(ticket, accept: false) })
        }
    }
}

/// Üst çubuk: üç sütun (sol logo, orta sekmeler, sağ durum hapı); yanlarda 24.
private struct ShellHeader: View {
    @EnvironmentObject private var model: AppModel
    @Binding var tab: ShellTab

    var body: some View {
        HStack(spacing: DS.space("m")) {
            DSBrand().frame(maxWidth: .infinity, alignment: .leading)
            DSTabs(selection: $tab, items: [(.home, "Home"), (.history, "History"), (.settings, "Settings")], fill: false)
                .fixedSize()
            HStack {
                let status = ShellStatus(model: model)
                DSStatusPill(text: status.text, dot: status.dot)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, DS.space("l"))
        .frame(height: DS.size("header"))
    }
}

/// Durum hapının metni ve rengi (METINLER.md › Pencere kabuğu).
struct ShellStatus {
    let text: LocalizedStringKey
    let dot: Color

    @MainActor init(model: AppModel) {
        if model.demoMode {
            (text, dot) = ("Demo Mode", .dsAmber)
        } else if model.isRunning {
            switch model.sessionState {
            case .streaming:
                (text, dot) = HomeProblem.current(model) == nil ? ("Translation On", .dsSuccess) : ("Needs Attention", .dsLive)
            case .connecting:
                (text, dot) = ("Connecting…", .dsAmber)
            case .disconnected:
                (text, dot) = ("Needs Attention", .dsLive)
            }
        } else if model.isStarting {
            (text, dot) = ("Connecting…", .dsAmber)
        } else if !model.canStart {
            (text, dot) = ("Setup Incomplete", .dsFaint)
        } else {
            (text, dot) = ("Ready", .dsFaint)
        }
    }
}
