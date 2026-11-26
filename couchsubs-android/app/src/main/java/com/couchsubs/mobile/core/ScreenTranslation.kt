// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.max
import kotlin.math.min

/**
 * "Ekranı çevir": karenin tamamı bir kez okunur, yazılar yerlerine göre gruplara ayrılır (menü, görev paneli, bilgi
 * kutusu, altyazı...) ve hepsi tek istekte çevrilir. TV ve telefon her çeviriyi kendi İngilizce yazısının üstüne, o
 * yazının boyutunda koyar (Mac/iPhone ScreenTranslation.swift ve Windows ScreenTranslation.cs ile aynı kurallar).
 */
object ScreenTranslation {
    /** Ekrandaki bir yazı grubu. */
    data class Group(
        /** Ayrı ayrı çevrilecek parçalar (başlık, cümle, menü satırı...). */
        val paragraphs: List<String>,
        /** Karedeki yeri, kenarlara oranla. */
        val box: TextBox,
        /** Satırlarının tipik yüksekliği, karenin yüksekliğine oranla; yazı boyu buna göre seçilir. */
        val lineHeight: Double,
        /** Her parçadaki kumanda simgeleri, parçadaki [ButtonIcons.MARKER] sırasıyla; simge yoksa null. */
        val icons: List<List<IconSlot>>? = null,
        /** GTA 6 telefonunun ekranındaki grubun rolü ve düz ekrandaki yeri ([PhoneChat]); telefon dışındaysa null. */
        val phone: ScreenPhoneCard.Placement? = null,
        /** Özgün yazının satır sayısı; çeviri de bu kadar satıra sığdırılır (TV satır aralığını buna göre seçer). */
        val rows: Int = 1,
    )

    data class Item(
        val source: String,
        /** Parçaların çevirisi, her parça ayrı satırda. */
        val translation: String,
        val box: TextBox,
        val lineHeight: Double,
        /** Çevirinin içindeki kumanda simgeleri (kareden kesilmiş); TV [translation]'ın o yerine koyar. */
        val icons: List<IconPlacement>? = null,
        /** Otomatik ekran yazısında özgün bloğun zemini ve yazı rengi ([TextStyleSampler]); `surface` alanıyla gider. */
        val surface: TextSurface? = null,
        /** Özgün yazının görünüşü (kalın, dar, hizalama, büyük harf); `style` alanıyla gider. */
        val look: TextLook? = null,
        /** Çevirisi aslıyla aynı (ad, "ok"): yalnız telefon kartında gösterilir, başka yerde atılır ([ScreenPhoneCard]). */
        val unchanged: Boolean = false,
        /** Telefondaki yazının rolü ve düz ekrandaki yeri; kart bunlarla dizilir ([ScreenPhoneCard.layout]). */
        val phone: ScreenPhoneCard.Placement? = null,
        /**
         * GTA 6 telefonunun mesajı kendi balonunun üstünde, yerinde (kartsız): TV çeviriyi balona sığdırır (yazı okunabilir
         * sınıra kadar küçülür, satır kırılır; sığmazsa balon biraz aşağı uzar). Mac ile aynı.
         */
        val bubble: Boolean = false,
        /**
         * Telefonun yanındaki sohbet panelinin parçası ([ScreenPhoneCard.PanelPart]); yeni çiziciler paneli akışla çizer,
         * eski TV kutuları yerinde çizer (Mac ile aynı).
         */
        val panel: ScreenPhoneCard.PanelPart? = null,
        /**
         * Panelin zemininde ([ScreenPhoneCard.PanelPart.CARD]): parçalar akışla değil kutularının yerinde çizilir; her
         * Türkçe balon telefondaki İngilizce balonuyla aynı yükseklikte ([ScreenPhoneCard.layout], JSON `aligned`). Eski TV
         * yok sayar (Mac ile aynı).
         */
        val aligned: Boolean = false,
        /** Kutunun genişleyebileceği yatay alan (simgelere ve komşu yazıya kadar; [ScreenFit]); null ise bilinmiyor. */
        val room: TextBox? = null,
        /** Özgün yazının satır sayısı ([Group.rows]). */
        val rows: Int = 1,
        /**
         * Yerinde birebir çizim için kareden ölçülenler (örtü kutusu, zemin/degrade, satır aralığı, boş alan, grup;
         * [TextPainter]); null ise eski çizim.
         */
        val paint: TextPaint? = null,
        /**
         * Sohbet listesinin satırı ya da ana ekran bileşeni tek kartta (`panel == ROW`; JSON `row`). Eski TV yok sayar
         * (iPhone ile aynı).
         */
        val listRow: ScreenPhoneCard.ListRow? = null,
    ) {
        /** Birden çok parça var: satır satır, sola yaslı gösterilir. */
        val paragraphs: Boolean get() = translation.contains('\n')
    }

    /**
     * Kalabalık ekranda ekranı kutuyla doldurmamak ve çeviriyi uzatmamak için en çok bu kadar grup çevrilir; fazlası
     * olunca en az yazısı olanlar (tek sözcüklük etiketler) bırakılır.
     */
    const val MAX_GROUPS = 30

    /**
     * Grupları sırayla çevirir; her grup çevrilince o ana kadarki sonuçlarla [progress] çağrılır. Çevirisi aslıyla aynı
     * olan (ad, sayı, zaten Türkçe yazı) grup gösterilmez. [cancelled] true dönerse iş bırakılır. [frame] okunan kareyse
     * yazıların içindeki kumanda simgeleri ondan kesilip çeviriye konur.
     */
    fun translateGroups(
        reading: Reading, translate: (String) -> String, cancelled: () -> Boolean = { false }, frame: GrayFrame? = null,
        color: ((Int, Int) -> Int)? = null, phone: ScreenPhoneCard.Handset? = null, memory: PhoneChatMemory? = null,
        phoneCard: Boolean = true, panelScale: Double = 1.0, progress: (List<Item>) -> Unit = {},
    ): List<Item> {
        val all = withImages(groups(reading, wholeScreen = true, handset = phone, frame = frame, color = color), frame)
        val chat = chatTitle(all)
        val made = sortedMapOf<Int, Item>()
        // Telefon listesi kartlarının avatarı, rozeti ve seçim çerçevesi bu kareden ([PhoneListLook]).
        val looks = PhoneListLook()
        fun shown(): List<Item> {
            var items = present(made.values.toList(), phone, phoneCard, panelScale)
            if (frame != null && frame.isValid && items.any { it.listRow != null }) {
                items = looks.apply(items, frame.width, frame.height,
                    color ?: { x, y -> frame.at(x, y).let { (it shl 16) or (it shl 8) or it } })
            }
            // Liste kartı kendi kutusunda çizilir; yerinde birebir çizim ölçüleri ([ScreenFit]) ona uygulanmaz.
            return ScreenFit.fitted(items.filter { it.panel != ScreenPhoneCard.PanelPart.ROW }, frame, color) +
                items.filter { it.panel == ScreenPhoneCard.PanelPart.ROW }
        }
        // Simgeler çeviride uydurma adlarla korunur (IconText); sözlükteki kısa etiketler çevirmene gitmez, fiyatlar
        // adla korunur (PriceText).
        val prepared = all.map { group -> group.paragraphs.map { IconText.protect(it) } }
        // Önce çevirmene gitmeyecek gruplar (sözlük, bu ekranda daha önce çevrilmiş yazı): çeviri beklemeden hemen çizilir.
        val waiting = mutableListOf<Int>()
        for ((g, group) in all.withIndex()) {
            val ready = group.paragraphs.map { known(it, group) ?: remembered(it, group, chat, memory) }
            if (ready.any { it == null }) {
                waiting.add(g)
                continue
            }
            item(group, prepared[g], ready.map { it!! }, keepUnchanged = phone != null)?.let { made[g] = styled(it, frame, color) }
        }
        if (made.isNotEmpty() && waiting.isNotEmpty()) shown().takeIf { it.isNotEmpty() }?.let(progress)
        for (g in waiting) {
            if (cancelled()) return shown()
            val group = all[g]
            val translated = prepared[g].mapIndexed { index, paragraph ->
                val source = group.paragraphs[index]
                known(source, group) ?: remembered(source, group, chat, memory)
                    ?: PriceText.protect(paragraph.text).let { PriceText.restore(translate(it.text), it.values) }
                        .also { memory?.remember(memoryChat(group, chat), source, it) }
            }
            val item = item(group, prepared[g], translated, keepUnchanged = phone != null) ?: continue
            made[g] = styled(item, frame, color)
            val now = shown()
            if (now.isNotEmpty()) progress(now)
        }
        return shown()
    }

