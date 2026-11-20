// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import kotlin.random.Random

/**
 * Gerçek oyun kareleriyle yerel doğrulama (depoya kare girmez): COUCHSUBS_REAL_FRAMES=<dizin> verilince koşar, yoksa
 * atlanır. Dizinde `kareler/K*.png` ve platform dışı OCR'ın satırları `ocr/K*.json` bulunur (ML Kit JVM'de çalışmaz;
 * sahte okuyucu istenen kırpıntıyla kesişen satırları kırpıntı koordinatına çevirir). Hat Android'dekiyle aynıdır:
 * bulucu → okuyucu → arayüz sözlüğü / oturum terimleri → sahte çevirmen ("⟨TR⟩") → stil → TV olayları. Olaylar
 * `<çıktı>/<K>.events.json`'a yazılır; `node render.js <repo> <kare> <olaylar> <png>` ile TV çizimiyle bakılır.
 */
class RealFramesTest {
    private class Image(val width: Int, val height: Int, val rgb: IntArray) {
        val luma = ByteArray(rgb.size) { i ->
            val c = rgb[i]
            ((299 * ((c shr 16) and 0xff) + 587 * ((c shr 8) and 0xff) + 114 * (c and 0xff)) / 1000).toByte()
        }

        fun crop(region: CropRegion): Triple<GrayFrame, (Int, Int) -> Int, ByteArray> {
            val left = (region.left * width).toInt().coerceIn(0, width - 1)
            val top = (region.top * height).toInt().coerceIn(0, height - 1)
            val w = ((region.right - region.left) * width).toInt().coerceIn(1, width - left)
            val h = ((region.bottom - region.top) * height).toInt().coerceIn(1, height - top)
            val gray = ByteArray(w * h) { i -> luma[(top + i / w) * width + left + i % w] }
            return Triple(GrayFrame(gray, w, h), { x, y -> rgb[(top + y) * width + left + x] and 0xffffff }, gray)
        }

        /** Küçük gürültülü kopya (ardışık kareler: yayın sıkıştırması gibi ±2). */
        fun noisy(seed: Int): Image {
            val random = Random(seed)
            return Image(width, height, IntArray(rgb.size) { i ->
                val d = random.nextInt(5) - 2
                val c = rgb[i]
                fun ch(v: Int) = (v + d).coerceIn(0, 255)
                (ch((c shr 16) and 0xff) shl 16) or (ch((c shr 8) and 0xff) shl 8) or ch(c and 0xff)
            })
        }
    }

    private class Line(val text: String, val box: TextBox, val confidence: Float)

    /** Sahte okuyucu: alanla kesişen OCR satırları, alanın koordinatına çevrilmiş ve kırpılmış. */
    private fun read(lines: List<Line>, region: CropRegion): Reading {
        val w = region.right - region.left
        val h = region.bottom - region.top
        return Reading(lines.filter { l ->
            val cx = (l.box.left + l.box.right) / 2
            val cy = (l.box.top + l.box.bottom) / 2
            cx in region.left..region.right && cy in region.top..region.bottom
        }.map { l ->
            TextLine(l.text, TextBox(((l.box.left - region.left) / w).coerceIn(0.0, 1.0), ((l.box.top - region.top) / h).coerceIn(0.0, 1.0),
                ((l.box.right - region.left) / w).coerceIn(0.0, 1.0), ((l.box.bottom - region.top) / h).coerceIn(0.0, 1.0)),
                confidence = l.confidence)
        })
    }

    private class Fake : TextTranslator {
        var requests = 0
        // Sözcükler ters sırada: "aslıyla aynı" denetimi uzun cümlede sahte çeviriyi çevrilmemiş saymasın.
        private fun fake(text: String) = "⟨TR⟩ " + text.split(' ').reversed().joinToString(" ")
        override fun translate(text: String): String { requests++; return fake(text) }
        override fun translateAll(texts: List<String>): List<String> { requests++; return texts.map(::fake) }
    }

    private class Events : RegionSender {
        val list = JSONArray()
        val log = mutableListOf<Pair<String, String>>()
        override fun sendRegion(id: String, text: String, box: TextBox?, lineHeight: Double?) =
            sendRegion(id, text, box, lineHeight, null, null)
        override fun sendRegion(
            id: String, text: String, box: TextBox?, lineHeight: Double?, icons: List<IconPlacement>?,
            blocks: List<ScreenTranslation.Item>?,
        ) {
            val frame = SubtitleServer.regionFrame(id, text, box, lineHeight, icons, blocks)
            list.put(JSONObject().put("event", "region").put("data", JSONObject(frame.substringAfter("data: ").trim())))
            log.add(id to text)
        }
        override fun clearRegions() {
            list.put(JSONObject().put("event", "region-clear").put("data", JSONObject()))
        }
    }

