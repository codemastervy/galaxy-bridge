package nz.galaxybridge.watch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * adb shell am broadcast -n nz.galaxybridge.watch/.DebugReceiver -a nz.galaxybridge.watch.debug.FORGET_IPHONE
 * adb shell am broadcast -n nz.galaxybridge.watch/.DebugReceiver -a nz.galaxybridge.watch.debug.HFP
 */
class DebugReceiver : BroadcastReceiver() {
    @SuppressLint("MissingPermission")
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "nz.galaxybridge.watch.debug.FORGET_IPHONE" -> {
                LinkService.forgetPhone(context)
                Log.i(TAG, "debug forget done")
            }
            "nz.galaxybridge.watch.debug.HFP" -> {
                val adapter = context.getSystemService(BluetoothManager::class.java).adapter
                val phone = adapter.bondedDevices.firstOrNull { it.name?.contains("iPhone") == true } ?: return
                val pending = goAsync()
                adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                        for (call in listOf("setConnectionPolicy" to arrayOf<Any>(phone, 100), "connect" to arrayOf<Any>(phone))) {
                            val r = runCatching {
                                proxy.javaClass.methods.first { it.name == call.first && it.parameterCount == call.second.size }
                                    .invoke(proxy, *call.second)
                            }
                            Log.i(TAG, "hfp ${call.first}: ${r.getOrNull()} ${r.exceptionOrNull()?.let { (it.cause ?: it).toString() } ?: ""}")
                        }
                        adapter.closeProfileProxy(profile, proxy)
                        pending.finish()
                    }
                    override fun onServiceDisconnected(profile: Int) {}
                }, 16 /* HEADSET_CLIENT */)
            }
        }
    }

    companion object { private const val TAG = "GBLink" }
}
