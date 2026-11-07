package nz.galaxybridge.watch.face

import android.content.ComponentName
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.text.format.DateFormat
import android.view.SurfaceHolder
import androidx.wear.watchface.CanvasComplicationFactory
import androidx.wear.watchface.CanvasType
import androidx.wear.watchface.ComplicationSlot
import androidx.wear.watchface.ComplicationSlotsManager
import androidx.wear.watchface.DrawMode
import androidx.wear.watchface.Renderer
import androidx.wear.watchface.WatchFace
import androidx.wear.watchface.WatchFaceService
import androidx.wear.watchface.WatchFaceType
import androidx.wear.watchface.WatchState
import androidx.wear.watchface.complications.ComplicationSlotBounds
import androidx.wear.watchface.complications.DefaultComplicationDataSourcePolicy
import androidx.wear.watchface.complications.SystemDataSources
import androidx.wear.watchface.complications.data.ComplicationType
import androidx.wear.watchface.complications.rendering.CanvasComplicationDrawable
import androidx.wear.watchface.complications.rendering.ComplicationDrawable
import androidx.wear.watchface.complications.rendering.ComplicationStyle
import androidx.wear.watchface.style.CurrentUserStyleRepository
import androidx.wear.watchface.style.UserStyleSchema
import androidx.wear.watchface.style.UserStyleSetting
import androidx.wear.watchface.style.UserStyleSetting.ComplicationSlotsUserStyleSetting
import androidx.wear.watchface.style.UserStyleSetting.ComplicationSlotsUserStyleSetting.ComplicationSlotOverlay
import androidx.wear.watchface.style.UserStyleSetting.ComplicationSlotsUserStyleSetting.ComplicationSlotsOption
import androidx.wear.watchface.style.WatchFaceLayer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import nz.galaxybridge.watch.PhoneBatteryComplication
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The Wear OS Bridge watch face. It draws whichever design was picked in the iPhone app's face
 * gallery, has three complication slots (edited from the watch's own face editor) and a
 * low-power always-on mode.
 */
class BridgeFaceService : WatchFaceService() {
    companion object {
        const val LEFT = 100
        const val RIGHT = 101
        const val BOTTOM = 102
        val SLOTS = mapOf(
            LEFT to RectF(0.20f, 0.40f, 0.40f, 0.60f),
            RIGHT to RectF(0.60f, 0.40f, 0.80f, 0.60f),
            BOTTOM to RectF(0.40f, 0.65f, 0.60f, 0.85f),
        )

        /**
         * Where the three complications sit, per arrangement (centres in face-radius units,
         * 0,0 = middle). Must match slotPositions in FaceSpecs.swift.
         */
        val ARRANGEMENTS: Map<String, Map<Int, Triple<Float, Float, Float>>> = mapOf(
            "std" to mapOf(LEFT to Triple(-.4f, 0f, .2f), RIGHT to Triple(.4f, 0f, .2f), BOTTOM to Triple(0f, .5f, .2f)),
            "low" to mapOf(LEFT to Triple(-.48f, .3f, .18f), RIGHT to Triple(.48f, .3f, .18f), BOTTOM to Triple(0f, .64f, .17f)),
            "top" to mapOf(LEFT to Triple(-.42f, -.42f, .18f), RIGHT to Triple(.42f, -.42f, .18f), BOTTOM to Triple(0f, .58f, .19f)),
            "wide" to mapOf(LEFT to Triple(-.56f, 0f, .17f), RIGHT to Triple(.56f, 0f, .17f), BOTTOM to Triple(0f, .6f, .18f)),
        )
        private val ORDER = listOf(LEFT, RIGHT, BOTTOM)
        const val STYLE_SLOTS = "slots"

        fun optionId(arrangement: String, shown: Set<String>) =
            "$arrangement:" + listOf("left", "right", "bottom").joinToString("") { if (it in shown) "1" else "0" }

        fun rect(c: Triple<Float, Float, Float>) =
            RectF(.5f + (c.first - c.third) / 2, .5f + (c.second - c.third) / 2, .5f + (c.first + c.third) / 2, .5f + (c.second + c.third) / 2)
    }

    override fun createUserStyleSchema(): UserStyleSchema {
        val options = ARRANGEMENTS.flatMap { (name, pos) ->
            (0 until 8).map { mask ->
                val overlays = ORDER.mapIndexed { i, id ->
                    ComplicationSlotOverlay.Builder(id)
                        .setEnabled(mask and (4 shr i) != 0)
                        .setComplicationSlotBounds(ComplicationSlotBounds(rect(pos.getValue(id))))
                        .build()
                }
                val key = "$name:" + (0 until 3).joinToString("") { if (mask and (4 shr it) != 0) "1" else "0" }
                ComplicationSlotsOption(UserStyleSetting.Option.Id(key), key, key, null, overlays)
            }
        }
        val setting = ComplicationSlotsUserStyleSetting(
            UserStyleSetting.Id(STYLE_SLOTS), "Complications", "Complication layout", null, options,
            listOf(WatchFaceLayer.COMPLICATIONS), options.first { it.id.value.decodeToString() == "std:111" })
        return UserStyleSchema(listOf(setting))
    }

    override fun createComplicationSlotsManager(currentUserStyleRepository: CurrentUserStyleRepository): ComplicationSlotsManager {
        val factory = CanvasComplicationFactory { watchState, listener ->
            CanvasComplicationDrawable(ComplicationDrawable(this), watchState, listener)
        }
        val types = listOf(ComplicationType.RANGED_VALUE, ComplicationType.SHORT_TEXT,
            ComplicationType.MONOCHROMATIC_IMAGE, ComplicationType.SMALL_IMAGE)
        val phone = ComponentName(this, PhoneBatteryComplication::class.java)
        val policies = mapOf(
            LEFT to DefaultComplicationDataSourcePolicy(phone, ComplicationType.RANGED_VALUE,
                SystemDataSources.DATA_SOURCE_DAY_AND_DATE, ComplicationType.SHORT_TEXT),
            RIGHT to DefaultComplicationDataSourcePolicy(SystemDataSources.DATA_SOURCE_WATCH_BATTERY, ComplicationType.RANGED_VALUE),
            BOTTOM to DefaultComplicationDataSourcePolicy(SystemDataSources.DATA_SOURCE_STEP_COUNT, ComplicationType.SHORT_TEXT),
        )
        val slots = SLOTS.map { (id, rect) ->
            ComplicationSlot.createRoundRectComplicationSlotBuilder(id, factory, types, policies.getValue(id),
                ComplicationSlotBounds(rect)).build()
        }
        return ComplicationSlotsManager(slots, currentUserStyleRepository)
    }

    override suspend fun createWatchFace(
        surfaceHolder: SurfaceHolder,
        watchState: WatchState,
        complicationSlotsManager: ComplicationSlotsManager,
        currentUserStyleRepository: CurrentUserStyleRepository,
    ): WatchFace {
        FaceDesign.load(this)
        val renderer = FaceRenderer(this, surfaceHolder, watchState, complicationSlotsManager, currentUserStyleRepository)
        return WatchFace(WatchFaceType.ANALOG, renderer)
    }
}

class FaceRenderer(
    private val context: Context,
    surfaceHolder: SurfaceHolder,
    watchState: WatchState,
    private val slots: ComplicationSlotsManager,
    private val repo: CurrentUserStyleRepository,
) : Renderer.CanvasRenderer2<FaceRenderer.Assets>(surfaceHolder, repo, watchState, CanvasType.HARDWARE, 1000L, false) {

    class Assets : Renderer.SharedAssets { override fun onDestroy() {} }
    override suspend fun createSharedAssets() = Assets()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var design = FaceDesign.current.value
    private val p = Paint(Paint.ANTI_ALIAS_FLAG)
    private val bold = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
    private val dateFmt = DateTimeFormatter.ofPattern("EEE d", Locale.getDefault())
    private var bgShader: RadialGradient? = null
    private var bgKey = ""

    init {
        scope.launch {
            FaceDesign.current.collect { design = it; applySlots(it); styleComplications(); invalidate() }
        }
    }

    override fun onDestroy() { scope.cancel(); super.onDestroy() }

    /** Moves, shows or hides the complications to suit the design. */
    private fun applySlots(d: FaceDesign) {
        val spec = d.spec
        val arrangement = spec?.optString("slotpos")?.takeIf { it in BridgeFaceService.ARRANGEMENTS } ?: "std"
        val key = BridgeFaceService.optionId(arrangement, if (spec != null) SpecDraw.slots(spec) else setOf("left", "right", "bottom"))
        runCatching {
            val setting = repo.schema.userStyleSettings.first { it.id.value == BridgeFaceService.STYLE_SLOTS }
            val option = setting.options.first { it.id.value.decodeToString() == key }
            if (repo.userStyle.value[setting] != option) {
                repo.updateUserStyle(repo.userStyle.value.toMutableUserStyle().apply { this[setting] = option }.toUserStyle())
            }
        }.onFailure { android.util.Log.w("BridgeFace", "slots", it) }
    }

    private fun styleComplications() {
        for (slot in slots.complicationSlots.values) {
            val d = (slot.renderer as? CanvasComplicationDrawable)?.drawable ?: continue
            fun ComplicationStyle.apply(ink: Int, accent: Int) {
                backgroundColor = Color.TRANSPARENT
                borderColor = Color.TRANSPARENT
                borderStyle = ComplicationStyle.BORDER_STYLE_NONE
                textColor = ink; titleColor = ink; iconColor = accent
                rangedValuePrimaryColor = accent
                rangedValueSecondaryColor = (ink and 0x00FFFFFF) or (0x40 shl 24)
                highlightColor = accent
            }
            d.activeStyle.apply(design.ink, design.accent)
            d.ambientStyle.apply(0xFFCCCCCC.toInt(), 0xFF999999.toInt())
        }
    }

    override fun renderHighlightLayer(canvas: Canvas, bounds: Rect, zonedDateTime: ZonedDateTime, sharedAssets: Assets) {
        renderParameters.highlightLayer?.let { canvas.drawColor(it.backgroundTint) }
        for (slot in slots.complicationSlots.values) if (slot.enabled) slot.renderHighlightLayer(canvas, zonedDateTime, renderParameters)
    }

    override fun render(canvas: Canvas, bounds: Rect, zonedDateTime: ZonedDateTime, sharedAssets: Assets) {
        val ambient = renderParameters.drawMode == DrawMode.AMBIENT
        val d = design
        val s = bounds.width().toFloat()
        val f = Frame(canvas, s / 2f, bounds.exactCenterX(), bounds.exactCenterY(), ambient,
            accent = if (ambient) 0xFF9A9A9A.toInt() else d.accent,
            ink = if (ambient) 0xFFDDDDDD.toInt() else d.ink,
            dim = if (ambient) 0x66FFFFFF else d.dim)

        val spec = d.spec
        if (d.layout == "spec" && spec != null) {
            val v = SpecDraw.Values(zonedDateTime, DateFormat.is24HourFormat(context), battery())
            val pal = SpecDraw.Pal(d.bg1, d.bg2, d.accent, d.ink)
            SpecDraw.draw(canvas, f.cx, f.cy, f.r, spec, pal, v, ambient, 0, p)
            for (slot in slots.complicationSlots.values) if (slot.enabled) slot.render(canvas, zonedDateTime, renderParameters)
            SpecDraw.draw(canvas, f.cx, f.cy, f.r, spec, pal, v, ambient, 1, p)
            return
        }

        if (ambient) canvas.drawColor(Color.BLACK) else {
            val key = "${d.bg1}/${d.bg2}/$s"
            if (key != bgKey) {
                bgKey = key
                bgShader = RadialGradient(f.cx, f.cy, f.r, d.bg1, d.bg2, Shader.TileMode.CLAMP)
            }
            p.reset(); p.isAntiAlias = true; p.shader = bgShader
            canvas.drawRect(bounds, p); p.shader = null
        }

        val t = Time(zonedDateTime, DateFormat.is24HourFormat(context), dateFmt)
        // Dials first, then complications, then hands on top.
        FaceDraw.background(f, d.layout, t, p, bold)
        for (slot in slots.complicationSlots.values) if (slot.enabled) slot.render(canvas, zonedDateTime, renderParameters)
        FaceDraw.foreground(f, d.layout, t, p, bold)
    }

    private var batteryAt = 0L
    private var batteryPct = 0
    private fun battery(): Int {
        val now = System.currentTimeMillis()
        if (now - batteryAt > 60_000) {
            batteryAt = now
            batteryPct = context.getSystemService(android.os.BatteryManager::class.java)
                ?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)?.coerceIn(0, 100) ?: 0
        }
        return batteryPct
    }
}

