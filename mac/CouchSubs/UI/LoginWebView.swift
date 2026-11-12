// SPDX-License-Identifier: AGPL-3.0-only

import RemotePlay
import SwiftUI
import WebKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Sony'nin giriş sayfası; giriş bitince yönlendirme adresini yakalar. Mac ve iPhone/iPad uygulamaları ortak kullanır.
struct LoginWebView: PlatformViewRepresentable {
    let onRedirect: (URL) -> Void
    let onProblem: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onRedirect: onRedirect, onProblem: onProblem) }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #endif

    private func makeWebView(_ context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: PSNAccount.authorizeURL))
        return view
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onRedirect: (URL) -> Void
        let onProblem: (String?) -> Void
        private var redirected = false

        init(onRedirect: @escaping (URL) -> Void, onProblem: @escaping (String?) -> Void) {
            self.onRedirect = onRedirect
            self.onProblem = onProblem
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Kodlu ya da Sony'nin hatasını taşıyan her yönlendirme yakalanır; eskiden hatalı yönlendirme boş sayfada kalıyordu.
            if let url = action.request.url, !redirected,
               PSNAccount.code(fromRedirect: url) != nil || PSNAccount.error(fromRedirect: url) != nil {
                redirected = true
                onRedirect(url)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse {
                if http.statusCode >= 400 {
                    RemotePlayLog.write("PSN giriş sayfası: HTTP \(http.statusCode)")
                    onProblem("HTTP \(http.statusCode)")
                } else {
                    onProblem(nil)
                }
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            // Yönlendirmeyi kendimiz iptal ediyoruz; o bir sorun değildir.
            let nsError = error as NSError
            let canceled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
            // WebKitErrorFrameLoadInterruptedByPolicyChange: yönlendirmeyi iptal etmemiz.
            let interrupted = nsError.domain == "WebKitErrorDomain" && nsError.code == 102
            if redirected || canceled || interrupted { return }
            RemotePlayLog.write("PSN giriş sayfası açılamadı: \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
            onProblem(nsError.localizedDescription)
        }
    }
}
