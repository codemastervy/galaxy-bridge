package nz.galaxybridge.watch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * GATT client for the iPhone's own services over the bonded link: ANCS (notifications and
 * calls) and AMS (music). iOS only exposes these to a bonded accessory, and only after the
 * user leaves "Share System Notifications" on for the watch in iPhone Bluetooth settings.
 *
 * Android allows one GATT operation at a time, so every read/write goes through [ops].
 */
@SuppressLint("MissingPermission") // BLUETOOTH_CONNECT is granted before LinkService starts.
class AppleClient(
    private val context: Context,
    private val onNotification: (Ancs.Event, Ancs.Details, appName: String) -> Unit,
    private val onRemoved: (uid: Int) -> Unit,
) {
    companion object {
        private const val TAG = "AppleClient"
        private val CCCD = GBLink.CCCD

        val connected = MutableStateFlow(false)
        val nowPlaying = MutableStateFlow(Ams.NowPlaying())
    }

    private val main = Handler(Looper.getMainLooper())
    private var gatt: BluetoothGatt? = null
    private var target: BluetoothDevice? = null

    private var controlPoint: BluetoothGattCharacteristic? = null
    private var remoteCommand: BluetoothGattCharacteristic? = null

    private val ops = ArrayDeque<() -> Boolean>()
    private var opBusy = false
    private val opTimeout = Runnable { opBusy = false; nextOp() }

    /** UIDs waiting for their attributes, oldest first. */
    private val fetchQueue = ArrayDeque<Ancs.Event>()
    private var fetching: Ancs.Event? = null
    private var pendingDetails: Ancs.Details? = null
    private val responses = Ancs.Responses()
    private val fetchTimeout = Runnable { finishFetch() }
    private val appNames = HashMap<String, String>()
    private val namePrefs = context.getSharedPreferences("appNames", Context.MODE_PRIVATE)

    fun connect(device: BluetoothDevice) {
        if (target == device && gatt != null) return
        close()
        target = device
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    fun close() {
        main.removeCallbacksAndMessages(null)
        gatt?.close()
        gatt = null
        target = null
        reset()
    }

    private fun reset() {
        ops.clear()
        opBusy = false
        fetchQueue.clear()
        fetching = null
        responses.reset()
        controlPoint = null
        remoteCommand = null
        connected.value = false
        nowPlaying.value = Ams.NowPlaying()
    }

    fun perform(uid: Int, positive: Boolean) {
        val cp = controlPoint ?: return
        enqueue { write(cp, Ancs.performAction(uid, positive)) }
    }

    fun media(command: Int) {
        val rc = remoteCommand ?: return
        enqueue { write(rc, byteArrayOf(command.toByte())) }
    }

    private fun retry() {
        val device = target ?: return
        main.postDelayed({
            if (target == device) {
                gatt?.close()
                gatt = device.connectGatt(context, true, callback, BluetoothDevice.TRANSPORT_LE)
            }
        }, 3_000)
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = main.post {
            if (g != gatt) return@post
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                reset()
                retry()
            }
        }.let { }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = main.post {
            if (g != gatt) return@post
            val ancs = g.getService(Ancs.SERVICE)
            val ams = g.getService(Ams.SERVICE)
            Log.i(TAG, "services: ancs=${ancs != null} ams=${ams != null}")
            if (ancs != null) {
                controlPoint = ancs.getCharacteristic(Ancs.CONTROL_POINT)
                // Data Source must be subscribed before Notification Source.
                ancs.getCharacteristic(Ancs.DATA_SOURCE)?.let { subscribe(it) }
                ancs.getCharacteristic(Ancs.NOTIFICATION_SOURCE)?.let { subscribe(it) }
                connected.value = controlPoint != null
            }
            if (ams != null) {
                remoteCommand = ams.getCharacteristic(Ams.REMOTE_COMMAND)
                remoteCommand?.let { subscribe(it) }
                ams.getCharacteristic(Ams.ENTITY_UPDATE)?.let { eu ->
                    subscribe(eu)
                    enqueue { write(eu, Ams.SUBSCRIBE_PLAYER) }
                    enqueue { write(eu, Ams.SUBSCRIBE_TRACK) }
                }
            }
            if (ancs == null && ams == null) retryDiscovery(g)
        }.let { }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) = main.post {
            if (status != BluetoothGatt.GATT_SUCCESS) Log.w(TAG, "subscribe ${d.characteristic.uuid} failed: $status")
            opDone()
        }.let { }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) = main.post {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.w(TAG, "write ${c.uuid} failed: $status")
                // A failed Get Attributes (e.g. the notification already went) mustn't stall the queue.
                if (c.uuid == Ancs.CONTROL_POINT && fetching != null) finishFetch()
            }
            opDone()
        }.let { }

        @Deprecated("Pre-33 callback")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") val v = c.value ?: return
            changed(c, v)
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            changed(c, value)
        }
    }

    /** iOS sometimes hides ANCS until the link is encrypted; look again shortly. */
    private var discoveryRetries = 0
    private fun retryDiscovery(g: BluetoothGatt) {
        if (discoveryRetries++ > 5) return
        main.postDelayed({ if (g == gatt) g.discoverServices() }, 5_000)
    }

    private fun changed(c: BluetoothGattCharacteristic, value: ByteArray) {
        val v = value.copyOf()
        main.post {
            when (c.uuid) {
                Ancs.NOTIFICATION_SOURCE -> Ancs.parseEvent(v)?.let(::onEvent)
                Ancs.DATA_SOURCE -> onData(v)
                Ams.ENTITY_UPDATE -> nowPlaying.value = nowPlaying.value.apply(v)
            }
        }
    }

    private fun onEvent(e: Ancs.Event) {
        when (e.kind) {
            Ancs.EVENT_REMOVED -> {
                fetchQueue.removeAll { it.uid == e.uid }
                onRemoved(e.uid)
            }
            else -> {
                // Don't replay the whole notification centre every time the watch reconnects.
                if (e.has(Ancs.FLAG_PRE_EXISTING)) return
                fetchQueue.removeAll { it.uid == e.uid }
                fetchQueue.addLast(e)
                if (fetchQueue.size > 50) fetchQueue.removeFirst()
                nextFetch()
            }
        }
    }

    private fun nextFetch() {
        if (fetching != null) return
        val cp = controlPoint ?: return
        val e = fetchQueue.removeFirstOrNull() ?: return
        fetching = e
        responses.reset()
        main.postDelayed(fetchTimeout, 5_000)
        enqueue { write(cp, Ancs.getNotificationAttributes(e.uid)) }
    }

    private fun onData(chunk: ByteArray) {
        val event = fetching ?: return
        when (val r = responses.append(chunk)) {
            is Ancs.Responses.Result.Notification -> {
                if (r.details.uid != event.uid) return finishFetch()
                val known = appNames[r.details.appId] ?: namePrefs.getString(r.details.appId, null)
                if (known != null || r.details.appId.isEmpty()) {
                    deliver(event, r.details, known ?: "iPhone")
                    finishFetch()
                } else {
                    pendingDetails = r.details
                    val cp = controlPoint ?: return finishFetch()
                    enqueue { write(cp, Ancs.getAppAttributes(r.details.appId)) }
                }
            }
            is Ancs.Responses.Result.AppName -> {
                val details = pendingDetails
                val name = r.name.ifEmpty { r.appId.substringAfterLast('.') }.take(40)
                appNames[r.appId] = name
                namePrefs.edit().putString(r.appId, name).apply()
                if (details != null && details.appId == r.appId) deliver(event, details, name)
                finishFetch()
            }
            null -> Unit
        }
    }

    private fun deliver(e: Ancs.Event, d: Ancs.Details, app: String) {
        runCatching { onNotification(e, d, app) }.onFailure { Log.w(TAG, "post failed", it) }
    }

    private fun finishFetch() {
        main.removeCallbacks(fetchTimeout)
        fetching = null
        pendingDetails = null
        responses.reset()
        nextFetch()
    }

    // --- serialized GATT operations ---

    private fun enqueue(op: () -> Boolean) {
        ops.addLast(op)
        nextOp()
    }

    private fun nextOp() {
        if (opBusy) return
        val op = ops.removeFirstOrNull() ?: return
        opBusy = true
        main.postDelayed(opTimeout, 4_000)
        if (!runCatching(op).getOrDefault(false)) opDone()
    }

    private fun opDone() {
        main.removeCallbacks(opTimeout)
        opBusy = false
        nextOp()
    }

    private fun subscribe(c: BluetoothGattCharacteristic) = enqueue {
        val g = gatt ?: return@enqueue false
        g.setCharacteristicNotification(c, true)
        val d = c.getDescriptor(CCCD) ?: return@enqueue false
        val v = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if (Build.VERSION.SDK_INT >= 33) {
            g.writeDescriptor(d, v) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            d.value = v
            @Suppress("DEPRECATION")
            g.writeDescriptor(d)
        }
    }

    private fun write(c: BluetoothGattCharacteristic, value: ByteArray): Boolean {
        val g = gatt ?: return false
        val type = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        return if (Build.VERSION.SDK_INT >= 33) {
            g.writeCharacteristic(c, value, type) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            c.value = value
            c.writeType = type
            @Suppress("DEPRECATION")
            g.writeCharacteristic(c)
        }
    }
}
