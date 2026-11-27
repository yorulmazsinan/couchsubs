// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CouchSubsCore
import SwiftUI

/// TV uygulamasını geliştirici moduyla kurma adımları (LG, Samsung, Android TV). Yapılacak bir şey yoksa görünmez.
struct TVAppCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var passphrase = ""
    @State private var logCopied = false

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
                    // Uygulama "hazır" görünüp TV'de yoksa ya da açılmıyorsa (TV uygulaması bağlı değil) yeniden kurulabilir (#352, #389).
                    if model.canReinstallTVApp {
                        Button("Reinstall the TV app") { Task { await model.reinstallTVApp() } }.buttonStyle(.secondary)
                    }
                }
            case .pressInstallOnTV:
                Card(title: "CouchSubs TV app") {
                    Text("The Google Play page opened on the TV: press Install (or Update) with the TV remote. The app opens by itself once it is installed.")
                    HStack(spacing: Theme.space("s")) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the TV…").foregroundStyle(Color.csSecondary)
                    }
                }
            case .devModeOff:
                devModeSteps
                    // Kullanıcı TV'de geliştirici modunu açınca kendiliğinden devam eder.
                    // Kart kapanınca (ör. "Devam") bekleme iptal olur; iptal edilmiş görevde TV'ye bir daha sorulmaz (#359).
                    .task {
                        while !Task.isCancelled, model.tvApp == .devModeOff {
                            do { try await Task.sleep(for: .seconds(3)) } catch { return }
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
                    ErrorText(error: Self.message(for: error, brand: brand, reason: reason, address: model.computerAddress))
                    // TV bu Mac'i kabul etmediyse Host PC IP'ye yazılacak adres de görünür (#343).
                    if brand == .samsung, error == .unreachable {
                        HintText(text: "This computer's address (Host PC IP): \(model.computerAddress ?? "?")")
                        otherAddresses
                    }
                    Button("Try again") { Task { await model.refreshTVApp() } }.buttonStyle(.secondary)
                    logActions
                }
            case .chooseAndroidTV(let hosts):
                // Aynı ağda iki Android TV: izin sorusu yanlış odadaki TV'de çıkmasın diye TV sorulur (#425).
                Card(title: "CouchSubs TV app") {
                    Text("More than one Android TV with debugging on was found on the network. Which one is yours?")
                    HintText(text: "You can see the TV's address on the TV in Settings › Network & Internet.")
                    ForEach(hosts, id: \.self) { host in
                        Button(String(format: String(localized: "Install on the TV at %@"), host)) {
                            Task { await model.chooseAndroidTV(host) }
                        }
                        .buttonStyle(.secondary)
                    }
                    Button("Search again") { Task { await model.refreshTVApp() } }.buttonStyle(.secondary)
                }
            case .hostPcMismatch(let tvIp, let computer):
                Card(title: "CouchSubs TV app") {
                    ErrorText(error: String(format: String(localized: "The TV's Host PC IP is %1$@, but this computer's address is %2$@. In the TV's Developer Mode window, set Host PC IP to %2$@ and restart the TV fully (hold the power button until the Samsung logo appears, about 5 seconds)."), tvIp, computer))
                    HintText(text: "1. On the TV, open Apps and scroll to the very bottom of the page.")
                    HintText(text: "2. There, press 1 2 3 4 5 on the remote (or type 12345 on the on-screen keypad). The Developer Mode window opens.")
                    HintText(text: "3. Turn Developer mode On, type this computer's address as Host PC IP: \(computer) and press OK.")
                    otherAddresses
                    HintText(text: "4. Restart the TV: hold the power button on the remote and keep holding until the TV turns off and comes back on with the Samsung logo (about 5 seconds); letting go when it turns off only puts it on standby. If no logo appears, unplug the TV for 30 seconds. This screen continues by itself.")
                    Button("Try again") { Task { await model.refreshTVApp() } }.buttonStyle(.secondary)
                }
                // Host PC IP düzeltilip TV yeniden başlayınca kendiliğinden devam eder.
                .task {
                    while !Task.isCancelled, case .hostPcMismatch = model.tvApp {
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        await model.refreshTVApp()
                    }
                }
            }
        }
        // TV'de CouchSubs'ın kimliğiyle başka uygulama: kaldırıp CouchSubs'ı kurmak için onay. "Vazgeç"te hiçbir şey
        // silinmez; kartta aynı metin ve "Yeniden dene" kalır (Windows, iPhone ve Android ile aynı).
        .onAppear { askForeign(model.tvApp) }
        .onChange(of: model.tvApp) { state in askForeign(state) }
        // Yeni arayüzde açılır kart: "Kaldırıp Kur" amber ana eylem, "Vazgeç" ikincil (design/yeni-arayuz/METINLER.md).
        .sheet(isPresented: Binding(get: { foreignPrompt && newLook }, set: { foreignPrompt = $0 })) {
            ForeignTVAppPrompt { replace in
                foreignPrompt = false
                if replace { Task { await model.replaceForeignTVApp() } }
            }
        }
        .alert("Another App Is Installed", isPresented: Binding(get: { foreignPrompt && !newLook }, set: { foreignPrompt = $0 })) {
            Button("Remove And Install", role: .destructive) { Task { await model.replaceForeignTVApp() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Another app on this TV is using the CouchSubs identity. Remove it and install CouchSubs?")
        }
    }

    @State private var foreignPrompt = false
    @Environment(\.csNewLook) private var newLook

    private func askForeign(_ state: TVAppState) {
        if case .failed(.foreignApp, _) = state { foreignPrompt = true }
    }

    /// Kurulum hatasında günlük (tvinstall.log) üç markada da Finder'da gösterilir ya da panoya kopyalanır
    /// (telefonlardaki "Kurulum günlüğünü paylaş"ın karşılığı).
    private var logActions: some View {
        HStack(spacing: Theme.space("s")) {
            Button("Show the install log") { Self.showLogInFinder() }.buttonStyle(.secondary)
            Button(logCopied ? "Copied" : "Copy the log") {
                let log = TVInstallLog.tail()
                guard !log.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log, forType: .string)
                logCopied = true
            }.buttonStyle(.secondary)
        }
    }

    /// Günlük dosyasını Finder'da seçili gösterir; dosya henüz yoksa klasörünü açar.
    static func showLogInFinder() {
        let file = TVInstallLog.file
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// Wi-Fi ve Ethernet ikisi de bağlıysa ya da birden çok ağ varsa Host PC IP için diğer adresler de yazılır.
    @ViewBuilder
    private var otherAddresses: some View {
        let others = model.otherComputerAddresses
        if !others.isEmpty {
            HintText(text: "If the TV does not accept this address, try one of this computer's other addresses: \(others.joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private var devModeSteps: some View {
        switch brand {
        // Vestel Linux'ta bilgisayar TV'ye kurulum yapmaz; elle kurulum adımları kendi kartında (VestelTVCard).
        case .vestelLinux:
            EmptyView()
        case .lg:
            Card(title: "CouchSubs TV app") {
                Text("The TV app is not installed. CouchSubs can install it once Developer Mode is on.")
                HintText(text: "1. Create a free account at webostv.developer.lge.com.")
                HintText(text: "2. On the TV, install Developer Mode from the LG Content Store and sign in.")
                HintText(text: "3. Turn on Dev Mode Status. The TV restarts and this screen continues by itself.")
                // Parola alanı burada da görünür: CouchSubs geliştirici modunu göremese de TV'de Key Server ve parola
                // açıksa kullanıcı takılmaz (#94). Anahtar ancak "TV'ye kur"a basılınca istenir.
                passphraseEntry(error: nil)
            }
        case .samsung:
            Card(title: "CouchSubs TV app") {
                Text("The TV app is not installed. CouchSubs installs it once Developer Mode is on.")
                // Telefonlardaki kurulum ekranıyla aynı not: 2016 (Tizen 2.4) ve sonrası kurulur, 2016–2018 deneysel.
                HintText(text: "Samsung TVs and smart monitors (2016 and later; 2016–2018 models are experimental).")
                HintText(text: "1. On the TV, open Apps and scroll to the very bottom of the page.")
                HintText(text: "2. There, press 1 2 3 4 5 on the remote (or type 12345 on the on-screen keypad). The Developer Mode window opens.")
                HintText(text: "3. Turn Developer mode On, type this computer's address as Host PC IP: \(model.computerAddress ?? "?") and press OK.")
                otherAddresses
                HintText(text: "4. Restart the TV: hold the power button on the remote and keep holding until the TV turns off and comes back on with the Samsung logo (about 5 seconds); letting go when it turns off only puts it on standby. If no logo appears, unplug the TV for 30 seconds. This screen continues by itself.")
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
            passphraseEntry(error: error)
        }
    }

    /// Key Server parolası alanı ve kurma düğmesi; parola kartında ve LG'nin geliştirici modu adımlarında aynı.
    @ViewBuilder
    private func passphraseEntry(error: DevModeError?) -> some View {
        HintText(text: "Open the Developer Mode app on the TV, turn on Key Server and keep the app on screen. Type the Passphrase it shows.")
        HStack {
            TextField("Passphrase", text: $passphrase)
                .textFieldStyle(CSTextFieldStyle())
            Button("Install on the TV") { Task { await model.installTVApp(passphrase: passphrase) } }
                .buttonStyle(.primary)
                .disabled(passphrase.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ErrorText(error: error.map { Self.message(for: $0, brand: .lg) })
        if error != nil { logActions }
    }

    /// `reason`: TV'nin verdiği sebep; varsa mesajın altına eklenir. Samsung'da ayrıntı (TV'nin kurulum çıktısı,
    /// Samsung'un yanıtı) da yazılır: hiçbir hata genel mesajda kalmasın. Gönderilecek günlük dosyası üç markada da
    /// yazılır (önceden yalnız Samsung'da).
    /// `address`: TV'nin göreceği bu Mac'in adresi; Samsung "TV kabul etmedi" hatasındaki adım satırına yazılır.
    static func message(for error: DevModeError, brand: TVBrand, reason: String?, address: String? = nil) -> String {
        // Soru penceresinin metni; "Vazgeç"ten sonra kartta da bu kalır ("Yeniden dene" yine sorar).
        if error == .foreignApp { return message(for: error, brand: brand) }
        var text = message(for: error, brand: brand, hasReason: reason != nil)
        let samsung = brand == .samsung
        // LG "ipk verified failed" (-5): saat yerindeyse de ne yapılacağı söylenir (iPhone, Windows, Android aynı).
        if brand == .lg, error == .installFailed, let reason, DevModeInstaller.isPackageVerifyFailure(reason) {
            text = String(localized: "The TV could not verify the TV app package (ipk verified failed). Check that the TV's date and time are right (Settings › General › System › Time & Timer), unplug the TV for 30 seconds, plug it back in and try again. If it fails again, send us the reason below.")
        }
        // Kurulum bağlantısı reddedildi ("IP hatası", #1158): menü, iki ayar ve bu cihazın adresi tek satırda (iPhone,
        // Windows ve Android ile aynı).
        if samsung, error == .unreachable { text += "\n\n" + hostPcSteps(address) }
        if let reason {
            let label = samsung ? String(localized: "Details:") : String(localized: "TV says:")
            text += "\n\n" + label + " " + reason
        }
        // Mac App Store sürümü sandbox'ta kurar (ssh, ssh-keygen ve yardımcı sandbox'ı miras alır). Sandbox bir adımı
        // engellerse kullanıcı çıkışsız kalmasın: TV uygulaması bir kez GitHub (DMG) sürümüyle kurulur, sonrası yeter.
        if Distribution.isAppStore, error == .installFailed {
            text += "\n\n" + String(localized: "If the Mac App Store version cannot install the TV app, install it once with the GitHub (DMG) version of CouchSubs. After that, this version is enough.")
        }
        let send = String(format: String(localized: "If this keeps happening, send us this file: %@"), TVInstallLog.displayPath)
        guard samsung else { return text + "\n\n" + send }
        if error == .installFailed || error == .certificateRejected {
            text += "\n\n" + String(localized: "If the TV shows “Server under maintenance”, it cannot reach Samsung's servers: check the TV's internet connection and its date and time, restart the TV and try again.")
        }
        // TV'nin kendi "Samsung sunucusuna bağlanılamıyor (AS400)" uyarısı (Samsung 7 Series 2018, 21 Kas).
        if error == .installFailed || error == .certificateRejected || error == .unreachable {
            text += "\n\n" + String(localized: "If the TV shows “Unable to connect to Samsung server” (AS400): this warning comes from the TV itself; the TV can't reach Samsung's servers. Check the TV's internet connection, unplug the TV and plug it back in after 30 seconds. To install CouchSubs, enter this device's address as Host PC IP.")
        }
        // Samsung kısa basışta yalnız bekleme moduna geçer; "yeniden başlatın" diyen hatalarda nasıl yapılacağı yazılır.
        if error == .unreachable || error == .installFailed || error == .certificateRejected {
            text += "\n\n" + String(localized: "To restart a Samsung TV fully, hold the power button on the remote until the TV turns off and comes back on with the Samsung logo (about 5 seconds), or unplug it for 30 seconds. Letting go when it turns off only puts it on standby.")
        }
        // TV kurulum sırasında HDMI-CEC yüzünden başka kaynağa geçerse bağlantı kopar.
        if error == .connectionLost {
            text += "\n\n" + String(localized: "If the TV keeps switching to HDMI 1 or another source while the CouchSubs TV app is open, turn off Anynet+ (HDMI-CEC) and Auto Source Switching on the TV: Settings › All Settings › Connection › External Device Manager.")
        }
        return text + "\n\n" + send
    }

    /// Samsung'da Host PC IP'nin nerede ve neye ayarlanacağı; adres bilinmiyorsa "?".
    static func hostPcSteps(_ address: String?) -> String {
        String(format: String(localized: "On the TV: Apps › press 1 2 3 4 5 › Developer mode On, Host PC IP = this device's IP (%@), then restart the TV."),
               address ?? "?")
    }

    static func message(for error: DevModeError, brand: TVBrand, hasReason: Bool = false) -> String {
        switch error {
        case .keyServerOff: String(localized: "Key Server is off. Turn it on in the Developer Mode app and keep the app on screen.")
        case .wrongPassphrase: String(localized: "The passphrase is not correct. Check it on the TV screen.")
        case .keyRefused: String(localized: "The TV refused the key. Open Key Server and type the passphrase again.")
        case .unreachable where brand == .samsung:
            String(localized: "The TV did not accept this computer. In the TV's Developer Mode window, check that Host PC IP is this computer's address, then restart the TV.")
        case .unreachable: String(localized: "The TV did not respond. Make sure it is on and on the same network.")
        // Kayıtlı adres sessiz, TV ağda da bulunamadı: "geliştirici modu / Key Server kapalı" denmez (beta.89).
        case .tvNotResponding: String(localized: "The TV isn't responding at this address (is it on and on the same network?)")
        // #200, #1116: Key Server yanıt veriyor ama 9922 reddediyor (iPhone/Android'deki lgErrRestartNeeded ile aynı metin).
        case .devConnectionClosed:
            String(localized: "Developer mode looks on (the TV's Key Server answers), but the TV refuses the install connection. Unplug the TV for 30 seconds and plug it back in (or press RESTART in the Developer Mode app), then open the Developer Mode app, check that Dev Mode Status is on, turn on Key Server and try again. On some TVs that use webOS Hub this connection may be closed in the TV's software; the TV app then cannot be installed this way.")
        // Eskiden her hatada boş alan suçlanıyordu; oysa çoğu zaman sorun başkaydı (ares-install aynı TV'ye kurabiliyordu).
        case .installFailed where hasReason:
            String(localized: "The TV app could not be installed. Try again; if it fails again, send us the reason below.")
        case .installFailed: String(localized: "The TV app could not be installed. Try again.")
        case .notEnoughSpace: String(localized: "The TV is out of free space. Remove an app you do not use from the TV and try again.")
        case .tooOld: String(localized: "This Samsung TV is too old for the CouchSubs TV app (2016 models and later are supported).")
        case .signInFailed: String(localized: "Samsung sign-in did not complete. Try again and finish signing in on the page that opens.")
        case .certificateFailed: String(localized: "Samsung did not issue the signing certificate. Try again in a few minutes.")
        case .notApproved: String(localized: "Debugging was not allowed on the TV. Try again and choose Allow on the TV.")
        case .certificateMismatch:
            String(localized: "A CouchSubs TV app signed on another computer is still on the TV and could not be removed. On the TV, open Apps, select CouchSubs, delete it and try again.")
        case .certificateRejected:
            String(localized: "The TV did not accept the signing certificate. Make sure the TV is connected to the internet (it checks the certificate with Samsung) and its date and time are right (Settings › General › System Manager › Time), then try again. CouchSubs gets a new certificate, so you sign in to Samsung once more.")
        case .tvClockWrong where brand == .lg:
            String(localized: "The TV's date and time are wrong, so it rejected the TV app package (ipk verified failed). On the TV, open Settings › General › System › Time & Timer › Time, turn off Set Automatically, enter today's date and time, then restart the TV and try again.")
        case .tvClockWrong:
            String(localized: "The TV's clock is behind, so the new certificate is not valid for it yet. Set the TV's date and time (Settings › General › System Manager › Time) or wait a few minutes, then try again.")
        case .packageBlocked:
            String(localized: "The TV refuses CouchSubs because an earlier CouchSubs is still registered on it (Tizen error 118, -22), even if it no longer appears among the apps. If CouchSubs is among the TV's apps, delete it there and try again. Otherwise reset Smart Hub (Settings › Support › Device Care › Self Diagnosis › Reset Smart Hub; menu names differ a little by model) and try again. Resetting Smart Hub also removes the other apps you downloaded.")
        case .connectionLost:
            String(localized: "The connection to the TV dropped during the install. Keep the TV on and on the same network as this computer, then try again.")
        case .foreignApp:
            String(localized: "Another app on this TV is using the CouchSubs identity. Remove it and install CouchSubs?")
        }
    }
}
