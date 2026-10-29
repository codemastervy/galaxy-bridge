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
    data class Hello(val protocolVersion: Int, val appVersion: String) : PhoneMessage()
    data class Ack(val batchId: String) : PhoneMessage()

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
                    Hello(json.optInt("v"), app)
                }
                "ack" -> {
                    val id = json.optString("id", "")
                    if (!isBatchId(id)) return null
                    Ack(id)
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
        JSONObject().put("t", "samples").put("id", batchId)
            .put("items", JSONArray(items.map { it.toJson() })).bytes()

    fun shutter(): ByteArray = JSONObject().put("t", "shutter").bytes()

    fun battery(percent: Int): ByteArray =
        JSONObject().put("t", "battery").put("pct", percent.coerceIn(0, 100)).bytes()

    private fun JSONObject.bytes() = toString().toByteArray(Charsets.UTF_8)
}
