// SPDX-License-Identifier: AGPL-3.0-only
// Oyun paketleri › Paketi içe aktar: topluluk çeviri dosyası (JSON, TXT, iki dilli SRT) seçilir, önizlenir ve bu
// telefona paket olarak kurulur (Mac, Windows ve iPhone ile aynı akış). Dosya Storage Access Framework ile seçilir:
// depolama izni istenmez, dosya yalnız okunur ve hiçbir yere gönderilmez.

package com.couchsubs.mobile.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.GamePackImportPreview
import com.couchsubs.mobile.core.GamePackImporter
import com.couchsubs.mobile.core.GamePackSkipReason
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

private const val LOG_TAG = "CouchSubsPacks"

/** Seçilen dosya ve önizlemesi. */
private class ImportSelection(val fileName: String, val preview: GamePackImportPreview)

/** SAF'ta seçilebilen türler; SRT çoğu zaman application/x-subrip ya da octet-stream gelir. Uzantıyı içe aktarıcı denetler. */
private val importTypes = arrayOf("application/json", "text/plain", "application/x-subrip", "text/srt", "text/*", "application/octet-stream")

/** Paket ekranındaki "İçe aktarılan paketler" bölümü: içe aktarma düğmesi, liste ve silme. */
@Composable
fun ImportedPacksSection() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val version by Services.packsVersion.collectAsState()
    var imported by remember { mutableStateOf<List<Services.ImportedPack>>(emptyList()) }
    var reading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var selection by remember { mutableStateOf<ImportSelection?>(null) }
    var deleting by remember { mutableStateOf<Services.ImportedPack?>(null) }
    LaunchedEffect(version) { imported = withContext(Dispatchers.IO) { Services.importedPacks() } }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        reading = true
        scope.launch {
            try {
                selection = withContext(Dispatchers.IO) { readSelection(context, uri) }
            } catch (failure: GamePackImporter.ImportException) {
                error = context.getString(R.string.packs_import_format_error)
            } catch (failure: Exception) {
                error = context.getString(R.string.packs_import_read_error)
            } catch (failure: OutOfMemoryError) {
                error = context.getString(R.string.packs_import_read_error)
            } finally {
                reading = false
            }
        }
    }

    Text(stringResource(R.string.packs_imported_title), style = Tokens.Type.headline, color = Tokens.Color.text)
    Text(stringResource(R.string.packs_import_note), style = Tokens.Type.caption, color = Tokens.Color.secondary)
    if (imported.isNotEmpty()) {
        RowList(imported.map { pack ->
            {
                RowItem(pack.title, linesText(context, pack.entries)) {
                    GhostButton(stringResource(R.string.packs_delete), color = Tokens.Color.danger) { deleting = pack }
                }
            }
        })
    }
    error?.let { NoteTile(it) }
    SecondaryButton(stringResource(R.string.packs_import), enabled = !reading) {
        error = null
        picker.launch(importTypes)
    }

    selection?.let { current ->
        ImportPreviewDialog(current, onDone = { selection = null })
    }
    deleting?.let { pack ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(stringResource(R.string.packs_delete_title)) },
            text = { Text(stringResource(R.string.packs_delete_body, pack.title)) },
            confirmButton = {
                TextButton({
                    deleting = null
                    scope.launch(Dispatchers.IO) { Services.deleteImportedPack(pack) }
                }) { Text(stringResource(R.string.packs_delete), color = Tokens.Color.danger) }
            },
            dismissButton = { TextButton({ deleting = null }) { Text(stringResource(R.string.cancel)) } },
            containerColor = Tokens.Color.surface2,
        )
    }
}