class Frame(val c: Canvas, val r: Float, val cx: Float, val cy: Float, val ambient: Boolean,
            val accent: Int, val ink: Int, val dim: Int) {
    /** Background tracks for rings and arcs. */
    val faint: Int get() = (ink and 0x00FFFFFF) or (0x26 shl 24)
}

class Time(z: ZonedDateTime, h24: Boolean, dateFmt: DateTimeFormatter) {
    val sec = z.second.toFloat()
    val min = z.minute + sec / 60f
    val hour = (z.hour % 12) + min / 60f
    val hhmm: String = "%d:%02d".format(if (h24) z.hour else ((z.hour + 11) % 12 + 1), z.minute)
        .let { if (h24) it.padStart(5, '0') else it }
    val date: String = z.format(dateFmt).uppercase()
}

/**
 * The eight layouts. Units are fractions of the face radius, so this matches the iPhone
 * gallery's renderer (FaceRender in FaceCatalog.swift) exactly.
 */
object FaceDraw {
    fun background(f: Frame, layout: String, t: Time, p: Paint, bold: Typeface) = with(f) {
        when (layout) {
            "classic" -> {
                for (i in 0 until 60) if (i % 5 == 0) tick(f, p, i * 6f, .82f, .95f, .022f, ink)
                    else tick(f, p, i * 6f, .90f, .95f, .008f, dim)
                text(f, p, bold, "12", 0f, -.66f, .20f, accent)
            }
            "minimal" -> for (i in 0 until 12) dot(f, p, i * 30f, .88f, if (i == 0) .04f else .025f, if (i == 0) accent else dim)
            "bold" -> for (i in 0 until 12) tick(f, p, i * 30f, .74f, .95f, .07f, if (i % 3 == 0) accent else ink, round = false)
            "digital" -> {
                ring(f, p, .93f, .035f, faint)
                if (!ambient) arc(f, p, .93f, .035f, 0f, t.sec * 6f, accent)
                text(f, p, bold, t.date, 0f, -.70f, .11f, accent)
            }
            "ring" -> {
                ring(f, p, .90f, .08f, faint); arc(f, p, .90f, .08f, 0f, t.min * 6f, accent)
                ring(f, p, .76f, .08f, faint); arc(f, p, .76f, .08f, 0f, t.hour * 30f, ink)
            }
            "orbit" -> {
                ring(f, p, .90f, .006f, dim); ring(f, p, .70f, .006f, dim)
                text(f, p, bold, t.date, 0f, -.56f, .10f, dim)
            }
            "sport" -> {
                for (i in 0 until 60) tick(f, p, i * 6f, .94f, .99f, .008f, dim)
                for (i in 1..12) text(f, p, bold, "${i * 5}", angleX(i * 30f, .84f), angleY(i * 30f, .84f), .09f, dim)
                text(f, p, bold, t.date, 0f, -.64f, .09f, accent)
            }
            "radar" -> {
                for (rr in listOf(.30f, .55f, .80f)) ring(f, p, rr, .006f, dim)
                line(f, p, 0f, -.95f, 0f, .95f, .004f, dim); line(f, p, -.95f, 0f, .95f, 0f, .004f, dim)
                for (i in 0 until 12) tick(f, p, i * 30f, .84f, .94f, .015f, ink)
                if (!ambient) for (k in 0 until 10) {
                    p.reset(); p.isAntiAlias = true; p.color = accent
                    p.alpha = (255 * .35f * (1 - k / 10f)).toInt()
                    c.drawArc(cx - .95f * r, cy - .95f * r, cx + .95f * r, cy + .95f * r,
                        t.sec * 6f - 90f - (k + 1) * 6f, 6.5f, true, p)
                }
            }
        }
    }

