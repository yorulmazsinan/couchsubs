// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Bir ekran yazısının yerinde, arayüz Türkçe yapılmış gibi çizilmesi için göndericinin kareden ölçtükleri (TV pikselleri
 * okuyamaz). Yalnız yazı değişince ölçülür (Mac/iPhone: TextPaint.swift, Windows: TextPaint.cs; aynı kurallar ve
 * eşikler). TV'ye öğenin `bg`, `bg2`, `bgDir`, `bgPat`, `fg`, `weight`, `upper`, `align`, `lineH`, `cover`, `grow`,
 * `group` alanlarıyla gider; eski TV bunları yok sayıp eski çizimi sürdürür.
 */
data class TextPaint(
    /** Kutunun zemini (degradede başlangıç ucu: sol ya da üst). Opak çizilir. */
    val background: String,
    /** Satır aralığı (bir satırın üstünden ötekinin üstüne), kareye oranla; tek satırda satır yüksekliği. */
    val pitch: Double,
    /**
     * Özgün yazıyı tam örten kutu: yazı tanıma kutusu ve dışına taşan harf noktaları, en çok [TextPainter.MARGIN_MAX]
     * piksel payla. Simgeye doğru taşmaz.
     */
    val cover: TextBox,
    /** Degradenin öbür ucu (sağ ya da alt); düz zeminde null. */
    val background2: String? = null,
    /** Degradenin yönü: "h" (yatay) ya da "v" (dikey); düz zeminde null. */
    val direction: String? = null,
    /** Zemin desenli (harita, dünya): [background] ortalama renktir. */
    val patterned: Boolean = false,
    /**
     * Kutunun yana uzayabileceği alan (yalnız tek satırlık etikette, hizanın açık tarafında): o yönde başka yazı, simge
     * ya da kutu yok, yalnız oyunun zemini var. Simgeyle ya da komşuyla arada [ScreenFit.GAP_LINES] kadar boşluk kalır.
     * null: uzayamaz.
     */
    val grow: TextBox? = null,
    /**
     * Aynı listede alt alta (ya da aynı satırda) duran, özgün hâlinde aynı boydaki etiketlerin ortak numarası; grubun
     * hepsi aynı yazı boyunda çizilir. null: tek başına.
     */
    val group: Int? = null,
    /**
     * Yazı tanıma kutusunun ucundaki simge (menü simgesi, tuş simgesi) yazının hangi yanında ("left", "right"): örtü ve uzama
     * o simgeye girmez, yazı o yana yaslanır (TV'ye `align` olarak gider). null: simge yok.
     */
    val iconSide: String? = null,
    /**
     * Çizim kipi ([TextPainter.Target.kind] verilince seçilir; yalnız otomatik ekran yazısında): [MODE_COVER] örtme,
     * [MODE_BESIDE] yanına yazma, [MODE_TWIN] ikiz panel. TV'ye `mode` olarak gider; eski TV yok sayıp örter.
     */
    val mode: String = MODE_COVER,
    /** beside/twin: Türkçenin yazıldığı kutu. TV'ye `spot`. */
    val spot: TextBox? = null,
    /** [spot]'un yana uzayabileceği alan (yalnız sol ve sağ kenarı anlamlı). TV'ye `spotRoom`. */
    val spotRoom: TextBox? = null,
    /** twin: ikiz panelin kutusu (özgünle aynı boyda; yanda, altta ya da üstte). TV'ye `twinBox`. */
    val twin: TextBox? = null,
    /** twin: panelin köşe yarıçapı (ikizde), kare yüksekliğine oranla. TV'ye `radius`. */
    val radius: Double = 0.0,
    /** twin: ikizin özgüne oranı: yazı boyu ve satır aralığı bu katta. TV'ye `scale`. */
    val scale: Double = 1.0,
    /** twin: konuşma balonunun kuyruğu hangi alt köşede ("left"/"right"); null: yok. TV'ye `tail`. */
    val tail: String? = null,
    /** twin: panelin solundaki kare resim (kişi resmi): karedeki yeri ve ikiz paneldeki yeri. */
    val portrait: TextBox? = null,
    val portraitTwin: TextBox? = null,
    /** Kesilmiş resim (PNG data: adresi, en çok [TextPainter.PORTRAIT_MAX] piksel); çağıran keser. TV'ye `icon`. */
    val portraitImage: String? = null,
    /**
     * twin: özgün panelin kenar çizgisi (panelin hemen dışındaki düz renkli ince şerit; GTA 6 kartının üstündeki renkli
     * çizgi): ikiz de aynı çizgiyle çizilir. null: çizgi yok. TV'ye `edge` ({color, top, right, bottom, left}).
     */
    val edge: Edge? = null,
) {
    /** Kenar çizgisi: rengi ve her yandaki kalınlığı (kare yüksekliğine oranla; 0: o yanda çizgi yok). */
    data class Edge(val color: String, val top: Double, val right: Double, val bottom: Double, val left: Double)

    /** Bu ölçüler [area] içindeki oranlarsa, aynı yerin [area]'yı içeren çerçevedeki oranları. */
    fun placedIn(area: TextBox): TextPaint =
        copy(cover = cover.placedIn(area), grow = grow?.placedIn(area), pitch = pitch * (area.bottom - area.top),
            spot = spot?.placedIn(area), spotRoom = spotRoom?.placedIn(area), twin = twin?.placedIn(area),
            radius = radius * (area.bottom - area.top), portrait = portrait?.placedIn(area),
            portraitTwin = portraitTwin?.placedIn(area),
            edge = edge?.let {
                val h = area.bottom - area.top
                Edge(it.color, it.top * h, it.right * h, it.bottom * h, it.left * h)
            })

    /**
     * Çizim kipleri (Sinan Bey, beta.100: oyun arayüzünün hiçbir öğesi örtülmez; örtme yalnız son çare).
     * - [MODE_COVER]: türü belli olmayan yazı ("Ekranı çevir"), telefon ve hiç boş yer bulunamayan yazı: özgün yazıyı
     *   örten kutu (eski davranış).
     * - [MODE_BESIDE]: zeminsiz satır (soldaki dikey menü, sekme çubuğu, tuş/ipucu listesi, kart başlığı, oyun dünyasındaki
     *   istem): özgün yazı yerinde kalır, Türkçe arka plansız, özgün stille yanındaki boş alana yazılır. Listede bütün
     *   Türkçeler aynı tarafta, aynı boyda ve hizada.
     * - [MODE_TWIN]: kutu (görev paneli, harita mekân kartı, bildirim, ipucu kutusu, widget) örtülmez; en uygun boş yere
     *   (yan › alt › üst) özgün kutunun aynısı (zemin, kenar çizgisi, köşe, kuyruk, kişi resmi, iç boşluk, aynı yazı boyu)
     *   çizilir, Türkçenin tamamı oraya yazılır; kutu içeriğe göre uzar.
     */
    companion object {
        const val MODE_COVER = "cover"
        const val MODE_BESIDE = "beside"
        const val MODE_TWIN = "twin"
    }
}

/**
 * [TextPaint] ölçümü. Piksel erişimi soyuttur (`color(x, y)`, 0xRRGGBB): ortak deneme dosyası (fixtures/text-paint.json)
 * üç platformda aynı yapay kareyi kurar.
 */
object TextPainter {
    /** Bir noktanın rengi (0-255 kanallar). */
    data class Rgb(val r: Int, val g: Int, val b: Int)

    /**
     * Ölçülecek yazı: kareye oranla kutusu ve satır yüksekliği, özgün satır sayısı, sampler'ın bulduğu zemin/yazı rengi
     * ve hizası ("left", "center", "right").
     */
    data class Target(
        val box: TextBox, val lineHeight: Double, val rows: Int, val background: String, val foreground: String,
        val upper: Boolean, val align: String,
        /** Okunan yazının sözcük sayısı (simge sanılan karakterler sayılmaz, [words]); 0: bilinmiyor, kutunun ucundaki simge aranmaz. */
        val words: Int = 0,
        /** Yazının türü: verilirse çizim kipi seçilir ([TextPaint.mode]); null: hep örtme ("Ekranı çevir"). */
        val kind: ScreenTextKind? = null,
        /** Yazı bir tuş istemi/eylemi ("Hold L2 to aim"): düz zeminde de yanına yazılabilir. */
        val prompt: Boolean = false,
    )

    // Kip seçimi sabitleri (Mac/iPhone TextPaint.swift, Windows TextPaint.cs aynı)