    /**
     * Çevirmen parçaları tek istekte çevirebiliyorsa (yapay zekâ) ekranın bütün parçaları birlikte gider ve sonuç bir
     * kerede gelir; yoksa gruplar sırayla çevrilip hazırlandıkça bildirilir. [frame] okunan kareyse yazıların içindeki
     * kumanda simgeleri ondan kesilip çeviriye konur ve her çeviri özgün yazının stilinde (zemin ve yazı rengi —
     * [color] verilirse gerçek renk —, kalınlık, hiza, BÜYÜK HARF; otomatik ekran yazısıyla aynı, [TextStyleSampler])
     * kendi kutusunun yerine çizilir. [phone]: karede bulunan GTA 6 telefonu; yazıları yanında bir mesaj kartında
     * dizilir ([ScreenPhoneCard]). [memory] verilirse çeviriler (telefon mesajları sohbetin başlığıyla) saklanır; aynı
     * sohbete dönünce ya da kart yenilenince çevirmene gitmez ([PhoneChatMemory]).
     */
    fun translate(
        reading: Reading, translator: TextTranslator, cancelled: () -> Boolean = { false }, frame: GrayFrame? = null,
        color: ((Int, Int) -> Int)? = null, phone: ScreenPhoneCard.Handset? = null, memory: PhoneChatMemory? = null,
        phoneCard: Boolean = true, panelScale: Double = 1.0, progress: (List<Item>) -> Unit = {},
    ): List<Item> {
        if (!translator.translatesTogether)
            return translateGroups(reading, { translator.translate(it) }, cancelled, frame, color, phone, memory, phoneCard, panelScale, progress)
        val groups = withImages(groups(reading, wholeScreen = true, handset = phone, frame = frame, color = color), frame)
        // Simgeler çeviride uydurma adlarla korunur (IconText). Sözlükteki kısa arayüz etiketleri ("SCROLL", "SEND",
        // "BACK") ve telefondaki kişi adları çevirmene gitmez; fiyatlar adla korunur (PriceText).
        val prepared = groups.map { group -> group.paragraphs.map { IconText.protect(it) } }
        val sources = groups.flatMap { it.paragraphs }
        if (sources.isEmpty()) return emptyList()
        val chat = chatTitle(groups)
        // Daha önce görülen sohbetin mesajları da çevirmene gitmez ([memory]).
        val owners = groups.flatMap { group -> group.paragraphs.map { group } }
        val prices = prepared.flatMap { group -> group.map { PriceText.protect(it.text) } }
        // Diskteki çeviri önbelleğinde duran yazı (menü satırları oturumdan oturuma tekrar eder) da çevirmene gitmez.
        val knowns: MutableList<String?> = sources.indices.map { i ->
            known(sources[i], owners[i]) ?: remembered(sources[i], owners[i], chat, memory)
                ?: translator.cachedTranslation(prices[i].text)?.let { PriceText.restore(it, prices[i].values) }
        }.toMutableList()
        val asked = prices.indices.filter { knowns[it] == null }
        // Gruplar: hazır olanlar (bütün parçaları biliniyor) çeviri isteğini beklemeden hemen çizilir.
        fun laid(translations: List<String?>): List<Item> {
            val items = mutableListOf<Item>()
            var next = 0
            for ((index, group) in groups.withIndex()) {
                val count = group.paragraphs.size
                val part = (next until next + count).map { translations.getOrNull(it) }
                next += count
                if (part.any { it == null }) continue
                item(group, prepared[index], part.map { it!! }, keepUnchanged = phone != null)?.let { items.add(styled(it, frame, color)) }
            }
            return ScreenFit.fitted(present(items, phone, phoneCard, panelScale), frame, color)
        }
        if (asked.isNotEmpty()) laid(knowns).takeIf { it.isNotEmpty() }?.let(progress)
        val answers = if (asked.isEmpty()) emptyList() else translator.translateAll(asked.map { prices[it].text })
        if (cancelled()) return emptyList()
        asked.forEachIndexed { k, index ->
            if (k < answers.size) {
                knowns[index] = PriceText.restore(answers[k], prices[index].values)
                memory?.remember(memoryChat(owners[index], chat), sources[index], knowns[index]!!)
            }
        }
        // Gelmeyen çeviri boş kalır: parça aslıyla gösterilir.
        val shown = laid(knowns.map { it ?: "" })
        if (shown.isNotEmpty()) progress(shown)
        return shown
    }

    /**
     * Oyun arayüzü sözlüğündeki kısa etiketin Türkçesi ("SCROLL" → "KAYDIR", "TIP" → "BAHŞİŞ VER"); simgeli ya da
     * sözlükte olmayan parçada null (çevirmene gider).
     */
    internal fun known(paragraph: String, group: Group? = null): String? = when {
        // Telefondaki kişi adı (sohbet başlığı, listedeki ad) çevrilmez: "Rose" "Gül", "May" "Mayıs" olmasın.
        group?.phone?.role?.keepsText == true -> paragraph
        // "JASON & LUCIA" gibi yalnız özel adlardan oluşan sekme/başlık çevrilmez (#859).
        keepsNames(paragraph) -> paragraph
        paragraph.indexOf(ButtonIcons.MARKER) >= 0 -> null
        else -> UiCommands.translateLabel(paragraph)
    }

    /** Telefondaki sohbetin başlığı (kişi adı); sohbet listesinde ya da telefonsuz karede boş. */
    internal fun chatTitle(groups: List<Group>): String =
        groups.firstOrNull { it.phone?.role == ScreenPhoneCard.Role.HEADER }?.paragraphs?.firstOrNull() ?: ""

    /** Hafızadaki yeri: telefon mesajı sohbetin başlığıyla, telefon dışındaki yazı (görev, menü) başlıksız saklanır. */
    internal fun memoryChat(group: Group, chat: String): String = if (group.phone == null) "" else chat

    /** Bu sohbette (telefon dışındaki yazıda: bu ekranda) daha önce çevrilmiş parçanın çevirisi ([PhoneChatMemory]). */
    internal fun remembered(paragraph: String, group: Group, chat: String, memory: PhoneChatMemory?): String? =
        memory?.translation(memoryChat(group, chat), paragraph)

    /**
     * Öğeye özgün yazının görünüşü: zemin ve yazı rengi, kalınlık, dar yazı, hiza; özgün yazı BÜYÜK HARFse çeviri de
     * büyütülür. Önceden "Ekranı çevir" her yazıyı aynı siyah kutuda gösteriyordu, otomatik ekran yazısı ise özgün
     * stilde; kullanıcılar çevirinin "ayrı bir kutuda" durduğunu söylüyordu.
     */
    internal fun styled(item: Item, frame: GrayFrame?, color: ((Int, Int) -> Int)?): Item {
        if (frame == null) return item
        val box = item.box
        val style = TextStyleSampler.sample(
            frame, (box.left * frame.width).toInt(), (box.top * frame.height).toInt(),
            kotlin.math.ceil(box.right * frame.width).toInt(), kotlin.math.ceil(box.bottom * frame.height).toInt(),
            item.lineHeight * frame.height, item.source, emptyList(), color,
        ) ?: return item
        val translation = if (style.look.upper) TextStyleSampler.upper(item.translation) else item.translation
        return item.copy(translation = translation, surface = style.surface, look = style.look)
    }

