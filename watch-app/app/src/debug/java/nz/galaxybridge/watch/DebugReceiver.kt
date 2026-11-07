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
 * adb shell am broadcast -n nz.galaxybridge.watch/.DebugReceiver -a nz.galaxybridge.watch.debug.FACE
 * adb shell am broadcast -n nz.galaxybridge.watch/.DebugReceiver -a nz.galaxybridge.watch.debug.DESIGN
 */
class DebugReceiver : BroadcastReceiver() {
    @SuppressLint("MissingPermission")
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            "nz.galaxybridge.watch.debug.FORGET_IPHONE" -> {
                LinkService.forgetPhone(context)
                Log.i("GBLink", "debug forget done")
            }
            "nz.galaxybridge.watch.debug.FACE" -> {
                val r = goAsync()
                Thread {
                    val f = WatchFaces.describeActive(context)
                    Log.i("WatchFaces", "active ${f.optString("pkg")} '${f.optString("name")}' png=${f.optString("png").length}")
                    Log.i("WatchFaces", "list ${WatchFaces.list(context)}")
                    f.optString("png").takeIf { it.isNotEmpty() }?.let {
                        java.io.File(context.cacheDir, "face.png").writeBytes(android.util.Base64.decode(it, 0))
                    }
                    r.finish()
                }.start()
            }
            "nz.galaxybridge.watch.debug.RENDER" -> {
                // Draws every face layout to cache/face-<layout>.png (no complications).
                val bold = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
                val z = java.time.ZonedDateTime.now().withHour(10).withMinute(9).withSecond(36)
                val t = nz.galaxybridge.watch.face.Time(z, false, java.time.format.DateTimeFormatter.ofPattern("EEE d"))
                for (layout in nz.galaxybridge.watch.face.FaceDesign.LAYOUTS) {
                    val bmp = android.graphics.Bitmap.createBitmap(450, 450, android.graphics.Bitmap.Config.ARGB_8888)
                    val c = android.graphics.Canvas(bmp)
                    val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
                    p.shader = android.graphics.RadialGradient(225f, 225f, 225f, 0xFF1B1E4B.toInt(), 0xFF05060F.toInt(), android.graphics.Shader.TileMode.CLAMP)
                    c.drawRect(0f, 0f, 450f, 450f, p)
                    val f = nz.galaxybridge.watch.face.Frame(c, 225f, 225f, 225f, false, 0xFF2ED1DB.toInt(), -1, 0x70FFFFFF)
                    nz.galaxybridge.watch.face.FaceDraw.background(f, layout, t, p, bold)
                    p.reset(); p.isAntiAlias = true; p.color = 0x33FFFFFF
                    for (r in nz.galaxybridge.watch.face.BridgeFaceService.SLOTS.values) c.drawOval(r.left * 450, r.top * 450, r.right * 450, r.bottom * 450, p)
                    nz.galaxybridge.watch.face.FaceDraw.foreground(f, layout, t, p, bold)
                    java.io.File(context.cacheDir, "face-$layout.png").outputStream().use { bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                }
                Log.i("WatchFaces", "rendered")
            }
            "nz.galaxybridge.watch.debug.DESIGN" -> {
                // Loads files/design.json (copied in with run-as) as the face design.
                val f = java.io.File(context.filesDir, "design.json")
                val d = runCatching { nz.galaxybridge.watch.face.FaceDesign.parse(org.json.JSONObject(f.readText())) }.getOrNull()
                if (d != null) nz.galaxybridge.watch.face.FaceDesign.save(context, d)
                Log.i("WatchFaces", "design ${d?.id ?: "rejected"}")
            }
            "nz.galaxybridge.watch.debug.HFP" -> {
                val adapter = context.getSystemService(BluetoothManager::class.java).adapter
                adapter.bondedDevices.firstOrNull { it.name?.contains("iPhone") == true }
                    ?.let { CallAudio.connect(context, it) }
            }
        }
    }
}
