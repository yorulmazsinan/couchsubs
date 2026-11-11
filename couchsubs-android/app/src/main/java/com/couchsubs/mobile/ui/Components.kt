// SPDX-License-Identifier: AGPL-3.0-only
// Tuvaldeki (design-canvas, Telefon-*) tekrar eden parçalar: başlık satırı, ikonlu kare karo, segmentli seçim, kod
// haneleri, satır listesi.
package com.couchsubs.mobile.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.R

/** Logo (36), isteğe bağlı başlık ve sağda simge düğmeleri; 44 yükseklik. */
@Composable
fun TopBar(title: String? = null, onBack: (() -> Unit)? = null, onClose: (() -> Unit)? = null, actions: @Composable RowScope.() -> Unit = {}) {
    Row(Modifier.fillMaxWidth().height(Tokens.Control.icon), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
        when {
            onBack != null -> IconAction(Icons.AutoMirrored.Filled.ArrowBack, stringResource(R.string.back), onBack)
            else -> Image(painterResource(R.mipmap.icon), null, Modifier.size(36.dp))
        }
        if (title != null) Text(title, style = Tokens.Type.headline, color = Tokens.Color.text, modifier = Modifier.weight(1f))
        else Spacer(Modifier.weight(1f))
        actions()
        if (onClose != null) IconAction(Icons.Filled.Close, stringResource(R.string.close), onClose)
    }
}

@Composable
fun IconAction(icon: ImageVector, label: String, onClick: () -> Unit) =
    IconSquare(label, onClick = onClick) { Icon(icon, label, tint = Tokens.Color.text, modifier = Modifier.size(20.dp)) }

@Composable
fun SettingsAction(onClick: () -> Unit) = IconAction(Icons.Filled.Settings, stringResource(R.string.settings), onClick)

/** Profil (cihazlar ve tercihler) simge düğmesi. */
@Composable
fun ProfileAction(onClick: () -> Unit) = IconAction(Icons.Filled.Person, stringResource(R.string.profile), onClick)

/** Ekran başlığı (display) ve altında açıklama; üstte isteğe bağlı "Kurulum · Adım 1/3". */
@Composable
fun Heading(title: String, body: String? = null, step: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
        step?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.accent) }
        Text(title, style = Tokens.Type.display, color = Tokens.Color.text)
        body?.let { Text(it, style = Tokens.Type.body, color = Tokens.Color.secondary) }
    }
}

/** Renkli zeminli küçük simge rozeti (karoların sol üstü). */
@Composable
fun IconBadge(icon: ImageVector, tint: Color) {
    Box(Modifier.size(36.dp).background(tint.copy(alpha = 0.14f), RoundedCornerShape(Tokens.Radius.inner)), contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
    }
}

/** Kare karo: üstte simge (ve sağda canlı nokta ya da hap), altta etiket ve değer. */
@Composable
fun SquareTile(
    icon: ImageVector?, label: String, value: String, modifier: Modifier = Modifier, tint: Color = Tokens.Color.accent,
    style: TileStyle = TileStyle.NORMAL, dim: Boolean = false, code: String? = null, corner: (@Composable () -> Unit)? = null,
    note: String? = null, onClick: (() -> Unit)? = null,
) {
    Tile(modifier.aspectRatio(1f).alpha(if (dim) 0.5f else 1f), style = style, onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) IconBadge(icon, tint)
            if (code != null) CodeBadge(code, tint)
            Spacer(Modifier.weight(1f))
            corner?.invoke()
        }
        Spacer(Modifier.weight(1f))
        Text(label, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        Text(value, style = Tokens.Type.title, color = Tokens.Color.text, maxLines = 2)
        note?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
    }
}

/** Oyun kısaltması ("GTA") kutusu. */
@Composable
fun CodeBadge(code: String, tint: Color = Tokens.Color.pro) {
    Box(Modifier.background(tint.copy(alpha = 0.14f), RoundedCornerShape(Tokens.Radius.inner)).padding(horizontal = 10.dp, vertical = 8.dp)) {
        Text(code, style = Tokens.Type.caption, color = tint)
    }
}

/** İki sütunlu satır (bento). */
@Composable
fun TwoColumns(left: @Composable (Modifier) -> Unit, right: @Composable (Modifier) -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
        left(Modifier.weight(1f))
        right(Modifier.weight(1f))
    }
}

/** Segmentli seçim: seçili parça yüzey + amber çerçeve ve parıltı. */
@Composable
fun Segmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.control)).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        options.forEachIndexed { index, option ->
            val on = index == selected
            Box(
                Modifier.weight(1f).height(36.dp)
                    .let { if (on) it.glow(Tokens.Color.accent.copy(alpha = 0.5f), 16.dp, Tokens.Radius.inner) else it }
                    .background(if (on) Tokens.Color.surface else Color.Transparent, RoundedCornerShape(Tokens.Radius.inner))
                    .let { if (on) it.border(1.dp, Tokens.Color.accent.copy(alpha = 0.45f), RoundedCornerShape(Tokens.Radius.inner)) else it }
                    .clickable { onSelect(index) },
                contentAlignment = Alignment.Center,
            ) { Text(option, style = Tokens.Type.body.copy(fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold), color = if (on) Tokens.Color.text else Tokens.Color.secondary) }
        }
    }
}

/** Sekiz haneli eşleme kodu kutuları (radius.inner); yazılan rakamlar kutulara dağılır. */
@Composable
fun CodeCells(code: String, length: Int = 8) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
        repeat(length) { index ->
            val digit = code.getOrNull(index)?.toString() ?: ""
            Box(
                Modifier.weight(1f).height(48.dp).background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.inner))
                    .border(1.dp, if (index == code.length) Tokens.Color.accent else Tokens.Color.borderStrong, RoundedCornerShape(Tokens.Radius.inner)),
                contentAlignment = Alignment.Center,
            ) { Text(digit, style = Tokens.Type.title, color = Tokens.Color.text) }
        }
    }
}

/** Geniş karonun içindeki satırlar, aralarında 1 px ayraç. */
@Composable
fun RowList(rows: List<@Composable () -> Unit>) {
    Tile {
        rows.forEachIndexed { index, row ->
            if (index > 0) HorizontalDivider(color = Tokens.Color.borderStrong)
            row()
        }
    }
}

/** "ya da e-posta ile" gibi ortası yazılı ayraç. */
@Composable
fun DividerText(text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
        HorizontalDivider(Modifier.weight(1f), color = Tokens.Color.borderStrong)
        Text(text, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        HorizontalDivider(Modifier.weight(1f), color = Tokens.Color.borderStrong)
    }
}

/** Sağ tarafta seçici olan satır için küçük durum hapı. */
@Composable
fun StatusPill(text: String, ok: Boolean) = Pill(text, if (ok) Tokens.Color.success else Tokens.Color.secondary)

/** Ekran kenarları ve çerçeveli durum karosu (ör. hata mesajı). */
@Composable
fun NoteTile(text: String, color: Color = Tokens.Color.warning) {
    Box(Modifier.fillMaxWidth().background(color.copy(alpha = 0.10f), RoundedCornerShape(Tokens.Radius.control))
        .border(BorderStroke(1.dp, color.copy(alpha = 0.4f)), RoundedCornerShape(Tokens.Radius.control)).padding(Tokens.Space.tile)) {
        Text(text, style = Tokens.Type.body, color = color)
    }
}
