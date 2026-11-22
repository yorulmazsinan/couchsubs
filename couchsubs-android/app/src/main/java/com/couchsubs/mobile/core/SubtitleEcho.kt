// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

/**
 * Altyazı hattının son okuduğu satırlar ve altyazı alanı: ekran yazısı (otomatik dedektör, hazır alanlar, görev satırı,
 * "Ekranı çevir") altyazıyı ikinci kez çizmesin. Kullanıcı bildirimi (X, beta.65/66): "Ekran yazılarını otomatik
 * çevir" açıkken altyazının çevirisi hem seçilen altyazı konumunda hem oyunun altyazısının tam üstünde görünüyordu.
 * Dedektör yalnız merkezi altyazı alanında kalan karoları dışlıyordu; alanın kenarına taşan satırın karoları (iki
 * satırlı altyazının alan dışında kalan üst satırı, alandan geniş satırın uçları) aday oluyor, bulunan alan yarım/bir
 * karo genişletildiği için altyazının kendisini de okuyordu. Hazır GTA 6 mesaj alanı da (0,72–0,99 x 0,45–0,80)
 * varsayılan altyazı alanıyla (0,14–0,86 x 0,62–0,97) kesişiyor, geniş altyazının sağ ucunu okuyordu. Görev satırının
 * bölgesi de ([MissionLine]) altyazı alanının içindedir; görev kalkıp yerine altyazı gelince altyazı orada da okunuyordu.
 *
 * Kural: ekran yazısı okumasında altyazı alanında altyazı satırının yerine düşen satır (bkz. [isSubtitlePlace]), son
 * altyazı satırının hemen üstüne/altına taşan aynı boydaki satır ve altyazı hattının son [WINDOW_MS] içinde okuduğu
 * metne benzeyen satır atılır. Menü durumunda ve görev satırının kendi alanında yalnız metin eşleşmesi uygulanır (menü
 * satırları altyazı alanında da olabilir; görev satırı altyazı alanının içindedir). Mac/iPhone (SubtitleEcho.swift) ve
 * Windows (SubtitleEcho.cs) aynı kuralları uygular. İş parçacığı güvenlidir.
 */
class SubtitleEcho(private val clock: () -> Long = monotonicClock) {
    companion object {
        /** Altyazı hattının okuduğu metin bu kadar süre hatırlanır (ekran yazısı turu 0,5–1 sn arayla okur). */
        const val WINDOW_MS = 6000L
        /** Altyazı satırına bitişik satır kuralı bu kadar süre geçerlidir (altyazı ekrandayken). */
        const val ADJACENT_MS = 1500L
        /** Kısa okuma, uzun satırın parçası sayılmak için en az bu kadar harf/rakam taşımalı */
        internal const val PART_MINIMUM = 10
        /** ve uzun satırın en az bu kadarı olmalı (altyazıda geçen kısa görev yazısı "Get to the docks" atılmasın). */
        internal const val PART_SHARE = 0.4
        /** Bu kadar büyük altyazı alanı (Tam ekran) yerle dışlanmaz. */
        internal const val WHOLE_SCREEN = 0.6

        /** Uygulamanın tek altyazı hattı ve ekran yazısı okuyucuları bunu paylaşır (testler kendi örneğini kurar). */
        val shared = SubtitleEcho()

        internal fun inside(box: TextBox, region: TextBox): Boolean {
            val x = (box.left + box.right) / 2
            val y = (box.top + box.bottom) / 2
            if (x >= region.left && x <= region.right && y >= region.top && y <= region.bottom) return true
            val w = minOf(box.right, region.right) - maxOf(box.left, region.left)
            val h = minOf(box.bottom, region.bottom) - maxOf(box.top, region.top)
            val area = (box.right - box.left) * (box.bottom - box.top)
            return w > 0 && h > 0 && area > 0 && w * h >= 0.5 * area
        }

        /**
         * Kutu altyazı satırıyla aynı sırada (dikeyde örtüşüyor ya da arada satır boyunun yarısından az boşluk) ve
         * yatayda dardakinin en az %80'i örtüşüyor: altyazının kendisi, parçası ya da aynı yere gelen yeni altyazı.
         * Telefon kartının satırı geniş altyazıyla aynı sıradaysa bile yalnız ucu örtüşür, atılmaz.
         */
        internal fun sameRow(box: TextBox, line: TextBox): Boolean {
            val height = maxOf(box.bottom - box.top, line.bottom - line.top)
            val gap = maxOf(box.top - line.bottom, line.top - box.bottom)
            val overlap = minOf(box.right, line.right) - maxOf(box.left, line.left)
            val narrower = minOf(box.right - box.left, line.right - line.left)
            return height > 0 && narrower > 0 && gap <= height * 0.5 && overlap >= narrower * 0.8
        }

        /**
         * Aynı boyda (±%30), yatayda örtüşen ve dikeyde en çok bir satır boyu aralıklı iki satır (iki satırlı altyazının
         * alan dışında kalan satırı).
         */
        internal fun adjacent(box: TextBox, line: TextBox): Boolean {
            val a = box.bottom - box.top
            val b = line.bottom - line.top
            if (a <= 0 || b <= 0 || maxOf(a, b) > minOf(a, b) * 1.3) return false
            val gap = maxOf(box.top - line.bottom, line.top - box.bottom)
            val overlap = minOf(box.right, line.right) - maxOf(box.left, line.left)
            return gap <= b && overlap > 0.3 * minOf(box.right - box.left, line.right - line.left)
        }
    }

