package nz.galaxybridge.watch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.util.Log

/**
 * Call audio on the watch: connects the watch's hands-free (HFP client) link to the iPhone, so
 * calls answered on the watch can use its speaker and mic. Android only turns this on by itself
 * for an Android companion phone; for an iPhone the app has to ask on each connection.
 * The connect call is a system API reached by reflection and may be refused on some watches.
 */
object CallAudio {
    private const val TAG = "CallAudio"
    private const val HEADSET_CLIENT = 16

    @SuppressLint("MissingPermission")
    fun connect(context: Context, phone: BluetoothDevice) {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return
        val app = context.applicationContext
        adapter.getProfileProxy(app, object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                val state = runCatching { proxy.getConnectionState(phone) }.getOrDefault(BluetoothProfile.STATE_DISCONNECTED)
                if (state == BluetoothProfile.STATE_DISCONNECTED) {
                    val r = runCatching {
                        proxy.javaClass.getMethod("connect", BluetoothDevice::class.java).invoke(proxy, phone) as Boolean
                    }
                    Log.i(TAG, "connect: ${r.getOrNull() ?: (r.exceptionOrNull()?.cause ?: r.exceptionOrNull())}")
                }
                adapter.closeProfileProxy(profile, proxy)
            }
            override fun onServiceDisconnected(profile: Int) {}
        }, HEADSET_CLIENT)
    }
}
