package nz.galaxybridge.watch

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Shows iPhone notifications as real watch notifications, so they buzz, appear in the
 * notification list and can be acted on like any other. Swiping one away clears it on the
 * iPhone too (if enabled), and incoming calls get a full-screen answer/decline screen.
 */
class PhoneNotifier(private val context: Context) {
    companion object {
        private const val CH_IPHONE = "iphone"
        private const val CH_CALLS = "calls"
        private const val CH_SILENT = "iphone_quiet"
        private const val GROUP = "iphone"
        private const val ID_BASE = 10_000

        const val ACTION = "nz.galaxybridge.watch.ANCS_ACTION"
        const val EXTRA_UID = "uid"
        const val EXTRA_POSITIVE = "positive"
        const val EXTRA_DISMISSED = "dismissed"

        /** The call currently ringing, for [AlertActivity]. */
        val incomingCall = MutableStateFlow<Call?>(null)

        data class Call(val uid: Int, val caller: String, val detail: String,
                        val acceptLabel: String, val declineLabel: String)
    }

    private val nm = context.getSystemService(NotificationManager::class.java)

    init {
        nm.createNotificationChannel(NotificationChannel(CH_IPHONE, "iPhone notifications",
            NotificationManager.IMPORTANCE_HIGH).apply { enableVibration(true) })
        nm.createNotificationChannel(NotificationChannel(CH_SILENT, "iPhone notifications (silent)",
            NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(CH_CALLS, "iPhone calls",
            NotificationManager.IMPORTANCE_HIGH).apply {
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 800, 600, 800, 600, 800, 600, 800)
            setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
        })
    }

    fun post(e: Ancs.Event, d: Ancs.Details, app: String) {
        if (e.category == Ancs.CATEGORY_INCOMING_CALL) {
            if (WatchSettings.enabled(context, WatchSettings.CALLS)) postCall(e, d)
            return
        }
        if (!WatchSettings.enabled(context, WatchSettings.NOTIFICATIONS)) return

        val title = d.title.ifEmpty { app }
        val text = listOf(d.subtitle, d.message).filter { it.isNotEmpty() }.joinToString("\n")
        val b = Notification.Builder(context, if (e.has(Ancs.FLAG_SILENT)) CH_SILENT else CH_IPHONE)
            .setSmallIcon(R.drawable.ic_stat_iphone)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSubText(app)
            .setGroup(GROUP + d.appId)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setOnlyAlertOnce(e.kind == Ancs.EVENT_MODIFIED)
            .setCategory(when (e.category) {
                Ancs.CATEGORY_MISSED_CALL, Ancs.CATEGORY_VOICEMAIL -> Notification.CATEGORY_MISSED_CALL
                4 -> Notification.CATEGORY_MESSAGE
                5 -> Notification.CATEGORY_EVENT
                6 -> Notification.CATEGORY_EMAIL
                else -> Notification.CATEGORY_STATUS
            })
        if (e.has(Ancs.FLAG_POSITIVE_ACTION) && d.positiveLabel.isNotEmpty()) {
            b.addAction(action(e.uid, true, d.positiveLabel))
        }
        if (e.has(Ancs.FLAG_NEGATIVE_ACTION) && d.negativeLabel.isNotEmpty()) {
            b.addAction(action(e.uid, false, d.negativeLabel))
        }
        if (WatchSettings.enabled(context, WatchSettings.CLEAR_ON_IPHONE) && e.has(Ancs.FLAG_NEGATIVE_ACTION)) {
            b.setDeleteIntent(broadcast(e.uid, positive = false, dismissed = true))
        }
        nm.notify(ID_BASE + (e.uid and 0x3FFFFFFF), b.build())
    }

    private fun postCall(e: Ancs.Event, d: Ancs.Details) {
        val call = Call(e.uid, d.title.ifEmpty { "Unknown caller" }, d.message.ifEmpty { "Incoming call" },
            d.positiveLabel.ifEmpty { "Accept" }, d.negativeLabel.ifEmpty { "Decline" })
        incomingCall.value = call
        val screen = PendingIntent.getActivity(context, e.uid,
            Intent(context, AlertActivity::class.java).putExtra(AlertActivity.EXTRA_MODE, AlertActivity.MODE_CALL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val caller = Person.Builder().setName(call.caller).setImportant(true).build()
        val n = Notification.Builder(context, CH_CALLS)
            .setSmallIcon(R.drawable.ic_stat_iphone)
            .setContentTitle(call.caller)
            .setContentText(call.detail)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setFullScreenIntent(screen, true)
            .setContentIntent(screen)
            .setStyle(Notification.CallStyle.forIncomingCall(caller,
                broadcast(e.uid, positive = false), broadcast(e.uid, positive = true)))
            .build()
        nm.notify(ID_BASE + (e.uid and 0x3FFFFFFF), n)
    }

    fun remove(uid: Int) {
        if (incomingCall.value?.uid == uid) incomingCall.value = null
        nm.cancel(ID_BASE + (uid and 0x3FFFFFFF))
    }

    fun clearAll() {
        incomingCall.value = null
        nm.activeNotifications.filter { it.id >= ID_BASE }.forEach { nm.cancel(it.id) }
    }

    private fun action(uid: Int, positive: Boolean, label: String) =
        Notification.Action.Builder(null, label.take(20), broadcast(uid, positive)).build()

    private fun broadcast(uid: Int, positive: Boolean, dismissed: Boolean = false): PendingIntent {
        val i = Intent(ACTION).setClass(context, ActionReceiver::class.java)
            .putExtra(EXTRA_UID, uid).putExtra(EXTRA_POSITIVE, positive).putExtra(EXTRA_DISMISSED, dismissed)
        val code = (uid shl 2) or (if (positive) 1 else 0) or (if (dismissed) 2 else 0)
        return PendingIntent.getBroadcast(context, code, i,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
}

/** Not exported: only our own PendingIntents can reach it. */
class ActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != PhoneNotifier.ACTION || !intent.hasExtra(PhoneNotifier.EXTRA_UID)) return
        val uid = intent.getIntExtra(PhoneNotifier.EXTRA_UID, 0)
        val positive = intent.getBooleanExtra(PhoneNotifier.EXTRA_POSITIVE, false)
        LinkService.performAction(uid, positive, dismissedOnly = intent.getBooleanExtra(PhoneNotifier.EXTRA_DISMISSED, false))
    }
}
