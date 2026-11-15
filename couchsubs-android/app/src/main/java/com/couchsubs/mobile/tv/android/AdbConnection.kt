// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki AdbConnection.cs'in (windows/src/CouchSubs.TvInstall/Android) telefon karşılığı. Protokol: AOSP
// packages/modules/adb (protocol.txt). Google'ın adb aracı dağıtılmaz.
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.samsung.AdbKey
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Android TV kurulumunda çıkan sorunlar; arayüz her birine ne yapılacağını söyler (masaüstündeki DevModeError). */
enum class AndroidInstallError {
    /** TV yanıt vermedi ya da ağ hata ayıklaması kapalı. */
    UNREACHABLE,
    /** TV'de "hata ayıklamaya izin verilsin mi" sorusu onaylanmadı. */
    NOT_APPROVED,
    /** Kablosuz hata ayıklama portu bu telefonu tanımıyor: önce eşleme kodu ile eşlenmeli. */
    NOT_PAIRED,
    /** Eşleme kodu yanlış ya da eşleme penceresi kapandı. */
    PAIRING_FAILED,
    /** TV'deki kopya başka anahtarla imzalı (ör. Google Play'den); kaldırılmadan güncellenemez. Kullanıcı onaylarsa kaldırılır. */
    REPLACE_NEEDED,
    NOT_ENOUGH_SPACE,
    INSTALL_FAILED,
    CONNECTION_LOST,
    /** Bu telefon uygulamasının içinde TV paketi yok (derlemede indirilemedi). */
    PACKAGE_MISSING,
}

class AndroidInstallException(val error: AndroidInstallError, val detail: String? = null, val installedFromPlay: Boolean = false) :
    IOException(if (detail == null) error.name else "${error.name}: $detail")

/** ADB çerçevesi: 24 baytlık küçük-endian başlık ve veri (sdb'yle aynı biçim; denetim toplamına bakılmaz). */
class AdbPacket(val command: Int, val arg0: Int, val arg1: Int, val payload: ByteArray = ByteArray(0)) {
    companion object {
        const val CNXN = 0x4E584E43
        const val AUTH = 0x48545541
        const val OPEN = 0x4E45504F
        const val OKAY = 0x59414B4F
        const val WRTE = 0x45545257
        const val CLSE = 0x45534C43
        const val STLS = 0x534C5453
        private const val MAX_PAYLOAD = 1024 * 1024

        fun encode(packet: AdbPacket): ByteArray {
            var sum = 0
            for (b in packet.payload) sum += b.toInt() and 0xFF
            return ByteBuffer.allocate(24 + packet.payload.size).order(ByteOrder.LITTLE_ENDIAN)
                .putInt(packet.command).putInt(packet.arg0).putInt(packet.arg1).putInt(packet.payload.size)
                .putInt(sum).putInt(packet.command xor -1).put(packet.payload).array()
        }

        /**
         * Akıştan bir çerçeve okur. 0x01000001 ve sonraki adbd'ler denetim toplamını 0 gönderir; yalnız sihirli sayı
         * ve uzunluk denetlenir.
         */
        fun read(input: InputStream): AdbPacket {
            val header = readExactly(input, 24)
            val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val command = buffer.int
            val arg0 = buffer.int
            val arg1 = buffer.int
            val length = buffer.int
            buffer.int
            val magic = buffer.int
            if (magic != command xor -1 || length < 0 || length > MAX_PAYLOAD) throw IOException("ADB paketi bozuk")
            return AdbPacket(command, arg0, arg1, if (length > 0) readExactly(input, length) else ByteArray(0))
        }

        internal fun readExactly(input: InputStream, size: Int): ByteArray {
            val result = ByteArray(size)
            var read = 0
            while (read < size) {
                val n = input.read(result, read, size - read)
                if (n < 0) throw EOFException("TV bağlantıyı kapattı")
                read += n
            }
            return result
        }
    }
}

/**
 * ADB istemcisi: bağlantı, RSA kimlik doğrulama (TV'de onay sorusu), kablosuz hata ayıklamada TLS ve sırayla açılan
 * kanallar. Çağrılar bloklar; IO iş parçacığında çalışır.
 */
class AdbConnection private constructor(private val socket: Socket) : Closeable {
    private var input: InputStream = socket.getInputStream().buffered()
    private var output: OutputStream = socket.getOutputStream()
    private var tls: AdbTlsClient.Session? = null
    private var nextLocalId = 1
    var maxData = 4096
        private set

    /** Bağlantı TLS'li mi (kablosuz hata ayıklama portu)? */
    val secure get() = tls != null

