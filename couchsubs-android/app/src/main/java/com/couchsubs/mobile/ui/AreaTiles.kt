// SPDX-License-Identifier: AGPL-3.0-only
// Ayarlar › Altyazı alanı ve Ek alanlar (iPhone'daki AreaTile ve ExtraAreasTile ile aynı): hazır seçimler, son kareyle
// canlı önizleme (çerçeve sürüklenir, kenar ve köşelerinden boyutlanır; altyazı alanında "Ortada tut"), Özel'de
// kaydırıcılar; en çok üç ek alan.
package com.couchsubs.mobile.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.AreaPreset
import com.couchsubs.mobile.core.AreaProfile
import com.couchsubs.mobile.core.AreaProfiles
import com.couchsubs.mobile.core.areasDifferFromProfile
import com.couchsubs.mobile.core.gameProfiles
import com.couchsubs.mobile.core.CropRegion
import com.couchsubs.mobile.core.ExtraArea
import com.couchsubs.mobile.core.ExtraAreaPreset
import com.couchsubs.mobile.core.MINIMUM_REGION_SIZE
import com.couchsubs.mobile.core.RegionEdit
import com.couchsubs.mobile.core.withVertical
import com.couchsubs.mobile.service.FramePreview
import com.couchsubs.mobile.service.LiveState
import com.couchsubs.mobile.service.PlayedGame

/**
 * Ayarlar › Bu oyunun alanları: alanlar oynanan oyuna kaydedilir, o oyun yeniden oynanınca kendiliğinden gelir. Profil
 * etkinse hangi oyunun alanları olduğu ve kaydedilmemiş değişiklikte "Profile kaydet" (Windows, Mac ve iPhone ile aynı).
 */
@Composable
fun AreaProfileTile() {
    val status by LiveState.status.collectAsState()
    val settings = Services.settings
    // Alanlar bu ekranda değişince "kaydedilmedi" durumu yeniden okunur.
    var edits by remember { mutableIntStateOf(0) }
    DisposableEffect(settings) {
        val listener = settings.onAreasChanged { edits++ }
        onDispose { settings.removeListener(listener) }
    }
    val active = status.areaProfileGame
    val target = status.areaProfileTarget
    val unsaved = remember(edits, status.areasVersion, active) { settings.areasDifferFromProfile }
    var confirmDelete by remember { mutableStateOf(false) }
    Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.area_profile_title))
        val (headline, note) = when {
            active != null -> stringResource(R.string.area_profile_saved, active) to
                stringResource(if (unsaved) R.string.area_profile_unsaved else R.string.area_profile_comes_back)
            target != null -> stringResource(R.string.area_profile_general) to stringResource(R.string.area_profile_save_note, target)
            else -> stringResource(R.string.area_profile_unknown) to stringResource(R.string.area_profile_choose_game)
        }
        Text(headline, style = Tokens.Type.body, color = Tokens.Color.text)
        Text(note, style = Tokens.Type.caption, color = Tokens.Color.secondary)
        if (target != null && status.areaProfileTargetSaved) {
            // Oynanan oyunun kayıtlı alanları uygulanmadı: üzerine yazılmaz, istenirse kullanılır.
            SecondaryButton(stringResource(R.string.area_profile_use_saved, target)) {
                PlayedGame.areas.targetKey?.let { PlayedGame.areas.use(it, settings) }
            }
        } else if (target != null && (active == null || unsaved)) {
            SecondaryButton(if (active == null) stringResource(R.string.area_profile_save_for, target) else stringResource(R.string.area_profile_save)) {
                PlayedGame.areas.save()
            }
        }
        if (active != null) DestructiveButton(stringResource(R.string.area_profile_delete)) { confirmDelete = true }
    }
    if (confirmDelete && active != null) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text(stringResource(R.string.area_profile_delete)) },
        text = { Text(stringResource(R.string.area_profile_delete_body, active)) },
        confirmButton = {
            TextButton({
                confirmDelete = false
                PlayedGame.areas.delete()
            }) { Text(stringResource(R.string.area_profile_delete), color = Tokens.Color.danger) }
        },
        dismissButton = { TextButton({ confirmDelete = false }) { Text(stringResource(R.string.cancel)) } },
        containerColor = Tokens.Color.surface2,
    )
}

