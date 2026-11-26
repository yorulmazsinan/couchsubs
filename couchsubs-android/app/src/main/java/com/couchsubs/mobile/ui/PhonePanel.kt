// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.graphics.BitmapFactory
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.couchsubs.mobile.core.ScreenPhoneCard
import com.couchsubs.mobile.core.ScreenTranslation

/**
 * GTA 6 telefonunun yanındaki sohbet paneli, karedeki yerinde ([width]×[height] karenin gösterildiği alan). Yazı boyu
 * panelin satır yüksekliğinden; küçük ekranda en az [minFont]. Hizalı panelde ([ScreenPhoneCard.Panel.aligned]) her
 * parça kendi kutusunda ([PhonePanelAligned]); değilse akışla kartta ([PhonePanelView]). Mac/iPhone PhonePanelInFrame,
 * Windows PhoneBlocksCanvas, TV app.js placePanel ile aynı çizim.
 */
@Composable
fun PhonePanelInFrame(panel: ScreenPhoneCard.Panel, width: Dp, height: Dp, minFont: Float = 12f) {
    val box = panel.card.box
    val font = maxOf(minFont, (height.value * panel.card.lineHeight * 0.85).toFloat())
    if (panel.aligned) {
        PhonePanelAligned(panel, width, height, font)
        return
    }
    PhonePanelView(panel, font, maxOf(6f, (ScreenPhoneCard.PANEL_RADIUS * height.value / 1080).toFloat()).dp,
        Modifier
            .offset(x = width * box.left.toFloat(), y = height * box.top.toFloat())
            .size(width * (box.right - box.left).toFloat(), height * (box.bottom - box.top).toFloat()))
}

/**
 * Telefon paneli görününce solarak gelir, telefon kalkınca (panel null) solarak kaybolur (TV, Mac, iPhone, Windows ile
 * aynı, 250 ms); kaybolurken son panel çizilmeye devam eder.
 */
@Composable
fun FadingPhonePanel(panel: ScreenPhoneCard.Panel?, width: Dp, height: Dp, minFont: Float = 12f) {
    var last by remember { mutableStateOf(panel) }
    if (panel != null) last = panel
    AnimatedVisibility(visible = panel != null, enter = fadeIn(tween(250)), exit = fadeOut(tween(250))) {
        last?.let { PhonePanelInFrame(it, width, height, minFont) }
    }
}

/**
 * Hizalı panel (Mac/iPhone PhonePanelAligned, Windows PhonePanelView.Aligned, TV app.js placeAlignedPanel aynı çizim):
 * zemin kartı ve simge yok; her parça kendi kutusunda (Türkçe balon telefondaki İngilizce balonuyla aynı yükseklikte),
 * telefonun balon renginde %85 örtülü, yuvarlak köşeli; gelen sola, giden sağa yaslı; kişi adı üstte küçük başlık. Gerçek
 * yazı tahminden uzunsa alttaki parça en az kaydırmayla itilir (yazı küçülmez, yatayda sıkıştırılmaz).
 */
@Composable
fun PhonePanelAligned(panel: ScreenPhoneCard.Panel, width: Dp, height: Dp, fontSize: Float) {
    val font = maxOf(8f, fontSize)
    val parts = listOfNotNull(panel.title) + panel.messages
    val density = LocalDensity.current
    Layout(content = {
        parts.forEach { item -> AlignedPart(item, item === panel.title, font, width * (item.box.right - item.box.left).toFloat(), height) }
    }) { measurables, constraints ->
        val w = width.toPx()
        val h = height.toPx()
        val usual = with(density) { (font / 0.85f * 0.6f).dp.toPx() }
        val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
        val tops = IntArray(parts.size)
        var bottom = 0f
        var plannedBottom = 0f
        parts.forEachIndexed { i, item ->
            var top = (item.box.top * h).toFloat()
            // Çakışma: üsttekinin gerçek altına, bilgisayarın bıraktığı aralık (en çok olağan boşluk) korunarak.
            if (i > 0) top = maxOf(top, bottom + maxOf(0f, minOf(top - plannedBottom, usual)))
            plannedBottom = (item.box.bottom * h).toFloat()
            bottom = top + placeables[i].height
            tops[i] = top.toInt()
        }
        layout(constraints.maxWidth, constraints.maxHeight) {
            placeables.forEachIndexed { i, placeable -> placeable.place((parts[i].box.left * w).toInt(), tops[i]) }
        }
    }
}

