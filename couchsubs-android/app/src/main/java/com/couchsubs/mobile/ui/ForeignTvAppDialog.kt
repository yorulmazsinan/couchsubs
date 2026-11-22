// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.ui

import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.couchsubs.mobile.R

/**
 * TV'de CouchSubs'ın kimliğiyle başka bir uygulama kurulu: kaldırılıp CouchSubs kurulsun mu (LG, Samsung, Android TV;
 * Windows, Mac ve iPhone'daki pencereyle aynı metin). Onay verilmeden hiçbir şey kaldırılmaz.
 */
@Composable
fun ForeignTvAppDialog(onReplace: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.tvinstall_foreign_title)) },
        text = { Text(stringResource(R.string.tvinstall_foreign_body)) },
        confirmButton = {
            TextButton(onReplace) { Text(stringResource(R.string.tvinstall_foreign_replace), color = Tokens.Color.danger) }
        },
        dismissButton = { TextButton(onDismiss) { Text(stringResource(R.string.cancel)) } },
        containerColor = Tokens.Color.surface2,
    )
}
