// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * Oyun telefonu kurallarının baktığı kare: [width]×[height] piksel, üstten ve soldan. Android'de çözücünün karesi YUV'dur;
 * kurallar Mac/iPhone (CGImage) ve Windows'takiyle aynı değerleri görsün diye renk burada RGB'ye çevrilmiş okunur.
 */
interface PhoneImage {
    val width: Int
    val height: Int

    /** (x, y) pikselinin tonu: 77·R + 150·G + 29·B (0–65280; 256'ya bölünce parlaklık). */
    fun tone(x: Int, y: Int): Int

    /** (x, y) pikselinin rengi, 0xRRGGBB. */
    fun rgb(x: Int, y: Int): Int

    /** [region]'ın gri kopyası (kumanda simgeleri ondan kesilir); kare bunu veremiyorsa null. */
    fun gray(region: CropRegion): GrayFrame? = null

    /** [region]'ın 64×12 gri izi ([RegionSignature]): her hücrenin ortasındaki piksel. */
    fun signature(region: CropRegion): ByteArray {
        val out = ByteArray(RegionSignature.WIDTH * RegionSignature.HEIGHT)
        if (width <= 0 || height <= 0) return out
        val left = region.left * width
        val top = region.top * height
        val w = (region.right - region.left) * width
        val h = (region.bottom - region.top) * height
        for (y in 0 until RegionSignature.HEIGHT) {
            val sy = (top + (y + 0.5) * h / RegionSignature.HEIGHT).toInt().coerceIn(0, height - 1)
            for (x in 0 until RegionSignature.WIDTH) {
                val sx = (left + (x + 0.5) * w / RegionSignature.WIDTH).toInt().coerceIn(0, width - 1)
                out[y * RegionSignature.WIDTH + x] = (tone(sx, sy) shr 8).toByte()
            }
        }
        return out
    }
}

/**
 * GTA 6'nın oyun içi telefonunu izler ("GTA 6'daki telefonu otomatik çevir"). Hizalı iki gözlem şartı, tek bir menü ya
 * da altyazı karesinin telefon oturumu açmasını önler (Mac/iPhone GamePhoneTracker.swift, Windows GamePhoneTracker.cs
 * ile aynı kurallar).
 */
class GamePhoneTracker(private val locateNear: (PhoneImage, GamePhoneGeometry.Pose?) -> GamePhoneGeometry.Pose?) {
    constructor() : this({ image, near -> GamePhoneGeometry.locate(image, near) })
    constructor(locate: (PhoneImage) -> GamePhoneGeometry.Pose?) : this({ image, _ -> locate(image) })

    class Sample(val sampled: Boolean, val pose: GamePhoneGeometry.Pose?)

    private var lastTime: Long? = null
    private var previous: GamePhoneGeometry.Pose? = null
    private var shown: GamePhoneGeometry.Pose? = null
    private var clock = 0L
    private val trace = DropLog({ clock })

    /** Telefonun açılması, kapanması ve oynadığı için açılmaması altyazı günlüğüne ([PhoneTrace]; sınırlı). null: uygulamanın günlüğü. */
    @Volatile var onLog: ((String) -> Unit)? = null

    private fun note(reason: String) = trace.note(PhoneTrace.COMPONENT, reason, "", onLog)

