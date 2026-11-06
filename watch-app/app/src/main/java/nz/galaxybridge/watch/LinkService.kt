package nz.galaxybridge.watch

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.BatteryManager
import android.os.IBinder
import android.os.ParcelUuid
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.VibrationEffect
import android.os.VibratorManager
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * Hosts the GBLink GATT service. Both characteristics require an encrypted link, so the
 * Bluetooth stack forces LE pairing (with on-screen confirmation) before any data flows.
 * Only one phone, the first one that pairs, is trusted until the user forgets it.
 */
@SuppressLint("MissingPermission") // Permissions are checked in MainActivity before starting.
class LinkService : Service() {

    enum class Status { STOPPED, WAITING, CONNECTED }

    companion object {
        private const val TAG = "GBLink"
        private const val CHANNEL = "link"
        private const val PREFS = "link"
        private const val KEY_TRUSTED = "trustedPhone"

        val status = MutableStateFlow(Status.STOPPED)
        val pending = MutableStateFlow(0)
        @Volatile private var instance: LinkService? = null

        fun start(context: Context) {
            context.startForegroundService(Intent(context, LinkService::class.java))
        }

        /** Prefers the Bluetooth remote (works in the iPhone Camera app); falls back to GBLink. */
        fun sendShutter() {
            val service = instance ?: return
            if (!service.hid.press()) service.send(WatchMessages.shutter())
        }

        val battery = MutableStateFlow<Int?>(null)

        /** Epoch ms until which a new phone may pair; 0 when closed. */
        val pairingUntil = MutableStateFlow(0L)
        val hasPhone = MutableStateFlow(false)
        private const val PAIRING_WINDOW_MS = 120_000L
        private const val FIND_ID = 4
        /** Batches in flight at once; the iPhone saves them to Apple Health concurrently. */
        private const val WINDOW = 6

        fun openPairing() = instance?.setPairingWindow(true)
        fun cancelPairing() = instance?.setPairingWindow(false)

        fun samplesQueued() = instance?.flushQueue()

        fun forgetPhone(context: Context) {
            context.getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(KEY_TRUSTED).apply()
            hasPhone.value = false
            instance?.apply { apple.close(); notifier.clearAll(); disconnectAll() }
            removeIPhoneBonds(context)
        }

        /**
         * Deletes the watch's Bluetooth keys for any iPhone. Without this, an iPhone that has
         * forgotten the watch can't pair again: Android refuses a fresh pairing from a device it
         * still holds keys for. removeBond is a system API, so this may be refused; returns how
         * many were removed.
         */
        @SuppressLint("MissingPermission")
        fun removeIPhoneBonds(context: Context): Int {
            val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return 0
            val apple = "00000000-deca-fade-deca-deafdecacafe"
            var removed = 0
            for (d in runCatching { adapter.bondedDevices }.getOrDefault(emptySet())) {
                val isIPhone = d.name?.contains("iPhone", ignoreCase = true) == true ||
                    d.uuids?.any { it.toString().equals(apple, ignoreCase = true) } == true
                if (!isIPhone) continue
                val ok = runCatching { d.javaClass.getMethod("removeBond").invoke(d) as Boolean }
                    .onFailure { Log.w(TAG, "removeBond refused", it) }.getOrDefault(false)
                Log.i(TAG, "removeBond ${d.address.takeLast(5)}: $ok")
                if (ok) removed++
            }
            return removed
        }

        fun statusFlow(): StateFlow<Status> = status

        /** iPhone-side info the watch shows. */
        val phoneBattery = MutableStateFlow<PhoneMessage.PhoneBattery?>(null)
        val weather = MutableStateFlow<PhoneMessage.Weather?>(null)
        val events = MutableStateFlow<List<PhoneMessage.Event>>(emptyList())
        val findingWatch = MutableStateFlow(false)
        val findingPhone = MutableStateFlow(false)
        /** Phone clock minus watch clock in ms, when it's off by more than a minute; else 0. */
        val clockSkew = MutableStateFlow(0L)
        /** The iPhone's time zone when it differs from the watch's; else empty. */
        val zoneMismatch = MutableStateFlow("")

        fun performAction(uid: Int, positive: Boolean, dismissedOnly: Boolean = false) {
            val s = instance ?: return
            if (dismissedOnly && !WatchSettings.enabled(s, WatchSettings.CLEAR_ON_IPHONE)) return
            s.apple.perform(uid, positive)
            if (!dismissedOnly) s.notifier.remove(uid)
        }

        fun media(command: Int) = instance?.apple?.media(command)

        /** Sends a feature message if the iPhone is connected. Returns false otherwise. */
        fun sendFeature(type: String, body: org.json.JSONObject = org.json.JSONObject()): Boolean {
            val s = instance ?: return false
            if (s.phone == null || !s.subscribed) return false
            s.send(WatchMessages.feature(type, body))
            return true
        }

        fun connected() = instance?.let { it.phone != null && it.subscribed } == true

        fun findPhone(on: Boolean) {
            val s = instance ?: return
            findingPhone.value = on && status.value == Status.CONNECTED
            s.send(WatchMessages.findPhone(on))
        }

        fun stopFindingWatch() = instance?.ring(false)

    }

