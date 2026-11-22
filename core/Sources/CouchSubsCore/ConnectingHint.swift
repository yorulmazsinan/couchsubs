// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// PS5 bağlantısı 30 sn'den uzun "Bağlanıyor…"da kalınca durum satırının altında nedeni söylenir: PS5 uyandırılıyor,
/// PS5 aramaya yanıt vermiyor (açık mı, aynı ağda mı) ya da yanıt verdi ama oturum açılmıyor. Eskiden yalnız
/// "Bağlanıyor…" görünüyor, kullanıcı ne beklediğini bilmiyordu. Windows (CouchSubs.Core/ConnectingHint.cs) ve Android
/// (core/ConnectingHint.kt) aynı kural ve metinler.
public enum ConnectingHint {
    /// Oturumun bağlanırken son bildirdiği adım (RemotePlay `ConnectStep` ile aynı adlar).
    public enum Step: String, Sendable {
        /// PS5 kayıtlı adreste ve ağda aramaya yanıt vermedi; yine de bağlanılıyor.
        case noAnswer
        /// PS5 dinlenmedeydi; uyandırma gönderildi, uyanması bekleniyor.
        case waking
        /// PS5 yanıt verdi; oturum açılıyor.
        case opening
    }

    /// Bu süreden sonra neden gösterilir (sn).
    public static let after: TimeInterval = 30

    /// `seconds` sn'dir bağlanılıyorsa gösterilecek neden; daha kısa sürdüyse nil.
    public static func text(seconds: TimeInterval, step: Step?) -> String? {
        guard seconds >= after else { return nil }
        switch step {
        case .waking:
            return String(localized: "The PS5 is being woken from rest mode. This can take up to a minute.")
        case .opening:
            return String(localized: "The PS5 answered, but the connection is taking long. If it doesn't connect, stop and start translating again.")
        case .noAnswer, nil:
            return String(localized: "The PS5 is not answering. Make sure it is on and on the same network as this device.")
        }
    }
}
