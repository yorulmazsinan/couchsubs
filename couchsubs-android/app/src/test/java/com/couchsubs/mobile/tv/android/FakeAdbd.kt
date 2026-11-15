// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.samsung.AdbKey
import org.bouncycastle.crypto.util.PrivateKeyFactory
import org.bouncycastle.tls.Certificate
import org.bouncycastle.tls.CertificateEntry
import org.bouncycastle.tls.CertificateRequest
import org.bouncycastle.tls.DefaultTlsServer
import org.bouncycastle.tls.ProtocolVersion
import org.bouncycastle.tls.SignatureAndHashAlgorithm
import org.bouncycastle.tls.TlsCredentials
import org.bouncycastle.tls.TlsServerProtocol
import org.bouncycastle.tls.crypto.TlsCryptoParameters
import org.bouncycastle.tls.crypto.impl.bc.BcDefaultTlsCredentialedSigner
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.RSAPublicKey
import java.security.spec.RSAPublicKeySpec
import java.util.Base64
import java.util.Vector
import javax.crypto.Cipher
import kotlin.concurrent.thread

internal fun tempKey(name: String = "adbkey"): AdbKey =
    AdbKey.loadOrCreate(File(Files.createTempDirectory("adb").toFile(), name))

/** adb'nin açık anahtar satırını ("base64 ad") RSA açık anahtarına çevirir (android_pubkey.c'nin tersi). */
internal fun decodePublicKeyLine(line: String): RSAPublicKey {
    val blob = Base64.getDecoder().decode(line.substringBefore(' ').trim('\u0000'))
    val buffer = ByteBuffer.wrap(blob).order(ByteOrder.LITTLE_ENDIAN)
    val words = buffer.int
    buffer.int
    val modulus = ByteArray(words * 4).also { buffer.get(it) }
    buffer.position(buffer.position() + words * 4)
    val exponent = buffer.int
    val spec = RSAPublicKeySpec(BigInteger(1, modulus.reversedArray()), BigInteger.valueOf(exponent.toLong()))
    return KeyFactory.getInstance("RSA").generatePublic(spec) as RSAPublicKey
}

/** adbd'nin imza denetimi: RSA_verify(NID_sha1) — imza açılınca SHA-1 DigestInfo ve jetonun kendisi çıkmalı. */
internal fun adbSignatureValid(key: RSAPublicKey, token: ByteArray, signature: ByteArray): Boolean = try {
    val plain = Cipher.getInstance("RSA/ECB/PKCS1Padding").run { init(Cipher.DECRYPT_MODE, key); doFinal(signature) }
    plain.contentEquals(byteArrayOf(0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14) + token)
} catch (error: Exception) {
    false
}

/** Testlerin TLS 1.3 sunucusu (TV'nin adbd'si yerine); istemci sertifikası ister. */
internal class FakeTlsServer(private val tvKey: AdbKey) : DefaultTlsServer(BcTlsCrypto(SecureRandom())) {
    var clientCertificate: Certificate? = null

    override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv13.only()

    override fun getCredentials(): TlsCredentials {
        val crypto = crypto as BcTlsCrypto
        val chain = Certificate(ByteArray(0), arrayOf(CertificateEntry(crypto.createCertificate(AdbTlsClient.selfSignedCertificate(tvKey)), null)))
        return BcDefaultTlsCredentialedSigner(TlsCryptoParameters(context), crypto, PrivateKeyFactory.createKey(tvKey.privateKeyBytes()),
            chain, SignatureAndHashAlgorithm.rsa_pss_rsae_sha256)
    }

    override fun getCertificateRequest(): CertificateRequest {
        val algorithms = Vector<SignatureAndHashAlgorithm>().apply { add(SignatureAndHashAlgorithm.rsa_pss_rsae_sha256) }
        return CertificateRequest(ByteArray(0), algorithms, null, null)
    }

    override fun notifyClientCertificate(clientCertificate: Certificate) {
        this.clientCertificate = clientCertificate
    }

    /** BouncyCastle dışa aktarıma yalnız el sıkışma biterken izin verir. */
    var exported: ByteArray? = null

