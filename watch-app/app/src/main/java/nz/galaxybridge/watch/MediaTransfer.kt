package nz.galaxybridge.watch

import android.content.ContentUris
import android.content.ContentValues
import android.graphics.BitmapFactory
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * Photos from the iPhone into the watch's Gallery, and voice recordings from the watch to the
 * iPhone. Both go over the Bluetooth link in base64 parts of a few tens of KB.
 */
object MediaTransfer {
    private const val TAG = "MediaTransfer"
    private const val MAX_PHOTO = 4 * 1024 * 1024
    /** Raw bytes per recording part; base64 makes it ~43 KB, under the 64 KB message cap. */
    private const val PART = 32 * 1024

    private var photoId = ""
    private var photoParts = 0
    private val photo = ByteArrayOutputStream()

    /** {"id", "part", "parts", "name", "data"}: parts arrive in order over the ordered link. */
    fun receivePhoto(s: LinkService, j: JSONObject) {
        val id = j.optString("id").take(64)
        val part = j.optInt("part", -1)
        val parts = j.optInt("parts", -1)
        if (id.isEmpty() || parts !in 1..200 || part !in 0 until parts) return
        if (part == 0) { photoId = id; photoParts = parts; photo.reset() }
        if (id != photoId || parts != photoParts) return
        val bytes = runCatching { Base64.decode(j.optString("data"), Base64.DEFAULT) }.getOrNull() ?: return reset()
        if (photo.size() + bytes.size > MAX_PHOTO) return reset()
        photo.write(bytes)
        if (part < parts - 1) return
        val data = photo.toByteArray()
        reset()
        // Only save real images: decode the header before writing anything.
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, opts)
        if (opts.outWidth <= 0 || opts.outMimeType != "image/jpeg") return Features.result(s, "photo", false, "Not a JPEG")
        val name = Features.clean(j.optString("name")).filter { it.isLetterOrDigit() || it in "-_ " }.take(40).ifEmpty { "iPhone" }
        val ok = runCatching {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, "$name-${System.currentTimeMillis()}.jpg")
                put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/Wear OS Bridge")
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = s.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
            s.contentResolver.openOutputStream(uri)!!.use { it.write(data) }
            values.clear(); values.put(MediaStore.Images.Media.IS_PENDING, 0)
            s.contentResolver.update(uri, values, null, null)
            true
        }.onFailure { Log.w(TAG, "save photo", it) }.getOrDefault(false)
        Features.result(s, "photo", ok, if (ok) "Saved to Gallery" else "Couldn't save")
    }

    private fun reset() { photoId = ""; photoParts = 0; photo.reset() }

    fun listRecordings(s: LinkService) {
        val out = JSONArray()
        runCatching {
            s.contentResolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.DISPLAY_NAME, MediaStore.Audio.Media.DURATION,
                    MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DATE_ADDED, MediaStore.Audio.Media.RELATIVE_PATH),
                null, null, "${MediaStore.Audio.Media.DATE_ADDED} DESC")?.use { c ->
                while (c.moveToNext() && out.length() < 100) {
                    val path = c.getString(5) ?: ""
                    if (!path.startsWith("Recordings") && !path.contains("Voice", ignoreCase = true)) continue
                    out.put(JSONObject().put("id", c.getLong(0)).put("name", c.getString(1).take(60))
                        .put("ms", c.getLong(2)).put("bytes", c.getLong(3)).put("at", c.getLong(4) * 1000))
                }
            }
        }.onFailure { Log.w(TAG, "list recordings", it) }
        s.send(WatchMessages.feature("recordings", JSONObject().put("items", out)))
    }

    fun sendRecording(s: LinkService, id: Long) {
        if (id < 0) return
        val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
        val bytes = runCatching { s.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
        if (bytes == null || bytes.size > 40 * 1024 * 1024) return Features.result(s, "recording", false, "Couldn't read it")
        val parts = maxOf(1, (bytes.size + PART - 1) / PART)
        for (i in 0 until parts) {
            val chunk = bytes.copyOfRange(i * PART, minOf(bytes.size, (i + 1) * PART))
            s.send(WatchMessages.feature("recPart", JSONObject().put("id", id).put("part", i).put("parts", parts)
                .put("data", Base64.encodeToString(chunk, Base64.NO_WRAP))))
        }
    }
}
