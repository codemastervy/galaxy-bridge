package nz.galaxybridge.watch

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.util.UUID

/**
 * GBLink framing and messages. Must stay in step with WearLink/Sources/WearLink/GBLink.swift.
 *
 * chunk = [flags] + bytes, flags bit0 = first, bit1 = last;
 * the first chunk's bytes start with a uint32 big-endian total length.
 */
object GBLink {
    val SERVICE: UUID = UUID.fromString("3ed75be1-1098-4239-b80a-a7763a2d4855")
    val TO_PHONE: UUID = UUID.fromString("7ff2dd95-3428-49e6-83fb-37de84360199")
    val TO_WATCH: UUID = UUID.fromString("e8038e21-fbf8-4a81-91a6-81a1bf361465")
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val PROTOCOL_VERSION = 1
    const val MAX_MESSAGE_BYTES = 64 * 1024

    private const val FIRST: Int = 0x01
    private const val LAST: Int = 0x02

    /** Scan-response service data; matches GBAdvert in GBLink.swift. */
    fun advert(readyToPair: Boolean, name: String): ByteArray {
        val ascii = name.filter { it.code in 0x20..0x7E }.take(10).toByteArray(Charsets.US_ASCII)
        return byteArrayOf(1, if (readyToPair) 1 else 0) + ascii
    }

    fun chunks(message: ByteArray, maxChunk: Int): List<ByteArray> {
        require(maxChunk > 5) { "ATT payload too small" }
        val body = ByteBuffer.allocate(4 + message.size).putInt(message.size).put(message).array()
        val room = maxChunk - 1
        val out = ArrayList<ByteArray>()
        var offset = 0
        while (offset < body.size) {
            val end = minOf(offset + room, body.size)
            var flags = 0
            if (offset == 0) flags = flags or FIRST
            if (end == body.size) flags = flags or LAST
            out += byteArrayOf(flags.toByte()) + body.copyOfRange(offset, end)
            offset = end
        }
        return out
    }

    class FramingException(message: String) : Exception(message)

    /** Reassembles chunks; throws and resets on anything malformed or oversized. */
    class Assembler {
        private var buffer: java.io.ByteArrayOutputStream? = null
        private var expected = 0

        fun append(chunk: ByteArray): ByteArray? {
            if (chunk.isEmpty()) throw FramingException("empty chunk")
            val flags = chunk[0].toInt()
            val bytes = chunk.copyOfRange(1, chunk.size)

            if (flags and FIRST != 0) {
                if (bytes.size < 4) { buffer = null; throw FramingException("short header") }
                expected = ByteBuffer.wrap(bytes, 0, 4).int
                if (expected < 0 || expected > MAX_MESSAGE_BYTES) { buffer = null; throw FramingException("too large") }
                buffer = java.io.ByteArrayOutputStream(expected).apply { write(bytes, 4, bytes.size - 4) }
            } else {
                val b = buffer ?: throw FramingException("continuation without start")
                b.write(bytes)
            }

            val current = buffer ?: return null
            if (current.size() > expected) { buffer = null; throw FramingException("length mismatch") }
            if (flags and LAST == 0) return null
            buffer = null
            if (current.size() != expected) throw FramingException("length mismatch")
            return current.toByteArray()
        }
    }
}

enum class SampleKind(val wire: String, val range: ClosedFloatingPointRange<Double>) {
    HEART_RATE("hr", 25.0..250.0),
    STEPS("steps", 0.0..50_000.0),
    ACTIVE_ENERGY("kcal", 0.0..5_000.0),
    DISTANCE("dist", 0.0..100_000.0),
}

data class HealthSample(val kind: SampleKind, val startMs: Long, val endMs: Long, val value: Double) {
    fun isPlausible(): Boolean = value.isFinite() && value in kind.range && endMs >= startMs

    fun toJson(): JSONObject = JSONObject()
        .put("k", kind.wire).put("start", startMs).put("end", endMs).put("v", value)
}