    /** Panel taramasında nokta zeminden en çok bu kadar uzaksa panelin zeminidir. */
    const val PANEL_TOLERANCE = 24
    /** Bir satır/sütunun en az bu kadarı zemin (ya da yazı) ise panel o yöne sürer. */
    const val PANEL_SHARE = 0.7
    /** Panel karenin en çok bu kadarı genişlikte/yükseklikte; daha büyüğü panel sayılmaz. */
    const val PANEL_MAX_WIDTH = 0.45
    const val PANEL_MAX_HEIGHT = 0.35
    /** Panel yazının her yanında en az bu kadar satır yüksekliği (en az 2 piksel) taşmalı; taşmıyorsa düz kutudur. */
    const val PANEL_PAD_LINES = 0.2
    /**
     * Tek satırlık tek yazının kutusu (ikiz) yazıyı her yanda en çok bu kadar satır yüksekliği aşar (yanlarda yazının
     * genişliği kadar da olabilir); yalnız tuş istemlerinin kutusu her yanda en çok [PROMPT_PAD_LINES]. Daha büyük düz alan
     * (koyu oyun dünyası, ekranın altındaki karartı) kutu değildir: ikizi dev bir kutu olurdu (beta.103, TCL Android TV;
     * Mac TextPainter.labelPadLines, Windows LabelPadLines aynı).
     */
    const val LABEL_PAD_LINES = 3.0
    const val PROMPT_PAD_LINES = 2.5
    /** Köşe yuvarlak: köşeden köşegen boyunca en az bu kadar nokta zemin değil (aynı kenardaki iki köşede). */
    const val CORNER_MIN = 2
    /** Yanına yazmada yazı rengine bu kadar yakın noktaların payı [BESIDE_SHARE]'den azsa alan boştur. */
    const val BESIDE_INK = 48
    const val BESIDE_SHARE = 0.1
    /** Türkçenin özgün yazıdan uzaklığı, satır yüksekliğinin katı. */
    const val BESIDE_GAP_LINES = 0.5
    /** Yanına yazma alanı en çok özgün yazının bu katı (+ bir satır yüksekliği) genişlikte taranır. */
    const val BESIDE_MAX = 1.6
    /**
     * Listede (grup) Türkçe sütunu özgün yazıdan en çok bu kadar satır yüksekliği uzakta olabilir (kısa satırla sütun
     * arasındaki boşluk da boş olmalı).
     */
    const val BESIDE_REACH_LINES = 12.0
    /** İkiz panel özgün panelle aynı boyda (Sinan Bey, beta.100: "AYNI punto, küçültme yok"; #1296'daki 0,58 kalktı). */
    const val TWIN_SCALE = 1.0
    /** İkizdeki yazı özgün panelin genişliğini en çok bu katı kadar aşabilir (boş yer varsa; kutu içeriğe göre uzar). */
    const val TWIN_WIDEN = 0.5
    /** Kenar çizgisi en çok bu kadar piksel kalın aranır. */
    const val EDGE_MAX = 8
    /** Kişi resmi en çok bu kadar piksel kenarlı kesilir. */
    const val PORTRAIT_MAX = 40

    /** Piksel kutusu ([l, r) x [t, b)). */
    data class Box(val l: Int, val t: Int, val r: Int, val b: Int)

    /** [spot] sonucu: yazı kutusu (piksel) ve uzayabileceği sol/sağ sınır. */
    data class Spot(val l: Int, val t: Int, val r: Int, val b: Int, val roomL: Int, val roomR: Int)

    /** Yanına yazma yönü. */
    enum class Side { LEFT, RIGHT, BELOW, ABOVE }

    /** Yanına yazma için bir hedefin çevresindeki boş alan (piksel; döngüde ölçülür, kip kararı döngüden sonra verilir). */
    data class Room(
        /** Örtü kutusu ve satır yüksekliği. */
        val l: Int, val t: Int, val r: Int, val b: Int, val line: Double,
        /**
         * Türkçenin özgünden uzaklığı ([BESIDE_GAP_LINES]), öbür uçta engelden uzaklığı ([ScreenFit.GAP_LINES]) ve en
         * çok genişliği ([BESIDE_MAX]).
         */
        val near: Int, val far: Int, val most: Int,
        val iconLeft: Boolean, val iconRight: Boolean,
        /** Örtünün solundan/sağından art arda boş sütun sayısı (en çok [cap]; azsa alan bir engelle bitti). */
        val left: Int = 0, val right: Int = 0, val cap: Int = 0,
        /** Altından/üstünden art arda boş satır sayısı. */
        val down: Int = 0, val up: Int = 0,
        /** Altındaki/üstündeki yazı şeridinde solda/sağda art arda boş sütun (en çok [side] + [far]). */
        val downLeft: Int = 0, val downRight: Int = 0, val upLeft: Int = 0, val upRight: Int = 0, val side: Int = 0,
    )

    /** [edges] sonucu: çizginin rengi ve her yandaki kalınlığı (piksel). */
    data class Edges(val color: Rgb, val top: Int, val right: Int, val bottom: Int, val left: Int)

    /** [cornerRadius] sonucu: yarıçap (piksel) ve kuyruk. */
    data class Corner(val radius: Double, val tail: String?)

    /**
     * Yazının (örtü kutusu) çevresindeki düz alan: kutu, satır/sütunlarının en az [PANEL_SHARE]'i zemin ([like]) olduğu
     * sürece dört yana büyür. Karenin kenarına değen ya da çok büyük alan açık zemindir: null.
     */
    internal fun findPanel(l: Int, t: Int, r: Int, b: Int, width: Int, height: Int, like: (Int, Int) -> Boolean): Box? {
        fun row(y: Int, x0: Int, x1: Int): Boolean {
            val step = max(1, (x1 - x0) / 64)
            var n = 0
            var ok = 0
            var x = x0
            while (x < x1) {
                n++
                if (like(x, y)) ok++
                x += step
            }
            return n > 0 && ok >= PANEL_SHARE * n
        }
        fun column(x: Int, y0: Int, y1: Int): Boolean {
            val step = max(1, (y1 - y0) / 64)
            var n = 0
            var ok = 0
            var y = y0
            while (y < y1) {
                n++
                if (like(x, y)) ok++
                y += step
            }
            return n > 0 && ok >= PANEL_SHARE * n
        }
        if (r <= l || b <= t) return null
        val maxW = (PANEL_MAX_WIDTH * width).toInt()
        val maxH = (PANEL_MAX_HEIGHT * height).toInt()
        var pl = max(0, l)
        var pt = max(0, t)
        var pr = min(width, r)
        var pb = min(height, b)
        var grew = true
        while (grew) {
            grew = false
            while (pl > 0 && column(pl - 1, pt, pb)) {
                pl--
                grew = true
                if (pr - pl > maxW) return null
            }
            while (pr < width && column(pr, pt, pb)) {
                pr++
                grew = true
                if (pr - pl > maxW) return null
            }
            while (pt > 0 && row(pt - 1, pl, pr)) {
                pt--
                grew = true
                if (pb - pt > maxH) return null
            }
            while (pb < height && row(pb, pl, pr)) {
                pb++
                grew = true
                if (pb - pt > maxH) return null
            }
        }
        if (pl == 0 || pt == 0 || pr == width || pb == height) return null
        return Box(pl, pt, pr, pb)
    }

    /**
     * Panelin köşe yarıçapı (piksel) ve balonun kuyruğu: köşeler ([ground]) köşegen boyunca taranır; üst ya da alt kenarın
     * iki köşesinde en az [CORNER_MIN] nokta zemin değilse panel yuvarlaktır. Üst köşeler yuvarlakken alt köşelerden
     * yalnız biri köşeliyse orada kuyruk vardır. null: köşeli kutu.
     */
    internal fun cornerRadius(l: Int, t: Int, r: Int, b: Int, ground: (Int, Int) -> Boolean): Corner? {
        val limit = max(1, min(r - l, b - t) / 4)
        fun corner(x: Int, y: Int, dx: Int, dy: Int): Int {
            var k = 0
            while (k <= limit && !ground(x + dx * k, y + dy * k)) k++
            return k
        }
        val tl = corner(l, t, 1, 1)
        val tr = corner(r - 1, t, -1, 1)
        val bl = corner(l, b - 1, 1, -1)
        val br = corner(r - 1, b - 1, -1, -1)
        fun round(k: Int) = k >= CORNER_MIN && k <= limit
        val top = round(tl) && round(tr)
        val bottom = round(bl) && round(br)
        if (!top && !bottom) return null
        val ks = (if (top) listOf(tl, tr) else emptyList()) + (if (bottom) listOf(bl, br) else emptyList())
        val radius = ks.sum().toDouble() / ks.size / (1 - 1 / sqrt(2.0))
        val tail = if (!top || bottom) null else if (!round(bl) && round(br)) "left" else if (round(bl) && !round(br)) "right" else null
        return Corner(radius, tail)
    }

