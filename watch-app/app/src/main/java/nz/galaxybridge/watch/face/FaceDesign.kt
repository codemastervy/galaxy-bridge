package nz.galaxybridge.watch.face

import android.content.Context
import android.graphics.Color
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject

/**
 * One design for the Wear OS Bridge watch face, chosen in the iPhone app's face gallery.
 * Must match FaceDesign in the iPhone app (FaceCatalog.swift): same layouts, same colour keys.
 */
data class FaceDesign(
    val id: String,
    val name: String,
    val layout: String,
    val bg1: Int,
    val bg2: Int,
    val accent: Int,
    val ink: Int,
) {
    val dim: Int get() = (ink and 0x00FFFFFF) or (0x70 shl 24)

    fun toJson(): JSONObject = JSONObject().put("id", id).put("name", name).put("layout", layout)
        .put("bg1", hex(bg1)).put("bg2", hex(bg2)).put("accent", hex(accent)).put("ink", hex(ink))

    companion object {
        val LAYOUTS = setOf("classic", "minimal", "bold", "digital", "ring", "orbit", "sport", "radar")
        val DEFAULT = FaceDesign("aurora-classic", "Aurora Classic", "classic",
            0xFF1B1E4B.toInt(), 0xFF05060F.toInt(), 0xFF2ED1DB.toInt(), Color.WHITE)

        private const val PREFS = "face"
        val current = MutableStateFlow(DEFAULT)
        @Volatile private var loaded = false

        fun load(c: Context): FaceDesign {
            if (!loaded) {
                loaded = true
                c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("design", null)
                    ?.let { runCatching { parse(JSONObject(it)) }.getOrNull() }?.let { current.value = it }
            }
            return current.value
        }

        fun save(c: Context, d: FaceDesign) {
            c.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("design", d.toJson().toString()).apply()
            loaded = true
            current.value = d
        }

        /** Validates everything from the phone; returns null for anything unexpected. */
        fun parse(j: JSONObject): FaceDesign? {
            val layout = j.optString("layout").takeIf { it in LAYOUTS } ?: return null
            val id = j.optString("id").takeIf { it.length in 1..60 && it.all { ch -> ch.isLetterOrDigit() || ch == '-' } } ?: return null
            val name = j.optString("name").filter { !it.isISOControl() }.take(40).ifEmpty { return null }
            return FaceDesign(id, name, layout,
                color(j, "bg1") ?: return null, color(j, "bg2") ?: return null,
                color(j, "accent") ?: return null, color(j, "ink") ?: return null)
        }

        private val HEX = Regex("^#[0-9A-Fa-f]{6}$")
        private fun color(j: JSONObject, k: String): Int? =
            j.optString(k).takeIf { HEX.matches(it) }?.let { (0xFF000000 or it.substring(1).toLong(16)).toInt() }

        private fun hex(c: Int) = "#%06X".format(c and 0xFFFFFF)
    }
}
