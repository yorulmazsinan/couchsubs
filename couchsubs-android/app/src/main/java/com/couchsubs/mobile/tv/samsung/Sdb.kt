// SPDX-License-Identifier: AGPL-3.0-only
// sdb protokolü TizenSdb.Core'dan (MIT, Patrick Stel) Kotlin'e taşındı: https://github.com/PatrickSt1991/tizen-sdb
// (masaüstü uygulamaları aynı kütüphaneyi NuGet'ten kullanır; windows/src/CouchSubs.TvInstall).
package com.couchsubs.mobile.tv.samsung

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.RSAPrivateCrtKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.RSAPublicKeySpec
import java.util.Base64

/** sdb (ADB'nin Tizen'deki karşılığı) çerçevesi: 24 baytlık küçük-endian başlık ve veri. */
class SdbFrame(val command: Int, val arg0: Int, val arg1: Int, val payload: ByteArray = ByteArray(0)) {
    companion object {
        const val CNXN = 0x4E584E43
        const val AUTH = 0x48545541
        const val OPEN = 0x4E45504F
        const val OKAY = 0x59414B4F
        const val WRTE = 0x45545257
        const val CLSE = 0x45534C43
        const val HEADER = 24

        /** Verinin bayt toplamı (sdb'nin denetim toplamı). */
        fun checksum(payload: ByteArray): Int {
            var sum = 0
            for (b in payload) sum += b.toInt() and 0xFF
            return sum
        }

        fun encode(frame: SdbFrame): ByteArray {
            val buffer = ByteBuffer.allocate(HEADER + frame.payload.size).order(ByteOrder.LITTLE_ENDIAN)
            buffer.putInt(frame.command).putInt(frame.arg0).putInt(frame.arg1)
                .putInt(frame.payload.size).putInt(checksum(frame.payload)).putInt(frame.command xor -1)
            buffer.put(frame.payload)
            return buffer.array()
        }

        /** Akıştan bir çerçeve okur; başlık ya da toplam bozuksa [IOException]. */
        fun read(input: InputStream): SdbFrame {
            val header = readExactly(input, HEADER)
            val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            val command = buffer.int
            val arg0 = buffer.int
            val arg1 = buffer.int
            val length = buffer.int
            val sum = buffer.int
            val magic = buffer.int
            if (length < 0 || length > 16 * 1024 * 1024) throw IOException("sdb: geçersiz uzunluk $length")
            val payload = if (length > 0) readExactly(input, length) else ByteArray(0)
            if (magic != command xor -1) throw IOException("sdb: geçersiz çerçeve (komut %08X)".format(command))
            if (sum != checksum(payload)) throw IOException("sdb: denetim toplamı tutmuyor")
            return SdbFrame(command, arg0, arg1, payload)
        }

        private fun readExactly(input: InputStream, size: Int): ByteArray {
            val result = ByteArray(size)
            var read = 0
            while (read < size) {
                val n = input.read(result, read, size - read)
                if (n < 0) throw EOFException("TV bağlantıyı kapattı")
                read += n
            }
            return result
        }

        /** sync: alt protokolünün paketi: 4 harfli kimlik, küçük-endian uzunluk, veri. */
        fun syncPacket(id: String, payload: ByteArray, offset: Int = 0, length: Int = payload.size): ByteArray {
            val buffer = ByteBuffer.allocate(8 + length).order(ByteOrder.LITTLE_ENDIAN)
            buffer.put(id.toByteArray(Charsets.US_ASCII)).putInt(length).put(payload, offset, length)
            return buffer.array()
        }

        /** `capability:` yanıtı: ilk iki bayt uzunluk, sonra `anahtar:değer` satırları. */
        fun parseCapability(bytes: ByteArray): Map<String, String> {
            if (bytes.size < 2) return emptyMap()
            val result = linkedMapOf<String, String>()
            for (line in String(bytes, 2, bytes.size - 2, Charsets.UTF_8).split('\n')) {
                val parts = line.split(':').filter { it.isNotEmpty() }
                if (parts.size == 2 && parts[0] !in result) result[parts[0]] = parts[1]
            }
            return result
        }
    }
}

/**
 * sdb istemcisi. TizenSdb arka planda çerçeve okuyan bir döngüyle aynı anda birçok kanal açar; kurulum komutları sırayla
 * çalıştığı için burada bir anda tek kanal açıktır ve çerçeveler çağıranın iş parçacığında okunur.
 */