    /**
     * Panelin solundaki kare resim (kişi resmi): panelin solu ile yazının arası, yazının satırı çevresinde; [off]
     * noktalarının sınırı. En az 0,8 satır yüksekliği (en az 6 piksel), en çok 4 satır, kareye yakın ve yazıdan ayrıksa.
     */
    internal fun portrait(panelLeft: Int, panelTop: Int, panelBottom: Int, l: Int, t: Int, b: Int, line: Double,
                          off: (Int, Int) -> Boolean): Box? {
        val x0 = panelLeft + 2
        val x1 = l
        val y0 = max(panelTop + 2, t - round(line))
        val y1 = min(panelBottom - 2, b + round(line))
        if (x1 <= x0 || y1 <= y0) return null
        var minX = Int.MAX_VALUE
        var minY = Int.MAX_VALUE
        var maxX = -1
        var maxY = -1
        for (y in y0 until y1) for (x in x0 until x1) if (off(x, y)) {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        if (maxX < 0) return null
        val w = maxX - minX + 1
        val h = maxY - minY + 1
        val least = max(6, round(0.8 * line))
        if (w < least || h < least || w > 4 * line || h > 4 * line || w < 0.75 * h || w > 1.33 * h ||
            maxX + 1 + max(2, round(ScreenFit.GAP_LINES * line)) > l) return null
        return Box(minX, minY, maxX + 1, maxY + 1)
    }

    /**
     * Kişi resmini kareden keser: en çok [largest] piksel kenarlı (en yakın nokta), opak PNG data: adresi. [largest]:
     * çıktının en uzun kenarı (telefon listesinin avatarı [PhoneListLook.AVATAR_MAX]); varsayılan [PORTRAIT_MAX].
     */
    fun portraitImage(box: TextBox, width: Int, height: Int, color: (Int, Int) -> Int, largest: Int = PORTRAIT_MAX): String? {
        val l = max(0, round(box.left * width))
        val t = max(0, round(box.top * height))
        val r = min(width, round(box.right * width))
        val b = min(height, round(box.bottom * height))
        if (r - l < 2 || b - t < 2) return null
        val side = max(r - l, b - t)
        val ow = max(1, min(r - l, (r - l) * largest / side))
        val oh = max(1, min(b - t, (b - t) * largest / side))
        val rgb = ByteArray(ow * oh * 3)
        for (j in 0 until oh) for (i in 0 until ow) {
            val c = color(l + i * (r - l) / ow, t + j * (b - t) / oh)
            val p = (j * ow + i) * 3
            rgb[p] = (c shr 16).toByte()
            rgb[p + 1] = (c shr 8).toByte()
            rgb[p + 2] = c.toByte()
        }
        return "data:image/png;base64," + java.util.Base64.getEncoder().encodeToString(ButtonIcons.pngRgb(rgb, ow, oh))
    }

    /**
     * Boş alan ölçümü. [free]: null başka hedef ya da simge (alan orada biter), true yazı rengine yakın nokta, false boş
     * zemin. Bir sütun/satır, yazı rengindeki noktaları [BESIDE_SHARE]'den azsa boştur.
     */
    internal fun measureRoom(l: Int, t: Int, r: Int, b: Int, line: Double, width: Int, height: Int, iconLeft: Boolean,
                             iconRight: Boolean, free: (Int, Int) -> Boolean?): Room {
        val w = r - l
        val h = b - t
        val near = max(2, round(BESIDE_GAP_LINES * line))
        val far = max(1, ceil(ScreenFit.GAP_LINES * line).toInt())
        val most = round(BESIDE_MAX * max(0, w) + line)
        val base = Room(l, t, r, b, line, near, far, most, iconLeft, iconRight)
        if (w <= 0 || h <= 0 || t < 0 || b > height) return base
        fun open(cells: List<Boolean?>): Boolean {
            if (cells.isEmpty() || cells.any { it == null }) return false
            return cells.count { it == true } < BESIDE_SHARE * cells.size
        }
        fun column(x: Int, y0: Int, y1: Int): Boolean {
            if (x < 0 || x >= width || y0 < 0 || y1 > height || y1 <= y0) return false
            return open((y0 until y1).map { free(x, it) })
        }
        fun row(y: Int, x0: Int, x1: Int): Boolean {
            if (y < 0 || y >= height || x0 < 0 || x1 > width || x1 <= x0) return false
            return open((x0 until x1).map { free(it, y) })
        }
        fun run(x: Int, step: Int, y0: Int, y1: Int, cap: Int): Int {
            var n = 0
            while (n < cap && column(x + step * n, y0, y1)) n++
            return n
        }
        fun rows(y: Int, step: Int, cap: Int): Int {
            var n = 0
            while (n < cap && row(y + step * n, l, r)) n++
            return n
        }
        val cap = min(width, near + most + far + round(BESIDE_REACH_LINES * line))
        val vertical = near + 2 * h
        val side = w / 2
        val low = b + near
        val high = t - near - h
        val down = low + h <= height
        val up = high >= 0
        return base.copy(
            cap = cap,
            left = if (iconLeft) 0 else run(l - 1, -1, t, b, cap),
            right = if (iconRight) 0 else run(r, 1, t, b, cap),
            down = rows(b + near, 1, vertical),
            up = rows(t - near - 1, -1, vertical),
            side = side,
            downLeft = if (down) run(l - 1, -1, low, low + h, side + far) else 0,
            downRight = if (down) run(r, 1, low, low + h, side + far) else 0,
            upLeft = if (up) run(l - 1, -1, high, high + h, side + far) else 0,
            upRight = if (up) run(r, 1, high, high + h, side + far) else 0,
        )
    }

    /**
     * Yanına yazma yeri (Sinan Bey: "SELAMLA  GREET"; beta.100: menülerde de). [edge]: listede ortak kenar (solda
     * Türkçenin sağ kenarı, sağda sol kenarı, altta üstü, üstte altı); null: hedefin kendi kenarından yakın boşluk kadar.
     * Solda/sağda alan en az örtü genişliğinde olmalı (Türkçe `most`'a kadar uzar); altta/üstte örtü yüksekliği kadar satır
     * boş olmalı (Türkçe iki yana yarım genişliğe kadar uzar). Simgenin olduğu yana yazılmaz.
     */
    internal fun spot(m: Room, side: Side, edge: Int?): Spot? {
        val w = m.r - m.l
        val h = m.b - m.t
        if (w <= 0 || h <= 0) return null
        fun usable(n: Int, cap: Int) = n - (if (n < cap) m.far else 0)
        fun spreadL(left: Int) = m.l - max(0, min(m.side, usable(left, m.side + m.far)))
        fun spreadR(right: Int) = m.r + max(0, min(m.side, usable(right, m.side + m.far)))
        when (side) {
            Side.LEFT -> {
                if (m.iconLeft) return null
                val e = edge ?: (m.l - m.near)
                val gap = m.l - e
                if (gap < m.near) return null
                val room = min(m.most, usable(m.left, m.cap) - gap)
                if (room < w) return null
                return Spot(e - w, m.t, e, m.b, e - room, e)
            }
            Side.RIGHT -> {
                if (m.iconRight) return null
                val e = edge ?: (m.r + m.near)
                val gap = e - m.r
                if (gap < m.near) return null
                val room = min(m.most, usable(m.right, m.cap) - gap)
                if (room < w) return null
                return Spot(e, m.t, e + w, m.b, e, e + room)
            }
            Side.BELOW -> {
                val top = edge ?: (m.b + m.near)
                if (top - m.b < m.near || m.down < top + h - (m.b + m.near)) return null
                return Spot(m.l, top, m.r, top + h, spreadL(m.downLeft), spreadR(m.downRight))
            }
            Side.ABOVE -> {
                val bottom = edge ?: (m.t - m.near)
                if (m.t - bottom < m.near || bottom - h < 0 || m.up < (m.t - m.near) - (bottom - h)) return null
                return Spot(m.l, bottom - h, m.r, bottom, spreadL(m.upLeft), spreadR(m.upRight))
            }
        }
    }

    /**
     * Panelin ([l, r) x [t, b)) kenar çizgisi: her yanda panelin hemen dışındaki 1…[EDGE_MAX] piksellik düz renkli şerit
     * (satır/sütun noktalarının en az %80'i ortalamasına [PANEL_TOLERANCE] kadar yakın, zeminden uzak) ve ötesinde o renk
     * biter. Çizginin rengi ilk bulunan yanınki; öbür yanlar ancak aynı renkteyse. null: çizgi yok.
     */
    internal fun edges(l: Int, t: Int, r: Int, b: Int, width: Int, height: Int, ground: Rgb,
                       blocked: (Int, Int) -> Boolean, color: (Int, Int) -> Rgb): Edges? {
        fun inside(p: Pair<Int, Int>) = p.first >= 0 && p.first < width && p.second >= 0 && p.second < height
        /** Yanın k. dış çizgisinin rengi (düzse). */
        fun strip(points: List<Pair<Int, Int>>): Rgb? {
            if (points.isEmpty() || !points.all { inside(it) } || points.any { blocked(it.first, it.second) }) return null
            val colors = points.map { color(it.first, it.second) }
            val average = mean(colors)
            if (colors.count { distance(it, average) <= PANEL_TOLERANCE } < 0.8 * colors.size) return null
            return average
        }
        fun horizontal(y: Int): List<Pair<Int, Int>> {
            val step = max(1, (r - l) / 32)
            return (l until r step step).map { it to y }
        }
        fun vertical(x: Int): List<Pair<Int, Int>> {
            val step = max(1, (b - t) / 32)
            return (t until b step step).map { x to it }
        }
        var reference: Rgb? = null
        /** Kalınlık: `line(k)` (k = 1, 2, …) aynı renkte sürdükçe; [EDGE_MAX]'a varan ya da karenin kenarına değen şerit çizgi değildir. */
        fun thickness(line: (Int) -> List<Pair<Int, Int>>): Int {
            val first = strip(line(1)) ?: return 0
            if (distance(first, ground) <= PANEL_TOLERANCE) return 0
            if (reference?.let { distance(it, first) <= PANEL_TOLERANCE } == false) return 0
            var k = 1
            while (k < EDGE_MAX) {
                val next = strip(line(k + 1)) ?: break
                if (distance(next, first) > PANEL_TOLERANCE) break
                k++
            }
            if (k >= EDGE_MAX || !line(k + 1).all { inside(it) }) return 0
            if (reference == null) reference = first
            return k
        }
        val top = thickness { horizontal(t - it) }
        val bottom = thickness { horizontal(b - 1 + it) }
        val left = thickness { vertical(l - it) }
        val right = thickness { vertical(r - 1 + it) }
        val ref = reference ?: return null
        if (top + bottom + left + right <= 0) return null
        return Edges(ref, top, right, bottom, left)
    }

    /** Nokta zeminden bu kadar (en büyük renk bileşeni farkı) uzak ve yazı rengine zeminden yakınsa harf noktasıdır. */
    const val INK_DISTANCE = 40
    /** Bir satır/sütunun en az bu kadarı harf noktasıysa orada yazı sürer. */
    const val INK_SHARE = 0.03
    /** Kutu yazı tanıma kutusunun dışına en çok bu kadar satır yüksekliği uzar (taşan harf ucu). */
    const val REACH_LINES = 0.5
    /** Kenar payı: satır yüksekliğinin bu kadarı, en az 1, en çok [MARGIN_MAX] piksel. */
    const val MARGIN_LINES = 0.08
    const val MARGIN_MAX = 3
    /** İki uç arasındaki fark (en büyük renk bileşeni) en az bu kadarsa zemin degradedir. */
    const val GRADIENT_STEP = 10
    /** Zeminin kendi içindeki sapması bundan büyükse zemin desenlidir. */
    const val PATTERN_DEVIATION = TextStyleSampler.FLAT_DEVIATION
    /** Kenar şeridinin ortalaması sampler'ın zemininden bu kadar uzaksa (seçili satırın kendi kutusu dar) sampler'ınki kalır. */
    const val TRUST_DISTANCE = 48
    /** Boş alan en çok bu kadar satır yüksekliği taranır. */
    const val GROW_LINES = 12.0
    /** Aynı grup: satır yükseklikleri en çok bu oranda farklı ([ScreenFit.SAME_LINE]). */
    const val SAME_LINE = ScreenFit.SAME_LINE

    /**
     * Kutunun ucundaki simgeyi yazıdan ayıran en dar boşluk, satır yüksekliğinin katı (harf arası bundan dardır; GTA 6
     * menüsünde simgeyle yazı arası ~0,4 satır).
     */
    const val ICON_GAP_LINES = 0.3
    /** Simge parçasının genişliği satır yüksekliğinin bu katları arasında ("I" harfi gibi ince parça simge sayılmaz). */
    const val ICON_MIN_WIDE = 0.45
    const val ICON_MAX_WIDE = 1.6
    /** Simge sanılıp yazı olarak okunan karakterler (GTA 6 menü simgesi "I", "II"; tuş simgeleri). */
    private const val ICON_GLYPHS = "I|l![]()©®@○◯●□■△▲✕✖×◎⊗⊙"

    /**
     * Okunan yazının sözcük sayısı: simge sanılan bir iki karakterlik parçalar ve harfi/rakamı olmayan parçalar sayılmaz
     * ("I Map" → 1, "SELECT ⊗" → 1, "- SMASH 'N' GRABS" → 3, "• Objective" → 1). Menü simgesi (yön tuşu, renkli nokta)
     * "-", "•", "+" diye okununca sözcük sayılıyor, simge bulunmuyordu: kutu simgenin üstüne çiziliyordu (#1268, #1270;
     * Mac/iPhone, Windows ile aynı).
     */
    fun words(text: String): Int =
        IconText.plain(text).split(Regex("\\s+")).filter { it.isNotEmpty() }
            .count { token -> !(token.length <= 2 && token.all { it in ICON_GLYPHS }) && token.any { it.isLetterOrDigit() } }

    /** Simge parçası: [l, r) piksel sütunları. */
    data class Span(val l: Int, val r: Int)

    /** [iconSpans] sonucu: simgeler ve onlar çıkınca yazının sol/sağ kenarı. */
    data class Icons(val left: Span?, val right: Span?, val textLeft: Int, val textRight: Int)

    /**
     * Kutunun ([l, r), piksel) ucundaki simge: harf sütunları ([ink]) [ICON_GAP_LINES] satırdan geniş boşluklarla parçalara
     * bölünür; parça sayısı sözcük sayısından çoksa uçtaki simge genişliğindeki ([ICON_MIN_WIDE]-[ICON_MAX_WIDE] satır)
     * parça simgedir. İki uç da uyarsa hizanın yanı (sola yaslıda sol, öbürlerinde sağ) önce; ikincisi ancak iki fazla parça
     * varsa. Simgeler çıkınca kalan parça sözcüklerden çoksa simge yoktur.
     */
    fun iconSpans(l: Int, r: Int, line: Double, words: Int, align: String, ink: (Int) -> Boolean): Icons {
        val none = Icons(null, null, l, r)
        if (words <= 0 || r - l < 2) return none
        val gap = max(2, round(ICON_GAP_LINES * line))
        val spans = mutableListOf<Span>()
        var start: Int? = null
        var last = l
        var blank = 0
        for (x in l until r) {
            if (ink(x)) {
                if (start == null) start = x
                last = x
                blank = 0
            } else if (start != null) {
                blank++
                if (blank >= gap) {
                    spans.add(Span(start, last + 1))
                    start = null
                    blank = 0
                }
            }
        }
        start?.let { spans.add(Span(it, last + 1)) }
        if (spans.size < 2 || spans.size <= words) return none
        fun isIcon(span: Span): Boolean {
            val wide = (span.r - span.l).toDouble()
            return wide >= ICON_MIN_WIDE * line && wide <= ICON_MAX_WIDE * line
        }
        val extra = spans.size - words
        val first = spans.first()
        val end = spans.last()
        var left: Span? = null
        var right: Span? = null
        if (align == "left") {
            if (isIcon(first)) left = first
            if (isIcon(end) && (left == null || extra >= 2)) right = end
        } else {
            if (isIcon(end)) right = end
            if (isIcon(first) && (right == null || extra >= 2)) left = first
        }
        // Simgeler çıkınca kalan parçalar sözcüklerden çok olamaz: harfleri aralıklı tek sözcük simge sanılmaz.
        if (spans.size - (if (left == null) 0 else 1) - (if (right == null) 0 else 1) > words) return none
        return Icons(left, right, if (left != null) spans[1].l else l, if (right != null) spans[spans.size - 2].r else r)
    }

    private class Sample(val c: Rgb, val fx: Double, val top: Boolean)

    /** Swift `rounded()` gibi: yarım sıfırdan uzağa. */
    private fun round(value: Double): Int = if (value >= 0) floor(value + 0.5).toInt() else -floor(-value + 0.5).toInt()

    private fun rgbOf(value: Int) = Rgb((value shr 16) and 255, (value shr 8) and 255, value and 255)

    /** Ölçümler (hedeflerle aynı sırada). [width]/[height]: karenin piksel boyu; [color]: (x, y) noktası, 0xRRGGBB. */
    fun paints(targets: List<Target>, width: Int, height: Int, color: (Int, Int) -> Int): List<TextPaint> {
        if (width <= 0 || height <= 0) return emptyList()
        val fw = width.toDouble()
        val fh = height.toDouble()
        val pixel = { x: Int, y: Int -> rgbOf(color(x, y)) }
        // Hedeflerin piksel kutuları (öbür hedefler engeldir); karenin dışına taşan kutu kareye kırpılır (#1255).
        fun px(v: Double, size: Int, up: Boolean): Int {
            if (!v.isFinite()) return if (v > 0) size else 0
            val p = if (up) ceil(v * size) else floor(v * size)
            return p.coerceIn(0.0, size.toDouble()).toInt()
        }
        val rects = targets.map { t ->
            Box(px(t.box.left, width, false), px(t.box.top, height, false), px(t.box.right, width, true), px(t.box.bottom, height, true))
        }
        val result = mutableListOf<TextPaint>()
        // Kip seçimi için: örtü kutuları (piksel), satır yükseklikleri, zeminler ve panel adayları.
        val covers = mutableListOf<Box>()
        val lines = mutableListOf<Double>()
        val grounds = mutableListOf<Rgb>()
        val panels = sortedMapOf<Int, Box>()
        // Yanına yazma için her hedefin çevresindeki boş alan (yalnız kipi seçilen yazıda).
        val rooms = mutableListOf<Room?>()
        fun rectHit(x: Int, y: Int, except: Int?): Boolean = rects.indices.any { j ->
            j != except && x >= rects[j].l && x < rects[j].r && y >= rects[j].t && y < rects[j].b
        }
        for ((index, target) in targets.withIndex()) {
            val bg = rgb(target.background)
            val fg = rgb(target.foreground)
            val line = max(1.0, target.lineHeight * fh)
            fun isInk(c: Rgb): Boolean {
                val toBg = distance(c, bg)
                return toBg > INK_DISTANCE && distance(c, fg) < toBg
            }
            // Kutunun ucundaki kendi simgesi (0. adım): öbür hedefler gibi engeldir; araya `GAP_LINES` boşluk kalır.
            val zones = mutableListOf<Span>()
            fun others(x: Int, y: Int): Boolean = zones.any { x >= it.l && x < it.r } || rects.indices.any { j ->
                j != index && x >= rects[j].l && x < rects[j].r && y >= rects[j].t && y < rects[j].b
            }
            fun inkRow(y: Int, x0: Int, x1: Int): Boolean {
                if (y < 0 || y >= height || x1 <= x0) return false
                val step = max(1, (x1 - x0) / 200)
                var n = 0
                var ink = 0
                var x = max(0, x0)
                val end = min(width, x1)
                while (x < end) {
                    if (others(x, y)) return false
                    n++
                    if (isInk(pixel(x, y))) ink++
                    x += step
                }
                return n > 0 && ink >= max(2, ceil(INK_SHARE * n).toInt())
            }
            fun inkColumn(x: Int, y0: Int, y1: Int): Boolean {
                if (x < 0 || x >= width || y1 <= y0) return false
                var n = 0
                var ink = 0
                for (y in max(0, y0) until min(height, y1)) {
                    if (others(x, y)) return false
                    n++
                    if (isInk(pixel(x, y))) ink++
                }
                return n > 0 && ink >= max(1, ceil(INK_SHARE * n).toInt())
            }
            val own = rects[index]
            var l = own.l
            var t = own.t
            var r = own.r
            var b: Int
            // 0) Kutunun ucundaki simge (#1266, #1267): yazı tanıma kutusu menü/tuş simgesini de alıyordu; kutu simgenin
            // üstüne çiziliyor, simge kayboluyordu. Simge kutudan çıkar ve engel olur: örtü, kenar payı ve uzama ona girmez.
            var iconLeft = false
            var iconRight = false
            if (target.rows <= 1) {
                val found = iconSpans(l, r, line, target.words, target.align) { at -> inkColumn(at, own.t, own.b) }
                val keep = ceil(ScreenFit.GAP_LINES * line).toInt()
                found.left?.let { zones.add(Span(it.l - keep, it.r + keep)); iconLeft = true }
                found.right?.let { zones.add(Span(it.l - keep, it.r + keep)); iconRight = true }
                l = found.textLeft
                r = found.textRight
            }
            val textLeft = l
            val textRight = r
            // 1) Örtü: yazı tanıma kutusunun dışına taşan harf noktaları (bitişik satır/sütunlar) kutuya katılır.
            val reach = max(1, round(REACH_LINES * line))
            var y = own.b
            while (y < min(height, own.b + reach) && inkRow(y, l, r)) y++
            b = y
            y = t - 1
            while (y >= max(0, own.t - reach) && inkRow(y, l, r)) y--
            t = y + 1
            var x = r
            while (x < min(width, textRight + reach) && inkColumn(x, t, b)) x++
            r = x
            x = l - 1
            while (x >= max(0, textLeft - reach) && inkColumn(x, t, b)) x--
            l = x + 1
            // Kenar payı: yazının yanındaki boş noktalar; ötesinde başka yazı/simge varsa pay ona değmez.
            val margin = max(1, min(MARGIN_MAX, round(MARGIN_LINES * line)))
            fun pad(blank: (Int) -> Boolean): Int {
                var k = 0
                while (k < margin && blank(k + 1)) k++
                return k
            }
            val padL = pad { k -> l - k >= 0 && !inkColumn(l - k, t, b) && (t until b).none { others(l - k, it) } }
            val padR = pad { k -> r - 1 + k < width && !inkColumn(r - 1 + k, t, b) && (t until b).none { others(r - 1 + k, it) } }
            val padT = pad { k -> t - k >= 0 && !inkRow(t - k, l, r) }
            val padB = pad { k -> b - 1 + k < height && !inkRow(b - 1 + k, l, r) }
            val cl = l - padL
            val cr = r + padR
            val ct = t - padT
            val cb = b + padB
            val cover = TextBox(cl / fw, ct / fh, cr / fw, cb / fh)

            // 2) Zemin: kutunun üstündeki ve altındaki şerit (yanlarda simge olabilir); sol/sağ üçte bir ve üst/alt farkı.
            val strip = max(2, round(0.25 * line))
            val samples = mutableListOf<Sample>()
            fun collect(y0: Int, y1: Int, top: Boolean) {
                if (y0 < 0 || y1 > height || y1 <= y0) return
                val step = max(1, (cr - cl) / 64)
                val rowStep = max(1, (y1 - y0) / 4)
                val found = mutableListOf<Sample>()
                var yy = y0
                while (yy < y1) {
                    var xx = max(0, cl)
                    val end = min(width, cr)
                    while (xx < end) {
                        if (others(xx, yy)) return
                        val c = pixel(xx, yy)
                        if (!isInk(c)) found.add(Sample(c, (xx - cl).toDouble() / max(1, cr - cl - 1), top))
                        xx += step
                    }
                    yy += rowStep
                }
                samples += found
            }
            collect(ct - strip, ct, top = true)
            collect(cb, cb + strip, top = false)
            var paint = TextPaint(target.background, pitch(target), cover,
                iconSide = if (iconLeft == iconRight) null else if (iconLeft) "left" else "right")
            if (samples.size >= 16) {
                val all = samples.map { it.c }
                val average = mean(all)
                if (distance(average, bg) <= TRUST_DISTANCE) {
                    val left = samples.filter { it.fx < 1.0 / 3 }.map { it.c }
                    val right = samples.filter { it.fx > 2.0 / 3 }.map { it.c }
                    val above = samples.filter { it.top }.map { it.c }
                    val below = samples.filter { !it.top }.map { it.c }
                    // Desen: her parçanın kendi içindeki sapması (degrade kendi başına desen sayılmaz).
                    val parts = listOf(true, false).flatMap { side ->
                        (0 until 3).map { third -> samples.filter { it.top == side && min(2, (it.fx * 3).toInt()) == third }.map { it.c } }
                    }.filter { it.size >= 4 }
                    val spread = if (parts.isEmpty()) deviation(all) else parts.sumOf { deviation(it) } / parts.size
                    val dh = if (left.size >= 4 && right.size >= 4) distance(mean(left), mean(right)) else 0
                    val dv = if (above.size >= 4 && below.size >= 4) distance(mean(above), mean(below)) else 0
                    paint = when {
                        spread > PATTERN_DEVIATION -> paint.copy(patterned = true, background = hex(average))
                        dh >= GRADIENT_STEP && dh >= dv -> {
                            // Üçte birlerin ortası 1/6 ve 5/6'da: uçlara doğrusal uzatılır.
                            val a = mean(left)
                            val z = mean(right)
                            paint.copy(background = hex(extend(a, z, 0.25)), background2 = hex(extend(z, a, 0.25)), direction = "h")
                        }
                        dv >= GRADIENT_STEP -> {
                            val a = mean(above)
                            val z = mean(below)
                            // Şeritlerin ortası kutunun yarım şerit dışında: uçlar içeri doğru aradeğerlenir.
                            val span = (cb - ct + strip).toDouble()
                            val inward = if (span > 0) strip.toDouble() / 2 / span else 0.0
                            paint.copy(background = hex(extend(a, z, -inward)), background2 = hex(extend(z, a, -inward)), direction = "v")
                        }
                        else -> paint.copy(background = hex(average))
                    }
                }
            }

            // 3) Boş alan: tek satırlık etiket hizasının açık tarafına (sağa yaslıda sola, sola yaslıda sağa, ortalıda iki
            // yana) uzayabilir; başka yazıya, simgeye, kutu kenarına ya da karenin kenarına `GAP_LINES` kala durur. Kutunun
            // ucunda simge varsa yalnız simgenin öbür yanına uzar (sağdaki tuş simgesinde sola, soldaki menü simgesinde sağa).
            if (target.rows <= 1) {
                val sixth = max(1, (cb - ct) / 6)
                val band = mutableListOf<Int>()
                run {
                    var yy = ct + sixth
                    val end = max(ct + 1, cb - sixth)
                    while (yy < end) {
                        band.add(min(height - 1, max(0, yy)))
                        yy += sixth
                    }
                }
                val gap = ceil(ScreenFit.GAP_LINES * line).toInt()
                val limit = round(GROW_LINES * line)
                fun scan(start: Int, step: Int, first: Rgb): Int {
                    var ground = first
                    var at = start
                    val end = if (step < 0) max(-1, start - limit) else min(width, start + limit)
                    // Sınır karşılaştırması ve adım sınırı: başlangıç karenin dışında kalsa da döngü biter (#1255).
                    var steps = 0
                    while ((if (step < 0) at > end else at < end) && at >= 0 && at < width && steps <= width) {
                        steps++
                        if (band.any { others(at, it) } || rects.indices.any { j ->
                                j != index && at >= rects[j].l && at < rects[j].r && rects[j].b > ct && rects[j].t < cb
                            }) return at - step * gap
                        var sr = 0
                        var sg = 0
                        var sb = 0
                        for (yy in band) {
                            val c = pixel(at, yy)
                            if (distance(c, ground) > ScreenFit.INK_DISTANCE) return at - step * gap
                            sr += c.r
                            sg += c.g
                            sb += c.b
                        }
                        val n = band.size
                        // Degrade zeminde zemin yavaşça izlenir (ScreenFit.withRoom ile aynı).
                        ground = Rgb((ground.r * 7 + sr / n) / 8, (ground.g * 7 + sg / n) / 8, (ground.b * 7 + sb / n) / 8)
                        at += step
                    }
                    return if (step < 0) max(0, end + 1) else min(width, end)
                }
                val startColor = rgb(paint.background)
                val endColor = rgb(paint.background2 ?: paint.background)
                var gl = cl
                var gr = cr
                val toLeft = !iconLeft && (target.align != "left" || iconRight)
                val toRight = !iconRight && (target.align != "right" || iconLeft)
                if (band.isNotEmpty() && toLeft) gl = min(cl, max(0, scan(cl - 1, -1, startColor) + 1))
                if (band.isNotEmpty() && toRight) gr = max(cr, min(width, scan(cr, 1, endColor)))
                if (gl < cl || gr > cr) paint = paint.copy(grow = TextBox(gl / fw, cover.top, gr / fw, cover.bottom))
            }

            // 5) Kip (yalnız türü verilen yazıda; telefon hep örtülür): düz zemini sınırlı bir alansa (panel) karar döngüden
            // sonra panel panel verilir (kutu: ikiz; listedeki satırın kendi şeridi/vurgusu: yanına yazma). Açık zeminde
            // (desenli zemin, degrade, karenin kenarına değen ya da çok büyük düz alan) Türkçe yanındaki boş alana yazılır;
            // listede bütün satırlar birlikte (aynı yan, aynı hiza). Yer bulunamazsa örtülür.
            covers.add(Box(cl, ct, cr, cb))
            lines.add(line)
            grounds.add(rgb(paint.background))
            val kind = target.kind
            if (kind != null && kind != ScreenTextKind.PHONE) {
                val ground = rgb(paint.background)
                val panel = if (paint.patterned || paint.background2 != null) null
                else findPanel(cl, ct, cr, cb, width, height) { px, py ->
                    if (rectHit(px, py, index) || (px >= cl && px < cr && py >= ct && py < cb)) true
                    else distance(pixel(px, py), ground) <= PANEL_TOLERANCE
                }
                if (panel != null) panels[index] = panel
                rooms.add(measureRoom(cl, ct, cr, cb, line, width, height, iconLeft, iconRight) { px, py ->
                    if (others(px, py)) null else distance(pixel(px, py), fg) <= BESIDE_INK
                })
            } else {
                rooms.add(null)
            }
            result.add(paint)
        }
        fun overlaps(a: Box, b: Box) = min(a.r, b.r) > max(a.l, b.l) && min(a.b, b.b) > max(a.t, b.t)
        // Listeler ([groups]): aynı sütunda ya da aynı satırda duran, aynı boydaki tek satırlık etiketler.
        val lists = groups(targets)
        val listIndex = mutableMapOf<Int, Int>()
        for ((k, list) in lists.withIndex()) for (m in list.first) listIndex[m] = k

        // 6) Kutular (ikiz): kesişen paneller tek paneldir (bildirimin başlığı ve gövdesi, kartın başlığı, açıklaması ve
        // ayrıntıları), kutusu hepsinin birleşimi. Her yazı panelin içinde her yanda [PANEL_PAD_LINES] boşlukla durmalı;
        // durmuyorsa panel yazının kendi şerididir (yanına yazılır). Tek satırlık tek yazılı panel listenin satırıysa (kart
        // başlığının koyu şeridi, seçili satırın açık vurgusu) kutu değil satırdır. İkiz özgünle aynı boyda (yazı, resim,
        // köşe, iç boşluk, kenar çizgisi), en uygun boş yere: yan (ekranın ortasına bakan yan önce) › alt › üst; başka
        // yazıya, başka kutuya ve karenin dışına taşmaz. Yer yoksa örtülür (son çare).
        // Zemini degrade ya da desenli ölçülen yazı (yarı saydam kartın altından harita görünüyor) başka yazının bulduğu
        // panelin içindeyse o paneldedir: kartın başlığı ve açıklaması ayrıntı satırlarıyla tek kart olur (beta.100 3407–3409).
        // Kesişen paneller önce birleşir (yarı saydam kartta her yazının taraması kartın bir parçasında durabilir); yazının
        // örtüsünün en az %80'i birleşik panelin içindeyse yazı o paneldedir.
        val merged = mutableListOf<Box>()
        for (p in panels.keys.toList()) {
            var box = panels[p]!!
            while (true) {
                val k = merged.indexOfFirst { overlaps(it, box) }
                if (k < 0) break
                val o = merged.removeAt(k)
                box = Box(min(o.l, box.l), min(o.t, box.t), max(o.r, box.r), max(o.b, box.b))
            }
            merged.add(box)
        }
        for (i in targets.indices) {
            if (rooms[i] == null || panels.containsKey(i)) continue
            val c = covers[i]
            val area = max(1, (c.r - c.l) * (c.b - c.t)).toDouble()
            merged.firstOrNull { p ->
                (max(0, min(p.r, c.r) - max(p.l, c.l)) * max(0, min(p.b, c.b) - max(p.t, c.t))).toDouble() >= 0.8 * area
            }?.let { panels[i] = it }
        }
        // Tuş isteminin ve tek başına tek satırlık yazının kutusu yazıyı sarmalı: koyu oyun dünyası (gece, gölge, ekranın
        // altındaki karartı) da düz zemin gibi büyüyüp panel sanılabiliyor; tuş çubuğundaki "◯ Back" bu alanın ikizine,
        // ekranın altında dev siyah kutuya yazılıyordu (TCL Android TV, beta.103). Tek yazı her yanda en çok
        // [LABEL_PAD_LINES] satır aşabilir (yanlarda yazının genişliği kadar da: kısa yazılı geniş kart); yalnız tuş
        // istemlerinin kutusu her yanda en çok [PROMPT_PAD_LINES] satır. Başka yazılı kutu (bildirim: ad, gövde, kişi resmi)
        // bu sınırdan muaf. Sarmayan alan kutu değildir, satırlar yanına yazılır (Mac TextPainter, Windows TextPaint.cs aynı).
        fun hugs(members: List<Int>, l: Int, t: Int, r: Int, b: Int): Boolean {
            val prompt = members.all { targets[it].prompt }
            if (!members.all { targets[it].rows <= 1 } || !(prompt || members.size == 1)) return true
            val ul = members.minOf { covers[it].l }
            val ut = members.minOf { covers[it].t }
            val ur = members.maxOf { covers[it].r }
            val ub = members.maxOf { covers[it].b }
            val line = members.maxOf { lines[it] }
            // Aynı satırdaki birden çok tuş istemi (tuş çubuğu "◯ Geri  ✕ Seç") tek kutu değil, ayrı küçük etiketlerdir.
            if (members.size >= 2 && prompt && members.maxOf { covers[it].t } < members.minOf { covers[it].b }) return false
            val padY = (if (prompt) PROMPT_PAD_LINES else LABEL_PAD_LINES) * line
            val padX = if (prompt) padY else max(padY, (ur - ul).toDouble())
            return ut - t <= padY && b - ub <= padY && ul - l <= padX && r - ur <= padX
        }
        val keys = panels.keys.toList()
        val parent = keys.associateWith { it }.toMutableMap()
        fun root(start: Int): Int {
            var i = start
            while (parent[i] != i) i = parent[i]!!
            return i
        }
        for (a in keys) for (b in keys) {
            if (b > a && overlaps(panels[a]!!, panels[b]!!)) parent[root(b)] = root(a)
        }
        class Panel(val members: List<Int>, val box: Box)
        val boxes = mutableListOf<Panel>()
        for (members in keys.groupBy { root(it) }.values.map { it.sorted() }.sortedBy { it[0] }) {
            val l = members.minOf { panels[it]!!.l }
            val t = members.minOf { panels[it]!!.t }
            val r = members.maxOf { panels[it]!!.r }
            val b = members.maxOf { panels[it]!!.b }
            val padded = members.all { m ->
                val c = covers[m]
                val pad = max(2, round(PANEL_PAD_LINES * lines[m]))
                c.l - l >= pad && r - c.r >= pad && c.t - t >= pad && b - c.b >= pad
            }
            val box = members.size >= 2 || targets[members[0]].rows > 1 || listIndex[members[0]] == null
            if (padded && box && hugs(members, l, t, r, b)) boxes.add(Panel(members, Box(l, t, r, b)))
        }
        val boxed = boxes.flatMap { it.members }.toSet()
        val twins = mutableListOf<Box>()
        for (panel in boxes) {
            val members = panel.members
            val l = panel.box.l
            val t = panel.box.t
            val r = panel.box.r
            val b = panel.box.b
            val ground = grounds[members[0]]
            val line = lines[members[0]]
            // Zemin: panelin yazı dışındaki noktalarının ortalaması (yazının çevresindeki şeritten daha doğru ton).
            var sr = 0
            var sg = 0
            var sb = 0
            var count = 0
            val stepX = max(1, (r - l) / 24)
            val stepY = max(1, (b - t) / 24)
            for (yy in t until b step stepY) for (xx in l until r step stepX) {
                if (rectHit(xx, yy, null)) continue
                val c = pixel(xx, yy)
                if (distance(c, ground) > PANEL_TOLERANCE) continue
                sr += c.r
                sg += c.g
                sb += c.b
                count++
            }
            val fill = if (count >= 8) Rgb(sr / count, sg / count, sb / count) else ground
            val corner = cornerRadius(l, t, r, b) { px, py -> distance(pixel(px, py), ground) <= PANEL_TOLERANCE }
            val edge = edges(l, t, r, b, width, height, fill, { px, py -> rectHit(px, py, null) }, pixel)
            val el = edge?.left ?: 0
            val et = edge?.top ?: 0
            val er = edge?.right ?: 0
            val eb = edge?.bottom ?: 0
            val ow = r - l + el + er
            val oh = b - t + et + eb
            val ox = l - el
            val oy = t - et
            val gap = max(2, ceil(ScreenFit.GAP_LINES * line).toInt())
            fun blocked(a: Box): Boolean =
                a.l < 0 || a.t < 0 || a.r > width || a.b > height ||
                    rects.indices.any { j -> j !in members && overlaps(a, rects[j]) } ||
                    boxes.any { overlaps(a, it.box) } || twins.any { overlaps(a, it) }
            val sides = if ((l + r) / 2 < width / 2) listOf(ox + ow + gap to oy, ox - gap - ow to oy)
            else listOf(ox - gap - ow to oy, ox + ow + gap to oy)
            val candidates = sides + listOf(ox to oy + oh + gap, ox to oy - gap - oh)
            val at = candidates.firstOrNull { !blocked(Box(it.first, it.second, it.first + ow, it.second + oh)) } ?: continue
            twins.add(Box(at.first, at.second, at.first + ow, at.second + oh))
            val dx = at.first - ox
            val dy = at.second - oy
            // İkizdeki Türkçe özgün panelden uzunsa ikiz sağa uzar (boş yer varsa, en çok [TWIN_WIDEN]).
            var widen = (TWIN_WIDEN * (r - l)).toInt()
            for (j in rects.indices) {
                if (j in members) continue
                val o = rects[j]
                if (o.t < b + dy && o.b > t + dy && o.l >= r + dx) widen = min(widen, o.l - (r + dx) - er - gap)
            }
            for (other in boxes.map { it.box } + Box(l, t, r, b)) {
                if (other.t < b + dy && other.b > t + dy && other.l >= r + dx) widen = min(widen, other.l - (r + dx) - er - gap)
            }
            widen = max(0, min(widen, width - (r + dx) - er))
            fun sx(v: Int) = (v + dx) / fw
            fun sy(v: Int) = (v + dy) / fh
            var face: Box? = null
            for (m in members) {
                if (face != null) break
                face = portrait(l, t, b, covers[m].l, covers[m].t, covers[m].b, lines[m]) { px, py ->
                    !rectHit(px, py, null) && distance(pixel(px, py), ground) > 2 * PANEL_TOLERANCE
                }
            }
            val inset = max(gap, members.minOf { covers[it].l - l })
            for (m in members) {
                val c = covers[m]
                val left = targets[m].align == "left"
                var paint = result[m].copy(mode = TextPaint.MODE_TWIN, scale = TWIN_SCALE, tail = corner?.tail,
                    background = hex(fill), background2 = null, direction = null, patterned = false,
                    twin = TextBox(sx(l), sy(t), sx(r), sy(b)), radius = (corner?.radius ?: 0.0) / fh,
                    spot = TextBox(sx(c.l), sy(c.t), sx(c.r), sy(c.b)),
                    spotRoom = TextBox(if (left) sx(c.l) else sx(l + inset), sy(c.t), max(sx(c.r), sx(r - inset + widen)), sy(c.b)))
                if (edge != null) {
                    paint = paint.copy(edge = TextPaint.Edge(hex(edge.color), et / fh, er / fh, eb / fh, el / fh))
                }
                if (face != null) {
                    paint = paint.copy(portrait = TextBox(face.l / fw, face.t / fh, face.r / fw, face.b / fh),
                        portraitTwin = TextBox(sx(face.l), sy(face.t), sx(face.r), sy(face.b)))
                }
                result[m] = paint
            }
        }

        // 7) Satırlar (yanına yazma): listede bütün satırlar aynı yana (sağa yaslı sütunda sol, sola yaslı sütunda sağ;
        // satırdaki sekme/kart başlıklarında hizanın açık yanı, sonra alt, sonra üst), sütunda Türkçeler tek hizada (sağa
        // yaslı listede sağ kenarları, sola yaslıda sol kenarları aynı), satırda aynı taban çizgisinde. Bir yan ancak listenin
        // bütün satırlarına yer varsa ve hiçbiri önceden yerleşen Türkçeye ya da ikiz kutuya binmiyorsa seçilir; değilse
        // sıradaki yan denenir (çakışma örtmeye döndürmez). Hiçbir yana birlikte sığmazsa en çok satırın sığdığı yan seçilir;
        // sığmayan satır kendi başına önce listenin yanlarını, sonra alt › üst dener (#1339: GTA 6 duraklatma menüsünde en uzun
        // satır "Photo Studio" sağa sığmayınca bütün liste dağılıyor, satırlar tek tek yerleşiyor, "Photo Studio" örtülüyordu).
        // Listede olmayan tek satır sol › sağ › alt › üst. Mac TextPaint.swift ve Windows TextPaint.cs aynı.
        fun assign(i: Int, spot: Spot) {
            result[i] = result[i].copy(mode = TextPaint.MODE_BESIDE, spot = TextBox(spot.l / fw, spot.t / fh, spot.r / fw, spot.b / fh),
                spotRoom = TextBox(spot.roomL / fw, spot.t / fh, spot.roomR / fw, spot.b / fh))
        }
        // Yerleşen Türkçelerin ve ikiz kutuların yeri (piksel): sonraki yerleşim bunlara binmez.
        val used = twins.toMutableList()
        fun collides(s: Spot) = used.any { overlaps(it, Box(s.l, s.t, s.r, s.b)) }
        val placed = mutableSetOf<Int>()
        val listSides = mutableMapOf<Int, List<Side>>()
        for (list in lists) {
            val members = list.first.filter { rooms[it] != null && it !in boxed }
            if (members.size < 2) continue
            val ms = members.map { rooms[it]!! }
            val aligns = members.map { targets[it].align }
            val majority = listOf("left", "right", "center").maxBy { a -> aligns.count { it == a } }
            val sameRow = ms.maxOf { it.t } < ms.minOf { it.b }
            val sides = if (sameRow) {
                (if (majority == "left") listOf(Side.RIGHT) else if (majority == "right") listOf(Side.LEFT) else emptyList()) +
                    listOf(Side.BELOW, Side.ABOVE)
            } else {
                val tolerance = round(0.5 * ms.maxOf { it.line })
                val rightEdge = ms.maxOf { it.r } - ms.minOf { it.r } <= tolerance
                val leftEdge = ms.maxOf { it.l } - ms.minOf { it.l } <= tolerance
                val right = if (rightEdge && !leftEdge) true else if (leftEdge && !rightEdge) false
                else if (majority == "right") true else if (majority == "left") false else null
                if (right == false) listOf(Side.RIGHT, Side.LEFT) else listOf(Side.LEFT, Side.RIGHT)
            }
            for (m in members) listSides[m] = sides
            var bestSide: Side? = null
            var bestSpots: List<Spot?> = emptyList()
            var bestFit = 0
            for (side in sides) {
                val edge = when (side) {
                    Side.LEFT -> if (sameRow) null else ms.minOf { it.l - it.near }
                    Side.RIGHT -> if (sameRow) null else ms.maxOf { it.r + it.near }
                    Side.BELOW -> ms.maxOf { it.b + it.near }
                    Side.ABOVE -> ms.minOf { it.t - it.near }
                }
                val spots: MutableList<Spot?> = ms.map { spot(it, side, edge) }.toMutableList()
                if ((side == Side.BELOW || side == Side.ABOVE) && spots.all { it != null }) {
                    // Satırdaki komşular arasında Türkçeler ortadaki çizgiyi geçmez.
                    val order = spots.indices.sortedBy { spots[it]!!.l }
                    for ((a, b) in order.zipWithNext()) {
                        val middle = (ms[a].r + ms[b].l) / 2
                        val sa = spots[a]!!
                        val sb = spots[b]!!
                        spots[a] = sa.copy(roomR = max(sa.r, min(sa.roomR, middle)))
                        spots[b] = sb.copy(roomL = min(sb.l, max(sb.roomL, middle)))
                    }
                }
                val free = spots.map { s -> s?.takeIf { !collides(it) } }
                val fit = free.count { it != null }
                if (fit > bestFit) {
                    bestFit = fit
                    bestSide = side
                    bestSpots = free
                }
                if (fit == free.size) break
            }
            val chosen = bestSide ?: continue
            for ((m, s) in members.zip(bestSpots)) {
                if (s == null) continue
                assign(m, s)
                used.add(Box(s.l, s.t, s.r, s.b))
                placed.add(m)
            }
            val preferred = listOf(chosen) + sides.filter { it != chosen }
            for (m in members) listSides[m] = preferred
        }
        for (i in targets.indices) {
            val room = rooms[i] ?: continue
            if (i in boxed || i in placed) continue
            val order = (listSides[i] ?: listOf(Side.LEFT, Side.RIGHT)).toMutableList()
            for (side in listOf(Side.LEFT, Side.RIGHT, Side.BELOW, Side.ABOVE)) if (side !in order) order.add(side)
            for (side in order) {
                val s = spot(room, side, null) ?: continue
                if (collides(s)) continue
                assign(i, s)
                used.add(Box(s.l, s.t, s.r, s.b))
                break
            }
        }
        // Çakışma: yanına yazılan Türkçenin uzayabileceği alan (spotRoom) başka bir Türkçenin alanına ya da ikiz kutuya
        // binerse alan aradaki çizgide kesilir (Türkçeler birbirine yaslanmaz). Türkçenin kendi yeri binerse (yerleşim
        // çakışmayı önlediği için seyrek) listede olmayan yazı örtmeye döner; menü/liste satırı hiç örtülmez (#1339).
        fun overlapsBox(a: TextBox, b: TextBox) = min(a.right, b.right) > max(a.left, b.left) && min(a.bottom, b.bottom) > max(a.top, b.top)
        val eps = 1e-9
        for (i in result.indices) {
            if (result[i].mode != TextPaint.MODE_BESIDE) continue
            var mine = result[i].spotRoom ?: continue
            val spot = result[i].spot ?: continue
            var hit = false
            for (j in result.indices) {
                if (j == i) continue
                val twin = result[j].mode == TextPaint.MODE_TWIN
                val other = (if (twin) result[j].twin else if (result[j].mode == TextPaint.MODE_BESIDE) result[j].spot else null) ?: continue
                if (!overlapsBox(mine, other)) continue
                if (overlapsBox(spot, other)) {
                    if (twin || j < i) hit = true
                    continue
                }
                // Öbür Türkçe sağdaysa alan onun solunda, soldaysa sağında biter (ikizde kutunun kenarı; yanına yazmada iki
                // Türkçenin ortası).
                if (other.left >= spot.right - eps) {
                    val end = if (twin) other.left else (spot.right + other.left) / 2
                    mine = mine.copy(right = max(spot.right, min(mine.right, end)))
                } else if (other.right <= spot.left + eps) {
                    val end = if (twin) other.right else (other.right + spot.left) / 2
                    mine = mine.copy(left = min(spot.left, max(mine.left, end)))
                }
            }
            result[i] = result[i].copy(spotRoom = mine)
            if (hit && i !in listIndex) result[i] = result[i].copy(mode = TextPaint.MODE_COVER, spot = null, spotRoom = null)
        }
        // 4) Grup: aynı sütunda (ortak sol ya da sağ kenar, düzenli aralık) ya da aynı satırda duran, BÜYÜK HARF'i ve
        // satır yüksekliği aynı tek satırlık etiketler.
        for ((members, id) in lists) for (i in members) result[i] = result[i].copy(group = id)
        return result
    }

    /** Kare üzerinden ölçüm: [color] verilirse gerçek renk (0xRRGGBB), yoksa gri ton. */
    fun paints(targets: List<Target>, frame: GrayFrame, color: ((Int, Int) -> Int)? = null): List<TextPaint> {
        if (!frame.isValid) return emptyList()
        return paints(targets, frame.width, frame.height, color ?: { x, y -> frame.at(x, y).let { (it shl 16) or (it shl 8) or it } })
    }

    /** Satır aralığı: çok satırlı yazıda kutudan ((satır sayısı - 1) aralık + bir satır yüksekliği), tek satırda satır yüksekliği. */
    internal fun pitch(target: Target): Double {
        val height = target.box.bottom - target.box.top
        if (target.rows <= 1 || target.lineHeight <= 0) return if (target.lineHeight > 0) target.lineHeight else height
        return max(target.lineHeight, (height - target.lineHeight) / (target.rows - 1))
    }

    /** Grup üyeleri ve numarası (grubun en küçük sıra numarası); tek üyeli grup yok. */
    internal fun groups(targets: List<Target>): List<Pair<List<Int>, Int>> {
        val labels = targets.indices.filter { targets[it].rows <= 1 }
        val parent = labels.associateWith { it }.toMutableMap()
        fun root(start: Int): Int {
            var i = start
            while (parent[i] != i) i = parent[i]!!
            return i
        }
        fun overlap(a: TextBox, b: TextBox): Double =
            max(0.0, min(a.bottom, b.bottom) - max(a.top, b.top)) / max(1e-9, min(a.bottom - a.top, b.bottom - b.top))
        for (a in labels) for (b in labels) {
            if (b <= a) continue
            val x = targets[a]
            val y = targets[b]
            val line = max(x.lineHeight, y.lineHeight)
            if (x.upper != y.upper || abs(x.lineHeight - y.lineHeight) > SAME_LINE * line) continue
            // Satır yüksekliği kareye oranla; yatay pay aynı piksele denk gelsin diye en-boy oranı bilinmez, yarım satır
            // yüksekliğinin yarısı kadar (16:9'da ~0,28 satır) alınır.
            val tolerance = 0.5 * line * 9 / 16
            val sameRow = overlap(x.box, y.box) >= 0.5
            val column = (abs(x.box.left - y.box.left) <= tolerance || abs(x.box.right - y.box.right) <= tolerance) &&
                overlap(x.box, y.box) == 0.0 && abs(x.box.top - y.box.top) <= 3 * line
            if (sameRow || column) parent[root(a)] = root(b)
        }
        return labels.groupBy { root(it) }.values.filter { it.size >= 2 }.map { it.sorted() to it.min() }.sortedBy { it.second }
    }

    fun rgb(hex: String): Rgb {
        if (hex.length != 7 || hex[0] != '#') return Rgb(0, 0, 0)
        val value = hex.substring(1).toIntOrNull(16) ?: return Rgb(0, 0, 0)
        return rgbOf(value)
    }

    fun hex(c: Rgb): String = String.format(java.util.Locale.ROOT, "#%02X%02X%02X", c.r.coerceIn(0, 255), c.g.coerceIn(0, 255), c.b.coerceIn(0, 255))

    fun distance(a: Rgb, b: Rgb): Int = maxOf(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))

    internal fun mean(list: List<Rgb>): Rgb {
        val n = max(1, list.size)
        return Rgb(list.sumOf { it.r } / n, list.sumOf { it.g } / n, list.sumOf { it.b } / n)
    }

    /** [a]'dan [b]'nin tersine [share] kadar (eksiyse [b]'ye doğru) uzatılmış renk. */
    internal fun extend(a: Rgb, b: Rgb, share: Double): Rgb {
        fun one(x: Int, y: Int) = round(x + (x - y) * share)
        return Rgb(one(a.r, b.r), one(a.g, b.g), one(a.b, b.b))
    }

    internal fun deviation(list: List<Rgb>): Double {
        if (list.isEmpty()) return 0.0
        fun spread(values: List<Int>): Double {
            val average = values.sum().toDouble() / values.size
            return sqrt(values.sumOf { (it - average) * (it - average) } / values.size)
        }
        return (spread(list.map { it.r }) + spread(list.map { it.g }) + spread(list.map { it.b })) / 3
    }
}