    fun foreground(f: Frame, layout: String, t: Time, p: Paint, bold: Typeface) = with(f) {
        when (layout) {
            "classic" -> {
                hand(f, p, t.hour * 30f, .50f, .07f, ink); hand(f, p, t.min * 6f, .78f, .045f, ink)
                if (!ambient) hand(f, p, t.sec * 6f, .86f, .016f, accent, tail = .18f)
                dot(f, p, 0f, 0f, .05f, accent)
            }
            "minimal" -> {
                hand(f, p, t.hour * 30f, .48f, .04f, ink); hand(f, p, t.min * 6f, .80f, .025f, ink)
                if (!ambient) hand(f, p, t.sec * 6f, .85f, .01f, accent)
                dot(f, p, 0f, 0f, .03f, accent)
            }
            "bold" -> {
                hand(f, p, t.hour * 30f, .52f, .10f, ink); hand(f, p, t.min * 6f, .82f, .07f, ink)
                hand(f, p, t.min * 6f, .82f, .07f, accent, from = .62f)
                if (!ambient) hand(f, p, t.sec * 6f, .88f, .012f, accent)
                dot(f, p, 0f, 0f, .07f, ink)
            }
            "digital" -> text(f, p, bold, t.hhmm, 0f, -.36f, .42f, ink)
            "ring" -> text(f, p, bold, t.hhmm, 0f, -.40f, .20f, ink)
            "orbit" -> {
                text(f, p, bold, t.hhmm, 0f, -.36f, .18f, ink)
                dot(f, p, t.hour * 30f, .70f, .07f, accent)
                dot(f, p, t.min * 6f, .90f, .05f, ink)
                if (!ambient) dot(f, p, t.sec * 6f, .90f, .02f, accent)
            }
            "sport" -> {
                text(f, p, bold, t.hhmm, 0f, -.36f, .34f, ink)
                if (!ambient) tick(f, p, t.sec * 6f, .90f, .99f, .02f, accent)
            }
            "radar" -> {
                hand(f, p, t.hour * 30f, .50f, .05f, ink); hand(f, p, t.min * 6f, .80f, .03f, ink)
                dot(f, p, 0f, 0f, .04f, accent)
            }
        }
    }

