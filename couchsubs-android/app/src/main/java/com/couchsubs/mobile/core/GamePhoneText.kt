// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * Oyun telefonundaki yazının kuralları: kullanıcı adları ve etiketler çevrilmez, mesaj listesindeki kişi adları oyunda
 * kalır, balonlar düz ekran koordinatlarıyla gruplanır (Mac/iPhone GamePhoneText.swift, Windows GamePhoneText.cs).
 */
object GamePhoneText {
    private val identifier = Regex("(?<![\\p{L}\\p{N}_])[@#][\\p{L}\\p{N}_]+(?:[.-][\\p{L}\\p{N}_]+)*")
    private val chatWord = Regex("(?<![\\p{L}\\p{N}_@#.-])(?:2gether|4u)(?![\\p{L}\\p{N}_])")
    private val misreadTen = Regex("(?<![\\p{L}\\p{N}_@#])(?:IO|I0|lO|l0)(?=\\s+min(?:s|utes?)?\\b)")
    private val sections = setOf("Messages", "Suggested", "Suggestions", "Öneriler", "Mesajlar")

    /**
     * Aynı uzun mesajda (en az dokuz sözcük) yan yana iki kısa sözcükte birer harf oynamış ("it out" → "ct ocut"): yazı
     * tanıma sapmasıdır, çeviri hemen yenilenmez. Tek sözcüklük yanıtlar, eklenen/silinen sözcükler, sayılar ve
     * olumsuzluklar doğrudan işlenir (Windows GamePhoneText.HasAdjacentOcrEdits).
     */
    fun hasAdjacentOcrEdits(shown: String, next: String): Boolean {
        val before = TextMatch.normalize(shown).split(' ')
        val after = TextMatch.normalize(next).split(' ')
        if (before.size < 9 || before.size != after.size) return false
        var first = 0
        var last = before.size - 1
        while (first <= last && before[first] == after[first]) first++
        while (last > first && before[last] == after[last]) last--
        if (last != first + 1) return false
        for (i in first..last) {
            val a = before[i]
            val b = after[i]
            val length = maxOf(a.length, b.length)
            if (minOf(a.length, b.length) < 2 || length > 6 || !a.all { it.isLetter() } || !b.all { it.isLetter() } ||
                !TextMatch.isSimilar(a, b, 1.0 - 1.0 / length)) return false
        }
        return !TextMatch.addsMeaning(next, shown) && !TextMatch.addsMeaning(shown, next)
    }

    fun containsIdentifier(text: String): Boolean =
        (text.contains('@') || text.contains('#')) && identifier.containsMatchIn(text)

    fun isWrittenChatWord(token: String): Boolean =
        (token.contains('2') || token.contains('4')) && chatWord.containsMatchIn(token)

    /** İngilizce modele giden yazı: "IO min" → "10 min", "2gether" → "together", "4u" → "for you". */
    fun englishModelInput(text: String): String {
        val value = if (text.contains("min")) misreadTen.replace(text, "10") else text
        if (!isWrittenChatWord(value)) return value
        return chatWord.replace(value) { if (it.value == "2gether") "together" else "for you" }
    }

    /** Çevirideki kullanıcı adları ve etiketler özgün yazımına döner; biri kaybolmuş ya da değişmişse çeviri kullanılmaz (null). */
    fun keepIdentifiers(source: String, translation: String?): String? {
        if (translation.isNullOrEmpty() || !containsIdentifier(source)) return translation
        val names = identifier.findAll(source).map { it.value }.toMutableList()
        val result = StringBuilder(translation)
        for (match in identifier.findAll(translation).toList().reversed()) {
            val index = names.indexOfLast { it.equals(match.value, ignoreCase = true) }
            if (index < 0) return null
            result.replace(match.range.first, match.range.last + 1, names.removeAt(index))
        }
        return if (names.isEmpty()) result.toString() else null
    }

    private fun isTag(token: String): Boolean =
        (token.startsWith('@') || token.startsWith('#')) && identifier.matchEntire(token) != null