    private lateinit var manager: BluetoothManager
    private var server: BluetoothGattServer? = null
    private lateinit var toPhone: BluetoothGattCharacteristic
    private lateinit var queue: SampleQueue
    lateinit var hid: HidShutter
    lateinit var apple: AppleClient
    lateinit var notifier: PhoneNotifier
    private lateinit var media: MediaBridge
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var phone: BluetoothDevice? = null
    private var subscribed = false
    private var mtu = 23
    private val assembler = GBLink.Assembler()

    private val outbox = ArrayDeque<ByteArray>()
    private var notifyInFlight = false
    private val inFlightBatches = HashSet<String>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        queue = SampleQueue(filesDir)
        pending.value = queue.size()
        PhoneInfo.load(this)
        startInForeground()
        manager = getSystemService(BluetoothManager::class.java)
        hasPhone.value = trustedAddress() != null
        openServer()
        advertise()
        hid = HidShutter(this) { getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_TRUSTED, null) }
        hid.start()
        notifier = PhoneNotifier(this)
        apple = AppleClient(this,
            onNotification = { e, d, app -> if (Features.allowNotification(this, e, d, app)) notifier.post(e, d, app) },
            onRemoved = notifier::remove)
        media = MediaBridge(this) { apple.media(it) }
        AppleClient.nowPlaying.onEach { media.update(it); Tiles.refresh(this) }.launchIn(scope)
        WatchSettings.changes.onEach { media.update(AppleClient.nowPlaying.value); sendStatus() }.launchIn(scope)
        AppleClient.connected.onEach { sendStatus() }.launchIn(scope)
        trustedDevice()?.let { apple.connect(it) }
        registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        status.value = Status.WAITING
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        scope.cancel()
        runCatching { unregisterReceiver(bondReceiver) }
        ring(false)
        apple.close()
        media.release()
        hid.stop()
        manager.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
        server?.close()
        instance = null
        status.value = Status.STOPPED
        super.onDestroy()
    }

    private fun startInForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "iPhone connection", NotificationManager.IMPORTANCE_LOW))
        val n = Notification.Builder(this, CHANNEL)
            .setContentTitle("Galaxy Bridge")
            .setContentText("Keeping your iPhone connected")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
        startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    private fun openServer() {
        val service = BluetoothGattService(GBLink.SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        toPhone = BluetoothGattCharacteristic(
            GBLink.TO_PHONE,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED_MITM,
        ).apply {
            // MITM = authenticated pairing: both screens show a code the user must confirm.
            addDescriptor(BluetoothGattDescriptor(
                GBLink.CCCD,
                BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED_MITM or
                    BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED_MITM,
            ))
        }
        val toWatch = BluetoothGattCharacteristic(
            GBLink.TO_WATCH,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED_MITM,
        )
        service.addCharacteristic(toPhone)
        service.addCharacteristic(toWatch)
        server = manager.openGattServer(this, callback)?.also { it.addService(service) }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(errorCode: Int) {
            Log.w(TAG, "advertising failed: $errorCode")
        }
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val closePairing = Runnable { setPairingWindow(false) }

    fun setPairingWindow(open: Boolean) {
        handler.removeCallbacks(closePairing)
        pairingUntil.value = if (open) System.currentTimeMillis() + PAIRING_WINDOW_MS else 0L
        if (open) handler.postDelayed(closePairing, PAIRING_WINDOW_MS)
        advertise()
    }

    private fun pairingOpen() = System.currentTimeMillis() < pairingUntil.value

    private fun advertise() {
        val advertiser = manager.adapter?.bluetoothLeAdvertiser ?: return
        advertiser.stopAdvertising(advertiseCallback)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(
                if (pairingOpen()) AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                else AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(GBLink.SERVICE))
            .setIncludeDeviceName(false)
            .build()
        val scanResponse = AdvertiseData.Builder()
            .addServiceData(ParcelUuid(GBLink.SERVICE), GBLink.advert(pairingOpen(), shortName()))
            .build()
        advertiser.startAdvertising(settings, data, scanResponse, advertiseCallback)
    }

    /** "Galaxy Watch4 Classic (A1B2)" → "A1B2", so the iPhone can tell watches apart. */
    private fun shortName(): String {
        val name = manager.adapter?.name.orEmpty()
        return Regex("\\(([^)]+)\\)").find(name)?.groupValues?.get(1) ?: name
    }

    private fun trustedDevice(): BluetoothDevice? =
        trustedAddress()?.let { a -> runCatching { manager.adapter.getRemoteDevice(a) }.getOrNull() }

    private fun trustedAddress(): String? =
        getSharedPreferences(PREFS, MODE_PRIVATE).getString(KEY_TRUSTED, null)

    /**
     * A phone is trusted only if it's bonded and is either the saved phone or pairing while the
     * user has opened the pairing window on the watch. A new pairing replaces the old phone.
     */
    private fun isTrusted(device: BluetoothDevice): Boolean {
        val bond = device.bondState
        // iOS subscribes over the freshly encrypted link a moment before Android finishes the
        // key exchange. Refusing here made iOS hang up and abort the pairing, so while the user
        // has the pairing window open, accept the bonding phone and save it once it's bonded.
        if (bond == BluetoothDevice.BOND_BONDING && pairingOpen()) {
            bondingPhone = device
            return true
        }
        if (bond != BluetoothDevice.BOND_BONDED) return false
        if (trustedAddress() == device.address) return true
        if (!pairingOpen() && bondingPhone != device) return false
        bondingPhone = null
        val previous = phone
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().putString(KEY_TRUSTED, device.address).apply()
        hasPhone.value = true
        setPairingWindow(false)
        if (previous != null && previous != device) server?.cancelConnection(previous)
        return true
    }

    /** A phone that subscribed while its pairing was still finishing. */
    private var bondingPhone: BluetoothDevice? = null

    private val bondReceiver = object : BroadcastReceiver() {
        @SuppressLint("MissingPermission")
        override fun onReceive(context: Context, intent: Intent) {
            @Suppress("DEPRECATION")
            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE) ?: return
            if (device != bondingPhone) return
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)) {
                BluetoothDevice.BOND_BONDED -> {
                    Log.i(TAG, "pairing finished")
                    isTrusted(device)
                    if (phone == device && subscribed) { hid.connectToPhone(); apple.connect(device); CallAudio.connect(this@LinkService, device) }
                }
                BluetoothDevice.BOND_NONE -> {
                    Log.w(TAG, "pairing failed")
                    bondingPhone = null
                    if (phone == device) server?.cancelConnection(device)
                }
            }
        }
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_DISCONNECTED && device == phone) {
                phone = null
                subscribed = false
                outbox.clear()
                notifyInFlight = false
                inFlightBatches.clear()
                mtu = 23
                findingPhone.value = false
                LinkService.status.value = Status.WAITING
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            if (device == phone || phone == null) this@LinkService.mtu = mtu
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            val ok = descriptor.uuid == GBLink.CCCD && isTrusted(device)
            if (responseNeeded) {
                server?.sendResponse(device, requestId,
                    if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION, 0, null)
            }
            if (!ok) return
            phone = device
            subscribed = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            if (subscribed) {
                LinkService.status.value = Status.CONNECTED
                send(WatchMessages.hello(BuildConfig.VERSION_NAME))
                battery.value = batteryPercent()
                send(WatchMessages.battery(batteryPercent()))
                flushQueue()
                sendStatus()
                Workouts.flush(this@LinkService)
                if (device.bondState == BluetoothDevice.BOND_BONDED) {
                    hid.connectToPhone()
                    apple.connect(device)
                    CallAudio.connect(this@LinkService, device)
                }
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            val ok = characteristic.uuid == GBLink.TO_WATCH && device == phone && isTrusted(device) && !preparedWrite
            if (responseNeeded) {
                server?.sendResponse(device, requestId,
                    if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION, 0, null)
            }
            if (!ok) return
            val message = try {
                assembler.append(value)
            } catch (e: GBLink.FramingException) {
                Log.w(TAG, "dropped malformed chunk")
                null
            } ?: return
            when (val m = PhoneMessage.decode(message)) {
                is PhoneMessage.Ack -> {
                    queue.ack(m.batchId)
                    inFlightBatches.remove(m.batchId)
                    pending.value = queue.size()
                    flushQueue()
                }
                is PhoneMessage.Hello -> {
                    val skew = if (m.phoneTime > 0) m.phoneTime - System.currentTimeMillis() else 0
                    clockSkew.value = if (kotlin.math.abs(skew) > 60_000) skew else 0
                    zoneMismatch.value = m.timeZone.takeIf {
                        it.isNotEmpty() && java.util.TimeZone.getTimeZone(it).rawOffset != java.util.TimeZone.getDefault().rawOffset
                    }.orEmpty()
                }
                is PhoneMessage.Find -> ring(m.on)
                // A refused change (permission not granted) still replies, so the phone shows the real value.
                is PhoneMessage.Set -> if (!WatchSettings.set(this@LinkService, m.key, m.value)) sendStatus()
                PhoneMessage.GetStatus -> sendStatus()
                is PhoneMessage.PhoneBattery -> { phoneBattery.value = m; PhoneInfo.save(this@LinkService, m); Tiles.refresh(this@LinkService) }
                is PhoneMessage.Weather -> { weather.value = m; PhoneInfo.save(this@LinkService, m); Tiles.refresh(this@LinkService) }
                is PhoneMessage.Events -> { events.value = m.items; PhoneInfo.save(this@LinkService, m); Tiles.refresh(this@LinkService) }
                is PhoneMessage.Raw -> Features.handle(this@LinkService, m.type, m.json)
                null -> Log.w(TAG, "rejected message from phone")
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            notifyInFlight = false
            pump()
        }
    }

    fun send(message: ByteArray) {
        if (phone == null || !subscribed) return
        // ATT caps an attribute value at 512 bytes even when the MTU is 517.
        outbox.addAll(GBLink.chunks(message, minOf(mtu - 3, 512)))
        pump()
    }

    fun sendStatus() {
        val bm = getSystemService(BatteryManager::class.java)
        send(WatchMessages.status(WatchSettings.status(this, batteryPercent(), bm.isCharging)))
    }

    private var ringtone: Ringtone? = null

    /** "Find my watch": rings and vibrates until stopped here or on the iPhone. */
    fun ring(on: Boolean) {
        findingWatch.value = on
        val vibrator = getSystemService(VibratorManager::class.java).defaultVibrator
        ringtone?.stop()
        ringtone = null
        vibrator.cancel()
        handler.removeCallbacks(stopRinging)
        if (!on) {
            getSystemService(NotificationManager::class.java).cancel(FIND_ID)
            return
        }
        vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 600, 400), 0))
        ringtone = RingtoneManager.getRingtone(this, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM))?.apply {
            audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
            isLooping = true
            play()
        }
        handler.postDelayed(stopRinging, 60_000)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel("find", "Find my watch", NotificationManager.IMPORTANCE_HIGH))
        val screen = android.app.PendingIntent.getActivity(this, 1,
            Intent(this, AlertActivity::class.java).putExtra(AlertActivity.EXTRA_MODE, AlertActivity.MODE_FIND),
            android.app.PendingIntent.FLAG_IMMUTABLE)
        nm.notify(FIND_ID, Notification.Builder(this, "find")
            .setSmallIcon(R.drawable.ic_stat_iphone)
            .setContentTitle("Find my watch")
            .setContentText("Tap to stop")
            .setCategory(Notification.CATEGORY_ALARM)
            .setFullScreenIntent(screen, true)
            .setContentIntent(screen)
            .build())
    }

    private val stopRinging = Runnable { ring(false) }

    private fun pump() {
        val device = phone ?: return
        if (notifyInFlight) return
        val next = outbox.removeFirstOrNull() ?: return
        notifyInFlight = true
        val result = runCatching { server?.notifyCharacteristicChanged(device, toPhone, false, next) }
            .onFailure { Log.w(TAG, "notify failed", it) }.getOrNull()
        if (result != BluetoothGatt.GATT_SUCCESS) {
            // Stack busy: retry shortly instead of stalling until the next reconnect.
            notifyInFlight = false
            outbox.addFirst(next)
            handler.postDelayed({ pump() }, 50)
        }
    }

    /** Sends up to [WINDOW] full batches at a time; the rest follow as acks arrive. */
    fun flushQueue() {
        if (phone == null || !subscribed) { pending.value = queue.size(); return }
        if (inFlightBatches.size >= WINDOW) return
        queue.compact(exclude = inFlightBatches)
        for ((id, items) in queue.pending(limit = WINDOW - inFlightBatches.size, exclude = inFlightBatches)) {
            inFlightBatches += id
            send(WatchMessages.samples(id, items))
            // If the phone never acks (e.g. it dropped the message), make the batch eligible again.
            handler.postDelayed({ if (inFlightBatches.remove(id)) flushQueue() }, 30_000)
        }
        pending.value = queue.size()
    }

    private fun disconnectAll() {
        phone?.let { server?.cancelConnection(it) }
    }

    private fun batteryPercent(): Int =
        getSystemService(BatteryManager::class.java).getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
}
