package nz.galaxybridge.watch

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/** adb shell am broadcast -a nz.galaxybridge.watch.debug.FORGET_IPHONE -n nz.galaxybridge.watch/.DebugReceiver */
class DebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        LinkService.forgetPhone(context)
        Log.i("GBLink", "debug forget done")
    }
}
