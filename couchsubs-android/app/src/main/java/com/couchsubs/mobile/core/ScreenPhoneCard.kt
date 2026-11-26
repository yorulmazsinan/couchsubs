// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import kotlin.math.abs

/**
 * GTA 6 telefonunun sohbet paneli ("Ekranı çevir" ve otomatik telefon okuması; Yanda Panel ayarı, varsayılan). Panel
 * koyu, yarı saydam kartta; karşı taraf solda krem, oyuncu sağda amber; parçalar [PanelPart] ile işaretlenir.
 *
 * "Ekranı çevir"de GTA 6 telefonu: eğik telefon ekranının üstüne yazmak okunmuyordu (yazı küçük, ekran yamuk). Telefon
 * karede bulunursa ([GamePhoneGeometry]) ekranındaki satırlar düz ekrana taşınıp ayrı gruplanır ([PhoneChat]) ve
 * çevirileri telefonun hemen yanına, ekranda yer olan tarafa, telefon boyunda açık renkli bir "mesaj kartı" olarak
 * dizilir: en üstte kişi adı, altında her mesaj kendi balonunda (giden sağda mavi, gelen solda beyaz), sohbet listesinde
 * ad + önizleme satırları. Balonların yüksekliği Türkçenin kaç satır tutacağına göre hesaplanır, üst üste binmez; kart
 * dolarsa en eski mesajlar düşer. Yanda yer yoksa kart telefonun üstüne konur. Telefon dışındaki yazılar kendi
 * yerlerinde kalır. Kart TV'ye ve telefona sıradan stilli öğeler olarak gider (zemin, başlık, balonlar), ayrı bir çizim
 * gerekmez (Mac/iPhone: ScreenPhoneCard.swift, Windows: ScreenPhoneCard.cs; ortak deneme dosyası fixtures/phone-chat.json).
 */
/** "GTA 6 Telefon Mesajları" ayarı ve panelin yazı çarpanı (Mac: PhonePanelOptions). */
data class PhonePanelOptions(val enabled: Boolean = true, val textScale: Double = 1.0)

object ScreenPhoneCard {
    /** Panelin parçası; JSON'da `panel` alanının değeri ([wire]). Mac/Windows ile aynı. */
    enum class PanelPart(val wire: String) {
        /** Panelin zemini (kutusu panelin yeri ve boyu). */
        CARD("card"),
        /** Konuşulan kişinin adı (telefonun başlığı; çevrilmez). */
        TITLE("title"),
        /** Karşı tarafın mesajı (solda, açık zemin) ve oyuncunun mesajı (sağda, amber zemin). */
        THEIRS("theirs"), MINE("mine"),
        /** Ortalı kısa satır ("Bugün", saat) ve sohbet listesinin bölüm başlığı. */
        NOTE("note"),
        /**
         * Sohbet listesinin bir satırı ya da ana ekran bileşeni tek kartta ([ListRow]: avatar, kalın ad, altında önizleme,
         * rozet, seçili satır çerçevesi). TV uygulaması 0.9.110; eski TV öğeyi yerinde, ad ve önizleme iki satır çizer.
         */
        ROW("row"),
    }

    /**
     * Liste kartının içeriği ([PanelPart.ROW]; JSON `row`). Sinan Bey (beta.100, 3399): ad ve önizleme ayrı haplar
     * dağınıktı; telefondaki satırın Türkçe kopyası tek kartta. Avatar ve rozet oyundan kesilir ([PhoneListLook]; küçük PNG,
     * aynı satırda bir kez kesilip saklanır), seçili satırın çerçevesi kareden okunur. Eşitlik karedeki arama yerlerini
     * ([portraitSpot], [badgeSpot], [frameSpot]) saymaz: el titremesiyle oynarlar (#1279). iPhone ile aynı.
     */
    data class ListRow(
        /** Kalın ad (kişi adı çevrilmez; bileşen başlığı çevrilir). Boşsa yalnız önizleme. */
        val name: String,
        /** Adın altındaki önizleme (çeviri; kesikse "..." ile biter). Boş olabilir (yalnız emoji önizleme). */
        val preview: String,
        /** Oyundan kesilmiş avatar ya da bileşen simgesi (PNG data: adresi); yoksa null. */
        val avatar: String? = null,
        /** Sağdaki rozet (gönder/konum simgesi; PNG data: adresi); yoksa null. */
        val badge: String? = null,
        /** Seçili satırın çerçeve rengi (telefonda mavi); seçili değilse null. */
        val selected: String? = null,
        /** Ana ekran bileşeni ("Hatırlatıcılar / 6 Bildirim"). */
        val widget: Boolean = false,
        /** Karede avatarın, rozetin ve seçim çerçevesinin aranacağı yerler (kesmek için; gönderilmez, eşitliğe girmez). */
        val portraitSpot: TextBox? = null,
        val badgeSpot: TextBox? = null,
        val frameSpot: TextBox? = null,
    ) {
        /** Görünüşü aynı mı (karedeki arama yerleri el titremesiyle oynar, karşılaştırmaya girmez; #1279). */
        override fun equals(other: Any?): Boolean = other is ListRow && name == other.name && preview == other.preview &&
            avatar == other.avatar && badge == other.badge && selected == other.selected && widget == other.widget

        override fun hashCode(): Int = listOf(name, preview, avatar, badge, selected, widget).hashCode()
    }

