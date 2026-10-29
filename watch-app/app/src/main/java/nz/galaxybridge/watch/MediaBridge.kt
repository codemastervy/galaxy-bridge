package nz.galaxybridge.watch

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState

/**
 * Mirrors what the iPhone is playing into a local MediaSession, so the watch's own media
 * controls (and the Galaxy Bridge music screen) show it and send commands back over AMS.
 */
class MediaBridge(private val context: Context, private val command: (Int) -> Unit) {
    companion object {
        private const val CHANNEL = "media"
        private const val NOTIFICATION_ID = 3
    }

    private val nm = context.getSystemService(NotificationManager::class.java)
    private val session = MediaSession(context, "iPhone").apply {
        setCallback(object : MediaSession.Callback() {
            override fun onPlay() = command(Ams.CMD_PLAY)
            override fun onPause() = command(Ams.CMD_PAUSE)
            override fun onSkipToNext() = command(Ams.CMD_NEXT)
            override fun onSkipToPrevious() = command(Ams.CMD_PREVIOUS)
        })
    }

    init {
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "iPhone music", NotificationManager.IMPORTANCE_LOW))
    }

    fun update(np: Ams.NowPlaying) {
        if (!np.active || !WatchSettings.enabled(context, WatchSettings.MUSIC)) {
            session.isActive = false
            nm.cancel(NOTIFICATION_ID)
            return
        }
        session.setMetadata(MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, np.title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, np.artist)
            .putString(MediaMetadata.METADATA_KEY_ALBUM, np.album)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, (np.durationSec * 1000).toLong())
            .build())
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SKIP_TO_NEXT or
                PlaybackState.ACTION_SKIP_TO_PREVIOUS)
            .setState(if (np.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                (np.elapsedSec * 1000).toLong(), if (np.playing) 1f else 0f, np.elapsedAt)
            .build())
        session.isActive = true

        val open = PendingIntent.getActivity(context, 0,
            Intent(context, MainActivity::class.java).putExtra(MainActivity.EXTRA_PAGE, MainActivity.PAGE_MUSIC),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_music)
            .setContentTitle(np.title.ifEmpty { np.player })
            .setContentText(np.artist)
            .setContentIntent(open)
            .setOngoing(np.playing)
            .setStyle(Notification.MediaStyle().setMediaSession(session.sessionToken))
            .build()
        nm.notify(NOTIFICATION_ID, n)
    }

    fun release() {
        nm.cancel(NOTIFICATION_ID)
        session.release()
    }
}
