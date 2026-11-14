// SPDX-License-Identifier: AGPL-3.0-only
// Tuvaldeki (design-canvas, Telefon-*) tekrar eden parçalar: başlık satırı, durum karosu, paket karosu, segmentli
// seçim, kod haneleri, satır listesi. Simgeler kutusuzdur; renkli kare ve tonlu hap yoktur.
package com.couchsubs.mobile.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
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
import androidx.compose.ui.text.font.FontWeight
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
        if (title != null) Text(title, style = Tokens.Type.title, color = Tokens.Color.text, modifier = Modifier.weight(1f), maxLines = 1)
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

/** Ekran başlığı (display) ve altında açıklama; üstte isteğe bağlı "Kurulum · Adım 1/3" (ikincil renk). */
@Composable
fun Heading(title: String, body: String? = null, step: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
        step?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
        Text(title, style = Tokens.Type.display, color = Tokens.Color.text)
        body?.let { Text(it, style = Tokens.Type.body, color = Tokens.Color.secondary) }
    }
}

/** Kutusuz karo simgesi (18 dp, ikincil renk; oyun paketi simgesi mor). */
@Composable
fun TileIcon(icon: ImageVector, tint: Color = Tokens.Color.secondary) =
    Icon(icon, null, tint = tint, modifier = Modifier.size(Tokens.Control.tileIcon))

/**
 * Durum karosu: üstte etiket satırı (kutusuz simge, caption ad, sağda isteğe bağlı durum), altında title değer ve
 * isteğe bağlı not.
 */
@Composable
fun StatusTile(
    icon: ImageVector?, label: String, value: String, modifier: Modifier = Modifier,
    style: TileStyle = TileStyle.NORMAL, dim: Boolean = false, corner: (@Composable () -> Unit)? = null,
    note: String? = null, onClick: (() -> Unit)? = null,
) {
    Tile(modifier.alpha(if (dim) 0.4f else 1f), style = style, onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
            if (icon != null) TileIcon(icon)
            Text(label, style = Tokens.Type.caption, color = Tokens.Color.secondary, modifier = Modifier.weight(1f), maxLines = 1)
            corner?.invoke()
        }
        Text(value, style = Tokens.Type.title, color = Tokens.Color.text, maxLines = 2)
        note?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
    }
}

/** Oyun paketi karosu: nötr kısaltma monogramı ve sağda durum, altında ad (headline) ve satır sayısı. */
@Composable
fun PackTile(
    code: String, name: String, lines: String, modifier: Modifier = Modifier, style: TileStyle = TileStyle.NORMAL,
    dim: Boolean = false, corner: (@Composable () -> Unit)? = null, onClick: (() -> Unit)? = null,
) {
    Tile(modifier.alpha(if (dim) 0.4f else 1f), style = style, onClick = onClick) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            GameMonogram(code)
            Spacer(Modifier.weight(1f))
            corner?.invoke()
        }
        Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
            Text(name, style = Tokens.Type.headline, color = Tokens.Color.text, maxLines = 1)
            Text(lines, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
    }
}

/** Oyun kısaltması ("GTA"): 44 dp, 8 köşe, surface2 zemin, nötr yazı. */
@Composable
fun GameMonogram(code: String) {
    Box(Modifier.size(Tokens.Control.icon).background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.inner)), contentAlignment = Alignment.Center) {
        Text(code, style = Tokens.Type.caption.copy(fontWeight = FontWeight.SemiBold), color = Tokens.Color.text)
    }
}

/** Seçili karonun sağ üstündeki işaret: 20 dp sarı daire içinde onay. */
@Composable
fun SelectedCheck() {
    Box(Modifier.size(20.dp).background(Tokens.Color.accent, CircleShape), contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.Check, stringResource(R.string.selected), tint = Tokens.Color.onAccent, modifier = Modifier.size(14.dp))
    }
}

/** İki sütunlu satır (bento); iki karo aynı yükseklikte. */
@Composable
fun TwoColumns(left: @Composable (Modifier) -> Unit, right: @Composable (Modifier) -> Unit) {
    Row(Modifier.height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
        left(Modifier.weight(1f).fillMaxHeight())
        right(Modifier.weight(1f).fillMaxHeight())
    }
}

/** Segmentli seçim: surface2 ray; seçili parça yükseltilmiş zemin ve yarı kalın yazı (çerçeve ve parıltı yok). */
@Composable
fun Segmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().background(Tokens.Color.surface2, RoundedCornerShape(Tokens.Radius.control)).padding(Tokens.Space.hair),
        horizontalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
        options.forEachIndexed { index, option ->
            val on = index == selected
            Box(
                Modifier.weight(1f).height(36.dp)
                    .background(if (on) Tokens.Color.raised else Color.Transparent, RoundedCornerShape(Tokens.Radius.inner))
                    .clickable { onSelect(index) },
                contentAlignment = Alignment.Center,
            ) {
                Text(option, style = Tokens.Type.body.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium),
                    color = if (on) Tokens.Color.text else Tokens.Color.secondary, maxLines = 1)
            }
        }
    }
}

/** Sekiz haneli eşleme kodu kutuları (radius.inner); yazılan rakamlar kutulara dağılır, sıradaki kutu sarı çerçeveli. */
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

/** Geniş karonun içindeki satırlar, aralarında 1 px ayraç (karo iç boşluğu 4/16). */
@Composable
fun RowList(rows: List<@Composable () -> Unit>) {
    val shape = RoundedCornerShape(Tokens.Radius.tile)
    Column(
        Modifier.fillMaxWidth().background(Tokens.Color.surface, shape).border(1.dp, Tokens.Color.border, shape)
            .padding(horizontal = Tokens.Space.tile, vertical = Tokens.Space.hair),
    ) {
        rows.forEachIndexed { index, row ->
            if (index > 0) HorizontalDivider(color = Tokens.Color.border)
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

/** Bilgi ya da hata karosu: düz karo, solda kutusuz simge, metin verilen renkte (varsayılan uyarı). */
@Composable
fun NoteTile(text: String, color: Color = Tokens.Color.warning) {
    Tile(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
            if (color == Tokens.Color.warning) TileIcon(Icons.Filled.Warning, color)
            Text(text, style = Tokens.Type.body, color = color)
        }
    }
}
