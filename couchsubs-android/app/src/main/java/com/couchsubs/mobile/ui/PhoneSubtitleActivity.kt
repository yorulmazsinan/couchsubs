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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
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
                        IconAction(Icons.Filled.Close, stringResource(R.string.close)) { finish() }
                    }
                    Column(Modifier.align(Alignment.Center).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                        val style = Tokens.Type.subtitleLandscape
                        val previous = status.recent.getOrNull(1)?.translation
                        if (previous != null && status.current.isNotEmpty() && previous != status.current) Text(previous,
                            style = style.copy(fontSize = style.fontSize * scale * 0.8f, lineHeight = style.lineHeight * scale * 0.8f),
                            color = color.copy(alpha = 0.4f), textAlign = TextAlign.Center)
                        Text(status.current.ifEmpty { if (status.running) "" else "CouchSubs" },
                            style = style.copy(fontSize = style.fontSize * scale, lineHeight = style.lineHeight * scale),
                            color = color, textAlign = TextAlign.Center)
                    }
                    Text(stringResource(R.string.subtitle_screen_note), style = Tokens.Type.caption, color = Tokens.Color.secondary,
                        modifier = Modifier.align(Alignment.BottomCenter))
                }
            }
        }
    }
}
