package nz.galaxybridge.watch.face

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import org.json.JSONArray
import org.json.JSONObject
import java.time.ZonedDateTime
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Draws a face described as a list of elements (ticks, numerals, hands, arcs, text…), so new
 * designs come from the iPhone's gallery without changing the watch app. Must stay in step with
 * SpecRender in FaceSpecs.swift. Positions and sizes are fractions of the face radius; angles are
 * degrees clockwise from 12 o'clock. Every value from the phone is clamped before use.
 */
object SpecDraw {
    const val MAX_ELEMENTS = 160

    class Values(z: ZonedDateTime, val h24: Boolean, val battery: Int) {
        val hour24 = z.hour
        val minuteInt = z.minute
        val sec = z.second.toFloat()
        val min = z.minute + sec / 60f
        val hour = (z.hour % 12) + min / 60f
        val day = z.dayOfMonth
        val wd: String = z.dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault()).uppercase().take(3)
        val weekday: String = z.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.getDefault()).uppercase()
        val month: String = z.month.getDisplayName(TextStyle.SHORT, Locale.getDefault()).uppercase().take(3)
    }

    class Pal(val bg1: Int, val bg2: Int, val accent: Int, val ink: Int)

    private val fonts = HashMap<String, Typeface>()
    private fun font(name: String): Typeface = fonts.getOrPut(name) {
        when (name) {
            "black" -> Typeface.create("sans-serif-black", Typeface.NORMAL)
            "light" -> Typeface.create("sans-serif-light", Typeface.NORMAL)
            "thin" -> Typeface.create("sans-serif-thin", Typeface.NORMAL)
            "medium", "rounded" -> Typeface.create("sans-serif-medium", Typeface.NORMAL)
            "condensed" -> Typeface.create("sans-serif-condensed", Typeface.BOLD)
            "mono" -> Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            "serif" -> Typeface.create(Typeface.SERIF, Typeface.NORMAL)
            "serifbold" -> Typeface.create(Typeface.SERIF, Typeface.BOLD)
            else -> Typeface.create("sans-serif", Typeface.BOLD)
        }
    }

    fun slots(spec: JSONObject): Set<String> =
        spec.optJSONArray("slots")?.let { a -> (0 until a.length()).map { a.optString(it) }.toSet() }
            ?: setOf("left", "right", "bottom")

    /** layer 0: under the complications; layer 1: hands and anything marked "top". */
    fun draw(c: Canvas, cx: Float, cy: Float, r: Float, spec: JSONObject, pal: Pal, v: Values, ambient: Boolean, layer: Int, p: Paint) {
        val g = G(c, cx, cy, r, pal, v, ambient, p)
        if (layer == 0) g.background(spec.optJSONObject("bg"))
        val els = spec.optJSONArray("els") ?: return
        for (i in 0 until min(els.length(), MAX_ELEMENTS)) {
            val e = els.optJSONObject(i) ?: continue
            val top = e.optString("t") == "hand" || e.optBoolean("top")
            if ((layer == 1) != top) continue
            if (ambient && !g.showInAmbient(e)) continue
            runCatching { g.element(e) }
        }
    }

    private class G(val c: Canvas, val cx: Float, val cy: Float, val r: Float, val pal: Pal, val v: Values,
                    val ambient: Boolean, val p: Paint) {

        fun num(e: JSONObject, k: String, def: Float, lo: Float = -3f, hi: Float = 3f): Float {
            val d = e.optDouble(k, def.toDouble())
            return if (d.isNaN()) def else d.toFloat().coerceIn(lo, hi)
        }
        fun int(e: JSONObject, k: String, def: Int, lo: Int = 0, hi: Int = 120) = e.optInt(k, def).coerceIn(lo, hi)
        fun str(e: JSONObject, k: String, def: String = "") = e.optString(k, def).take(40)

        /** Always-on mode: no seconds, and no large filled areas (OLED burn-in and battery). */
        fun showInAmbient(e: JSONObject): Boolean {
            if (e.has("amb")) return e.optBoolean("amb")
            val v = e.optString("v")
            if (v == "second" || v == "ss") return false
            return when (e.optString("t")) {
                "disc", "rect" -> !e.has("c")
                "rays", "sweep" -> false
                else -> true
            }
        }

        // --- colours ---
        fun col(s: String?, alpha: Float = 1f): Int {
            var base = when (s) {
                null, "", "ink" -> pal.ink
                "accent" -> pal.accent
                "dim" -> withAlpha(pal.ink, 0.44f)
                "faint" -> withAlpha(pal.ink, 0.15f)
                "bg1" -> pal.bg1
                "bg2" -> pal.bg2
                "black" -> Color.BLACK
                "white" -> Color.WHITE
                else -> parseHex(s) ?: pal.ink
            }
            if (ambient) base = grey(base, s)
            return if (alpha >= 1f) base else withAlpha(base, Color.alpha(base) / 255f * alpha)
        }
        private fun grey(cv: Int, name: String?): Int = when (name) {
            "accent" -> 0xFF9A9A9A.toInt()
            "bg1", "bg2", "black" -> Color.BLACK
            else -> {
                val l = (0.3 * Color.red(cv) + 0.59 * Color.green(cv) + 0.11 * Color.blue(cv)).roundToInt().coerceIn(60, 230)
                Color.argb(Color.alpha(cv), l, l, l)
            }
        }
        private fun parseHex(s: String): Int? = when {
            s.length == 7 && s[0] == '#' -> s.substring(1).toLongOrNull(16)?.let { (0xFF000000 or it).toInt() }
            s.length == 9 && s[0] == '#' -> s.substring(1).toLongOrNull(16)?.toInt()
            else -> null
        }
        private fun withAlpha(cv: Int, a: Float) = (cv and 0x00FFFFFF) or ((a.coerceIn(0f, 1f) * 255).roundToInt() shl 24)
        fun ec(e: JSONObject, k: String = "c", def: String = "ink") = col(e.optString(k, def).ifEmpty { def }, num(e, "a", 1f, 0f, 1f))

        // --- values ---
        fun frac(name: String): Float = when (name) {
            "hour" -> v.hour / 12f
            "minute" -> v.min / 60f
            "second" -> v.sec / 60f
            "battery" -> v.battery / 100f
            "day24" -> (v.hour24 + v.min / 60f) / 24f
            "month" -> v.day / 31f
            else -> 1f
        }

        fun text(name: String, e: JSONObject): String = when (name) {
            "time" -> hhmm()
            "time0" -> "%02d:%02d".format(if (v.h24) v.hour24 else h12(), v.minuteInt)
            "hh" -> if (v.h24) "%02d".format(v.hour24) else "${h12()}"
            "h" -> if (v.h24) "${v.hour24}" else "${h12()}"
            "mm" -> "%02d".format(v.minuteInt)
            "ss" -> "%02d".format(v.sec.toInt())
            "date" -> "${v.wd} ${v.day}"
            "wd" -> v.wd
            "weekday" -> v.weekday
            "day" -> "${v.day}"
            "dd" -> "%02d".format(v.day)
            "month" -> v.month
            "ampm" -> if (v.hour24 < 12) "AM" else "PM"
            "battery" -> "${v.battery}%"
            "words" -> words(v.hour24, v.minuteInt)
            else -> str(e, "text")
        }
        fun h12() = (v.hour24 + 11) % 12 + 1
        fun hhmm() = if (v.h24) "%02d:%02d".format(v.hour24, v.minuteInt) else "%d:%02d".format(h12(), v.minuteInt)

        // --- geometry ---
        fun px(deg: Float, rad: Float) = cx + (sin(Math.toRadians(deg.toDouble())) * rad * r).toFloat()
        fun py(deg: Float, rad: Float) = cy - (cos(Math.toRadians(deg.toDouble())) * rad * r).toFloat()

        fun stroke(w: Float, color: Int, cap: String = "round") {
            p.reset(); p.isAntiAlias = true; p.style = Paint.Style.STROKE; p.strokeWidth = w * r; p.color = color
            p.strokeCap = if (cap == "butt") Paint.Cap.BUTT else Paint.Cap.ROUND
        }
        fun fill(color: Int) { p.reset(); p.isAntiAlias = true; p.style = Paint.Style.FILL; p.color = color }

        fun background(bg: JSONObject?) {
            if (ambient) { c.drawColor(Color.BLACK); return }
            val style = bg?.optString("style") ?: "radial"
            val c1 = col(bg?.optString("c1", "bg1") ?: "bg1"); val c2 = col(bg?.optString("c2", "bg2") ?: "bg2")
            p.reset(); p.isAntiAlias = true
            p.shader = when (style) {
                "solid" -> null
                "linear" -> {
                    val a = num(bg ?: JSONObject(), "angle", 180f, -360f, 360f)
                    LinearGradient(px(a + 180, 1f), py(a + 180, 1f), px(a, 1f), py(a, 1f), c1, c2, Shader.TileMode.CLAMP)
                }
                else -> RadialGradient(cx + num(bg ?: JSONObject(), "x", 0f) * r, cy + num(bg ?: JSONObject(), "y", 0f) * r,
                    r * num(bg ?: JSONObject(), "r", 1f, 0.1f, 3f), c1, c2, Shader.TileMode.CLAMP)
            }
            p.color = c1
            c.drawCircle(cx, cy, r * 1.5f, p)
            p.shader = null
        }

        fun element(e: JSONObject) {
            when (e.optString("t")) {
                "ticks" -> ticks(e)
                "nums" -> nums(e)
                "hand" -> hand(e)
                "text" -> textEl(e)
                "arc" -> arc(e)
                "ring" -> { stroke(num(e, "w", .01f, 0f, 1f), ec(e)); c.drawCircle(cx + num(e, "x", 0f) * r, cy + num(e, "y", 0f) * r, num(e, "r", .9f, 0f) * r, p) }
                "disc" -> disc(e)
                "rect" -> rect(e)
                "dot" -> { val a = frac(str(e, "v", "hour")) * 360f; fill(ec(e, def = "accent")); c.drawCircle(px(a, num(e, "r", .8f)), py(a, num(e, "r", .8f)), num(e, "size", .04f, 0f, 1f) * r, p) }
                "sweep" -> sweep(e)
                "rays" -> rays(e)
                "marker" -> marker(e)
                "line" -> { stroke(num(e, "w", .01f, 0f, 1f), ec(e), str(e, "cap", "round")); c.drawLine(cx + num(e, "x1", 0f) * r, cy + num(e, "y1", 0f) * r, cx + num(e, "x2", 0f) * r, cy + num(e, "y2", 0f) * r, p) }
                "binary" -> binary(e)
            }
        }

        fun ticks(e: JSONObject) {
            val n = int(e, "n", 60, 1, 120)
            val skip = intSet(e.optJSONArray("skip"))
            val every = int(e, "every", 0, 0, 120)
            val litName = e.optString("lit")
            val litCount = if (litName.isNotEmpty()) floor(frac(litName) * n).toInt() else -1
            val shape = str(e, "shape", "line")
            val off = when (e.optString("rotate")) { "hour" -> -frac("hour") * 360f; "minute" -> -frac("minute") * 360f; else -> 0f }
            for (i in 0 until n) {
                if (i in skip) continue
                val major = every > 0 && i % every == 0
                val r1 = num(e, if (major) "r1b" else "r1", .9f); val r2 = num(e, if (major) "r2b" else "r2", .95f)
                val w = num(e, if (major) "wb" else "w", .01f, 0f, 1f)
                var color = if (major) ec(e, "cb", e.optString("c", "ink")) else ec(e)
                if (litCount >= 0 && i <= litCount) color = col(e.optString("lc", "accent"))
                val a = i * 360f / n + off
                if (outside(e, a)) continue
                if (shape == "dot") { fill(color); c.drawCircle(px(a, r2), py(a, r2), w / 2f * r, p) }
                else { stroke(w, color, str(e, "cap", "butt")); c.drawLine(px(a, r1), py(a, r1), px(a, r2), py(a, r2), p) }
            }
        }

        fun nums(e: JSONObject) {
            val labels = e.optJSONArray("labels")
            val n = labels?.length()?.coerceIn(1, 60) ?: int(e, "n", 12, 1, 60)
            val skip = intSet(e.optJSONArray("skip"))
            val off = when (e.optString("rotate")) { "hour" -> -frac("hour") * 360f; "minute" -> -frac("minute") * 360f; else -> 0f }
            val rad = num(e, "r", .78f); val size = num(e, "size", .16f, 0f, 2f)
            val hl = e.optString("hl")
            val cur = if (hl == "hour") (v.hour24 % 12) else -1
            for (i in 0 until n) {
                if (i in skip) continue
                val label = labels?.optString(i)?.take(8) ?: if (n == 12) "${if (i == 0) 12 else i}" else "$i"
                val a = i * 360f / n + off
                if (outside(e, a)) continue
                val isCur = i == cur && n == 12
                val s = if (isCur) size * num(e, "hs", 1.3f, 0f, 4f) else size
                val color = if (isCur) col(e.optString("hc", "accent")) else ec(e)
                val x = px(a, rad); val y = py(a, rad)
                if (e.optString("orient") == "radial") {
                    c.save(); c.rotate(a, x, y); drawText(label, x, y, s, color, e); c.restore()
                } else drawText(label, x, y, s, color, e)
            }
        }

        fun drawText(s: String, x: Float, y: Float, size: Float, color: Int, e: JSONObject, align: String = "center") {
            p.reset(); p.isAntiAlias = true; p.color = color; p.typeface = font(str(e, "font", "bold")); p.textSize = size * r
            p.letterSpacing = num(e, "track", 0f, -0.5f, 2f)
            p.textAlign = when (align) { "left" -> Paint.Align.LEFT; "right" -> Paint.Align.RIGHT; else -> Paint.Align.CENTER }
            val glow = num(e, "glow", 0f, 0f, 0.5f)
            if (glow > 0f && !ambient) p.setShadowLayer(glow * r, 0f, 0f, color)
            if (e.optBoolean("outline")) { p.style = Paint.Style.STROKE; p.strokeWidth = size * r * 0.04f }
            val lines = s.split('\n').take(6)
            val lh = size * r * num(e, "lh", 1.05f, 0.5f, 3f)
            val fm = p.fontMetrics
            val first = y - (lines.size - 1) * lh / 2f - (fm.ascent + fm.descent) / 2f
            lines.forEachIndexed { i, line -> c.drawText(line, x, first + i * lh, p) }
            p.clearShadowLayer()
        }

        fun textEl(e: JSONObject) {
            var s = text(str(e, "v", "custom"), e)
            when (e.optString("case")) { "lower" -> s = s.lowercase(); "upper" -> s = s.uppercase(); "title" -> s = s.lowercase().replaceFirstChar { it.uppercase() } }
            drawText(s, cx + num(e, "x", 0f) * r, cy + num(e, "y", 0f) * r, num(e, "size", .2f, 0f, 2f), ec(e), e, str(e, "align", "center"))
        }

        fun hand(e: JSONObject) {
            val a = frac(str(e, "v", "hour")) * 360f
            val len = num(e, "len", .6f, 0f, 1.5f); val w = num(e, "w", .04f, 0f, 1f) * r
            val tail = num(e, "tail", 0f, 0f, 1f) * r; val color = ec(e)
            c.save(); c.rotate(a, cx, cy)
            val tip = cy - len * r
            when (e.optString("style")) {
                "taper", "outline" -> {
                    val path = Path().apply {
                        moveTo(cx - w / 2, cy + tail); lineTo(cx - w * .15f, tip); lineTo(cx + w * .15f, tip); lineTo(cx + w / 2, cy + tail); close()
                    }
                    if (e.optString("style") == "outline") { stroke(.012f, color); p.strokeJoin = Paint.Join.ROUND } else fill(color)
                    c.drawPath(path, p)
                }
                "sword" -> {
                    val path = Path().apply {
                        moveTo(cx, cy + tail); lineTo(cx - w / 2, cy - len * r * .25f); lineTo(cx, tip); lineTo(cx + w / 2, cy - len * r * .25f); close()
                    }
                    fill(color); c.drawPath(path, p)
                }
                "lollipop" -> {
                    stroke(w / r * .5f, color); c.drawLine(cx, cy + tail, cx, tip + w * 1.6f, p)
                    fill(color); c.drawCircle(cx, tip + w * 1.6f, w * 1.6f, p)
                }
                "arrow" -> {
                    stroke(w / r, color); c.drawLine(cx, cy + tail, cx, tip + len * r * .18f, p)
                    fill(color)
                    c.drawPath(Path().apply { moveTo(cx - w * 1.8f, tip + len * r * .2f); lineTo(cx, tip); lineTo(cx + w * 1.8f, tip + len * r * .2f); close() }, p)
                }
                else -> { stroke(w / r, color, if (e.optString("style") == "butt") "butt" else "round"); c.drawLine(cx, cy + tail, cx, tip, p) }
            }
            e.optString("tip").takeIf { it.isNotEmpty() }?.let {
                stroke(w / r, col(it)); c.drawLine(cx, tip + len * r * num(e, "tiplen", .25f, 0f, 1f), cx, tip, p)
            }
            c.restore()
        }

        fun arc(e: JSONObject) {
            val rad = num(e, "r", .9f, 0f); val w = num(e, "w", .04f, 0f, 1f)
            val start = num(e, "start", 0f, -720f, 720f); val span = num(e, "span", 360f, -360f, 360f)
            val x = cx + num(e, "x", 0f) * r; val y = cy + num(e, "y", 0f) * r
            val oval = RectF(x - rad * r, y - rad * r, x + rad * r, y + rad * r)
            e.optString("track").takeIf { it.isNotEmpty() }?.let { stroke(w, col(it), str(e, "cap", "round")); c.drawArc(oval, start - 90f, span, false, p) }
            val sweep = span * frac(str(e, "v", "full"))
            if (sweep == 0f) return
            stroke(w, ec(e, def = "accent"), str(e, "cap", "round")); c.drawArc(oval, start - 90f, sweep, false, p)
        }

        fun disc(e: JSONObject) {
            val x = cx + num(e, "x", 0f) * r; val y = cy + num(e, "y", 0f) * r; val rad = num(e, "r", .1f, 0f) * r
            if (e.has("c")) {
                fill(ec(e))
                e.optString("c2").takeIf { it.isNotEmpty() && !ambient }?.let { p.shader = RadialGradient(x, y - rad * .3f, rad * 1.2f, ec(e), col(it), Shader.TileMode.CLAMP) }
                c.drawCircle(x, y, rad, p); p.shader = null
            }
            e.optString("sc").takeIf { it.isNotEmpty() }?.let { stroke(num(e, "sw", .01f, 0f, 1f), col(it)); c.drawCircle(x, y, rad, p) }
        }

        fun rect(e: JSONObject) {
            val x = cx + num(e, "x", 0f) * r; val y = cy + num(e, "y", 0f) * r
            val hw = num(e, "w", .3f, 0f) * r / 2; val hh = num(e, "h", .2f, 0f) * r / 2; val rad = num(e, "rad", .05f, 0f) * r
            val box = RectF(x - hw, y - hh, x + hw, y + hh)
            if (e.has("c")) { fill(ec(e)); c.drawRoundRect(box, rad, rad, p) }
            e.optString("sc").takeIf { it.isNotEmpty() }?.let { stroke(num(e, "sw", .01f, 0f, 1f), col(it, num(e, "a", 1f, 0f, 1f))); c.drawRoundRect(box, rad, rad, p) }
        }

        fun sweep(e: JSONObject) {
            val a = frac(str(e, "v", "second")) * 360f; val rad = num(e, "r", .95f, 0f) * r
            val span = num(e, "span", 60f, 0f, 360f); val alpha = num(e, "alpha", .35f, 0f, 1f)
            val steps = 12
            for (k in 0 until steps) {
                fill(col(e.optString("c", "accent"), alpha * (1 - k / steps.toFloat())))
                c.drawArc(cx - rad, cy - rad, cx + rad, cy + rad, a - 90f - (k + 1) * span / steps, span / steps + .5f, true, p)
            }
        }

        fun rays(e: JSONObject) {
            val n = int(e, "n", 24, 2, 120); val rad = num(e, "r", 1.2f, 0f) * r
            fill(ec(e))
            for (i in 0 until n step 2) c.drawArc(cx - rad, cy - rad, cx + rad, cy + rad, i * 360f / n - 90f, 360f / n, true, p)
        }

        fun marker(e: JSONObject) {
            val a = num(e, "a", 0f, -720f, 720f) + (e.optString("v").takeIf { it.isNotEmpty() }?.let { frac(it) * 360f } ?: 0f)
            val rad = num(e, "r", .9f); val s = num(e, "size", .06f, 0f, 1f) * r
            val x = px(a, rad); val y = py(a, rad)
            fill(ec(e, def = "accent"))
            c.save(); c.rotate(a, x, y)
            when (e.optString("shape")) {
                "dia" -> c.drawPath(Path().apply { moveTo(x, y - s); lineTo(x + s * .6f, y); lineTo(x, y + s); lineTo(x - s * .6f, y); close() }, p)
                "bar" -> c.drawRoundRect(x - s * .25f, y - s, x + s * .25f, y + s, s * .2f, s * .2f, p)
                "circle" -> c.drawCircle(x, y, s / 2, p)
                else -> c.drawPath(Path().apply { moveTo(x - s * .6f, y - s * .5f); lineTo(x + s * .6f, y - s * .5f); lineTo(x, y + s * .5f); close() }, p)
            }
            c.restore()
        }

        fun binary(e: JSONObject) {
            val value = when (e.optString("v")) { "minute" -> v.minuteInt; "second" -> v.sec.toInt(); else -> v.hour24 }
            val bits = int(e, "n", 6, 1, 8); val size = num(e, "size", .05f, 0f, 1f) * r; val gap = num(e, "gap", .14f, 0f, 1f) * r
            val x0 = cx + num(e, "x", 0f) * r - (bits - 1) * gap / 2; val y = cy + num(e, "y", 0f) * r
            for (b in 0 until bits) {
                val on = (value shr (bits - 1 - b)) and 1 == 1
                fill(if (on) ec(e, def = "accent") else col(e.optString("c2", "faint")))
                c.drawCircle(x0 + b * gap, y, size, p)
            }
        }

        /** Elements with "win" only draw within that many degrees either side of 12 o'clock. */
        fun outside(e: JSONObject, a: Float): Boolean {
            val win = num(e, "win", 0f, 0f, 180f)
            if (win <= 0f) return false
            val norm = ((a % 360f) + 540f) % 360f - 180f
            return kotlin.math.abs(norm) > win
        }

        fun intSet(a: JSONArray?): Set<Int> = a?.let { (0 until min(it.length(), 120)).map { i -> it.optInt(i, -1) }.toSet() } ?: emptySet()
    }

    private val HOURS = listOf("TWELVE", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN")
    private val MINS = mapOf(5 to "FIVE", 10 to "TEN", 15 to "QUARTER", 20 to "TWENTY", 25 to "TWENTY-FIVE", 30 to "HALF")

    /** "QUARTER\nPAST\nTEN", rounded to five minutes. Must match words() in FaceSpecs.swift. */
    fun words(h24: Int, m: Int): String {
        var m5 = ((m + 2) / 5) * 5
        var h = h24 % 12
        if (m5 == 60) { m5 = 0; h = (h + 1) % 12 }
        return when {
            m5 == 0 -> "${HOURS[h]}\nO'CLOCK"
            m5 <= 30 -> "${MINS[m5]}\nPAST\n${HOURS[h]}"
            else -> "${MINS[60 - m5]}\nTO\n${HOURS[(h + 1) % 12]}"
        }
    }

    @Suppress("unused") private fun clamp01(x: Float) = max(0f, min(1f, x))
}