    companion object {
        const val DEFAULT_PORT = 5555
        internal const val VERSION = 0x01000001
        internal const val STLS_VERSION = 0x01000000
        private const val OFFERED_MAX_DATA = 256 * 1024
        private const val AUTH_TOKEN = 1
        private const val AUTH_SIGNATURE = 2
        private const val AUTH_PUBLICKEY = 3
        const val KEY_NAME = "couchsubs@phone"

        /**
         * Bağlanır ve TV'nin onayını alır.
         * @param onApprovalNeeded TV bu telefonu ilk kez görüyor; ekranda "hata ayıklamaya izin verilsin mi" sorusu çıktı.
         * @param approvalTimeoutMs Kullanıcının TV'de onaylaması için tanınan süre.
         */
        fun connect(host: String, port: Int, key: AdbKey, onApprovalNeeded: () -> Unit = {}, approvalTimeoutMs: Int = 90_000,
                    connectTimeoutMs: Int = 5_000): AdbConnection {
            val socket = Socket()
            try {
                socket.connect(InetSocketAddress(host, port), connectTimeoutMs)
                socket.tcpNoDelay = true
            } catch (error: IOException) {
                runCatching { socket.close() }
                throw AndroidInstallException(AndroidInstallError.UNREACHABLE, "$host:$port: ${error.message}")
            }
            val connection = AdbConnection(socket)
            try {
                connection.handshake(key, onApprovalNeeded, approvalTimeoutMs)
                return connection
            } catch (error: Exception) {
                connection.close()
                throw error
            }
        }
    }

    private fun send(packet: AdbPacket) {
        output.write(AdbPacket.encode(packet))
        output.flush()
    }

    private fun handshake(key: AdbKey, onApprovalNeeded: () -> Unit, approvalTimeoutMs: Int) {
        socket.soTimeout = 10_000
        send(AdbPacket(AdbPacket.CNXN, VERSION, OFFERED_MAX_DATA, "host::\u0000".toByteArray(Charsets.US_ASCII)))
        var signed = false
        var waitingForApproval = false
        while (true) {
            val packet = try {
                AdbPacket.read(input)
            } catch (error: IOException) {
                // Onay beklenirken bağlantı kapandıysa ya da süre dolduysa kullanıcı izin vermedi. TLS'ten sonra kapandıysa
                // TV bu telefonun sertifikasını tanımadı (TLS 1.3'te istemci el sıkışmayı TV'den önce bitirir).
                val kind = when {
                    tls != null -> AndroidInstallError.NOT_PAIRED
                    waitingForApproval -> AndroidInstallError.NOT_APPROVED
                    else -> AndroidInstallError.UNREACHABLE
                }
                throw AndroidInstallException(kind, error.message ?: error.javaClass.simpleName)
            }
            when {
                packet.command == AdbPacket.CNXN -> {
                    maxData = minOf(OFFERED_MAX_DATA, if (packet.arg1 <= 0) 4096 else packet.arg1)
                    socket.soTimeout = 120_000
                    return
                }
                packet.command == AdbPacket.STLS -> {
                    // Kablosuz hata ayıklama portu: TV yalnız eşleştirmede öğrendiği anahtarın sertifikasını kabul eder.
                    send(AdbPacket(AdbPacket.STLS, STLS_VERSION, 0))
                    val session = try {
                        AdbTlsClient.connect(input, output, key)
                    } catch (error: IOException) {
                        throw AndroidInstallException(AndroidInstallError.NOT_PAIRED, "TLS: ${error.message}")
                    }
                    tls = session
                    input = session.input.buffered()
                    output = session.output
                }
                packet.command == AdbPacket.AUTH && packet.arg0 == AUTH_TOKEN && !signed -> {
                    signed = true
                    send(AdbPacket(AdbPacket.AUTH, AUTH_SIGNATURE, 0, key.signAdbToken(packet.payload)))
                }
                packet.command == AdbPacket.AUTH && packet.arg0 == AUTH_TOKEN -> {
                    // İmza tanınmadı: TV bu anahtarı ilk kez görüyor. Açık anahtarı gönderince TV kullanıcıya sorar.
                    if (waitingForApproval) throw AndroidInstallException(AndroidInstallError.NOT_APPROVED, "TV anahtarı yine sordu")
                    send(AdbPacket(AdbPacket.AUTH, AUTH_PUBLICKEY, 0, (key.publicKeyLine(KEY_NAME) + "\u0000").toByteArray(Charsets.US_ASCII)))
                    waitingForApproval = true
                    socket.soTimeout = approvalTimeoutMs
                    onApprovalNeeded()
                }
                else -> throw AndroidInstallException(AndroidInstallError.UNREACHABLE, "beklenmeyen paket %08x".format(packet.command))
            }
        }
    }