    /**
     * Gösterilecek öğeler: telefon varsa [card] açıkken kartı dizilir; kapalıyken (varsayılan ayar) her mesajın çevirisi
     * kendi balonunun üstünde, balonun rengiyle yerinde kalır ([Item.bubble]). Çevirisi aslıyla aynı öğeler (kart dışında;
     * yerinde kişi adı) atılır, özgün yazı görünür kalır (Mac ile aynı).
     */
    internal fun present(items: List<Item>, phone: ScreenPhoneCard.Handset?, card: Boolean = true, textScale: Double = 1.0): List<Item> =
        withoutDuplicates((if (phone != null && card) ScreenPhoneCard.layout(items, phone, textScale)
            else items.map { it.copy(bubble = it.phone?.role?.inCard == true) }).filter { !it.unchanged })

    // --- Aynı yerde tek çizim (#827) ---

    /**
     * Aynı okumada iki satırın (ya da iki öğenin) kutusu küçüğünün alanının en az bu kadarı kadar örtüşüyorsa aynı yazının
     * iki okunuşudur; yalnız harfi çok olanı kalır.
     */
    const val DUPLICATE_SHARE = 0.5

    /**
     * Ayrı yollardan gelen iki çevirinin ("Ekranı çevir", otomatik ekran yazısı, ek alan) kutusu küçüğünün alanının en az
     * bu kadarı kadar örtüşüyorsa aynı yazıyı çiziyorlardır; yalnız biri çizilir. Önceden GTA 6 haritasında ikisi üst üste
     * çiziliyor, alttakinin yazısı üsttekinin arasından görünüyordu.
     */
    const val COVER_SHARE = 0.25

    /** İki kutunun kesişiminin küçük kutunun alanına oranı (0…1). */
    fun overlap(a: TextBox, b: TextBox): Double {
        val width = minOf(a.right, b.right) - maxOf(a.left, b.left)
        val height = minOf(a.bottom, b.bottom) - maxOf(a.top, b.top)
        if (width <= 0 || height <= 0) return 0.0
        val smaller = minOf((a.right - a.left) * (a.bottom - a.top), (b.right - b.left) * (b.bottom - b.top))
        return if (smaller > 0) minOf(1.0, width * height / smaller) else 0.0
    }

    private fun letters(text: String): Int = text.count { it.isLetter() }

    /**
     * Aynı yazının iki okunuşundan (yazı tanıma bir satırı hem bütün hem parça okuyabiliyor) yalnız harfi çok olanı kalır;
     * eşitse önce gelen. Sıra korunur. Önceden ikisi ayrı çevrilip üst üste çiziliyordu ("Donnie'nin Paketini Bul" altında
     * "Bulur").
     */
    fun withoutDuplicateLines(lines: List<TextLine>): List<TextLine> {
        val counts = lines.map { letters(it.text) }
        return lines.filterIndexed { i, line ->
            val box = line.box ?: return@filterIndexed true
            lines.indices.none { j ->
                val other = lines[j].box
                j != i && other != null && overlap(box, other) >= DUPLICATE_SHARE &&
                    (counts[j] > counts[i] || (counts[j] == counts[i] && j < i))
            }
        }
    }

    /**
     * Satırın başındaki ya da sonundaki simge kırıntısı (menüdeki harita/dükkân/ayar simgesi yazı tanımada "<", "©",
     * "@" ya da baştaki tek harf olarak okunur) satırdan atılır; kutu yalnız yazının sözcüklerini kapsar (#827). Önceden
     * çeviri kutusu simgeyi de örtüyordu. Sözcük yerleri bilinmiyorsa harf sayısına göre kestirilir. Kumanda simgeli
     * satıra (simge çeviride yerinde gösterilir), sayıya, noktalamaya ve geriye iki harf kalmayacaksa dokunulmaz.
     */
    fun withoutEdgeMarks(line: TextLine): TextLine {
        val box = line.box ?: return line
        if (!line.icons.isNullOrEmpty() || line.text.contains(ButtonIcons.MARKER)) return line
        val measured = !line.words.isNullOrEmpty()
        val words = if (measured) line.words!! else ButtonIcons.estimate(line.text, box)
        var start = 0
        var end = words.size
        while (start < end - 1 && isEdgeMark(words[start].text, leading = true)) start++
        while (end - 1 > start && isEdgeMark(words[end - 1].text, leading = false)) end--
        if (start == 0 && end == words.size) return line
        val kept = words.subList(start, end)
        if (kept.sumOf { letters(it.text) } < 2) return line
        return line.copy(
            text = kept.joinToString(" ") { it.text },
            box = TextBox(if (start > 0) kept.first().box.left else box.left, box.top,
                if (end < words.size) kept.last().box.right else box.right, box.bottom),
            words = if (measured) kept.toList() else null,
        )
    }

    /** Yalnız noktalamadan oluşan parça simge değildir ("...", "-"). */
    private const val PUNCTUATION = ".,!?…:;-–—'\"’”"
    /** Kumanda tuşu yazısı ("(✕)", "△", "R1"): kontrol şemasında etiketin parçasıdır, çeviride de yazılır; atılmaz. */
    private const val BUTTON_GLYPHS = "✕×△○□◯⨯"

    /**
     * Simge kırıntısı mı: harfi ve rakamı yok ve yalnız noktalama ya da kumanda tuşu değil ("<", "©", "@"); satır başında
     * tek harf de ("G Settings"; "a", "A", "I" sözcüktür).
     */
    internal fun isEdgeMark(word: String, leading: Boolean): Boolean {
        val core = word.trim { it in "()[]{}" }
        if (word.any { it.isDigit() } || word.any { it in BUTTON_GLYPHS } || ButtonIcons.isButtonName(core) ||
            (word.length > 1 && word.first() == '(' && word.last() == ')')) return false
        if (word.none { it.isLetter() }) return !word.all { it in PUNCTUATION }
        return leading && word.length == 1 && word !in setOf("a", "A", "I")
    }

    /** Telefon kartının parçası (zemin, balon, başlık): kart bilerek üst üste dizilir, çakışma kuralına girmez. */
    internal fun isCardPart(item: Item): Boolean = item.phone != null || ScreenPhoneCard.isBackdrop(item)

    /** Aynı okumanın öğelerinden aynı yeri çizenlerin yalnız harfi çok olanı kalır ([DUPLICATE_SHARE]); kart dokunulmaz. */
    internal fun withoutDuplicates(items: List<Item>): List<Item> {
        val counts = items.map { letters(it.source) }
        return items.filterIndexed { i, item ->
            isCardPart(item) || items.indices.none { j ->
                j != i && !isCardPart(items[j]) && overlap(item.box, items[j].box) >= DUPLICATE_SHARE &&
                    (counts[j] > counts[i] || (counts[j] == counts[i] && j < i))
            }
        }
    }

    /**
     * Katmanlar tek listede: sonra gelen öğe, kendisiyle çakışan ([COVER_SHARE]) önceki öğelerin yerine geçer (yeni olan
     * eskisini değiştirir). Telefon kartının parçaları dokunulmaz.
     */
    fun layered(items: List<Item>): List<Item> {
        val result = mutableListOf<Item>()
        for (item in items) {
            if (!isCardPart(item)) result.removeAll { !isCardPart(it) && overlap(it.box, item.box) >= COVER_SHARE }
            result.add(item)
        }
        return result
    }

    /**
     * [items]'tan [top] öğelerinden biriyle çakışanlar ([COVER_SHARE]) atılır: "Ekranı çevir" ekrandayken onun yazılarının
     * yerindeki otomatik ekran yazısı ve ek alan kutuları çizilmez.
     */
    fun uncovered(items: List<Item>, top: List<Item>): List<Item> =
        items.filter { item -> top.none { overlap(item.box, it.box) >= COVER_SHARE } }

    /** Aynı ekranın iki okuması en az bu kadar benzer; yeni bir mesajın eklenmesi bile ekranı "değişmiş" yapar. */
    const val SAME_SCREEN_SIMILARITY = 0.95

