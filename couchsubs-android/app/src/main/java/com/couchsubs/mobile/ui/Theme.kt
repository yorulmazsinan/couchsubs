// SPDX-License-Identifier: AGPL-3.0-only
// Mobil tasarım sistemi (bento): TASARIM-MOBIL.md'deki tokenlar. Uygulama yalnız koyu temadır. Değerler yalnız buradan
// gelir; ekranlar bu dosyadaki bileşenleri kullanır.
package com.couchsubs.mobile.ui

import android.graphics.BlurMaskFilter
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Shapes
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Tokens {
    object Color {
        val bg = androidx.compose.ui.graphics.Color(0xFF141518)
        val surface = androidx.compose.ui.graphics.Color(0xFF1C1E23)
        val surface2 = androidx.compose.ui.graphics.Color(0xFF25282F)
        val border = androidx.compose.ui.graphics.Color(0x12FFFFFF)
        val borderStrong = androidx.compose.ui.graphics.Color(0xFF30333A)
        val text = androidx.compose.ui.graphics.Color(0xFFF3EEE4)
        val secondary = androidx.compose.ui.graphics.Color(0xFFA9A59C)
        val accent = androidx.compose.ui.graphics.Color(0xFFF5B83D)
        val accentHi = androidx.compose.ui.graphics.Color(0xFFFFCF6B)
        val onAccent = androidx.compose.ui.graphics.Color(0xFF17181B)
        val accentGlow = androidx.compose.ui.graphics.Color(0x73F5B83D)
        val pro = androidx.compose.ui.graphics.Color(0xFFA78BFA)
        val proGlow = androidx.compose.ui.graphics.Color(0x73A78BFA)
        val success = androidx.compose.ui.graphics.Color(0xFF62C990)
        val warning = androidx.compose.ui.graphics.Color(0xFFF2A55A)
        val danger = androidx.compose.ui.graphics.Color(0xFFF28B82)
    }

    object Space {
        val screen = 20.dp
        val gap = 12.dp
        val tile = 16.dp
        val inline = 8.dp
        val hair = 4.dp
    }

    object Radius {
        val tile = 24.dp
        val control = 16.dp
        val inner = 12.dp
    }

    object Control {
        val button = 52.dp
        val buttonSmall = 44.dp
        val icon = 44.dp
        val row = 52.dp
    }

    object Type {
        val display = TextStyle(fontSize = 32.sp, lineHeight = 38.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.4).sp)
        val title = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold)
        val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
        val body = TextStyle(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Normal)
        val caption = TextStyle(fontSize = 13.sp, lineHeight = 16.sp, fontWeight = FontWeight.Medium)
        val subtitleCurrent = TextStyle(fontSize = 28.sp, lineHeight = 36.sp, fontWeight = FontWeight.SemiBold)
        val subtitleLandscape = TextStyle(fontSize = 36.sp, lineHeight = 44.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
fun CouchSubsTheme(content: @Composable () -> Unit) {
    val c = Tokens.Color
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = c.accent, onPrimary = c.onAccent, secondary = c.pro, onSecondary = c.onAccent,
            background = c.bg, onBackground = c.text, surface = c.surface, onSurface = c.text,
            surfaceVariant = c.surface2, onSurfaceVariant = c.secondary, outline = c.borderStrong,
            error = c.danger, onError = c.onAccent, secondaryContainer = c.surface2, onSecondaryContainer = c.accent,
        ),
        typography = Typography(
            displaySmall = Tokens.Type.display, titleLarge = Tokens.Type.title, titleMedium = Tokens.Type.headline,
            bodyLarge = Tokens.Type.body, bodyMedium = Tokens.Type.body, bodySmall = Tokens.Type.caption,
            labelLarge = Tokens.Type.headline, labelMedium = Tokens.Type.caption,
        ),
        shapes = Shapes(small = RoundedCornerShape(12.dp), medium = RoundedCornerShape(16.dp), large = RoundedCornerShape(24.dp)),
        content = content,
    )
}

/** Dış parıltı (gölge katmanı); Android 9 öncesinde donanım hızlandırmada görünmeyebilir, düzen bozulmaz. */
fun Modifier.glow(color: Color, radius: Dp, corner: Dp, offsetY: Dp = 0.dp): Modifier = drawBehind {
    drawIntoCanvas { canvas ->
        val paint = Paint()
        paint.asFrameworkPaint().apply {
            this.color = android.graphics.Color.TRANSPARENT
            setShadowLayer(radius.toPx(), 0f, offsetY.toPx(), color.toArgb())
        }
        canvas.drawRoundRect(0f, 0f, size.width, size.height, corner.toPx(), corner.toPx(), paint)
    }
}