    @Synchronized
    fun sample(image: PhoneImage, now: Long): Sample {
        lastTime?.let { if (now >= it && now - it < INTERVAL_MS) return Sample(false, shown) }
        lastTime = now
        clock = now
        val wasShown = shown != null
        // Akıl sınırı: telefon ekranın küçük, dikey bir parçasıdır. Dışındaki bir aday (menüde ya da koyu ekranda yanlış
        // eşleşme) kabul edilmez; TV'de büyük opak telefon kutusu oyun görüntüsünü kapatırdı.
        // Açık telefon yerinde ararken gevşek doğrulama da denenir ([GamePhoneGeometry.locate] near): beyaz ya da mavi
        // ekranlı uygulamada (haber, ayarlar, hava) telefonun yanları zemine karışıyor, sıkı arama ıskalıyordu.
        var found = locateNear(image, shown)
        if (found != null && !plausible(found.bounds, image.width, image.height)) found = null
        val before = previous
        val current = shown
        if (found != null && ((before != null && found.bounds.isClose(before.bounds, 0.035)) ||
                (current != null && found.bounds.isClose(current.bounds, 0.035)))) {
            // İki uyumlu gözlem ya da açık telefonun yakınında tek gözlem: aynı telefon, yeri güncellenir.
            shown = found
            misses = 0
        } else if (current != null && misses < MISS_GRACE) {
            // Açık telefon tek bir karede bulunamadı ya da el titredi: hemen kapanmaz. Önceden tek ıska paneli kapatıyor,
            // yeniden açılış iki gözlem bekleyip bütün sayfayı yeniden çeviriyordu; çeviriler gidip geliyordu (X'teki
            // bildirim). Telefon gerçekten indirilince [MISS_GRACE] tur sonra kapanır.
            misses++
        } else {
            shown = null
            misses = 0
        }
        if (!wasShown && shown != null) note(PhoneTrace.OPENED) else if (wasShown && shown == null) note(PhoneTrace.CLOSED)
        // Telefon art arda iki örnekte bulundu ama yeri çok oynadı: hiç açılmıyor, okuma da başlamıyor (önceden sessizdi).
        if (shown == null && found != null && before != null) note(PhoneTrace.moving(PhoneTrace.shift(found.bounds, before.bounds)))
        previous = found
        return Sample(true, shown)
    }

    private var misses = 0

    @Synchronized
    fun reset() {
        lastTime = null
        previous = null
        shown = null
        misses = 0
    }

    companion object {
        const val INTERVAL_MS = 330L

        /**
         * Açık telefon art arda bu kadar örnekte bulunamazsa kapanır (330 ms aralıkla ~1–1,3 sn; Mac ve Windows ile aynı).
         * Önceden 2 örnekti (~0,7 sn): telefonun ekranı bir an okunamayınca panel kaybolup baştan çevrilerek geri geliyordu
         * (X, 22 Kas, GTA 6 telefonu).
         */
        const val MISS_GRACE = 3

        /** Telefon kutusunun alanı (kareye oranla) bu aralıkta olmalı. */
        const val MIN_AREA = 0.04
        const val MAX_AREA = 0.35

        /**
         * Telefon kutusu akla yatkın mı: alanı karenin %4–%35'i, piksel olarak dikey (yükseklik/genişlik 0,9–2,6; eğik
         * telefonun sınır kutusu dikey telefondan geniştir), yüksekliği karenin en çok %85'i, genişliği en çok yarısı,
         * merkezi karenin sol kenarında ya da üst üçte birinde değil.
         */
        fun plausible(region: CropRegion, width: Int, height: Int): Boolean {
            val w = region.right - region.left
            val h = region.bottom - region.top
            if (!(w > 0 && h > 0 && h <= 0.85 && w <= 0.5)) return false
            val area = w * h
            if (area < MIN_AREA || area > MAX_AREA) return false
            if (width >= 64) {
                val aspect = h * maxOf(1, height) / (w * maxOf(1, width))
                if (aspect < 0.9 || aspect > 2.6) return false
            }
            return (region.left + region.right) / 2 >= 0.35 && (region.top + region.bottom) / 2 >= 1.0 / 3
        }
    }
}

object GamePhoneGeometry {
    /** Telefonun üst (hoparlör) ve alt (tuş) yuvalarının karedeki yeri, kenarlara oranla. */
    data class Pose(val topX: Double, val topY: Double, val bottomX: Double, val bottomY: Double) {
        val bounds: CropRegion
            get() {
                val h = bottomY - topY
                val w = h * 225 / 400 * 0.25
                return CropRegion(top = topY + h * 0.012, bottom = bottomY - h * 0.015,
                    left = minOf(topX, bottomX) - w, right = maxOf(topX, bottomX) + w)
            }
    }