@Composable
private fun AlignedPart(item: ScreenTranslation.Item, title: Boolean, font: Float, rowWidth: Dp, height: Dp) {
    val row = item.listRow
    if (item.panel == ScreenPhoneCard.PanelPart.ROW && row != null) {
        PhoneListCard(item, row, font, rowWidth, height * (item.box.bottom - item.box.top).toFloat())
        return
    }
    val listed = isListRow(item)
    val note = item.panel == ScreenPhoneCard.PanelPart.NOTE && !listed
    val mine = item.panel == ScreenPhoneCard.PanelPart.MINE
    val size = if (title) font * 0.8f else if (listed) font * 0.92f else if (note) font * 0.8f else font
    val weight = if (title || item.look?.bold == true) FontWeight.Bold else if (listed) FontWeight.Normal
        else if (note) FontWeight.Medium else FontWeight.SemiBold
    Row(Modifier.width(rowWidth), horizontalArrangement = if (mine) Arrangement.End else if (note) Arrangement.Center else Arrangement.Start) {
        Text(item.translation, style = TextStyle(fontSize = size.sp, lineHeight = (size * 1.2f).sp, fontWeight = weight,
            letterSpacing = 0.sp), color = color(item.surface?.foreground, Color.White),
            textAlign = if (note) TextAlign.Center else TextAlign.Start, maxLines = if (title) 1 else Int.MAX_VALUE,
            overflow = if (title) TextOverflow.Ellipsis else TextOverflow.Clip,
            modifier = Modifier.widthIn(max = rowWidth)
                .clip(RoundedCornerShape((font * 0.75f).dp))
                .background(color(item.surface?.background, Color.Black).copy(alpha = ScreenPhoneCard.BUBBLE_OPACITY.toFloat()))
                .padding(horizontal = (font * 0.6f).dp, vertical = (font * 0.3f).dp))
    }
}

/**
 * Telefon listesinin tek kartı ([ScreenPhoneCard.ListRow]; iPhone PhoneListCard, TV app.js `placeListCard`, Windows
 * PhoneBlocksCanvas aynı çizim): telefonun satır kartı renginde yuvarlak köşeli kart; solda oyundan kesilmiş avatar,
 * yanında kalın ad ve altında önizleme, sağda rozet; seçili satırda telefondaki renkte çerçeve. Kartın üstü adın
 * İngilizcesiyle aynı hizada, boyu kutusu kadar.
 */
@Composable
private fun PhoneListCard(item: ScreenTranslation.Item, row: ScreenPhoneCard.ListRow, font: Float, width: Dp, height: Dp) {
    val line = font / 0.85f
    val avatar = remember(row.avatar) { pngImage(row.avatar) }
    val badge = remember(row.badge) { pngImage(row.badge) }
    val ink = color(item.surface?.foreground, Color.Black)
    val shape = RoundedCornerShape((line * 0.8f).dp)
    var card = Modifier.size(width, height)
        .clip(shape)
        .background(color(item.surface?.background, Color.White).copy(alpha = ScreenPhoneCard.BUBBLE_OPACITY.toFloat()))
    row.selected?.let { selected ->
        card = card.border(maxOf(1.5f, line * 0.12f).dp, color(selected, Color.Blue), shape)
    }
    Row(card.padding((line * ScreenPhoneCard.ROW_PADDING.toFloat()).dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy((line * ScreenPhoneCard.AVATAR_GAP.toFloat()).dp)) {
        avatar?.let {
            val side = (line * ScreenPhoneCard.AVATAR_LINES.toFloat()).dp
            Image(it, contentDescription = null, contentScale = ContentScale.FillBounds, filterQuality = FilterQuality.Medium,
                modifier = Modifier.size(side).clip(RoundedCornerShape(side * 0.3f)))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy((line * 0.1f).dp)) {
            if (row.name.isNotEmpty()) {
                // Avatarsız kart (sohbet dışı ekran: makale başlığı) başlığı satır kırar; kişi adı tek satır (Mac/iPhone ile aynı).
                Text(row.name, style = TextStyle(fontSize = font.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.sp), color = ink,
                    maxLines = if (row.avatar == null) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis)
            }
            if (row.preview.isNotEmpty()) {
                Text(row.preview, style = TextStyle(fontSize = (font * 0.92f).sp, fontWeight = FontWeight.Normal, letterSpacing = 0.sp),
                    color = ink.copy(alpha = ink.alpha * 0.8f))
            }
        }
        badge?.let {
            Image(it, contentDescription = null, contentScale = ContentScale.FillBounds, filterQuality = FilterQuality.Medium,
                modifier = Modifier.align(Alignment.Top).size((line * 1.1f).dp))
        }
    }
}

/** PNG data: adresinden resim; çözülemezse null. */
private fun pngImage(url: String?): ImageBitmap? {
    val comma = url?.indexOf(',') ?: return null
    if (comma < 0) return null
    return runCatching {
        val bytes = android.util.Base64.decode(url.substring(comma + 1), android.util.Base64.DEFAULT)
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.asImageBitmap()
    }.getOrNull()
}
/**
 * Sohbet paneli: yuvarlak köşeli, yarı saydam koyu kart; üstte kişinin adı, altında mesajlar sırayla (karşı taraf solda
 * krem, oyuncu sağda amber balon, not ortada). Sığmayan en eski mesajlar üstten kırpılır, son mesajlar görünür kalır. Sağ
 * altta sade kanepe simgesi.
 */
@Composable
fun PhonePanelView(panel: ScreenPhoneCard.Panel, fontSize: Float, radius: Dp, modifier: Modifier = Modifier) {
    val font = maxOf(8f, fontSize)
    val card = panel.card.surface
    val foreground = color(card?.foreground, Color.White)
    Box(modifier.clip(RoundedCornerShape(radius))
        .background(color(card?.background, Color.Black).copy(alpha = ScreenPhoneCard.PANEL_OPACITY.toFloat()))) {
        Column(Modifier.fillMaxSize().padding(start = (font * 0.6f).dp, top = (font * 0.55f).dp, end = (font * 0.6f).dp,
            bottom = (font * 1.3f).dp)) {
            panel.title?.let { title ->
                Text(title.translation, style = TextStyle(fontSize = (font * 1.05f).sp, fontWeight = FontWeight.Bold),
                    color = color(title.surface?.foreground, foreground), textAlign = TextAlign.Center, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height((font * 0.5f).dp))
            }
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().clipToBounds(), contentAlignment = Alignment.BottomStart) {
                val bubbleMax = maxWidth * 0.84f
                Column(Modifier.fillMaxWidth().wrapContentHeight(align = Alignment.Bottom, unbounded = true)) {
                    panel.messages.forEachIndexed { index, item -> Message(item, font, bubbleMax, gap(panel.messages, index)) }
                }
            }
        }
        Canvas(Modifier.align(Alignment.BottomEnd).padding((font * 0.45f).dp).size((font * 0.9f).dp, (font * 0.6f).dp)) {
            val sx = size.width / 24f
            val sy = size.height / 16f
            for (part in ScreenPhoneCard.COUCH_GLYPH) {
                drawRoundRect(foreground.copy(alpha = 0.35f), Offset(part[0].toFloat() * sx, part[1].toFloat() * sy),
                    Size(part[2].toFloat() * sx, part[3].toFloat() * sy), CornerRadius(part[4].toFloat() * sx, part[4].toFloat() * sy))
            }
        }
    }
}

