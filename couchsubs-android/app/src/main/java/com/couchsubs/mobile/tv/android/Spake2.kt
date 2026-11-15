// SPDX-License-Identifier: AGPL-3.0-only
// Masaüstündeki SPAKE2'nin (windows/src/CouchSubs.TvInstall/Android/Spake2.cs) Kotlin karşılığı.
package com.couchsubs.mobile.tv.android

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * edwards25519 noktaları (RFC 8032), yalnız SPAKE2 için; hız gerekmez, eşleştirmede birkaç çarpma yapılır.
 * Genişletilmiş koordinatlar (X:Y:Z:T), a = -1 için birleşik toplama formülü.
 */
/** BigInteger.TWO Android 13 öncesinde yok. */
private val TWO: BigInteger = BigInteger.valueOf(2)

internal class EdPoint private constructor(private val x: BigInteger, private val y: BigInteger, private val z: BigInteger, private val t: BigInteger) {
    companion object {
        val P: BigInteger = TWO.pow(255).subtract(BigInteger.valueOf(19))
        val D: BigInteger = mod(BigInteger.valueOf(-121665).multiply(inverse(BigInteger.valueOf(121666))))

        /** Asal mertebeli alt grubun mertebesi. */
        val L: BigInteger = TWO.pow(252).add(BigInteger("27742317777372353535851937790883648493"))
        private val SQRT_MINUS_ONE: BigInteger = TWO.modPow(P.subtract(BigInteger.ONE).shiftRight(2), P)

        val IDENTITY = EdPoint(BigInteger.ZERO, BigInteger.ONE, BigInteger.ONE, BigInteger.ZERO)
        val BASE: EdPoint = run {
            val y = mod(BigInteger.valueOf(4).multiply(inverse(BigInteger.valueOf(5))))
            fromAffine(recoverX(y, false)!!, y)
        }

        fun mod(value: BigInteger): BigInteger = value.mod(P)
        private fun inverse(value: BigInteger): BigInteger = mod(value).modPow(P.subtract(TWO), P)
        private fun fromAffine(x: BigInteger, y: BigInteger) = EdPoint(x, y, BigInteger.ONE, mod(x.multiply(y)))

        /** 32 baytlık kodlamadan nokta; eğri üstünde değilse null. */
        fun decode(encoded: ByteArray): EdPoint? {
            if (encoded.size != 32) return null
            val bytes = encoded.copyOf()
            val sign = (bytes[31].toInt() and 0x80) != 0
            bytes[31] = (bytes[31].toInt() and 0x7f).toByte()
            val y = littleEndian(bytes)
            if (y >= P) return null
            val x = recoverX(y, sign) ?: return null
            return fromAffine(x, y)
        }

        private fun recoverX(y: BigInteger, sign: Boolean): BigInteger? {
            val y2 = mod(y.multiply(y))
            val u = mod(y2.subtract(BigInteger.ONE))
            val v = mod(D.multiply(y2).add(BigInteger.ONE))
            val x2 = mod(u.multiply(inverse(v)))
            if (x2.signum() == 0) return if (sign) null else BigInteger.ZERO
            var candidate = x2.modPow(P.add(BigInteger.valueOf(3)).shiftRight(3), P)
            if (mod(candidate.multiply(candidate).subtract(x2)).signum() != 0) candidate = mod(candidate.multiply(SQRT_MINUS_ONE))
            if (mod(candidate.multiply(candidate).subtract(x2)).signum() != 0) return null
            if (candidate.testBit(0) != sign) candidate = mod(candidate.negate())
            return candidate
        }

        fun littleEndian(bytes: ByteArray): BigInteger = BigInteger(1, bytes.reversedArray())
    }

    fun add(q: EdPoint): EdPoint {
        val a = mod(y.subtract(x).multiply(q.y.subtract(q.x)))
        val b = mod(y.add(x).multiply(q.y.add(q.x)))
        val c = mod(TWO.multiply(t).multiply(D).multiply(q.t))
        val dd = mod(TWO.multiply(z).multiply(q.z))
        val e = b.subtract(a)
        val f = dd.subtract(c)
        val g = dd.add(c)
        val h = b.add(a)
        return EdPoint(mod(e.multiply(f)), mod(g.multiply(h)), mod(f.multiply(g)), mod(e.multiply(h)))
    }

    fun negate() = EdPoint(mod(x.negate()), y, z, mod(t.negate()))

