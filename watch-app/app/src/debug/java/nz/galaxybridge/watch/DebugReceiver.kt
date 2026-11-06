package nz.galaxybridge.watch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
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
                Log.i("GBLink", "debug forget done")
            }
            "nz.galaxybridge.watch.debug.HFP" -> {
                val adapter = context.getSystemService(BluetoothManager::class.java).adapter
                adapter.bondedDevices.firstOrNull { it.name?.contains("iPhone") == true }
                    ?.let { CallAudio.connect(context, it) }
            }
        }
    }
}