/** Oyun profilleri kartında ad yazılan işlem: yeni profil (null anahtar), yeniden adlandırma ya da çoğaltma. */
private data class ProfileEditing(val key: String?, val duplicate: Boolean)

/**
 * Ayarlar › Oyun profilleri: her oyunun kendi alanları. Listede olmayan oyun adı yazılarak eklenir; profil seçilir,
 * yeniden adlandırılır, çoğaltılır, silinir. Profil seçmek oynanan oyunu da o yapar (Mac, Windows ve iPhone ile aynı).
 */
@Composable
fun GameProfilesTile() {
    val status by LiveState.status.collectAsState()
    val settings = Services.settings
    val areas = PlayedGame.areas
    var edits by remember { mutableIntStateOf(0) }
    DisposableEffect(settings) {
        val listener = settings.onAreasChanged { edits++ }
        onDispose { settings.removeListener(listener) }
    }
    val profiles = remember(edits, status.profilesVersion) { settings.gameProfiles(areas.areaSource) }
    val active = remember(edits, status.profilesVersion) { settings.activeAreaProfile }
    var editing by remember { mutableStateOf<ProfileEditing?>(null) }
    var name by remember { mutableStateOf("") }
    var problem by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<AreaProfile?>(null) }
    val existsText = stringResource(R.string.game_profiles_exists, name.trim())
    val emptyText = stringResource(R.string.game_profiles_empty)
    fun begin(mode: ProfileEditing, initial: String) {
        editing = mode
        name = initial
        problem = null
    }
    fun commit() {
        val mode = editing ?: return
        val key = mode.key
        val edit = when {
            key == null -> areas.saveAs(name, settings)
            mode.duplicate -> areas.duplicate(key, name, settings)
            else -> areas.rename(key, name, settings)
        }
        edits++
        when (edit) {
            AreaProfiles.Edit.DONE -> editing = null
            AreaProfiles.Edit.EXISTS -> problem = existsText
            else -> problem = emptyText
        }
    }
    @Composable
    fun Editor() {
        Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
            Field(name, { name = it }, stringResource(R.string.game_profiles_name))
            problem?.let { Text(it, style = Tokens.Type.caption, color = Tokens.Color.secondary) }
            Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                val mode = editing
                val title = when {
                    mode?.key == null -> R.string.game_profiles_save_current
                    mode.duplicate -> R.string.game_profiles_duplicate
                    else -> R.string.game_profiles_rename
                }
                SecondaryButton(stringResource(title), enabled = name.isNotBlank()) { commit() }
                GhostButton(stringResource(R.string.cancel), color = Tokens.Color.secondary) { editing = null }
            }
        }
    }
    Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.game_profiles_title))
        Text(stringResource(R.string.game_profiles_body), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        for (profile in profiles) key(profile.key) {
            // Düzenlenen profilin yerinde düzenleyici durur. "return@key" D8'de APK derlemesini bozuyordu
            // (NON_LOCAL_RETURN; android-app iş akışı #798'den beri kırmızıydı).
            if (editing?.key == profile.key) {
                Editor()
            } else {
                var menu by remember { mutableStateOf(false) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(profile.game, style = Tokens.Type.body, color = Tokens.Color.text, maxLines = 1)
                        if (profile.key == active) {
                            Text(stringResource(R.string.game_profiles_in_use), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                        }
                    }
                    if (profile.key != active) {
                        GhostButton(stringResource(R.string.area_profile_use)) {
                            areas.use(profile.key, settings)
                            edits++
                        }
                    }
                    Box {
                        GhostButton(stringResource(R.string.game_profiles_more), color = Tokens.Color.secondary) { menu = true }
                        DropdownMenu(menu, { menu = false }) {
                            DropdownMenuItem({ Text(stringResource(R.string.game_profiles_rename)) }, {
                                menu = false
                                begin(ProfileEditing(profile.key, false), profile.game)
                            })
                            DropdownMenuItem({ Text(stringResource(R.string.game_profiles_duplicate)) }, {
                                menu = false
                                begin(ProfileEditing(profile.key, true), "")
                            })
                            DropdownMenuItem({ Text(stringResource(R.string.area_profile_delete), color = Tokens.Color.danger) }, {
                                menu = false
                                deleting = profile
                            })
                        }
                    }
                }
            }
        }
        if (editing?.key == null && editing != null) {
            Editor()
        } else if (editing == null) {
            SecondaryButton(stringResource(R.string.game_profiles_new)) { begin(ProfileEditing(null, false), status.game ?: "") }
        }
    }
    deleting?.let { profile ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.area_profile_delete)) },
            text = { Text(stringResource(R.string.area_profile_delete_body, profile.game)) },
            confirmButton = {
                TextButton({
                    deleting = null
                    areas.delete(profile.key, settings)
                    edits++
                }) { Text(stringResource(R.string.area_profile_delete), color = Tokens.Color.danger) }
            },
            dismissButton = { TextButton({ deleting = null }) { Text(stringResource(R.string.cancel)) } },
            containerColor = Tokens.Color.surface2,
        )
    }
}

