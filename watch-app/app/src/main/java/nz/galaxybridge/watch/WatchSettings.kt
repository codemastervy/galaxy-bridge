package nz.galaxybridge.watch

import android.app.NotificationManager
import android.media.AudioManager
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
    const val SYNC_FLOORS = "sync.floors"
    const val AOD = "aod"
    const val RAISE_TO_WAKE = "raise"
    const val TAP_TO_WAKE = "tapWake"
    const val BEZEL_WAKE = "bezelWake"
    const val TOUCH_SENSITIVITY = "touchSens"
    const val THEATRE = "theatre"
    const val BATTERY_SAVER = "saver"
    const val WATER_LOCK = "waterLock"
    const val BEDTIME = "bedtime"
    /** 0–4: small, default, large, larger, largest. */
    const val FONT_SIZE = "font"
    const val VOLUME_NOTIFY = "vol.notify"
    const val VOLUME_ALARM = "vol.alarm"
    private val FONT_SCALES = floatArrayOf(0.85f, 1.0f, 1.15f, 1.3f, 1.45f)
    const val BRIGHTNESS = "brightness"
    const val SCREEN_TIMEOUT = "timeout"
    const val DND = "dnd"
    /** 0–15, scaled to the watch's own stream range. */
    const val VOLUME_MEDIA = "vol.media"
    const val VOLUME_RING = "vol.ring"
    /** 0 sound, 1 vibrate, 2 mute. */
    const val SOUND_MODE = "sound"

    private val APP_KEYS = mapOf(
        NOTIFICATIONS to 1, CALLS to 1, CLEAR_ON_IPHONE to 1, MUSIC to 1,
        SYNC_HEART to 1, SYNC_STEPS to 1, SYNC_ENERGY to 1, SYNC_DISTANCE to 1, SYNC_FLOORS to 1,
    )
    private val RANGES = APP_KEYS.mapValues { 0..1 } + mapOf(
        BRIGHTNESS to 1..255,
        SCREEN_TIMEOUT to 5..600, // seconds
        DND to 0..1,
        VOLUME_MEDIA to 0..15,
        VOLUME_RING to 0..15,
        SOUND_MODE to 0..2,
        VOLUME_NOTIFY to 0..15,
        VOLUME_ALARM to 0..15,
        FONT_SIZE to 0..4,
    ) + SECURE_TOGGLES.keys.associateWith { 0..1 }

    /** On/off system settings that need WRITE_SECURE_SETTINGS (granted once over adb): key → (table, name). */
    private val SECURE_TOGGLES: Map<String, Pair<String, String>>
        get() = mapOf(
            AOD to ("global" to "ambient_enabled"),
            RAISE_TO_WAKE to ("secure" to "wake_gesture_enabled"),
            TAP_TO_WAKE to ("secure" to "double_tap_to_wake"),
            BEZEL_WAKE to ("global" to "setting_wake_by_turning_bezel"),
            TOUCH_SENSITIVITY to ("system" to "setting_touch_sensitivity_on"),
            THEATRE to ("global" to "setting_theater_mode_on"),
            BATTERY_SAVER to ("global" to "low_power"),
            WATER_LOCK to ("global" to "setting_water_lock_on"),
            BEDTIME to ("global" to "setting_bedtime_mode_running_state"),
        )

    fun canWriteSecure(c: Context) =
        c.checkSelfPermission(android.Manifest.permission.WRITE_SECURE_SETTINGS) == android.content.pm.PackageManager.PERMISSION_GRANTED

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
        SampleKind.FLOORS -> SYNC_FLOORS
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
            VOLUME_MEDIA -> setVolume(c, AudioManager.STREAM_MUSIC, value)
            VOLUME_NOTIFY -> setVolume(c, AudioManager.STREAM_NOTIFICATION, value)
            VOLUME_ALARM -> setVolume(c, AudioManager.STREAM_ALARM, value)
            FONT_SIZE -> (canWriteSystem(c) || canWriteSecure(c)) && runCatching {
                Settings.System.putFloat(c.contentResolver, Settings.System.FONT_SCALE, FONT_SCALES[value])
            }.getOrDefault(false)
            in SECURE_TOGGLES -> canWriteSecure(c) && runCatching {
                val (table, name) = SECURE_TOGGLES.getValue(key)
                val cr = c.contentResolver
                when (table) {
                    "global" -> Settings.Global.putInt(cr, name, value)
                    "secure" -> Settings.Secure.putInt(cr, name, value)
                    else -> Settings.System.putInt(cr, name, value)
                }
                // Samsung keeps theatre mode in two places; keep the AOSP one in step.
                if (key == THEATRE) Settings.Global.putInt(cr, "theater_mode_on", value)
                true
            }.getOrDefault(false)
            VOLUME_RING -> setVolume(c, AudioManager.STREAM_RING, value)
            // Mute needs Do Not Disturb access; sound and vibrate don't.
            SOUND_MODE -> (value != 2 || canChangeDnd(c)) && runCatching {
                c.getSystemService(AudioManager::class.java).ringerMode = when (value) {
                    0 -> AudioManager.RINGER_MODE_NORMAL
                    1 -> AudioManager.RINGER_MODE_VIBRATE
                    else -> AudioManager.RINGER_MODE_SILENT
                }
                true
            }.getOrDefault(false)
            else -> false
        }
        if (ok) changes.value++
        return ok
    }

    private fun setVolume(c: Context, stream: Int, level: Int) = runCatching {
        val am = c.getSystemService(AudioManager::class.java)
        val max = am.getStreamMaxVolume(stream)
        am.setStreamVolume(stream, (level * max + 7) / 15, 0)
        true
    }.getOrDefault(false)

    private fun volume(c: Context, stream: Int): Int {
        val am = c.getSystemService(AudioManager::class.java)
        val max = am.getStreamMaxVolume(stream).coerceAtLeast(1)
        return (am.getStreamVolume(stream) * 15 + max / 2) / max
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
        settings.put(VOLUME_MEDIA, volume(c, AudioManager.STREAM_MUSIC))
        settings.put(VOLUME_RING, volume(c, AudioManager.STREAM_RING))
        settings.put(VOLUME_NOTIFY, volume(c, AudioManager.STREAM_NOTIFICATION))
        settings.put(VOLUME_ALARM, volume(c, AudioManager.STREAM_ALARM))
        val scale = runCatching { Settings.System.getFloat(c.contentResolver, Settings.System.FONT_SCALE) }.getOrDefault(1f)
        settings.put(FONT_SIZE, FONT_SCALES.indices.minByOrNull { kotlin.math.abs(FONT_SCALES[it] - scale) } ?: 1)
        for ((k, where) in SECURE_TOGGLES) {
            val cr = c.contentResolver
            val v = runCatching {
                when (where.first) {
                    "global" -> Settings.Global.getInt(cr, where.second)
                    "secure" -> Settings.Secure.getInt(cr, where.second)
                    else -> Settings.System.getInt(cr, where.second)
                }
            }.getOrNull()
            if (v != null) settings.put(k, if (v != 0) 1 else 0)
        }
        settings.put(SOUND_MODE, when (c.getSystemService(AudioManager::class.java).ringerMode) {
            AudioManager.RINGER_MODE_NORMAL -> 0
            AudioManager.RINGER_MODE_VIBRATE -> 1
            else -> 2
        })
        settings.put(DND, if (nm.currentInterruptionFilter > NotificationManager.INTERRUPTION_FILTER_ALL) 1 else 0)

        val stat = StatFs(Environment.getDataDirectory().path)
        return JSONObject()
            .put("model", Build.MODEL.take(32))
            .put("os", "Wear OS · Android ${Build.VERSION.RELEASE}".take(32))
            .put("app", BuildConfig.VERSION_NAME)
            .put("time", System.currentTimeMillis())
            .put("pct", battery.coerceIn(0, 100))
            .put("charging", charging)
            .put("freeMB", (stat.availableBytes / 1_000_000).toInt())
            .put("totalMB", (stat.totalBytes / 1_000_000).toInt())
            .put("settings", settings)
            .put("perms", JSONObject()
                .put("system", canWriteSystem(c))
                .put("dnd", canChangeDnd(c))
                .put("secure", canWriteSecure(c))
                .put("ancs", AppleClient.connected.value))
    }
}
