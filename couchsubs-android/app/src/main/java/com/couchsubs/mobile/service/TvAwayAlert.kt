// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import com.couchsubs.mobile.R
import com.couchsubs.mobile.Services
import com.couchsubs.mobile.core.TvAway
import com.couchsubs.mobile.ui.MainActivity

/**
 * #1303: uygulama arka plandayken TV bağlantısı koptu ("altyazı bir süre TV'ye geliyor, sonra yalnız telefonda kalıyor";
 * nedeni söylenmiyordu). Ana ekranda "CouchSubs'ı açık tutun" notu çıkar, uygulama ekranda değilse bildirim gösterilir
 * (tercih "Bağlantı koptuğunda bildir"). Ne zaman uyarılacağı [TvAway]'dedir; iPhone'daki ConnectionAlert.postTVLostWhileAway
 * ile aynı metin.
 */
object TvAwayAlert {
    private const val TAG = "CouchSubs"
    private const val CHANNEL = "connection"
    private const val ID = 4

    private val away = TvAway()

    private fun now() = System.nanoTime() / 1e9

    /** Uygulamanın ekranı arka plana geçti (MainActivity.onStop). Çeviri TV'ye gidiyorsa gezi başlar. */
    fun left() {
        val status = LiveState.status.value
        if (!status.running || status.demo || !Services.settings.target.showsOnTv) return
        away.left(linked = status.connectedTvs > 0)
    }

    /** Uygulamanın ekranı öne geldi (MainActivity.onStart): bildirim kalkar; TV giderken bağlıydı, şimdi değilse not çıkar. */
    fun returned(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(ID)
        if (!away.away) return
        if (away.returned(now(), linked = LiveState.status.value.connectedTvs > 0)) note(context, "dönüşte TV bağlı değil")
    }

    /** Bağlı TV uygulamasının bağlantısı koptu (TranslationService: bağlantı kapandı ya da alındı gelmedi). */
    fun lost(context: Context, why: String) {
        if (away.lost(now())) note(context, why)
    }

    /** Çeviri başladı ya da durdu. */
    fun reset(context: Context) {
        away.reset()
        context.getSystemService(NotificationManager::class.java)?.cancel(ID)
    }

    private fun note(context: Context, why: String) {
        val status = LiveState.status.value
        if (!status.running || status.demo || !Services.settings.target.showsOnTv) return
        Log.i(TAG, "TV bağlantısı uygulama arka plandayken koptu ($why); \"CouchSubs'ı açık tutun\" uyarısı gösterildi")
        LiveState.update { it.copy(tvLostWhileAway = true) }
        if (!Services.settings.notifyDisconnect || ConnectionAlert.appVisible()) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.channel_connection),
            NotificationManager.IMPORTANCE_DEFAULT))
        val open = PendingIntent.getActivity(context, ID, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.tv_lost_away_title))
            .setContentText(context.getString(R.string.tv_lost_away_body))
            .setStyle(Notification.BigTextStyle().bigText(context.getString(R.string.tv_lost_away_body)))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(ID, notification) }
    }
}
