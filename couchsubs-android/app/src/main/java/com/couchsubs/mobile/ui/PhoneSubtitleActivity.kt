// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import com.couchsubs.mobile.core.PhoneSubtitleLayout
import com.couchsubs.mobile.core.SpeakerColors
import com.couchsubs.mobile.core.SubtitleWrap
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import kotlin.math.roundToInt
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.widthIn
import androidx.compose.ui.unit.dp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.ui.unit.sp
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.service.TranslationService
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.service.LiveState

/**
 * Altyazı bu telefonun ekranında (tuval Telefon-Altyazi): yatay, siyah zeminde büyük yazı; üstte durum hapı ve kapat.
 * Ekran açık kalır, parlaklığa dokunulmaz (eskiden 10 saniye sonra kısılıyordu, ekran karanlık kalıyordu: #559).
 * "Ekranı döndür" yatayla dik arasında geçer (iPhone ile aynı).
 */
class PhoneSubtitleActivity : ComponentActivity() {
    companion object {
        /** Bölünmüş [display] metni; [enabled] ise konuşanların parçaları kendi renginde ([source]: bölünmemiş metin). */
        fun speakerText(display: String, source: String, enabled: Boolean): AnnotatedString {
            val segments = if (enabled) SpeakerColors.segments(display, source) else emptyList()
            if (segments.none { it.color != null }) return AnnotatedString(display)
            return buildAnnotatedString {
                append(display)
                segments.forEach { segment ->
                    val hex = segment.color ?: return@forEach
                    addStyle(SpanStyle(color = Color(android.graphics.Color.parseColor(hex))), segment.start, segment.end)
                }
            }
        }


        /** "Ekranı döndür": yataysa dike, değilse yataya (sensör yönüne göre iki yan da olur). */
        fun nextOrientation(current: Int): Int =
            if (current == ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            else ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Uygulama hep koyu; sistem açık temadayken de durum çubuğu simgeleri açık renk kalsın.
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        super.onCreate(savedInstanceState)
        val settings = Services.settings
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val color = if (settings.textColor == SubtitleTextColor.YELLOW) Tokens.Color.accentText else Tokens.Color.text
        val scale = settings.subtitleScale / 100f
        // "Hızlı konuşmada önceki satırları üstte tut" kapalıysa soluk önceki satır gösterilmez (TV ve Windows ile aynı).
        val stackPrevious = settings.stackPrevious
        // "Konuşana göre renk": konuşan adlı satır o konuşanın renginde (TV ile aynı palet; bkz. SpeakerColors).
        val speakerColors = settings.speakerColors
        val setApart = settings.setTextApart
        setContent {
            CouchSubsTheme {
                val status by LiveState.status.collectAsState()
                // "Arka planda sürdür": çeviri sürerken bu ekrandan çıkınca küçük pencere (iPhone ile aynı).
                LaunchedEffect(status.running) { BackgroundPip.update(this@PhoneSubtitleActivity, BackgroundPip.wanted(this@PhoneSubtitleActivity, status)) }
                if (inPip) {
                    PipSubtitleView(status)
                    return@CouchSubsTheme
                }
                // Parmakla yukarı-aşağı taşıma ve iki parmakla yazı boyu: kalıcı, TV'ye dokunmaz (iPhone ile aynı sınırlar).
                var phoneScale by remember { mutableFloatStateOf(settings.phoneSubtitleScale) }
                var phoneOffset by remember { mutableFloatStateOf(settings.phoneSubtitleOffset) }
                var areaHeight by remember { mutableIntStateOf(0) }
                Box(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding().padding(Tokens.Space.screen)
                    .onSizeChanged { areaHeight = it.height }
                    .pointerInput(Unit) {
                        detectTransformGestures { _, pan, zoom, _ ->
                            phoneOffset = PhoneSubtitleLayout.offset(phoneOffset, pan.y, size.height.toFloat())
                            phoneScale = PhoneSubtitleLayout.scale(phoneScale, zoom)
                            settings.phoneSubtitleOffset = phoneOffset
                            settings.phoneSubtitleScale = phoneScale
                        }
                    }) {
                    Row(Modifier.fillMaxWidth().align(Alignment.TopCenter), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        val connected = status.running && status.streaming
                        StatusLabel(stringResource(if (connected) R.string.subtitle_connected else R.string.subtitle_waiting), ok = connected, live = connected)
                        status.packInUse?.let { Pill(stringResource(R.string.running_pack, it), pro = true) }
                        // Bağlantı gidince bu ekrandan da yeniden bağlanılır (iPhone altyazı ekranı ve ana ekranla aynı
                        // kural: ReconnectOffer).
                        var now by remember { mutableStateOf(System.currentTimeMillis()) }
                        LaunchedEffect(Unit) {
                            while (true) {
                                kotlinx.coroutines.delay(1000)
                                now = System.currentTimeMillis()
                            }
                        }
                        if (status.running && !status.demo && !status.streaming &&
                            com.couchsubs.mobile.remoteplay.ReconnectOffer.shows(status.notLiveSince, status.gaveUp, now))
                            GhostButton(stringResource(R.string.reconnect)) { TranslationService.reconnect() }
                        Spacer(Modifier.weight(1f))
                        IconAction(Icons.Filled.Refresh, stringResource(R.string.screen_rotate)) {
                            requestedOrientation = nextOrientation(requestedOrientation)
                        }
                        if (connected) IconAction(
                            if (status.screenState == LiveStatus.ScreenState.IDLE) Icons.Filled.Search else Icons.Filled.Delete,
                            stringResource(if (status.screenState == LiveStatus.ScreenState.IDLE) R.string.screen_translate else R.string.screen_remove),
                        ) { TranslationService.translateScreen() }
                        IconAction(Icons.Filled.Close, stringResource(R.string.close)) { finish() }
                    }
                    Column(Modifier.align(Alignment.Center).fillMaxWidth()
                        .offset { androidx.compose.ui.unit.IntOffset(0, (phoneOffset * areaHeight).roundToInt()) },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        val style = Tokens.Type.subtitleLandscape
                        val scale = scale * phoneScale
                        val previous = status.previous
                        // Uzun çeviri en çok 3 satıra dengeli bölünür; sığmazsa yazı biraz küçülür (bkz. SubtitleWrap).
                        if (stackPrevious && previous.isNotEmpty() && status.current.isNotEmpty() && previous != status.current) {
                            val wrapped = SubtitleWrap.fit(previous)
                            Text(speakerText(wrapped.text, previous, speakerColors),
                                style = style.copy(fontSize = style.fontSize * scale * 0.8f * wrapped.scale, lineHeight = style.lineHeight * scale * 0.8f * wrapped.scale),
                                color = color.copy(alpha = 0.4f), textAlign = TextAlign.Center)
                        }
                        val currentText = status.current.ifEmpty { if (status.running) "" else "CouchSubs" }
                        val current = SubtitleWrap.fit(currentText)
                        Text(speakerText(current.text, currentText, speakerColors),
                            style = style.copy(fontSize = style.fontSize * scale * current.scale, lineHeight = style.lineHeight * scale * current.scale),
                            color = color, textAlign = TextAlign.Center)
                    }
                    Column(Modifier.align(Alignment.BottomCenter), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(stringResource(R.string.subtitle_screen_gesture_hint), style = Tokens.Type.caption, color = Tokens.Color.secondary,
                            textAlign = TextAlign.Center)
                        Text(stringResource(R.string.subtitle_screen_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                    }
                    // "Ekranı çevir" sonuçları: her çeviri kendi yazısının yerinde, aynı boyda ve özgün yazının stilinde
                    // (TV'deki gibi); GTA 6 telefonunun yazıları yanında mesaj kartı olarak gelir.
                    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
                        status.screen.forEach { item ->
                            if (item.surface != null) {
                                StyledBlock(item, maxWidth, maxHeight, fill = com.couchsubs.mobile.core.ScreenPhoneCard.isBackdrop(item))
                                return@forEach
                            }
                            val box = item.box
                            val width = maxOf(60.dp, maxWidth * (box.right - box.left).toFloat())
                            val size = (maxHeight.value * item.lineHeight * 0.8).coerceIn(10.0, 28.0).toFloat()
                            Text(item.translation, style = Tokens.Type.caption.copy(fontSize = size.sp, lineHeight = (size * 1.2f).sp),
                                color = Tokens.Color.text, textAlign = TextAlign.Start,
                                modifier = Modifier
                                    .offset(x = maxWidth * box.left.toFloat(), y = maxHeight * ((box.top + box.bottom) / 2).toFloat() - (size * 0.8f).dp)
                                    .width(width)
                                    .background(Color.Black.copy(alpha = 0.85f), androidx.compose.foundation.shape.RoundedCornerShape(4.dp))
                                    .padding(4.dp))
                        }
                    }
                    // Ek alanların (görev, telefon, bildirim) çevirisi oyundaki yerinde küçük kutuda (TV ve iPhone'daki gibi).
                    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
                        status.regions.forEach { region ->
                            // Ekran yazısı blokları özgün yerinde ve stilinde (zemin, yazı rengi, kalınlık, hizalama; TV'deki gibi).
                            // "Ekranı çevir" ekrandayken onun yazılarının yerindeki bloklar çizilmez (#827).
                            val styled = region.blocks?.filter { it.surface != null }
                                ?.let { com.couchsubs.mobile.core.ScreenTranslation.uncovered(it, status.screen) }
                            if (region.blocks?.any { it.surface != null } == true && styled.isNullOrEmpty()) return@forEach
                            if (!styled.isNullOrEmpty()) {
                                styled.forEach { item -> StyledBlock(item, maxWidth, maxHeight) }
                                return@forEach
                            }
                            val box = region.box ?: com.couchsubs.mobile.core.TextBox(0.6, 0.05, 0.95, 0.2)
                            // "Ekran yazılarını altyazıdan ayır": stili bilinmeyen kutu altyazı kutusuna benzemesin
                            // (zeminsiz, beyaz, koyu gölgeli; Mac ile aynı). Altyazının yeri hiç değişmez.
                            Text(region.text,
                                style = if (setApart) Tokens.Type.caption.copy(shadow = androidx.compose.ui.graphics.Shadow(Color.Black, blurRadius = 6f))
                                    else Tokens.Type.caption,
                                color = if (setApart) Color.White else Tokens.Color.text,
                                modifier = Modifier
                                    .offset(x = maxWidth * box.left.toFloat(), y = maxHeight * box.top.toFloat())
                                    .widthIn(min = 120.dp, max = maxOf(120.dp, maxWidth * (box.right - box.left).toFloat()))
                                    .then(if (setApart) Modifier else Modifier.background(Color.Black.copy(alpha = 0.8f),
                                        androidx.compose.foundation.shape.RoundedCornerShape(6.dp)))
                                    .padding(6.dp))
                        }
                    }
                }
                // TV'nin eşleştirme isteği tam ekran altyazıdayken de görünür (onay penceresi ve üstte onay satırı).
                TvPairingPrompt(status.pairing)
            }
        }
    }

    /** Küçük pencerede (Resim içinde resim) mi; içerik buna göre çizilir. */
    private var inPip by mutableStateOf(false)

    override fun onResume() {
        super.onResume()
        TranslationService.syncPairing()
    }

    /** Android 11 ve öncesi: ana ekrana dönülürken küçük pencere burada açılır. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        BackgroundPip.onUserLeave(this, BackgroundPip.wanted(this, LiveState.status.value))
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
    }
}

/**
 * Otomatik ekran yazısının bir bloğu, özgün yazının yerinde ve stilinde: zemin rengi (her zeminde tam opak; özgün yazı
 * arasından görünmez, #827), yazı rengi, kalınlık, dar aile, hizalama. Yazı boyu özgün satır yüksekliğinden; Türkçe uzunsa en çok %40
 * küçülür (TV ile aynı kural).
 */
@androidx.compose.runtime.Composable
private fun StyledBlock(
    item: com.couchsubs.mobile.core.ScreenTranslation.Item, width: androidx.compose.ui.unit.Dp, height: androidx.compose.ui.unit.Dp,
    /** Kutu özgün yüksekliğinde dolu (telefon kartının zemini). */
    fill: Boolean = false,
) {
    val surface = item.surface ?: return
    val look = item.look
    fun color(hex: String, alpha: Float = 1f) = runCatching { Color(android.graphics.Color.parseColor(hex)).copy(alpha = alpha) }.getOrDefault(Color.Black)
    val box = item.box
    val boxWidth = width * (box.right - box.left).toFloat()
    val line = (height.value * item.lineHeight * 0.8).coerceIn(8.0, 40.0).toFloat()
    val longest = item.translation.split('\n').maxOfOrNull { it.length } ?: 1
    val original = item.source.split('\n').maxOfOrNull { it.length } ?: 1
    val shrink = (original.toFloat() / longest).coerceIn(0.6f, 1f)
    Text(item.translation,
        style = Tokens.Type.caption.copy(
            fontSize = (line * shrink).sp, lineHeight = (line * shrink * 1.15f).sp,
            fontWeight = if (look?.bold == true) androidx.compose.ui.text.font.FontWeight.Bold else androidx.compose.ui.text.font.FontWeight.Normal,
            fontFamily = if (look?.condensed == true) androidx.compose.ui.text.font.FontFamily(android.graphics.Typeface.create("sans-serif-condensed", android.graphics.Typeface.NORMAL)) else null,
        ),
        color = color(surface.foreground),
        textAlign = when (look?.align) { "right" -> TextAlign.End; "center" -> TextAlign.Center; else -> TextAlign.Start },
        modifier = Modifier
            .offset(x = width * box.left.toFloat(), y = height * box.top.toFloat())
            .width(boxWidth)
            .then(if (fill) Modifier.height(height * (box.bottom - box.top).toFloat()) else Modifier)
            .background(color(surface.background))
            .padding(horizontal = 2.dp))
}