    /** Kartın zemini: yazısı yalnız bölünmez boşluk olan öğe, kartın tamamını kaplar; balonlar üstüne çizilir. */
    const val BACKDROP_TEXT = "\u00A0"
    /** Panelin renkleri (CouchSubs tasarım dili): koyu zemin (çiziciler %88 örtüyle çizer), karşı taraf krem, oyuncu amber. */
    val CARD = TextSurface("#141518", "#F3EEE4")
    val INCOMING = TextSurface("#F3EEE4", "#17181B")
    val OUTGOING = TextSurface("#F5B83D", "#17181B")
    val NOTE = TextSurface("#141518", "#A9A59C")
    /** Panelin köşe yarıçapı (1080 satırlık ekranda piksel) ve zemin örtüsü. */
    const val PANEL_RADIUS = 18.0
    const val PANEL_OPACITY = 0.88
    /** Kanepe simgesi: 24×16 ızgarada yuvarlak köşeli dikdörtgenler (x, y, en, boy, köşe); Mac ile aynı şekil. */
    val COUCH_GLYPH: List<DoubleArray> = listOf(
        doubleArrayOf(3.0, 1.0, 18.0, 8.0, 2.5), doubleArrayOf(0.0, 5.0, 5.0, 8.0, 2.0), doubleArrayOf(19.0, 5.0, 5.0, 8.0, 2.0),
        doubleArrayOf(4.0, 8.0, 16.0, 5.0, 1.5), doubleArrayOf(2.0, 13.0, 2.0, 3.0, 0.8), doubleArrayOf(20.0, 13.0, 2.0, 3.0, 0.8),
    )
    /** Altyazı boyutu ayarının panel yazısına çarpanı sınırları; varsayılan altyazı boyu (TV pikseli, 1080p). */
    const val DEFAULT_FONT_SIZE = 46
    const val MIN_SCALE = 0.75
    const val MAX_SCALE = 1.6
    /** Yanda yer yoksa kart telefonun altına; orada da en az bu kadar yükseklik yoksa telefonun üstüne konur. */
    const val MIN_BELOW = 0.18
    /** Telefonla kart arasındaki boşluk ve kartın ekran kenarından payı (ekran genişliğine oranla). */
    const val GAP = 0.008
    /** Kart için yanda en az bu kadar yer olmalı; yoksa kart telefonun üstüne konur. */
    const val MIN_WIDTH = 0.12
    /**
     * Kartın istenen eni: telefonun bu katı, en az [CARD_MIN] (yanda yer varsa). Telefon boyundaki dar kartta Türkçe
     * mesajlar çok satıra bölünüyor, balonlar iç içe görünüyordu.
     */
    const val CARD_SCALE = 1.4
    const val CARD_MIN = 0.22
    /** Mesajlar telefon boyuna sığmazsa kart ekranın bu payına kadar yukarı ve aşağı uzar; yine sığmazsa eski mesajlar düşer. */
    const val SCREEN_MARGIN = 0.03
    /**
     * Balonlar arası boşluk, balonun iç dolgusu (üst + alt toplamı) ve satır aralığı; satır yüksekliğine oranla. TV yazıyı
     * kutunun üstüne yaslar: dolgu, son satırın altında da boşluk bırakır. Önceden balonlar arası 0,35 satırdı, mesajlar
     * birbirine yapışık görünüyordu.
     */
    const val BUBBLE_SPACING = 0.6
    const val BUBBLE_PADDING = 0.6
    const val LINE_SPACING = 1.2
    /** Sohbet listesinde kişi adıyla altındaki önizleme arasındaki boşluk (satır yüksekliğine oranla). Mac ile aynı. */
    const val LIST_GAP = 0.1
    /** Balonun kart genişliğine oranı (en çok) ve en az. */
    const val BUBBLE_SHARE = 0.8
    const val BUBBLE_MIN = 0.3
    /** Kartta yazı boyu (kare yüksekliğine oranla) en az bu: telefonun küçük yazısı TV'de okunsun (1080p'de ~24 nokta). */
    const val MIN_LINE = 0.022
    /**
     * Kartta yazı boyu en çok bu (altyazı boyutu çarpanıyla): telefon yazısıyla orantılı kalır. Sinan Bey (beta.100,
     * 3416): gönderinin Türkçesi dev, her satıra bir sözcük düşen patlak balondu; ölçüm fotoğrafın içindeki büyük yazıyı
     * (tabela) da alıyordu. 3417'deki küçük balon doğru boydur (1080p'de ~32 nokta satır).
     */
    const val MAX_LINE = 0.03
    /** Bir harfin ortalama genişliği, satır yüksekliğine oranla (TV'nin yazı tipinde Türkçe metinle ölçüldü, ~0,5). */
    const val CHAR_WIDTH = 0.5

    /** Telefondaki yazının kartta ne olduğu; [wire] Mac ve Windows'taki adı (ortak deneme dosyası). */
    enum class Role(val wire: String) {
        /** Sohbetin başlığı (kişi adı); çevrilmez. */
        HEADER("header"),
        /** Gelen mesaj (sola yaslı balon), giden mesaj (sağa yaslı), tarafı belirsiz mesaj (rengine bakılır). */
        INCOMING("incoming"), OUTGOING("outgoing"), MESSAGE("message"),
        /**
         * Sohbetin altındaki cevap seçeneği (oyuncunun seçeceği yanıt; [PhoneChat.withOptions]): her biri ayrı balon,
         * oyuncunun tarafında, seçeneklerin hepsi aynı renkte (iPhone ve Windows ile aynı).
         */
        OPTION("option"),
        /** Ortalı kısa satır: saat, "Today", "Delivered". */
        NOTE("note"),
        /** Sohbet listesi: kişi adı (çevrilmez), son mesaj önizlemesi, bölüm başlığı ("Messages"). */
        CONTACT("contact"), PREVIEW("preview"), HEADING("heading"),
        /** Ana ekranın yazısı (bildirim): sohbet değildir, karta girmez; kendi yerinde, özgün stilinde çizilir. */
        HOME("home"),
        /** Ana ekran bileşeni (başlık + sayaç: "Reminders / 6 Notifications"): panelde tek kart ([ListRow.widget]). */
        WIDGET("widget"),
        /**
         * Sohbet dışı ekranın satırı ya da bloğu ([PhoneScreen]: uygulama satırı, makale başlığı/gövdesi, gönderinin
         * açıklaması): panelde tek kart, mesaj listesi kartının görünüşünde (avatarsız).
         */
        CARD("card");

        /** Çevirmene gitmez, aslıyla gösterilir (ad). */
        val keepsText: Boolean get() = this == HEADER || this == CONTACT
        /**
         * Telefonun yanındaki panelde dizilir. Sinan Bey (beta.100, 3422): ana ekran ve hava yazıları da artık telefonun
         * üstüne çizilmez, panelde kart olur.
         */
        val inCard: Boolean get() = true
    }

    /**
     * Telefondaki bir grubun rolü ve düz ekrandaki yeri (0–1). Kartta ([Role.CARD]): [titled] ilk paragraf kalın başlık,
     * [bold] kartın tamamı başlık (makale başlığı).
     */
    data class Placement(val role: Role, val spot: TextBox, val titled: Boolean = false, val bold: Boolean = false)

    /**
     * Karedeki telefon: sınır kutusu ve ekranın ekseni (hoparlörden alt çentiğe). Eğik telefonun ekranındaki her nokta
     * düz ekrana (u: soldan sağa, v: yukarıdan aşağı, 0–1) taşınabilir; [GamePhoneReader]'ın düzeltmesinin tersidir.
     * [aspect]: karenin genişliği / yüksekliği.
     */
    data class Handset(val pose: GamePhoneGeometry.Pose, val aspect: Double) {
        val bounds: TextBox = pose.bounds.let { TextBox(it.left, it.top, it.right, it.bottom) }

        /** Ekranın yüksekliği, kare yüksekliğine oranla. */
        val screenHeight: Double get() = (pose.bottomY - pose.topY) * 0.915