    /** Ekranın yazılarının izi: düğmeye yeniden basınca ekranın değişip değişmediği buna bakılarak anlaşılır. */
    fun fingerprint(reading: Reading): String =
        TextMatch.normalize(groups(reading).flatMap { it.paragraphs }.joinToString(" ") { IconText.plain(it) })

    /**
     * İki iz aynı ekranın mı. Çeviriler ekrandayken düğmeye yeniden basmak önceden hep onları kaldırıyordu: telefonda
     * başka bir sohbete geçip basınca yeni sohbet çevrilmiyor, ekran boşalıyordu. Artık ekran değiştiyse yeni kare
     * çevrilir, değişmediyse çeviriler kalkar (Mac ve Windows ile aynı).
     */
    fun isSameScreen(a: String, b: String): Boolean =
        if (a.isEmpty() || b.isEmpty()) a == b else TextMatch.isSimilar(a, b, SAME_SCREEN_SIMILARITY)

    /** Simgeli grupların simgeleri [frame]'den kesilir; kare yoksa gruplar olduğu gibi kalır. */
    internal fun withImages(groups: List<Group>, frame: GrayFrame?): List<Group> {
        if (frame == null) return groups
        return groups.map { group ->
            val icons = group.icons
            if (icons == null) group else group.copy(icons = icons.map { ButtonIcons.withImages(it, frame) })
        }
    }

    /** Grubun gösterilecek çevirisi; çevirisi aslıyla aynıysa (ad, sayı, zaten Türkçe yazı) null. */
    internal fun item(group: Group, prepared: List<IconText.Protected>, translations: List<String>, keepUnchanged: Boolean = false): Item? {
        var changed = false
        val texts = mutableListOf<String>()
        val slots = mutableListOf<IconSlot>()
        for ((i, paragraph) in group.paragraphs.withIndex()) {
            val translation = translations.getOrElse(i) { "" }.trim()
            val text = if (translation.isEmpty()) IconText.indexed(paragraph, slots.size)
            else IconText.restore(translation, prepared[i].names, slots.size)
            changed = changed ||
                !TextMatch.isSimilar(TextMatch.normalize(IconText.plain(paragraph)), TextMatch.normalize(IconText.plain(text)), 0.90)
            texts.add(text)
            group.icons?.getOrNull(i)?.let { slots.addAll(it) }
        }
        if (!changed && !keepUnchanged) return null
        val rendered = IconText.render(texts.joinToString("\n"), slots)
        return Item(group.paragraphs.joinToString("\n") { IconText.plain(it) }, rendered.text, group.box, group.lineHeight,
            rendered.icons.takeIf { it.isNotEmpty() }, unchanged = !changed, phone = group.phone, rows = group.rows)
    }

    /**
     * Satırları gruplara toplar. Kumanda ipuçları ve yazı tanıma çöpleri atılır; harfi olmayan ya da tek harfli satırlar
     * ("23m", "9", "+") göstergedir, çevrilmez. Bir satır, üstündeki satırın hemen altındaysa, yatayda onunla üst üste
     * biniyorsa ve yazı boyu benziyorsa o gruba katılır; küçük harfle başlayan satır üstteki bitmemiş cümleye katılır
     * ([continues]). Gruplar yukarıdan aşağı; en çok [MAX_GROUPS], en çok yazısı olanlar.
     */
    fun groups(
        reading: Reading, keepPrompts: Boolean = false, keepIdentifiers: Boolean = false, wholeScreen: Boolean = false,
        handset: ScreenPhoneCard.Handset? = null,
        frame: GrayFrame? = null,
        /** [frame]'in (x, y) noktasının rengi (0xRRGGBB); renksiz simge denetimi için ([ButtonIcons.isColourless]). */
        color: ((Int, Int) -> Int)? = null,
    ): List<Group> {
        var marked = (if (wholeScreen) Reading(reading.lines.map(::repaired)) else reading).withButtonIcons()
        // "Ekranı çevir": tuş çubukları atılmaz, etiketlerine bölünür ([promptPieces]); fiyatlar düzelir ([PriceText.repair]).
        if (wholeScreen) {
            marked = Reading(marked.lines.flatMap { line ->
                if (line.icons.isNullOrEmpty() && line.box != null && (ButtonPrompts.isPrompt(line.text) || hasWideGap(line))) promptPieces(line)
                else listOf(line)
            })
            // Menü şeridinin sekmeleri ("JASON & LUCIA   MAP   BRIEF") tek satır okunsa da ayrı ayrı çevrilir (#859).
            val aspect = if (frame != null && frame.height > 0) frame.width.toDouble() / frame.height else 16.0 / 9.0
            marked = Reading(marked.lines.flatMap { menuPieces(it, aspect, frame) })
        }
        // Kare varsa yalnız aksi halde atılacak kumanda ipuçlarında simgeye görüntüden bakılır. "Ekranı çevir": satır
        // ucundaki kısa parça ("RECENTER 13", "EXIT O") okunmuş bir tuş simgesi olabilir; görüntüden renksiz simge olarak
        // doğrulanırsa simge olur, kutunun dışında kalır (#860; Mac ve Windows ile aynı).
        if (frame != null) {
            marked = Reading(marked.lines.map { line ->
                when {
                    !line.icons.isNullOrEmpty() -> line
                    ButtonPrompts.isPrompt(line.text) -> ButtonIcons.markFree(line, frame, color)
                    wholeScreen && hasShortEdge(line) -> ButtonIcons.markFree(line, frame, color, monochrome = true)
                    else -> line
                }
            })
        }
        val lines = (if (keepPrompts) marked else marked.withoutButtonPrompts()).withoutOcrNoise(keepIdentifiers).lines
            .filter { it.box != null && ScreenText.isWords(it.text) }
            // Saat ve sayaç ("12:00 pm") çevrilmez.
            .filter { !wholeScreen || !isClock(it.text) }
            .sortedWith(compareBy<TextLine>({ it.box!!.top }, { it.box!!.left }))
        // "Ekranı çevir": haritanın görev kartı kendi parçalarına ayrılır (başlık, açıklama, ayrıntılar; [MissionCard]).
        // Aynı yazının iki okunuşu tek satır kalır; satırın başındaki/sonundaki simge kutunun dışında kalır (#827).
        // Telefonun satırları girmez: eğik telefonda kutuları bilerek üst üste.
        val plain = { all: List<TextLine> ->
            // "Ekranı çevir"de satırın başındaki/sonundaki kumanda simgesi kutunun dışında kalır, görünür (#860).
            val kept = withoutDuplicateLines(all.map(::withoutEdgeMarks).map { if (wholeScreen) withoutEdgeIcons(it) else it })
            if (wholeScreen) withMissionCards(kept, frame) else groupLines(kept)
        }
        // [handset]: karede GTA 6 telefonu varsa ekranındaki satırlar ayrı gruplanır ([PhoneChat]: balon, başlık, liste).
        if (handset != null) {
            val (onPhone, rest) = lines.partition { PhoneChat.onScreen(handset.flat(it.box!!)) }
            // Süzülmemiş satırlar da gider: harfsiz hava durumu satırı ("76°") ana ekranı belli eder.
            val raw = reading.lines.filter { line -> line.box?.let { PhoneChat.onScreen(handset.flat(it)) } ?: false }
            if (onPhone.isNotEmpty()) return plain(rest) + PhoneChat.groups(onPhone, handset, raw)
        }
        return plain(lines)
    }

    /**
     * Satırlardaki görev kartları kendi gruplarıyla (kare varsa yalnız düz panelin üstündekiler), kalanlar her zamanki
     * gibi. Kart tanınmadan başlık açıklamanın ilk cümlesine katılıyor, beş-altı sözcüklük başlık cümleyle birlikte
     * çevriliyordu.
     */
    internal fun withMissionCards(lines: List<TextLine>, frame: GrayFrame?): List<Group> {
        val cards = MissionCard.find(lines).filter { card -> frame == null || MissionCard.onPanel(frame, card.all.map { lines[it] }) }
        val taken = cards.flatMap { it.all }.toSet()
        val rest = lines.indices.filter { it !in taken }.map { lines[it] }
        return (labelColumns(groupLines(rest), rest) + cards.flatMap { MissionCard.groups(it, lines) }).sortedBy { it.box.top }
    }