    override fun notifyHandshakeComplete() {
        super.notifyHandshakeComplete()
        exported = context.exportKeyingMaterial(AdbPairing.EXPORTED_KEY_LABEL, ByteArray(0), 64)
    }

    /** İstemci sertifikasındaki açık anahtarın SHA-256'sı (karşılaştırmak için). */
    fun clientKeyHash(): String? {
        val certificate = clientCertificate?.takeIf { !it.isEmpty } ?: return null
        val x509 = org.bouncycastle.asn1.x509.Certificate.getInstance(certificate.getCertificateAt(0).encoded)
        return sha256(x509.subjectPublicKeyInfo.encoded)
    }

    companion object {
        fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

        fun start(input: InputStream, output: OutputStream, tvKey: AdbKey): Pair<FakeTlsServer, TlsServerProtocol> {
            val server = FakeTlsServer(tvKey)
            val protocol = TlsServerProtocol(input, output)
            protocol.accept(server)
            return server to protocol
        }
    }
}

/**
 * Sahte Android TV adbd'si: bir bağlantıyı kabul eder, ADB el sıkışmasını (gerekirse onay ya da STLS) yapar ve açılan
 * hizmetlere [services]'in verdiği yanıtı yazar. Gelen veriler ve açılan hizmetler kaydedilir.
 */
