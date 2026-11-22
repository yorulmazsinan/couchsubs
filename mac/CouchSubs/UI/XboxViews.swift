// SPDX-License-Identifier: AGPL-3.0-only
// Xbox (Beta) ekranları: kurulumda Microsoft girişi (cihaz kodu) ve Xbox seçimi, Ayarlar'da konsol ve Xbox sesi.
// Akış ve metinler Windows'taki XboxLoginStep / XboxConsoleStep ile aynı (iPhone: UI/XboxScreens.swift).

import AppKit
import CouchSubsCore
import RemotePlay
import SwiftUI

/// Konsol türü seçimi (karşılama adımı ve Ayarlar › Konsol): PlayStation 5 ya da Xbox (Beta).
struct ConsolePicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Picker("Console", selection: Binding(get: { model.platform }, set: { model.choosePlatform($0) })) {
            Text(verbatim: "PlayStation 5").tag(ConsolePlatform.playstation)
            Text("Xbox Series / Xbox One (Beta)").tag(ConsolePlatform.xbox)
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
        .font(.csBody)
    }
}

/// Günlük dosyasını (remoteplay.log; Xbox satırları da orada) Finder'da seçili açar.
private func showXboxLogFile() {
    let file = RemotePlayLog.defaultFile
    if FileManager.default.fileExists(atPath: file.path) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    } else {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

/// Microsoft girişi (tuval 15): solda "XBOX · MICROSOFT HESABI" kartı (durum başlığı, açıklama, kod ve Kodu Kopyala,
/// tek ana düğme, Baştan); sağda ses ve "Bu Bilgisayarda Xbox Uygulaması ile mi Oynuyorsunuz?". Düğmeye basınca kod alınır,
/// panoya kopyalanır ve microsoft.com/link tarayıcıda açılır; kullanıcı kodu onaylayınca giriş kendiliğinden biter.
struct XboxLoginStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var code: XboxDeviceCode?
    @State private var working = false
    @State private var finished = false
    @State private var copied = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard(scrolls: false) {
                DSCardHeader("XBOX · MICROSOFT ACCOUNT")
                Text(title).font(.dsH2).fixedSize(horizontal: false, vertical: true)
                Text(text).dsMuted(.system(size: 14))
                if let code {
                    HStack(spacing: DS.space("s")) {
                        Text(verbatim: code.userCode)
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .tracking(3.4)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.radius("tile")))
                            .textSelection(.enabled)
                        if copied {
                            DSSuccessBadge(text: "Copied")
                        } else {
                            Button("Copy the Code") { copy(code) }.buttonStyle(.dsSecondary)
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 12)))
                    Text("1. The code is copied and microsoft.com/link is open in your browser. If it didn't open, click the link above.\n2. Paste the code, sign in with the Microsoft account you use on your Xbox and allow access.\n3. Come back to CouchSubs; sign-in finishes on its own.").dsMuted()
                }
                if let error {
                    Text(verbatim: error).font(.dsSmall).foregroundStyle(Color.dsLive).textSelection(.enabled)
                    Text("Sign-in did not finish. You can try again.").dsMuted()
                }
                Spacer(minLength: DS.space("s"))
                HStack(spacing: DS.space("xs")) {
                    if finished || (model.xboxSignedIn && code == nil && !working) {
                        Button("Find Consoles") { model.advance() }.buttonStyle(.dsPrimary)
                    } else if let code {
                        Button("Open the Microsoft Page") { open(code) }.buttonStyle(.dsPrimary)
                    } else {
                        Button(working ? "Opening the Microsoft sign-in page…" : "Sign In with Microsoft") { begin() }
                            .buttonStyle(.dsPrimary)
                            .disabled(working)
                    }
                    Button("Start Over") {
                        task?.cancel()
                        code = nil
                        error = nil
                        finished = false
                        working = false
                        copied = false
                    }
                    .buttonStyle(.dsSecondary)
                    if error != nil { Button("Show Log File") { showXboxLogFile() }.buttonStyle(.dsSecondary) }
                }
            }
            .frame(maxWidth: .infinity)
            XboxSideColumn {
                task?.cancel()
                model.useXboxWindow()
            }
            .frame(maxWidth: .infinity)
        }
        .animation(DS.enter(400), value: code?.userCode)
        .onDisappear { task?.cancel() }
    }

    private var title: LocalizedStringKey {
        if finished || (model.xboxSignedIn && code == nil && !working) { return "Searching for Xbox Consoles…" }
        return code == nil ? "Sign In with Your Microsoft Account" : "Enter the Code on the Microsoft Page"
    }

    private var text: LocalizedStringKey {
        if finished || (model.xboxSignedIn && code == nil && !working) { return "Microsoft sign-in is done. Getting the consoles on this account." }
        return code == nil ? "Link your Xbox account with a Microsoft device code. The sign-in page opens in your default browser."
            : "Copy the code, paste it on the Microsoft page that opens and finish signing in."
    }

    private func copy(_ code: XboxDeviceCode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.userCode, forType: .string)
        copied = true
    }

    private func open(_ code: XboxDeviceCode) {
        copy(code)
        if let url = URL(string: code.verificationURI) { model.openInBrowser(url) }
    }

    private func begin() {
        task?.cancel()
        error = nil
        finished = false
        code = nil
        working = true
        task = Task {
            defer { working = false }
            do {
                let challenge = try await model.beginXboxLogin()
                code = challenge
                open(challenge)
                try await model.completeXboxLogin(challenge)
                code = nil
                finished = true
            } catch is CancellationError {
            } catch let failure as XboxError {
                error = String(format: String(localized: "Couldn't sign in: %@"), XboxText.problem(failure))
                code = nil
            } catch {
                self.error = String(format: String(localized: "Couldn't sign in: %@"), error.localizedDescription)
                code = nil
            }
        }
    }
}