    private fun angleX(deg: Float, rad: Float) = (rad * Math.sin(Math.toRadians(deg.toDouble()))).toFloat()
    private fun angleY(deg: Float, rad: Float) = (-rad * Math.cos(Math.toRadians(deg.toDouble()))).toFloat()

    private fun stroke(p: Paint, w: Float, color: Int, round: Boolean = true) {
        p.reset(); p.isAntiAlias = true; p.style = Paint.Style.STROKE; p.strokeWidth = w; p.color = color
        p.strokeCap = if (round) Paint.Cap.ROUND else Paint.Cap.BUTT
    }

    private fun tick(f: Frame, p: Paint, deg: Float, from: Float, to: Float, w: Float, color: Int, round: Boolean = true) {
        stroke(p, w * f.r, color, round)
        f.c.drawLine(f.cx + angleX(deg, from) * f.r, f.cy + angleY(deg, from) * f.r,
            f.cx + angleX(deg, to) * f.r, f.cy + angleY(deg, to) * f.r, p)
    }

    private fun hand(f: Frame, p: Paint, deg: Float, len: Float, w: Float, color: Int, tail: Float = 0f, from: Float = 0f) {
        stroke(p, w * f.r, color)
        val start = if (from > 0f) from else -tail
        f.c.drawLine(f.cx + angleX(deg, start) * f.r, f.cy + angleY(deg, start) * f.r,
            f.cx + angleX(deg, len) * f.r, f.cy + angleY(deg, len) * f.r, p)
    }

