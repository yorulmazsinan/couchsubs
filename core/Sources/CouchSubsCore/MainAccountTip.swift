// SPDX-License-Identifier: AGPL-3.0-only

/// Çeviri ekranındaki "kolu açınca PS5'te ana hesabınızı seçin" ipucu ne zaman görünür (iPhone ve Mac; Android'de
/// MainAccountTip.kt, Windows'ta AppController.MainAccountTipVisible ile aynı kural).
///
/// CouchSubs PS5'e ikinci hesapla Uzaktan Oynatma açar. Fiziksel kol da o ikinci hesaba atanmışsa PS5 her bağlanışta o
/// hesabın kolunu Uzaktan Oynatma'ya devreder ve DualSense'i kapatır; oyuncu kolu açıp yine ikinci hesabı seçince PS5
/// Uzaktan Oynatma'yı keser, uygulama yeniden bağlanınca kol yine kapanır (Play yorumu 20 Kas, GitHub #231, #5). Eskiden
/// ipucu yalnız ilk altyazıdan önce görünüyordu; döngüdeki oyuncu ilk altyazıdan sonra onu hiç görmüyordu. Artık
/// bağlantı koptuğunda (yeniden bağlanırken) da görünür.
public enum MainAccountTip {
    /// `ps5`: görüntü PS5'ten geliyor (Xbox ya da pencere yakalama değil). `demo`: deneme modu. `hasSubtitle`: bu
    /// çeviride altyazı geldi. `streaming`: PS5 bağlantısı şu an kurulu.
    public static func isVisible(ps5: Bool, demo: Bool, hasSubtitle: Bool, streaming: Bool) -> Bool {
        ps5 && !demo && (!hasSubtitle || !streaming)
    }
}
