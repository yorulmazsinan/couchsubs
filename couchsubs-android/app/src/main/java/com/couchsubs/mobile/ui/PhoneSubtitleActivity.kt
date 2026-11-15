// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

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
import androidx.compose.material.icons.filled.Search
import androidx.compose.foundation.layout.width
import androidx.compose.ui.unit.sp
import com.couchsubs.mobile.service.LiveStatus
import com.couchsubs.mobile.service.TranslationService
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.service.LiveState
import kotlinx.coroutines.delay

/**
 * Altyazı bu telefonun ekranında (tuval Telefon-Altyazi): yatay, siyah zeminde büyük yazı; üstte durum hapı ve kapat.
 * Ekran açık kalır; bir süre sonra parlaklık kısılır (oyun çoğunlukla karanlık odada oynanır).
 */
class PhoneSubtitleActivity : ComponentActivity() {
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
        val streaming = getString(R.string.phase_streaming)
        setContent {
            CouchSubsTheme {
                val status by LiveState.status.collectAsState()
                LaunchedEffect(Unit) {
                    delay(10_000)
                    window.attributes = window.attributes.apply { screenBrightness = 0.35f }
                }
                Box(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding().padding(Tokens.Space.screen)) {
                    Row(Modifier.fillMaxWidth().align(Alignment.TopCenter), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        val connected = status.running && status.phase == streaming
                        StatusLabel(stringResource(if (connected) R.string.subtitle_connected else R.string.subtitle_waiting), ok = connected, live = connected)
                        status.packInUse?.let { Pill(stringResource(R.string.running_pack, it), pro = true) }
                        Spacer(Modifier.weight(1f))
                        if (connected) IconAction(
                            if (status.screenState == LiveStatus.ScreenState.IDLE) Icons.Filled.Search else Icons.Filled.Delete,
                            stringResource(if (status.screenState == LiveStatus.ScreenState.IDLE) R.string.screen_translate else R.string.screen_remove),
                        ) { TranslationService.translateScreen() }
                        IconAction(Icons.Filled.Close, stringResource(R.string.close)) { finish() }
                    }
                    Column(Modifier.align(Alignment.Center).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        val style = Tokens.Type.subtitleLandscape
                        val previous = status.previous
                        if (stackPrevious && previous.isNotEmpty() && status.current.isNotEmpty() && previous != status.current) Text(previous,
                            style = style.copy(fontSize = style.fontSize * scale * 0.8f, lineHeight = style.lineHeight * scale * 0.8f),
                            color = color.copy(alpha = 0.4f), textAlign = TextAlign.Center)
                        Text(status.current.ifEmpty { if (status.running) "" else "CouchSubs" },
                            style = style.copy(fontSize = style.fontSize * scale, lineHeight = style.lineHeight * scale),
                            color = color, textAlign = TextAlign.Center)
                    }
                    Text(stringResource(R.string.subtitle_screen_note), style = Tokens.Type.caption, color = Tokens.Color.secondary,
                        modifier = Modifier.align(Alignment.BottomCenter))
                    // "Ekranı çevir" sonuçları: her çeviri kendi yazısının yerinde ve aynı boyda (TV'deki gibi).
                    androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
                        status.screen.forEach { item ->
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
                            val box = region.box ?: com.couchsubs.mobile.core.TextBox(0.6, 0.05, 0.95, 0.2)
                            Text(region.text, style = Tokens.Type.caption, color = Tokens.Color.text,
                                modifier = Modifier
                                    .offset(x = maxWidth * box.left.toFloat(), y = maxHeight * box.top.toFloat())
                                    .widthIn(min = 120.dp, max = maxOf(120.dp, maxWidth * (box.right - box.left).toFloat()))
                                    .background(Color.Black.copy(alpha = 0.8f), androidx.compose.foundation.shape.RoundedCornerShape(6.dp))
                                    .padding(6.dp))
                        }
                    }
                }
            }
        }
    }
}