    private class Slot(val x: Double, val y: Int, val length: Int, val contrast: Int)

    /**
     * Yayın çözünürlüğünden bağımsız tek 400×225 algılama ızgarası, eksen başına iki örnek: kare 800×450'ye en yakın
     * komşuyla küçültülmüş gibi okunur (örnekler istenince, doğrudan kareden alınır).
     */
    private class Grid(private val image: PhoneImage) {
        private val xs = IntArray(800) { ((it + 0.5) * image.width / 800).toInt().coerceIn(0, image.width - 1) }
        private val ys = IntArray(450) { ((it + 0.5) * image.height / 450).toInt().coerceIn(0, image.height - 1) }

        fun at(x: Int, y: Int): Int {
            val cx = (2 * x).coerceIn(0, 798)
            val cy = (2 * y).coerceIn(0, 448)
            return (image.tone(xs[cx], ys[cy]) + image.tone(xs[cx + 1], ys[cy]) +
                image.tone(xs[cx], ys[cy + 1]) + image.tone(xs[cx + 1], ys[cy + 1])) shr 10
        }
    }

    private fun rounded(value: Double): Int = Math.rint(value).toInt()
    private fun limit(n: Int, low: Int, high: Int): Int = minOf(high, maxOf(low, n))

    /** Karenin içindeki dikdörtgen (piksel). */
    data class Area(val x: Int, val y: Int, val width: Int, val height: Int)

    /** Simsiyah şerit: örneklerin hepsi bu tondan koyu (0–255). */
    const val DARK_TONE = 24

    private fun widescreen(width: Int, height: Int) = abs(width.toDouble() / height - 400.0 / 225) <= 0.04

    /**
     * Karedeki 16:9 oyun görüntüsü (piksel). Pencereden okunan kare (PS Remote Play, chiaki-ng, OBS penceresi) başlık
     * çubuğunu ve pencere görüntüden farklı oransa siyah şeritleri de taşır; önceden telefon yalnız tam 16:9 karede
     * aranıyordu, pencerede hiç bulunmuyordu (ne otomatik telefon okuması ne "Ekranı çevir"in telefon kartı). Alttaki ve
     * yanlardaki simsiyah şeritler atılır, görüntü kalan genişliğin 16:9'u kadar yüksekliktedir ve alta yaslıdır (başlık
     * çubuğu üstte). Kare zaten 16:9 ise tamamı; görüntü bulunamazsa null (Mac/iPhone ve Windows ile aynı kural). Android
     * kendi akışını okur (hep 16:9); kural platformlar aynı kalsın diye burada da var.
     */
    fun picture(width: Int, height: Int, tone: (Int, Int) -> Int): Area? {
        if (width < 400 || height < 225) return null
        if (widescreen(width, height)) return Area(0, 0, width, height)
        val columns = IntArray(64) { minOf(width - 1, ((it + 0.5) * width / 64).toInt()) }
        fun darkRow(y: Int) = columns.all { tone(it, y) < DARK_TONE }
        var bottom = height
        while (bottom > height / 2 && darkRow(bottom - 1)) bottom--
        // Yan şeritlere başlık çubuğunun altından bakılır (başlık çubuğu bütün genişlikte uzanır).
        val from = height * 2 / 5
        val rows = IntArray(48) { from + ((it + 0.5) * (bottom - from) / 48).toInt() }
        fun darkColumn(x: Int) = rows.all { tone(x, it) < DARK_TONE }
        var left = 0
        var right = width
        while (left < width / 4 && darkColumn(left)) left++
        while (right > width * 3 / 4 && darkColumn(right - 1)) right--
        var w = right - left
        var h = Math.round(w * 9 / 16.0).toInt()
        if (h > bottom) {
            h = bottom
            w = Math.round(h * 16 / 9.0).toInt()
            left = (left + right - w) / 2
        }
        if (w < 400 || h < 225 || left < 0 || left + w > width) return null
        return Area(left, bottom - h, w, h)
    }