class SdbConnection private constructor(private val socket: Socket, private val key: AdbKey) : Closeable {
    private val input = socket.getInputStream().buffered()
    private val output: OutputStream = socket.getOutputStream()
    private var nextLocalId = 'a'.code
    var maxData = 4096
        private set
    var banner = ""
        private set

    companion object {
        const val PORT = 26101
        private const val VERSION = 0x01000000
        private const val AUTH_TOKEN = 1
        private const val AUTH_SIGNATURE = 2
        private const val AUTH_PUBLICKEY = 3
        private const val SYNC_MAX_DATA = 64 * 1024

        /**
         * Bağlanır. Samsung'un sdbd'si yeni açılmış bağlantıyı el sıkışmanın ortasında bazen kapatır (özellikle bir
         * öncekinin hemen ardından); TizenSdb gibi üç kez denenir.
         */
        fun connect(host: String, key: AdbKey, port: Int = PORT, timeoutMs: Int = 10_000): SdbConnection {
            var last: Exception? = null
            repeat(3) { attempt ->
                val socket = Socket()
                try {
                    socket.connect(InetSocketAddress(host, port), timeoutMs)
                    socket.soTimeout = 120_000
                    socket.tcpNoDelay = true
                    return SdbConnection(socket, key).also { it.handshake() }
                } catch (error: IOException) {
                    last = error
                    runCatching { socket.close() }
                    if (attempt < 2) Thread.sleep(400)
                }
            }
            throw last ?: IOException("sdb bağlantısı kurulamadı")
        }
    }

    private fun send(frame: SdbFrame) {
        output.write(SdbFrame.encode(frame))
        output.flush()
    }

    private fun handshake() {
        send(SdbFrame(SdbFrame.CNXN, VERSION, maxData, "host::sdb-net-client".toByteArray(Charsets.UTF_8)))
        while (true) {
            val reply = SdbFrame.read(input)
            when (reply.command) {
                SdbFrame.CNXN -> {
                    val offered = reply.arg1
                    if (offered > 0) maxData = minOf(maxData, offered)
                    banner = String(reply.payload, Charsets.UTF_8)
                    return
                }
                SdbFrame.AUTH -> when (reply.arg0) {
                    AUTH_TOKEN -> send(SdbFrame(SdbFrame.AUTH, AUTH_SIGNATURE, 0, key.sign(reply.payload)))
                    AUTH_PUBLICKEY -> send(SdbFrame(SdbFrame.AUTH, AUTH_PUBLICKEY, 0, key.publicKeyPayload()))
                    else -> throw IOException("sdb: bilinmeyen AUTH türü ${reply.arg0}")
                }
                else -> throw IOException("sdb: CNXN ya da AUTH bekleniyordu")
            }
        }
    }

    /** Açık bir sdb kanalı. TV'nin verisi sırayla [read] ile alınır. */
    inner class Channel(val localId: Int, val service: String) : Closeable {
        var remoteId = 0
        private val pending = ArrayDeque<ByteArray>()
        private var acked = false
        var closed = false
            private set

        /** TV'nin gönderdiği bir sonraki parça; kanal kapandıysa null. */
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

        /** Veriyi [maxData]'lık parçalarla yazar; TV her parçayı OKAY ile onaylar. */
        fun write(data: ByteArray) {
            var offset = 0
            while (offset < data.size) {
                if (closed) throw IOException("sdb: TV kanalı kapattı")
                val size = minOf(maxData, data.size - offset)
                acked = false
                send(SdbFrame(SdbFrame.WRTE, localId, remoteId, data.copyOfRange(offset, offset + size)))
                while (!acked) {
                    if (closed) throw IOException("sdb: TV kanalı kapattı")
                    pump()
                }
                offset += size
            }
        }

        /** Tam [size] bayt okur (sync yanıtları için). */
        fun readExactly(size: Int): ByteArray {
            val result = ByteArrayOutputStream(size)
            while (result.size() < size) {
                val chunk = read() ?: throw EOFException("sdb: kanal erken kapandı")
                val need = size - result.size()
                if (chunk.size <= need) result.write(chunk)
                else {
                    result.write(chunk, 0, need)
                    pending.addFirst(chunk.copyOfRange(need, chunk.size))
                }
            }
            return result.toByteArray()
        }

        /** Bir çerçeve okur ve bu kanala ya da başkasına göre işler. */
        internal fun pump() {
            val frame = SdbFrame.read(input)
            when (frame.command) {
                SdbFrame.OKAY -> if (frame.arg1 == localId) {
                    if (remoteId == 0) remoteId = frame.arg0 else acked = true
                }
                SdbFrame.WRTE -> if (frame.arg1 == localId) {
                    // TV kanal açılmadan önce de yazabilir (TizenSdb'deki not); veri saklanır.
                    if (remoteId == 0) remoteId = frame.arg0
                    pending.addLast(frame.payload)
                    send(SdbFrame(SdbFrame.OKAY, localId, frame.arg0))
                } else send(SdbFrame(SdbFrame.CLSE, frame.arg1, frame.arg0))
                SdbFrame.CLSE -> if (frame.arg1 == localId) {
                    closed = true
                    runCatching { send(SdbFrame(SdbFrame.CLSE, localId, frame.arg0)) }
                }
                SdbFrame.OPEN -> send(SdbFrame(SdbFrame.CLSE, frame.arg1, frame.arg0))
                else -> Unit
            }
        }

        override fun close() {
            if (closed) return
            closed = true
            runCatching { send(SdbFrame(SdbFrame.CLSE, localId, remoteId)) }
        }
    }