        /** Düz ekrandaki noktanın karedeki yeri (kenarlara oranla). */
        fun point(u: Double, v: Double): Pair<Double, Double> {
            val dx = pose.bottomX - pose.topX
            val dy = pose.bottomY - pose.topY
            val t = 0.04 + 0.915 * v
            val side = (u - 0.5) * 0.52
            return Pair(pose.topX + dx * t + side * dy / aspect, pose.topY + dy * t - side * dx * aspect * (0.52 + v * 0.30))
        }

        /** Düz ekrandaki kutunun karedeki sınır kutusu (dört köşesinden; eğik telefonda biraz geniştir). */
        fun frameBox(box: TextBox): TextBox {
            val corners = listOf(point(box.left, box.top), point(box.right, box.top), point(box.left, box.bottom), point(box.right, box.bottom))
            return TextBox(corners.minOf { it.first }, corners.minOf { it.second }, corners.maxOf { it.first }, corners.maxOf { it.second })
        }

        /** Karedeki noktanın düz ekrandaki yeri (Newton adımlarıyla; dönüşüm neredeyse doğrusal, dört adım yeter). */
        fun screen(x: Double, y: Double): Pair<Double, Double> {
            val dx = pose.bottomX - pose.topX
            val dy = pose.bottomY - pose.topY
            var u = 0.5
            var v = ((y - pose.topY) / dy - 0.04) / 0.915
            repeat(4) {
                val (px, py) = point(u, v)
                val ex = px - x
                val ey = py - y
                val a = 0.52 * dy / aspect
                val b = 0.915 * dx
                val c = -0.52 * dx * aspect * (0.52 + 0.30 * v)
                val d = 0.915 * dy - (u - 0.5) * 0.52 * dx * aspect * 0.30
                val det = a * d - b * c
                if (abs(det) <= 1e-12) return Pair(u, v)
                u -= (d * ex - b * ey) / det
                v -= (a * ey - c * ex) / det
            }
            return Pair(u, v)
        }

        /**
         * Karedeki satır kutusunun düz ekrandaki yeri. Eğik ekranda okunan kutu satırın eğimini de kapsar: satırın
         * gerçek yüksekliği kutunun yüksekliğinden eğimin payı düşülerek bulunur.
         */
        fun flat(box: TextBox): TextBox {
            val cx = (box.left + box.right) / 2
            val cy = (box.top + box.bottom) / 2
            val (_, cv) = screen(cx, cy)
            val dx = pose.bottomX - pose.topX
            val dy = pose.bottomY - pose.topY
            val slope = (-0.52 * dx * aspect * (0.52 + 0.30 * cv)) / (0.52 * dy / aspect)
            val left = screen(box.left, cy + slope * (box.left - cx)).first
            val right = screen(box.right, cy + slope * (box.right - cx)).first
            val height = box.bottom - box.top
            val upright = maxOf(height - abs(slope) * (box.right - box.left), height * 0.35)
            val half = upright / screenHeight / 2
            return TextBox(left, cv - half, right, cv + half)
        }

        companion object {
            /** Düz ekranın eni / boyu (telefon okuyucusunun ekran oranı: 0,52 / 0,915). */
            const val SCREEN_SHAPE = 0.52 / 0.915
        }
    }

    /**
     * Satır (karedeki kutusu) telefonun ekranında mı: düz ekrandaki ortası ekranın içinde ve iki yanı ekranın kenarlarını
     * [SIDE_SLACK]'ten çok aşmıyor. Altyazı hattı bu satırları okumaz ([SubtitlePipeline.process] `phone`). Telefonun
     * önünden geçen geniş altyazı satırı telefonun ekranından taşar, telefon yazısı sayılmaz (Mac/iPhone, Windows ile aynı).
     */
    fun holds(box: TextBox, handset: Handset): Boolean {
        val flat = handset.flat(box)
        val v = (flat.top + flat.bottom) / 2
        return v >= -SCREEN_SLACK && v <= 1 + BELOW_SLACK && flat.left >= -SIDE_SLACK && flat.right <= 1 + SIDE_SLACK
    }

    /**
     * Doğrulanmamış telefon adayı (#1251, CANDIDATE_HOLD_MS) yalnız ekranının içindeki satırları bekletir: alt gövde payı
     * (BELOW_SLACK) yok ve konuşan adlı satır ("Lucia: …") hiç bekletilmez. Yanlış aday (yanları zayıf, telefon olmayan
     * dikdörtgen) altındaki ya da önündeki altyazıyı 1,5 sn yutuyordu (beta.103 kaçan altyazı denetimi).
     * Mac/iPhone (ScreenPhoneCard.holdsUnconfirmed) ve Windows (HoldsUnconfirmed) aynı.
     */
    fun holdsUnconfirmed(text: String, box: TextBox, handset: Handset): Boolean {
        if (SpeakerPrefix.split(text) != null) return false
        val flat = handset.flat(box)
        val v = (flat.top + flat.bottom) / 2
        return v >= -SCREEN_SLACK && v <= 1 + SCREEN_SLACK && flat.left >= -SIDE_SLACK && flat.right <= 1 + SIDE_SLACK
    }

    /**
     * [holds]: satırın ortası ekranın üst kenarını bu kadar, yanları ekranın kenarlarını [SIDE_SLACK] kadar aşabilir. Alt
     * kenarda pay [BELOW_SLACK]: telefonun alt gövdesi örtülünce telefon kısa bulunuyor, son mesajlar ekranın altında
     * kalıyordu (gerçek kare gta6-telefon-sohbet-2; Mac ile aynı).
     */
    const val SCREEN_SLACK = 0.03
    const val SIDE_SLACK = 0.12
    const val BELOW_SLACK = 0.25

    /** Öğe kartın zemini mi (düz metin bunu atlar). */
    fun isBackdrop(item: ScreenTranslation.Item): Boolean = item.translation.isBlank()

    /**
     * Okunan karede telefon varsa yeri ve eğikliği; akla yatkın olmayan aday yok sayılır. [near]: açık telefonun son yeri
     * (bulunmuşsa); sıkı arama ıskalarsa orada gevşek doğrulama yapılır ([GamePhoneGeometry.locate]).
     */
    fun phone(image: PhoneImage, near: Handset? = null): Handset? = search(image, near).phone

    /** Altyazı hattının araması: bulunan telefon ya da (bulunamazsa) doğrulanmamış aday. */
    class Search(val phone: Handset?, val candidate: Handset?)

