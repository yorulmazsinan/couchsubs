// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Paket sunucusunun adresleri: birincil (workers.dev) ve yedekler (couchsubs-packs.enmeraapps.com, aynı Worker). Bazı ağlar
/// (DNS, reklam engelleyici, operatör) *.workers.dev'e ulaşamıyor (#583). Her istek son çalışan adresten başlar; ağ hatası,
/// zaman aşımı ya da 5xx olursa sıradaki denenir. 4xx (404, 429) sunucunun gerçek cevabıdır, başka adres denenmez. Çalışan
/// adres bu nesne yaşadıkça (uygulama açıkken) hatırlanır; o da düşerse sıra yeniden baştan dolaşılır.
///
/// Mac (`PackUpdater`) ve iPhone/iPad (uygulamadaki `PackStore`) ikisi de bunu kullanır; Windows'ta PackUpdater.cs,
/// Android'de HttpPackServer aynı kurallarla çalışır.
public final class PackMirrors: @unchecked Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public enum Failure: Error, Equatable, Sendable {
        /// Ağ hatası ya da zaman aşımı.
        case network
        /// HTTP yanıtı değil.
        case badResponse
        case status(Int)

        /// Başka adres denenmeli mi?
        public var retryable: Bool {
            switch self {
            case .network: return true
            case .badResponse: return false
            case let .status(code): return code >= 500
            }
        }
    }

    public let urls: [URL]
    private let lock = NSLock()
    private var preferred = 0

    /// Aynı adres bir kez; sıra korunur.
    public init(_ urls: [URL]) {
        var seen = Set<String>()
        self.urls = urls.filter { seen.insert($0.absoluteString.trimmingSuffix("/")).inserted }
    }

    public convenience init(primary: URL, fallbacks: [URL] = []) {
        self.init([primary] + fallbacks)
    }

    /// Son başarılı adresin sırası.
    public var preferredIndex: Int { lock.withLock { preferred } }

    /// `path` (ör. "v1/packs") her adreste sırayla, son çalışandan başlayarak istenir; 2xx gövdesi ya da son hata döner.
    /// `cachePolicy`: liste için `.reloadIgnoringLocalCacheData` verilir. Sunucu listeyi `max-age=300` ile gönderiyor;
    /// varsayılan önbellek kuralıyla "Paketleri şimdi güncelle" son beş dakikada alınmış eski listeyi diskten okuyor, yeni
    /// çıkan sürümü görmüyordu.
    public func get(_ path: String, timeout: TimeInterval, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
                    fetch: Fetch) async -> Result<Data, Failure> {
        guard !urls.isEmpty else { return .failure(.network) }
        let start = min(preferredIndex, urls.count - 1)
        var last = Failure.network
        for step in 0..<urls.count {
            let index = (start + step) % urls.count
            var request = URLRequest(url: urls[index].appendingPathComponent(path), cachePolicy: cachePolicy,
                                     timeoutInterval: timeout)
            request.httpMethod = "GET"
            let outcome: Result<Data, Failure>
            do {
                let (data, response) = try await fetch(request)
                if let http = response as? HTTPURLResponse {
                    outcome = (200..<300).contains(http.statusCode) ? .success(data) : .failure(.status(http.statusCode))
                } else {
                    outcome = .failure(.badResponse)
                }
            } catch {
                outcome = .failure(.network)
            }
            switch outcome {
            case .success:
                lock.withLock { preferred = index }
                return outcome
            case let .failure(failure):
                if !failure.retryable { return outcome }
                last = failure
            }
        }
        return .failure(last)
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var value = self
        while value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        return value
    }
}
