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

    @Volatile private var lastSent: String? = null
    @Volatile private var lastCheck = 0L

    /**
     * Sends the face to the iPhone if it changed. Switching between faces inside the same runtime
     * sends no broadcast, so this also runs when the screen turns on (at most once a minute).
     */
    fun sendIfChanged(c: Context, force: Boolean = false) {
        val now = android.os.SystemClock.elapsedRealtime()
        if (!force && now - lastCheck < 60_000) return
        if (!LinkService.connected()) return
        lastCheck = now
        Thread {
            val face = describeActive(c)
            val key = face.optString("pkg")
            if (force || key != lastSent) {
                if (LinkService.sendFeature("face", face)) lastSent = key
            }
        }.start()
    }

    /** Called when the iPhone asks; it always gets an answer. */
    fun sendNow(c: Context) = Thread {
        val face = describeActive(c)
        if (LinkService.sendFeature("face", face)) lastSent = face.optString("pkg")
    }.start()

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
        for (app in wffApps(c)) {
            if (!seen.add(app.packageName)) continue
            out.put(JSONObject().put("pkg", app.packageName).put("name", pm.getApplicationLabel(app).toString().take(50))
                .put("active", app.packageName == activeWff))
        }
        return out
    }

    private val OURS get() = ComponentName("nz.galaxybridge.watch", "nz.galaxybridge.watch.face.BridgeFaceService")

    fun oursActive(c: Context) = active(c) == OURS

    fun designState(c: Context): JSONObject =
        JSONObject().put("design", nz.galaxybridge.watch.face.FaceDesign.load(c).toJson()).put("active", oursActive(c))

    /**
     * A design from the iPhone gallery. It shows at once if the Wear OS Bridge face is on;
     * otherwise the watch is asked to switch to it (the system shows its own confirm screen).
     */
    fun setDesign(s: LinkService, j: JSONObject) {
        val d = nz.galaxybridge.watch.face.FaceDesign.parse(j) ?: return
        nz.galaxybridge.watch.face.FaceDesign.save(s, d)
        if (oursActive(s)) {
            Features.result(s, "design", true, "${d.name} is on your watch")
        } else {
            val ok = Features.start(s, Intent(WallpaperManager.ACTION_CHANGE_LIVE_WALLPAPER)
                .putExtra(WallpaperManager.EXTRA_LIVE_WALLPAPER_COMPONENT, OURS)) || openPicker(s)
            Features.result(s, "design", ok, "Choose the Wear OS Bridge face on your watch once; after that designs switch instantly")
        }
        s.send(WatchMessages.feature("design", designState(s)))
    }

    /** Small thumbnails for the iPhone's face list, one message each so none gets too big. */
    fun sendPreviews(c: Context, items: JSONArray) {
        for (i in 0 until items.length()) {
            val pkg = items.optJSONObject(i)?.optString("pkg") ?: continue
            val d = preview(c, pkg) ?: continue
            if (!LinkService.sendFeature("facePreview", JSONObject().put("pkg", pkg).put("img", jpeg(d, 120)))) return
        }
    }

    private fun preview(c: Context, pkg: String): Drawable? {
        val pm = c.packageManager
        val svc = pm.queryIntentServices(Intent(WallpaperService.SERVICE_INTERFACE).setPackage(pkg), PackageManager.GET_META_DATA)
            .firstOrNull()?.serviceInfo
        return svc?.let { servicePreview(c, ComponentName(it.packageName, it.name)) } ?: wffPreview(c, pkg)
    }

    private fun jpeg(d: Drawable, size: Int): String {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        Canvas(bmp).apply { drawColor(android.graphics.Color.BLACK) }
        d.setBounds(0, 0, size, size); d.draw(Canvas(bmp))
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 75, out)
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
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

    /** Watch Face Format faces: declared by an app property (or, in older faces, meta-data). */
    private fun wffApps(c: Context): List<android.content.pm.ApplicationInfo> {
        val pm = c.packageManager
        return pm.getInstalledApplications(PackageManager.GET_META_DATA).filter { app ->
            app.metaData?.containsKey(WFF) == true ||
                runCatching { pm.getProperty(WFF, app.packageName); true }.getOrDefault(false)
        }
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
        runtimeDumpPackage(c)?.let { return it }
        val cr = c.contentResolver
        for (key in listOf("current_watchface_package", "watchface_package", "clock_package")) {
            runCatching { android.provider.Settings.Global.getString(cr, key) }.getOrNull()
                ?.takeIf { it.isNotBlank() && it !in RUNTIMES }?.let { return it.substringBefore('/') }
        }
        val pm = c.packageManager
        return wffApps(c)
            .maxByOrNull { runCatching { pm.getPackageInfo(it.packageName, 0).lastUpdateTime }.getOrDefault(0) }
            ?.packageName
    }

    private val RESOURCE_PKG = Regex("Resource only package name ([A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z0-9_]+)+)")

    /**
     * The face runtime names the face it's drawing in its service dump. Reading it needs the
     * DUMP permission (granted once over adb); without it this returns null.
     */
    private fun runtimeDumpPackage(c: Context): String? {
        if (c.checkSelfPermission(android.Manifest.permission.DUMP) != PackageManager.PERMISSION_GRANTED) return null
        return runCatching {
            val binder = Class.forName("android.os.ServiceManager").getMethod("getService", String::class.java)
                .invoke(null, "activity") as android.os.IBinder
            val (read, write) = android.os.ParcelFileDescriptor.createPipe()
            val t = Thread {
                runCatching { binder.dump(write.fileDescriptor, RUNTIMES.flatMap { listOf("service", it) }.take(2).toTypedArray()) }
                write.close()
            }.apply { start() }
            val text = android.os.ParcelFileDescriptor.AutoCloseInputStream(read).bufferedReader().use { r ->
                buildString { var line = r.readLine(); while (line != null && length < 400_000) { append(line).append('\n'); line = r.readLine() } }
            }
            t.join(3000)
            RESOURCE_PKG.findAll(text).map { it.groupValues[1] }.lastOrNull()
        }.onFailure { android.util.Log.w("WatchFaces", "runtime dump", it) }.getOrNull()
    }

    private fun png(d: Drawable, size: Int = 220): String {
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        d.setBounds(0, 0, size, size)
        d.draw(Canvas(bmp))
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        if (out.size() > 36_000) { out.reset(); bmp.compress(Bitmap.CompressFormat.JPEG, 80, out) }
        return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
    }
}