    /**
     * [phone]; telefon bulunamazsa [Search.candidate]: sıkı aramada yanları zayıf kalan akla yatkın aday
     * ([GamePhoneGeometry.Probe.weak]), yoksa null. Aday telefon sayılmaz; altyazı hattı ekranındaki satırları kısa süre
     * bekletir (Mac/iPhone: ScreenPhoneCard.search, Windows: ScreenPhoneCard.Phone(frame, near, out candidate)).
     */
    fun search(image: PhoneImage, near: Handset? = null): Search {
        val aspect = image.width.toDouble() / maxOf(1, image.height)
        val found = GamePhoneGeometry.search(image, near?.pose)
        found.pose?.let { pose ->
            if (!GamePhoneTracker.plausible(pose.bounds, image.width, image.height)) return Search(null, null)
            return Search(Handset(pose, aspect), null)
        }
        val weak = found.probe.weak ?: return Search(null, null)
        if (!GamePhoneTracker.plausible(weak.bounds, image.width, image.height)) return Search(null, null)
        return Search(null, Handset(weak, aspect))
    }

    /**
     * Kartın yeri: telefonun yanında, telefon boyunda; iki yanda da yer yoksa telefonun üstünde. İki yanda da yer varsa
     * kart başka çevirilerin ([others]) üstüne en az binen yana, eşitse daha geniş boş kalan yana konur.
     */
    internal fun cardBox(phone: TextBox, others: List<TextBox> = emptyList()): TextBox {
        val roomLeft = phone.left - 2 * GAP
        val roomRight = 1 - phone.right - 2 * GAP
        val wanted = maxOf((phone.right - phone.left) * CARD_SCALE, CARD_MIN)
        fun side(right: Boolean): TextBox? {
            val width = minOf(wanted, if (right) roomRight else roomLeft)
            if (width < MIN_WIDTH) return null
            val left = if (right) phone.right + GAP else phone.left - GAP - width
            return TextBox(left, phone.top, left + width, phone.bottom)
        }
        // Önce daha geniş yan; öbür yan ancak başka çevirilerin üstüne daha az binerse seçilir.
        val candidates = listOfNotNull(side(roomLeft < roomRight), side(roomLeft >= roomRight))
        if (candidates.isEmpty()) {
            // Yanda yer yoksa telefonun altında; orada da yer yoksa telefonun üstünde (Mac ile aynı).
            if (1 - SCREEN_MARGIN - (phone.bottom + GAP) >= MIN_BELOW) {
                val width = minOf(wanted, 1 - 2 * GAP)
                val left = minOf(maxOf(GAP, (phone.left + phone.right - width) / 2), 1 - GAP - width)
                return TextBox(left, phone.bottom + GAP, left + width, 1 - SCREEN_MARGIN)
            }
            return TextBox(maxOf(0.0, phone.left), phone.top, minOf(1.0, phone.right), phone.bottom)
        }
        var best = candidates.first()
        for (candidate in candidates.drop(1)) if (covered(candidate, others) < covered(best, others) - 1e-9) best = candidate
        return best
    }

    /** Kutunun başka kutularla örtüşen alanı. */
    internal fun covered(box: TextBox, others: List<TextBox>): Double = others.sumOf { other ->
        maxOf(0.0, minOf(box.right, other.right) - maxOf(box.left, other.left)) *
            maxOf(0.0, minOf(box.bottom, other.bottom) - maxOf(box.top, other.top))
    }

    private class Row(val item: ScreenTranslation.Item, val width: Double, val height: Double, val side: String)