    /** Kanal açar ve TV'nin onayını (OKAY) bekler. */
    fun open(service: String): Channel {
        val channel = Channel(++nextLocalId, service)
        send(SdbFrame(SdbFrame.OPEN, channel.localId, 0, service.toByteArray(Charsets.US_ASCII)))
        while (channel.remoteId == 0) {
            if (channel.closed) throw IOException("sdb: TV kanalı açmadı ($service)")
            channel.pump()
        }
        return channel
    }

    /** Kabuk komutu çalıştırır ve bütün çıktısını döner (TizenSdb'deki gibi `shell:` hizmeti). */
    fun shell(command: String): String = open("shell:$command\u0000").use { String(it.readAll(), Charsets.UTF_8) }

    fun capability(): Map<String, String> = open("capability:\u0000").use { SdbFrame.parseCapability(it.readAll()) }

    /** Dosyayı TV'ye gönderir (sync: SEND, DATA…, DONE; TV OKAY ya da FAIL döner). */
    fun push(data: ByteArray, remotePath: String) {
        open("sync:\u0000").use { channel ->
            channel.write(SdbFrame.syncPacket("SEND", remotePath.toByteArray(Charsets.UTF_8)))
            var offset = 0
            while (offset < data.size) {
                val size = minOf(SYNC_MAX_DATA, data.size - offset)
                channel.write(SdbFrame.syncPacket("DATA", data, offset, size))
                offset += size
            }
            val mtime = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt((System.currentTimeMillis() / 1000).toInt()).array()
            channel.write(SdbFrame.syncPacket("DONE", mtime))
            while (true) {
                val header = channel.readExactly(8)
                val id = String(header, 0, 4, Charsets.US_ASCII)
                val length = ByteBuffer.wrap(header, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
                val payload = if (length > 0) channel.readExactly(length) else ByteArray(0)
                when (id) {
                    "OKAY" -> return
                    "FAIL" -> throw IOException("sdb sync: FAIL: ${String(payload, Charsets.UTF_8).ifEmpty { "unknown" }}")
                }
            }
        }
    }

    override fun close() {
        runCatching { socket.close() }
    }
}

/**
 * sdb'nin (ADB gibi) kimlik doğrulama anahtarı: 2048 bit RSA, uygulamanın kendi klasöründe saklanır. Çoğu Samsung TV
 * istemez; isteyen TV'ye imza ve Android biçiminde açık anahtar gönderilir.
 */
class AdbKey(private val privateKey: PrivateKey, val publicKey: RSAPublicKey) {
    // Android TV kurulumu da (tv/android) aynı anahtar biçimini kullanır; anahtar dosyası ayrıdır.
    companion object {
        /**
         * Anahtar kalıcıdır: TV onayı bu anahtara verilir, değişirse TV "hata ayıklamaya izin verilsin mi?" diye yeniden
         * sorar. Dosya okunamıyorsa (G/Ç hatası) yenisi üretilmez, hata yükselir; yalnız bozuk dosyanın yerine yenisi yazılır.
         * Yazma atomiktir (yarım kalan yazma anahtarı bozmasın); aynı anda iki çağrı (güncelleme denetimi ve bekçi) iki ayrı
         * anahtar üretmesin diye eşzamanlanır.
         */
        @Synchronized fun loadOrCreate(file: File): AdbKey {
            val factory = KeyFactory.getInstance("RSA")
            if (file.exists()) {
                val bytes = file.readBytes()
                runCatching {
                    val key = factory.generatePrivate(PKCS8EncodedKeySpec(bytes)) as RSAPrivateCrtKey
                    val publicKey = factory.generatePublic(RSAPublicKeySpec(key.modulus, key.publicExponent)) as RSAPublicKey
                    return AdbKey(key, publicKey)
                }
            }
            val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
            file.parentFile?.mkdirs()
            val temporary = File(file.path + ".tmp")
            temporary.writeBytes(pair.private.encoded)
            if (!temporary.renameTo(file)) {
                file.writeBytes(pair.private.encoded)
                temporary.delete()
            }
            return AdbKey(pair.private, pair.public as RSAPublicKey)
        }

        /**
         * Android'in RSAPublicKey yapısı: sözcük sayısı, n0inv, modül ve R² (küçük-endian 256 bayt), üs. TizenSdb'deki
         * EncodePublicKey'in aynısı.
         */
        fun encodePublicKey(key: RSAPublicKey): ByteArray {
            val size = 256
            val n = key.modulus
            val r32 = BigInteger.ONE.shiftLeft(32)
            val n0inv = r32.subtract(n.mod(r32).modInverse(r32))
            val rr = BigInteger.ONE.shiftLeft(size * 8).modPow(BigInteger.valueOf(2), n)
            val buffer = ByteBuffer.allocate(4 + 4 + size + size + 4).order(ByteOrder.LITTLE_ENDIAN)
            buffer.putInt(size / 4).putInt(n0inv.toInt())
            buffer.put(littleEndian(n, size)).put(littleEndian(rr, size))
            buffer.putInt(key.publicExponent.toInt())
            return buffer.array()
        }

        private fun littleEndian(value: BigInteger, size: Int): ByteArray {
            val big = value.toByteArray()
            val result = ByteArray(size)
            for (i in 0 until minOf(size, big.size)) result[i] = big[big.size - 1 - i]
            return result
        }
    }

