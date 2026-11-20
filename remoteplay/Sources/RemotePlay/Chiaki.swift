// SPDX-License-Identifier: AGPL-3.0-only

import CChiaki
import Foundation

/// libchiaki'nin günlüğünü uygulamanın günlüğüne ve remoteplay.log dosyasına yönlendirir (hata, uyarı, bilgi).
final class ChiakiLogger {
    let pointer: UnsafeMutablePointer<ChiakiLog>
    /// Her satır için çağrılır (libchiaki'nin iş parçacığında); `isError` hata düzeyindeki satırlarda doğrudur.
    var onMessage: ((_ text: String, _ isError: Bool) -> Void)?
    /// Satır yazılmadan önce sorulur (libchiaki'nin iş parçacığında); `false` dönerse satır günlüğe yazılmaz.
    /// `onMessage` yine çağrılır.
    var shouldWrite: ((_ text: String) -> Bool)?

    init() {
        pointer = .allocate(capacity: 1)
        let mask = UInt32(CHIAKI_LOG_ERROR.rawValue | CHIAKI_LOG_WARNING.rawValue | CHIAKI_LOG_INFO.rawValue)
        chiaki_log_init(pointer, mask, { level, message, user in
            guard let message else { return }
            let text = String(cString: message)
            let isError = level == CHIAKI_LOG_ERROR
            let name = isError ? "error" : level == CHIAKI_LOG_WARNING ? "warning" : "info"
            let owner = user.map { Unmanaged<ChiakiLogger>.fromOpaque($0).takeUnretainedValue() }
            if owner?.shouldWrite?(text) ?? true {
                print("[chiaki] \(text)")
                RemotePlayLog.write("[chiaki \(name)] \(text)")
            }
            owner?.onMessage?(text, isError)
        }, nil)
        // Günlük yapısı bu nesneyle birlikte yaşar; geri çağrıya sahibini sahiplenmeden ver.
        pointer.pointee.user = Unmanaged.passUnretained(self).toOpaque()
    }

    deinit { pointer.deallocate() }
}

extension ChiakiErrorCode {
    var isSuccess: Bool { self == CHIAKI_ERR_SUCCESS }
}

public struct ChiakiError: Error, CustomStringConvertible {
    public let code: ChiakiErrorCode
    public var description: String { String(cString: chiaki_error_string(code)) }
}

/// Swift `Data`'yı C dizisi demetine (tuple) kopyalar.
func copy<T>(_ data: Data, into tuple: inout T) {
    withUnsafeMutableBytes(of: &tuple) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        data.prefix(destination.count).withUnsafeBytes { destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0[...])) }
    }
}

/// C dizisi demetini `Data`'ya çevirir.
func data<T>(of tuple: T) -> Data {
    withUnsafeBytes(of: tuple) { Data($0) }
}

/// Sıfırla biten C dizgesi demetini `String`'e çevirir.
func string<T>(of tuple: T) -> String {
    let bytes = data(of: tuple)
    let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
    return String(decoding: bytes[..<end], as: UTF8.self)
}
