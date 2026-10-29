package nz.galaxybridge.watch

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import androidx.wear.watchface.complications.data.ComplicationData
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.data.LongTextComplicationData
import androidx.wear.watchface.complications.data.MonochromaticImage
import androidx.wear.watchface.complications.data.PlainComplicationText
import androidx.wear.watchface.complications.data.RangedValueComplicationData
import androidx.wear.watchface.complications.data.ShortTextComplicationData
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester
import androidx.wear.watchface.complications.datasource.ComplicationRequest
import androidx.wear.watchface.complications.datasource.SuspendingComplicationDataSourceService
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

/**
 * The latest iPhone battery, weather and calendar, kept on disk so watch-face complications
 * can show them even when LinkService isn't the one asking.
 */
object PhoneInfo {
    private fun prefs(c: Context) = c.getSharedPreferences("phoneInfo", Context.MODE_PRIVATE)

    fun save(c: Context, m: PhoneMessage) {
        val e = prefs(c).edit()
        when (m) {
            is PhoneMessage.PhoneBattery -> e.putInt("pct", m.percent).putBoolean("charging", m.charging)
            is PhoneMessage.Weather -> e.putString("weather", JSONObject()
                .put("place", m.place).put("temp", m.tempC).put("hi", m.highC).put("lo", m.lowC)
                .put("code", m.code).put("at", m.at).toString())
            is PhoneMessage.Events -> e.putString("events", JSONArray(m.items.map {
                JSONObject().put("title", it.title).put("start", it.start).put("end", it.end).put("allDay", it.allDay)
            }).toString())
            else -> return
        }
        e.apply()
        val cls = when (m) {
            is PhoneMessage.PhoneBattery -> PhoneBatteryComplication::class.java
            is PhoneMessage.Weather -> WeatherComplication::class.java
            else -> NextEventComplication::class.java
        }
        ComplicationDataSourceUpdateRequester.create(c, ComponentName(c, cls)).requestUpdateAll()
    }

    fun load(c: Context) {
        val p = prefs(c)
        if (p.contains("pct")) LinkService.phoneBattery.value =
            PhoneMessage.PhoneBattery(p.getInt("pct", 0), p.getBoolean("charging", false))
        p.getString("weather", null)?.let { s ->
            runCatching { PhoneMessage.decode(JSONObject(s).put("t", "weather").toString().toByteArray()) }
                .getOrNull()?.let { LinkService.weather.value = it as PhoneMessage.Weather }
        }
        p.getString("events", null)?.let { s ->
            runCatching { PhoneMessage.decode(JSONObject().put("t", "events").put("items", JSONArray(s)).toString().toByteArray()) }
                .getOrNull()?.let { LinkService.events.value = (it as PhoneMessage.Events).items }
        }
    }

    fun battery(c: Context): Pair<Int, Boolean>? = prefs(c).takeIf { it.contains("pct") }
        ?.let { it.getInt("pct", 0) to it.getBoolean("charging", false) }
}

private fun Context.openApp(page: Int = MainActivity.PAGE_HOME): PendingIntent =
    PendingIntent.getActivity(this, page,
        Intent(this, MainActivity::class.java).putExtra(MainActivity.EXTRA_PAGE, page),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

private fun text(s: String) = PlainComplicationText.Builder(s).build()

class PhoneBatteryComplication : SuspendingComplicationDataSourceService() {
    override fun getPreviewData(type: ComplicationType) = build(type, 76, false)

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        val (pct, charging) = PhoneInfo.battery(this) ?: return build(request.complicationType, null, false)
        return build(request.complicationType, pct, charging)
    }

    private fun build(type: ComplicationType, pct: Int?, charging: Boolean): ComplicationData? {
        val label = pct?.let { "$it%" } ?: "--"
        val image = MonochromaticImage.Builder(Icon.createWithResource(this, R.drawable.ic_stat_iphone)).build()
        val description = text(if (pct == null) "iPhone battery unknown" else "iPhone battery $pct%" + if (charging) ", charging" else "")
        return when (type) {
            ComplicationType.RANGED_VALUE -> RangedValueComplicationData.Builder(
                (pct ?: 0).toFloat(), 0f, 100f, description)
                .setText(text(label)).setMonochromaticImage(image).setTapAction(openApp()).build()
            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(text(label), description)
                .setMonochromaticImage(image).setTapAction(openApp()).build()
            else -> null
        }
    }
}

class WeatherComplication : SuspendingComplicationDataSourceService() {
    override fun getPreviewData(type: ComplicationType) =
        ShortTextComplicationData.Builder(text("18°"), text("Weather")).build()

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        PhoneInfo.load(this)
        val w = LinkService.weather.value
        val t = w?.let { "${it.tempC.toInt()}°" } ?: "--"
        val desc = text(w?.let { "${it.place} ${it.tempC.toInt()} degrees" } ?: "Weather unavailable")
        return when (request.complicationType) {
            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(text(t), desc)
                .setTitle(w?.let { text("${it.highC.toInt()}/${it.lowC.toInt()}") })
                .setTapAction(openApp()).build()
            ComplicationType.LONG_TEXT -> LongTextComplicationData.Builder(
                text(w?.let { "$t ${it.place}  H${it.highC.toInt()}° L${it.lowC.toInt()}°" } ?: "Weather unavailable"), desc)
                .setTapAction(openApp()).build()
            else -> null
        }
    }
}

class NextEventComplication : SuspendingComplicationDataSourceService() {
    override fun getPreviewData(type: ComplicationType) =
        LongTextComplicationData.Builder(text("10:00 Team meeting"), text("Next event")).build()

    override suspend fun onComplicationRequest(request: ComplicationRequest): ComplicationData? {
        PhoneInfo.load(this)
        val now = System.currentTimeMillis()
        val next = LinkService.events.value.firstOrNull { it.end > now && !it.allDay }
        val time = next?.let { DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(it.start)) }
        val desc = text(next?.let { "Next: ${it.title} at $time" } ?: "No upcoming events")
        return when (request.complicationType) {
            ComplicationType.LONG_TEXT -> LongTextComplicationData.Builder(
                text(next?.let { "$time ${it.title}" } ?: "No more events"), desc).setTapAction(openApp()).build()
            ComplicationType.SHORT_TEXT -> ShortTextComplicationData.Builder(text(time ?: "--"), desc)
                .setTitle(next?.let { text(it.title.take(7)) }).setTapAction(openApp()).build()
            else -> null
        }
    }
}