    /**
     * Telefondaki öğeleri ([ScreenTranslation.Item.phone] bilgisi olanlar) telefonun yanındaki panelde dizer (Mac:
     * ScreenPhoneCard.layout ile birebir). Telefonda çevrilmiş öğe yoksa liste olduğu gibi döner. Çevrilmemiş öğeler (kişi
     * adı, "ok") panelde aslıyla görünür. Hizalı panel ([ScreenTranslation.Item.aligned]): her Türkçe balon telefondaki
     * İngilizce balonuyla aynı yükseklikte durur ([alignedTop]); çakışan balon en az kaydırmayla aşağı itilir (aralarında en
     * az [BUBBLE_SPACING] satır), panel gerekirse aşağı uzar; ekranın alt payına dayanınca satırlar alttan yukarı itilir,
     * yukarıda da yer kalmazsa en eski mesajlar düşer. Yazı küçülmez. Balonlar telefonun balon renginde ([bubbleColor]).
     * [lockedLine]: telefondaki satır yüksekliği yerine kullanılacak kilitli ölçüm ([PhonePanelSteady.steadyLine], #1152).
     * Kartın kutusu, akışla çizen eski TV için bütün satırları ve dolguyu alacak boydadır.
     */
    fun layout(items: List<ScreenTranslation.Item>, handset: Handset, textScale: Double = 1.0,
               lockedLine: Double? = null): List<ScreenTranslation.Item> {
        val onPhone = items.filter { it.phone?.role?.inCard == true }.sortedBy { it.phone!!.spot.top }
        if (onPhone.none { !it.unchanged }) return items
        val others = items.filter { it.phone?.role?.inCard != true }
        val start = cardBox(handset.bounds, others.filter { !it.unchanged }.map { it.box })
        val cardWidth = start.right - start.left
        val measured = lockedLine ?: measuredLine(onPhone) ?: 0.0
        val scale = minOf(MAX_SCALE, maxOf(MIN_SCALE, textScale))
        val line = minOf(MAX_LINE * scale, maxOf(MIN_LINE * scale, measured))
        val pad = cardWidth * 0.05
        val padY = line * 0.4
        val spacing = line * BUBBLE_SPACING
        fun flat(align: String, bold: Boolean) = TextLook(bold, false, align, false)

        // Sohbetin üstündeki kişi adı çizilmez (Sinan Bey, beta.100 3400/3402: "Cal" başlığı gereksiz); balonlar aynen kalır.
        // Sohbet dışı ekranda çevrilmeyen kart (kişi adı "Jason", yer adı) çizilmez.
        val body = onPhone.filter { it.phone?.role != Role.HEADER && !(isCard(it.phone!!.role) && it.unchanged) }
        // Sohbet dışı ekranın kartları tek renkte (telefonda en çok görünen satır kartı rengi): her kart kendi örneğiyle
        // ayrı renkte çiziliyordu (Sinan Bey, 3423: "stilleri tutarsız").
        val cardStyle = commonStyle(body.filter { isCard(it.phone!!.role) }.map { it.surface })
        // Cevap seçenekleri tek renkte (okunabilen örneklerin en çok görüneni): seçili seçeneğin çerçevesi ya da renk geçişi
        // örneği bozunca biri telefonun renginde, öbürü yedek renkte çiziliyordu (X, 26 Kas; iPhone ile aynı).
        val optionStyle = commonStyle(body.filter { it.phone!!.role == Role.OPTION }.map { it.surface })

        // Her satırın panelde kaplayacağı yer: genişliği rolünden, yüksekliği Türkçenin o genişlikte kaç satır tuttuğundan.
        // Sohbet listesinin satırı (ad + altındaki önizleme) ve ana ekran bileşeni tek kart olur ([listRow]).
        val rows = mutableListOf<Row>()
        var index = 0
        while (index < body.size) {
            val item = body[index]
            val role = item.phone!!.role
            index += 1
            if (isCard(role)) {
                cardRow(item, cardStyle, handset, line, cardWidth - 2 * pad)?.let { (made, height) ->
                    rows.add(Row(made, cardWidth - 2 * pad, height, "left"))
                }
                continue
            }
            if (role == Role.CONTACT || role == Role.PREVIEW || role == Role.WIDGET) {
                var name: ScreenTranslation.Item? = null
                var preview: ScreenTranslation.Item? = null
                when (role) {
                    Role.CONTACT -> {
                        name = item
                        if (index < body.size && body[index].phone?.role == Role.PREVIEW) {
                            preview = body[index]
                            index += 1
                        }
                    }
                    Role.PREVIEW -> preview = item
                    else -> name = item
                }
                listRow(name, preview, role == Role.WIDGET, handset, line, cardWidth - 2 * pad)?.let { (made, height) ->
                    rows.add(Row(made, cardWidth - 2 * pad, height, "left"))
                }
                continue
            }
            val kind = if (role == Role.MESSAGE) (if (isOutgoing(item.surface)) Role.OUTGOING else Role.INCOMING)
                else if (role == Role.OPTION) Role.OUTGOING else role
            val bubble = kind == Role.INCOMING || kind == Role.OUTGOING
            val widest = (if (bubble) BUBBLE_SHARE else 1.0) * cardWidth - (if (bubble) 0.0 else 2 * pad)
            val inner = widest - 2 * pad
            val lines = wrap(item.translation, (inner * handset.aspect / (line * CHAR_WIDTH)).toInt())
            val longest = (lines.maxOfOrNull { it.length } ?: 0) * line * CHAR_WIDTH / handset.aspect + 2 * pad
            val width = if (bubble) minOf(widest, maxOf(cardWidth * BUBBLE_MIN, longest)) else widest
            val surface = when (kind) {
                Role.OUTGOING -> bubbleColor(if (role == Role.OPTION) optionStyle else item.surface, OUTGOING)
                Role.INCOMING -> bubbleColor(item.surface, INCOMING)
                // Bölüm başlığı ("Önerilen", "Mesajlar") soluk ve kalın küçük başlık, sola yaslı; not ortalı (iPhone ile aynı).
                else -> NOTE
            }
            val part = when (kind) {
                Role.OUTGOING -> PanelPart.MINE
                Role.INCOMING -> PanelPart.THEIRS
                else -> PanelPart.NOTE
            }
            val side = if (kind == Role.OUTGOING) "right" else if (kind == Role.NOTE) "center" else "left"
            val placed = item.copy(unchanged = false, lineHeight = line, surface = surface,
                look = flat(side, kind == Role.HEADING), panel = part)
            rows.add(Row(placed, width, lines.size * line * LINE_SPACING + line * BUBBLE_PADDING, side))
        }
        if (rows.isEmpty()) return items
        val limit = 1 - SCREEN_MARGIN
        val bodyTop = SCREEN_MARGIN
        // Her balon kendi İngilizce balonunun yüksekliğinde; çakışan balon üsttekinin altına en az kaydırmayla itilir. Panel
        // ekranın alt kenar payını aşarsa satırlar alttan yukarı itilir; yukarıda da yer kalmazsa en eski satırlar düşer.
        fun alignedTops(): DoubleArray {
            val tops = DoubleArray(rows.size)
            for (i in rows.indices) {
                val below = if (i == 0) bodyTop else tops[i - 1] + rows[i - 1].height + spacing
                tops[i] = maxOf(alignedTop(rows[i].item, line), below)
            }
            var floor = limit
            for (i in rows.indices.reversed()) {
                tops[i] = minOf(tops[i], floor - rows[i].height)
                floor = tops[i] - spacing
            }
            return tops
        }
        var tops = alignedTops()
        while (rows.size > 1 && tops[0] < bodyTop - 1e-9) {
            rows.removeAt(0)
            tops = alignedTops()
        }
        if (tops.isNotEmpty() && tops[0] < bodyTop) tops[0] = bodyTop
        val contentTop = if (tops.isNotEmpty()) tops[0] else start.top
        val contentBottom = if (rows.isNotEmpty()) tops.last() + rows.last().height else start.bottom
        // Kart: telefon boyunda, balonlar aşağı uzanırsa onlarla; eski TV'nin akışı (dolgu, aralıklar) da sığar.
        val flow = 2 * padY + rows.sumOf { it.height } + maxOf(0, rows.size - 1) * spacing
        val cardTop = maxOf(SCREEN_MARGIN, minOf(start.top, contentTop))
        val card = TextBox(start.left, cardTop, start.right,
            minOf(limit, maxOf(start.bottom, contentBottom + padY, cardTop + flow)))

        // Kartın altında kalan başka bir çeviri kartın telefondan uzak yanına alınır; oraya sığmazsa yerinde kalır.
        val cardOnLeft = card.right <= handset.bounds.left + 1e-9
        val result = others.map { item ->
            if (item.unchanged || covered(item.box, listOf(card)) <= 0) return@map item
            val width = item.box.right - item.box.left
            val left = if (cardOnLeft) card.left - GAP - width else card.right + GAP
            if (left >= 0 && left + width <= 1) item.copy(box = TextBox(left, item.box.top, left + width, item.box.bottom)) else item
        }.toMutableList()
        result.add(ScreenTranslation.Item("", BACKDROP_TEXT, card, line, surface = CARD, look = flat("left", false),
            panel = PanelPart.CARD, aligned = true))

        rows.forEachIndexed { index, row ->
            val left = when (row.side) {
                "right" -> card.right - pad - row.width
                "center" -> (card.left + card.right - row.width) / 2
                else -> card.left + pad
            }
            result.add(row.item.copy(box = TextBox(left, tops[index], left + row.width, tops[index] + row.height)))
        }
        return result
    }

    /** Sohbet dışı ekranın kartı mı (ana ekranın yazısı da). */
    internal fun isCard(role: Role): Boolean = role == Role.CARD || role == Role.HOME

    /** En çok görünen okunmuş renk (eşitlikte önce gelen); örnek yoksa null. */
    internal fun commonStyle(styles: List<TextSurface?>): TextSurface? {
        val known = styles.filterNotNull().filter { it.background.uppercase() != GamePhonePalette.neutral.background }
        var best: TextSurface? = null
        var bestCount = 0
        for (style in known) {
            val count = known.count { it == style }
            if (best == null || count > bestCount) {
                best = style
                bestCount = count
            }
        }
        return best
    }