    private fun line(f: Frame, p: Paint, x1: Float, y1: Float, x2: Float, y2: Float, w: Float, color: Int) {
        stroke(p, w * f.r, color)
        f.c.drawLine(f.cx + x1 * f.r, f.cy + y1 * f.r, f.cx + x2 * f.r, f.cy + y2 * f.r, p)
    }

    private fun dot(f: Frame, p: Paint, deg: Float, at: Float, radius: Float, color: Int) {
        p.reset(); p.isAntiAlias = true; p.color = color
        f.c.drawCircle(f.cx + angleX(deg, at) * f.r, f.cy + angleY(deg, at) * f.r, radius * f.r, p)
    }

    private fun ring(f: Frame, p: Paint, rad: Float, w: Float, color: Int) {
        stroke(p, w * f.r, color)
        f.c.drawCircle(f.cx, f.cy, rad * f.r, p)
    }

    private fun arc(f: Frame, p: Paint, rad: Float, w: Float, start: Float, sweep: Float, color: Int) {
        if (sweep <= 0f) return
        stroke(p, w * f.r, color)
        f.c.drawArc(f.cx - rad * f.r, f.cy - rad * f.r, f.cx + rad * f.r, f.cy + rad * f.r, start - 90f, sweep, false, p)
    }

    /** Text centred on (x, y), in radius units; size is the font size. */
    private fun text(f: Frame, p: Paint, bold: Typeface, s: String, x: Float, y: Float, size: Float, color: Int) {
        p.reset(); p.isAntiAlias = true; p.color = color; p.typeface = bold; p.textSize = size * f.r
        p.textAlign = Paint.Align.CENTER
        val fm = p.fontMetrics
        f.c.drawText(s, f.cx + x * f.r, f.cy + y * f.r - (fm.ascent + fm.descent) / 2f, p)
    }
}