/// Xbox sayfalarının sağ sütunu: ses anahtarı ve "Bu bilgisayarda Xbox uygulaması/play.xbox.com ile mi oynuyorsunuz?" (#853;
/// pencere okunur, Microsoft girişi gerekmez), altta marka notu.
private struct XboxSideColumn: View {
    @EnvironmentObject private var model: AppModel
    let chooseWindow: () -> Void

    var body: some View {
        VStack(spacing: DS.space("l")) {
            DSCard(spacing: DS.space("xs"), scrolls: false) {
                DSCardHeader("SOUND")
                DSSwitchRow(title: "Play Xbox Sound on This Computer", subtitle: "When off, sound comes only from the TV.",
                            isOn: $model.settings.xboxAudioOnDevice, divider: false)
            }
            DSCard(scrolls: false) {
                Text("Playing with the Xbox App or play.xbox.com on This Computer?").font(.dsH3).fixedSize(horizontal: false, vertical: true)
                Text("Then you don't need to sign in with Microsoft; just choose the game window.").dsMuted()
                Button("Choose the Game Window") { chooseWindow() }.buttonStyle(.dsSecondary)
                Spacer(minLength: DS.space("s"))
                Text("CouchSubs is not affiliated with Microsoft. Xbox is a trademark of Microsoft Corporation.").dsMuted()
            }
        }
    }
}