    /** Kısa etiket satırı: en çok bu kadar sözcük (otomatik ekran yazısıyla aynı). */
    const val LABEL_WORDS = 5

    /**
     * Bütün satırları kısa BÜYÜK HARFLİ etiket olan grup (tuş ipuçları sütunu, menü listesi) satır satır gruptur: her
     * etiket kendi kutusunda, kendi yerinde çevrilir. Önceden sütun tek kutu oluyor, sağındaki tuş simgelerini de
     * örtüyordu (#860).
     */
    internal fun labelColumns(groups: List<Group>, lines: List<TextLine>): List<Group> = groups.flatMap { group ->
        val own = lines.filter { line ->
            val box = line.box!!
            val x = (box.left + box.right) / 2
            val y = (box.top + box.bottom) / 2
            x >= group.box.left - 1e-6 && x <= group.box.right + 1e-6 && y >= group.box.top - 1e-6 && y <= group.box.bottom + 1e-6
        }
        val labels = own.size > 1 && own.all { line ->
            val plain = IconText.plain(line.text)
            plain.split(Regex("\\s+")).count { it.isNotEmpty() } <= LABEL_WORDS && plain.any { it.isLetter() } &&
                plain.none { it.isLowerCase() }
        }
        if (!labels) listOf(group) else own.map { line ->
            val icons = ScreenText.paragraphIcons(listOf(line))
            val box = line.box!!
            Group(ScreenText.paragraphs(listOf(line)), box, box.bottom - box.top, if (icons.any { it.isNotEmpty() }) icons else null)
        }
    }

    /** Saat ya da sayaç ("12:00 pm", "x3"): harfi yok ya da harflerinden çok rakamı var, fiyat değil. Çevrilmez. */
    fun isClock(text: String): Boolean {
        val plain = IconText.plain(text)
        val letters = plain.count { it.isLetter() }
        val digits = plain.count { it.isDigit() }
        if (letters != 0 && digits * 2 <= letters) return false
        return plain.split(Regex("\\s+")).none { PriceText.isMoney(it) }
    }

    /** Satırın ilk ya da son parçası en çok iki harflik (okunmuş tuş simgesi olabilir: "13", "O", "®"). */
    internal fun hasShortEdge(line: TextLine): Boolean {
        val parts = line.text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return parts.size >= 2 && (parts.last().length <= 2 || parts.first().length <= 2)
    }

    // --- Menü şeridi, özel adlar, kenardaki tuş simgesi (#856, #859, #860) ---

    /**
     * Menü şeridinde sekmelerin arası: satır yüksekliğinin bu katından geniş boşluk sözcük arası değildir (sözcük arası
     * yazı boyunun üçte biri kadardır). GTA 6 haritasının üst şeridi "JASON & LUCIA   MAP   BRIEF   PROGRESS" tek satır
     * okunuyor, sekmeler tek cümle sanılıp "LUCIA HARİTASI KISA İLERLEME RAPORU" diye çevriliyordu.
     */
    const val MENU_GAP = 0.9

    /**
     * BÜYÜK HARFLİ satırdaki geniş boşluklar ([MENU_GAP]) ayrı sekmelerdir: her sekme kendi satırı, kutusu kendi yazısı.
     * Kare verilirse boşluklar görüntüden bulunur ([inkPieces]; yazı tanımanın sözcük kutuları boşluğu da kapsıyor), yoksa
     * sözcük yerlerinden. Satır büyük harf değilse dokunulmaz. [aspect]: kutuların oranlandığı görüntünün
     * genişlik/yükseklik oranı. İki harfi olmayan parça atılır.
     *
     * Sekme şeridinin uçlarındaki geçiş simgeleri (L1/R1, #1372): yazı tanıma L1'i çoğu karede "JASON & LUCIA" ile aynı
     * satıra katıyordu; simgeli satıra hiç dokunulmadığı için şerit tek cümle çevriliyordu ("JASON LUCIA HARİTASI ÖZET").
     * Simgeler yalnız uçlardaysa önce ayrılır ([withoutEdgeIcons]), kalan yazı bölünür; bölünmezse satır simgeleriyle
     * olduğu gibi kalır. Yazının arasında simge olan satıra dokunulmaz. Mac ve Windows aynı.
     */
    fun menuPieces(line: TextLine, aspect: Double = 16.0 / 9.0, frame: GrayFrame? = null): List<TextLine> {
        if (!line.icons.isNullOrEmpty()) {
            val trimmed = withoutEdgeIcons(line)
            if (!trimmed.icons.isNullOrEmpty() || ButtonIcons.MARKER in trimmed.text || trimmed.text == line.text) return listOf(line)
            val pieces = menuPieces(trimmed, aspect, frame)
            return if (pieces.size >= 2) pieces else listOf(line)
        }
        val box = line.box ?: return listOf(line)
        if (!TextStyleSampler.isUpper(line.text) ||
            line.text.split(Regex("\\s+")).count { it.isNotEmpty() } < 2) return listOf(line)
        val limit = textHeight(line) * MENU_GAP / maxOf(0.1, aspect)
        if (frame != null) return inkPieces(line, frame, limit)
        val words = line.words
        if (words == null || words.size < 2) return listOf(line)
        val runs = mutableListOf(mutableListOf(words[0]))
        for (word in words.drop(1)) {
            if (word.box.left - runs.last().last().box.right > limit) runs.add(mutableListOf())
            runs.last().add(word)
        }
        if (runs.size < 2) return listOf(line)
        return runs.filter { run -> run.sumOf { w -> w.text.count { it.isLetter() } } >= 2 }.map { run ->
            val span = run.drop(1).fold(run[0].box) { all, word -> all.union(word.box) }
            TextLine(run.joinToString(" ") { it.text }, TextBox(span.left, box.top, span.right, box.bottom), run, confidence = line.confidence)
        }
    }

    /**
     * Satırın yazı boyu: sözcük kutularının ortanca yüksekliği (satır kutusundan büyük değil). Satıra katılan simge
     * harflerden uzundur; satır kutusunu, onunla sekme boşluğu eşiğini de büyütüyordu (#1372). Mac ve Windows aynı.
     */
    internal fun textHeight(line: TextLine): Double {
        val box = line.box ?: return 0.0
        val full = box.bottom - box.top
        val heights = (line.words ?: emptyList()).map { it.box.bottom - it.box.top }.filter { it > 0 }.sorted()
        return if (heights.isEmpty()) full else minOf(full, heights[heights.size / 2])
    }

