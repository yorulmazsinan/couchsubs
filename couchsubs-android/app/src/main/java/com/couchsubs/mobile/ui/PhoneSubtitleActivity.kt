// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import com.couchsubs.mobile.core.SubtitleTextColor
import com.couchsubs.mobile.service.LiveState
import com.couchsubs.mobile.settings.AppSettings

/** Altyazı bu telefonun ekranında: yatay, siyah zeminde büyük yazı (TV yerine telefonu TV'nin önüne koyanlar için). */
class PhoneSubtitleActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val settings = AppSettings(this)
        if (settings.keepScreenOn) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val color = if (settings.textColor == SubtitleTextColor.YELLOW) Tokens.Dark.accent else Color.White
        val size = settings.phoneTextSize
        setContent {
            val status by LiveState.status.collectAsState()
            Box(Modifier.fillMaxSize().background(Color.Black).padding(Tokens.Space.xxl), contentAlignment = Alignment.Center) {
                Text(
                    text = status.current.ifEmpty { if (status.running) "" else "CouchSubs" },
                    color = color, fontSize = size.sp, lineHeight = (size * 1.25).sp, fontWeight = FontWeight.SemiBold,
                    textAlign = TextAlign.Center,
                )
                if (status.current.isEmpty() && status.running)
                    Text(status.phase, color = Tokens.Dark.textSecondary, modifier = Modifier.align(Alignment.BottomCenter))
            }
        }
    }
}
