package nz.galaxybridge.watch

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONObject

/**
 * Settings the iPhone app can read and change. Each key has a fixed range; anything else is
 * rejected before it reaches here. App settings live in our prefs; system settings use the
 * normal Android permissions (Modify system settings, Do Not Disturb access), which the user
 * grants once on the watch.
 */
object WatchSettings {
    const val NOTIFICATIONS = "notify"
    const val CALLS = "calls"
    const val CLEAR_ON_IPHONE = "clearSync"
    const val MUSIC = "music"
    const val SYNC_HEART = "sync.hr"
    const val SYNC_STEPS = "sync.steps"
    const val SYNC_ENERGY = "sync.kcal"
    const val SYNC_DISTANCE = "sync.dist"
    const val BRIGHTNESS = "brightness"
    const val SCREEN_TIMEOUT = "timeout"
    const val DND = "dnd"

    private val APP_KEYS = mapOf(
        NOTIFICATIONS to 1, CALLS to 1, CLEAR_ON_IPHONE to 1, MUSIC to 1,
        SYNC_HEART to 1, SYNC_STEPS to 1, SYNC_ENERGY to 1, SYNC_DISTANCE to 1,
    )
    private val RANGES = APP_KEYS.mapValues { 0..1 } + mapOf(
        BRIGHTNESS to 1..255,
        SCREEN_TIMEOUT to 5..600, // seconds
        DND to 0..1,
    )

    /** Bumped whenever something changes, so the UI and the phone refresh. */
    val changes = MutableStateFlow(0)

    fun isValid(key: String, value: Int) = RANGES[key]?.contains(value) == true

    private fun prefs(c: Context) = c.getSharedPreferences("settings", Context.MODE_PRIVATE)

    fun enabled(c: Context, key: String): Boolean =
        prefs(c).getInt(key, APP_KEYS[key] ?: 0) == 1

    fun syncs(c: Context, kind: SampleKind) = enabled(c, when (kind) {
        SampleKind.HEART_RATE -> SYNC_HEART
        SampleKind.STEPS -> SYNC_STEPS
        SampleKind.ACTIVE_ENERGY -> SYNC_ENERGY
        SampleKind.DISTANCE -> SYNC_DISTANCE
    })

    fun canWriteSystem(c: Context) = Settings.System.canWrite(c)
    fun canChangeDnd(c: Context) = c.getSystemService(NotificationManager::class.java).isNotificationPolicyAccessGranted

    /** Applies a validated setting. Returns false if the watch hasn't granted the permission. */
    fun set(c: Context, key: String, value: Int): Boolean {
        if (!isValid(key, value)) return false
        val ok = when (key) {
            in APP_KEYS -> { prefs(c).edit().putInt(key, value).apply(); true }
            BRIGHTNESS -> canWriteSystem(c) && runCatching {
                Settings.System.putInt(c.contentResolver, Settings.System.SCREEN_BRIGHTNESS_MODE,
                    Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL)
                Settings.System.putInt(c.contentResolver, Settings.System.SCREEN_BRIGHTNESS, value)
            }.getOrDefault(false)
            SCREEN_TIMEOUT -> canWriteSystem(c) && runCatching {
                Settings.System.putInt(c.contentResolver, Settings.System.SCREEN_OFF_TIMEOUT, value * 1000)
            }.getOrDefault(false)
            DND -> canChangeDnd(c) && runCatching {
                c.getSystemService(NotificationManager::class.java).setInterruptionFilter(
                    if (value == 1) NotificationManager.INTERRUPTION_FILTER_PRIORITY
                    else NotificationManager.INTERRUPTION_FILTER_ALL)
                true
            }.getOrDefault(false)
            else -> false
        }
        if (ok) changes.value++
        return ok
    }

    private fun system(c: Context, name: String, default: Int) =
        runCatching { Settings.System.getInt(c.contentResolver, name) }.getOrDefault(default)

    /** Everything the iPhone app shows on its watch screen. */
    fun status(c: Context, battery: Int, charging: Boolean): JSONObject {
        val settings = JSONObject()
        for (k in APP_KEYS.keys) settings.put(k, if (enabled(c, k)) 1 else 0)
        settings.put(BRIGHTNESS, system(c, Settings.System.SCREEN_BRIGHTNESS, 128).coerceIn(1, 255))
        settings.put(SCREEN_TIMEOUT, (system(c, Settings.System.SCREEN_OFF_TIMEOUT, 15_000) / 1000).coerceIn(5, 600))
        val nm = c.getSystemService(NotificationManager::class.java)
        settings.put(DND, if (nm.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL) 1 else 0)

        val stat = StatFs(Environment.getDataDirectory().path)
        return JSONObject()
            .put("model", Build.MODEL.take(32))
            .put("os", "Wear OS · Android ${Build.VERSION.RELEASE}".take(32))
            .put("app", BuildConfig.VERSION_NAME)
            .put("pct", battery.coerceIn(0, 100))
            .put("charging", charging)
            .put("freeMB", (stat.availableBytes / 1_000_000).toInt())
            .put("totalMB", (stat.totalBytes / 1_000_000).toInt())
            .put("settings", settings)
            .put("perms", JSONObject()
                .put("system", canWriteSystem(c))
                .put("dnd", canChangeDnd(c))
                .put("ancs", AppleClient.connected.value))
    }
}
