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

/// Microsoft girişi: düğmeye basınca kod alınır, panoya kopyalanır ve microsoft.com/link tarayıcıda açılır; kullanıcı
/// kodu onaylayınca giriş kendiliğinden biter. Microsoft'un giriş sayfası uygulamanın içinde açılmaz.
struct XboxLoginStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var code: XboxDeviceCode?
    @State private var working = false
    @State private var finished = false
    @State private var copied = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        StepLayout(title: "Sign in with your Microsoft account",
                   message: "Link your Xbox account with a Microsoft device code, as in Greenlight. The sign-in page opens in your default browser.") {
            VStack(alignment: .leading, spacing: Theme.space("m")) {
                Pill(text: "Beta")
                if model.xboxSignedIn && code == nil {
                    DoneLabel(text: String(localized: "Signed in"))
                }
                Button("Sign in with Microsoft") { begin() }
                    .buttonStyle(CSButtonStyle(kind: model.xboxSignedIn ? .secondary : .primary))
                    .disabled(working)
                if let code {
                    Card {
                        Text("Your code (click to copy):").font(.csCallout).foregroundStyle(Color.csSecondary)
                        Button { copy(code) } label: {
                            Text(verbatim: code.userCode).font(.csCode).foregroundStyle(Color.csAccentText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Copy the code"))
                        Button { open(code) } label: {
                            Text(verbatim: code.verificationURI.replacingOccurrences(of: "https://", with: ""))
                                .font(.csBody.weight(.semibold)).foregroundStyle(Color.csAccentText).underline()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Open the Microsoft page"))
                        HintText(text: "1. The code is copied and microsoft.com/link is open in your browser. If it didn't open, click the link above.\n2. Paste the code, sign in with the Microsoft account you use on your Xbox and allow access.\n3. Come back to CouchSubs; sign-in finishes on its own.")
                        if copied { Text("Code copied").font(.csCallout).foregroundStyle(Color.csSuccess) }
                    }
                }
                if working {
                    HStack(spacing: Theme.space("m")) {
                        ProgressView().controlSize(.small)
                        HintText(text: code == nil ? "Opening the Microsoft sign-in page…" : "Waiting for the sign-in to finish…")
                    }
                } else if finished {
                    DoneLabel(text: String(localized: "Microsoft sign-in is done. You can continue."))
                }
                ErrorText(error: error).textSelection(.enabled)
                if error != nil {
                    HintText(text: "Sign-in did not finish. You can try again.")
                    Button("Show log file") { showXboxLogFile() }.buttonStyle(.secondary)
                }
                // #853: oyun bu bilgisayardaki Xbox uygulamasında / play.xbox.com'da (ya da capture card ile OBS'te)
                // oynanıyorsa CouchSubs Xbox'a bağlanmaz, yalnız seçilen pencereyi okur; Microsoft girişi atlanır.
                Card {
                    HStack {
                        Text("Playing with the Xbox app or play.xbox.com on this computer?").font(.csBody.weight(.semibold))
                        Spacer()
                        Button("Select") {
                            task?.cancel()
                            model.useXboxWindow()
                        }
                        .buttonStyle(.secondary)
                    }
                    HintText(text: "CouchSubs reads only the window you select in Settings › Picture source (the Xbox app, play.xbox.com or OBS with a capture card). It doesn't connect to the Xbox, so no Microsoft sign-in is needed and your Xbox session isn't interrupted.")
                }
            }
        }
        .onDisappear { task?.cancel() }
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

/// Xbox seçimi: hesaptaki Xbox'lar listelenir; uzak özellikleri kapalı olan seçilemez ve nedeni yazılır.
struct XboxConsoleStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var consoles: [XboxConsole]?
    @State private var selected: String?
    @State private var error: String?
    @State private var needsSignIn = false

    var body: some View {
        StepLayout(title: "Choose your home Xbox",
                   message: "Your Xbox must be on and on the same network as this computer. Turn on remote play in the Xbox settings.") {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                if let console = model.xboxConsole {
                    DoneLabel(text: Self.displayName(of: console))
                }
                Card {
                    HStack {
                        Text(verbatim: "Xbox").font(.csHeadline)
                        Pill(text: "Beta")
                        if consoles == nil { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Find consoles") { Task { await load() } }.buttonStyle(.secondary).disabled(consoles == nil)
                    }
                    if let consoles {
                        if consoles.isEmpty && error == nil {
                            HintText(text: "No Xbox found on this account. Sign in on your Xbox with the same account and turn on remote features.")
                        } else if !consoles.isEmpty {
                            HintText(text: "Choose the console to use:")
                            ForEach(consoles) { console in row(console) }
                        }
                    } else {
                        HintText(text: "Searching for Xbox consoles…")
                    }
                }
                HintText(text: "The Xboxes on your account. On the Xbox, turn on Settings › Devices & connections › Remote features.")
                ErrorText(error: error).textSelection(.enabled)
                if error != nil {
                    HStack(spacing: Theme.space("m")) {
                        if needsSignIn {
                            Button("Sign in with Microsoft") { model.back() }.buttonStyle(.primary)
                        }
                        Button("Show log file") { showXboxLogFile() }.buttonStyle(.secondary)
                    }
                }
            }
        }
        .task { await load() }
    }

    private static func displayName(of console: XboxConsole) -> String {
        console.name.isEmpty ? (console.model.isEmpty ? "Xbox" : console.model) : console.name
    }

    private func row(_ console: XboxConsole) -> some View {
        let chosen = selected == console.id
        return Button {
            guard console.streamingEnabled else { return }
            selected = console.id
            model.chooseXbox(console)
        } label: {
            HStack(spacing: Theme.space("m")) {
                Image(systemName: console.streamingEnabled ? (chosen ? "largecircle.fill.circle" : "circle") : "exclamationmark.triangle.fill")
                    .foregroundStyle(console.streamingEnabled ? (chosen ? Color.csAccentText : Color.csSecondary) : Color.csWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.space("xs")) {
                    Text(verbatim: console.model.isEmpty || console.name.isEmpty ? Self.displayName(of: console) : "\(console.name) (\(console.model))")
                        .font(.csBody.weight(.semibold))
                    Text(console.streamingEnabled ? "Remote play on" : "Remote play off: turn on Remote features on the Xbox")
                        .font(.csCallout).foregroundStyle(Color.csSecondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!console.streamingEnabled)
        .accessibilityAddTraits(chosen ? .isSelected : [])
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

/// Ayarlar › Konsol: konsol türü; Xbox'ta bağlı Xbox, Microsoft hesabı ve bağlama/çıkış.
struct ConsoleSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Card {
            ConsolePicker()
            if model.isXbox {
                HintText(text: "Xbox support is in Beta. If something goes wrong, tell us and we'll fix it as soon as we can.")
                HStack {
                    Text("Xbox and connection")
                    Spacer()
                    if let console = model.xboxConsole {
                        Text(verbatim: console.name.isEmpty ? "Xbox" : console.name).foregroundStyle(Color.csSecondary)
                    }
                    Button(model.xboxSignedIn ? "Choose your Xbox" : "Sign in with Microsoft") {
                        model.linkXbox()
                        dismiss()
                    }
                    .buttonStyle(CSButtonStyle(kind: model.needsXboxLink ? .primary : .secondary))
                }
                if model.xboxSignedIn {
                    HStack {
                        Label(String(localized: "Signed in"), systemImage: "checkmark.circle.fill").foregroundStyle(Color.csSuccess)
                        Spacer()
                        Button("Sign out of Microsoft") { model.signOutXbox() }.buttonStyle(.secondary)
                    }
                }
            } else {
                HintText(text: "With Remote Play and a second PSN account.")
            }
        }
    }
}

/// Ayarlar › Görüntü kaynağı, Xbox seçiliyken (Windows'taki Xbox kartı): oyun sesi. Uzaktan oynatma sürerken Xbox sesi
/// istemciye verip TV'yi susturur; açıkken ses bu Mac'in ses çıkışından çalınır.
struct XboxSoundCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Card {
            SwitchRow(title: "Play Xbox sound on this computer", isOn: $model.settings.xboxAudioOnDevice)
            HintText(text: "While Xbox Remote Play is running, the Xbox mutes the TV and sends game sound only to this computer (an Xbox limitation). If you turn this off, the game has no sound. To hear it from the TV or speakers, set the sound output of this computer to them.")
        }
    }
}
