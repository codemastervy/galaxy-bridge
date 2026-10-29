package nz.galaxybridge.watch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothClass
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Presents the watch to the iPhone as a Bluetooth remote with a single Volume Up button,
 * which the iPhone's Camera app (and Galaxy Bridge's camera) treat as the shutter.
 *
 * The report descriptor only declares the Consumer Control "Volume Increment" usage, so this
 * device cannot type keys or send any other input.
 */
@SuppressLint("MissingPermission") // BLUETOOTH_CONNECT is granted before LinkService starts.
class HidShutter(private val context: Context, private val trustedAddress: () -> String?) {

    companion object {
        private const val TAG = "HidShutter"
        private const val REPORT_ID = 1

        private val DESCRIPTOR = byteArrayOf(
            0x05, 0x0C,                   // Usage Page (Consumer)
            0x09, 0x01,                   // Usage (Consumer Control)
            0xA1.toByte(), 0x01,          // Collection (Application)
            0x85.toByte(), REPORT_ID.toByte(), //   Report ID (1)
            0x15, 0x00,                   //   Logical Minimum (0)
            0x25, 0x01,                   //   Logical Maximum (1)
            0x75, 0x01,                   //   Report Size (1)
            0x95.toByte(), 0x01,          //   Report Count (1)
            0x09, 0xE9.toByte(),          //   Usage (Volume Increment)
            0x81.toByte(), 0x02,          //   Input (Data, Variable, Absolute)
            0x95.toByte(), 0x07,          //   Report Count (7)
            0x81.toByte(), 0x03,          //   Input (Constant) padding
            0xC0.toByte(),                // End Collection
        )

        val connected = MutableStateFlow(false)
    }

    private val main = Handler(Looper.getMainLooper())
    private var hid: BluetoothHidDevice? = null
    private var host: BluetoothDevice? = null

    private val callback = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
            if (registered) connectToPhone()
        }

        override fun onConnectionStateChanged(device: BluetoothDevice, state: Int) {
            if (state == BluetoothProfile.STATE_CONNECTED) {
                host = device
                connected.value = true
            } else if (device == host && state == BluetoothProfile.STATE_DISCONNECTED) {
                host = null
                connected.value = false
            }
        }
    }

    fun start() {
        val adapter = context.getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter ?: return
        adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                val device = proxy as BluetoothHidDevice
                hid = device
                val sdp = BluetoothHidDeviceAppSdpSettings(
                    "Galaxy Bridge Shutter", "Camera remote", "Galaxy Bridge",
                    BluetoothHidDevice.SUBCLASS1_NONE, DESCRIPTOR,
                )
                device.registerApp(sdp, null, null, context.mainExecutor, callback)
            }

            override fun onServiceDisconnected(profile: Int) {
                hid = null
                connected.value = false
            }
        }, BluetoothProfile.HID_DEVICE)
    }

    fun stop() {
        hid?.unregisterApp()
        connected.value = false
    }

    /** Connects to the trusted iPhone, falling back to the bonded phone if its classic address differs. */
    fun connectToPhone() {
        val device = hid ?: return
        val bonded = BluetoothAdapter.getDefaultAdapter()?.bondedDevices.orEmpty()
        val phone = bonded.firstOrNull { it.address == trustedAddress() && it.type != BluetoothDevice.DEVICE_TYPE_LE }
            ?: bonded.firstOrNull {
                it.bluetoothClass?.majorDeviceClass == BluetoothClass.Device.Major.PHONE &&
                    it.name?.contains("iPhone", ignoreCase = true) == true
            }
            ?: return
        if (!device.connect(phone)) Log.w(TAG, "HID connect request refused")
    }

    /** Taps Volume Up once. Returns false when the iPhone isn't connected as a remote. */
    fun press(): Boolean {
        val device = hid ?: return false
        val target = host ?: run { connectToPhone(); return false }
        if (!device.sendReport(target, REPORT_ID, byteArrayOf(0x01))) return false
        main.postDelayed({ device.sendReport(target, REPORT_ID, byteArrayOf(0x00)) }, 60)
        return true
    }
}