/** Dosyayı okur (en çok [GamePackImporter.MAX_FILE_BYTES]) ve önizler; bloklar. */
private fun readSelection(context: Context, uri: Uri): ImportSelection {
    val resolver = context.contentResolver
    var name = uri.lastPathSegment?.substringAfterLast('/') ?: ""
    var size = -1L
    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
        if (cursor.moveToFirst()) {
            cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !cursor.isNull(it) }?.let { name = cursor.getString(it) }
            cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !cursor.isNull(it) }?.let { size = cursor.getLong(it) }
        }
    }
    if (size > GamePackImporter.MAX_FILE_BYTES) throw GamePackImporter.ImportException(GamePackImporter.Failure.FILE_TOO_LARGE)
    val data = resolver.openInputStream(uri)?.use { input ->
        // Boyutu bildirilmeyen sağlayıcıda da sınırın bir bayt fazlası okunur: aşan dosya belleğe alınmaz.
        val buffer = java.io.ByteArrayOutputStream()
        val chunk = ByteArray(64 * 1024)
        while (true) {
            val count = input.read(chunk)
            if (count < 0) break
            buffer.write(chunk, 0, count)
            if (buffer.size() > GamePackImporter.MAX_FILE_BYTES) throw GamePackImporter.ImportException(GamePackImporter.Failure.FILE_TOO_LARGE)
        }
        buffer.toByteArray()
    } ?: throw IOException("cannot open $uri")
    val preview = GamePackImporter.parse(data, name)
    // Kaç satırın kabul edildiği, kaçının neden atlandığı günlükte de (Günlükleri paylaş; #1355).
    Log.i(LOG_TAG, preview.logLine(name))
    return ImportSelection(name, preview)
}

