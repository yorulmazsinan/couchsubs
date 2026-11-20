// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv

import com.couchsubs.mobile.settings.AppSettings
import com.couchsubs.mobile.core.SubtitleAccess
import okhttp3.*
import org.json.JSONObject
import org.json.JSONArray
import java.net.InetAddress
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

/** iPhone/Windows ile aynı oturum teslimi. Android TV yalnız kullanıcı onaylı /pair yolunu kullanır. */
object TvSessionLauncher {
    const val SAMSUNG_APP_ID = "CouchSubsT.CouchSubs"

    /**
     * Samsung'da `actionType` TV'nin uygulama listesinde bildirdiği türe göre seçilir ([samsungActionType]); bilinmiyorsa
     * DEEP_LINK.
     */
    fun launchMessage(brand: TvBrand, server: String, key: String, actionType: String = "DEEP_LINK"): String {
        val params = JSONObject().put("server", server).put("key", key)
        return if (brand == TvBrand.LG) JSONObject().put("type", "request").put("id", "launch_1")
            .put("uri", "ssap://system.launcher/launch").put("payload", JSONObject().put("id", "com.couchsubs.tv").put("params", params)).toString()
        else JSONObject().put("method", "ms.channel.emit").put("params", JSONObject().put("event", "ed.apps.launch").put("to", "host")
            .put("data", JSONObject().put("appId", SAMSUNG_APP_ID).put("action_type", actionType).put("metaTag", params.toString()))).toString()
    }

    /**
     * Samsung TV'de kurulu uygulamaların listesini ister; listede geliştirici modunda kurulan (mağazada olmayan)
     * uygulamalar da bulunur.
     */
    const val SAMSUNG_INSTALLED_APPS_REQUEST = """{"method":"ms.channel.emit","params":{"event":"ed.installedApp.get","to":"host"}}"""

    /** TV'nin kurulu uygulama listesine göre CouchSubs: yoksa [installed] false; varsa TV'nin bildirdiği `app_type`. */
    data class SamsungAppPresence(val installed: Boolean, val appType: Int?)

    /** Kurulu uygulama listesi yanıtında [appId] var mı; yanıt bu değilse null. */
    fun samsungInstalledApp(text: String, appId: String = SAMSUNG_APP_ID): SamsungAppPresence? = try {
        val message = JSONObject(text)
        val apps = message.optJSONObject("data")?.optJSONArray("data")
        if (message.optString("event") != "ed.installedApp.get" || apps == null) null
        else (0 until apps.length()).mapNotNull { apps.optJSONObject(it) }.firstOrNull { it.optString("appId") == appId }
            ?.let { SamsungAppPresence(true, if (it.has("app_type")) it.optInt("app_type") else null) }
            ?: SamsungAppPresence(false, null)
    } catch (_: Exception) { null }