/** Ayarlar › Altyazı alanı: Alt alan, Üst alan, Tam ekran, Özel; önizlemede çerçeve sürüklenir. */
@Composable
fun AreaTile() {
    val settings = Services.settings
    // Oyunun alanları uygulanınca ya da geri dönülünce ([LiveStatus.areasVersion]) kayıtlı alan yeniden okunur.
    val version = LiveState.status.collectAsState().value.areasVersion
    var region by remember(version) { mutableStateOf(settings.region) }
    var preset by remember(version) { mutableStateOf(settings.areaPreset) }
    var centered by remember { mutableStateOf(settings.keepAreaCentered) }
    fun custom(value: CropRegion) {
        region = value
        preset = AreaPreset.CUSTOM
        settings.setCustomRegion(value)
    }
    Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.area_title))
        val presets = listOf(AreaPreset.BOTTOM, AreaPreset.TOP, AreaPreset.FULL, AreaPreset.CUSTOM)
        Segmented(listOf(stringResource(R.string.area_bottom), stringResource(R.string.area_top), stringResource(R.string.area_full),
            stringResource(R.string.area_custom)), presets.indexOf(preset)) { index ->
            preset = presets[index]
            settings.selectAreaPreset(preset)
            region = settings.region
        }
        RegionPreview(region, centered = centered, onChange = ::custom)
        if (preset == AreaPreset.CUSTOM) {
            val position = region.top * 100
            val height = (region.bottom - region.top) * 100
            SliderRow(stringResource(R.string.area_position), position, 0f..maxOf(1.0, 100 - height).toFloat()) { custom(region.withVertical(it, height)) }
            SliderRow(stringResource(R.string.area_height), height, (MINIMUM_REGION_SIZE * 100).toFloat()..100f) { custom(region.withVertical(position, it)) }
        }
        RowItem(stringResource(R.string.area_keep_centered)) { Switch(centered, { centered = it; settings.keepAreaCentered = it }) }
        // "Ortalı kalır" yalnız Ortada tut açıkken yazılır.
        Text(stringResource(if (centered) R.string.area_drag_note else R.string.area_drag_note_free), style = Tokens.Type.caption,
            color = Tokens.Color.secondary)
    }
}

@Composable
private fun SliderRow(title: String, value: Double, range: ClosedFloatingPointRange<Float>, onChange: (Double) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.hair)) {
        SliderHeader(title, "%${value.toInt()}")
        Slider(value.toFloat(), { onChange(it.toDouble()) }, valueRange = range, colors = couchSliderColors())
    }
}

