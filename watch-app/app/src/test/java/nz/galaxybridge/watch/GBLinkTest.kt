package nz.galaxybridge.watch

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GBLinkTest {
    @Test fun chunkRoundTrip() {
        val message = ByteArray(1000) { it.toByte() }
        val a = GBLink.Assembler()
        var out: ByteArray? = null
        for (c in GBLink.chunks(message, 20)) {
            assertTrue(c.size <= 20)
            a.append(c)?.let { out = it }
        }
        assertArrayEquals(message, out)
    }

    @Test fun matchesSwiftSingleChunkFormat() {
        // Same bytes the Swift side produces for "{}": flags 0x03, length 2, payload.
        assertArrayEquals(byteArrayOf(3, 0, 0, 0, 2, '{'.code.toByte(), '}'.code.toByte()),
            GBLink.chunks("{}".toByteArray(), 180).single())
    }

    @Test(expected = GBLink.FramingException::class) fun rejectsContinuationWithoutStart() {
        GBLink.Assembler().append(byteArrayOf(2, 1, 2))
    }

    @Test(expected = GBLink.FramingException::class) fun rejectsOversized() {
        GBLink.Assembler().append(byteArrayOf(1, 0x7f, 0, 0, 0))
    }

    @Test fun decodesAckAndRejectsJunk() {
        val id = "8a0f5c2e-3b1d-4c8e-9f7a-1d2c3b4a5e6f"
        assertEquals(PhoneMessage.Ack(id), PhoneMessage.decode("""{"t":"ack","id":"$id"}""".toByteArray()))
        assertNull(PhoneMessage.decode("""{"t":"ack","id":"../../etc"}""".toByteArray()))
        assertNull(PhoneMessage.decode("""{"t":"exec"}""".toByteArray()))
        assertNull(PhoneMessage.decode("not json".toByteArray()))
    }

    @Test fun samplePlausibility() {
        assertTrue(HealthSample(SampleKind.HEART_RATE, 1, 1, 70.0).isPlausible())
        assertTrue(!HealthSample(SampleKind.HEART_RATE, 1, 1, 400.0).isPlausible())
        assertTrue(!HealthSample(SampleKind.STEPS, 5, 1, 10.0).isPlausible())
        assertTrue(!HealthSample(SampleKind.DISTANCE, 1, 2, Double.NaN).isPlausible())
    }

    @Test fun advertMatchesSwiftFormat() {
        assertArrayEquals(byteArrayOf(1, 1, 'S'.code.toByte(), '9'.code.toByte()), GBLink.advert(true, "S9"))
        // Non-ASCII dropped, capped at 10 bytes.
        assertEquals(12, GBLink.advert(false, "ÄBCDEFGHIJKLMN").size)
    }
}