    /**
     * Sohbet dışı ekranın kartı: mesaj listesi kartının görünüşünde, avatarsız. Kalın başlık ("Strength Workout") ve
     * altında yazı ("Level 3/4"), yalnız başlık (makale başlığı) ya da yalnız yazı (gönderinin açıklaması, ayar satırı).
     * Kartın üstü İngilizcesiyle aynı hizada, boyu Türkçenin satır sayısına ve telefondaki bloğun boyuna göre (Mac/iPhone
     * ve Windows ile aynı).
     */
    internal fun cardRow(item: ScreenTranslation.Item, style: TextSurface?, handset: Handset, line: Double,
                         width: Double): Pair<ScreenTranslation.Item, Double>? {
        val parts = item.translation.split('\n')
        if (parts.none { it.isNotBlank() }) return null
        val placement = item.phone
        val title: String
        val below: String
        if (placement?.bold == true) {
            title = parts.joinToString(" ")
            below = ""
        } else if (placement?.titled == true && parts.size >= 2) {
            title = parts[0]
            below = parts.drop(1).joinToString(" ")
        } else {
            title = ""
            below = parts.joinToString(" ")
        }
        val row = ListRow(title, below, widget = false)
        val inset = ROW_PADDING * line / handset.aspect
        val inner = width - 2 * inset
        val perLine = (inner * handset.aspect / (line * CHAR_WIDTH)).toInt()
        val lines = (if (title.isEmpty()) 0 else wrap(title, perLine).size) + (if (below.isEmpty()) 0 else wrap(below, perLine).size)
        val needed = maxOf(1, lines) * line * LINE_SPACING + 2 * ROW_PADDING * line
        val original = item.box.bottom - item.box.top + line * BUBBLE_PADDING
        val placed = item.copy(unchanged = false, lineHeight = line, surface = bubbleColor(style ?: item.surface, ROW_COLOR),
            look = TextLook(false, false, "left", false), panel = PanelPart.ROW, listRow = row)
        return placed to maxOf(needed, original)
    }

    /** Liste kartının rengi okunamadıysa: GTA 6 telefonunun açık satır kartı. */
    val ROW_COLOR = TextSurface("#F4F1EC", "#17181B")
    /** Liste kartında avatarın çapı, avatarla yazı arası ve kartın iç dolgusu (satır yüksekliğine oranla). */
    const val AVATAR_LINES = 2.2
    const val AVATAR_GAP = 0.5
    const val ROW_PADDING = 0.45

    /**
     * Liste satırını (ad + önizleme) ya da ana ekran bileşenini tek kart yapar: kartın üstü adın İngilizcesiyle aynı
     * hizada, boyu Türkçenin satır sayısına ve telefondaki satırın boyuna göre (hangisi büyükse; kartlar arası boşluk
     * telefondakiyle orantılı kalır). Kart telefonun satır kartı renginde (önizlemenin örneklenen zemini). Avatarın,
     * rozetin ve seçim çerçevesinin karedeki yeri [ListRow]'a yazılır; kesmek çağıranın işi ([PhoneListLook]). iPhone ile aynı.
     */
    internal fun listRow(name: ScreenTranslation.Item?, preview: ScreenTranslation.Item?, widget: Boolean, handset: Handset,
                         line: Double, width: Double): Pair<ScreenTranslation.Item, Double>? {
        val first = name ?: preview ?: return null
        val title: String
        val below: String
        if (widget) {
            val parts = first.translation.split('\n', limit = 2)
            title = parts[0]
            below = if (parts.size > 1) parts[1] else ""
        } else {
            title = name?.translation ?: ""
            below = preview?.translation ?: ""
        }
        val inset = ROW_PADDING * line / handset.aspect
        val inner = width - 2 * inset - (AVATAR_LINES + AVATAR_GAP) * line / handset.aspect
        val wrapped = if (below.isEmpty()) 0 else wrap(below, (inner * handset.aspect / (line * CHAR_WIDTH)).toInt()).size
        val lines = (if (title.isEmpty()) 0 else 1) + wrapped
        val needed = maxOf(maxOf(1, lines) * line * LINE_SPACING, AVATAR_LINES * line) + 2 * ROW_PADDING * line
        // Telefondaki satırın boyu (adın üstünden önizlemenin altına, dolguyla).
        val last = preview ?: first
        val original = last.box.bottom - first.box.top + line * BUBBLE_PADDING
        // Karedeki yerler (düz ekrandan): avatar adın solunda, ad ve önizleme bloğunun ortasında; rozet satırın sağ ucunda,
        // ad hizasında; seçim çerçevesi satırın üst kenarı (adın biraz üstü).
        var portraitSpot: TextBox? = null
        var badgeSpot: TextBox? = null
        var frameSpot: TextBox? = null
        val top = first.phone?.spot
        val bottom = last.phone?.spot
        if (top != null && bottom != null) {
            val shape = Handset.SCREEN_SHAPE
            if (widget) {
                // Bileşenin simgesi başlığın solunda (sayaç satırının sol hizasında), başlık satırı boyunda.
                val size = (top.bottom - top.top) * 0.5
                portraitSpot = handset.frameBox(TextBox(top.left - size * 0.1 / shape, top.top - size * 0.1,
                    top.left + size * 1.1 / shape, top.top + size * 1.1))
            } else {
                val block = maxOf(1e-4, bottom.bottom - top.top)
                val center = (top.top + bottom.bottom) / 2
                val size = block * 1.35
                val right = minOf(top.left, bottom.left) - block * 0.1 / shape
                portraitSpot = handset.frameBox(TextBox(right - size / shape, center - size / 2, right, center + size / 2))
                val nameCenter = (top.top + top.bottom) / 2
                val badge = block * 0.62
                badgeSpot = handset.frameBox(TextBox(0.985 - badge / shape, nameCenter - badge / 2, 0.985, nameCenter + badge / 2))
                frameSpot = handset.frameBox(TextBox(maxOf(0.25, top.left), top.top - block * 0.6, 0.8, top.top - block * 0.05))
            }
        }
        val row = ListRow(title, below, widget = widget, portraitSpot = portraitSpot, badgeSpot = badgeSpot, frameSpot = frameSpot)
        val item = first.copy(
            source = if (widget) first.source else listOfNotNull(name?.source, preview?.source).joinToString("\n"),
            translation = listOf(title, below).filter { it.isNotEmpty() }.joinToString("\n"),
            unchanged = false, lineHeight = line,
            surface = bubbleColor(preview?.surface ?: first.surface, if (widget) CARD else ROW_COLOR),
            look = TextLook(false, false, "left", false), panel = PanelPart.ROW, listRow = row)
        return item to maxOf(needed, original)
    }

