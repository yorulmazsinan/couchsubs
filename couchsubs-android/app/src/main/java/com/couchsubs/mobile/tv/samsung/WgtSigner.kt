// SPDX-License-Identifier: AGPL-3.0-only
// İmza biçimi TizenSdb.Core'un TizenResigner'ından (MIT, Patrick Stel) taşındı: https://github.com/PatrickSt1991/tizen-sdb
package com.couchsubs.mobile.tv.samsung

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.util.Base64
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Tizen web uygulaması paketini (.wgt) imzalar: W3C Widget Signature biçiminde `author-signature.xml` (paketin dosyaları)
 * ve `signature1.xml` (dağıtıcı; önce yazar imzası, sonra dosyalar). Özet ve imza [Digest] ile seçilir: SHA-512 (bugünkü
 * Tizen Studio ve TizenSdb gibi; #71'de Tizen 2.4'te de çalıştı), Tizen 2.x TV'lerde ikinci denemedeki yalın pakette
 * SHA-256 (#638, #890).
 *
 * Android'de XML imza kütüphanesi (javax.xml.crypto) yoktur. İmzalanan iki parça (SignedInfo ve `#prop` nesnesi) bu
 * sınıfın kendi yazdığı, yapısı sabit XML olduğundan kanonik biçimleri doğrudan üretilir: SignedInfo exclusive C14N,
 * nesne C14N 1.1 ile (ikisinde de boşluk yok, öznitelikler sıralı, öğeler açık kapanışlı). Dosyaya da aynı metin
 * yazılır; TV kendi kanonikleştirdiğinde aynı baytları bulur. Birim testi imzayı Apache Santuario'nun XML imza doğrulayıcısıyla denetler.
 */
object WgtSigner {
    private const val DSIG = "http://www.w3.org/2000/09/xmldsig#"
    private const val DSP = "http://www.w3.org/2009/xmldsig-properties"
    private const val EXC_C14N = "http://www.w3.org/2001/10/xml-exc-c14n#"
    private const val C14N11 = "http://www.w3.org/2006/12/xml-c14n11"

    /** İmzadaki özet ve imza algoritması. */
    enum class Digest(val signatureMethod: String, val digestMethod: String, internal val hash: String, internal val signature: String) {
        /** W3C Widget Signature'ın zorunlu tuttuğu, Tizen 2.x SDK'sının ürettiği biçim; Tizen 2.x'te yalnız yalın pakette. */
        SHA256("http://www.w3.org/2001/04/xmldsig-more#rsa-sha256", "http://www.w3.org/2001/04/xmlenc#sha256", "SHA-256", "SHA256withRSA"),

        /** Bugünkü Tizen Studio'nun ve TizenSdb'nin ürettiği biçim (her TV; Tizen 2.x'te ilk deneme, #890). */
        SHA512("http://www.w3.org/2001/04/xmldsig-more#rsa-sha512", "http://www.w3.org/2001/04/xmlenc#sha512", "SHA-512", "SHA512withRSA"),
    }

    class Entry(val name: String, val data: ByteArray)

    /** İmza için anahtar ve sertifika zinciri (yaprak önce, kök yok). */
    class Signer(val key: PrivateKey, val chain: List<X509Certificate>)

    /** İmzasız ya da imzalı paketi yeniden imzalar; eski imza dosyaları atılır, diğer dosyaların sırası korunur. */
    fun sign(wgt: ByteArray, author: Signer, distributor: Signer, digest: Digest = Digest.SHA512): ByteArray {
        val files = readEntries(wgt)
        val authorSignature = Entry("author-signature.xml", signature("AuthorSignature", files, author, digest))
        val distributorSignature = Entry("signature1.xml", signature("DistributorSignature", listOf(authorSignature) + files, distributor, digest))
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for (entry in listOf(authorSignature, distributorSignature) + files) {
                zip.putNextEntry(ZipEntry(entry.name))
                zip.write(entry.data)
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    internal fun readEntries(wgt: ByteArray): List<Entry> {
        val files = ArrayList<Entry>()
        ZipInputStream(ByteArrayInputStream(wgt)).use { zip ->
            while (true) {
                val entry = zip.nextEntry ?: break
                val name = entry.name
                val lower = name.lowercase()
                if (name.endsWith("/") || lower.endsWith("author-signature.xml") || lower.endsWith("signature1.xml")) continue
                files.add(Entry(name, zip.readBytes()))
            }
        }
        return files
    }

    /** Bir imza dosyası (`<Signature Id="…">`), XML bildirimi ve girinti olmadan. */
    internal fun signature(id: String, files: List<Entry>, signer: Signer, digest: Digest = Digest.SHA512): ByteArray {
        val signedInfo = signedInfo(files, digest(propObject(id, canonical = true).toByteArray(Charsets.UTF_8), digest), digest)
        val value = Signature.getInstance(digest.signature).run {
            initSign(signer.key)
            update(canonicalSignedInfo(signedInfo).toByteArray(Charsets.UTF_8))
            sign()
        }
        val xml = StringBuilder()
        xml.append("<Signature xmlns=\"$DSIG\" Id=\"").append(attr(id)).append("\">")
        xml.append(signedInfo)
        xml.append("<SignatureValue>").append(Base64.getEncoder().encodeToString(value)).append("</SignatureValue>")
        xml.append("<KeyInfo><X509Data>")
        for (certificate in signer.chain)
            xml.append("<X509Certificate>\n").append(wrap76(Base64.getEncoder().encodeToString(certificate.encoded))).append("\n</X509Certificate>")
        xml.append("</X509Data></KeyInfo>")
        xml.append(propObject(id, canonical = false))
        xml.append("</Signature>")
        return xml.toString().toByteArray(Charsets.UTF_8)
    }

    /** Dosyadaki SignedInfo (ad alanı üst öğeden gelir). */
    internal fun signedInfo(files: List<Entry>, propDigest: String, digest: Digest = Digest.SHA512): String {
        val xml = StringBuilder("<SignedInfo>")
        xml.append("<CanonicalizationMethod Algorithm=\"$EXC_C14N\"></CanonicalizationMethod>")
        xml.append("<SignatureMethod Algorithm=\"${digest.signatureMethod}\"></SignatureMethod>")
        for (file in files) {
            xml.append("<Reference URI=\"").append(attr(file.name)).append("\">")
            xml.append("<DigestMethod Algorithm=\"${digest.digestMethod}\"></DigestMethod>")
            xml.append("<DigestValue>").append(digest(file.data, digest)).append("</DigestValue></Reference>")
        }
        xml.append("<Reference URI=\"#prop\"><Transforms><Transform Algorithm=\"$C14N11\"></Transform></Transforms>")
        xml.append("<DigestMethod Algorithm=\"${digest.digestMethod}\"></DigestMethod><DigestValue>").append(propDigest).append("</DigestValue></Reference>")
        xml.append("</SignedInfo>")
        return xml.toString()
    }

    /** Exclusive C14N: kullanılan varsayılan ad alanı kök öğede yazılır. */
    internal fun canonicalSignedInfo(signedInfo: String): String =
        "<SignedInfo xmlns=\"$DSIG\">" + signedInfo.removePrefix("<SignedInfo>")

    /**
     * `<Object Id="prop">`: profil, rol (author ya da distributor) ve boş tanımlayıcı. Kanonik biçimde (C14N 1.1) üst
     * öğeden gelen varsayılan ad alanı nesnenin kendisinde yazılır.
     */
    internal fun propObject(id: String, canonical: Boolean): String {
        val role = if (id == "AuthorSignature") "author" else "distributor"
        val target = attr("#$id")
        fun property(name: String, child: String, uri: String?) =
            "<SignatureProperty Id=\"$name\" Target=\"$target\"><dsp:$child${uri?.let { " URI=\"${attr(it)}\"" } ?: ""}></dsp:$child></SignatureProperty>"
        return (if (canonical) "<Object xmlns=\"$DSIG\" Id=\"prop\">" else "<Object Id=\"prop\">") +
            "<SignatureProperties xmlns:dsp=\"$DSP\">" +
            property("profile", "Profile", "http://www.w3.org/ns/widgets-digsig#profile") +
            property("role", "Role", "http://www.w3.org/ns/widgets-digsig#role-$role") +
            property("identifier", "Identifier", null) +
            "</SignatureProperties></Object>"
    }

    internal fun digest(data: ByteArray, digest: Digest = Digest.SHA512): String =
        Base64.getEncoder().encodeToString(MessageDigest.getInstance(digest.hash).digest(data))

    /** Kanonik XML'deki öznitelik kaçışları. */
    internal fun attr(value: String): String = buildString {
        for (c in value) append(when (c) {
            '&' -> "&amp;"
            '<' -> "&lt;"
            '"' -> "&quot;"
            '\t' -> "&#x9;"
            '\n' -> "&#xA;"
            '\r' -> "&#xD;"
            else -> c.toString()
        })
    }

    private fun wrap76(text: String) = text.chunked(76).joinToString("\n")
}
