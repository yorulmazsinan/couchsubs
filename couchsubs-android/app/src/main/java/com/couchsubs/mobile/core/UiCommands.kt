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
        // GTA 6 telefonu ve bar menüsü ("SCROLL / SEND / BACK", "TIP $10 / ORDER / BARTENDER").
        "SEND" to "Gönder", "TIP" to "Bahşiş ver", "BARTENDER" to "Barmen",
    )

    /**
     * Menülerin kısa etiketleri (ayar değerleri, sekme ve düğme adları); yalnız [translateLabel]'da aranır. [commands]'ta
     * olan etiketin orada kayıtlı Türkçesi kullanılır (Mac ve Windows: UiCommands ile aynı).
     */
    private val labels: Map<String, String> = mapOf(
        "ON" to "Açık", "OFF" to "Kapalı", "LOAD" to "Yükle", "SETTINGS" to "Ayarlar", "MAP" to "Harita",
        "RESUME" to "Sürdür", "QUIT" to "Çık", "NEXT" to "İleri", "PREVIOUS" to "Önceki", "ALL" to "Tümü",
        "NONE" to "Hiçbiri", "DEFAULT" to "Varsayılan", "APPLY" to "Uygula", "RESET" to "Sıfırla",
        "INVENTORY" to "Envanter", "OUTFITS" to "Kıyafetler", "OUTFIT" to "Kıyafet", "WEAPONS" to "Silahlar",
        "STATS" to "İstatistikler", "GAME" to "Oyun",
    )

    private fun joined(parts: List<String>) =
        parts.joinToString(" ${ButtonIcons.MARKER} ").split(' ').filter { it.isNotEmpty() }.joinToString(" ")

    private fun trimmed(text: String) = text.trim().trim('.', ',', ':', '!', '?').trim()

    /**
     * Tuş çubuğunun Türkçesi: simgelerle ([ButtonIcons.MARKER]) ayrılan her parça sözlükte olan BÜYÜK HARFLİ bir
     * komutsa simgeler yerinde kalarak sözlükteki biçimiyle çevrilir ("SET DESTINATION ✕" → "Hedef belirle ✕"); tek
     * başına komut da ("REFUEL"). Parçalardan biri sözlükte yoksa ya da sıradan cümleyse ("Open the door") null. Mac ve
     * Windows UiCommands.translate ile aynı; önceden Android büyük harfli komutu büyük harfle ("HEDEF BELİRLE") veriyordu.
     */
    fun translate(paragraph: String): String? {
        val translated = mutableListOf<String>()
        var any = false
        for (part in paragraph.split(ButtonIcons.MARKER)) {
            val words = trimmed(part)
            if (words.isEmpty()) {
                translated.add("")
                continue
            }
            if (words.none { it.isLetter() } || words != words.uppercase(Locale.ROOT)) return null
            translated.add(commands[words] ?: return null)
            any = true
        }
        return if (any) joined(translated) else null
    }

    /** Yazı tanımanın Kiril harfle okuduğu Latin harfler ("Мар" → "Map"). */
    private fun latin(text: String): String = text.map { c ->
        when (c) {
            'А' -> 'A'; 'В' -> 'B'; 'Е' -> 'E'; 'К' -> 'K'; 'М' -> 'M'; 'Н' -> 'H'; 'О' -> 'O'; 'Р' -> 'P'; 'С' -> 'C'
            'Т' -> 'T'; 'Х' -> 'X'; 'а' -> 'a'; 'е' -> 'e'; 'о' -> 'o'; 'р' -> 'p'; 'с' -> 'c'; 'х' -> 'x'; 'у' -> 'y'
            else -> c
        }
    }.joinToString("")

    /**
     * Menüdeki kısa etiketin Türkçesi ("OFF" → "KAPALI", "Off" → "Kapalı", "off" → "kapalı"): etiketin tamamı sözlükte
     * olmalı (büyük/küçük harf fark etmez); biçimi Türkçe kurallarıyla korunur (i → İ, ı → I). Sözlükte yoksa null.
     */
    fun translateLabel(label: String): String? {
        val words = trimmed(label)
        if (words.none { it.isLetter() }) return null
        val key = latin(words).uppercase(Locale.ROOT)
        val turkishText = commands[key] ?: labels[key] ?: return null
        val letters = words.filter { it.isLetter() }
        return when {
            letters.all { it.isUpperCase() } -> turkishText.uppercase(turkish)
            letters.all { it.isLowerCase() } -> turkishText.lowercase(turkish)
            else -> turkishText
        }
    }

    /**
     * [translateLabel], yazı tanımanın etikete kattığı kırıntıyla da: simge imleriyle ayrılan her parça ayrı aranır;
     * baştaki ya da sondaki en çok iki harflik kırıntı (simgenin yanlış okunuşu: "pi Settings", "EXIT OR") olduğu gibi
     * kalır (baştaki tuş adı değilse atılır). Bir parça bulunmazsa null (Mac ve Windows ile aynı).
     */
    fun translateLabelLoosely(label: String): String? {
        if (label.contains(ButtonIcons.MARKER)) {
            val done = mutableListOf<String>()
            var any = false
            for (part in label.split(ButtonIcons.MARKER)) {
                if (part.isBlank()) { done.add(""); continue }
                done.add(translateLabelLoosely(part) ?: return null)
                any = true
            }
            return if (any) joined(done) else null
        }
        translateLabel(label)?.let { return it }
        val words = label.trim().split(' ').filter { it.isNotEmpty() }
        if (words.size < 2) return null
        // Baştaki kırıntı tuş adıysa ("R3 LOOK BEHIND") kalır; değilse ("1 Map", "pi Settings") atılır.
        if (words[0].length <= 2) translateLabel(words.drop(1).joinToString(" "))?.let { rest ->
            return if (ButtonIcons.isButtonName(words[0])) words[0] + " " + rest else rest
        }
        if (words.last().length <= 2) translateLabel(words.dropLast(1).joinToString(" "))?.let { return it + " " + words.last() }
        return null
    }
}