    /** k·P; k negatif olmayan bir tam sayı (indirgenmesi gerekmez). */
    fun multiply(scalar: BigInteger): EdPoint {
        var result = IDENTITY
        var addend = this
        var k = scalar
        while (k.signum() > 0) {
            if (k.testBit(0)) result = result.add(addend)
            addend = addend.add(addend)
            k = k.shiftRight(1)
        }
        return result
    }

    fun encode(): ByteArray {
        val inverse = inverse(z)
        val affineX = mod(x.multiply(inverse))
        val affineY = mod(y.multiply(inverse))
        val bytes = ByteArray(32)
        val big = affineY.toByteArray()
        for (i in 0 until minOf(32, big.size)) bytes[i] = big[big.size - 1 - i]
        if (affineX.testBit(0)) bytes[31] = (bytes[31].toInt() or 0x80).toByte()
        return bytes
    }
}

/**
 * BoringSSL'in SPAKE2'si (crypto/curve25519/spake25519.cc), adb'nin kablosuz hata ayıklama eşleştirmesindeki
 * biçimiyle: istemci "alice", adlar sonlarındaki NUL ile birlikte, şifre = eşleştirme kodu + TLS'ten dışa
 * aktarılan 64 bayt. Sonuç 64 baytlık anahtar malzemesidir.
 *
 * @param random64 Test için sabit rastgelelik; verilmezse güvenli rastgele 64 bayt.
 */
internal class Spake2(private val alice: Boolean, password: ByteArray, random64: ByteArray? = null) {
    companion object {
        val CLIENT_NAME = "adb pair client\u0000".toByteArray(Charsets.US_ASCII)
        val SERVER_NAME = "adb pair server\u0000".toByteArray(Charsets.US_ASCII)

        /** "edwards25519 point generation seed (M)" ve "(N)" tohumlarından türetilmiş noktalar (BoringSSL). */
        val M: EdPoint = EdPoint.decode(hex("5ada7e4bf6ddd9adb6626d32131c6b5c51a1e347a3478f53cfcf441b88eed12e"))!!
        val N: EdPoint = EdPoint.decode(hex("10e3df0ae37d8e7a99b5fe74b44672103dbddcbd06af680d71329a11693bc778"))!!

        fun hex(text: String) = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

        private fun reduce(littleEndianBytes: ByteArray) = EdPoint.littleEndian(littleEndianBytes).mod(EdPoint.L)
    }

    private val myName = if (alice) CLIENT_NAME else SERVER_NAME
    private val theirName = if (alice) SERVER_NAME else CLIENT_NAME
    private val passwordHash: ByteArray = MessageDigest.getInstance("SHA-512").digest(password)
    // x25519_sc_reduce, ardından eş çarpana (8) çarpılır.
    private val privateKey: BigInteger = reduce(random64 ?: ByteArray(64).also { SecureRandom().nextBytes(it) }).shiftLeft(3)
    private val passwordScalar: BigInteger = run {
        var scalar = reduce(passwordHash)
        // BoringSSL'in "password scalar hack"i: alt üç bit sıfır olacak biçimde l, 2l, 4l eklenir.
        if (scalar.testBit(0)) scalar = scalar.add(EdPoint.L)
        if (scalar.testBit(1)) scalar = scalar.add(EdPoint.L.shiftLeft(1))
        if (scalar.testBit(2)) scalar = scalar.add(EdPoint.L.shiftLeft(2))
        scalar
    }

    val message: ByteArray = EdPoint.BASE.multiply(privateKey).add((if (alice) M else N).multiply(passwordScalar)).encode()

    /** Karşı tarafın mesajından 64 baytlık anahtar malzemesi; nokta geçersizse null. */
    fun finish(theirMessage: ByteArray): ByteArray? {
        val theirs = EdPoint.decode(theirMessage) ?: return null
        val unmasked = theirs.add((if (alice) N else M).multiply(passwordScalar).negate())
        val shared = unmasked.multiply(privateKey).encode()
        val sha = MessageDigest.getInstance("SHA-512")
        fun update(data: ByteArray) {
            sha.update(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(data.size.toLong()).array())
            sha.update(data)
        }
        if (alice) {
            update(myName); update(theirName); update(message); update(theirMessage)
        } else {
            update(theirName); update(myName); update(theirMessage); update(message)
        }
        update(shared)
        update(passwordHash)
        return sha.digest()
    }
}
