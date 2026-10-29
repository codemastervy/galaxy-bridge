package nz.galaxybridge.watch

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import androidx.health.services.client.HealthServices
import androidx.health.services.client.PassiveListenerService
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.IntervalDataPoint
import androidx.health.services.client.data.PassiveListenerConfig
import androidx.health.services.client.data.SampleDataPoint
import kotlinx.coroutines.guava.await
import java.time.Instant

object Health {
    private val TYPES = setOf(
        DataType.HEART_RATE_BPM,
        DataType.STEPS,
        DataType.CALORIES,
        DataType.DISTANCE,
    )

    /** Registers background delivery; Health Services keeps it across restarts of our app. */
    suspend fun register(context: Context) {
        val client = HealthServices.getClient(context).passiveMonitoringClient
        val supported = client.getCapabilitiesAsync().await().supportedDataTypesPassiveMonitoring
        val config = PassiveListenerConfig.builder()
            .setDataTypes(TYPES.intersect(supported))
            .build()
        client.setPassiveListenerServiceAsync(HealthListenerService::class.java, config).await()
    }

    fun toSamples(data: DataPointContainer): List<HealthSample> {
        val boot = Instant.ofEpochMilli(System.currentTimeMillis() - SystemClock.elapsedRealtime())
        val out = ArrayList<HealthSample>()
        for (p in data.getData(DataType.HEART_RATE_BPM)) {
            val t = (p as SampleDataPoint<Double>).getTimeInstant(boot).toEpochMilli()
            out += HealthSample(SampleKind.HEART_RATE, t, t, p.value)
        }
        fun interval(type: DataType<*, *>, kind: SampleKind, toDouble: (Any) -> Double) {
            @Suppress("UNCHECKED_CAST")
            for (p in data.getData(type as DataType<Any, IntervalDataPoint<Any>>)) {
                out += HealthSample(kind,
                    p.getStartInstant(boot).toEpochMilli(),
                    p.getEndInstant(boot).toEpochMilli(),
                    toDouble(p.value))
            }
        }
        interval(DataType.STEPS, SampleKind.STEPS) { (it as Long).toDouble() }
        interval(DataType.CALORIES, SampleKind.ACTIVE_ENERGY) { it as Double }
        interval(DataType.DISTANCE, SampleKind.DISTANCE) { it as Double }
        return out.filter { it.isPlausible() }
    }
}

class HealthListenerService : PassiveListenerService() {
    override fun onNewDataPointsReceived(dataPoints: DataPointContainer) {
        SampleQueue(filesDir).add(Health.toSamples(dataPoints))
        LinkService.samplesQueued()
    }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) LinkService.start(context)
    }
}
