// SPDX-License-Identifier: AGPL-3.0-only

import RemotePlay
import SwiftUI

struct ConsoleStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var consoles: [ConsoleInfo] = []
    @State private var selected: String?
    @State private var manualHost = ""
    @State private var pin = ""
    @State private var searching = false
    @State private var working = false
    @State private var error: String?
    /// Bu ekranda eşleşme az önce başarıyla bitti; kod değişene dek Bağlan kapalı, ileti düğmenin altında.
    @State private var paired = false
    @Environment(\.scrollOnboardingTo) private var scrollTo

    private static let pairedAnchor = "paired"

    private var host: String { selected ?? manualHost.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        StepLayout(title: "Connect your PS5",
                   message: "Turn on the PS5. As the second user, open Settings › System › Remote Play › Pair Device and enter the 8-digit code shown there.") {
            VStack(alignment: .leading, spacing: Theme.space("l")) {
                if let console = model.console {
                    DoneLabel(text: Self.displayName(of: console))
                }
                Card {
                HStack {
                    Text(verbatim: "PS5").font(.csHeadline)
                    if searching { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Search again") { Task { await search() } }.buttonStyle(.secondary).disabled(searching)
                }
                if consoles.isEmpty && !searching {
                    HintText(text: "No PS5 found. Make sure it is on and on the same network, or enter its IP address. CouchSubs must also be allowed in System Settings › Privacy & Security › Local Network.")
                    TextField("IP address, e.g. 192.168.1.20", text: $manualHost)
                        .textFieldStyle(CSTextFieldStyle())
                        .onSubmit { Task { await register() } }
                } else {
                    Picker("PS5", selection: $selected) {
                        ForEach(consoles, id: \.host) { Text(verbatim: "\($0.name) — \($0.host)").tag(Optional($0.host)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .font(.csBody)
                }
                }
                VStack(alignment: .leading, spacing: Theme.space("s")) {
                    Text("8-digit code").font(.csCallout).foregroundStyle(Color.csSecondary)
                    // Kod yazılıp Return'e basılınca bağlanılır (eskiden Return, kapalı "Devam"a gidip hiçbir şey yapmıyordu).
                    // Yeni kod yazılınca Bağlan yeniden açılır (onChange macOS 13'te farklı olduğu için bağlamada).
                    TextField("", text: Binding(get: { pin }, set: { value in
                        pin = value
                        if !value.isEmpty { paired = false }
                    }))
                        .textFieldStyle(CSTextFieldStyle(font: .csCode, height: 52))
                        .frame(maxWidth: 240)
                        .onSubmit { Task { await register() } }
                }
                HStack(spacing: Theme.space("m")) {
                    // Düğme çalışırken ve eşleşmeden sonra (kod değişene dek) kapalı; eksik kod ya da adres tıklanınca
                    // açıkça söylenir.
                    Button("Connect") { Task { await register() } }
                        .buttonStyle(.primary)
                        .disabled(working || paired)
                    if working {
                        ProgressView().controlSize(.small)
                        HintText(text: "Connecting to the PS5… This can take up to 30 seconds.")
                    }
                }
                // Eşleşme başarılı: düğmenin hemen altında yeşil ileti (üstteki ad kaydırınca görünmüyordu).
                if paired, let console = model.console {
                    DoneLabel(text: String(localized: "PS5 paired: \(Self.displayName(of: console)) (\(console.host)). Press Continue."))
                        .id(Self.pairedAnchor)
                }
                ErrorText(error: error).textSelection(.enabled)
                if error != nil {
                    // Eşleştirme olmazsa gönderilecek remoteplay.log Finder'da seçili açılır.
                    Button("Show log file") { showLogFile() }.buttonStyle(.secondary)
                }
            }
        }
        .task { await search() }
    }

    /// PS5 adını göndermezse yine de başarı görünsün.
    private static func displayName(of console: RegisteredConsole) -> String {
        console.name.isEmpty ? "PS5" : console.name
    }

    private func showLogFile() {
        let file = RemotePlayLog.defaultFile
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            let folder = file.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    private func search() async {
        searching = true
        consoles = await model.discoverConsoles()
        if selected == nil { selected = consoles.first?.host }
        searching = false
    }

    /// Eşleşince düğmenin altında yeşil ileti çıkar (kaydırılmış olsa da görünür), kod alanı temizlenir ve ~1 sn sonra
    /// sonraki adıma geçilir. Hata davranışı aynı.
    private func register() async {
        guard !working, !paired else { return }
        working = true
        error = nil
        do {
            try await model.register(host: host, pin: pin)
            paired = true
            pin = ""
        } catch {
            self.error = error.localizedDescription
        }
        working = false
        guard paired else { return }
        // İleti çizildikten sonra kaydırılır.
        try? await Task.sleep(for: .milliseconds(50))
        scrollTo(Self.pairedAnchor)
        try? await Task.sleep(for: .seconds(1))
        // Kullanıcı bu arada Geri'ye bastıysa model ilerlemez (yalnız PS5 adımından geçer).
        model.continueAfterPairing()
    }
}
