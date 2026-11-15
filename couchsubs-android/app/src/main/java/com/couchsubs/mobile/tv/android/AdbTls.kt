// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki AdbTls.cs'in (windows/src/CouchSubs.TvInstall/Android) Kotlin karşılığı; TLS BouncyCastle'dandır (MIT).
package com.couchsubs.mobile.tv.android

import com.couchsubs.mobile.tv.samsung.AdbKey
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.BasicConstraints
import org.bouncycastle.asn1.x509.Extension
import org.bouncycastle.asn1.x509.KeyUsage
import org.bouncycastle.asn1.x509.SubjectPublicKeyInfo
import org.bouncycastle.cert.X509v3CertificateBuilder
import org.bouncycastle.crypto.params.AsymmetricKeyParameter
import org.bouncycastle.crypto.util.PrivateKeyFactory
import org.bouncycastle.operator.DefaultDigestAlgorithmIdentifierFinder
import org.bouncycastle.operator.DefaultSignatureAlgorithmIdentifierFinder
import org.bouncycastle.operator.bc.BcRSAContentSignerBuilder
import org.bouncycastle.tls.Certificate
import org.bouncycastle.tls.CertificateEntry
import org.bouncycastle.tls.CertificateRequest
import org.bouncycastle.tls.DefaultTlsClient
import org.bouncycastle.tls.ProtocolVersion
import org.bouncycastle.tls.SignatureAndHashAlgorithm
import org.bouncycastle.tls.TlsAuthentication
import org.bouncycastle.tls.TlsClientProtocol
import org.bouncycastle.tls.TlsCredentials
import org.bouncycastle.tls.TlsServerCertificate
import org.bouncycastle.tls.crypto.TlsCryptoParameters
import org.bouncycastle.tls.crypto.impl.bc.BcDefaultTlsCredentialedSigner
import org.bouncycastle.tls.crypto.impl.bc.BcTlsCrypto
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.math.BigInteger
import java.security.SecureRandom
import java.util.Date

/**
 * adb'nin kablosuz hata ayıklamada kullandığı TLS 1.3 istemcisi: TV'nin sertifikası denetlenmez (adb de denetlemez),
 * telefon adb anahtarından üretilmiş kendinden imzalı sertifikayla kendini tanıtır; TV bu açık anahtarı eşleştirmede
 * öğrenmiştir. Android'in kendi TLS'i anahtar dışa aktarımını (eşleştirmede gerekir) Android 10'dan önce sunmadığı ve
 * JVM testlerinde denenemediği için BouncyCastle kullanılır.
 */
internal class AdbTlsClient(key: AdbKey) : DefaultTlsClient(BcTlsCrypto(SecureRandom())) {
    private val certificate: ByteArray = selfSignedCertificate(key)
    private val privateKey: AsymmetricKeyParameter = PrivateKeyFactory.createKey(key.privateKeyBytes())

    /** Kurulmuş bağlantının uygulama verisi akışları. */
    class Session(val input: InputStream, val output: OutputStream, val client: AdbTlsClient, private val protocol: TlsClientProtocol) {
        fun close() = runCatching { protocol.close() }
    }

    companion object {
        /** Bağlantı kurulur; TV sertifikayı reddederse [IOException]. */
        fun connect(input: InputStream, output: OutputStream, key: AdbKey): Session {
            val client = AdbTlsClient(key)
            val protocol = TlsClientProtocol(input, output)
            protocol.connect(client)
            return Session(protocol.inputStream, protocol.outputStream, client, protocol)
        }

        /** adb'nin kendi ürettiği gibi: anahtarın kendinden imzalı X.509 sertifikası (DER). */
        fun selfSignedCertificate(key: AdbKey): ByteArray {
            val name = X500Name("CN=CouchSubs")
            val now = System.currentTimeMillis()
            val builder = X509v3CertificateBuilder(name, BigInteger.valueOf(now), Date(now - 86_400_000L),
                Date(now + 10L * 365 * 86_400_000L), name, SubjectPublicKeyInfo.getInstance(key.publicKey.encoded))
            builder.addExtension(Extension.basicConstraints, true, BasicConstraints(true))
            builder.addExtension(Extension.keyUsage, true, KeyUsage(KeyUsage.keyCertSign or KeyUsage.cRLSign or KeyUsage.digitalSignature))
            val signature = DefaultSignatureAlgorithmIdentifierFinder().find("SHA256withRSA")
            val digest = DefaultDigestAlgorithmIdentifierFinder().find(signature)
            val signer = BcRSAContentSignerBuilder(signature, digest).build(PrivateKeyFactory.createKey(key.privateKeyBytes()))
            return builder.build(signer).encoded
        }
    }

    /**
     * RFC 8446 dışa aktarıcıyla eşleştirme şifresinin TLS parçası: adb etiketi sonundaki NUL ile birlikte verir
     * ("adb-label\u0000"), 64 bayt. BouncyCastle dışa aktarıma yalnız el sıkışma biterken izin verir; orada saklanır.
     */
    var exportedKeyingMaterial: ByteArray? = null
        private set

    override fun notifyHandshakeComplete() {
        super.notifyHandshakeComplete()
        exportedKeyingMaterial = context.exportKeyingMaterial(AdbPairing.EXPORTED_KEY_LABEL, ByteArray(0), 64)
    }

    override fun getSupportedVersions(): Array<ProtocolVersion> = ProtocolVersion.TLSv13.only()

    override fun getAuthentication(): TlsAuthentication = object : TlsAuthentication {
        override fun notifyServerCertificate(serverCertificate: TlsServerCertificate) = Unit

        override fun getClientCredentials(request: CertificateRequest): TlsCredentials {
            val crypto = crypto as BcTlsCrypto
            val chain = Certificate(request.certificateRequestContext, arrayOf(CertificateEntry(crypto.createCertificate(certificate), null)))
            return BcDefaultTlsCredentialedSigner(TlsCryptoParameters(context), crypto, privateKey, chain,
                SignatureAndHashAlgorithm.rsa_pss_rsae_sha256)
        }
    }
}