internal class FakeAdbd(
    /** Önceden onaylanmış açık anahtarlar (TV'nin adb_keys'i). */
    val authorized: MutableList<RSAPublicKey> = mutableListOf(),
    /** Yeni anahtar gelince kullanıcı "İzin ver" der mi? */
    private val approve: Boolean = true,
    /** Kablosuz hata ayıklama portu gibi TLS ister. */
    private val tlsKey: AdbKey? = null,
    /** Hizmet adı (ve gelen veri) → TV'nin çıktısı. */
    private val services: (String, ByteArray) -> String = { _, _ -> "" },
    /** `exec:` hizmetine gelecek veri uzunluğu; bu kadar bayt gelince yanıt yazılır. */
    private val expectedInput: (String) -> Int = { service -> Regex("""-S (\d+)""").find(service)?.groupValues?.get(1)?.toInt() ?: 0 },
) {
    private val server = ServerSocket(0)
    val port get() = server.localPort
    val opened = mutableListOf<String>()
    val received = linkedMapOf<String, ByteArray>()
    var tlsClientKeyHash: String? = null
    var approvalAsked = false
    private var failure: Throwable? = null
    private lateinit var worker: Thread

    fun start(connections: Int = 1): FakeAdbd {
        worker = thread(isDaemon = true) {
            try {
                repeat(connections) { server.accept().use { serve(it.getInputStream(), it.getOutputStream()) } }
            } catch (error: Throwable) {
                failure = error
            } finally {
                server.close()
            }
        }
        return this
    }

    fun join() {
        worker.join(10_000)
        failure?.let { throw AssertionError("sahte adbd", it) }
    }

    private fun send(output: OutputStream, packet: AdbPacket) {
        output.write(AdbPacket.encode(packet))
        output.flush()
    }

    private fun serve(rawInput: InputStream, rawOutput: OutputStream) {
        var input = rawInput
        var output = rawOutput
        val hello = AdbPacket.read(input)
        check(hello.command == AdbPacket.CNXN) { "CNXN bekleniyordu" }
        check(hello.arg0 == AdbConnection.VERSION)
        if (tlsKey != null) {
            send(output, AdbPacket(AdbPacket.STLS, AdbConnection.STLS_VERSION, 0))
            val reply = AdbPacket.read(input)
            check(reply.command == AdbPacket.STLS) { "STLS yanıtı bekleniyordu" }
            val (tls, protocol) = FakeTlsServer.start(input, output, tlsKey)
            tlsClientKeyHash = tls.clientKeyHash()
            val known = authorized.map { FakeTlsServer.sha256(it.encoded) }
            // adbd yalnız eşleştirmede öğrendiği anahtarı kabul eder.
            if (tlsClientKeyHash !in known) {
                protocol.close()
                return
            }
            input = protocol.inputStream
            output = protocol.outputStream
        } else {
            val token = ByteArray(20).also { SecureRandom().nextBytes(it) }
            send(output, AdbPacket(AdbPacket.AUTH, 1, 0, token))
            var answer = AdbPacket.read(input)
            check(answer.command == AdbPacket.AUTH && answer.arg0 == 2) { "imza bekleniyordu" }
            if (authorized.none { adbSignatureValid(it, token, answer.payload) }) {
                send(output, AdbPacket(AdbPacket.AUTH, 1, 0, token))
                answer = AdbPacket.read(input)
                check(answer.command == AdbPacket.AUTH && answer.arg0 == 3) { "açık anahtar bekleniyordu" }
                approvalAsked = true
                if (!approve) return
                authorized += decodePublicKeyLine(String(answer.payload, Charsets.US_ASCII))
            }
        }
        send(output, AdbPacket(AdbPacket.CNXN, 0x01000001, 256 * 1024, "device::ro.product.name=fake;\u0000".toByteArray()))

        var nextRemote = 100
        while (true) {
            val packet = try {
                AdbPacket.read(input)
            } catch (error: java.io.IOException) {
                return
            }
            if (packet.command != AdbPacket.OPEN) continue
            val service = String(packet.payload, Charsets.UTF_8).trimEnd('\u0000')
            opened += service
            val local = packet.arg0
            val remote = nextRemote++
            send(output, AdbPacket(AdbPacket.OKAY, remote, local))
            val data = ByteArrayOutputStream()
            if (service == "sync:") {
                data.write(readSync(input, output, local, remote))
                received[service] = data.toByteArray()
                send(output, AdbPacket(AdbPacket.WRTE, remote, local, "OKAY".toByteArray() + ByteArray(4)))
                expectOkay(input)
            } else {
                val expected = expectedInput(service)
                while (data.size() < expected) {
                    val chunk = AdbPacket.read(input)
                    if (chunk.command == AdbPacket.WRTE) {
                        data.write(chunk.payload)
                        send(output, AdbPacket(AdbPacket.OKAY, remote, local))
                    }
                }
                received[service] = data.toByteArray()
                val reply = services(service, data.toByteArray())
                if (reply.isNotEmpty()) {
                    send(output, AdbPacket(AdbPacket.WRTE, remote, local, reply.toByteArray()))
                    expectOkay(input)
                }
            }
            send(output, AdbPacket(AdbPacket.CLSE, remote, local))
        }
    }

    /** Yanıtımızın onayını bekler; arada gelen (okunmayan) veri atlanır, hizmet erken kapanmış gibi. */
    private fun expectOkay(input: InputStream) {
        while (true) {
            val packet = AdbPacket.read(input)
            if (packet.command == AdbPacket.OKAY) return
            check(packet.command == AdbPacket.WRTE) { "OKAY bekleniyordu" }
        }
    }

    /** sync: SEND … DONE arasındaki dosya verisi; gelen her parça onaylanır. */
    private fun readSync(input: InputStream, output: OutputStream, local: Int, remote: Int): ByteArray {
        val stream = ByteArrayOutputStream()
        val file = ByteArrayOutputStream()
        while (true) {
            val chunk = AdbPacket.read(input)
            if (chunk.command != AdbPacket.WRTE) continue
            stream.write(chunk.payload)
            send(output, AdbPacket(AdbPacket.OKAY, remote, local))
            // Çözümle: SEND/DATA/DONE paketleri.
            val bytes = stream.toByteArray()
            var offset = 0
            file.reset()
            var done = false
            while (offset + 8 <= bytes.size) {
                val id = String(bytes, offset, 4, Charsets.US_ASCII)
                val length = ByteBuffer.wrap(bytes, offset + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
                if (id == "DONE") { done = true; break }
                if (offset + 8 + length > bytes.size) break
                if (id == "DATA") file.write(bytes, offset + 8, length)
                offset += 8 + length
            }
            if (done) return file.toByteArray()
        }
    }
}