/** Messages the watch understands from the phone. Anything else is rejected. */
sealed class PhoneMessage {
    /** [phoneTime] (epoch ms) and [timeZone] (IANA id) let the watch spot a wrong clock. */
    data class Hello(val protocolVersion: Int, val appVersion: String,
                     val phoneTime: Long = 0, val timeZone: String = "") : PhoneMessage()
    data class Ack(val batchId: String) : PhoneMessage()
    /** Ring the watch so it can be found, or stop ringing. */
    data class Find(val on: Boolean) : PhoneMessage()
    /** Change one setting; key and value are validated against [WatchSettings]. */
    data class Set(val key: String, val value: Int) : PhoneMessage()
    object GetStatus : PhoneMessage()
    data class PhoneBattery(val percent: Int, val charging: Boolean) : PhoneMessage()
    data class Weather(val place: String, val tempC: Double, val highC: Double, val lowC: Double,
                       val code: Int, val at: Long) : PhoneMessage()
    data class Events(val items: List<Event>) : PhoneMessage()
    data class Event(val title: String, val start: Long, val end: Long, val allDay: Boolean)

    companion object {
        fun decode(bytes: ByteArray): PhoneMessage? {
            if (bytes.size > GBLink.MAX_MESSAGE_BYTES) return null
            val json = try {
                JSONObject(String(bytes, Charsets.UTF_8))
            } catch (_: Exception) {
                return null
            }
            return when (json.optString("t")) {
                "hello" -> {
                    if (!json.has("v")) return null
                    val app = json.optString("app", "")
                    if (app.length > 32) return null
                    val tz = json.optString("tz", "")
                    if (tz.length > 64 || !tz.all { it.isLetterOrDigit() || it in "/_+-" }) return null
                    Hello(json.optInt("v"), app, json.optLong("time", 0), tz)
                }
                "ack" -> {
                    val id = json.optString("id", "")
                    if (!isBatchId(id)) return null
                    Ack(id)
                }
                "find" -> Find(json.optBoolean("on", false))
                "set" -> {
                    val key = json.optString("key", "")
                    if (!json.has("value")) return null
                    val value = json.optInt("value", Int.MIN_VALUE)
                    if (!WatchSettings.isValid(key, value)) return null
                    Set(key, value)
                }
                "status" -> GetStatus
                "phone" -> {
                    val pct = json.optInt("pct", -1)
                    if (pct !in 0..100) return null
                    PhoneBattery(pct, json.optBoolean("charging", false))
                }
                "weather" -> {
                    val t = json.optDouble("temp"); val hi = json.optDouble("hi"); val lo = json.optDouble("lo")
                    if (listOf(t, hi, lo).any { !it.isFinite() || it !in -90.0..60.0 }) return null
                    Weather(clean(json.optString("place", "")).take(32), t, hi, lo,
                        json.optInt("code", 0).coerceIn(0, 99), json.optLong("at", 0))
                }
                "events" -> {
                    val arr = json.optJSONArray("items") ?: return null
                    if (arr.length() > 20) return null
                    val items = (0 until arr.length()).map { i ->
                        val o = arr.optJSONObject(i) ?: return null
                        val start = o.optLong("start", -1); val end = o.optLong("end", -1)
                        if (start < 0 || end < start) return null
                        Event(clean(o.optString("title", "")).take(64), start, end, o.optBoolean("allDay", false))
                    }
                    Events(items)
                }
                else -> null
            }
        }

        fun isBatchId(id: String): Boolean =
            try { UUID.fromString(id).toString().equals(id, ignoreCase = true) } catch (_: Exception) { false }
    }
}

object WatchMessages {
    fun hello(appVersion: String): ByteArray =
        JSONObject().put("t", "hello").put("v", GBLink.PROTOCOL_VERSION).put("app", appVersion).bytes()

    fun samples(batchId: String, items: List<HealthSample>): ByteArray =
        // "now" lets the phone correct for a wrong watch clock (e.g. no network time after a reboot).
        JSONObject().put("t", "samples").put("id", batchId).put("now", System.currentTimeMillis())
            .put("items", JSONArray(items.map { it.toJson() })).bytes()

    fun shutter(): ByteArray = JSONObject().put("t", "shutter").bytes()

    fun battery(percent: Int): ByteArray =
        JSONObject().put("t", "battery").put("pct", percent.coerceIn(0, 100)).bytes()

    fun findPhone(on: Boolean): ByteArray = JSONObject().put("t", "find").put("on", on).bytes()

    fun status(info: JSONObject): ByteArray = info.put("t", "status").bytes()

    private fun JSONObject.bytes() = toString().toByteArray(Charsets.UTF_8)
}
