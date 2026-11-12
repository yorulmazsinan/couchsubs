// SPDX-License-Identifier: AGPL-3.0-only

import RemotePlay
import SwiftUI
import WebKit

struct PSNLoginStep: View {
    @EnvironmentObject private var model: AppModel
    @State private var showLogin = false
    @State private var working = false
    @State private var error: String?
    /// Pencere yönlendirmeyi yakaladı mı; yakalamadan kapanırsa kullanıcıya söylenir (eskiden sessizdi).
    @State private var redirected = false
    /// Giriş sayfasının son sorunu (açılamadı, Sony'nin HTTP hatası).
    @State private var pageProblem: String?
    @State private var showManual = false
    @State private var manualId = ""
    @State private var manualError: String?

    var body: some View {
        StepLayout(title: "Sign in with the second account",
                   message: "Sign in to PlayStation Network with the second account you just created. Your password goes directly to Sony; CouchSubs only keeps the account ID.") {
            VStack(alignment: .leading, spacing: Theme.space("m")) {
                if model.accountId != nil {
                    DoneLabel(text: String(localized: "Signed in"))
                }
                Button(model.accountId == nil ? "Sign in" : "Sign in again") {
                    redirected = false
                    pageProblem = nil
                    showLogin = true
                }
                .buttonStyle(CSButtonStyle(kind: model.accountId == nil ? .primary : .secondary))
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
                ErrorText(error: error).textSelection(.enabled)
                manualEntry.padding(.top, Theme.space("s"))
            }
        }
        .sheet(isPresented: $showLogin, onDismiss: sheetClosed) {
            PSNLoginSheet(onRedirect: received, onProblem: { pageProblem = $0 })
        }
    }

    /// Sony girişi açılmıyorsa (ör. servis sağlayıcı engelliyor) hesap kimliği elle yazılır.
    @ViewBuilder private var manualEntry: some View {
        if showManual {
            VStack(alignment: .leading, spacing: Theme.space("s")) {
                HintText(text: "If Sony's sign-in page does not open (some internet providers block it), enter the second account's PSN account ID in base64 (12 characters, e.g. AbCdEfGhIjk=).")
                HStack(spacing: Theme.space("m")) {
                    TextField("", text: $manualId)
                        .textFieldStyle(CSTextFieldStyle())
                        .frame(maxWidth: 240)
                        .onSubmit(saveManual)
                    Button("Save", action: saveManual).buttonStyle(.primary)
                }
                ErrorText(error: manualError)
            }
        } else {
            Button("Enter account ID manually") { showManual = true }.buttonStyle(.secondary)
        }
    }

    private func saveManual() {
        if model.useManualAccountId(manualId) {
            manualError = nil
            error = nil
        } else {
            manualError = String(localized: "This is not a valid account ID. It is 12 characters in base64, e.g. AbCdEfGhIjk=.")
        }
    }

    /// Pencere yönlendirmesiz kapandıysa nedeni söylenir (eskiden sessizce dönülüyordu).
    private func sheetClosed() {
        guard !redirected else { return }
        let failure: Error = model.loginWindowError(problem: pageProblem)
        error = failure.localizedDescription
    }

    private func received(_ url: URL) {
        redirected = true
        showLogin = false
        working = true
        error = nil
        Task {
            do { try await model.completePSNLogin(redirect: url) } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

/// Sony'nin giriş sayfasını açar; giriş bitince yönlendirme adresini yakalar.
struct PSNLoginSheet: View {
    let onRedirect: (URL) -> Void
    /// Sayfa açılamadı ya da Sony hata kodu döndürdü (nil: sorun giderildi).
    let onProblem: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "PlayStation Network").font(.csHeadline)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.secondary)
            }
            .padding(Theme.space("m"))
            Divider()
            LoginWebView(onRedirect: onRedirect, onProblem: onProblem)
        }
        .frame(width: 520, height: 680)
    }
}