    /** Karenin bir parçası, kendi başına bir kare gibi. */
    private class Cropped(private val image: PhoneImage, private val area: Area) : PhoneImage {
        override val width: Int get() = area.width
        override val height: Int get() = area.height
        override fun tone(x: Int, y: Int): Int = image.tone(area.x + x, area.y + y)
        override fun rgb(x: Int, y: Int): Int = image.rgb(area.x + x, area.y + y)
    }

    /**
     * Karedeki telefon. [near]: açık telefonun son yeri; sıkı arama ıskalarsa o yerin hemen çevresinde gevşek doğrulama
     * yapılır ([confirmPicture]): hoparlör yarığı ve kamera üstte, alt çentik altta aynı yerde duruyorsa telefon
     * yerindedir. Sinan Bey (beta.100, 3418–3425): beyaz/mavi ekranlı uygulamalarda (haber, makale, hava, ayarlar,
     * eklenti) telefonun yan kenarları elin ve gövdenin rengine karışıyor, sıkı arama telefonu kaybediyordu; telefon
     * kaybolunca balonlar kalkıyor ("arada kaçıyor", 3417), telefonun yazıları altyazıya (3418, 3420, 3421) ve ekran
     * yazısı kutularına (3420–3425) gidiyordu. Gevşek doğrulama yalnız açık telefonun yerinde yapılır: yeni telefon yine
     * sıkı aramayla ve iki gözlemle açılır (Mac/iPhone ve Windows ile aynı).
     */
    fun locate(image: PhoneImage, near: Pose? = null): Pose? {
        if (image.width < 400 || image.height < 225) return null
        if (widescreen(image.width, image.height)) return locatePicture(image, near)
        val area = picture(image.width, image.height) { x, y -> image.tone(x, y) shr 8 } ?: return null
        val w = image.width.toDouble()
        val h = image.height.toDouble()
        // Açık telefonun yeri görüntünün içine taşınır.
        val local = near?.let { pose ->
            Pose((pose.topX * w - area.x) / area.width, (pose.topY * h - area.y) / area.height,
                (pose.bottomX * w - area.x) / area.width, (pose.bottomY * h - area.y) / area.height)
        }
        val pose = locatePicture(Cropped(image, area), local) ?: return null
        fun x(value: Double) = (area.x + value * area.width) / w
        fun y(value: Double) = (area.y + value * area.height) / h
        return Pose(x(pose.topX), y(pose.topY), x(pose.bottomX), y(pose.bottomY))
    }

    private fun locatePicture(image: PhoneImage, near: Pose? = null): Pose? {
        if (image.width < 400 || image.height < 225 || !widescreen(image.width, image.height)) return null
        strictPicture(image)?.let { return it }
        return near?.let { confirmPicture(image, it) }
    }

    /** Gevşek doğrulamada yarıklar açık telefonun son yerinden en çok bu kadar (400×225 ızgarada) uzak olabilir. */
    const val CONFIRM_REACH = 4.0