    /** Açık bir kanal; TV'nin verisi sırayla [read] ile alınır. */
    inner class Channel(val localId: Int) : Closeable {
        var remoteId = 0
        private val pending = ArrayDeque<ByteArray>()
        private var acked = false
        var closed = false
            private set

        fun read(): ByteArray? {
            while (pending.isEmpty()) {
                if (closed) return null
                pump()
            }
            return pending.removeFirst()
        }

        fun readAll(): ByteArray {
            val all = ByteArrayOutputStream()
            while (true) all.write(read() ?: break)
            return all.toByteArray()
        }

        fun readExactly(size: Int): ByteArray {
            val result = ByteArrayOutputStream(size)
            while (result.size() < size) {
                val chunk = read() ?: throw EOFException("ADB: kanal erken kapandı")
                val need = size - result.size()
                if (chunk.size <= need) result.write(chunk)
                else {
                    result.write(chunk, 0, need)
                    pending.addFirst(chunk.copyOfRange(need, chunk.size))
                }
            }
            return result.toByteArray()
        }

        /** Veriyi [maxData]'lık parçalarla yazar; TV her parçayı OKAY ile onaylar. TV kanalı kapatırsa false. */
        fun write(data: ByteArray, offset: Int = 0, length: Int = data.size): Boolean {
            var position = offset
            val end = offset + length
            while (position < end) {
                if (closed) return false
                val size = minOf(maxData, end - position)
                acked = false
                send(AdbPacket(AdbPacket.WRTE, localId, remoteId, data.copyOfRange(position, position + size)))
                while (!acked) {
                    if (closed) return false
                    pump()
                }
                position += size
            }
            return true
        }

        internal fun pump() {
            val packet = AdbPacket.read(input)
            when (packet.command) {
                AdbPacket.OKAY -> if (packet.arg1 == localId) {
                    if (remoteId == 0) remoteId = packet.arg0 else acked = true
                }
                AdbPacket.WRTE -> if (packet.arg1 == localId) {
                    if (remoteId == 0) remoteId = packet.arg0
                    pending.addLast(packet.payload)
                    send(AdbPacket(AdbPacket.OKAY, localId, packet.arg0))
                } else send(AdbPacket(AdbPacket.CLSE, packet.arg1, packet.arg0))
                AdbPacket.CLSE -> if (packet.arg1 == localId || packet.arg1 == 0) {
                    closed = true
                    runCatching { send(AdbPacket(AdbPacket.CLSE, localId, packet.arg0)) }
                }
                else -> Unit
            }
        }

        override fun close() {
            if (closed) return
            closed = true
            runCatching { send(AdbPacket(AdbPacket.CLSE, localId, remoteId)) }
        }
    }

    /** Hizmet açar (`shell:…`, `exec:…`, `sync:`) ve TV'nin onayını bekler; açılmazsa [IOException]. */
    fun open(service: String): Channel {
        val channel = Channel(nextLocalId++)
        send(AdbPacket(AdbPacket.OPEN, channel.localId, 0, (service + "\u0000").toByteArray(Charsets.UTF_8)))
        while (channel.remoteId == 0) {
            if (channel.closed) throw IOException("ADB: TV hizmeti açmadı ($service)")
            channel.pump()
        }
        return channel
    }

    /** Hizmeti açar, varsa girdiyi gönderir ve hizmet kapanana kadar bütün çıktıyı döner. */
    fun run(service: String, data: ByteArray? = null): String = open(service).use { channel ->
        if (data != null) channel.write(data)
        String(channel.readAll(), Charsets.UTF_8)
    }

    /** Dosyayı TV'ye gönderir (sync: SEND "yol,kip", DATA…, DONE; TV OKAY ya da FAIL döner). */
    fun push(data: ByteArray, remotePath: String, mode: Int = 0x1A4) {
        open("sync:").use { channel ->
            fun packet(id: String, body: ByteArray, offset: Int = 0, length: Int = body.size): ByteArray =
                ByteBuffer.allocate(8 + length).order(ByteOrder.LITTLE_ENDIAN).put(id.toByteArray(Charsets.US_ASCII))
                    .putInt(length).put(body, offset, length).array()
            // Dosya kipi: normal dosya (0100000) ve izinler, onluk yazılır.
            channel.write(packet("SEND", "$remotePath,${0x8000 or mode}".toByteArray(Charsets.UTF_8)))
            var offset = 0
            while (offset < data.size) {
                val size = minOf(64 * 1024, data.size - offset)
                channel.write(packet("DATA", data, offset, size))
                offset += size
            }
            val time = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt((System.currentTimeMillis() / 1000).toInt()).array()
            // DONE'un uzunluk alanı değiştirilme zamanıdır; ardından veri yoktur.
            channel.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).put("DONE".toByteArray(Charsets.US_ASCII)).put(time).array())
            val header = channel.readExactly(8)
            val id = String(header, 0, 4, Charsets.US_ASCII)
            val length = ByteBuffer.wrap(header, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (id == "OKAY") return
            val message = if (id == "FAIL" && length in 1..4096) String(channel.readExactly(length), Charsets.UTF_8) else id
            throw IOException("ADB sync: FAIL: $message")
        }
    }

    override fun close() {
        tls?.close()
        runCatching { socket.close() }
    }
}