/// Xbox seçimi (tuval 15, son durum): hesaptaki Xbox'lar seçenek kartlarında, uzak özellikleri kapalı olan seçilemez.
struct XboxConsoleStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var consoles: [XboxConsole]?
    @State private var selected: String?
    @State private var error: String?
    @State private var needsSignIn = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.space("l")) {
            DSCard(spacing: DS.space("xs"), scrolls: false) {
                DSCardHeader("XBOX · MICROSOFT ACCOUNT") {
                    Button(consoles == nil ? "Searching…" : "Find Consoles") { Task { await load() } }
                        .buttonStyle(.dsSecondary)
                        .disabled(consoles == nil)
                }
                Text(consoles == nil ? "Searching for Xbox Consoles…" : "Choose Your Xbox at Home").font(.dsH2)
                Text(consoles == nil ? "Microsoft sign-in is done. Getting the consoles on this account." : "Choose the console to use.")
                    .dsMuted(.system(size: 14))
                    .padding(.bottom, DS.space("xs"))
                if let consoles {
                    if consoles.isEmpty && error == nil {
                        Text("No Xbox found on this account. Sign in on your Xbox with the same account and turn on remote features.").dsMuted()
                    }
                    ForEach(Array(consoles.enumerated()), id: \.element.id) { index, console in
                        row(console)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                Text("The Xboxes on your account. On the Xbox, turn on Settings › Devices & connections › Remote features.").dsMuted()
                if let error {
                    Text(verbatim: error).font(.dsSmall).foregroundStyle(Color.dsLive).textSelection(.enabled)
                    HStack(spacing: DS.space("xs")) {
                        if needsSignIn { Button("Sign In with Microsoft") { model.back() }.buttonStyle(.dsPrimary) }
                        Button("Show Log File") { showXboxLogFile() }.buttonStyle(.dsSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            XboxSideColumn { model.useXboxWindow() }.frame(maxWidth: .infinity)
        }
        .animation(DS.enter(400), value: consoles?.map(\.id))
        .task { await load() }
    }

    private static func displayName(of console: XboxConsole) -> String {
        console.name.isEmpty ? (console.model.isEmpty ? "Xbox" : console.model) : console.name
    }

    private func row(_ console: XboxConsole) -> some View {
        Button {
            guard console.streamingEnabled else { return }
            selected = console.id
            model.chooseXbox(console)
        } label: {
            HStack(spacing: DS.space("m")) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.displayName(of: console)).font(.dsBodyStrong)
                    Text(verbatim: console.model.isEmpty ? "Xbox" : console.model).font(.dsSmall).foregroundStyle(Color.dsMuted)
                }
                Spacer()
                DSBadge(text: console.streamingEnabled ? "Remote Play On" : "Remote Features Off", tone: console.streamingEnabled ? .ok : .warn)
            }
        }
        .buttonStyle(DSOptionStyle(selected: selected == console.id))
        .disabled(!console.streamingEnabled)
    }

    private func load() async {
        consoles = nil
        error = nil
        needsSignIn = false
        selected = selected ?? model.xboxConsole?.id
        do {
            let list = try await model.discoverXboxConsoles()
            consoles = list
            // Tek seçilebilir Xbox varsa ya da hiç seçilmemişse ilki seçilir (iPhone'daki gibi).
            if selected == nil || !list.contains(where: { $0.id == selected && $0.streamingEnabled }),
               let first = list.first(where: \.streamingEnabled) {
                selected = first.id
                model.chooseXbox(first)
            }
        } catch let failure as XboxError {
            needsSignIn = failure.kind == .signInRequired
            error = String(localized: "Couldn't get the consoles.") + " " + XboxText.problem(failure)
            consoles = []
        } catch {
            self.error = String(localized: "Couldn't get the consoles.") + " " + error.localizedDescription
            consoles = []
        }
    }
}

/// Ayarlar › Konsol ve Kaynak › KONSOL: PlayStation 5 / Xbox sekmeleri; PS5'te eşleşen PS5 ve ikinci hesap, Xbox'ta bağlı
/// Xbox ve Microsoft hesabı.
struct ConsoleSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        DSCard(scrolls: false) {
            DSCardHeader("CONSOLE")
            DSTabs(selection: Binding(get: { model.platform }, set: { model.choosePlatform($0) }),
                   items: [(ConsolePlatform.playstation, LocalizedStringKey("PlayStation 5")), (ConsolePlatform.xbox, LocalizedStringKey("Xbox"))])
            if model.isXbox {
                DSRow(title: LocalizedStringKey(model.xboxConsole.map { $0.name.isEmpty ? "Xbox" : $0.name } ?? "Xbox"),
                      subtitle: model.xboxSignedIn ? "Signed in" : "Xbox support is in Beta. If something goes wrong, tell us and we'll fix it as soon as we can.",
                      divider: false) {
                    DSBadge(text: model.needsXboxLink ? "Not Connected" : "Connected", tone: model.needsXboxLink ? .unknown : .ok)
                }
                HStack(spacing: DS.space("xs")) {
                    Button(model.xboxSignedIn ? "Choose Your Xbox at Home" : "Link Xbox Account") { model.linkXbox() }
                        .buttonStyle(model.needsXboxLink ? .dsPrimary : .dsSecondary)
                    if model.xboxSignedIn { Button("Sign out of Microsoft") { model.signOutXbox() }.buttonStyle(.dsSecondary) }
                }
            } else {
                DSRow(title: LocalizedStringKey(model.console.map { $0.name.isEmpty ? "PS5" : $0.name } ?? "PS5"),
                      subtitle: model.console.map { LocalizedStringKey($0.host) } ?? "With Remote Play and a second PSN account.",
                      divider: false) {
                    DSBadge(text: model.console == nil ? "Not Set Up" : "Connected", tone: model.console == nil ? .unknown : .ok)
                }
            }
        }
    }
}

/// Ayarlar › Konsol ve Kaynak, Xbox seçiliyken: oyun sesi. Uzaktan oynatma sürerken Xbox sesi istemciye verip TV'yi
/// susturur; açıkken ses bu Mac'in ses çıkışından çalınır.
struct XboxSoundCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space("xs")) {
            DSSwitchRow(title: "Play Xbox Sound on This Computer", isOn: $model.settings.xboxAudioOnDevice, divider: false)
            Text("While Xbox Remote Play is running, the Xbox mutes the TV and sends game sound only to this computer (an Xbox limitation). If you turn this off, the game has no sound. To hear it from the TV or speakers, set the sound output of this computer to them.").dsMuted()
        }
    }
}
