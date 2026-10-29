package nz.galaxybridge.watch

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/**
 * Apple Notification Center Service (ANCS): the iPhone's GATT service that lets a bonded
 * accessory see, and act on, the phone's notifications. Byte layouts follow Apple's
 * "ANCS Specification". Everything parsed here comes off the air, so parsers are strict and
 * bounded and return null rather than throwing on bad input.
 */
object Ancs {
    val SERVICE: UUID = UUID.fromString("7905F431-B5CE-4E99-A40F-4B1E122D00D0")
    val NOTIFICATION_SOURCE: UUID = UUID.fromString("9FBF120D-6301-42D9-8C58-25E699A21DBD")
    val CONTROL_POINT: UUID = UUID.fromString("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9")
    val DATA_SOURCE: UUID = UUID.fromString("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB")

    const val EVENT_ADDED = 0
    const val EVENT_MODIFIED = 1
    const val EVENT_REMOVED = 2

    const val FLAG_SILENT = 1 shl 0
    const val FLAG_IMPORTANT = 1 shl 1
    const val FLAG_PRE_EXISTING = 1 shl 2
    const val FLAG_POSITIVE_ACTION = 1 shl 3
    const val FLAG_NEGATIVE_ACTION = 1 shl 4

    const val CATEGORY_INCOMING_CALL = 1
    const val CATEGORY_MISSED_CALL = 2
    const val CATEGORY_VOICEMAIL = 3

    private const val CMD_NOTIFICATION_ATTRIBUTES = 0
    private const val CMD_APP_ATTRIBUTES = 1
    private const val CMD_PERFORM_ACTION = 2

    private const val ATTR_APP_ID = 0
    private const val ATTR_TITLE = 1
    private const val ATTR_SUBTITLE = 2
    private const val ATTR_MESSAGE = 3
    private const val ATTR_POSITIVE_LABEL = 6
    private const val ATTR_NEGATIVE_LABEL = 7
    private const val APP_ATTR_DISPLAY_NAME = 0

    private const val MAX_TITLE = 64
    private const val MAX_MESSAGE = 512

    data class Event(val kind: Int, val flags: Int, val category: Int, val uid: Int) {
        fun has(flag: Int) = flags and flag != 0
    }

    data class Details(
        val uid: Int,
        val appId: String,
        val title: String,
        val subtitle: String,
        val message: String,
        val positiveLabel: String,
        val negativeLabel: String,
    )

    fun parseEvent(b: ByteArray): Event? {
        if (b.size != 8) return null
        val kind = b[0].toInt() and 0xFF
        if (kind > EVENT_REMOVED) return null
        return Event(kind, b[1].toInt() and 0xFF, b[2].toInt() and 0xFF, le32(b, 4))
    }

    fun getNotificationAttributes(uid: Int): ByteArray =
        byteArrayOf(CMD_NOTIFICATION_ATTRIBUTES.toByte()) + le32(uid) + byteArrayOf(
            ATTR_APP_ID.toByte(),
            ATTR_TITLE.toByte(), MAX_TITLE.toByte(), 0,
            ATTR_SUBTITLE.toByte(), MAX_TITLE.toByte(), 0,
            ATTR_MESSAGE.toByte(), (MAX_MESSAGE and 0xFF).toByte(), (MAX_MESSAGE shr 8).toByte(),
            ATTR_POSITIVE_LABEL.toByte(),
            ATTR_NEGATIVE_LABEL.toByte(),
        )

    fun getAppAttributes(appId: String): ByteArray =
        byteArrayOf(CMD_APP_ATTRIBUTES.toByte()) + appId.toByteArray(Charsets.UTF_8) +
            byteArrayOf(0, APP_ATTR_DISPLAY_NAME.toByte())

    fun performAction(uid: Int, positive: Boolean): ByteArray =
        byteArrayOf(CMD_PERFORM_ACTION.toByte()) + le32(uid) + byteArrayOf(if (positive) 0 else 1)

    private const val NOTIFICATION_ATTR_COUNT = 6

    /**
     * Data Source responses can span several notifications. Feed chunks in; a result comes
     * back once a whole response has arrived. Only one request is outstanding at a time.
     */
    class Responses {
        private var buf = ByteArray(0)

        sealed class Result {
            data class Notification(val details: Details) : Result()
            data class AppName(val appId: String, val name: String) : Result()
        }

        fun reset() { buf = ByteArray(0) }

        fun append(chunk: ByteArray): Result? {
            buf += chunk
            if (buf.size > 4096) { reset(); return null }
            val r = parse(buf) ?: return null
            reset()
            return r
        }

