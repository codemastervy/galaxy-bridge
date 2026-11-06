package nz.galaxybridge.watch

import android.content.Context
import android.os.SystemClock
import android.util.Log
import androidx.health.services.client.ExerciseUpdateCallback
import androidx.health.services.client.HealthServices
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.ExerciseConfig
import androidx.health.services.client.data.ExerciseLapSummary
import androidx.health.services.client.data.ExerciseType
import androidx.health.services.client.data.ExerciseUpdate
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.guava.await
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant
import java.util.UUID

/**
 * Workouts recorded with Health Services (heart rate, distance, calories, GPS route). Each
 * finished workout is saved to disk and sent to the iPhone, which writes it to Apple Health
 * as a workout with its route, then acks so the watch can delete it.
 */
object Workouts {
    private const val TAG = "Workouts"

    enum class Kind(val wire: String, val label: String, val type: ExerciseType) {
        RUN("run", "Run", ExerciseType.RUNNING),
        WALK("walk", "Walk", ExerciseType.WALKING),
        CYCLE("cycle", "Cycle", ExerciseType.BIKING),
        HIKE("hike", "Hike", ExerciseType.HIKING),
        OTHER("other", "Workout", ExerciseType.WORKOUT),
    }

    data class Live(val kind: Kind, val startMs: Long, val hr: Double = 0.0, val distM: Double = 0.0,
                    val kcal: Double = 0.0, val gps: Boolean = false)

    val live = MutableStateFlow<Live?>(null)
    /** Elapsed-realtime when the workout started, for the on-screen clock. */
    var startedAt = 0L
        private set

    private val hrPoints = ArrayList<Pair<Long, Double>>()
    private val route = ArrayList<DoubleArray>() // [t, lat, lon, alt]
    private var hrMax = 0.0

    private fun dir(c: Context) = File(c.filesDir, "workouts").apply { mkdirs() }

    suspend fun start(c: Context, kind: Kind): String? {
        val client = HealthServices.getClient(c).exerciseClient
        val caps = runCatching { client.getCapabilitiesAsync().await() }.getOrElse { return "Health Services unavailable" }
        val typeCaps = caps.typeToCapabilities[kind.type] ?: return "${kind.label} isn't supported on this watch"
        val wanted = setOf(DataType.HEART_RATE_BPM, DataType.DISTANCE_TOTAL, DataType.CALORIES_TOTAL, DataType.LOCATION)
        val types = wanted.intersect(typeCaps.supportedDataTypes)
        val gps = DataType.LOCATION in types &&
            c.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        val config = ExerciseConfig.builder(kind.type)
            .setDataTypes(if (gps) types else types - DataType.LOCATION)
            .setIsAutoPauseAndResumeEnabled(false)
            .setIsGpsEnabled(gps)
            .build()
        hrPoints.clear(); route.clear(); hrMax = 0.0
        client.setUpdateCallback(callback)
        return runCatching {
            client.startExerciseAsync(config).await()
            startedAt = SystemClock.elapsedRealtime()
            live.value = Live(kind, System.currentTimeMillis(), gps = gps)
            null
        }.getOrElse { Log.w(TAG, "start", it); "Couldn't start: ${it.message?.take(60)}" }
    }

    suspend fun stop(c: Context) {
        val current = live.value ?: return
        runCatching { HealthServices.getClient(c).exerciseClient.endExerciseAsync().await() }
            .onFailure { Log.w(TAG, "end", it) }
        live.value = null
        val end = System.currentTimeMillis()
        if (end - current.startMs < 60_000) return // too short to keep
        val id = UUID.randomUUID().toString()
        val json = JSONObject()
            .put("id", id).put("kind", current.kind.wire).put("start", current.startMs).put("end", end)
            .put("kcal", current.kcal).put("dist", current.distM)
            .put("hrAvg", if (hrPoints.isEmpty()) 0.0 else hrPoints.sumOf { it.second } / hrPoints.size)
            .put("hrMax", hrMax)
            .put("hr", JSONArray(sample(hrPoints, 300).map { JSONArray().put(it.first).put(it.second) }))
            .put("route", JSONArray(sample(route, 900).map { p ->
                JSONArray().put(p[0].toLong()).put(round(p[1], 6)).put(round(p[2], 6)).put(round(p[3], 1))
            }))
        File(dir(c), "$id.json").writeText(json.toString())
        flush(c)
    }

    /** Sends every finished workout the iPhone hasn't acknowledged yet. */
    fun flush(c: Context) {
        for (f in dir(c).listFiles().orEmpty().filter { it.extension == "json" }) {
            val body = runCatching { JSONObject(f.readText()) }.getOrNull() ?: continue
            if (!LinkService.sendFeature("workout", body)) return
        }
    }

    fun ack(c: Context, id: String) {
        if (!GBLinkIds.isUuid(id)) return
        File(dir(c), "$id.json").delete()
    }

    private val callback = object : ExerciseUpdateCallback {
        override fun onExerciseUpdateReceived(update: ExerciseUpdate) {
            val m = update.latestMetrics
            val boot = Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())
            var cur = live.value ?: return
            for (p in m.getData(DataType.HEART_RATE_BPM)) {
                val t = p.getTimeInstant(boot).toEpochMilli()
                if (p.value in 25.0..250.0) { hrPoints += t to p.value; hrMax = maxOf(hrMax, p.value); cur = cur.copy(hr = p.value) }
            }
            m.getData(DataType.DISTANCE_TOTAL)?.let { cur = cur.copy(distM = it.total) }
            m.getData(DataType.CALORIES_TOTAL)?.let { cur = cur.copy(kcal = it.total) }
            for (p in m.getData(DataType.LOCATION)) {
                val v = p.value
                route += doubleArrayOf(p.getTimeInstant(boot).toEpochMilli().toDouble(), v.latitude, v.longitude,
                    if (v.altitude.isFinite()) v.altitude else 0.0)
            }
            live.value = cur
        }
        override fun onLapSummaryReceived(lapSummary: ExerciseLapSummary) {}
        override fun onRegistered() {}
        override fun onRegistrationFailed(throwable: Throwable) { Log.w(TAG, "callback", throwable) }
        override fun onAvailabilityChanged(dataType: DataType<*, *>, availability: Availability) {}
    }

    private fun <T> sample(list: List<T>, max: Int): List<T> =
        if (list.size <= max) list else (0 until max).map { list[it * list.size / max] }

    private fun round(v: Double, places: Int): Double {
        val f = Math.pow(10.0, places.toDouble())
        return Math.round(v * f) / f
    }
}

object GBLinkIds {
    fun isUuid(id: String) = PhoneMessage.isBatchId(id)
}
