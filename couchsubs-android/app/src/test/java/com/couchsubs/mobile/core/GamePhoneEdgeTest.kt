// SPDX-License-Identifier: AGPL-3.0-only
package com.couchsubs.mobile.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1369 (beta-104, Mac): gevşek doğrulamada ([GamePhoneGeometry.confirmPicture]) açık telefonun son yeri hoparlör ya da
 * çentik şeridinin dışında kalınca satır aralığı ters kuruluyor, Mac/iPhone'da uygulama çöküyordu. Son yer kenarda,
 * dışında, eksi, karenin altını aşan ya da sayı olmayan bir yer olsa da arama null döner, hata atmaz. Ortak deneme dosyası
 * fixtures/phone-near-edges.json (core/Tests/CouchSubsCoreTests/Fixtures ile aynı; Mac/iPhone GamePhoneEdgeTests.swift,
 * Windows GamePhoneEdgeTests.cs aynı durumları koşar).
 */
class GamePhoneEdgeTest {
    private val vectors = JSONObject(Fixtures.text("phone-near-edges.json"))
    private val frames = GamePhoneFirstSightingTest()

    private fun poses(): List<GamePhoneGeometry.Pose> {
        val near = vectors.getJSONArray("near")
        val poses = (0 until near.length()).map { i ->
            val p = near.getJSONArray(i)
            GamePhoneGeometry.Pose(p.getDouble(0), p.getDouble(1), p.getDouble(2), p.getDouble(3))
        }.toMutableList()
        // JSON'da olmayan sayılar.
        for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.MAX_VALUE, -Double.MAX_VALUE)) {
            poses += GamePhoneGeometry.Pose(0.5, bad, 0.5, 0.8)
            poses += GamePhoneGeometry.Pose(0.5, 0.2, 0.5, bad)
            poses += GamePhoneGeometry.Pose(bad, 0.2, 0.5, 0.8)
            poses += GamePhoneGeometry.Pose(0.5, 0.2, bad, 0.8)
            poses += GamePhoneGeometry.Pose(bad, bad, bad, bad)
        }
        // Sabit tohumlu rastgele yerler.
        var seed = 1369UL
        fun next(): Double {
            seed = seed * 6364136223846793005UL + 1442695040888963407UL
            return (seed shr 11).toDouble() / (1UL shl 53).toDouble()
        }
        repeat(150) { poses += GamePhoneGeometry.Pose(next() * 3 - 1, next() * 3 - 1, next() * 3 - 1, next() * 3 - 1) }
        return poses
    }

    @Test
    fun confirmRowsStayInsideTheBand() {
        val items = vectors.getJSONArray("rows")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val center = item.getDouble("center")
            val low = item.getInt("low")
            val high = item.getInt("high")
            val rows = GamePhoneGeometry.confirmRows(center, low, high)
            val expected = item.optJSONArray("rows")
            assertEquals("$center in $low until $high", expected?.let { listOf(it.getInt(0), it.getInt(1)) },
                rows?.let { listOf(it.first, it.last + 1) })
        }
        for (bad in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) assertNull(GamePhoneGeometry.confirmRows(bad, 17, 75))
    }

    /** Telefonsuz karede (düz, karanlık: kazançlı geçişler de koşar; 16:9 olmayan pencere) hiçbir son yer telefon bulmaz. */
    @Test
    fun confirmNearEveryEdgeNeverThrows() {
        val images = listOf(
            TestPhoneImage(800, 450) { _, _ -> TestPhoneImage.gray(128) },
            TestPhoneImage(800, 450) { _, _ -> TestPhoneImage.gray(10) },
            TestPhoneImage(800, 450) { x, y -> TestPhoneImage.gray((x * 7 + y * 13) % 256) },
            TestPhoneImage(800, 560) { _, y -> TestPhoneImage.gray(if (y < 80) 200 else 90) },
        )
        val near = poses()
        images.forEachIndexed { i, image ->
            for (pose in near) {
                val confirmed = GamePhoneGeometry.confirmPicture(image, pose)
                val searched = GamePhoneGeometry.search(image, pose).pose
                // Desenli karede yalnız hata atmaması aranır.
                if (i == 2) continue
                assertNull("kare $i: $pose", confirmed)
                assertNull("kare $i: $pose", searched)
            }
        }
    }

    /** Gerçek telefon karesinde kenardaki ve dışarıdaki son yerler hata atmaz; telefonun kendi yeri yine doğrulanır. */
    @Test
    fun confirmNearEveryEdgeOnRealPhone() {
        val near = poses()
        val items = vectors.getJSONArray("frames")
        for (i in 0 until items.length()) {
            val item = items.getJSONObject(i)
            val frame = frames.load(item.getString("frame"), item.getString("transform"))
            for (pose in near) GamePhoneGeometry.confirmPicture(frame, pose)
            val found = GamePhoneGeometry.search(frame).pose
            assertNotNull(found)
            assertNotNull(GamePhoneGeometry.confirmPicture(frame, found!!))
            val tracker = GamePhoneTracker()
            tracker.sample(frame, 0)
            tracker.sample(frame, 330)
        }
    }
}
