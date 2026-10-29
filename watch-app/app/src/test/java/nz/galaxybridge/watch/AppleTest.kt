package nz.galaxybridge.watch

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppleTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
    private fun attr(id: Int, s: String): ByteArray {
        val b = s.toByteArray()
        return bytes(id, b.size and 0xFF, b.size shr 8) + b
    }

    @Test fun parsesEvent() {
        val e = Ancs.parseEvent(bytes(0, 0x18, 1, 1, 0x2A, 0, 0, 0))!!
        assertEquals(Ancs.EVENT_ADDED, e.kind)
        assertEquals(Ancs.CATEGORY_INCOMING_CALL, e.category)
        assertEquals(42, e.uid)
        assertTrue(e.has(Ancs.FLAG_POSITIVE_ACTION) && e.has(Ancs.FLAG_NEGATIVE_ACTION))
        assertNull(Ancs.parseEvent(bytes(9, 0, 0, 0, 0, 0, 0, 0)))
        assertNull(Ancs.parseEvent(bytes(0, 0, 0)))
    }

    @Test fun requestLayouts() {
        assertArrayEquals(bytes(2, 7, 0, 0, 0, 1), Ancs.performAction(7, positive = false))
        val req = Ancs.getNotificationAttributes(1)
        assertArrayEquals(bytes(0, 1, 0, 0, 0, 0, 1, 64, 0), req.copyOfRange(0, 9))
        assertArrayEquals(bytes(1, 'a'.code, 0, 0), Ancs.getAppAttributes("a"))
    }

    @Test fun reassemblesSplitResponse() {
        val full = bytes(0, 5, 0, 0, 0) + attr(0, "com.apple.MobileSMS") + attr(1, "Mum") +
            attr(2, "") + attr(3, "Dinner\u0007 at 6?") + attr(6, "") + attr(7, "Clear")
        val r = Ancs.Responses()
        assertNull(r.append(full.copyOfRange(0, 10)))
        assertNull(r.append(full.copyOfRange(10, 30)))
        val out = r.append(full.copyOfRange(30, full.size)) as Ancs.Responses.Result.Notification
        assertEquals(5, out.details.uid)
        assertEquals("Mum", out.details.title)
        assertEquals("Dinner at 6?", out.details.message) // control char stripped
        assertEquals("Clear", out.details.negativeLabel)
    }

    @Test fun parsesAppName() {
        val r = Ancs.Responses()
        val out = r.append(bytes(1) + "com.x".toByteArray() + bytes(0) + attr(0, "X App"))
        assertEquals(Ancs.Responses.Result.AppName("com.x", "X App"), out)
    }

    @Test fun nowPlayingUpdates() {
        var np = Ams.NowPlaying()
        np = np.apply(bytes(2, 2, 0) + "Song".toByteArray())
        np = np.apply(bytes(0, 1, 0) + "1,1.0,12.5".toByteArray(), now = 99)
        np = np.apply(bytes(0, 2, 0) + "7".toByteArray()) // out of range volume ignored
        assertEquals("Song", np.title)
        assertTrue(np.playing)
        assertEquals(12.5, np.elapsedSec, 0.0)
        assertEquals(0f, np.volume)
    }

    @Test fun phoneMessagesValidated() {
        assertEquals(PhoneMessage.Find(true), PhoneMessage.decode("""{"t":"find","on":true}""".toByteArray()))
        assertEquals(PhoneMessage.Set("brightness", 200), PhoneMessage.decode("""{"t":"set","key":"brightness","value":200}""".toByteArray()))
        assertNull(PhoneMessage.decode("""{"t":"set","key":"brightness","value":999}""".toByteArray()))
        assertNull(PhoneMessage.decode("""{"t":"set","key":"adb_enabled","value":1}""".toByteArray()))
        assertNull(PhoneMessage.decode("""{"t":"phone","pct":140}""".toByteArray()))
        assertNull(PhoneMessage.decode("""{"t":"weather","temp":500,"hi":1,"lo":1}""".toByteArray()))
    }
}