    /**
     * Sohbet listesinin bölüm başlığı ("Suggested", "Messages"); değilse null. Başlığın yanındaki simge yazı tanımada tek
     * harf ya da işaret olarak okunur ("g Suggested", "✱ Suggested", "Messages ☆"): o artık atılır. Önceden "g Suggested"
     * başlık sayılmıyor, sallanan telefonda liste her okumada bir liste bir sohbet çiziliyor, TV'de "g Önerilen" yazıyordu.
     * Simge artığı [ButtonIcons.isIconToken] ile aynı tanımdadır (tek harf ya da işaret). iPhone ile aynı.
     */
    internal fun section(text: String): String? {
        val value = text.dropWhile { !it.isLetter() }.dropLastWhile { !it.isLetter() }
        if (value in sections) return value
        val words = value.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.size !in 2..3) return null
        val heading = words.firstOrNull { it in sections } ?: return null
        val rest = words.filter { it != heading }
        if (rest.size != words.size - 1 ||
            !rest.all { it.length == 1 || ButtonIcons.isIconToken(it) || it.none { c -> c.isLetter() } }) return null
        return heading
    }

    private fun looksLikeName(text: String): Boolean {
        val label = text.takeWhile { it != '(' }.trim()
        val words = label.split(' ').filter { it.isNotEmpty() }
        if (section(label) != null || words.size !in 1..4 || !words[0][0].isUpperCase()) return false
        return words.all { word ->
            (word[0].isUpperCase() || word in setOf("de", "du", "of")) && word.all { it.isLetter() || it == '-' || it == '\'' }
        }
    }

    fun isMessagePreview(text: String): Boolean =
        text.any { it.isWhitespace() } && section(text) == null && !looksLikeName(text)

    private fun layout(line: TextLine): TextBox? = line.phoneBox ?: line.box

    private fun isContactPair(name: TextLine, preview: TextLine): Boolean {
        val label = name.text.trim()
        val lowerName = label.length in 2..18 && label.all { it.isLowerCase() }
        if (!(looksLikeName(label) || lowerName)) return false
        val a = layout(name) ?: return false
        val b = layout(preview) ?: return false
        val h = a.bottom - a.top
        return a.left > 0.1 && a.left < 0.48 && abs(a.left - b.left) <= 0.06 &&
            b.top > a.top && b.top - a.bottom < h * 0.7 && b.bottom - b.top < h * 1.8
    }

    /**
     * Sağ kenara dayanan önizlemenin kesik sonu ("after .,", "there ...") tek yazımla üç nokta olur; son sözcük
     * tamamlanmaz, yalnız noktalama düzelir.
     */
    private fun previewPunctuation(line: TextLine): TextLine {
        val box = layout(line) ?: return line
        if (box.right < 0.76) return line
        val text = line.text
        var start = text.length
        while (start > 0 && text[start - 1] in ".,„") start--
        if (text.length - start !in 2..3 || text[start] != '.') return line
        var wordEnd = start
        while (wordEnd > 0 && text[wordEnd - 1].isWhitespace()) wordEnd--
        if (wordEnd == 0 || !text[wordEnd - 1].isLetter()) return line
        if (wordEnd == start && text.endsWith("...")) return line
        return line.copy(text = text.substring(0, wordEnd) + "...")
    }

    /**
     * Çeviriye gidecek satırlar (yalnız etiketten oluşan satırlar çıkarılır). Sohbet listesi (Mesajlar ekranı: "Suggested",
     * "Messages", kişi adı ve altında son mesajın önizlemesi) tanınırsa her satır rolüyle işaretlenir ([TextLine.listRole]):
     * kişi adı (çevrilmez, kalın), önizleme (altında, çevrilir), bölüm başlığı. Liste için kişi adı sütununda en az üç
     * "ad + önizleme" çifti ve bir bölüm başlığı (ya da başlık okunamadıysa "…" ile kesilmiş en az iki önizleme) gerekir.
     * Önceden iki başlığın ikisi de okunmalıydı: sallanan telefonda biri her okumada kaçıyor, liste bir sohbet balonları bir
     * düz satırlar olarak gidip geliyordu (LG, beta.93). Kişi adları da atılıyordu; şimdi listede adıyla görünür. iPhone ile aynı.
     *
     * Liste değilse ve ekran sohbet dışıysa ([PhoneScreen.kind]: gönderi, haber, makale, hava, fitness, ayarlar, eklenti)
     * satırlar kartlarına ayrılır ([TextLine.phoneCard]); çevrilmeyen satırlar (kullanıcı adı, saat, geri düğmesi, konum,
     * fotoğraf yazısı, kaynak adı) atılır. Ana ekran kendi kurallarında kalır ([PhoneChat.isHomeScreen]). Mac/iPhone ve
     * Windows ile aynı.
     */
    fun forTranslation(reading: Reading): Reading {
        val list = listed(reading)
        if (list.lines.any { it.listRole != null } || PhoneChat.isHomeScreen(list.lines)) return list
        return screen(reading) ?: list
    }

    /** Sohbet dışı ekranın kartları ([PhoneScreen.cards]); ekran sohbetse ya da satırların düz yeri bilinmiyorsa null. */
    fun screen(reading: Reading): Reading? {
        val all = reading.lines.filter { it.phoneBox != null }
        if (all.isEmpty()) return null
        val lines = all.map { PhoneScreen.Line(it.text, it.phoneBox!!) }
        val kind = PhoneScreen.kind(lines)
        if (kind == PhoneScreen.Kind.CHAT) return null
        val result = mutableListOf<TextLine>()
        PhoneScreen.cards(lines, kind).forEachIndexed { number, card ->
            card.lines.forEachIndexed { position, index ->
                result.add(all[index].copy(listRole = ScreenPhoneCard.Role.CARD,
                    phoneCard = PhoneScreen.Mark(number, card.titled && position == 0, card.bold)))
            }
        }
        return Reading(result)
    }

    private fun listed(reading: Reading): Reading {
        val lines = reading.lines.filter { line ->
            val words = line.text.split(Regex("\\s+")).filter { it.isNotEmpty() }
            !(words.any(::isTag) && words.all { word -> isTag(word) || word.none { it.isLetterOrDigit() } })
        }.toMutableList()
        for (i in lines.indices) section(lines[i].text)?.let { lines[i] = lines[i].copy(text = it) }
        val headed = lines.any { section(it.text) != null }
        val order = lines.indices.filter { layout(lines[it]) != null }.sortedBy { layout(lines[it])!!.top }
        val names = mutableListOf<Int>()
        val previews = mutableSetOf<Int>()
        var i = 0
        while (i + 1 < order.size) {
            val name = order[i]
            val preview = order[i + 1]
            if (lines[preview].text.trim().contains(' ') && isContactPair(lines[name], lines[preview])) {
                names.add(name)
                previews.add(preview)
                i += 2
            } else {
                i += 1
            }
        }
        if (names.size < 3) return Reading(lines)
        val first = layout(lines[names.first()]) ?: return Reading(lines)
        val last = layout(lines[names.last()]) ?: return Reading(lines)
        if (last.top <= first.top) return Reading(lines)
        if (!headed && previews.count { isCut(lines[it].text) } < 2) return Reading(lines)
        val slope = (last.left - first.left) / (last.top - first.top)
        fun inColumn(line: TextLine): Boolean {
            val box = layout(line) ?: return false
            return abs(box.left - (first.left + slope * (box.top - first.top))) <= 0.06
        }
        if (!names.all { inColumn(lines[it]) }) return Reading(lines)
        // Listeyi uzun önizlemeler doğruladı: aynı satır düzenindeki "Okay" gibi tek sözcüklük yanıt da önizlemedir, ad
        // gibi göründüğü için ad sayılmaz (iPhone ile aynı).
        i = 0
        while (i + 1 < order.size) {
            val name = order[i]
            val preview = order[i + 1]
            if (inColumn(lines[name]) && name !in previews && preview !in names && !lines[preview].text.trim().contains(' ') &&
                looksLikeName(lines[preview].text) && isContactPair(lines[name], lines[preview])) {
                names.add(name)
                previews.add(preview)
                i += 2
            } else {
                i += 1
            }
        }
        return Reading(lines.indices.map { index ->
            val line = lines[index]
            when {
                index in previews -> previewPunctuation(line).copy(listRole = ScreenPhoneCard.Role.PREVIEW)
                section(line.text) != null -> line.copy(listRole = ScreenPhoneCard.Role.HEADING)
                inColumn(line) && (index in names || looksLikeName(line.text)) -> line.copy(listRole = ScreenPhoneCard.Role.CONTACT)
                else -> line.copy(listRole = ScreenPhoneCard.Role.PREVIEW)
            }
        })
    }

    /** Telefonun "…" ile kestiği önizleme ("Hey this is Joey from Coa..."). */
    fun isCut(text: String): Boolean {
        val value = text.trim()
        return value.endsWith("...") || value.endsWith("…")
    }

    private val danglingWords = setOf(
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "from", "with", "by", "about", "and", "but", "or", "so",
        "than", "my", "your", "his", "her", "its", "our", "their", "this", "that", "is", "are", "was", "were", "be", "i",
        "you", "we", "they", "it", "if", "as",
    )

    private fun isPunctuation(c: Char): Boolean = when (Character.getType(c).toByte()) {
        Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
        Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
        Character.OTHER_PUNCTUATION -> true
        else -> false
    }

    /**
     * Kesik önizlemenin çevrilecek kısmı: telefon son sözcüğü yarıda keser ("Coa...", "in t..."), yazı tanıma da üç
     * noktanın önündeki boşluğu güvenilir okumaz; son sözcük her zaman atılır, ardından kalan bağlaç/edat ("from", "in",
     * "than") da. Çeviri "..." ile biter ([cutTranslation]): önceden "Hey this is Joey from Coa..." "Selam, ben
     * Coa'dan Joey..." çevriliyor, yarım sözcük uyduruluyordu. Kesik değilse ya da geriye bir sözcük bile kalmazsa null.
     * iPhone ile aynı.
     */
    fun cutInput(text: String): String? {
        if (!isCut(text)) return null
        val value = text.trim().trimEnd('.', '…')
        val words = value.split(Regex("\\s+")).filter { it.isNotEmpty() }.toMutableList()
        if (words.size < 2) return null
        words.removeAt(words.size - 1)
        while (words.size > 1 && words.last().lowercase().trim(::isPunctuation) in danglingWords) words.removeAt(words.size - 1)
        val core = words.joinToString(" ").trimEnd(',', ';', ':', '-', '–', '—').trim()
        return if (core.any { it.isLetter() }) core else null
    }

    /**
     * Önizleme satırın sağ kenarına bu kadar yakınsa (düz ekranda) ve cümle sonu yoksa telefon onu "…" koymadan kesmiştir
     * ("$ in your mailbox. You bailed": aslı "...You bailed me out again bro!").
     */
    const val CLIP_EDGE = 0.88

    /**
     * "…" olmadan kesilmiş önizlemenin çevrilecek kısmı: sözcükler kalır (son sözcük tam görünüyor), sondaki bağlaç/edat
     * atılır. Sinan Bey (beta.100, 3399): "$ in your mailbox. You bailed" bağlamsız çevrilip "Posta kutunda. Beni aradın"
     * oluyordu. Cümle sonuyla biten ya da tek sözcüklük önizleme kesik sayılmaz (null). iPhone ile aynı.
     */
    fun clippedInput(text: String): String? {
        val value = text.trim()
        val last = value.lastOrNull() ?: return null
        if (last in ".!?…\"')") return null
        val words = value.split(Regex("\\s+")).filter { it.isNotEmpty() }.toMutableList()
        if (words.size < 2) return null
        while (words.size > 1 && words.last().lowercase().trim(::isPunctuation) in danglingWords) words.removeAt(words.size - 1)
        val core = words.joinToString(" ").trimEnd(',', ';', ':', '-', '–', '—').trim()
        return if (core.any { it.isLetter() }) core else null
    }

    /** Kesik önizlemenin motora giden hâli: sonuna "..." eklenir; motor metnin kesik olduğunu görür, sonunu tamamlamaz. */
    fun cutHint(core: String): String = "$core..."

    /** Kaynağın başındaki para simgesi ("$ in your mailbox") çeviride düştüyse başa geri konur. */
    fun keepingLeadingSymbol(source: String, translation: String): String {
        val trimmed = source.trim()
        val first = trimmed.firstOrNull() ?: return translation
        if (Character.getType(first) != Character.CURRENCY_SYMBOL.toInt() || translation.contains(first)) return translation
        val rest = trimmed.drop(1)
        val glued = rest.isNotEmpty() && !rest[0].isWhitespace()
        return first + (if (glued) "" else " ") + translation.trim()
    }

    /**
     * Sohbetten tam çevirisi bilinen mesajın kesik önizlemesi: önizlemenin (kesik ya da "…"sız kesilmiş) sadeleştirilmiş
     * hâliyle başlayan bilinen en kısa mesajın çevirisinin aynı oranda başı + "...". Uydurma değil, sohbette gösterilen
     * çevirinin kendisidir. Önizleme en az [PREVIEW_LETTERS] harf olmalı; bulunmazsa null. iPhone ile aynı.
     */
    const val PREVIEW_LETTERS = 8

    fun knownPreview(preview: String, known: Map<String, String>): String? {
        val core = preview.trim().trimEnd('.', '…')
        val words = TextMatch.normalize(core).split(' ').filter { it.isNotEmpty() }
        // "…" ile kesilen önizlemenin son sözcüğü yarımdır ("Coa"): eşleşmeye girmez.
        val head = (if (isCut(preview) && words.size > 1) words.dropLast(1) else words).joinToString(" ")
        if (head.count { it.isLetter() } < PREVIEW_LETTERS) return null
        val best = known.entries.filter { (key, _) ->
            val full = TextMatch.normalize(key)
            full.length > head.length + 2 && full.startsWith(head)
        }.minWithOrNull(compareBy<Map.Entry<String, String>> { it.key.length }.thenBy { it.key }) ?: return null
        val ratio = head.length.toDouble() / maxOf(1, TextMatch.normalize(best.key).length)
        val target = kotlin.math.ceil(best.value.length * ratio).toInt()
        val all = best.value.split(Regex("\\s+")).filter { it.isNotEmpty() }
        val taken = mutableListOf<String>()
        var length = 0
        for (word in all) {
            if (taken.isNotEmpty() && length + 1 + word.length > target + 2) break
            length += (if (taken.isEmpty()) 0 else 1) + word.length
            taken.add(word)
        }
        if (taken.size >= all.size) return null
        return cutTranslation(taken.joinToString(" "))
    }

    /** Kesik önizlemenin çevirisi: sondaki noktalama atılıp "..." eklenir (telefondaki gibi kesik görünür). */
    fun cutTranslation(translation: String): String =
        translation.trim().trimEnd('.', ',', ';', ':', '…', '–', '—', '-').trim() + "..."

    /** Balonlar: düzleştirilmiş ekranda ([TextLine.phoneBox]) alt alta ve hizalı satırlar tek balondur. */
    /**
     * Telefon ekranının blokları, kendi yerlerinde. Ana ekranda uygulama adları (WhatUp, simge etiketleri) çevrilmez
     * ([PhoneChat.withoutAppNames]); saat ve hava harfsiz satır olarak zaten atılır.
     */
    fun groups(source: Reading): List<ScreenTranslation.Group> {
        if (source.lines.any { it.phoneCard != null }) return cardGroups(source)
        val home = PhoneChat.isHomeScreen(source.lines)
        val reading = Reading(PhoneChat.withoutAppNames(source.lines))
        val flat = reading.lines.all { it.phoneBox != null }
        // Sohbet listesi ([forTranslation]): her satır kendi satırıdır (ad ve altındaki önizleme ayrı), rolü okumadan gelir.
        val listed = reading.lines.any { it.listRole != null }
        fun box(line: TextLine): TextBox = (if (flat) line.phoneBox else line.box)!!
        val groups = mutableListOf<ScreenTranslation.Group>()
        val run = mutableListOf<TextLine>()
        fun finish() {
            if (run.isEmpty()) return
            try {
                if (!flat) {
                    groups += ScreenTranslation.groups(Reading(run.toList()), keepIdentifiers = true)
                    return
                }
                val clean = withoutRepeatedLines(Reading(run.toList()).withButtonIcons().withoutButtonPrompts()
                    .withoutOcrNoise(keepIdentifiers = true).lines.filter { it.box != null && ScreenText.isWords(it.text) })
                val first = clean.firstOrNull()?.box ?: return
                val place = clean.drop(1).fold(first) { total, line -> total.union(line.box!!) }
                val heights = run.map { box(it).bottom - box(it).top }.sorted()
                val icons = clean.flatMap { it.icons ?: emptyList() }
                // Düz ekrandaki yeri: sohbet panelinde tarafı (sol/sağ) ve sırası bundan çıkar ([roles]).
                val spot = run.drop(1).fold(box(run[0])) { total, line -> total.union(box(line)) }
                groups += ScreenTranslation.Group(listOf(withoutRepeat(clean.joinToString(" ") { it.text })), place, heights[heights.size / 2],
                    if (icons.isEmpty()) null else listOf(icons),
                    ScreenPhoneCard.Placement(if (listed) run[0].listRole ?: ScreenPhoneCard.Role.PREVIEW else ScreenPhoneCard.Role.MESSAGE, spot))
            } finally {
                run.clear()
            }
        }
        for (line in reading.lines.filter { it.box != null }.sortedBy { box(it).top }) {
            run.lastOrNull()?.let { if (listed || breaksBlock(box(it), box(line), flat && endsSentence(it.text))) finish() }
            run.add(line)
        }
        finish()
        val kept = groups.take(ScreenTranslation.MAX_GROUPS)
        if (listed && flat && kept.isNotEmpty()) return kept
        val placed = roles(kept, home)
        return if (home) widgets(placed) else placed
    }

    /**
     * Sohbet dışı ekranın kartları ([forTranslation] işaretledi): her kart bir grup, telefondaki sırasıyla. Başlıklı
     * kartın başlığı ayrı paragraf (kalın çizilir), gövdesi tek paragraf; alt satıra sarılmış cümle birleşir (tireyle
     * bölünmüş sözcük boşluksuz). Grubun rolü [ScreenPhoneCard.Role.CARD], düz ekrandaki yeri kartın satırlarının birleşimi.
     */
    fun cardGroups(reading: Reading): List<ScreenTranslation.Group> {
        val marked = reading.lines.filter { it.phoneCard != null && it.box != null && it.phoneBox != null }
        val numbers = marked.map { it.phoneCard!!.card }.toSet().sorted()
        val groups = mutableListOf<ScreenTranslation.Group>()
        for (number in numbers) {
            val run = marked.filter { it.phoneCard!!.card == number }
            val clean = Reading(run).withoutOcrNoise(keepIdentifiers = true).lines
                .filter { it.box != null && it.phoneBox != null && ScreenText.isWords(it.text) }
            if (clean.isEmpty()) continue
            val mark = run[0].phoneCard!!
            val titled = clean.size >= 2 && clean[0].phoneCard?.title == true
            fun joined(lines: List<TextLine>): String {
                var text = ""
                for (line in lines) {
                    val part = line.text.trim()
                    text = if (text.isEmpty()) part else if (text.endsWith("-")) text + part else "$text $part"
                }
                return text
            }
            val paragraphs = if (titled) listOf(clean[0].text.trim(), joined(clean.drop(1))) else listOf(joined(clean))
            val boxes = clean.map { it.box!! }
            val spots = clean.map { it.phoneBox!! }
            val heights = spots.map { it.bottom - it.top }.sorted()
            groups += ScreenTranslation.Group(paragraphs, boxes.drop(1).fold(boxes[0]) { total, box -> total.union(box) },
                heights[(heights.size - 1) / 2],
                phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.CARD, spots.drop(1).fold(spots[0]) { total, spot -> total.union(spot) },
                    titled = titled, bold = mark.bold))
        }
        return groups.take(ScreenTranslation.MAX_GROUPS)
    }

    /** "Reminders 10 Notifications": bir-üç sözcüklük harfli başlık ve ardından sayaç; değilse null. */
    internal fun widgetParts(text: String): Pair<String, String>? {
        val words = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        for (count in 1..3) {
            if (count >= words.size) break
            val title = words.take(count).joinToString(" ")
            val counter = words.drop(count).joinToString(" ")
            if (PhoneChat.isCounter(counter) && title.none { it.isDigit() } && title.any { it.isLetter() }) return title to counter
        }
        return null
    }

    /**
     * Ana ekranda bileşen başlığı ve hemen altındaki sayaç ("Reminders" / "6 Notifications") tek grup olur: panelde tek
     * kart ([ScreenPhoneCard.Role.WIDGET]; "Ekranı çevir"de [PhoneChat.isWidget]). Başlığın solunda simge olduğundan
     * ikisi ayrı blok okunuyordu ve bileşen çevrilmiyordu (Sinan Bey, beta.100 3397). iPhone ile aynı.
     */
    internal fun widgets(groups: List<ScreenTranslation.Group>): List<ScreenTranslation.Group> {
        val result = mutableListOf<ScreenTranslation.Group>()
        for (group in groups) {
            val text = group.paragraphs.joinToString(" ")
            // Başlık ve sayaç tek satır grubu okunduysa ("Reminders 10 Notifications") ikiye ayrılır.
            val split = if (group.phone?.role == ScreenPhoneCard.Role.HOME && group.paragraphs.size == 1) widgetParts(text) else null
            if (split != null) {
                result.add(group.copy(paragraphs = listOf(split.first, split.second), icons = null,
                    phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.WIDGET, group.phone!!.spot)))
                continue
            }
            val spot = group.phone?.spot
            val last = result.lastOrNull()
            val above = last?.phone?.spot
            if (PhoneChat.isCounter(text) && spot != null && last != null && above != null &&
                last.phone?.role == ScreenPhoneCard.Role.HOME && last.paragraphs.size == 1 && !PhoneChat.isCounter(last.paragraphs[0]) &&
                last.paragraphs[0].split(Regex("\\s+")).count { it.isNotEmpty() } in 1..3 &&
                spot.top >= above.top && spot.top - above.bottom < (above.bottom - above.top) * PhoneChat.HOME_GAP &&
                spot.left <= above.left + PhoneChat.LEFT_ALIGN && above.left - spot.left <= PhoneChat.WIDGET_INDENT) {
                result[result.size - 1] = last.copy(paragraphs = listOf(last.paragraphs[0], text), box = last.box.union(group.box),
                    phone = ScreenPhoneCard.Placement(ScreenPhoneCard.Role.WIDGET, above.union(spot)))
                continue
            }
            result.add(group)
        }
        return result
    }

    /**
     * Sohbet panelinde her grubun rolü ("Ekranı çevir"in [PhoneChat] kuralları, düz ekrandaki yerinden): en üstteki kısa
     * ad satırı kişinin adıdır (çevrilmez), ortalı kısa satır not, sağa yaslı balon oyuncunun, sola yaslı karşı tarafın
     * mesajı. Sohbet listesinde önizlemeler, ana ekranda bütün yazılar kendi yerinde kalır. Mac ile aynı.
     */
    internal fun roles(groups: List<ScreenTranslation.Group>, home: Boolean): List<ScreenTranslation.Group> {
        if (groups.any { it.phone == null }) return groups.map { it.copy(phone = null) }
        val list = groups.any { section(it.paragraphs.joinToString("")) != null }
        val first = groups.indices.minByOrNull { groups[it].phone!!.spot.top }
        return groups.mapIndexed { index, group ->
            val text = group.paragraphs.joinToString(" ")
            val spot = group.phone!!.spot
            val row = PhoneChat.Row(emptyList(), spot, text)
            val role = when {
                home -> ScreenPhoneCard.Role.HOME
                index == first && !list && PhoneChat.isHeader(row) -> ScreenPhoneCard.Role.HEADER
                list -> if (section(text) != null) ScreenPhoneCard.Role.HEADING else ScreenPhoneCard.Role.PREVIEW
                else -> PhoneChat.role(listOf(row))
            }
            group.copy(phone = ScreenPhoneCard.Placement(role, spot))
        }
    }

    private fun endsSentence(text: String): Boolean = text.trimEnd().lastOrNull()?.let { it in ".!?" } ?: false

    /**
     * Art arda iki kez yazılmış metin ("A. B. A. B.") bir kez: OCR aynı satırı iki kutuda okuyunca ya da motor çeviriyi iki
     * kez yazınca balonda aynı paragraf art arda iki kez görünüyordu (X, 22 Kas). Metin sözcük sözcük ikiye bölünür (en az
     * dört sözcük); iki yarı aynı mesajsa ([PhoneSteady.sameReading]) ilk yarı kalır (Mac ile aynı).
     */
    fun withoutRepeat(text: String): String {
        val words = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.size < 4 || words.size % 2 != 0) return text
        val half = words.size / 2
        val first = words.take(half).joinToString(" ")
        val second = words.drop(half).joinToString(" ")
        if (TextMatch.normalize(first).none { it.isLetter() } || !PhoneSteady.sameReading(first, second)) return text
        return first
    }

    /**
     * Aynı balonda bir öncekiyle aynı ([PhoneSteady.sameReading]) ya da bir öncekinin içinde kalan satır atılır: soluk satır
     * bazen hem tam hem parça olarak iki kutuda okunur (Mac ile aynı).
     */
    fun withoutRepeatedLines(lines: List<TextLine>): List<TextLine> {
        val kept = ArrayList<TextLine>()
        for (line in lines) {
            val previous = kept.lastOrNull()
            if (previous != null) {
                val a = TextMatch.normalize(previous.text)
                val b = TextMatch.normalize(line.text)
                if (PhoneSteady.sameReading(previous.text, line.text) ||
                    (b.length >= 6 && 2 * b.length >= a.length && b.count { it.isLetter() } >= 4 && a.contains(b))) continue
            }
            kept.add(line)
        }
        return kept
    }

    /**
     * Düzeltilmiş telefon ekranında satır arası dar, aynı taraftaki ardışık balonların arası daha geniştir: cümle sonundan
     * sonra satır yüksekliğinin 0,65'inden geniş boşluk yeni balondur; aynı balonda alt satıra geçen ikinci cümle birlikte kalır.
     */
    private fun breaksBlock(previous: TextBox, next: TextBox, afterFlatSentence: Boolean): Boolean {
        val lineHeight = maxOf(previous.bottom - previous.top, next.bottom - next.top)
        if (next.top - previous.bottom > lineHeight * (if (afterFlatSentence) 0.65 else 1.0)) return true
        val alignedLeft = abs(previous.left - next.left) <= 0.08
        val alignedRight = minOf(previous.left, next.left) > 0.25 && abs(previous.right - next.right) <= 0.045
        return !alignedLeft && !alignedRight
    }
}