    /**
     * `ed.apps.launch` açılış türü: `app_type` 4 (yerel Tizen uygulaması) NATIVE_LAUNCH, 2 (web uygulaması; CouchSubs .wgt)
     * ve bilinmeyen DEEP_LINK.
     */
    fun samsungActionType(appType: Int?): String = if (appType == 4) "NATIVE_LAUNCH" else "DEEP_LINK"
    fun registerMessage(key: String?): String {
        val payload = JSONObject().put("forcePairing", false).put("pairingType", "PROMPT")
            .put("manifest", JSONObject().put("manifestVersion", 1).put("appVersion", "1.0")
                .put("permissions", JSONArray(listOf("LAUNCH", "LAUNCH_WEBAPP", "APP_TO_APP", "READ_RUNNING_APPS", "READ_INSTALLED_APPS"))))
        if (!key.isNullOrEmpty()) payload.put("client-key", key)
        return JSONObject().put("type", "register").put("id", "register_0").put("payload", payload).toString()
    }
    fun launch(settings: AppSettings, port: Int, key: String, active: () -> Boolean) {
        val tv = settings.installedTv ?: return
        if (tv.brand == TvBrand.ANDROID_TV || !active()) return
        val remote = InetAddress.getByName(tv.host)
        if (!SubtitleAccess.isLocalPeer(remote)) return
        val own = DatagramSocket().use { it.connect(InetSocketAddress(remote, 9)); it.localAddress.hostAddress } ?: return
        val server = "http://${if (own.contains(':')) "[$own]" else own}:$port"
        val tokenKey = "tv.control.${tv.brand}.${tv.host}"
        val pinKey = "$tokenKey.certificate"
        val storedPin = settings.secrets.get(pinKey)
        var certificatePin: String? = null
        // TV sertifikaları kendinden imzalıdır. İlk TV izninden sonra sertifika parmak izi sabitlenir.
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = throw java.security.cert.CertificateException()
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw java.security.cert.CertificateException()
                val pin = MessageDigest.getInstance("SHA-256").digest(chain[0].publicKey.encoded).joinToString("") { "%02x".format(it.toInt() and 255) }
                if (storedPin != null && storedPin != pin) throw java.security.cert.CertificateException("TV certificate changed")
                certificatePin = pin
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
        val client = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS)
            .dns(object : Dns {
                override fun lookup(hostname: String): List<InetAddress> =
                    if (hostname == tv.host) listOf(remote) else throw java.net.UnknownHostException(hostname)
            })
            .sslSocketFactory(tls.socketFactory, trust).hostnameVerifier { host, _ -> host == tv.host }.build()
        val token = settings.secrets.get(tokenKey)
        val host = if (tv.host.contains(':')) "[${tv.host}]" else tv.host
        val urls = if (tv.brand == TvBrand.LG) listOf("wss://$host:3001", "ws://$host:3000") else listOf(
            "wss://$host:8002/api/v2/channels/samsung.remote.control?name=Q291Y2hTdWJz" + (token?.let { "&token=" + java.net.URLEncoder.encode(it, "UTF-8") } ?: ""))
        try {
            for (url in urls) {
                if (!active()) return
                val done = CountDownLatch(1)
                var registered = false
                var sent = false
                // Samsung: kurulu uygulama listesinin yanıtı bekleniyor mu. Yanıt 3 saniyede gelmezse eski yol (DEEP_LINK).
                val awaitingList = java.util.concurrent.atomic.AtomicBoolean(false)
                fun samsungLaunch(webSocket: WebSocket, presence: SamsungAppPresence?) {
                    if (!awaitingList.getAndSet(false)) return
                    // Kurulu değilken DEEP_LINK gönderilirse Smart Hub uygulamayı mağazada arıyor ve TV'de "Sunucu bakım
                    // altında (1544007)" çıkıyordu (#402, #511, #637); listede yoksa hiçbir şey gönderilmez.
                    if (presence?.installed != false) sent = webSocket.send(launchMessage(tv.brand, server, key, samsungActionType(presence?.appType)))
                    webSocket.close(1000, null)
                }
                val socket = client.newWebSocket(Request.Builder().url(url).build(), object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        if (!active()) { done.countDown(); return }
                        if (tv.brand == TvBrand.LG) webSocket.send(registerMessage(token))
                    }
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        try {
                            if (awaitingList.get()) {
                                samsungInstalledApp(text)?.let { samsungLaunch(webSocket, it) }
                                return
                            }
                            val message = JSONObject(text)
                            val approved = if (tv.brand == TvBrand.LG) message.optString("type") == "registered" else message.optString("event") == "ms.channel.connect"
                            if (approved && !registered && active()) {
                                registered = true
                                val received = if (tv.brand == TvBrand.LG) message.optJSONObject("payload")?.optString("client-key") else message.optJSONObject("data")?.optString("token")
                                if (!received.isNullOrEmpty()) settings.secrets.put(tokenKey, received)
                                certificatePin?.let { settings.secrets.put(pinKey, it) }
                                if (tv.brand == TvBrand.SAMSUNG) {
                                    awaitingList.set(true)
                                    if (!webSocket.send(SAMSUNG_INSTALLED_APPS_REQUEST)) samsungLaunch(webSocket, null)
                                    else Thread { Thread.sleep(3000); samsungLaunch(webSocket, null) }.apply { isDaemon = true }.start()
                                } else sent = webSocket.send(launchMessage(tv.brand, server, key))
                            } else if (message.optString("id") == "launch_1" || message.optString("type") == "error" || message.optString("event") in listOf("ms.channel.unauthorized", "ms.channel.timeOut")) done.countDown()
                        } catch (_: Exception) { done.countDown() }
                    }
                    override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { done.countDown() }
                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { done.countDown() }
                })
                try { done.await(60, TimeUnit.SECONDS) } finally { socket.close(1000, null); socket.cancel() }
                // Açılış başarısız olsa bile TV /pair ile onay isteyebilir; sürekli yeniden başlatma yok.
                if (registered || sent || storedPin != null) return
            }
        } finally { client.dispatcher.executorService.shutdown(); client.connectionPool.evictAll() }
    }
}