/** Önizleme: oyunun adı (JSON'dan ya da dosya adından), sayılar; onaylanınca kurulur, aynı kimlik varsa sorulur. */
@Composable
private fun ImportPreviewDialog(selection: ImportSelection, onDone: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val preview = selection.preview
    var title by remember { mutableStateOf(preview.suggestedTitle ?: selection.fileName.substringBeforeLast('.')) }
    var installing by remember { mutableStateOf(false) }
    var confirmReplacement by remember { mutableStateOf(false) }
    var installError by remember { mutableStateOf<String?>(null) }
    // Perde başarı anı: paket kuruldu (ışın + yaylı tik + başarı titreşimi); kısa süre sonra pencere kendiliğinden kapanır.
    var installed by remember { mutableStateOf(false) }
    val view = LocalView.current
    val canInstall = !installing && preview.entries.isNotEmpty() && title.isNotBlank()

    fun install(replacing: Boolean) {
        if (!canInstall) return
        installError = null
        installing = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    GamePackImporter.install(preview, title, Services.importedPacksDirectory, replacing)
                    Log.i(LOG_TAG, preview.installLog(title))
                    Services.localPacksChanged()
                }
                installed = true
            } catch (failure: GamePackImporter.ImportException) {
                if (failure.failure == GamePackImporter.Failure.DESTINATION_EXISTS) confirmReplacement = true
                else {
                    Haptics.error(view)
                    installError = context.getString(R.string.packs_import_install_error)
                }
            } catch (failure: Exception) {
                Haptics.error(view)
                installError = context.getString(R.string.packs_import_install_error)
            } finally {
                installing = false
            }
        }
    }

    if (installed) {
        LaunchedEffect(Unit) {
            kotlinx.coroutines.delay(2400)
            onDone()
        }
        AlertDialog(
            onDismissRequest = onDone,
            text = {
                // Eğik tipografik kapak + başarı anı, oyunun adı, "Kurulu" ve satır sayısı; tek düğme.
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Tokens.Space.gap)) {
                    Box(contentAlignment = Alignment.Center) {
                        Celebration(56.dp)
                        Box(Modifier.offset(x = (-44).dp, y = (-6).dp).rotate(-8f).size(54.dp, 72.dp)
                            .clip(RoundedCornerShape(Tokens.Radius.inner))) { CoverArt(title, modifier = Modifier.fillMaxSize()) }
                    }
                    Text(title, style = Tokens.Type.h3, color = Tokens.Color.text, textAlign = TextAlign.Center)
                    Row(horizontalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                        StatusChip(stringResource(R.string.perde_installed), ChipTone.OK, icon = Icons.Filled.Check)
                        StatusChip(linesText(context, preview.acceptedCount), ChipTone.AMBER, dot = false)
                    }
                }
            },
            confirmButton = { PrimaryButton(stringResource(R.string.perde_done), onClick = onDone) },
            containerColor = Tokens.Color.surface,
        )
        return
    }
    AlertDialog(
        onDismissRequest = { if (!installing) onDone() },
        title = { Text(stringResource(R.string.packs_import_heading)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Tokens.Space.inline)) {
                Field(title, { title = it }, stringResource(R.string.packs_import_game_title))
                // Kabul edilen ve nedenine göre atlanan kayıtlar (#1355; Mac, iPhone ve Windows ile aynı satırlar).
                CountRow(stringResource(R.string.packs_import_usable), preview.acceptedCount)
                if (preview.segments.isNotEmpty()) CountRow(stringResource(R.string.packs_import_segments), preview.segments.size)
                CountRow(stringResource(R.string.packs_import_skipped), preview.skippedCount)
                preview.skipped[GamePackSkipReason.INVALID_KEY]?.let { CountRow(stringResource(R.string.packs_import_skipped_key), it) }
                preview.skipped[GamePackSkipReason.EMPTY_TRANSLATION]?.let { CountRow(stringResource(R.string.packs_import_skipped_empty), it) }
                preview.skipped[GamePackSkipReason.MALFORMED_RECORD]?.let { CountRow(stringResource(R.string.packs_import_skipped_malformed), it) }
                CountRow(stringResource(R.string.packs_import_duplicate), preview.duplicateCount)
                CountRow(stringResource(R.string.packs_import_conflict), preview.conflictCount)
                if (preview.fuzzy != null) Text(stringResource(R.string.packs_import_fuzzy), style = Tokens.Type.caption, color = Tokens.Color.secondary)
                if (preview.fuzzyDropped) Text(stringResource(R.string.packs_import_fuzzy_dropped), style = Tokens.Type.caption, color = Tokens.Color.warning)
                if (preview.entries.isEmpty()) Text(stringResource(R.string.packs_import_empty), style = Tokens.Type.body, color = Tokens.Color.warning)
                installError?.let { Text(it, style = Tokens.Type.body, color = Tokens.Color.danger) }
                if (installing) Box(Modifier.align(Alignment.CenterHorizontally)) { BarsLoader() }
            }
        },
        confirmButton = {
            TextButton({ install(replacing = false) }, enabled = canInstall) {
                Text(stringResource(R.string.packs_import_install), color = if (canInstall) Tokens.Color.accentText else Tokens.Color.secondary)
            }
        },
        dismissButton = { TextButton(onDone, enabled = !installing) { Text(stringResource(R.string.cancel)) } },
        containerColor = Tokens.Color.surface2,
    )
    if (confirmReplacement) AlertDialog(
        onDismissRequest = { confirmReplacement = false },
        title = { Text(stringResource(R.string.packs_import_replace_title)) },
        text = { Text(stringResource(R.string.packs_import_replace_body)) },
        confirmButton = {
            TextButton({
                confirmReplacement = false
                install(replacing = true)
            }) { Text(stringResource(R.string.packs_import_replace), color = Tokens.Color.danger) }
        },
        dismissButton = { TextButton({ confirmReplacement = false }) { Text(stringResource(R.string.cancel)) } },
        containerColor = Tokens.Color.surface2,
    )
}

@Composable
private fun CountRow(label: String, count: Int) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = Tokens.Type.body, color = Tokens.Color.secondary)
        Text(java.text.NumberFormat.getIntegerInstance().format(count), style = Tokens.Type.body, color = Tokens.Color.text)
    }
}
