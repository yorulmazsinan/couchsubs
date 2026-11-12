// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

/// PS5 kaydı, PSN hesap kimliği ve TV anahtarı Anahtarlık'ta saklanır.
public enum SecureStore {
    /// Anahtarlık hizmet adı: Mac ve iPhone/iPad uygulamaları kendi kayıtlarını tutar.
    #if os(macOS)
    private static let service = "com.couchsubs.mac"
    #else
    private static let service = "com.couchsubs.ios"
    #endif

    public static func save<T: Encodable>(_ value: T, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key,
                                      kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func remove(_ key: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary)
    }
}
