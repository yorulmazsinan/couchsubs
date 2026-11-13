// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// TV uygulamasını geliştirici moduyla kurma adımları (LG, Samsung, Android TV). Yapılacak bir şey yoksa görünmez.
struct TVAppCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""

    private var brand: TVBrand { model.tv?.brand ?? .lg }

    var body: some View {
        Group {
            switch model.tvApp {
            case .unknown:
                EmptyView()
            case .working:
                Card(title: "CouchSubs TV app") {
                    HStack(spacing: Theme.space("s")) {
                        ProgressView().controlSize(.small)
                        Text("Installing the TV app…").foregroundStyle(Color.csSecondary)
                    }
                }
            case .upToDate(let version):
                Card(title: "CouchSubs TV app") {
                    DoneLabel(text: String(format: String(localized: "The TV app is ready (version %@)."), version))
                    if brand == .lg {
                        if let hours = model.devModeHoursLeft {
                            HintText(text: "Developer Mode: \(hours) hours left. CouchSubs extends it by itself each time you use it.")
                        } else {
                            HintText(text: "CouchSubs extends Developer Mode by itself each time you use it.")
                        }
                    } else if brand == .samsung {
                        HintText(text: "If the TV keeps switching to HDMI 1 or another source while the CouchSubs TV app is open, turn off Anynet+ (HDMI-CEC) and Auto Source Switching on the TV: Settings › All Settings › Connection › External Device Manager.")
                    }
                }
            case .devModeOff:
                devModeSteps
                    // Kullanıcı TV'de geliştirici modunu açınca kendiliğinden devam eder.
                    .task {
                        while !Task.isCancelled, model.tvApp == .devModeOff {
                            try? await Task.sleep(for: .seconds(3))
                            await model.refreshTVApp()
                        }
                    }
            case .needsPassphrase(let error):
                passphraseCard(error: error)
            case .signIn(let url):
                Card(title: "CouchSubs TV app") {
                    Text("The Samsung account page opened in your browser. Finish signing in there. If you do not see it, switch to the browser or press Open the page again.")
                    HintText(text: "Samsung signs the app for your TV with your free Samsung account.")
                    HintText(text: "No account? You can create a free one on the same page. If the browser asks to allow access to devices on your network, allow it.")
                    // Samsung'un sayfası girişi açılır pencerede açıyor; engellenince kullanıcılar takılıyordu (Burak Yazgan, 2026-11-13).
                    HintText(text: "If the sign-in window does not open, the browser may have blocked it as a pop-up: allow pop-ups for this page from the icon in the address bar, then press Open the page again.")
                    HStack(spacing: Theme.space("s")) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for sign-in…").foregroundStyle(Color.csSecondary)
                        Spacer()
                        Button("Open the page again") { model.openInBrowser(url) }.buttonStyle(.secondary)
                        // Tarayıcı açılmazsa bağlantı başka bir tarayıcıya yapıştırılabilir.
                        Button("Copy the link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }.buttonStyle(.secondary)
                    }
                }
            case .approveOnTV:
                Card(title: "CouchSubs TV app") {
                    Text("Look at the TV: it asks whether to allow debugging from this computer.")
                    HintText(text: "Tick “Always allow from this computer” and choose Allow. The app then installs by itself.")
                    HStack(spacing: Theme.space("s")) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the TV…").foregroundStyle(Color.csSecondary)
                    }
                }
            case .failed(let error, let reason):
                Card(title: "CouchSubs TV app") {
                    ErrorText(error: Self.message(for: error, brand: brand, reason: reason))
                    Button("Try again") { Task { await model.refreshTVApp() } }.buttonStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var devModeSteps: some View {
        switch brand {
        case .lg:
            Card(title: "CouchSubs TV app") {
                Text("The TV app is not installed. CouchSubs can install it once Developer Mode is on.")
                HintText(text: "1. Create a free account at webostv.developer.lge.com.")
                HintText(text: "2. On the TV, install Developer Mode from the LG Content Store and sign in.")
                HintText(text: "3. Turn on Dev Mode Status. The TV restarts and this screen continues by itself.")
            }
        case .samsung:
            Card(title: "CouchSubs TV app") {
                Text("The TV app is not installed. CouchSubs installs it once Developer Mode is on.")
                HintText(text: "1. On the TV, open Apps and scroll to the very bottom of the page.")
                HintText(text: "2. There, press 1 2 3 4 5 on the remote (or type 12345 on the on-screen keypad). The Developer Mode window opens.")
                HintText(text: "3. Turn Developer mode On, type this computer's address as Host PC IP: \(model.computerAddress ?? "?") and press OK.")
                HintText(text: "4. Restart the TV: hold the power button on the remote for about 2 seconds until the TV turns off, then turn it on again. This screen continues by itself.")
                HintText(text: "Later you sign in once with a free Samsung account; Samsung needs it to sign the app for your TV.")
                HintText(text: "If the TV keeps switching to HDMI 1 or another source while the CouchSubs TV app is open, turn off Anynet+ (HDMI-CEC) and Auto Source Switching on the TV: Settings › All Settings › Connection › External Device Manager.")
            }
        case .androidTV:
            Card(title: "CouchSubs TV app") {
                Text("The TV app is not installed. CouchSubs installs it over the network once debugging is on.")
                HintText(text: "1. On the TV, open Settings › Device Preferences › About (Google TV: Settings › System › About).")
                HintText(text: "2. Press OK on Build 7 times until it says you are a developer.")
                HintText(text: "3. Go back to Device Preferences (Google TV: System) › Developer options and turn on USB debugging. Turn on Network debugging too if you see it.")
                HStack(spacing: Theme.space("s")) {
                    ProgressView().controlSize(.small)
                    Text("Looking for the TV on the network…").foregroundStyle(Color.csSecondary)
                }
                HintText(text: "Menu names differ a little by brand. If the app is already on the TV, you can skip this step.")
                Link("Install with a USB stick instead", destination: AppIdentity.tvGuideURL)
            }
        }
    }

    private func passphraseCard(error: DevModeError?) -> some View {
        Card(title: "CouchSubs TV app") {
            Text("Developer Mode is on. One last step to install the TV app:")
            HintText(text: "Open the Developer Mode app on the TV, turn on Key Server and keep the app on screen. Type the Passphrase it shows.")
            HStack {
                TextField("Passphrase", text: $passphrase)
                    .textFieldStyle(CSTextFieldStyle())
                Button("Install on the TV") { Task { await model.installTVApp(passphrase: passphrase) } }
                    .buttonStyle(.primary)
                    .disabled(passphrase.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ErrorText(error: error.map { Self.message(for: $0, brand: .lg) })
        }
    }

    /// `reason`: TV'nin verdiği sebep; varsa mesajın altına eklenir. Samsung'da ayrıntı (TV'nin kurulum çıktısı,
    /// Samsung'un yanıtı) ve gönderilecek günlük dosyası da yazılır: hiçbir hata genel mesajda kalmasın.
    static func message(for error: DevModeError, brand: TVBrand, reason: String?) -> String {
        var text = message(for: error, brand: brand, hasReason: reason != nil)
        let samsung = brand == .samsung
        if let reason {
            let label = samsung ? String(localized: "Details:") : String(localized: "TV says:")
            text += "\n\n" + label + " " + reason
        }
        // Mac App Store sürümü sandbox'ta kurar (ssh, ssh-keygen ve yardımcı sandbox'ı miras alır). Sandbox bir adımı
        // engellerse kullanıcı çıkışsız kalmasın: TV uygulaması bir kez GitHub (DMG) sürümüyle kurulur, sonrası yeter.
        if Distribution.isAppStore, error == .installFailed {
            text += "\n\n" + String(localized: "If the Mac App Store version cannot install the TV app, install it once with the GitHub (DMG) version of CouchSubs. After that, this version is enough.")
        }
        guard samsung else { return text }
        if error == .installFailed || error == .certificateRejected {
            text += "\n\n" + String(localized: "If the TV shows “Server under maintenance”, it cannot reach Samsung's servers: check the TV's internet connection and its date and time, restart the TV and try again.")
        }
        // Samsung kısa basışta yalnız bekleme moduna geçer; "yeniden başlatın" diyen hatalarda nasıl yapılacağı yazılır.
        if error == .unreachable || error == .installFailed || error == .certificateRejected {
            text += "\n\n" + String(localized: "To restart a Samsung TV fully, hold the power button on the remote for about 2 seconds until it turns off; a short press only puts it on standby.")
        }
        // TV kurulum sırasında HDMI-CEC yüzünden başka kaynağa geçerse bağlantı kopar.
        if error == .connectionLost {
            text += "\n\n" + String(localized: "If the TV keeps switching to HDMI 1 or another source while the CouchSubs TV app is open, turn off Anynet+ (HDMI-CEC) and Auto Source Switching on the TV: Settings › All Settings › Connection › External Device Manager.")
        }
        let send = String(format: String(localized: "If this keeps happening, send us this file: %@"), TVInstallLog.displayPath)
        return text + "\n\n" + send
    }

    static func message(for error: DevModeError, brand: TVBrand, hasReason: Bool = false) -> String {
        switch error {
        case .keyServerOff: String(localized: "Key Server is off. Turn it on in the Developer Mode app and keep the app on screen.")
        case .wrongPassphrase: String(localized: "The passphrase is not correct. Check it on the TV screen.")
        case .keyRefused: String(localized: "The TV refused the key. Open Key Server and type the passphrase again.")
        case .unreachable where brand == .samsung:
            String(localized: "The TV did not accept this computer. In the TV's Developer Mode window, check that Host PC IP is this computer's address, then restart the TV.")
        case .unreachable: String(localized: "The TV did not respond. Make sure it is on and on the same network.")
        // Eskiden her hatada boş alan suçlanıyordu; oysa çoğu zaman sorun başkaydı (ares-install aynı TV'ye kurabiliyordu).
        case .installFailed where hasReason:
            String(localized: "The TV app could not be installed. Try again; if it fails again, send us the reason below.")
        case .installFailed: String(localized: "The TV app could not be installed. Try again.")
        case .notEnoughSpace: String(localized: "The TV is out of free space. Remove an app you do not use from the TV and try again.")
        case .tooOld: String(localized: "This Samsung TV is too old for the CouchSubs TV app (2017 models and later are supported).")
        case .signInFailed: String(localized: "Samsung sign-in did not complete. Try again and finish signing in on the page that opens.")
        case .certificateFailed: String(localized: "Samsung did not issue the signing certificate. Try again in a few minutes.")
        case .notApproved: String(localized: "Debugging was not allowed on the TV. Try again and choose Allow on the TV.")
        case .certificateMismatch:
            String(localized: "A CouchSubs TV app signed on another computer is still on the TV and could not be removed. On the TV, open Apps, select CouchSubs, delete it and try again.")
        case .certificateRejected:
            String(localized: "The TV did not accept the signing certificate. Make sure the TV is connected to the internet (it checks the certificate with Samsung) and its date and time are right (Settings › General › System Manager › Time), then try again. CouchSubs gets a new certificate, so you sign in to Samsung once more.")
        case .tvClockWrong:
            String(localized: "The TV's clock is behind, so the new certificate is not valid for it yet. Set the TV's date and time (Settings › General › System Manager › Time) or wait a few minutes, then try again.")
        case .packageBlocked:
            String(localized: "The TV refuses CouchSubs because an earlier CouchSubs is still registered on it (Tizen error 118, -22), even if it no longer appears among the apps. If CouchSubs is among the TV's apps, delete it there and try again. Otherwise reset Smart Hub (Settings › Support › Device Care › Self Diagnosis › Reset Smart Hub; menu names differ a little by model) and try again. Resetting Smart Hub also removes the other apps you downloaded.")
        case .connectionLost:
            String(localized: "The connection to the TV dropped during the install. Keep the TV on and on the same network as this computer, then try again.")
        }
    }
}