    /**
     * Hizalı panelde satırın istenen üst kenarı: Türkçe yazının üstü İngilizce yazının üstünde ([ScreenTranslation.Item.box],
     * karede); balon üst dolgusu kadar yukarıdan başlar (Mac ile aynı).
     */
    fun alignedTop(item: ScreenTranslation.Item, line: Double): Double = item.box.top - line * BUBBLE_PADDING / 2

    /** Kişi adının (başlık) yüksekliği ve altındaki boşluk (satır yüksekliğine oranla); başlık balondan küçük. */
    const val TITLE_HEIGHT = 1.4
    const val TITLE_GAP = 0.3
    /** Hizalı panelde balonların, notların ve başlığın zemin örtüsü. */
    const val BUBBLE_OPACITY = 0.85

    /**
     * Balonun rengi: telefondaki balondan örneklenen zemin ve yazı ([GamePhonePalette]); örnek yoksa ya da okunamadıysa
     * (nötr yedek, geçersiz renk) [fallback]. Örneğin yazısı zeminde okunmuyorsa (kontrast 4,5'ten az) zemine göre koyu ya da
     * açık yazı (Mac ile aynı).
     */
    fun bubbleColor(style: TextSurface?, fallback: TextSurface): TextSurface {
        if (style == null || style.background.equals(GamePhonePalette.neutral.background, ignoreCase = true)) return fallback
        val background = rgb(style.background) ?: return fallback
        val ink = rgb(style.foreground)
        if (ink != null && contrast(background, ink) >= 4.5) return style.copy(flat = true)
        val dark = "#17181B"
        val light = "#F3EEE4"
        return TextSurface(style.background, if (contrast(background, rgb(dark)!!) >= contrast(background, rgb(light)!!)) dark else light)
    }

    private fun rgb(hex: String): DoubleArray? {
        if (hex.length != 7 || hex[0] != '#') return null
        val value = hex.substring(1).toIntOrNull(16) ?: return null
        return doubleArrayOf(((value shr 16) and 0xFF).toDouble(), ((value shr 8) and 0xFF).toDouble(), (value and 0xFF).toDouble())
    }

