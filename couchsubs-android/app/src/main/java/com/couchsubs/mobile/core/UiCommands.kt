// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import java.util.Locale

/**
 * Oyun menülerindeki ve tuş çubuğundaki kısa komut ve etiketlerin Türkçesi ("OFF", "Map", "SELECT ✕"). Çeviri motoru bu
 * tek sözcükleri bağlamsız görünce yanlış anlıyordu ("OPEN" → "AÇIK"); sözlükteki etiket motora ve pakete gitmez,
 * anında çevrilir. Harf biçimi korunur: "OFF" → "KAPALI", "Off" → "Kapalı", "off" → "kapalı" (Türkçe kurallarla).
 * Sözlük Windows'taki UiCommands.cs ile aynıdır (GameTranslator'ın AGPL-3.0 UiPrompts sınıfından), menü terimleriyle
 * genişletildi.
 */
object UiCommands {
    private val turkish = Locale.forLanguageTag("tr")

    private val commands: Map<String, String> = mapOf(
        "ADD MARKER" to "İşaret ekle", "SET DESTINATION" to "Hedef belirle", "REMOVE DESTINATION" to "Hedefi kaldır",
        "RECENTER" to "Ortala", "2D VIEW" to "2B görünüm", "3D VIEW" to "3B görünüm", "ZOOM" to "Yakınlaştır",
        "EXIT" to "Çıkış", "BACK" to "Geri", "SELECT" to "Seç", "CLOSE" to "Kapat", "CLOSE MENU" to "Menüyü kapat",
        "MENU" to "Menü", "OPEN" to "Aç", "NEXT PAGE" to "Sonraki sayfa", "PREVIOUS PAGE" to "Önceki sayfa",
        "SHOW TEXT" to "Metni göster", "SHOW" to "Göster", "FLIP" to "Çevir", "PUT DOWN" to "Bırak", "PICK UP" to "Al",
        "DRINK" to "İç", "EAT" to "Ye", "WEAR" to "Giy", "TAKE OFF" to "Çıkar", "BUY" to "Satın al", "SELL" to "Sat",
        "PAY" to "Öde", "PAY LATER" to "Sonra öde", "PAY NOW" to "Şimdi öde", "ACCEPT" to "Kabul et",
        "DECLINE" to "Reddet", "YES" to "Evet", "NO" to "Hayır", "CONFIRM" to "Onayla", "CANCEL" to "İptal",
        "GOODBYE" to "Hoşça kal", "GREET" to "Selamla", "TALK" to "Konuş", "DEFUSE" to "Yatıştır",
        "PROVOKE" to "Kışkırt", "WARN" to "Uyar", "OFFER RIDE" to "Arabaya çağır", "ENTER" to "Gir",
        "LEAVE" to "Ayrıl", "SKIP" to "Geç", "CONTINUE" to "Devam et", "RETRY" to "Tekrar dene",
        "RESTORE ALL" to "Hepsini geri yükle", "RESTORE DEFAULT" to "Varsayılana döndür", "PREVIEW" to "Önizle",
        "PAUSE PREVIEW" to "Önizlemeyi durdur", "ADJUST" to "Ayarla", "SCROLL" to "Kaydır", "REFUEL" to "Yakıt al",
        "LIFT" to "Kaldır", "ORDER" to "Sipariş ver", "MAYBE LATER" to "Belki sonra", "PHOTO STUDIO" to "Fotoğraf stüdyosu",
        "REMINDERS" to "Hatırlatıcılar", "ROTATE" to "Döndür", "INTERACT" to "Etkileşim", "USE" to "Kullan",
        "KNOCK" to "Kapıyı çal", "CALL" to "Ara", "HANG UP" to "Telefonu kapat", "ANSWER" to "Cevapla",
        "IGNORE" to "Yoksay", "REPLY" to "Yanıtla", "DELETE" to "Sil", "SAVE" to "Kaydet", "VIEW" to "Görüntüle",
        "INSPECT" to "İncele", "SEARCH" to "Ara", "HIDE" to "Saklan", "JOIN" to "Katıl", "TERMS" to "Koşullar",
        "MARKERS" to "İşaretler", "DROP" to "Bırak", "EQUIP" to "Kuşan", "UNEQUIP" to "Çıkar", "STORE" to "Dükkân",
        "HELP" to "Yardım", "OPTIONS" to "Seçenekler", "CAMERA" to "Kamera", "TOGGLE" to "Aç / kapat", "GRAB" to "Tut",
        "SIT" to "Otur", "STAND UP" to "Kalk", "SLEEP" to "Uyu", "SHOWER" to "Duş al", "TURN OFF" to "Kapat",
        "TURN ON" to "Aç", "WATCH" to "İzle", "LISTEN" to "Dinle", "DRIVE" to "Sür", "GET IN" to "Bin",
        "GET OUT" to "İn", "STEAL" to "Çal", "HACK" to "Hackle", "LOOT" to "Yağmala", "COLLECT" to "Topla",
        // Menü terimleri (ekran yazısı menüleri: tekerlek menü, duraklatma menüsü, ayarlar).
        "ON" to "Açık", "OFF" to "Kapalı", "LOAD" to "Yükle", "SETTINGS" to "Ayarlar", "MAP" to "Harita",
        "RESUME" to "Sürdür", "QUIT" to "Çık", "NEXT" to "İleri", "PREVIOUS" to "Önceki", "ALL" to "Tümü",
        "NONE" to "Hiçbiri", "DEFAULT" to "Varsayılan", "APPLY" to "Uygula", "RESET" to "Sıfırla",
        "INVENTORY" to "Envanter", "OUTFITS" to "Kıyafetler", "OUTFIT" to "Kıyafet", "WEAPONS" to "Silahlar",
        "STATS" to "İstatistikler", "GAME" to "Oyun",
    )

    /**
     * Etiketin Türkçesi: simgelerle ([ButtonIcons.MARKER]) ayrılan her parça sözlükte olan bir komutsa simgeler yerinde
     * kalarak çevrilir. Parçalardan biri sözlükte yoksa ya da sıradan cümleyse ("Open the door") null.
     */
    fun translate(paragraph: String): String? {
        val parts = paragraph.split(ButtonIcons.MARKER)
        val translated = mutableListOf<String>()
        var any = false
        for (part in parts) {
            val words = part.trim().trim('.', ',', ':', '!', '?').trim()
            if (words.isEmpty()) {
                translated.add("")
                continue
            }
            if (words.none { it.isLetter() }) return null
            val turkishText = commands[words.uppercase(Locale.ROOT)] ?: return null
            translated.add(cased(turkishText, words))
            any = true
        }
        if (!any) return null
        return translated.joinToString(" ${ButtonIcons.MARKER} ").split(' ').filter { it.isNotEmpty() }.joinToString(" ")
    }

    /** Özgünün harf biçimi: BÜYÜK, küçük ya da baş harfi büyük. */
    private fun cased(value: String, original: String): String {
        val letters = original.filter { it.isLetter() }
        return when {
            letters.all { it.isUpperCase() } -> value.uppercase(turkish)
            letters.all { it.isLowerCase() } -> value.lowercase(turkish)
            else -> value.replaceFirstChar { it.titlecase(turkish) }
        }
    }
}