    /** Bir kare dizisi: her 100 ms'de bulucu örneği, her 500 ms'de ek alan turu (TranslationService'teki gibi). */
    private class Run(val excluded: List<CropRegion>) {
        val detector = ScreenTextDetector()
        val engine = Fake()
        val events = Events()
        val watcher = RegionWatcher({ Reading.Empty }, engine, events)
        var now = 0L
    }

    private fun step(run: Run, image: Image, lines: List<Line>, watcher: RegionWatcher) {
        val sample = run.detector.sample(image.width, image.height) { x, y -> image.luma[y * image.width + x].toInt() and 0xff }
        val areas = run.detector.update(sample, emptyList(), run.now, subtitle = run.excluded.firstOrNull())
        if (run.now % 500 == 0L) {
            val crops = areas.map { area ->
                val (gray, color, bytes) = image.crop(area.region)
                area to RegionWatcher.Crop(area.region, RegionSignature.of(bytes, gray.width, gray.height), gray, color)
            }
            watcher.pass(areas.map { it.id }.toSet(), crops)
        }
        run.now += 100
    }

    @Test
    fun realFrames() {
        val root = System.getenv("COUCHSUBS_REAL_FRAMES")
        assumeTrue("COUCHSUBS_REAL_FRAMES verilmedi", root != null)
        val dir = File(root!!)
        val out = File(System.getenv("COUCHSUBS_REAL_OUT") ?: File(dir, "android").path).apply { mkdirs() }
        val report = StringBuilder()
        for (name in listOf("K1", "K2", "K3", "K4", "K5")) {
            val png = File(dir, "kareler/$name.png")
            val ocr = File(dir, "ocr/$name.json")
            if (!png.exists() || !ocr.exists()) continue
            val image = trimmed(load(png))
            val json = JSONObject(ocr.readText()).getJSONArray("lines")
            val lines = (0 until json.length()).map { json.getJSONObject(it) }.map { item ->
                val b = item.getJSONObject("box")
                Line(item.getString("text"), TextBox(b.getDouble("left"), b.getDouble("top"), b.getDouble("right"), b.getDouble("bottom")),
                    item.optDouble("confidence", 1.0).toFloat())
            }
            if (System.getenv("COUCHSUBS_REAL_GRID") != null) {
                val sample = ScreenTextDetector().sample(image.width, image.height) { x, y -> image.luma[y * image.width + x].toInt() and 0xff }
                report.append("ızgara $name (b/d):\n")
                for (row in 0 until ScreenTextDetector.ROWS) {
                    report.append((0 until ScreenTextDetector.COLUMNS).joinToString(" ") { c ->
                        val i = row * ScreenTextDetector.COLUMNS + c
                        val text = sample.bright[i] in ScreenTextDetector.MIN_BRIGHT..ScreenTextDetector.MAX_BRIGHT && sample.dark[i] >= ScreenTextDetector.MIN_DARK
                        (if (text) "#" else ".") + "%02d/%03d".format(sample.bright[i] % 100, sample.dark[i])
                    }).append('\n')
                }
            }
            // Varsayılan ayar: altyazı alanı alt orta (oradaki yazı bulucuya girmez).
            val run = Run(listOf(CropRegion()))
            val watcher = RegionWatcher({ crop -> read(lines, crop.pixels as CropRegion) }, run.engine, run.events)
            watcher.onAutoRejected = { run.detector.rejected(it) }
            var last = ""
            if (System.getenv("COUCHSUBS_REAL_GRID") != null) run.detector.debug = { last = it; if (name == System.getenv("COUCHSUBS_REAL_GRID")) report.append("t=${run.now} $it ${run.detector.areas.map { a -> a.id }}\n") }
            // 3 sn aynı kare (her örnek ±2 gürültülü).
            repeat(30) { step(run, image.noisy(it), lines, watcher) }
            if (last.isNotEmpty()) report.append("$last\n")
            val firstRequests = run.engine.requests
            val firstEvents = run.events.log.size
            File(out, "$name.events.json").writeText(run.events.list.toString(1))
            report.append("== $name (${image.width}x${image.height})\n")
            report.append("alanlar: ${run.detector.areas.map { "${it.id}${if (it.menu) "/menü" else ""} ${fmt(it.region)}" }}\n")
            run.events.log.forEach { (id, text) -> report.append("  $id ← ${text.replace("\n", " ⏎ ")}\n") }
            report.append("istek: $firstRequests\n")
            // Ardışık kareler: 10 kare daha; K3'te seçili satır bir alta kayar.
            val next = if (name == "K3") movedSelection(image, lines) else image
            repeat(10) { step(run, next.noisy(100 + it), lines, watcher) }
            val later = run.events.log.drop(firstEvents)
            report.append("ardışık: ${later.size} olay, istek ${run.engine.requests - firstRequests}, boşaltma ${later.count { it.second.isEmpty() }}\n")
            later.forEach { (id, text) -> report.append("  + $id ← ${text.replace("\n", " ⏎ ")}\n") }
            if (name == "K3") File(out, "K3b.events.json").writeText(run.events.list.toString(1))
        }
        File(out, "rapor.txt").writeText(report.toString())
        println(report)
    }

