// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * design/tokens.json'daki renk, yazı ve boşluk değerleri (Mac ve Windows'la aynı). Ekranlar onaylanan tasarıma göre
 * yeniden yapılacak; değerler yalnız buradan gelir.
 */
object Tokens {
    object Dark {
        val background = Color(0xFF141518)
        val surface = Color(0xFF1E2024)
        val border = Color(0xFF30333A)
        val textPrimary = Color(0xFFF3EEE4)
        val textSecondary = Color(0xFFA9A59C)
        val accent = Color(0xFFF5B83D)
        val onAccent = Color(0xFF17181B)
        val accentText = Color(0xFFF5B83D)
        val accentSoft = Color(0xFF3A3020)
        val success = Color(0xFF62C990)
        val warning = Color(0xFFF2A55A)
        val danger = Color(0xFFF28B82)
        val onDanger = Color(0xFF17181B)
    }

    object Light {
        val background = Color(0xFFF6F4EF)
        val surface = Color(0xFFFFFFFF)
        val border = Color(0xFFE2DED4)
        val textPrimary = Color(0xFF17181B)
        val textSecondary = Color(0xFF5B5954)
        val accent = Color(0xFFF5B83D)
        val onAccent = Color(0xFF17181B)
        val accentText = Color(0xFF7E5300)
        val accentSoft = Color(0xFFFBEBC8)
        val success = Color(0xFF256B43)
        val warning = Color(0xFF9A4A08)
        val danger = Color(0xFFB3261E)
        val onDanger = Color(0xFFFFFFFF)
    }

    object Space {
        val xs = 4.dp
        val s = 8.dp
        val m = 12.dp
        val l = 16.dp
        val xl = 24.dp
        val xxl = 32.dp
    }

    object Radius {
        val control = 10.dp
        val card = 14.dp
    }

    object Size {
        val buttonHeight = 44.dp
        val primaryActionHeight = 52.dp
        val statusDot = 10.dp
    }
}

private val typography = Typography(
    displaySmall = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.SemiBold),
    titleLarge = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
    titleMedium = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
    bodyLarge = TextStyle(fontSize = 15.sp, lineHeight = 20.sp),
    bodyMedium = TextStyle(fontSize = 14.sp, lineHeight = 18.sp),
    bodySmall = TextStyle(fontSize = 12.sp),
    labelLarge = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
)

@Composable
fun CouchSubsTheme(content: @Composable () -> Unit) {
    val scheme = if (isSystemInDarkTheme()) darkColorScheme(
        primary = Tokens.Dark.accent, onPrimary = Tokens.Dark.onAccent,
        background = Tokens.Dark.background, onBackground = Tokens.Dark.textPrimary,
        surface = Tokens.Dark.surface, onSurface = Tokens.Dark.textPrimary,
        surfaceVariant = Tokens.Dark.surface, onSurfaceVariant = Tokens.Dark.textSecondary,
        outline = Tokens.Dark.border, error = Tokens.Dark.danger, onError = Tokens.Dark.onDanger,
        secondaryContainer = Tokens.Dark.accentSoft, onSecondaryContainer = Tokens.Dark.accentText,
    ) else lightColorScheme(
        primary = Tokens.Light.accent, onPrimary = Tokens.Light.onAccent,
        background = Tokens.Light.background, onBackground = Tokens.Light.textPrimary,
        surface = Tokens.Light.surface, onSurface = Tokens.Light.textPrimary,
        surfaceVariant = Tokens.Light.surface, onSurfaceVariant = Tokens.Light.textSecondary,
        outline = Tokens.Light.border, error = Tokens.Light.danger, onError = Tokens.Light.onDanger,
        secondaryContainer = Tokens.Light.accentSoft, onSecondaryContainer = Tokens.Light.accentText,
    )
    MaterialTheme(colorScheme = scheme, typography = typography, content = content)
}
