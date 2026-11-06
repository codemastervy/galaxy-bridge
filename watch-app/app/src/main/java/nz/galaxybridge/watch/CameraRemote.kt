package nz.galaxybridge.watch

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject

/**
 * Live preview and controls for Wear OS Bridge's own iPhone camera. While the watch shows the
 * camera page it asks for frames ("camView"); the phone sends small JPEGs about twice a second.
 */
object CameraRemote {
    val frame = MutableStateFlow<Bitmap?>(null)
    /** Phone camera state: "front", "timer" (seconds), "open". */
    val front = MutableStateFlow(false)
    val timer = MutableStateFlow(0)
    val open = MutableStateFlow(false)

    fun frame(j: JSONObject) {
        val bytes = runCatching { Base64.decode(j.optString("data"), Base64.DEFAULT) }.getOrNull() ?: return
        if (bytes.size > 60_000) return
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
        if (opts.outWidth !in 1..640 || opts.outHeight !in 1..640) return
        frame.value = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }

    fun state(j: JSONObject) {
        front.value = j.optBoolean("front", false)
        timer.value = j.optInt("timer", 0).coerceIn(0, 10)
        open.value = j.optBoolean("open", false)
        if (!open.value) frame.value = null
    }

    fun view(on: Boolean) {
        LinkService.sendFeature("camView", JSONObject().put("on", on))
        if (!on) frame.value = null
    }

    /** "shoot", "flip" or "timer" (cycles off → 3 s → 10 s). */
    fun command(cmd: String) = LinkService.sendFeature("camCmd", JSONObject().put("cmd", cmd))
}