    /**
     * Açık telefonun son yerinde gevşek doğrulama: üstte kameralı hoparlör yarığı ve altta alt çentik, son yerin
     * [CONFIRM_REACH] kadar çevresinde, sıkı aramayla aynı boy ve oran kurallarıyla; yan kenarların ve çerçevenin gücüne
     * bakılmaz (beyaz ekranda yanlar zemine karışır). Bulunmazsa null.
     */
    internal fun confirmPicture(image: PhoneImage, near: Pose): Pose? {
        val grid = Grid(image)
        val topX = near.topX * 400
        val topY = near.topY * 225
        val bottomX = near.bottomX * 400
        val bottomY = near.bottomY * 225
        val reach = CONFIRM_REACH.toInt()
        val upperRows = maxOf(17, rounded(topY) - reach) until minOf(75, rounded(topY) + reach + 1)
        val lowerRows = maxOf(145, rounded(bottomY) - reach) until minOf(217, rounded(bottomY) + reach + 1)
        if (upperRows.isEmpty() || lowerRows.isEmpty()) return null
        val upper = slots(grid, upperRows, 8..19, 12).filter { abs(it.x - topX) <= CONFIRM_REACH && hasCamera(grid, it) }
        val lower = slots(grid, lowerRows, 5..14, 16).filter { abs(it.x - bottomX) <= CONFIRM_REACH }
        var best = Double.POSITIVE_INFINITY
        var pose: Pose? = null
        for (top in upper) {
            for (bottom in lower) {
                val h = (bottom.y - top.y).toDouble()
                val dx = bottom.x - top.x
                if (!(h >= 115 && h <= 179 && abs(dx) <= h * 0.24 &&
                        bottom.length >= top.length * 0.46 && bottom.length <= top.length &&
                        h >= 7.9 * top.length && h <= 16.5 * top.length &&
                        h >= 12 * bottom.length && h <= 30 * bottom.length)) continue
                val distance = abs(top.x - topX) + abs(top.y - topY) + abs(bottom.x - bottomX) + abs(bottom.y - bottomY)
                if (distance < best) {
                    best = distance
                    pose = Pose(top.x / 400, top.y / 225.0, bottom.x / 400, bottom.y / 225.0)
                }
            }
        }
        return pose
    }

    private fun strictPicture(image: PhoneImage): Pose? {
        val grid = Grid(image)
        // Olağan oyun görüntüsü burada biter. Gövdeye ancak üst bantta hem hoparlör hem kamera görülünce bakılır.
        val upper = slots(grid, 17 until 75, 8..19, 12).filter { hasCamera(grid, it) }
        if (upper.isEmpty()) return null
        val lower = slots(grid, 145 until 217, 5..14, 16)
        var best = 0.0
        var pose: Pose? = null
        for (top in upper) {
            for (bottom in lower) {
                val h = (bottom.y - top.y).toDouble()
                val dx = bottom.x - top.x
                if (!(h >= 115 && h <= 179 && abs(dx) <= h * 0.24 &&
                        bottom.length >= top.length * 0.46 && bottom.length <= top.length &&
                        h >= 7.9 * top.length && h <= 16.5 * top.length &&
                        h >= 12 * bottom.length && h <= 30 * bottom.length &&
                        smoothRim(grid, top, dx, h) && smoothRim(grid, bottom, dx, h))) continue
                val left = sideStrength(grid, top, dx, h, -1)
                if (left < 12) continue
                val right = sideStrength(grid, top, dx, h, 1)
                if (right < 12) continue
                val edges = minOf(left, right) + 0.25 * maxOf(left, right)
                val rims = rimBoundary(grid, top, dx, h, lower = false) + rimBoundary(grid, bottom, dx, h, lower = true)
                val score = edges + 0.1 * minOf(top.contrast, bottom.contrast) + 0.5 * rims
                if (score > best) {
                    best = score
                    pose = Pose(top.x / 400, top.y / 225.0, bottom.x / 400, bottom.y / 225.0)
                }
            }
        }
        return pose
    }