    /** TV'nin gönderdiği jetonu imzalar (TizenSdb: RSA-SHA1, PKCS#1). */
    fun sign(token: ByteArray): ByteArray =
        Signature.getInstance("SHA1withRSA").run { initSign(privateKey); update(token); sign() }

    fun publicKeyPayload(): ByteArray = (publicKeyLine("couchsubs@android") + "\u0000").toByteArray(Charsets.US_ASCII)

    /** adb'nin açık anahtar satırı: Android biçimindeki anahtarın base64'ü ve "kullanıcı@cihaz" (sonda NUL yok). */
    fun publicKeyLine(name: String): String = Base64.getEncoder().encodeToString(encodePublicKey(publicKey)) + " " + name

    /** Android TV'nin TLS'i (kablosuz hata ayıklama) için PKCS#8 özel anahtar. */
    internal fun privateKeyBytes(): ByteArray = privateKey.encoded

    /**
     * adb'nin imzası (adbd auth.cpp, RSA_sign NID_sha1): TV'nin 20 baytlık jetonu SHA-1 özeti yerine geçer, yeniden
     * özetlenmez. PKCS#1 v1.5 dolgusu ve SHA-1 DigestInfo önekiyle jetonun kendisi imzalanır. ([sign] jetonu özetler;
     * Samsung'un sdbd'si onu bekler.)
     */
    fun signAdbToken(token: ByteArray): ByteArray {
        val key = privateKey as RSAPrivateCrtKey
        val size = (key.modulus.bitLength() + 7) / 8
        val digestInfo = byteArrayOf(0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14) + token
        require(digestInfo.size <= size - 11) { "jeton çok uzun" }
        val block = ByteArray(size)
        block[1] = 0x01
        for (i in 2 until size - digestInfo.size - 1) block[i] = 0xFF.toByte()
        digestInfo.copyInto(block, size - digestInfo.size)
        val signature = BigInteger(1, block).modPow(key.privateExponent, key.modulus).toByteArray()
        // Baştaki işaret baytı atılır, kısa çıkarsa sıfırla doldurulur.
        val result = ByteArray(size)
        val start = maxOf(0, signature.size - size)
        signature.copyInto(result, size - (signature.size - start), start)
        return result
    }
}
