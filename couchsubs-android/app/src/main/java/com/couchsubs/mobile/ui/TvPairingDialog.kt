// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui
import androidx.compose.runtime.Composable
import androidx.compose.material3.*
import androidx.compose.ui.res.stringResource
import com.couchsubs.mobile.R
import com.couchsubs.mobile.core.SubtitlePairing
import com.couchsubs.mobile.service.TranslationService

@Composable fun TvPairingDialog(ticket: SubtitlePairing.Ticket?) {
    if (ticket == null) return
    AlertDialog(onDismissRequest = { TranslationService.resolvePairing(ticket.id, false) },
        title = { Text(stringResource(R.string.tv_pair_title)) },
        text = { Text(stringResource(R.string.tv_pair_code, ticket.code)) },
        confirmButton = { TextButton(onClick = { TranslationService.resolvePairing(ticket.id, true) }) { Text(stringResource(R.string.tv_pair_approve)) } },
        dismissButton = { TextButton(onClick = { TranslationService.resolvePairing(ticket.id, false) }) { Text(stringResource(R.string.tv_pair_reject)) } })
}
