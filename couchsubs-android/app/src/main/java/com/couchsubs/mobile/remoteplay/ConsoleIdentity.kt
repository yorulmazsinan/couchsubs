// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.remoteplay

import com.couchsubs.mobile.account.Backend

/**
 * Kayıtlı PS5'i ağda tanıma kuralı (Mac/iPhone ve Windows `ConsoleIdentity` ile aynı).
 *
 * PS5'in değişmeyen kimliği keşif yanıtındaki `host-id`'dir (PS5'in MAC adresi, 12 onaltılık hane; kayıtta PS5'in bildirdiği
 * MAC ile aynı). Eskiden PS5 yalnız adıyla eşleniyordu: ad değişince yeni adreste bulunamıyor, aynı adlı iki PS5'te emin
 * olunamıyordu. Kimliği bilinen kayıt kimlikle eşlenir; eski kayıtta (kimlik yok) ad kuralı geçerlidir ve PS5 adıyla bir kez
 * bulununca kimliği kayda yazılır.
 */
object ConsoleIdentity {
    /** Kimliğin karşılaştırılan biçimi: yalnız onaltılık haneler, büyük harf. Boş ya da tamamı sıfır kimlik null. */
    fun normalized(raw: String?): String? {
        if (raw == null) return null
        val hex = raw.uppercase().filter { it in '0'..'9' || it in 'A'..'F' }
        return if (hex.isEmpty() || hex.all { it == '0' }) null else hex
    }

    /** Kayıt yanıtındaki MAC'ten (6 bayt) kimlik; boşsa null. */
    fun fromMac(mac: ByteArray?): String? =
        mac?.take(6)?.joinToString("") { "%02X".format(it.toInt() and 0xFF) }?.let(::normalized)

    /**
     * Aramaya yanıt veren PS5 kayıtlı PS5 mi: iki tarafta da kimlik varsa kimlik (ad bakılmaz), yoksa ad (boşluk ve harf
     * büyüklüğü gözetilmez; kayıtta ad yoksa her yanıt kabul edilir).
     */
    fun isRegistered(info: ConsoleInfo, console: RegisteredConsole): Boolean {
        val wanted = console.hostId
        val found = info.hostId
        return if (wanted != null && found != null) wanted == found else matchesName(info, console.name)
    }

    fun matchesName(info: ConsoleInfo, name: String): Boolean =
        name.isBlank() || info.name.trim().equals(name.trim(), ignoreCase = true)

    /** Ağda bulunanlar arasından kayıtlı PS5 (tek eşleşen); emin olunamazsa null (başka PS5'e geçilmez, GitHub #425). */
    fun pickMoved(found: List<ConsoleInfo>, console: RegisteredConsole): ConsoleInfo? =
        found.filter { isRegistered(it, console) }.singleOrNull()

    /**
     * Eşleşen yanıttan öğrenilenlerle kayıt: yeni adres, (eski kayıtta) kimlik ve kimlikle eşlendiyse PS5'in yeni adı.
     * Değişen bir şey yoksa null.
     */
    fun updated(console: RegisteredConsole, info: ConsoleInfo): RegisteredConsole? {
        val byId = console.hostId != null && console.hostId == info.hostId
        // Ad yalnız gerçekten değiştiyse yazılır (harf ya da boşluk farkı değişiklik sayılmaz).
        val renamed = byId && info.name.isNotBlank() && !matchesName(info, console.name)
        val name = if (renamed) info.name.trim() else console.name
        val hostId = console.hostId ?: info.hostId
        if (info.host == console.host && hostId == console.hostId && name == console.name) return null
        return RegisteredConsole(info.host, name, console.registKey, console.morning, hostId)
    }

    /** Kayıt güncellenince günlüğe giden satır (Mac ve Windows'ta aynı metin). */
    fun changeLine(old: RegisteredConsole, new: RegisteredConsole): String {
        val parts = mutableListOf<String>()
        if (old.host != new.host)
            parts += "PS5 yeni adreste bulundu: ${old.host} → ${new.host} (${if (old.hostId != null) "host-id ile" else "adıyla"})"
        if (old.hostId == null && new.hostId != null) parts += "PS5 kimliği kayda yazıldı: ${new.hostId}"
        if (old.name != new.name) parts += "PS5'in adı değişmiş: ${old.name} → ${new.name}"
        return parts.joinToString("; ")
    }
}

