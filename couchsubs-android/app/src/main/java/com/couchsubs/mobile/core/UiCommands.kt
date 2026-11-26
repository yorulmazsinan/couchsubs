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
        "EXIT" to "Çık", "BACK" to "Geri", "SELECT" to "Seç", "CLOSE" to "Kapat", "CLOSE MENU" to "Menüyü kapat",
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
        "REMINDERS" to "Hatırlatıcılar",
        // GTA 6 duraklatma menüsü ve harita ipuçları (Sinan Bey, 24 Kas: sabit karşılıklar, çeviri motorundan önce).
        "ADD WAYPOINT" to "İşaret ekle", "RETRY CHECKPOINT" to "Kontrol noktasını yeniden dene",
        "RESTART MISSION" to "Görevi yeniden başlat", "QUIT MISSION" to "Görevden çık",
        "ROTATE" to "Döndür", "INTERACT" to "Etkileşim", "USE" to "Kullan",
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
        "STATS" to "İstatistikler", "GAME" to "Oyun", "BRIEF" to "Özet", "PROGRESS" to "İlerleme", "VEHICLES" to "Araçlar",
        "ANIMALS" to "Hayvanlar",
        // Ayarlar › Kumanda şeması önizlemesi (#1362): kısa arayüz komutları diyalog gibi çevriliyordu ("RUN" → "KAÇ!",
        // "MOVE" → "ÇEKİL!", "DETONATE EXPLOSIVES" → "DETONATE EXPLOSIVES YAP"). Etiket olarak sabit karşılıklar.
        "RUN" to "Koş", "MOVE" to "Hareket", "SPRINT" to "Depar", "WALK" to "Yürü", "JUMP" to "Zıpla", "CLIMB" to "Tırman",
        "CROUCH" to "Eğil", "COVER" to "Siper", "SHOOT" to "Ateş et", "AIM" to "Nişan al", "MELEE" to "Yakın dövüş",
        "RELOAD" to "Şarjör değiştir", "HOLSTER" to "Silahı kılıfa koy", "CELLPHONE" to "Cep telefonu", "PHONE" to "Telefon",
        "RADIO CONTROLS" to "Radyo kontrolleri", "RADIO MENU" to "Radyo menüsü", "RADIO" to "Radyo", "OBJECTIVE" to "Hedef",
        "MINIMAP" to "Mini harita", "DETONATE EXPLOSIVES" to "Patlayıcıları patlat", "DETONATE" to "Patlat",
        "LOADOUT" to "Teçhizat", "QUICK NAVIGATION" to "Hızlı gezinme", "PARTNER MENU" to "Partner menüsü",
        "PAUSE" to "Duraklat", "LOOK BEHIND" to "Arkana bak", "WEAPON WHEEL" to "Silah çarkı",
        "INTERACTION MENU" to "Etkileşim menüsü", "ACCELERATE" to "Hızlan", "BRAKE" to "Fren", "REVERSE" to "Geri vites",
        "HANDBRAKE" to "El freni", "HORN" to "Korna", "HEADLIGHTS" to "Farlar", "SWIM" to "Yüz", "TAKE COVER" to "Siper al",
        "THROW" to "Fırlat", "SPECIAL ABILITY" to "Özel yetenek", "SWITCH CHARACTER" to "Karakter değiştir",
        "SWITCH WEAPON" to "Silah değiştir", "CONTROLS" to "Kontroller",
        // Haritanın görev listesi ve görev kartı (#1365): "GOAL" motordan "GOL." dönüyordu; arayüz etiketi olarak sabit.
        "GOAL" to "Hedef", "GOALS" to "Hedefler", "OBJECTIVES" to "Hedefler", "MISSION" to "Görev", "MISSIONS" to "Görevler",
        "STORY" to "Hikâye", "OPTIONAL" to "İsteğe bağlı", "REWARD" to "Ödül", "REWARDS" to "Ödüller",
    )

    /**
     * Görev başlığı: emir fiili ve ardında özel ad ("Hit Kingpin Bowling", "Meet Bret"). Motor özel adı görüp başlığı
     * olduğu gibi döndürünce başlık hiç çevrilmiyordu (#1365); yalnız fiil çevrilir, ad olduğu gibi kalır ve Türkçe eki
     * alır ("Kingpin Bowling'i Soy", "Bret ile Buluş"). Adın her sözcüğü büyük harfle başlar, yalnız harf; bağlaç/edat
     * ("for", "the") ya da iyelik ("Vicki's") varsa başlık bu kalıba girmez. Yalnız motor çevirmediğinde kullanılır
     * (Mac/iPhone ve Windows aynı).
     */
    private val titleVerbs: List<Triple<String, String, String>> = listOf(
        Triple("hit", "i", "Soy"), Triple("rob", "i", "Soy"), Triple("meet", "", "ile Buluş"), Triple("visit", "i", "Ziyaret Et"),
        Triple("find", "i", "Bul"), Triple("check out", "a", "Göz At"), Triple("go to", "a", "Git"), Triple("head to", "a", "Git"),
        Triple("return to", "a", "Dön"), Triple("call", "i", "Ara"), Triple("follow", "i", "Takip Et"), Triple("steal", "i", "Çal"),
        Triple("protect", "i", "Koru"), Triple("chase", "i", "Kovala"), Triple("rescue", "i", "Kurtar"), Triple("defend", "i", "Savun"),
        Triple("explore", "i", "Keşfet"), Triple("investigate", "i", "Araştır"), Triple("pick up", "i", "Al"), Triple("help", "a", "Yardım Et"),
    )

    fun missionTitle(title: String): String? {
        val words = title.trim(' ').split(' ').filter { it.isNotEmpty() }
        if (words.size !in 2..6 || TextStyleSampler.isUpper(title)) return null
        for ((verbText, suffix, turkishVerb) in titleVerbs) {
            val verb = verbText.split(' ')
            if (words.size <= verb.size || !words.zip(verb).all { (word, v) -> word.lowercase(Locale.ROOT) == v } ||
                !words[0].first().isUpperCase()) continue
            val name = words.drop(verb.size)
            if (!name.all { word -> word.first().isUpperCase() && word.length >= 2 && word.all { it.isLetter() || it == '-' } }) return null
            val joined = name.joinToString(" ")
            val target = if (suffix.isEmpty()) joined else com.couchsubs.mobile.translation.TurkishSuffix.attach(joined, suffix)
            return "$target $turkishVerb"
        }
        return null
    }

    /**
     * Etiketin sonunda önündeki sözcüklerden ayrı duran tek harf (yazı tanımanın tuş simgesinden okuduğu harf, #1362:
     * "RADIO CONTROLS f" → "RADYO KONTROLLERİ F", "RADIO MENU (I") atılır. Yalnız en az iki sözcüklü (iki harften uzun)
     * etiketin sonunda ve şu durumlarda: harf parantezle okunmuş; BÜYÜK HARFLİ etiketin sonunda küçük harf; ya da BÜYÜK
     * HARFLİ etiketin sonunda tuş yüzü harfi (A, B, X, Y, F, E, Q, R, L, I, O). Harfin sözcüğe ait olduğu etiket ("PRESS A",
     * "PLAN B"; önündeki sözcük [glyphOwners]'da) dokunulmaz (Mac/Windows aynı).
     */
    fun withoutKeyGlyph(label: String): String {
        val tokens = label.split(' ').filter { it.isNotEmpty() }
        if (tokens.size < 3) return label
        val last = tokens.last()
        val core = last.trim('(', '[', '{', ')', ']', '}')
        if (core.length != 1) return label
        val letter = core[0]
        if (!letter.isLetter() || letter.code >= 128) return label
        val head = tokens.dropLast(1)
        if (head.count { word -> word.count { it.isLetter() } >= 2 } < 2 ||
            head.last().uppercase(Locale.ROOT) in glyphOwners
        ) return label
        val letters = head.joinToString("").filter { it.isLetter() }
        val upperHead = letters.isNotEmpty() && letters.all { it.isUpperCase() }
        val bracketed = last != core
        val glyph = bracketed || (upperHead && (letter.isLowerCase() || letter in "ABXYFEQRLIO"))
        return if (glyph) head.joinToString(" ") else label
    }

    /** Ardındaki tek harf kendisine ait olan sözcükler ("PRESS A", "PLAN B", "BUTTON X"). */
    private val glyphOwners: Set<String> = setOf(
        "PRESS", "HOLD", "TAP", "USE", "KEY", "BUTTON", "PLAN", "TYPE", "CLASS", "GRADE", "PART", "SIDE", "VITAMIN",
        "ROUTE", "LEVEL", "ZONE", "AREA", "SECTOR", "GATE", "BLOCK", "TEAM", "GROUP", "OPTION", "CHAPTER", "ACT",
        "STAGE", "SEASON", "EPISODE", "FLOOR", "ROOM", "SLOT", "PLAYER", "MODE", "SECTION",
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
        val near = nearKey(key) ?: ""
        val turkishText = commands[key] ?: labels[key] ?: commands[near] ?: labels[near] ?: return null
        val letters = words.filter { it.isLetter() }
        if (letters.all { it.isUpperCase() }) return turkishText.uppercase(turkish)
        if (letters.all { it.isLowerCase() }) return turkishText.lowercase(turkish)
        // Her sözcüğü büyük harfle başlayan etiket ("Set Destination", "Photo Studio"): Türkçesi de öyle ("Hedef Belirle").
        val titled = words.split(' ').filter { it.isNotEmpty() }.all { word ->
            word.first().isUpperCase() || word.none { it.isLetter() }
        }
        if (titled && words.contains(' ')) {
            return turkishText.split(' ').filter { it.isNotEmpty() }.joinToString(" ") { word ->
                word.take(1).uppercase(turkish) + word.drop(1)
            }
        }
        return turkishText
    }

    /**
     * Yazı tanımanın tek harfini yanlış okuduğu etiket ("SET DESTINATlON", "SETTINQS"): en az yedi harflik anahtarlardan
     * tek harf farkla (değişen, eksik ya da fazla) eşleşen tek anahtar; birden çoğu eşleşirse null (Mac ve Windows aynı).
     */
    internal fun nearKey(key: String): String? {
        if (key.length < 7) return null
        val found = (commands.keys + labels.keys).filter { it.length >= 7 && kotlin.math.abs(it.length - key.length) <= 1 && oneEdit(it, key) }
        return found.singleOrNull()
    }

    /** İki yazı en çok bir düzenlemeyle (bir harf değişmesi, eklenmesi ya da silinmesi) aynı mı. */
    internal fun oneEdit(a: String, b: String): Boolean {
        if (a == b) return true
        if (a.length == b.length) return a.indices.count { a[it] != b[it] } == 1
        val (long, short) = if (a.length > b.length) a to b else b to a
        if (long.length != short.length + 1) return false
        var i = 0
        var j = 0
        var skipped = false
        while (i < long.length && j < short.length) {
            if (long[i] == short[j]) { i++; j++ }
            else if (skipped) return false
            else { skipped = true; i++ }
        }
        return true
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
        translateTabs(label)?.let { return it }
        val words = label.trim().split(' ').filter { it.isNotEmpty() }
        if (words.size < 2) return null
        // Baştaki kırıntı tuş adıysa ("R3 LOOK BEHIND") kalır; değilse ("1 Map", "pi Settings") atılır.
        if (words[0].length <= 2) translateLabel(words.drop(1).joinToString(" "))?.let { rest ->
            return if (ButtonIcons.isButtonName(words[0])) words[0] + " " + rest else rest
        }
        if (words.last().length <= 2) translateLabel(words.dropLast(1).joinToString(" "))?.let { return it + " " + words.last() }
        return null
    }

    /**
     * Tek satır okunan sekme çubuğu ("JASON & LUCIA MAP BRIEF"): "AD & AD" kalır, kalan her sözcük sözlükte olmalı; motora
     * gitmez, her karede aynı çeviri (Mac/Windows ile aynı). Yalnız BÜYÜK HARFLİ yazıda.
     */
    fun translateTabs(label: String): String? {
        val words = label.trim().split(' ').filter { it.isNotEmpty() }
        if (words.size < 2 || !TextStyleSampler.isUpper(label)) return null
        val out = mutableListOf<String>()
        var i = 0
        while (i < words.size) {
            if (i + 2 < words.size && words[i + 1] == "&") {
                out += words.subList(i, i + 3)
                i += 3
                continue
            }
            out += translateLabel(words[i]) ?: return null
            i++
        }
        return out.joinToString(" ")
    }
}