/** Ayarlar › Ek alanlar: altyazının yanında sürekli okunan en çok üç küçük alan (görev, bildirim, telefon). */
@Composable
fun ExtraAreasTile() {
    val settings = Services.settings
    val version = LiveState.status.collectAsState().value.areasVersion
    var areas by remember(version) { mutableStateOf(settings.extraAreas) }
    var menu by remember { mutableStateOf(false) }
    // Altyazı alanı Tam ekranken ek alanlar okunmaz (bkz. watched); seçim değişince not ve soluk görünüm güncellenir.
    var fullScreen by remember(version) { mutableStateOf(settings.areaPreset == AreaPreset.FULL) }
    DisposableEffect(settings) {
        val listener = settings.onAreasChanged { fullScreen = settings.areaPreset == AreaPreset.FULL }
        onDispose { settings.removeListener(listener) }
    }
    fun save(value: List<ExtraArea>) {
        areas = value
        settings.extraAreas = value
    }
    fun update(id: String, change: (ExtraArea) -> ExtraArea) = save(areas.map { if (it.id == id) change(it) else it })
    Tile(Modifier.fillMaxWidth()) {
        TileLabel(stringResource(R.string.extra_title))
        Text(stringResource(R.string.extra_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        if (fullScreen && areas.isNotEmpty()) {
            Text(stringResource(R.string.extra_full_screen_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
        }
        areas.forEach { area ->
            // Karo içindeki kutu: inner köşe ve çerçeve, zemin karonunki; böylece içindeki ad alanı (surface2) kutudan ayrılır.
            val shape = RoundedCornerShape(Tokens.Radius.inner)
            Column(Modifier.fillMaxWidth().alpha(if (fullScreen) 0.5f else 1f).border(1.dp, Tokens.Color.borderStrong, shape).padding(Tokens.Space.gap),
                verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                    Box(Modifier.weight(1f)) {
                        Field(area.name, { name -> update(area.id) { it.copy(name = name) } }, stringResource(R.string.extra_name))
                    }
                    Switch(area.enabled, { on -> update(area.id) { it.copy(enabled = on) } })
                    IconAction(Icons.Filled.Delete, stringResource(R.string.extra_remove)) { save(areas.filter { it.id != area.id }) }
                }
                val presets = ExtraAreaPreset.entries
                Segmented(listOf(stringResource(R.string.extra_quest), stringResource(R.string.extra_notification), stringResource(R.string.extra_phone)),
                    presets.indexOf(ExtraAreaPreset.matching(area.region))) { index -> update(area.id) { it.copy(region = presets[index].region) } }
                Box(Modifier.alpha(if (area.enabled) 1f else 0.5f)) {
                    RegionPreview(area.region) { region -> update(area.id) { it.copy(region = region) } }
                }
            }
        }
        if (areas.size < ExtraArea.MAX_COUNT) Box {
            SecondaryButton(stringResource(R.string.extra_add)) { menu = true }
            DropdownMenu(menu, { menu = false }) {
                ExtraAreaPreset.entries.forEach { preset ->
                    val name = presetName(preset)
                    DropdownMenuItem({ Text(presetTitle(preset)) }, {
                        menu = false
                        save(areas + ExtraArea(name = name, region = preset.region))
                    })
                }
            }
        }
    }
}

@Composable
private fun presetTitle(preset: ExtraAreaPreset) = stringResource(when (preset) {
    ExtraAreaPreset.QUEST -> R.string.extra_quest_title
    ExtraAreaPreset.NOTIFICATION -> R.string.extra_notification_title
    ExtraAreaPreset.PHONE -> R.string.extra_phone_title
})

@Composable
private fun presetName(preset: ExtraAreaPreset) = stringResource(when (preset) {
    ExtraAreaPreset.QUEST -> R.string.extra_quest
    ExtraAreaPreset.NOTIFICATION -> R.string.extra_notification
    ExtraAreaPreset.PHONE -> R.string.extra_phone
})

/**
 * Alanın canlı önizlemesi: son karenin üstünde çerçeve; alanın dışı karartılır, okunacak yer belirgin olur. Çerçeve
 * içinden sürüklenerek taşınır, sekiz tutamacından (köşeler ve kenar ortaları) sürüklenerek boyutlandırılır. [centered]
 * (altyazı alanında "Ortada tut" açıkken): yatay boyut ortadan değişir, alan ortalı kalır. Kurallar [RegionEdit]'tedir (Windows, Mac ve iPhone ile
 * aynı). Çerçevenin dışından başlayan sürükleme bir şey değiştirmez. Sürükleme boyunca yalnız önizlemedeki taslak değişir;
 * [onChange] bırakınca bir kez çağrılır, ayar her harekette yazılmaz (GitHub #802; Windows RegionPicker, Mac RegionDrag).
 */
@Composable
fun RegionPreview(region: CropRegion, centered: Boolean = false, onChange: (CropRegion) -> Unit) {
    DisposableEffect(Unit) {
        FramePreview.watch(true)
        onDispose { FramePreview.watch(false) }
    }
    val frame by FramePreview.frame.collectAsState()
    val current by rememberUpdatedState(region)
    val change by rememberUpdatedState(onChange)
    val evenly by rememberUpdatedState(centered)
    // Süren sürüklemenin taslağı; sürükleme yokken null.
    var draft by remember { mutableStateOf<CropRegion?>(null) }
    Box(Modifier.fillMaxWidth().aspectRatio(16f / 9f).clip(RoundedCornerShape(Tokens.Radius.control)).background(Color.Black)) {
        frame?.let { Image(it.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = ContentScale.FillBounds) }
            ?: Text(stringResource(R.string.area_preview_empty), style = Tokens.Type.caption, color = Tokens.Color.secondary,
                textAlign = TextAlign.Center, modifier = Modifier.align(Alignment.Center).padding(Tokens.Space.gap))
        Canvas(Modifier.fillMaxSize().pointerInput(Unit) {
            var start = current
            var handle: Int? = null
            var moved = Offset.Zero
            detectDragGestures(
                onDragStart = { at ->
                    start = current
                    moved = Offset.Zero
                    // Parmakla tutulsun diye tutma payı görünen tutamaçtan geniştir.
                    val grab = 20.dp.toPx()
                    handle = RegionEdit.handleAt(start, at.x.toDouble() / size.width, at.y.toDouble() / size.height,
                        grab.toDouble() / size.width, grab.toDouble() / size.height)
                },
                onDragEnd = {
                    val result = draft
                    handle = null
                    draft = null
                    if (result != null && result != start) change(result)
                },
                onDragCancel = {
                    handle = null
                    draft = null
                },
            ) { pointer, drag ->
                val grabbed = handle ?: return@detectDragGestures
                pointer.consume()
                moved += drag
                draft = RegionEdit.dragged(start, grabbed, moved.x.toDouble() / size.width, moved.y.toDouble() / size.height, evenly)
            }
        }) {
            val shown = draft ?: region
            val left = (shown.left * size.width).toFloat()
            val top = (shown.top * size.height).toFloat()
            val right = (shown.right * size.width).toFloat()
            val bottom = (shown.bottom * size.height).toFloat()
            val shade = Color.Black.copy(alpha = 0.5f)
            drawRect(shade, Offset.Zero, Size(size.width, top))
            drawRect(shade, Offset(0f, bottom), Size(size.width, size.height - bottom))
            drawRect(shade, Offset(0f, top), Size(left, bottom - top))
            drawRect(shade, Offset(right, top), Size(size.width - right, bottom - top))
            drawRect(Tokens.Color.accent, Offset(left, top), Size(right - left, bottom - top), style = Stroke(2.dp.toPx()))
            val handleSize = 9.dp.toPx()
            RegionEdit.handles(shown).forEach { grip ->
                drawRect(Tokens.Color.accent, Offset((grip.x * size.width).toFloat() - handleSize / 2, (grip.y * size.height).toFloat() - handleSize / 2),
                    Size(handleSize, handleSize))
            }
        }
    }
}