    private fun slots(grid: Grid, rows: IntRange, lengths: IntRange, maximum: Int): List<Slot> {
        val left = 95
        val width = 211
        val count = rows.last - rows.first + 1
        val band = IntArray((count + 8) * width)
        for (y in (rows.first - 4)..(rows.last + 4)) {
            val row = (y - rows.first + 4) * width
            for (i in 0 until width) band[row + i] = grid.at(left + i, y)
        }
        val found = mutableListOf<Slot>()
        for (y in rows) {
            val row = (y - rows.first + 4) * width
            var start: Int? = null
            for (x in (105 - left)..(294 - left)) {
                val p = row + x
                val surround = minOf(band[p - 3 * width], band[p + 3 * width])
                if (x < 294 - left && surround - band[p] >= limit(surround / 3, 14, 25)) {
                    if (start == null) start = x
                    continue
                }
                val s = start
                if (s != null && (x - s) in lengths) {
                    val center = row + s + (x - s) / 2
                    val end = p + 1
                    val border = row + s - 2
                    val rim = intArrayOf(
                        band[border - 4 * width], band[center - 4 * width], band[end - 4 * width],
                        band[border + 4 * width], band[center + 4 * width], band[end + 4 * width],
                        band[border], band[end],
                    ).sortedArray()
                    val tone = (rim[3] + rim[4]) / 2
                    val contrast = tone - band[center]
                    if (contrast >= limit(tone / 3, 20, 33) && rim[7] - rim[0] <= maxOf(24, contrast * 3 / 4)) {
                        if (found.size >= maximum) return emptyList()
                        found.add(Slot(left + (s + x - 1) / 2.0, y, x - s, contrast))
                    }
                }
                start = null
            }
        }
        return found
    }

    private fun hasCamera(grid: Grid, top: Slot): Boolean {
        for (side in intArrayOf(-1, 1)) {
            for (d in maxOf(5, rounded(top.length * 0.62))..rounded(top.length * 1.15)) {
                for (y in (top.y - 2)..(top.y + 2)) {
                    val x = rounded(top.x) + side * d
                    val above = grid.at(x, y - 3)
                    val below = grid.at(x, y + 3)
                    val left = grid.at(x - 3, y)
                    val right = grid.at(x + 3, y)
                    val low = minOf(minOf(above, below), minOf(left, right))
                    val high = maxOf(maxOf(above, below), maxOf(left, right))
                    if (low - grid.at(x, y) >= limit(low / 3, 15, 23) && (high - low) < maxOf(25.0, top.contrast * 0.9)) return true
                }
            }
        }
        return false
    }

    private fun smoothRim(grid: Grid, slot: Slot, dx: Double, h: Double): Boolean {
        val r = (h * 0.14).toInt()
        return intArrayOf(-r, 3 - r, r - 3, r).count { k ->
            val x = rounded(slot.x) + k
            val y = slot.y + rounded(-k.toDouble() * dx / h)
            abs(grid.at(x, y - 2) - grid.at(x, y + 2)) < 16
        } >= 3
    }

    private fun rimBoundary(grid: Grid, slot: Slot, dx: Double, h: Double, lower: Boolean): Int {
        var best = 0
        var distance = if (lower) -10 else 3
        val last = if (lower) -4 else 7
        while (distance <= last) {
            val samples = (-2..2).map { i ->
                val k = i * 0.08
                val d = distance * 0.01
                val x = rounded(slot.x + k * h + dx * d)
                val y = rounded(slot.y + h * d - (if (lower) 0.8 else 0.52) * dx * k)
                abs(grid.at(x, y - 2) - grid.at(x, y + 2))
            }.sorted()
            best = maxOf(best, samples[2])
            distance += 2
        }
        return best
    }

    private fun sideStrength(grid: Grid, slot: Slot, dx: Double, h: Double, side: Int): Int {
        var best = 0
        for (width in 23..27) {
            val r = (side * width) * 0.01
            val samples = doubleArrayOf(0.10, 0.24, 0.39, 0.54, 0.69, 0.84).map { t ->
                val x = rounded(slot.x + t * dx + r * h)
                val y = rounded(slot.y + t * h - r * dx)
                maxOf(abs(grid.at(x - 4, y) - grid.at(x, y)), abs(grid.at(x - 2, y) - grid.at(x + 2, y)), abs(grid.at(x, y) - grid.at(x + 4, y)))
            }.sorted()
            best = maxOf(best, (samples[2] + samples[3]) / 2)
        }
        return best
    }
}