    private class Line(val text: String, var box: TextBox?, var at: Long)

    private val lock = Any()
    private val lines = mutableListOf<Line>()
    private var region: TextBox? = null

    /** Altyazı hattının gösterdiği çeviriler (hat verir): karede okunan kendi altyazımız ekran yazısı olarak da çevrilmez. */
    @Volatile var own: OwnSubtitles? = null

    /** Altyazı hattı her işlediği karede çağırır: [block] altyazı bloğunun satırları (yeri [region]'a oranla). */
    fun record(block: Reading, region: TextBox) {
        val time = clock()
        synchronized(lock) {
            this.region = region
            for (line in block.lines) {
                val text = TextMatch.normalize(IconText.plain(line.text))
                if (text.length < 3) continue
                val box = line.box?.placedIn(region)
                val existing = lines.firstOrNull { it.text == text }
                if (existing != null) {
                    existing.at = time
                    existing.box = box ?: existing.box
                } else {
                    lines.add(Line(text, box, time))
                }
            }
            lines.removeAll { time - it.at > WINDOW_MS }
            while (lines.size > 64) lines.removeAt(0)
        }
    }

    /** Okuma durdu ya da hat sıfırlandı. */
    fun reset(): Unit = synchronized(lock) {
        lines.clear()
        region = null
    }

    /** Altyazı hattı son [WINDOW_MS] içinde bir altyazı okudu ("Ekranı çevir" yer kuralını yalnız o zaman uygular). */
    val hasRecent: Boolean
        get() {
            val time = clock()
            return synchronized(lock) { lines.any { time - it.at <= WINDOW_MS } }
        }

    /** [text] altyazı hattının son [WINDOW_MS] içinde okuduğu bir satıra benziyor ya da onun parçası/bütünü. */
    fun isEcho(text: String): Boolean {
        if (own?.isOwn(text) == true) return true
        val probe = TextMatch.normalize(IconText.plain(text))
        if (probe.length < 3) return false
        val time = clock()
        return synchronized(lock) {
            lines.any { line ->
                if (time - line.at > WINDOW_MS) return@any false
                if (TextMatch.isSimilar(probe, line.text, 0.8)) return@any true
                val (short, long) = if (probe.length <= line.text.length) probe to line.text else line.text to probe
                short.length >= PART_MINIMUM && short.length >= PART_SHARE * long.length && long.contains(short)
            }
        }
    }

    /**
     * Karedeki (0..1) kutu altyazının yerinde mi: altyazı alanında (merkezi içinde ya da alanının en az yarısı) ve altyazı
     * hattının son [WINDOW_MS] içinde okuduğu bir satırın üstünde ([sameRow]), ya da son altyazı satırının hemen
     * üstüne/altına taşan aynı boyda bir satır.
     *
     * Alanın tamamı dışlanmaz. Kullanıcı bildirimi (X, beta.69, GTA 6): "Ekranı çevir" altyazıyı çeviriyor, telefon
     * mesajlarını çevirmiyordu. Sağ alttaki telefon kartı (0,72–0,99 x 0,45–0,80) varsayılan altyazı alanıyla
     * (0,14–0,86 x 0,62–0,97) kesişiyor; altyazı okunurken kartın 0,62'nin altındaki mesaj satırlarının merkezi alanın
     * içinde kaldığı için hepsi atılıyordu (hazır mesaj alanında da). Altyazının kendisi metinle, alan kenarına taşan ve
     * alana düşen parçaları altyazı satırının yerinden tanınır.
     */
    fun isSubtitlePlace(box: TextBox): Boolean {
        val time = clock()
        return synchronized(lock) {
            // Tam ekran (ya da ekranın çoğu) altyazı alanıyken yer kuralı uygulanmaz; metin eşleşmesi yeter.
            val region = region
            if (region != null && (region.right - region.left) * (region.bottom - region.top) < WHOLE_SCREEN &&
                inside(box, region) &&
                lines.any { line -> val other = line.box; time - line.at <= WINDOW_MS && other != null && sameRow(box, other) }
            ) return@synchronized true
            lines.any { line ->
                val other = line.box
                time - line.at <= ADJACENT_MS && other != null && adjacent(box, other)
            }
        }
    }

    /**
     * Ekran yazısı okumasından altyazıya ait satırlar çıkarılmış hali. [place]: okumanın karedeki yeri (satır kutuları
     * ona oranla). [geometry]: yerle de dışla (menü durumu ve görev alanı dışında); metin eşleşmesi her zaman uygulanır.
     */
    fun filter(reading: Reading, place: TextBox = TextBox(0.0, 0.0, 1.0, 1.0), geometry: Boolean = true): Reading {
        val kept = reading.lines.filter { line ->
            if (isEcho(line.text)) return@filter false
            val box = line.box
            !(geometry && box != null && isSubtitlePlace(box.placedIn(place)))
        }
        return if (kept.size == reading.lines.size) reading else Reading(kept)
    }
}
