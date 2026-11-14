// SPDX-License-Identifier: AGPL-3.0-only
// Mobil tasarım sistemi (düz bento): design/tokens.json v3 ve TASARIM-MOBIL.md. Uygulama yalnız koyu temadır.
// Değerler yalnız buradan gelir; ekranlar bu dosyadaki bileşenleri kullanır. Parıltı, degrade ve renkli gölge yoktur.
package com.couchsubs.mobile.ui

import android.provider.Settings
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
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Tokens {
    /** design/tokens.json v3, koyu görünüm. Parıltı rengi yoktur. */
    object Color {
        val bg = androidx.compose.ui.graphics.Color(0xFF141518)
        val surface = androidx.compose.ui.graphics.Color(0xFF1C1E23)
        val surface2 = androidx.compose.ui.graphics.Color(0xFF25282F)
        /** Seçili segment gibi yükseltilmiş parça (surface2'nin bir basamak üstü). */
        val raised = androidx.compose.ui.graphics.Color(0xFF30333A)
        /** Karo çerçevesi (tokens.json tileBorder). */
        val border = androidx.compose.ui.graphics.Color(0xFF2C2E32)
        /** Alan çerçevesi ve ayraçlar (tokens.json border). */
        val borderStrong = androidx.compose.ui.graphics.Color(0xFF30333A)
        val text = androidx.compose.ui.graphics.Color(0xFFF3EEE4)
        val secondary = androidx.compose.ui.graphics.Color(0xFFA9A59C)
        /** Yalnız dolgu (birincil düğme, seçili şey, ilerleme); sarı yazı ve simge için [accentText]. */
        val accent = androidx.compose.ui.graphics.Color(0xFFF5B83D)
        val accentHi = androidx.compose.ui.graphics.Color(0xFFFFCF6B)
        val accentText = androidx.compose.ui.graphics.Color(0xFFF5B83D)
        val onAccent = androidx.compose.ui.graphics.Color(0xFF17181B)
        /** Yalnız oyun paketleri: düz mor simge ve yazı; [proSoft] paket etiketinin zemini. */
        val pro = androidx.compose.ui.graphics.Color(0xFFA78BFA)
        val proSoft = androidx.compose.ui.graphics.Color(0xFF322F45)
        val success = androidx.compose.ui.graphics.Color(0xFF62C990)
        val warning = androidx.compose.ui.graphics.Color(0xFFF2A55A)
        val danger = androidx.compose.ui.graphics.Color(0xFFF28B82)
        val dangerSoft = androidx.compose.ui.graphics.Color(0xFF2F2325)
    }

    /** Telefon ölçüleri (TASARIM-MOBIL.md): kenar 20, karolar arası 12, karo içi 16. */
    object Space {
        val screen = 20.dp
        val gap = 12.dp
        val tile = 16.dp
        val inline = 8.dp
        val hair = 4.dp
    }

    /** Tek köşe ölçeği: karo 16, denetim 12, karo içi kutu 8, etiket 6. */
    object Radius {
        val tile = 16.dp
        val control = 12.dp
        val inner = 8.dp
        val tag = 6.dp
    }

    object Control {
        val button = 52.dp
        val buttonSmall = 44.dp
        val icon = 44.dp
        val row = 52.dp
        val tag = 24.dp
        val tileIcon = 18.dp
        val statusDot = 8.dp
    }

    /** Beş boy (28/22/17/15/13), kalınlık 400–600; altyazı içeriği (subtitle*) dışında başka boy yok. */
    object Type {
        val display = TextStyle(fontSize = 28.sp, lineHeight = 34.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp)
        val title = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold)
        val headline = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.SemiBold)
        /** Önceki altyazı satırları: headline boyu, normal kalınlık. */
        val line = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, fontWeight = FontWeight.Normal)
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
            error = c.danger, onError = c.onAccent, secondaryContainer = c.surface2, onSecondaryContainer = c.text,
        ),
        typography = Typography(
            displaySmall = Tokens.Type.display, titleLarge = Tokens.Type.title, titleMedium = Tokens.Type.headline,
            bodyLarge = Tokens.Type.body, bodyMedium = Tokens.Type.body, bodySmall = Tokens.Type.caption,
            labelLarge = Tokens.Type.headline, labelMedium = Tokens.Type.caption,
        ),
        shapes = Shapes(
            extraSmall = RoundedCornerShape(Tokens.Radius.tag), small = RoundedCornerShape(Tokens.Radius.inner),
            medium = RoundedCornerShape(Tokens.Radius.control), large = RoundedCornerShape(Tokens.Radius.tile),
            extraLarge = RoundedCornerShape(Tokens.Radius.tile),
        ),
        content = content,
    )
}

/** Her ekranın zemini: düz `bg` (ışık, degrade ve parıltı yok). */
@Composable
fun ScreenBackground(content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(Tokens.Color.bg), content = content)
}

enum class TileStyle { NORMAL, ACTIVE }

/** Karo: düz yüzey ve 1 px çerçeve; etkin (seçili) karo 1 px sarı çerçeveyle belli olur, parlamaz. */
@Composable
fun Tile(modifier: Modifier = Modifier, style: TileStyle = TileStyle.NORMAL, onClick: (() -> Unit)? = null, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(Tokens.Radius.tile)
    val border = if (style == TileStyle.ACTIVE) Tokens.Color.accent else Tokens.Color.border
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Column(
        modifier.scale(if (pressed) 0.97f else 1f)
            .background(Tokens.Color.surface, shape)
            .border(1.dp, border, shape)
            .let { if (onClick != null) it.clickable(interactionSource = interaction, indication = null, onClick = onClick) else it }
            .padding(Tokens.Space.tile),
        verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline),
        content = content,
    )
}