/** Sohbet listesinin satırı (kişi adı, önizleme, bölüm başlığı): sola yaslı not; ad ve başlık kalın. iPhone ile aynı. */
internal fun isListRow(item: ScreenTranslation.Item): Boolean =
    item.panel == ScreenPhoneCard.PanelPart.NOTE && item.look?.align == "left"

/** Satırın üstündeki boşluk (yazı boyuna oranla): önizleme, üstündeki kişi adının hemen altındadır. iPhone ile aynı. */
internal fun gap(messages: List<ScreenTranslation.Item>, index: Int): Float {
    if (index <= 0) return 0.45f
    val item = messages[index]
    val previous = messages[index - 1]
    if (isListRow(item) && isListRow(previous) && item.look?.bold != true && previous.look?.bold == true &&
        previous.surface?.foreground != ScreenPhoneCard.NOTE.foreground) return 0.08f
    return 0.45f
}

@Composable
private fun Message(item: ScreenTranslation.Item, font: Float, bubbleMax: Dp, gap: Float) {
    val note = item.panel == ScreenPhoneCard.PanelPart.NOTE
    val mine = item.panel == ScreenPhoneCard.PanelPart.MINE
    val text = color(item.surface?.foreground, Color.White)
    if (isListRow(item)) {
        Text(item.translation, style = TextStyle(fontSize = (font * 0.92f).sp,
            fontWeight = if (item.look?.bold == true) FontWeight.Bold else FontWeight.Normal), color = text,
            textAlign = TextAlign.Start, modifier = Modifier.fillMaxWidth().padding(top = (font * gap).dp))
        return
    }
    if (note) {
        Text(item.translation, style = TextStyle(fontSize = (font * 0.8f).sp, fontWeight = FontWeight.Medium), color = text,
            textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = (font * gap).dp))
        return
    }
    Row(Modifier.fillMaxWidth().padding(top = (font * gap).dp),
        horizontalArrangement = if (mine) Arrangement.End else Arrangement.Start) {
        Text(item.translation, style = TextStyle(fontSize = font.sp, lineHeight = (font * 1.2f).sp, fontWeight = FontWeight.SemiBold),
            color = text,
            modifier = Modifier.widthIn(max = bubbleMax)
                .clip(RoundedCornerShape((font * 0.75f).dp))
                .background(color(item.surface?.background, Color.Gray))
                .padding(horizontal = (font * 0.6f).dp, vertical = (font * 0.32f).dp))
    }
}

private fun color(hex: String?, fallback: Color): Color =
    hex?.let { runCatching { Color(android.graphics.Color.parseColor(it)) }.getOrNull() } ?: fallback