/**
 * Tüm ağı tarayarak PS5 araması ne zaman yapılır (Mac ve Windows `RelocateSchedule` ile aynı). Tarama pahalı (/24 ağın
 * bütün adresleri, 3 sn); PS5 kapalıyken her denemede yapılmaz. Eskiden iki tarama arası hep 30 sn'ydi; artık bağlantı kopunca
 * ilk denemede hemen, sonra 10 sn, 30 sn, 1 dk, 2 dk, sonra 5 dk arayla taranır (#1366: PS5 bulunamadıkça tarama seyrelir).
 * PS5 bulununca sıra baştan başlar.
 */
class RelocateSchedule {
    companion object {
        val DELAYS_MS = longArrayOf(0L, 10_000L, 30_000L, 60_000L, 120_000L, 300_000L)
    }

    private var next = 0L
    private var misses = 0

    fun isDue(nowMs: Long) = nowMs >= next

    /** Tarama bitti: PS5 bulunduysa sonraki tarama hemen yapılabilir, bulunamadıysa bekleme uzar. */
    fun searched(found: Boolean, nowMs: Long) {
        if (found) {
            misses = 0
            next = 0L
        } else {
            misses++
            next = nowMs + DELAYS_MS[minOf(misses, DELAYS_MS.size - 1)]
        }
    }

    /** Bağlantı başarısız oldu (akış koptu ya da PS5 bağlantıyı reddetti): sonraki denemede beklemeden taranır. */
    fun connectionFailed() {
        misses = 0
        next = 0L
    }
}

/**
 * Kayıtlı PS5'i bulur: önce kayıtlı adreste, yanıt yoksa ya da yanıt veren başka bir PS5'se ağda (kimlikle). Oturum dışında da
 * kullanılır (çalışan oyun yoklaması); kayıt değişirse [onChange] çağrılır. [discover] `null` için tüm ağı, adres için yalnız o
 * adresi sorar (bloklar).
 */
class ConsoleFinder(
    console: RegisteredConsole,
    private val discover: (String?) -> List<ConsoleInfo> = { host -> ConsoleDiscovery.discover(host, if (host == null) 3000 else 2000) },
    private val log: (String) -> Unit = { Backend.breadcrumb(it) },
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val lock = Any()
    private val schedule = RelocateSchedule()
    private var current = console
    @Volatile var onChange: (RegisteredConsole) -> Unit = {}

    val console: RegisteredConsole get() = synchronized(lock) { current }

    fun connectionFailed() = synchronized(lock) { schedule.connectionFailed() }

    data class Located(val info: ConsoleInfo?, val atHost: ConsoleInfo?)

    /**
     * Kayıtlı adresi sorar. Yanıt veren kayıtlı PS5'se o (eski kayıtta kimliği öğrenilir). Değilse, [sweep] açıksa ve tarama
     * zamanıysa ağ taranır. [Located.atHost]: kayıtlı adreste yanıt veren (başka PS5 olabilir). Bloklar. `sweep = false`: ağ
     * hiç taranmaz (bağlıyken çalışan oyun yoklaması, #1366).
     */
    fun locate(sweep: Boolean = true): Located {
        val saved = console
        val atHost = discover(saved.host).firstOrNull()
        if (atHost != null && ConsoleIdentity.isRegistered(atHost, saved)) {
            learn(atHost)
            return Located(atHost, atHost)
        }
        if (atHost != null)
            log("PS5: ${saved.host} adresinde başka PS5 yanıt verdi (${atHost.name})" + if (sweep) ", ${saved.name} ağda aranıyor" else "")
        return Located(if (sweep) relocate() else null, atHost)
    }

    /** Ağı tarar (zamanı geldiyse); kayıtlı PS5 bulunursa kayıt güncellenir. */
    fun relocate(): ConsoleInfo? {
        if (!synchronized(lock) { schedule.isDue(clock()) }) return null
        val moved = ConsoleIdentity.pickMoved(discover(null), console)
        synchronized(lock) { schedule.searched(moved != null, clock()) }
        moved?.let(::learn)
        return moved
    }

    private fun learn(info: ConsoleInfo) {
        val change = synchronized(lock) {
            val old = current
            ConsoleIdentity.updated(old, info)?.also { current = it }?.let { old to it }
        } ?: return
        log(ConsoleIdentity.changeLine(change.first, change.second))
        onChange(change.second)
    }
}