    /**
     * Satırın yazı sütunları: kutudaki her sütunda zeminden (kutunun ortanca parlaklığı) belirgin ayrılan nokta var mı;
     * [gap]'ten geniş boş aralıklar yazıyı parçalara böler. Parçalar kareye oranla (sol, sağ).
     */
    internal fun inkSpans(frame: GrayFrame, box: TextBox, gap: Double): List<Pair<Double, Double>> {
        if (!frame.isValid) return emptyList()
        val fw = frame.width.toDouble()
        val fh = frame.height.toDouble()
        val x0 = maxOf(0.0, box.left) * fw
        val y0 = maxOf(0.0, box.top) * fh
        val rw = (minOf(1.0, box.right) - maxOf(0.0, box.left)) * fw
        val rh = (minOf(1.0, box.bottom) - maxOf(0.0, box.top)) * fh
        if (rw < 8 || rh < 4) return emptyList()
        val columns = Math.round(rw).toInt().coerceIn(8, 800)
        val rows = 12
        // Ara değerlemesiz örnek: her hücrenin ortasındaki nokta.
        val luma = IntArray(columns * rows)
        for (y in 0 until rows) for (x in 0 until columns) {
            val px = (x0 + (x + 0.5) * rw / columns).toInt().coerceIn(0, frame.width - 1)
            val py = (y0 + (y + 0.5) * rh / rows).toInt().coerceIn(0, frame.height - 1)
            luma[y * columns + x] = frame.at(px, py)
        }
        val median = luma.sorted()[luma.size / 2]
        val ink = BooleanArray(columns) { x -> (0 until rows).any { y -> kotlin.math.abs(luma[y * columns + x] - median) > 60 } }
        val step = (box.right - box.left) / columns
        val blank = maxOf(1, kotlin.math.ceil(gap / maxOf(1e-9, step)).toInt())
        val spans = mutableListOf<Pair<Int, Int>>()
        var x = 0
        while (x < columns) {
            if (!ink[x]) { x++; continue }
            var end = x
            var run = 0
            var probe = x + 1
            while (probe < columns) {
                if (ink[probe]) { end = probe; run = 0 } else { run++; if (run > blank) break }
                probe++
            }
            spans.add(x to end)
            x = end + 1
        }
        return spans.map { (a, b) -> (box.left + a * step) to (box.left + (b + 1) * step) }
    }

    /**
     * Menü satırının sekmeleri: görüntüdeki geniş boşluklardan ([inkSpans]) bölünür. Sözcükler sırasıyla parçalara
     * dağıtılır: her parçanın harf sayısı payı genişlik payına en yakın olacak biçimde. Parça sayısı sözcüklerden çoksa
     * dokunulmaz.
     */
    internal fun inkPieces(line: TextLine, frame: GrayFrame, gap: Double): List<TextLine> {
        val box = line.box ?: return listOf(line)
        val spans = inkSpans(frame, box, gap)
        val words = line.text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (spans.size < 2 || words.size < spans.size) return listOf(line)
        val k = spans.size
        val n = words.size
        val widths = spans.map { it.second - it.first }
        val totalWidth = widths.sum()
        val sizes = words.map { it.length.toDouble() }
        val totalSize = sizes.sum() + (n - k)
        // En iyi bölme: best[i][j] ilk i sözcük j parçada; parçanın payı sözcükleri ve aralarındaki boşluklar.
        val best = Array(n + 1) { DoubleArray(k + 1) { Double.POSITIVE_INFINITY } }
        val from = Array(n + 1) { IntArray(k + 1) }
        best[0][0] = 0.0
        for (i in 1..n) for (j in 1..minOf(i, k)) for (start in (j - 1) until i) {
            if (best[start][j - 1] == Double.POSITIVE_INFINITY) continue
            val size = (start until i).sumOf { sizes[it] } + (i - start - 1)
            val cost = best[start][j - 1] + kotlin.math.abs(size / totalSize - widths[j - 1] / totalWidth)
            if (cost < best[i][j]) {
                best[i][j] = cost
                from[i][j] = start
            }
        }
        val bounds = ArrayDeque<Int>()
        var i = n
        for (j in k downTo 1) {
            bounds.addFirst(from[i][j])
            i = from[i][j]
        }
        bounds.addLast(n)
        return (0 until k).mapNotNull { j ->
            val text = words.subList(bounds[j], bounds[j + 1]).joinToString(" ")
            if (text.count { it.isLetter() } < 2) null
            else TextLine(text, TextBox(spans[j].first, box.top, spans[j].second, box.bottom), confidence = line.confidence)
        }
    }