    /** PNG'yi masaüstü JDK'nın ImageIO'suyla okur (Android sınıf yolunda yok; test JVM'inde var). */
    private fun load(file: File): Image {
        val buffered = Class.forName("javax.imageio.ImageIO").getMethod("read", File::class.java).invoke(null, file)
        val type = buffered.javaClass
        val width = type.getMethod("getWidth").invoke(buffered) as Int
        val height = type.getMethod("getHeight").invoke(buffered) as Int
        val rgb = type.getMethod("getRGB", Int::class.java, Int::class.java, Int::class.java, Int::class.java, IntArray::class.java,
            Int::class.java, Int::class.java).invoke(buffered, 0, 0, width, height, null, 0, width) as IntArray
        return Image(width, height, rgb)
    }

    /**
     * Ekran görüntüsü kenarındaki beyaz şeritler (yapıştırılan görüntünün çerçevesi; oyunda yok) atılır. OCR kutuları
     * ilk görüntüye göre olduğundan kırpılan kenarlar [trim]'de saklanır.
     */
    private var trim = IntArray(4)

    private fun trimmed(image: Image): Image {
        fun white(x: Int, y: Int) = image.rgb[y * image.width + x].let { c ->
            ((c shr 16) and 0xff) > 235 && ((c shr 8) and 0xff) > 235 && (c and 0xff) > 235 }
        fun rowWhite(y: Int) = (0 until image.width).count { white(it, y) } > 0.9 * image.width
        fun columnWhite(x: Int) = (0 until image.height).count { white(x, it) } > 0.9 * image.height
        var top = 0; while (top < image.height / 4 && rowWhite(top)) top++
        var bottom = image.height; while (bottom > image.height * 3 / 4 && rowWhite(bottom - 1)) bottom--
        var left = 0; while (left < image.width / 4 && columnWhite(left)) left++
        var right = image.width; while (right > image.width * 3 / 4 && columnWhite(right - 1)) right--
        trim = intArrayOf(left, top, image.width - right, image.height - bottom)
        if (top == 0 && left == 0 && bottom == image.height && right == image.width) return image
        val w = right - left
        val h = bottom - top
        // Yerine aynı boyda: kenarlar koyu yapılır (OCR koordinatları değişmesin).
        return Image(image.width, image.height, IntArray(image.rgb.size) { i ->
            val x = i % image.width
            val y = i / image.width
            if (x in left until left + w && y in top until top + h) image.rgb[i] else 0x101010
        })
    }

    private fun fmt(r: CropRegion) = "%.2f,%.2f-%.2f,%.2f".format(r.left, r.top, r.right, r.bottom)

    /** K3: seçili satır ("Map") ile alttaki ("Game") şeritlerinin renkleri ters çevrilir (seçim bir alta kaydı). */
    private fun movedSelection(image: Image, lines: List<Line>): Image {
        val rgb = image.rgb.copyOf()
        val map = lines[0].box
        val game = lines[1].box
        val rowHeight = (game.top - map.top)
        for (box in listOf(map, game)) {
            val top = ((box.top + box.bottom) / 2 - rowHeight / 2) * image.height
            val bottom = top + rowHeight * image.height
            for (y in top.toInt().coerceAtLeast(0) until bottom.toInt().coerceAtMost(image.height))
                for (x in (0.04 * image.width).toInt() until (0.47 * image.width).toInt()) {
                    val i = y * image.width + x
                    rgb[i] = rgb[i].inv() and 0xffffff
                }
        }
        return Image(image.width, image.height, rgb)
    }
}