/** Her ekranın zemini: sağ üstte amber, sol altta mor hareketsiz ışık. */
@Composable
fun ScreenBackground(content: @Composable BoxScope.() -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Tokens.Color.bg).drawBehind {
            drawCircle(Brush.radialGradient(listOf(Tokens.Color.accent.copy(alpha = 0.16f), Color.Transparent),
                center = Offset(size.width * 0.85f, -size.height * 0.05f), radius = 420.dp.toPx()), radius = 420.dp.toPx(),
                center = Offset(size.width * 0.85f, -size.height * 0.05f))
            drawCircle(Brush.radialGradient(listOf(Tokens.Color.pro.copy(alpha = 0.12f), Color.Transparent),
                center = Offset(-size.width * 0.1f, size.height * 1.05f), radius = 380.dp.toPx()), radius = 380.dp.toPx(),
                center = Offset(-size.width * 0.1f, size.height * 1.05f))
        },
        content = content,
    )
}

enum class TileStyle { NORMAL, ACTIVE, PRO }

/** Bento karosu: yüzey + yukarıdan %4 beyaz degrade + ince çerçeve; etkin karo amber, Pro karo mor parıltılı. */
@Composable
fun Tile(modifier: Modifier = Modifier, style: TileStyle = TileStyle.NORMAL, onClick: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(Tokens.Radius.tile)
    val border = when (style) {
        TileStyle.NORMAL -> BorderStroke(1.dp, Tokens.Color.border)
        TileStyle.ACTIVE -> BorderStroke(1.dp, Tokens.Color.accent.copy(alpha = 0.55f))
        TileStyle.PRO -> BorderStroke(1.dp, Brush.linearGradient(listOf(Tokens.Color.pro, Tokens.Color.accent)))
    }
    val glowing = when (style) {
        TileStyle.NORMAL -> modifier
        TileStyle.ACTIVE -> modifier.glow(Tokens.Color.accent.copy(alpha = 0.35f), 28.dp, Tokens.Radius.tile)
        TileStyle.PRO -> modifier.glow(Tokens.Color.proGlow, 32.dp, Tokens.Radius.tile)
    }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Column(
        glowing.scale(if (pressed) 0.97f else 1f)
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.04f), Color.Transparent)), shape)
            .background(Tokens.Color.surface.copy(alpha = 0.92f), shape)
            .border(border, shape)
            .let { if (onClick != null) it.clickable(interactionSource = interaction, indication = null, onClick = onClick) else it }
            .padding(Tokens.Space.tile),
        verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline),
        content = content,
    )
}

/** Karo başlığı (caption, ikincil renk) ve altında büyük değer. */
@Composable
fun TileLabel(text: String, color: Color = Tokens.Color.secondary) = Text(text, style = Tokens.Type.caption, color = color)

@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) =
    FilledButton(text, modifier, enabled, Brush.verticalGradient(listOf(Tokens.Color.accentHi, Tokens.Color.accent)), Tokens.Color.accentGlow, onClick)

/** Yalnız satın almaya götüren düğme: mor→amber degrade. */
@Composable
fun ProButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) =
    FilledButton(text, modifier, enabled, Brush.horizontalGradient(listOf(Tokens.Color.pro, Tokens.Color.accent)), Tokens.Color.proGlow, onClick)

@Composable
private fun FilledButton(text: String, modifier: Modifier, enabled: Boolean, fill: Brush, glowColor: Color, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val shape = RoundedCornerShape(Tokens.Radius.control)
    Button(
        onClick, enabled = enabled, interactionSource = interaction, shape = shape, contentPadding = PaddingValues(0.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent, disabledContainerColor = Color.Transparent,
            contentColor = Tokens.Color.onAccent, disabledContentColor = Tokens.Color.onAccent.copy(alpha = 0.4f)),
        modifier = modifier.fillMaxWidth().height(Tokens.Control.button).scale(if (pressed) 0.96f else 1f)
            .let { if (enabled) it.glow(glowColor.copy(alpha = glowColor.alpha * (if (pressed) 0.5f else 1f)), 24.dp, Tokens.Radius.control) else it }
            .background(if (enabled) fill else Brush.linearGradient(listOf(Tokens.Color.accent.copy(alpha = 0.4f), Tokens.Color.accent.copy(alpha = 0.4f))), shape),
    ) { Text(text, style = Tokens.Type.headline) }
}

