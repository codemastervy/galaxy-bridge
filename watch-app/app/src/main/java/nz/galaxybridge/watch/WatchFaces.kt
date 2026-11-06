package nz.galaxybridge.watch

import android.app.WallpaperManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.service.wallpaper.WallpaperService
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

/**
 * The active watch face (name and preview image) for the iPhone app's watch picture, and the
 * list of installed faces. Apps can't switch faces on Wear OS 5, but the picker can be opened.
 */
object WatchFaces {
    private const val PREVIEW = "com.google.android.wearable.watchface.preview_circular"
    private const val PREVIEW_ANY = "com.google.android.wearable.watchface.preview"
    private const val WFF = "com.google.wear.watchface.format.version"
    private val RUNTIMES = setOf("com.samsung.wear.watchface.runtime", "com.google.wear.watchface.runtime")

    fun active(c: Context): ComponentName? = runCatching { WallpaperManager.getInstance(c).wallpaperInfo?.component }.getOrNull()

    /** {"name", "pkg", "png"}: preview at most 240 px, PNG. */
    fun describeActive(c: Context): JSONObject {
        val pm = c.packageManager
        val info = runCatching { WallpaperManager.getInstance(c).wallpaperInfo }.getOrNull()
        val out = JSONObject()
        if (info == null) return out
        var pkg = info.packageName
        var name = info.loadLabel(pm).toString()
        var preview: Drawable? = servicePreview(c, info.component)
        // Watch Face Format faces run inside a shared runtime; find the face package itself.
        if (pkg in RUNTIMES) activeWffPackage(c)?.let { wff ->
            pkg = wff
            name = runCatching { pm.getApplicationLabel(pm.getApplicationInfo(wff, 0)).toString() }.getOrDefault(name)
            preview = wffPreview(c, wff) ?: preview
        }
        if (preview == null) preview = runCatching { info.loadThumbnail(pm) }.getOrNull()
        out.put("name", name.take(60)).put("pkg", pkg)
        preview?.let { out.put("png", png(it)) }
        return out
    }

    fun list(c: Context): JSONArray {
        val pm = c.packageManager
        val active = active(c)
        val activeWff = if (active?.packageName in RUNTIMES) activeWffPackage(c) else null
        val out = JSONArray()
        val seen = HashSet<String>()
        for (ri in pm.queryIntentServices(Intent(WallpaperService.SERVICE_INTERFACE), PackageManager.GET_META_DATA)) {
            val si = ri.serviceInfo
            if (si.packageName in RUNTIMES || !seen.add(si.packageName)) continue
            val isFace = si.metaData?.containsKey(PREVIEW) == true || si.metaData?.containsKey(PREVIEW_ANY) == true
            if (!isFace) continue
            out.put(JSONObject().put("pkg", si.packageName).put("name", ri.loadLabel(pm).toString().take(50))
                .put("active", active?.packageName == si.packageName))
        }
        for (app in pm.getInstalledApplications(PackageManager.GET_META_DATA)) {
            if (app.metaData?.containsKey(WFF) != true || !seen.add(app.packageName)) continue
            out.put(JSONObject().put("pkg", app.packageName).put("name", pm.getApplicationLabel(app).toString().take(50))
                .put("active", app.packageName == activeWff))
        }
        return out
    }

    /** Opens the watch's own face picker. */
    fun openPicker(c: Context): Boolean {
        val candidates = listOf(
            Intent("com.google.android.wearable.action.PICK_WATCH_FACE"),
            Intent("com.samsung.android.wearable.sysui.action.EDIT_WATCH_FACE"),
            Intent(WallpaperManager.ACTION_LIVE_WALLPAPER_CHOOSER),
        )
        return candidates.any { Features.start(c, it) }
    }

    private fun servicePreview(c: Context, cn: ComponentName): Drawable? = runCatching {
        val pm = c.packageManager
        val si = pm.getServiceInfo(cn, PackageManager.GET_META_DATA)
        val id = si.metaData?.getInt(PREVIEW)?.takeIf { it != 0 } ?: si.metaData?.getInt(PREVIEW_ANY)?.takeIf { it != 0 }
        id?.let { pm.getResourcesForApplication(cn.packageName).getDrawable(it, null) }
    }.getOrNull()

    private fun wffPreview(c: Context, pkg: String): Drawable? = runCatching {
        val pm = c.packageManager
        val res = pm.getResourcesForApplication(pkg)
        val id = listOf("preview", "preview_circular", "watch_face_preview", "preview_image")
            .map { res.getIdentifier(it, "drawable", pkg) }.firstOrNull { it != 0 }
        id?.let { res.getDrawable(it, null) } ?: pm.getApplicationIcon(pkg)
    }.getOrNull()

    /**
     * Which WFF face is active. The runtime doesn't say, so this asks Samsung's watch-face
     * settings; if that isn't available, it falls back to the most recently installed WFF face.
     */
    private fun activeWffPackage(c: Context): String? {
        val cr = c.contentResolver
        for (key in listOf("current_watchface_package", "watchface_package", "clock_package")) {
            runCatching { android.provider.Settings.Global.getString(cr, key) }.getOrNull()
                ?.takeIf { it.isNotBlank() && it !in RUNTIMES }?.let { return it.substringBefore('/') }
        }
        val pm = c.packageManager
        return pm.getInstalledApplications(PackageManager.GET_META_DATA)
            .filter { it.metaData?.containsKey(WFF) == true }
            .maxByOrNull { runCatching { pm.getPackageInfo(it.packageName, 0).lastUpdateTime }.getOrDefault(0) }
            ?.packageName
    }

    private fun png(d: Drawable, size: Int = 240): String {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, size, size)
        d.draw(Canvas(bmp))
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        if (out.size() > 55_000) { out.reset(); bmp.compress(Bitmap.CompressFormat.JPEG, 80, out) }
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }
}