        private fun parse(b: ByteArray): Result? {
            if (b.isEmpty()) return null
            return when (b[0].toInt()) {
                CMD_NOTIFICATION_ATTRIBUTES -> {
                    if (b.size < 5) return null
                    val attrs = attributes(b, 5, NOTIFICATION_ATTR_COUNT) ?: return null
                    Result.Notification(Details(
                        uid = le32(b, 1),
                        appId = attrs[ATTR_APP_ID].orEmpty(),
                        title = attrs[ATTR_TITLE].orEmpty(),
                        subtitle = attrs[ATTR_SUBTITLE].orEmpty(),
                        message = attrs[ATTR_MESSAGE].orEmpty(),
                        positiveLabel = attrs[ATTR_POSITIVE_LABEL].orEmpty(),
                        negativeLabel = attrs[ATTR_NEGATIVE_LABEL].orEmpty(),
                    ))
                }
                CMD_APP_ATTRIBUTES -> {
                    val end = b.indexOfFirst(1) { it == 0.toByte() }
                    if (end < 0) return null
                    val appId = String(b, 1, end - 1, Charsets.UTF_8)
                    val attrs = attributes(b, end + 1, 1) ?: return null
                    Result.AppName(appId, attrs[APP_ATTR_DISPLAY_NAME].orEmpty())
                }
                else -> { reset(); null }
            }
        }

        /** Reads `count` (id, uint16 LE length, bytes) tuples, or null if not all here yet. */
        private fun attributes(b: ByteArray, from: Int, count: Int): Map<Int, String>? {
            val out = HashMap<Int, String>()
            var i = from
            repeat(count) {
                if (i + 3 > b.size) return null
                val id = b[i].toInt() and 0xFF
                val len = (b[i + 1].toInt() and 0xFF) or ((b[i + 2].toInt() and 0xFF) shl 8)
                if (i + 3 + len > b.size) return null
                out[id] = clean(String(b, i + 3, len, Charsets.UTF_8))
                i += 3 + len
            }
            return out
        }
    }

    private fun ByteArray.indexOfFirst(from: Int, p: (Byte) -> Boolean): Int {
        for (i in from until size) if (p(this[i])) return i
        return -1
    }

    private fun le32(b: ByteArray, at: Int) = ByteBuffer.wrap(b, at, 4).order(ByteOrder.LITTLE_ENDIAN).int
    private fun le32(v: Int) = ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array()
}

/** Strips control characters (except newlines) from text that came off the air. */
internal fun clean(s: String): String =
    s.filter { it == '\n' || !it.isISOControl() }.replace(' ', '\n').trim()

/**
 * Apple Media Service (AMS): now-playing info and remote control for the iPhone's media player.
 */
object Ams {
    val SERVICE: UUID = UUID.fromString("89D3502B-0F36-433A-8EF4-C502AD55F8DC")
    val REMOTE_COMMAND: UUID = UUID.fromString("9B3C81D8-57B1-4A8A-B8DF-0E56F7CA51C2")
    val ENTITY_UPDATE: UUID = UUID.fromString("2F7CABCE-808D-411F-9A0C-BB92BA96C102")

    const val CMD_PLAY = 0
    const val CMD_PAUSE = 1
    const val CMD_TOGGLE = 2
    const val CMD_NEXT = 3
    const val CMD_PREVIOUS = 4
    const val CMD_VOLUME_UP = 5
    const val CMD_VOLUME_DOWN = 6

    private const val ENTITY_PLAYER = 0
    private const val ENTITY_TRACK = 2

    /** Subscribe to player name, playback info and volume. */
    val SUBSCRIBE_PLAYER = byteArrayOf(ENTITY_PLAYER.toByte(), 0, 1, 2)
    /** Subscribe to artist, album, title and duration. */
    val SUBSCRIBE_TRACK = byteArrayOf(ENTITY_TRACK.toByte(), 0, 1, 2, 3)

    data class NowPlaying(
        val player: String = "",
        val playing: Boolean = false,
        val elapsedSec: Double = 0.0,
        val elapsedAt: Long = 0,
        val volume: Float = 0f,
        val artist: String = "",
        val album: String = "",
        val title: String = "",
        val durationSec: Double = 0.0,
    ) {
        val active get() = player.isNotEmpty() || title.isNotEmpty()

        /** Applies one Entity Update notification: [entity, attribute, flags, UTF-8 value]. */
        fun apply(b: ByteArray, now: Long = System.currentTimeMillis()): NowPlaying {
            if (b.size < 3) return this
            val entity = b[0].toInt()
            val attr = b[1].toInt()
            val value = clean(String(b, 3, b.size - 3, Charsets.UTF_8)).take(128)
            return when (entity) {
                ENTITY_PLAYER -> when (attr) {
                    0 -> copy(player = value)
                    1 -> {
                        // "state,rate,elapsed": state 1 = playing.
                        val parts = value.split(',')
                        copy(
                            playing = parts.getOrNull(0)?.trim() == "1",
                            elapsedSec = parts.getOrNull(2)?.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 } ?: 0.0,
                            elapsedAt = now,
                        )
                    }
                    2 -> copy(volume = value.toFloatOrNull()?.takeIf { it in 0f..1f } ?: volume)
                    else -> this
                }
                ENTITY_TRACK -> when (attr) {
                    0 -> copy(artist = value)
                    1 -> copy(album = value)
                    2 -> copy(title = value)
                    3 -> copy(durationSec = value.toDoubleOrNull()?.takeIf { it.isFinite() && it >= 0 } ?: 0.0)
                    else -> this
                }
                else -> this
            }
        }
    }
}