@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick, enabled = enabled, shape = RoundedCornerShape(Tokens.Radius.control), border = BorderStroke(1.dp, Tokens.Color.borderStrong),
        colors = ButtonDefaults.buttonColors(containerColor = Tokens.Color.surface2, contentColor = Tokens.Color.text),
        modifier = modifier.fillMaxWidth().height(Tokens.Control.button)) { Text(text, style = Tokens.Type.headline) }
}

@Composable
fun GhostButton(text: String, modifier: Modifier = Modifier, color: Color = Tokens.Color.accent, onClick: () -> Unit) {
    TextButton(onClick, modifier = modifier.height(Tokens.Control.buttonSmall)) { Text(text, style = Tokens.Type.headline, color = color) }
}

@Composable
fun DestructiveButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(onClick, shape = RoundedCornerShape(Tokens.Radius.control), border = BorderStroke(1.dp, Tokens.Color.danger),
        colors = ButtonDefaults.buttonColors(containerColor = Tokens.Color.danger.copy(alpha = 0.12f), contentColor = Tokens.Color.danger),
        modifier = modifier.fillMaxWidth().height(Tokens.Control.button)) { Text(text, style = Tokens.Type.headline) }
}

@Composable
fun IconSquare(label: String, modifier: Modifier = Modifier, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        modifier.size(Tokens.Control.icon).background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.control))
            .clickable(onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
fun Pill(text: String, color: Color = Tokens.Color.accent, modifier: Modifier = Modifier) {
    Text(text, style = Tokens.Type.caption, color = color,
        modifier = modifier.background(color.copy(alpha = 0.14f), RoundedCornerShape(999.dp)).padding(horizontal = 10.dp, vertical = 4.dp))
}

/** Canlı nokta: 8 px yeşil, 1,6 sn'de bir genişleyip sönen halka. */
@Composable
fun LiveDot(color: Color = Tokens.Color.success) {
    val transition = rememberInfiniteTransition(label = "pulse")
    val ring by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1600), RepeatMode.Restart), label = "ring")
    Canvas(Modifier.size(20.dp)) {
        drawCircle(color.copy(alpha = (1 - ring) * 0.5f), radius = (4.dp.toPx() + ring * 6.dp.toPx()))
        drawCircle(color, radius = 4.dp.toPx())
    }
}

@Composable
fun Field(
    value: String, onChange: (String) -> Unit, label: String, modifier: Modifier = Modifier,
    secret: Boolean = false, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
) {
    OutlinedTextField(
        value, onChange, modifier.fillMaxWidth(), label = { Text(label, style = Tokens.Type.caption) }, singleLine = true,
        textStyle = Tokens.Type.headline, shape = RoundedCornerShape(Tokens.Radius.control), keyboardOptions = keyboard,
        visualTransformation = if (secret) androidx.compose.ui.text.input.PasswordVisualTransformation() else VisualTransformation.None,
        colors = OutlinedTextFieldDefaults.colors(
            focusedContainerColor = Tokens.Color.surface2, unfocusedContainerColor = Tokens.Color.surface2,
            focusedBorderColor = Tokens.Color.accent, unfocusedBorderColor = Tokens.Color.borderStrong, cursorColor = Tokens.Color.accent,
        ),
    )
}

/**
 * Ekran iskeleti: güvenli alan + 20 kenar, isteğe bağlı başlık satırı (display), kaydırılan içerik ve altta sabit
 * düğme bölgesi (birincil en altta).
 */
@Composable
fun ScreenScaffold(
    top: (@Composable () -> Unit)? = null,
    bottom: (@Composable ColumnScope.() -> Unit)? = null,
    scroll: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    ScreenBackground {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(Tokens.Space.screen)) {
            if (top != null) {
                top()
                Spacer(Modifier.height(Tokens.Space.gap))
            }
            val state = rememberScrollState()
            Column(
                Modifier.weight(1f).fillMaxWidth().let { if (scroll) it.verticalScroll(state) else it },
                verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap),
                content = content,
            )
            if (bottom != null) {
                Spacer(Modifier.height(Tokens.Space.gap))
                Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap), horizontalAlignment = Alignment.CenterHorizontally, content = bottom)
            }
        }
    }
}

@Composable
fun BodyText(text: String, color: Color = Tokens.Color.secondary, align: TextAlign? = null) =
    Text(text, style = Tokens.Type.body, color = color, textAlign = align)

/** Geniş karonun içindeki 52 yükseklikli satır (ayarlar, profil). */
@Composable
fun RowItem(title: String, value: String? = null, onClick: (() -> Unit)? = null, trailing: (@Composable () -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().height(Tokens.Control.row).let { if (onClick != null) it.clickable(onClick = onClick) else it },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Tokens.Type.headline, color = Tokens.Color.text)
            value?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
        }
        trailing?.invoke()
    }
}