/** Karo başlığı (caption, ikincil renk). */
@Composable
fun TileLabel(text: String, color: Color = Tokens.Color.secondary) = Text(text, style = Tokens.Type.caption, color = color)

/** Birincil düğme: düz sarı, gölgesiz; basılıyken accentHi ve %97 ölçek, devre dışıyken %40 saydam. Ekranda bir tane. */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Button(
        onClick, enabled = enabled, interactionSource = interaction, shape = RoundedCornerShape(Tokens.Radius.control), elevation = null,
        colors = ButtonDefaults.buttonColors(containerColor = if (pressed) Tokens.Color.accentHi else Tokens.Color.accent,
            contentColor = Tokens.Color.onAccent, disabledContainerColor = Tokens.Color.accent.copy(alpha = 0.4f),
            disabledContentColor = Tokens.Color.onAccent.copy(alpha = 0.4f)),
        modifier = modifier.fillMaxWidth().height(Tokens.Control.button).scale(if (pressed) 0.97f else 1f),
    ) { Text(text, style = Tokens.Type.headline) }
}

@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick, enabled = enabled, shape = RoundedCornerShape(Tokens.Radius.control), border = BorderStroke(1.dp, Tokens.Color.borderStrong),
        colors = ButtonDefaults.buttonColors(containerColor = Tokens.Color.surface2, contentColor = Tokens.Color.text), elevation = null,
        modifier = modifier.fillMaxWidth().height(Tokens.Control.button)) { Text(text, style = Tokens.Type.headline) }
}

@Composable
fun GhostButton(text: String, modifier: Modifier = Modifier, color: Color = Tokens.Color.accentText, onClick: () -> Unit) {
    TextButton(onClick, modifier = modifier.height(Tokens.Control.buttonSmall)) { Text(text, style = Tokens.Type.headline, color = color) }
}

/** Tehlikeli: kırmızı tonlu zemin, kırmızı yazı, çerçevesiz ("Çeviriyi durdur"). */
@Composable
fun DestructiveButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(onClick, shape = RoundedCornerShape(Tokens.Radius.control), elevation = null,
        colors = ButtonDefaults.buttonColors(containerColor = Tokens.Color.dangerSoft, contentColor = Tokens.Color.danger),
        modifier = modifier.fillMaxWidth().height(Tokens.Control.button)) { Text(text, style = Tokens.Type.headline) }
}

@Composable
fun IconSquare(label: String, modifier: Modifier = Modifier, onClick: () -> Unit, content: @Composable () -> Unit) {
    Box(
        modifier.size(Tokens.Control.icon).background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.control))
            .border(1.dp, Tokens.Color.border, RoundedCornerShape(Tokens.Radius.control))
            .clickable(onClickLabel = label, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** Etiket: 24 yükseklik, 6 köşe, caption; nötr (surface2 + ikincil yazı) ya da oyun paketi için mor ([pro]). */
@Composable
fun Pill(text: String, modifier: Modifier = Modifier, pro: Boolean = false) {
    Box(
        modifier.height(Tokens.Control.tag)
            .background(if (pro) Tokens.Color.proSoft else Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.tag))
            .padding(horizontal = Tokens.Space.inline),
        contentAlignment = Alignment.Center,
    ) { Text(text, style = Tokens.Type.caption, color = if (pro) Tokens.Color.pro else Tokens.Color.secondary, maxLines = 1) }
}

/** Sistemde "animasyonları kapat" (azaltılmış hareket) açık mı. */
@Composable
fun reducedMotion(): Boolean {
    val context = LocalContext.current
    return remember { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }
}

/**
 * Durum noktası (8 dp). Yalnız [live] (çeviri canlı) iken 2 sn'de bir genişleyip sönen halka atar; "Bağlı", "Hazır"
 * gibi durumlarda ve azaltılmış harekette durur.
 */
@Composable
fun LiveDot(color: Color = Tokens.Color.success, live: Boolean = false) {
    val animate = live && !reducedMotion()
    Box(Modifier.size(Tokens.Control.statusDot * 2), contentAlignment = Alignment.Center) {
        if (animate) {
            val transition = rememberInfiniteTransition(label = "pulse")
            val ring by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(2000), RepeatMode.Restart), label = "ring")
            Canvas(Modifier.fillMaxSize()) {
                drawCircle(color.copy(alpha = (1 - ring) * 0.7f), radius = size.minDimension / 2 * (0.5f + ring * 0.5f), style = Stroke(2.dp.toPx()))
            }
        }
        Box(Modifier.size(Tokens.Control.statusDot).background(color, CircleShape))
    }
}

/** Durum: nokta + kelime, zeminsiz ("Bağlı", "Çeviri sürüyor · 4:10"). Canlı durum etiket değildir. */
@Composable
fun StatusLabel(text: String, ok: Boolean = true, live: Boolean = false) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
        LiveDot(if (ok) Tokens.Color.success else Tokens.Color.secondary, live = live)
        Text(text, style = Tokens.Type.caption, color = Tokens.Color.text, maxLines = 1)
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
            focusedLabelColor = Tokens.Color.secondary, unfocusedLabelColor = Tokens.Color.secondary,
        ),
    )
}

/**
 * Ekran iskeleti: güvenli alan + 20 kenar, isteğe bağlı başlık satırı, kaydırılan içerik ve altta sabit düğme bölgesi
 * (birincil en altta).
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
        Modifier.fillMaxWidth().heightIn(min = Tokens.Control.row).let { if (onClick != null) it.clickable(onClick = onClick) else it }
            .padding(vertical = Tokens.Space.hair),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap),
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
            Text(title, style = Tokens.Type.headline, color = Tokens.Color.text)
            value?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
        }
        trailing?.invoke()
    }
}
