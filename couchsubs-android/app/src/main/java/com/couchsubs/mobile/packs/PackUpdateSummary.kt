// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.packs

/**
 * "Paketleri güncelle"nin sonucu: hangi paket eklendi, hangisi güncellendi, kaç satır geldi. Güncellemeden önceki paketler
 * (uygulamayla gelen ve önceden inmiş) ile yenilemede inen paketlerin sunucudaki satır sayısı karşılaştırılır. iPhone'daki
 * CouchSubsCore/PackUpdateSummary.swift ile aynı kurallar.
 */
data class PackUpdateSummary(val changes: List<Change>) {
    /** [added]: önceden bu telefonda yoktu; [lineDelta]: önceki sürüme göre satır farkı (eklenen pakette bütün satırlar). */
    data class Change(val id: String, val title: String, val added: Boolean, val lines: Int, val lineDelta: Int)

    val isEmpty: Boolean get() = changes.isEmpty()
    val updated: List<Change> get() = changes.filter { !it.added }
    val added: List<Change> get() = changes.filter { it.added }
    /** Gelen yeni satırların toplamı (eklenen paketlerin bütün satırları ve güncellenenlerdeki artış; azalan sayılmaz). */
    val newLines: Int get() = changes.sumOf { maxOf(0, it.lineDelta) }

    companion object {
        /**
         * [before]: güncellemeden önceki paketler (kimlik → satır sayısı; aynı kimlik birden çok kez varsa son gelen geçerli,
         * kitaplıktaki gibi). [downloaded]: yenilemede inenler. Aynı kimlik bir kez sayılır.
         */
        fun of(before: List<Pair<String, Int>>, downloaded: List<RemotePack>): PackUpdateSummary {
            val previous = before.toMap()
            val changes = downloaded.distinctBy { it.id }.map { pack ->
                val old = previous[pack.id]
                Change(pack.id, pack.title.ifBlank { pack.id }, old == null, pack.entries, pack.entries - (old ?: 0))
            }
            return PackUpdateSummary(changes)
        }
    }
}

/** Elle güncellemenin sonucu (ekranda uyarı olarak gösterilir). */
sealed interface PackUpdateOutcome {
    data object UpToDate : PackUpdateOutcome
    data class Updated(val summary: PackUpdateSummary) : PackUpdateOutcome
    /** [status]: HTTP kodu (SERVER için); [summary]: hataya rağmen inen paketler. */
    data class Failed(val reason: Reason, val status: Int?, val summary: PackUpdateSummary) : PackUpdateOutcome

    enum class Reason { OFFLINE, RATE_LIMITED, SERVER, PARTIAL, UNKNOWN }

    companion object {
        /** Yenileme sonucu; [error] liste alınamadıysa (ya da başka bir hata) dolu. */
        fun of(before: List<Pair<String, Int>>, result: PackStore.Refresh?, error: Throwable?): PackUpdateOutcome {
            val summary = PackUpdateSummary.of(before, result?.downloadedPacks.orEmpty())
            if (error != null) {
                val status = (error as? PackDownloadException)?.status
                val reason = when {
                    error !is PackDownloadException -> Reason.UNKNOWN
                    status == null -> Reason.OFFLINE
                    status == 429 -> Reason.RATE_LIMITED
                    else -> Reason.SERVER
                }
                return Failed(reason, status, summary)
            }
            if (result != null && result.failed.isNotEmpty()) {
                return Failed(if (result.offline) Reason.OFFLINE else Reason.PARTIAL, null, summary)
            }
            return if (summary.isEmpty) UpToDate else Updated(summary)
        }
    }
}