    /**
     * Oyunun logosu ve stilize başlığı çevrilmez: yalnız Roma rakamı ("VI"), oyun adı ("Grand Theft Auto", "GTA VI",
     * "Rockstar Games"). Önceden PS5 ana ekranındaki "Grand Theft Auto VI" "araba hırsızlığı." oluyordu (Sinan Bey,
     * beta.93; Mac ve Windows ile aynı).
     */
    internal fun isTitleMark(text: String): Boolean {
        val words = text.uppercase(java.util.Locale.ROOT).split(Regex("[\\s:\\-]+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return false
        fun isRoman(word: String) = romanNumeral.matches(word)
        if (words.all(::isRoman)) return true
        return words.filter { !isRoman(it) }.joinToString(" ") in titleMarks
    }

    private val romanNumeral = Regex("^(?=[IVX]+$)X{0,3}(IX|IV|V?I{0,3})$")
    private val titleMarks = setOf("GRAND THEFT AUTO", "GTA", "ROCKSTAR GAMES", "ROCKSTAR")

    /**
     * Yalnız özel adlardan oluşan yazı ("JASON & LUCIA", "Bonnie & Clyde"): "&" ile bağlı, her biri bir iki sözcüklük,
     * büyük harfle başlayan adlar. Çevirmene gitmez; çevirisi aslıdır (kutusu çizilmez, özgün yazı görünür kalır).
     */
    /**
     * Haritadaki yer adı ("Peregrine Bay", "Key Lento") ve soluk okunan parçası ("ne Bay"): iki-üç sözcük, yalnız harf, son
     * ya da ilk sözcük yer türü, BÜYÜK HARFLİ değil; çevrilmez (Mac/Windows ile aynı).
     */
    fun isPlaceName(text: String): Boolean {
        val words = text.split(' ').filter { it.isNotEmpty() }
        if (words.size !in 2..3 || TextStyleSampler.isUpper(text)) return false
        if (!words.all { w -> w.all { it.isLetter() || it in "'’-." } && w.any { it.isLetter() } }) return false
        if (!words.drop(1).all { it.first().isUpperCase() }) return false
        return words.last() in placeWords || words.first() in placeWords
    }

    private val placeWords = setOf("Bay", "Key", "Keys", "Island", "Islands", "Beach", "Harbor", "Harbour", "Lake", "River", "Creek", "Cove", "Reef", "Springs", "Heights", "Hills", "Park", "Marina", "Inlet", "Lagoon", "Everglades", "Glades", "Shores", "Shore")

    /**
     * Ürün/marka adı ("HARBOR LAGER", "Glacier Water", "VANILLA SHAKE"): iki-üç sözcük, yalnız harf, her sözcük büyük harfle
     * başlar, son sözcük ürün türü, hiçbiri eylem ya da bağlaç/edat değil. Çevrilmez; etkileşim listesinde de olduğu gibi
     * kalır (Sinan Bey beta.101; Mac/Windows ile aynı).
     */
    fun isProductName(text: String): Boolean {
        val body = if (text.isNotEmpty() && text.last() in "!?") text.dropLast(1) else text
        val words = body.split(' ').filter { it.isNotEmpty() }
        if (words.size !in 2..3) return false
        if (!words.all { w -> w.any { it.isLetter() } && w.all { it.isLetter() || it in "'’-&" } && w.first { it.isLetter() }.isUpperCase() }) return false
        val upper = words.map { it.uppercase(java.util.Locale.ROOT) }
        return upper.last() in productWords && upper.none { it in productStops }
    }

    private val productWords = setOf("BEER", "LAGER", "ALE", "STOUT", "CIDER", "WINE", "VODKA", "WHISKEY", "WHISKY", "RUM", "GIN", "TEQUILA", "BOURBON", "WATER", "SODA", "COLA", "POP", "JUICE", "LEMONADE", "SHAKE", "SMOOTHIE", "MILK", "COFFEE", "TEA", "CHIPS", "CRISPS", "CEREAL")

    private val productStops = setOf("DRINK", "TAKE", "EAT", "OPEN", "CLOSE", "BUY", "SELL", "GRAB", "USE", "PICK", "GET", "PUT", "DROP", "GIVE", "POUR", "SIP", "CHUG", "ORDER", "MAKE", "COOK", "CHECK", "LOOK", "INSPECT", "EXAMINE", "STEAL", "THROW", "SHARE", "OFFER", "FILL", "A", "AN", "THE", "OF", "SOME", "MORE", "NO", "AND", "OR", "WITH", "TO", "FOR", "YOUR", "MY", "ANY")

    fun keepsNames(text: String): Boolean {
        val plain = IconText.plain(text).trim()
        if (isTitleMark(plain) || isPlaceName(plain) || isProductName(plain) || isNamePair(plain)) return true
        val parts = plain.split(" & ")
        if (parts.size < 2) return false
        // BÜYÜK HARFLİ yazıda her ad tek sözcük: "JASON & LUCIA MAP" (sekmeler tek satır okununca) ad değildir.
        val most = if (TextStyleSampler.isUpper(IconText.plain(text))) 1 else 2
        return parts.all { part ->
            val words = part.split(' ').filter { it.isNotEmpty() }
            words.size in 1..most && words.all { word ->
                word.count { it.isLetter() } >= 2 && word.all { it.isLetter() || it in "'’-." } &&
                    word.first().isUpperCase() &&
                    word.lowercase() !in com.couchsubs.mobile.translation.SpeakerNameGuard.NOT_NAMES
            }
        }
    }

    /**
     * "&" okunmamış karakter adı çifti ("JASON LUCIA", #1372): yazı tanıma sekme şeridindeki "&"yi çoğu karede okumuyor,
     * ad çifti özel ad sayılmayıp motora gidiyordu. Tam iki sözcük, ikisi de bilinen karakter adı ([characterNames]);
     * büyük/küçük harf fark etmez. Mac ve Windows aynı.
     */
    fun isNamePair(text: String): Boolean {
        val words = text.split(' ').filter { it.isNotEmpty() }
        return words.size == 2 && words.all { it.uppercase(java.util.Locale.ROOT) in characterNames }
    }

    /** Ad çifti olarak tanınan oyun karakterleri (GTA 6 ve GTA V'in oynanabilir karakterleri). */
    private val characterNames = setOf("JASON", "LUCIA", "MICHAEL", "FRANKLIN", "TREVOR")

    private const val ICON_BRACKETS = " ()[]"

    /**
     * Menü satırının başındaki görev simgesi (#1365, GTA 6 haritasının görev listesi: daire içinde "KM", "KK", "W"): yazı
     * tanıma simgeyi satırın ilk sözcüğü okuyor ("KM Collect Chemicals for Kyle"), simge çeviriye giriyor ("KM, Kyle için
     * kimyasalları topluyor") ve kutu simgenin üstünü örtüyordu. Baştaki bir-iki BÜYÜK harflik sözcük, ardında büyük harfle
     * başlayan ve küçük harf taşıyan (BÜYÜK HARFLİ olmayan) en az iki sözcük varsa simgedir: atılır, kutu ikinci sözcükten
     * başlar. Gerçek kısa sözcükler ([BADGE_WORDS]: "A", "I", "OK", "TV", "DJ"…) dokunulmaz. Mac/iPhone ve Windows aynı.
     */
    fun withoutBadge(line: TextLine): TextLine {
        val tokens = line.text.split(' ').filter { it.isNotEmpty() }
        if (tokens.size < 3) return line
        val head = tokens[0]
        if (head.length !in 1..2 || !head.all { it.isLetter() && it.isUpperCase() } || head in BADGE_WORDS) return line
        val rest = tokens.drop(1)
        if (rest[0].first().isUpperCase().not() || rest.joinToString("").none { it.isLowerCase() }) return line
        val trimmed = line.copy(text = rest.joinToString(" "))
        val box = line.box ?: return trimmed
        val given = line.words
        val measured = given != null && given.size == tokens.size && given[0].text == head
        val words = if (measured) given!! else ButtonIcons.estimate(line.text, box)
        if (words.size < 2) return trimmed
        return trimmed.copy(box = TextBox(words[1].box.left, box.top, box.right, box.bottom),
            words = if (measured) words.drop(1) else null)
    }

    /** Satır başında simge sanılmayacak kısa BÜYÜK harfli sözcükler. */
    internal val BADGE_WORDS: Set<String> = setOf("A", "I", "O", "OK", "TV", "DJ", "UK", "US", "UN", "LA", "NY", "MR", "DR", "MS",
        "ST", "PS", "AI", "HQ", "ID", "EU", "OF", "IN", "ON", "TO", "MY", "NO", "GO", "UP")

    /**
     * Satırın başındaki ya da sonundaki kumanda simgesi (kareden tanınmış simge ya da okunmuş tuş adı: "RECENTER L3",
     * "EXIT (○)") çeviriye girmez; kutu yalnız yazının sözcüklerini kapsar, simge ekranda görünür kalır. Önceden çeviri
     * kutusu simgenin üstünü örtüyordu ("Ortala" L3'ü kapatıyordu, #860). Sözcük yerleri bilinmiyorsa harf sayısına göre
     * kestirilir. Geriye tuş adı olmayan iki harfli bir sözcük kalmayacaksa (yalnız tuştan oluşan satır) dokunulmaz.
     */
    fun withoutEdgeIcons(line: TextLine): TextLine {
        val box = line.box ?: return line
        val original = line.text.trim()
        var text = original
        val icons = (line.icons ?: emptyList()).toMutableList()
        if (text.count { it == ButtonIcons.MARKER } != icons.size) return line
        var left = box.left
        var right = box.right
        fun stripped() = text.trim { it in ICON_BRACKETS }
        // Kareden tanınmış simgeler (yazıda imle).
        while (icons.isNotEmpty() && stripped().lastOrNull() == ButtonIcons.MARKER) {
            text = stripped().dropLast(1).trim { it in ICON_BRACKETS }
            right = minOf(right, icons.removeAt(icons.size - 1).box.left)
        }
        while (icons.isNotEmpty() && stripped().firstOrNull() == ButtonIcons.MARKER) {
            text = stripped().drop(1).trim { it in ICON_BRACKETS }
            left = maxOf(left, icons.removeAt(0).box.right)
        }
        var words = line.words
        if (text == original) {
            // Okunmuş tuş adı ("L3", "(R3)").
            if (text.contains(ButtonIcons.MARKER)) return line
            val given = line.words
            val measured = !given.isNullOrEmpty() && given.joinToString(" ") { it.text } == text
            val list = (if (measured) given!! else ButtonIcons.estimate(text, box)).toMutableList()
            while (list.size > 1 && ButtonIcons.isButtonName(list.last().text)) right = minOf(right, list.removeAt(list.size - 1).box.left)
            while (list.size > 1 && ButtonIcons.isButtonName(list.first().text)) left = maxOf(left, list.removeAt(0).box.right)
            text = list.joinToString(" ") { it.text }
            words = if (measured) list else null
        } else {
            words = line.words?.filter { it.box.left >= left - 1e-6 && it.box.right <= right + 1e-6 }
        }
        if (text == original || right <= left) return line
        val hasWord = text.split(Regex("\\s+")).any { word -> word.count { it.isLetter() } >= 2 && !ButtonIcons.isButtonName(word) }
        if (!hasWord) return line
        return line.copy(text = text, icons = icons.takeIf { it.isNotEmpty() }, words = words?.takeIf { it.isNotEmpty() },
            box = TextBox(left, box.top, right, box.bottom))
    }

    /** Kutuları bilinen, süzülmüş ve sıralı satırları gruplar. */
    internal fun groupLines(lines: List<TextLine>): List<Group> {
        val groups = mutableListOf<MutableList<TextLine>>()
        for (line in lines) {
            var index = groups.indexOfLast { belongs(line.box!!, it.last().box!!) }
            if (index >= 0 && (bridgesColumns(groups[index].last().box!!, line.box!!, lines)
                || bridgesColumns(line.box!!, groups[index].last().box!!, lines))) index = -1
            // Küçük harfle başlayan satır, üstündeki bitmemiş cümlenin devamıdır: satır aralığı biraz geniş ya da yanında
            // başka bir yazı olsa da o gruba katılır. Ayrı grup olunca yarım cümle tek başına çevriliyor ya da grup
            // sınırına takılıp hiç çevrilmiyordu; bilgi kutusunun son satırı İngilizce kalıyordu.
            if (index < 0) index = groups.indexOfLast { continues(line, it.last()) }
            if (index >= 0) groups[index].add(line) else groups.add(mutableListOf(line))
        }
        return busiest(groups).map { group ->
            val heights = group.map { it.box!!.bottom - it.box!!.top }.sorted()
            val box = group.drop(1).fold(group[0].box!!) { total, line -> total.union(line.box!!) }
            val icons = ScreenText.paragraphIcons(group)
            Group(ScreenText.paragraphs(group), box, heights[heights.size / 2], if (icons.any { it.isNotEmpty() }) icons else null,
                rows = rows(group))
        }
    }

    /** Satırların kaç ayrı satır olduğu: yazı tanıma aynı satırı iki parça okuyabilir (yan yana parçalar tek satırdır). */
    internal fun rows(lines: List<TextLine>): Int {
        val rows = mutableListOf<TextBox>()
        for (box in lines.mapNotNull { it.box }) {
            if (rows.none { other ->
                    min(other.bottom, box.bottom) - max(other.top, box.top) >= 0.5 * min(other.bottom - other.top, box.bottom - box.top)
                }) rows.add(box)
        }
        return max(1, rows.size)
    }

    /** Satırın ve sözcüklerinin fiyat düzeltmesi (uzunluk değişmez). */
    internal fun repaired(line: TextLine): TextLine =
        line.copy(text = PriceText.repair(line.text), words = line.words?.map { it.copy(text = PriceText.repair(it.text)) })

    /**
     * Tuş çubuğunun etiketleri: tuş adları ve simgeleri ("R1", "△", okunmuş "X"/"O"), fiyatlar ("$10") ve harfsiz
     * parçalar ayırıcıdır, çeviriye girmez; aralarındaki her sözcük öbeği ayrı satır olur, kutusu sözcüklerinin yeri.
     * Sözcük yerleri biliniyorsa geniş boşluk da ayırır ("TIP $10   ORDER   BARTENDER"). İki harfi olmayan öbek atılır.
     */
    internal fun promptPieces(line: TextLine): List<TextLine> {
        val box = line.box ?: return listOf(line)
        val measured = !line.words.isNullOrEmpty()
        val words = if (measured) line.words!! else ButtonIcons.estimate(line.text, box)
        val gap = if (measured) wideGap(words) else Double.POSITIVE_INFINITY
        val runs = mutableListOf(mutableListOf<TextWord>())
        for (word in words) {
            if (isPromptSeparator(word.text)) {
                runs.add(mutableListOf())
                continue
            }
            val last = runs.last().lastOrNull()
            if (last != null && word.box.left - last.box.right > gap) runs.add(mutableListOf())
            runs.last().add(word)
        }
        return runs.filter { run -> run.sumOf { word -> word.text.count { it.isLetter() } } >= 2 }.map { run ->
            val span = run.drop(1).fold(run[0].box) { all, word -> all.union(word.box) }
            TextLine(run.joinToString(" ") { it.text }, TextBox(span.left, box.top, span.right, box.bottom), run, confidence = line.confidence)
        }
    }

    /** Sözcüklerin arasında bu kadar boşluk (harf başına ortalama genişliğin üç katı) ayrı seçenek demektir. */
    private fun wideGap(words: List<TextWord>): Double {
        val chars = words.sumOf { it.text.length }
        return if (chars == 0) Double.POSITIVE_INFINITY else words.sumOf { it.box.right - it.box.left } / chars * 3
    }

    /** Sözcük yerleri bilinen satırda aynı satıra düşmüş ayrı seçenekler var mı (geniş boşluk). */
    internal fun hasWideGap(line: TextLine): Boolean {
        val words = line.words ?: return false
        if (words.size < 2) return false
        val gap = wideGap(words)
        return words.zipWithNext().any { (a, b) -> b.box.left - a.box.right > gap }
    }

    /** Tuş çubuğunda çeviriye girmeyen parça: tuş adı/simgesi, tek harf (okunmuş simge), fiyat ya da harfsiz parça. */
    internal fun isPromptSeparator(word: String): Boolean {
        val core = word.trim('(', ')', '[', ']', '{', '}', '<', '>')
        // "&" sekme adının parçasıdır ("JASON & LUCIA"), ayırıcı değil.
        return ButtonIcons.isButtonName(core) || PriceText.isMoney(core) || (core.none { it.isLetter() } && core != "&") ||
            (core.length == 1 && core != "a")
    }

    /**
     * Kalabalık ekranda en çok yazısı olan [MAX_GROUPS] grup, yukarıdan aşağı sırasıyla. Önceden en üstteki gruplar
     * alınıyordu: menü ve gösterge etiketleri sınırı doldurunca ekranın alt yarısındaki bilgi kutusu hiç çevrilmiyordu.
     */
    private fun busiest(groups: List<List<TextLine>>): List<List<TextLine>> {
        if (groups.size <= MAX_GROUPS) return groups
        val letters = groups.map { group -> group.sumOf { line -> line.text.count { it.isLetter() } } }
        return groups.indices.sortedWith(compareByDescending<Int> { letters[it] }.thenBy { it })
            .take(MAX_GROUPS).sorted().map { groups[it] }
    }

    /**
     * Alt satır, üstteki satırın bitmemiş cümlesini sürdürüyor: küçük harfle başlıyor, üstteki cümle sonu işaretiyle
     * bitmiyor, yazı boyu benzer, yatayda üst üste ve arada satır yüksekliğinin bir buçuk katından az boşluk var.
     */
    private fun continues(lower: TextLine, upper: TextLine): Boolean {
        val first = lower.text.firstOrNull { it.isLetter() } ?: return false
        if (!first.isLowerCase() || SubtitleStabilizer.endsSentence(upper.text)) return false
        val below = lower.box ?: return false
        val above = upper.box ?: return false
        val a = above.bottom - above.top
        val b = below.bottom - below.top
        if (maxOf(a, b) > minOf(a, b) * 1.6) return false
        if (below.top - above.bottom >= maxOf(a, b) * 1.5 || below.top < above.top) return false
        val overlap = minOf(below.right, above.right) - maxOf(below.left, above.left)
        val narrower = minOf(below.right - below.left, above.right - above.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    // Geniş başlık/alt satır iki bağımsız sütundan birine katılmasın. Filtrelenmiş OCR satırlarına bakılır.
    private fun bridgesColumns(wide: TextBox, column: TextBox, lines: List<TextLine>): Boolean = lines.any { line ->
        val peer = line.box!!
        if (minOf(column.right, peer.right) > maxOf(column.left, peer.left)) return@any false
        val rowOverlap = minOf(column.bottom, peer.bottom) - maxOf(column.top, peer.top)
        if (rowOverlap <= 0 || rowOverlap < minOf(column.bottom - column.top, peer.bottom - peer.top) * 0.5) return@any false
        (belongs(column, wide) && belongs(peer, wide)) || (belongs(wide, column) && belongs(wide, peer))
    }

    /** Alt satır üsttekinin hemen altında (arada satır yüksekliğinin %80'inden az), yatayda onunla üst üste ve yazı boyu benzer. */
    private fun belongs(lower: TextBox, upper: TextBox): Boolean {
        val a = upper.bottom - upper.top
        val b = lower.bottom - lower.top
        if (maxOf(a, b) > minOf(a, b) * 1.6) return false
        if (lower.top - upper.bottom >= maxOf(a, b) * 0.8 || lower.top < upper.top) return false
        val overlap = minOf(lower.right, upper.right) - maxOf(lower.left, upper.left)
        val narrower = minOf(lower.right - lower.left, upper.right - upper.left)
        return overlap > 0 && overlap >= narrower * 0.5
    }

    /** Çevirilerin ekranda kalma süresi (ms): yazı çoksa daha uzun; düğmeye yeniden basınca hemen kalkar. */
    fun displayMilliseconds(items: List<Item>): Int =
        minOf(60000, maxOf(12000, 8000 + items.sumOf { it.translation.length } * 50))
}