    /** İki rengin WCAG kontrast oranı. */
    internal fun contrast(a: DoubleArray, b: DoubleArray): Double {
        fun linear(n: Double): Double {
            val s = n / 255
            return if (s <= 0.04045) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        fun luminance(c: DoubleArray) = 0.2126 * linear(c[0]) + 0.7152 * linear(c[1]) + 0.0722 * linear(c[2])
        val x = luminance(a)
        val y = luminance(b)
        return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
    }

    /**
     * Kartta dizilecek telefon yazılarının satır yüksekliklerinin ortancası (panelin yazı boyu); yoksa null. Çift sayıda
     * ölçümde küçük ortanca alınır: iki öğeden biri fotoğrafın içindeki büyük yazıysa (3416) panel onun boyunda çiziliyordu.
     */
    fun measuredLine(items: List<ScreenTranslation.Item>): Double? {
        val heights = items.filter { it.phone?.role?.inCard == true }.map { it.lineHeight }.sorted()
        return if (heights.isEmpty()) null else heights[(heights.size - 1) / 2]
    }

    /** Metni sözcük sözcük en çok [perLine] harflik satırlara böler (çok uzun sözcük kendi satırında kalır). */
    internal fun wrap(text: String, perLine: Int): List<String> {
        val limit = maxOf(4, perLine)
        val lines = mutableListOf<String>()
        for (paragraph in text.split('\n')) {
            var current = ""
            for (word in paragraph.split(Regex("\\s+")).filter { it.isNotEmpty() }) {
                if (current.isEmpty()) current = word
                else if (current.length + 1 + word.length <= limit) current += " $word"
                else {
                    lines.add(current)
                    current = word
                }
            }
            lines.add(current)
        }
        return lines
    }

    /** Çizilecek sohbet paneli: zemin, kişinin adı, mesajlar telefondaki sırasıyla ve panel dışındaki öğeler. */
    data class Panel(
        val card: ScreenTranslation.Item,
        val title: ScreenTranslation.Item?,
        val messages: List<ScreenTranslation.Item>,
        val outside: List<ScreenTranslation.Item>,
    ) {
        /** Hizalı panel: zemin çizilmez, her parça kendi kutusunun yerinde; değilse akışla, kartta. */
        val aligned: Boolean get() = card.aligned
    }

    /** Öğelerde panel varsa parçaları; yoksa null (Mac: ScreenPhoneCard.panel). */
    fun panel(items: List<ScreenTranslation.Item>): Panel? {
        val card = items.firstOrNull { it.panel == PanelPart.CARD } ?: return null
        val parts = items.filter { it.panel != null && it.panel != PanelPart.CARD }
        return Panel(card, parts.firstOrNull { it.panel == PanelPart.TITLE },
            parts.filter { it.panel != PanelPart.TITLE }.sortedBy { it.box.top }, items.filter { it.panel == null })
    }

    /**
     * Saydam altyazı penceresindeki sohbet paneli (Mac SubtitleOverlay, Windows SubtitleOverlayWindow; ortak çekirdekte
     * dört platformda aynı): pencere oyun karesi değil, kullanıcının seçtiği alan olduğundan balonlar telefondaki İngilizce
     * balonlarına hizalanamaz. Görünüm hizalı panelle aynıdır (koyu kart ve simge yok; her balon ayrı, telefonun balon
     * renginde, [bubbleColor]): balonlar alanın telefon tarafındaki kenarında üstten alta, telefondaki sırasıyla ve
     * aralarındaki boşlukla (en çok [STACKED_GAP_MAX] satır) dizilir; gelen sola, giden sağa yaslı, kişi adı üstte küçük
     * başlık. Yazı boyu [font] (piksel, en az [STACKED_MIN_FONT]). Mesajların hepsi alana sığmazsa önce sütun genişler (alanın
     * en çok [STACKED_WIDE_SHARE]'i), yine sığmazsa yazı [STACKED_MIN_FONT]'a dek küçülür; yalnız hiçbiri yetmezse yazı
     * verilen boyda kalır ve en eski mesajlar düşer. X (26 Kas, beta.104): saydam pencerede uzun ilk mesaj (dar sütunda 10+
     * satır) sığmadığı için hiç çizilmiyordu, "en üstteki mesaj çevrilmiyor" sanılıyordu. Kutular
     * alana oranla (0–1); [com.couchsubs.mobile.ui.PhonePanelAligned] hizalı paneli çizer gibi çizer. Aynı girdi her zaman
     * birebir aynı çıktı (#1279). Mac: ScreenPhoneCard.stacked, Windows: ScreenPhoneCard.Stacked.
     */
    fun stacked(panel: Panel, width: Double, height: Double, font: Double): Panel {
        if (width <= 0 || height <= 0) return panel
        val given = maxOf(STACKED_MIN_FONT, font)
        val narrow = minOf(width * STACKED_SHARE, given * STACKED_CHARS) / width
        val wide = maxOf(narrow, STACKED_WIDE_SHARE)
        // Sığan ilk düzen: verilen boy dar sütunda, geniş sütunda, sonra küçülen yazıyla; hiçbiri sığmazsa ilk düzen.
        val tries = mutableListOf(narrow to given)
        if (wide > narrow + 1e-9) tries += wide to given
        var smaller = given
        while (smaller > STACKED_MIN_FONT + 1e-9) {
            smaller = maxOf(STACKED_MIN_FONT, smaller * 0.9)
            tries += wide to smaller
        }
        for ((column, size) in tries) {
            val result = stackedPanel(panel, width, height, size, column)
            if (result.messages.size == panel.messages.size) return result
        }
        return stackedPanel(panel, width, height, given, narrow)
    }

    private fun stackedPanel(panel: Panel, width: Double, height: Double, size: Double, column: Double): Panel {
        // Çiziciler yazı boyunu satır yüksekliğinin 0,85'i alır (PhonePanelAligned).
        val line = size / 0.85 / height
        val aspect = width / height
        val right = (panel.card.box.left + panel.card.box.right) / 2 > 0.5
        val left = if (right) 1 - column else 0.0
        // Balonun yan dolgusu (çizicilerde yazı boyunun 0,6'sı), alana oranla.
        val padX = size * 0.6 / width

        val card = panel.card.copy(box = TextBox(left, 0.0, left + column, 1.0), lineHeight = line, aligned = true)
        val title = panel.title?.copy(box = TextBox(left, 0.0, left + column, line * TITLE_HEIGHT), lineHeight = line)
        val bodyTop = if (title == null) 0.0 else line * (TITLE_HEIGHT + TITLE_GAP)

        class Row(val item: ScreenTranslation.Item, val width: Double, val height: Double, val gap: Double)
        val rows = panel.messages.mapIndexed { index, source ->
            val bubble = source.panel == PanelPart.MINE || source.panel == PanelPart.THEIRS
            val surface = when (source.panel) {
                PanelPart.MINE -> bubbleColor(source.surface, OUTGOING)
                PanelPart.THEIRS -> bubbleColor(source.surface, INCOMING)
                else -> source.surface
            }
            val item = source.copy(lineHeight = line, surface = surface)
            val widest = (if (bubble) BUBBLE_SHARE else 1.0) * column
            // Liste kartında yazı avatarın sağında; kart en az avatar boyunda.
            val listed = item.panel == PanelPart.ROW
            val avatar = if (listed) (AVATAR_LINES + AVATAR_GAP + 2 * ROW_PADDING) * line / aspect else 0.0
            val lines = wrap(item.translation, ((widest - 2 * padX - avatar) * aspect / (line * CHAR_WIDTH)).toInt())
            // Telefondaki aralık satır yüksekliğine oranla korunur (önizleme kişi adının hemen altında kalır).
            val gap = if (index == 0) BUBBLE_SPACING else minOf(STACKED_GAP_MAX,
                maxOf(0.0, (source.box.top - panel.messages[index - 1].box.bottom) / maxOf(1e-9, source.lineHeight)))
            val height = if (listed) maxOf(lines.size * line * LINE_SPACING, AVATAR_LINES * line) + 2 * ROW_PADDING * line
                else lines.size * line * LINE_SPACING + line * BUBBLE_PADDING
            Row(item, widest, height, gap * line)
        }
        // Sığmazsa en eski mesajlar düşer; tek kalan çok uzun mesaj yine çizilir (aşağıda kırpılır).
        fun bottom(start: Int): Double {
            var sum = bodyTop
            for (i in start until rows.size) sum += rows[i].height + (if (i > start) rows[i].gap else 0.0)
            return sum
        }
        var first = 0
        while (first < rows.size - 1 && bottom(first) > 1 + 1e-9) first++

        val messages = mutableListOf<ScreenTranslation.Item>()
        var top = bodyTop
        for (i in first until rows.size) {
            val row = rows[i]
            if (i > first) top += row.gap
            val x = if (row.item.panel == PanelPart.MINE) left + column - row.width else left
            messages += row.item.copy(box = TextBox(x, top, x + row.width, top + row.height))
            top += row.height
        }
        return Panel(card, title, messages, panel.outside)
    }

    /**
     * Saydam pencerede panelin yazısı en az bu boyda (piksel); sütunun eni alanın en çok [STACKED_SHARE]'i ve yazı boyunun
     * [STACKED_CHARS] katı; balonlar arası boşluk en çok [STACKED_GAP_MAX] satır.
     */
    const val STACKED_MIN_FONT = 13.0
    const val STACKED_SHARE = 0.45
    const val STACKED_CHARS = 20.0
    const val STACKED_GAP_MAX = 1.2
    /** Mesajlar sığmazsa sütun alanın en çok bu payına genişler. */
    const val STACKED_WIDE_SHARE = 0.9

    /** Altyazı boyutu ayarının (TV pikseli, 1080p) panel yazısına çarpanı: varsayılan boyda 1. */
    fun textScale(fontSize: Int): Double = minOf(MAX_SCALE, maxOf(MIN_SCALE, fontSize / DEFAULT_FONT_SIZE.toDouble()))

    /**
     * Tarafı hizadan belli olmayan balon oyuncunun mu: zemini belirgin mavi, doygun bir renk ya da açık mavimsi (GTA 6'nın
     * giden balonu #D3DCF4; gelen balon kremdir).
     */
    internal fun isOutgoing(surface: TextSurface?): Boolean {
        if (isBlue(surface)) return true
        val hex = surface?.background ?: return false
        if (hex.length != 7 || !hex.startsWith("#")) return false
        val value = hex.substring(1).toIntOrNull(16) ?: return false
        val r = (value shr 16) and 0xFF
        val g = (value shr 8) and 0xFF
        val b = value and 0xFF
        val max = maxOf(r, g, b)
        val min = minOf(r, g, b)
        return (max - min >= 70 && max >= 90) || (b - r >= 20 && b >= g)
    }

    /** Balonun okunan rengi belirgin mavi mi (giden mesaj balonu): mavi kanal kırmızı ve yeşilin ortalamasından en az 40 fazla. */
    internal fun isBlue(surface: TextSurface?): Boolean {
        val hex = surface?.background ?: return false
        if (hex.length != 7 || !hex.startsWith("#")) return false
        val value = hex.substring(1).toIntOrNull(16) ?: return false
        val r = (value shr 16) and 0xFF
        val g = (value shr 8) and 0xFF
        val b = value and 0xFF
        return b - (r + g) / 2 >= 40
    }
}
